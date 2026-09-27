# One mutating runspace, with the listener free to serve authenticated reads.
# Provider closures are created inside the worker's runspace. The persisted
# provisioning store remains the authoritative job state across restarts.
function Set-EpicVMAgentOperationFailed {
    param($State, [string]$JobId)
    if (-not $JobId -or -not $State.Provisioning.Jobs.ContainsKey($JobId)) { return }
    $job = $State.Provisioning.Jobs[$JobId]
    if ($job.state -notin @('queued','cloning','booting')) { return }
    $job.failureStage = if ($job.state -eq 'queued') { 'preclaim' } else { 'agent_restart' }
    $job.state = 'setup_failed:' + $job.failureStage
    $job.errorCode = 'agent_worker_failed'
    $job.errorMessage = 'The provisioning worker stopped before the guest claim. Retry or recover the retained VM.'
    $job.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-EpicVMProvisioningStore -Store $State.Provisioning
}

function Start-EpicVMAgentOperation {
    param($State, [string]$AgentPath, [string]$Method, [string]$Path, $Headers, $Body, [string]$JobId = '')
    $workerState = [pscustomobject]@{
        Config=$State.Config; Token=$State.Token; Provider=$State.Provider
        StartedAt=$State.StartedAt; SyncRoot=$State.SyncRoot
        CompletedOperations=@{}; Provisioning=$State.Provisioning; DeferProvisioning=$false
    }
    $pipeline = [PowerShell]::Create()
    [void]$pipeline.AddScript({
        param($AgentPath, $WorkerState, $Method, $Path, $Headers, $Body, $JobId)
        $ErrorActionPreference = 'Stop'
        . $AgentPath -NoStart
        if ([string]$WorkerState.Config.Provider -eq 'HyperV') {
            $providerConfig = @{}
            foreach ($property in $WorkerState.Config.PSObject.Properties) { $providerConfig[$property.Name] = $property.Value }
            $WorkerState.Provider = New-EpicVMHyperVProvider -Config $providerConfig
        }
        if ($JobId) {
            # The raw one-use token stays in this worker. Once boot is ready,
            # the authenticated claim-reissue endpoint hands it to the caller.
            try { Start-EpicVMProvisioningJob -State $WorkerState -Job $WorkerState.Provisioning.Jobs[$JobId] | Out-Null }
            catch { } # Start-EpicVMProvisioningJob persists the terminal error.
        }
        else {
            Invoke-EpicVMApiRequest -State $WorkerState -Method $Method -Path $Path -Headers $Headers -Body $Body
        }
    }).AddArgument($AgentPath).AddArgument($workerState).AddArgument($Method).AddArgument($Path).AddArgument($Headers).AddArgument($Body).AddArgument($JobId)
    return [pscustomobject]@{Pipeline=$pipeline;Handle=$pipeline.BeginInvoke();State=$workerState;Context=$null;CacheKey='';RequestId='';JobId=$JobId}
}

function Complete-EpicVMAgentResponse {
    param($State, $Context, $Response, [string]$CacheKey, [string]$RequestId)
    if ($CacheKey -and $Response.StatusCode -ge 200 -and $Response.StatusCode -lt 300) {
        $State.CompletedOperations[$CacheKey] = $Response
        if ($State.CompletedOperations.Count -gt 256) { $State.CompletedOperations.Remove(@($State.CompletedOperations.Keys)[0]) }
    }
    [void](Write-EpicVMSafeHttpResponse -Response $Context.Response -StatusCode $Response.StatusCode -Json $Response.Json -Headers $Response.Headers -RequestId $RequestId)
    try { $Context.Response.Close() } catch { }
}

function Invoke-EpicVMAgentListener {
    param($State, $Listener, [string]$AgentPath)
    $State.DeferProvisioning = $true
    $operation = $null
    $incoming = $Listener.GetContextAsync()
    try {
        while ($Listener.IsListening) {
            if ($null -ne $operation) {
                $State.Provisioning = $operation.State.Provisioning
                if ($operation.Handle.IsCompleted) {
                    try {
                        $output = @($operation.Pipeline.EndInvoke($operation.Handle))
                        # Initialization can fail before the provisioning
                        # function has a chance to persist its own failure.
                        Set-EpicVMAgentOperationFailed -State $State -JobId $operation.JobId
                        if ($null -ne $operation.Context) {
                            $response = if ($output.Count) { $output[-1] } else { $null }
                            if ($null -eq $response) { throw 'The agent operation returned no response.' }
                            Complete-EpicVMAgentResponse -State $State -Context $operation.Context -Response $response -CacheKey $operation.CacheKey -RequestId $operation.RequestId
                        }
                    }
                    catch {
                        Set-EpicVMAgentOperationFailed -State $State -JobId $operation.JobId
                        if ($null -ne $operation.Context) {
                            $response = ConvertTo-EpicVMJsonResponse -StatusCode 500 -Body (New-EpicVMApiError -Code 'internal_error' -Message 'The agent operation failed.')
                            Complete-EpicVMAgentResponse -State $State -Context $operation.Context -Response $response -RequestId $operation.RequestId
                        }
                    }
                    finally { $operation.Pipeline.Dispose(); $operation = $null }
                }
            }
            if (-not $incoming.IsCompleted) { [void]$incoming.Wait(50); continue }
            $context = $incoming.GetAwaiter().GetResult()
            $incoming = $Listener.GetContextAsync()
            $requestId = [guid]::NewGuid().ToString('N')
            $response = $null
            $cacheKey = ''
            $createdJobId = ''
            try {
                $headers = @{}
                foreach ($key in $context.Request.Headers.AllKeys) { $headers[$key] = $context.Request.Headers[$key] }
                $path = '/' + $context.Request.Url.AbsolutePath.Trim('/')
                $method = $context.Request.HttpMethod
                $isMutation = Test-EpicVMMutationRequest -Method $method -Path $path
                $provided = ''
                $authorization = Get-EpicVMHeader -Headers $headers -Name 'Authorization'
                if ($authorization -match '^Bearer\s+(.+)$') { $provided = $Matches[1].Trim() }
                if (-not (Test-EpicVMBearerToken -ProvidedToken $provided -ExpectedToken $State.Token)) {
                    $response = ConvertTo-EpicVMJsonResponse -StatusCode 401 -Body (New-EpicVMApiError -Code 'unauthorized' -Message 'Authentication required.')
                }
                else {
                    $idempotencyKey = Get-EpicVMHeader -Headers $headers -Name 'Idempotency-Key'
                    if ($isMutation -and $idempotencyKey -and $idempotencyKey.Length -le 128) { $cacheKey = '{0}|{1}|{2}' -f $method,$path,$idempotencyKey }
                    if ($cacheKey -and $State.CompletedOperations.ContainsKey($cacheKey)) { $response = $State.CompletedOperations[$cacheKey] }
                    elseif ($isMutation -and $null -ne $operation) {
                        $response = ConvertTo-EpicVMJsonResponse -StatusCode 409 -Body (New-EpicVMApiError -Code 'agent_busy' -Message 'Another VM operation is still running. Follow its progress before retrying.')
                    }
                    elseif ($context.Request.ContentLength64 -gt 1048576) {
                        $response = ConvertTo-EpicVMJsonResponse -StatusCode 413 -Body (New-EpicVMApiError -Code 'body_too_large' -Message 'Request body exceeds the 1 MiB limit.')
                    }
                    else {
                        $body = $null
                        if ($context.Request.HasEntityBody) {
                            $read = Read-EpicVMBoundedBody -Stream $context.Request.InputStream
                            if ($read.TooLarge) { $response = ConvertTo-EpicVMJsonResponse -StatusCode 413 -Body (New-EpicVMApiError -Code 'body_too_large' -Message 'Request body exceeds the 1 MiB limit.') }
                            else { $body = $read.Body }
                        }
                        if ($null -eq $response) {
                            if ($isMutation -and -not ($method -eq 'POST' -and $path -eq '/v1/provisioning-jobs')) {
                                $operation = Start-EpicVMAgentOperation -State $State -AgentPath $AgentPath -Method $method -Path $path -Headers $headers -Body $body
                                $operation.Context = $context
                                $operation.CacheKey = $cacheKey
                                $operation.RequestId = $requestId
                                continue
                            }
                            $response = Invoke-EpicVMApiRequest -State $State -Method $method -Path $path -Headers $headers -Body $body
                            if ($method -eq 'POST' -and $path -eq '/v1/provisioning-jobs' -and $response.StatusCode -eq 202) {
                                $createdJobId = [string]$response.Body.job.id
                                $operation = Start-EpicVMAgentOperation -State $State -AgentPath $AgentPath -JobId $createdJobId
                            }
                        }
                    }
                }
            }
            catch {
                Set-EpicVMAgentOperationFailed -State $State -JobId $createdJobId
                $response = ConvertTo-EpicVMJsonResponse -StatusCode 500 -Body (New-EpicVMApiError -Code 'internal_error' -Message 'The agent could not process the request.')
            }
            Complete-EpicVMAgentResponse -State $State -Context $context -Response $response -CacheKey $cacheKey -RequestId $requestId
        }
    }
    finally {
        if ($null -ne $operation) { $operation.Pipeline.Stop(); $operation.Pipeline.Dispose() }
        $State.DeferProvisioning = $false
    }
}
