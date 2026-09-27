#Requires -Version 7.0
<# Injectable PowerShell Direct guest configuration provider. #>

Set-StrictMode -Version Latest

function Protect-EpicVMMachineSecret {
    param([Parameter(Mandatory)][SecureString]$Secret,[Parameter(Mandatory)][string]$Path)
    $ptr=[IntPtr]::Zero; $bytes=$null
    try {
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $bytes=[Text.Encoding]::UTF8.GetBytes($plain)
        $sealed=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $parent=Split-Path -Parent $Path
        if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        [IO.File]::WriteAllBytes($Path,$sealed)
        $acl=Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true,$false)
        foreach($rule in @($acl.Access)){[void]$acl.RemoveAccessRule($rule)}
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('SYSTEM','Read','Allow'))
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Administrators','Read','Allow'))
        Set-Acl -LiteralPath $Path -AclObject $acl
    } finally {
        if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
        if($ptr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
        $plain=$null
    }
}

function Get-EpicVMBootstrapCredential {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Username)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'The DPAPI bootstrap credential is unavailable.'}
    $sealed=[IO.File]::ReadAllBytes($Path); $bytes=$null; $secure=$null
    try {
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect($sealed,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $plain=[Text.Encoding]::UTF8.GetString($bytes)
        $secure=ConvertTo-SecureString $plain -AsPlainText -Force
        return [PSCredential]::new($Username,$secure)
    } catch { throw 'The DPAPI bootstrap credential could not be opened.' }
    finally {
        if($null -ne $sealed){[Array]::Clear($sealed,0,$sealed.Length)}
        if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
        $plain=$null
    }
}

function Get-EpicVMPowerShellDirectSafeMarker {
    param(
        [AllowNull()][object[]]$Records=@(),
        [AllowNull()][object]$ErrorRecord=$null
    )
    $safeMarkers=@(
        'EPICVM_POWERSHELL_DIRECT_READINESS_FAILED',
        'EPICVM_POWERSHELL_DIRECT_TIMEOUT',
        'EPICVM_POWERSHELL_DIRECT_OPEN_TIMEOUT',
        'EPICVM_POWERSHELL_DIRECT_OPERATION_TIMEOUT',
        'EPICVM_POWERSHELL_DIRECT_OPEN_FAILED',
        'EPICVM_POWERSHELL_DIRECT_OPERATION_FAILED',
        'EPICVM_POWERSHELL_DIRECT_CREDENTIAL_REJECTED',
        'EPICVM_POWERSHELL_DIRECT_VM_UNAVAILABLE',
        'EPICVM_POWERSHELL_DIRECT_VM_NOT_RUNNING',
        'EPICVM_POWERSHELL_DIRECT_HEARTBEAT_UNHEALTHY',
        'EPICVM_POWERSHELL_DIRECT_MODULE_UNAVAILABLE',
        'EPICVM_MANAGEMENT_OPEN_TIMEOUT',
        'EPICVM_MANAGEMENT_OPERATION_TIMEOUT',
        'EPICVM_MANAGEMENT_OPEN_FAILED',
        'EPICVM_MANAGEMENT_OPERATION_FAILED',
        'EPICVM_MANAGEMENT_CREDENTIAL_REJECTED',
        'EPICVM_MANAGEMENT_UNAVAILABLE',
        'EPICVM_MANAGEMENT_TRUSTED_HOSTS_BROAD',
        'EPICVM_SUNSHINE_INVALID_INPUT',
        'EPICVM_SUNSHINE_SERVICE_MISSING',
        'EPICVM_SUNSHINE_EXECUTABLE_MISSING',
        'EPICVM_SUNSHINE_VERSION_MISMATCH',
        'EPICVM_SUNSHINE_STATE_PATH_FAILED',
        'EPICVM_SUNSHINE_STATE_WRITE_FAILED',
        'EPICVM_SUNSHINE_STATE_ACL_FAILED',
        'EPICVM_SUNSHINE_FIREWALL_FAILED',
        'EPICVM_SUNSHINE_SERVICE_RESTART_FAILED',
        'EPICVM_SUNSHINE_LISTENER_FAILED',
        'EPICVM_SUNSHINE_VERIFICATION_FAILED',
        'guest_account_readiness_failed',
        'rdp_verification_failed',
        'bootstrap_cleanup_transport_failed',
        'bootstrap_cleanup_failed'
    )
    $allRecords=@($Records)
    if($null -ne $ErrorRecord){$allRecords+=@($ErrorRecord)}
    foreach($record in $allRecords){
        $exception=Get-EpicVMHyperVValue -Object $record -Name 'Exception' -Default $null
        $parts=@(
            [string](Get-EpicVMHyperVValue -Object $record -Name 'FullyQualifiedErrorId' -Default ''),
            [string](Get-EpicVMHyperVValue -Object $record -Name 'ErrorDetails' -Default ''),
            [string]$record
        )
        $chain=$exception
        for($depth=0;$null -ne $chain -and $depth -lt 5;$depth++){
            $parts += [string](Get-EpicVMHyperVValue -Object $chain -Name 'Message' -Default '')
            $chain=Get-EpicVMHyperVValue -Object $chain -Name 'InnerException' -Default $null
        }
        $recordText=$parts -join ' '
        foreach($candidate in $safeMarkers){
            if($recordText -match [regex]::Escape($candidate)){return $candidate}
        }
        $accountMarker=[regex]::Match($recordText,'(?i)guest_account_failed\|([a-z_]+)')
        if($accountMarker.Success -and $script:EpicVMGuestFailureDetailCodes -contains $accountMarker.Groups[1].Value.ToLowerInvariant()){
            return ('guest_account_failed|' + $accountMarker.Groups[1].Value.ToLowerInvariant())
        }
        $directText=$recordText.ToLowerInvariant()
        # Only explicit logon/password wording is a credential conclusion.
        # Generic access-denied text is also emitted when the LocalSystem
        # transport or Hyper-V session service cannot open, so it must never
        # be promoted to guest_credentials_rejected here.
        if($directText -match 'logon failure|user name or password|credentials? supplied.*not recognized|authentication failed'){
            return 'EPICVM_POWERSHELL_DIRECT_CREDENTIAL_REJECTED'
        }
        if($directText -match 'timed out|timeout'){
            return 'EPICVM_POWERSHELL_DIRECT_TIMEOUT'
        }
        if($directText -match 'parameter.*cannot be found|no parameter|not recognized as the name|module.*cannot be loaded|module.*not found'){
            return 'EPICVM_POWERSHELL_DIRECT_MODULE_UNAVAILABLE'
        }
        if($directText -match 'does not resolve to a single virtual machine|virtual machine.*not found|vm.*not running|powershell direct.*not available'){
            return 'EPICVM_POWERSHELL_DIRECT_VM_UNAVAILABLE'
        }
    }
    return $null
}

function Get-EpicVMPowerShellDirectFailureCode {
    param(
        [AllowNull()][object[]]$Records=@(),
        [AllowNull()][object]$ErrorRecord=$null,
        [ValidateSet('resolve','open','execute','collect')][string]$Phase='open',
        [bool]$SessionCreated=$false
    )
    $marker=Get-EpicVMPowerShellDirectSafeMarker -Records $Records -ErrorRecord $ErrorRecord
    if($marker -like 'guest_account_failed|*'){return 'guest_operation_failed'}
    if($marker -eq 'EPICVM_POWERSHELL_DIRECT_CREDENTIAL_REJECTED'){return 'guest_credentials_rejected'}
    if($marker -eq 'EPICVM_POWERSHELL_DIRECT_VM_NOT_RUNNING'){return 'hyperv_vm_not_running'}
    if($marker -eq 'EPICVM_POWERSHELL_DIRECT_HEARTBEAT_UNHEALTHY'){return 'guest_heartbeat_unhealthy'}
    if($marker -eq 'EPICVM_POWERSHELL_DIRECT_MODULE_UNAVAILABLE'){return 'direct_module_failure'}
    if($marker -eq 'EPICVM_POWERSHELL_DIRECT_OPEN_TIMEOUT'){return 'direct_open_timeout'}
    if($marker -eq 'EPICVM_POWERSHELL_DIRECT_OPERATION_TIMEOUT' -or $marker -eq 'EPICVM_POWERSHELL_DIRECT_TIMEOUT'){
        return $(if($SessionCreated){'direct_transport_error'}else{'direct_open_timeout'})
    }
    $errorObject=Get-EpicVMHyperVValue -Object $ErrorRecord -Name 'Exception' -Default $ErrorRecord
    $text=@(
        [string](Get-EpicVMHyperVValue -Object $errorObject -Name 'Message' -Default ''),
        [string](Get-EpicVMHyperVValue -Object $ErrorRecord -Name 'ErrorDetails' -Default '')
    ) -join ' '
    if($text -match '(?i)parameter.*cannot be found|no parameter|parameter binding'){return 'direct_parameter_failure'}
    if($text -match '(?i)module.*cannot be loaded|module.*not found|not recognized as the name'){return 'direct_module_failure'}
    if($text -match '(?i)runtime|runspace|pipeline'){return 'direct_runtime_failure'}
    # Do not infer a guest password failure from generic access-denied text.
    # Resolve-phase denial is a host/Hyper-V authorization result; denial
    # after resolve is an unclassified Direct transport failure unless the
    # guest explicitly reported a logon/password marker.
    if($text -match '(?i)logon failure|user name or password|credentials? supplied.*not recognized|authentication failed'){return 'guest_credentials_rejected'}
    if($text -match '(?i)access is denied|unauthorized'){
        return $(if($Phase -eq 'resolve'){'hyperv_access_denied'}else{'direct_transport_error'})
    }
    if($text -match '(?i)does not resolve to a single virtual machine|virtual machine.*not found|vm.*not found'){return 'hyperv_vm_not_found'}
    if($text -match '(?i)vm.*not running|not in the running state'){return 'hyperv_vm_not_running'}
    if($text -match '(?i)not supported|unsupported'){return 'direct_not_supported'}
    if($text -match '(?i)heartbeat.*(unhealthy|not healthy|not running)'){return 'guest_heartbeat_unhealthy'}
    if($Phase -eq 'open'){return 'direct_transport_error'}
    if($SessionCreated){return 'guest_operation_failed'}
    return 'direct_transport_error'
}

function New-EpicVMPowerShellDirectFailure {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][bool]$SessionCreated,
        [Parameter(Mandatory)][string]$CorrelationId,
        [Parameter(Mandatory)][int]$ElapsedMilliseconds
    )
    $exception=New-EpicVMHyperVError -Code $Code -Message 'The PowerShell Direct operation did not complete.'
    $exception | Add-Member NoteProperty SessionCreated ([bool]$SessionCreated) -Force
    $exception | Add-Member NoteProperty TransportPhase ([string]$Phase) -Force
    $exception | Add-Member NoteProperty CorrelationId ([string]$CorrelationId) -Force
    $exception | Add-Member NoteProperty DurationBucket ([string](ConvertTo-EpicVMOperationDurationBucket -Milliseconds $ElapsedMilliseconds)) -Force
    return $exception
}

function ConvertTo-EpicVMOperationDurationBucket {
    param([int]$Milliseconds=0)
    if($Milliseconds -lt 1000){return '<1s'}
    if($Milliseconds -lt 5000){return '1-5s'}
    if($Milliseconds -lt 15000){return '6-15s'}
    if($Milliseconds -lt 30000){return '16-30s'}
    if($Milliseconds -lt 60000){return '31-60s'}
    return '>60s'
}

function Invoke-EpicVMPowerShellDirectOnce {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$Script,
        [AllowNull()][object[]]$ArgumentList=@(),
        [int]$TimeoutSeconds=10,
        [AllowNull()][string]$VmId=''
    )
    $invoker=Get-EpicVMHyperVValue -Object $Provider -Name 'PowerShellDirectInvoker' -Default $null
    $correlationId=[Guid]::NewGuid().ToString('N')
    $started=[Diagnostics.Stopwatch]::StartNew()
    if($null -ne $invoker){
        try{return (ConvertTo-EpicVMDirectResult -Result (& $invoker $VmName $Credential $Script $ArgumentList))}
        catch{
            $marker=Get-EpicVMPowerShellDirectSafeMarker -ErrorRecord $_
            if($marker -like 'guest_account_failed|*'){
                $detail=$marker.Substring('guest_account_failed|'.Length)
                throw (New-EpicVMHyperVError -Code 'guest_account_failed' -Message 'The guest account operation failed.' -DetailCode $detail)
            }
            $code=Get-EpicVMPowerShellDirectFailureCode -ErrorRecord $_ -Phase 'open' -SessionCreated $false
            throw (New-EpicVMPowerShellDirectFailure -Code $code -Phase 'open' -SessionCreated $false -CorrelationId $correlationId -ElapsedMilliseconds ([int]$started.ElapsedMilliseconds))
        }
    }
    # Native production transport is an explicit session lifecycle. Open and
    # execute stay in one worker runspace: a PSSession created by one
    # PowerShell.Create() pipeline cannot safely be handed to a second runspace.
    # That split caused the repeated LocalSystem-only direct_transport_error.
    # Background remoting jobs remain forbidden as provisioning truth.
    $vmIdValue=$VmId
    $directHostServiceState=$null
    $workerPipeline=$null; $workerAsync=$null; $workerInput=$null; $workerOutput=$null
    $sessionCreated=$false; $phase='resolve'
    try {
        if([string]::IsNullOrWhiteSpace($vmIdValue)){
            try {
                $items=@(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VM' -Parameters @{Name=$VmName;ErrorAction='Stop'})
                if($items.Count -ne 1){throw 'vm not found'}
                $vmIdValue=[string](Get-EpicVMHyperVValue -Object $items[0] -Name 'Id' -Default '')
                $vmState=[string](Get-EpicVMHyperVValue -Object $items[0] -Name 'State' -Default '')
                if($vmState -and $vmState -ine 'Running'){throw 'vm not running'}
            } catch {
                $code=Get-EpicVMPowerShellDirectFailureCode -ErrorRecord $_ -Phase 'resolve' -SessionCreated $false
                throw (New-EpicVMPowerShellDirectFailure -Code $code -Phase 'resolve' -SessionCreated $false -CorrelationId $correlationId -ElapsedMilliseconds ([int]$started.ElapsedMilliseconds))
            }
        }
        $vmGuid=$null
        try{$vmGuid=[Guid]$vmIdValue}catch{throw (New-EpicVMPowerShellDirectFailure -Code 'hyperv_vm_not_found' -Phase 'resolve' -SessionCreated $false -CorrelationId $correlationId -ElapsedMilliseconds ([int]$started.ElapsedMilliseconds))}
        # The host VM-session service is trigger-start and may be idle between
        # sessions. Best-effort start it here, but let New-PSSession remain the
        # authoritative channel-open check.
        $directHostServiceState=Ensure-EpicVMPowerShellDirectHostService
        $phase='open'
        $workerScript={
            param($VmIdArgument,$GuestCredential,$GuestScript,$GuestArguments)
            $ErrorActionPreference='Stop'
            $session=$null
            [ordered]@{epicvmDirectPhase='open'}
            try {
                $session=New-PSSession -VMId ([Guid]$VmIdArgument) -Credential $GuestCredential -ErrorAction Stop
                if($null -eq $session){throw 'EPICVM_POWERSHELL_DIRECT_OPEN_FAILED'}
                [ordered]@{epicvmDirectPhase='execute';sessionCreated=$true}
                try {
                    if(@($GuestArguments).Count -gt 0){$result=Invoke-Command -Session $session -ScriptBlock $GuestScript -ArgumentList @($GuestArguments) -ErrorAction Stop}
                    else{$result=Invoke-Command -Session $session -ScriptBlock $GuestScript -ErrorAction Stop}
                    [ordered]@{epicvmDirectResult=$result}
                } catch {
                    # A guest throw is serialized through the worker runspace and
                    # can lose its original ErrorRecord metadata. Emit only the
                    # allowlisted account marker before rethrowing so the caller
                    # can preserve the concrete guest stage without exposing
                    # credentials or raw remoting text.
                    $guestText=@(
                        [string]$_.Exception.Message,
                        [string]$_.ErrorDetails,
                        [string]$_.FullyQualifiedErrorId
                    ) -join ' '
                    $guestMarker=[regex]::Match($guestText,'(?i)\bguest_account_failed\|([a-z_]+)\b')
                    $allowed=@('account_create_failed','account_update_failed','account_password_policy_failed','admin_membership_failed','account_verification_failed')
                    if($guestMarker.Success -and $allowed -contains $guestMarker.Groups[1].Value.ToLowerInvariant()){
                        [ordered]@{epicvmDirectGuestFailure=('guest_account_failed|' + $guestMarker.Groups[1].Value.ToLowerInvariant())}
                    }
                    throw
                }
            } finally {
                if($null -ne $session){try{Remove-PSSession -Session $session -ErrorAction SilentlyContinue}catch{}}
            }
        }
        $workerPipeline=[System.Management.Automation.PowerShell]::Create()
        [void]$workerPipeline.AddScript($workerScript.ToString())
        [void]$workerPipeline.AddArgument($vmGuid)
        [void]$workerPipeline.AddArgument($Credential)
        [void]$workerPipeline.AddArgument($Script)
        [void]$workerPipeline.AddArgument(@($ArgumentList))
        $workerInput=[System.Management.Automation.PSDataCollection[psobject]]::new()
        $workerOutput=[System.Management.Automation.PSDataCollection[psobject]]::new()
        $workerAsync=$workerPipeline.BeginInvoke($workerInput,$workerOutput)
        if(-not $workerAsync.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds([Math]::Max(1,[int]$TimeoutSeconds)))){
            $observed=@($workerOutput)
            $sessionCreated=@($observed|Where-Object{[bool](Get-EpicVMHyperVValue -Object $_ -Name 'sessionCreated' -Default $false)}).Count -gt 0
            $phase=if($sessionCreated){'execute'}else{'open'}
            $workerPipeline.Stop()
            $code=if($sessionCreated){'direct_transport_error'}else{'direct_open_timeout'}
            throw (New-EpicVMPowerShellDirectFailure -Code $code -Phase $phase -SessionCreated $sessionCreated -CorrelationId $correlationId -ElapsedMilliseconds ([int]$started.ElapsedMilliseconds))
        }
        $phase='collect'
        try{$null=$workerPipeline.EndInvoke($workerAsync)}catch{}
        $observed=@($workerOutput)
        $guestFailureEnvelope=$observed | Where-Object { Test-EpicVMPowerShellDirectRecordKey -Record $_ -Name 'epicvmDirectGuestFailure' } | Select-Object -Last 1
        $guestFailureMarker=[string](Get-EpicVMHyperVValue -Object $guestFailureEnvelope -Name 'epicvmDirectGuestFailure' -Default '')
        if($guestFailureMarker -like 'guest_account_failed|*'){
            $detail=$guestFailureMarker.Substring('guest_account_failed|'.Length)
            if($script:EpicVMGuestFailureDetailCodes -notcontains $detail){$detail='account_verification_failed'}
            throw (New-EpicVMHyperVError -Code 'guest_account_failed' -Message 'The guest account operation failed.' -DetailCode $detail)
        }
        $phaseMarker=$observed|Where-Object{Test-EpicVMPowerShellDirectRecordKey -Record $_ -Name 'epicvmDirectPhase'}|Select-Object -Last 1
        $sessionCreated=[bool](Get-EpicVMHyperVValue -Object $phaseMarker -Name 'sessionCreated' -Default $false)
        if($sessionCreated){$phase='execute'}else{$phase='open'}
        $marker=Get-EpicVMPowerShellDirectSafeMarker -Records @($workerPipeline.Streams.Error)
        if($workerPipeline.HadErrors -or $null -ne $marker){
            if($null -ne $marker -and $marker -like 'guest_account_failed|*'){
                $detail=$marker.Substring('guest_account_failed|'.Length)
                throw (New-EpicVMHyperVError -Code 'guest_account_failed' -Message 'The guest account operation failed.' -DetailCode $detail)
            }
            if($null -ne $marker -and $marker -like 'EPICVM_SUNSHINE_*'){
                throw (New-EpicVMHyperVError -Code (($marker -replace '^EPICVM_','').ToLowerInvariant()) -Message 'Guest streaming setup reported a safe failure.')
            }
            $code=Get-EpicVMPowerShellDirectFailureCode -Records @($workerPipeline.Streams.Error) -Phase $phase -SessionCreated $sessionCreated
            throw (New-EpicVMPowerShellDirectFailure -Code $code -Phase $phase -SessionCreated $sessionCreated -CorrelationId $correlationId -ElapsedMilliseconds ([int]$started.ElapsedMilliseconds))
        }
        $envelope=$observed|Where-Object{Test-EpicVMPowerShellDirectRecordKey -Record $_ -Name 'epicvmDirectResult'}|Select-Object -Last 1
        if($null -eq $envelope){throw (New-EpicVMPowerShellDirectFailure -Code 'direct_transport_error' -Phase $phase -SessionCreated $sessionCreated -CorrelationId $correlationId -ElapsedMilliseconds ([int]$started.ElapsedMilliseconds))}
        return (ConvertTo-EpicVMDirectResult -Result (Get-EpicVMHyperVValue -Object $envelope -Name 'epicvmDirectResult' -Default $null))
    } catch {
        $existingCode=[string](Get-EpicVMHyperVValue -Object $_.Exception -Name 'ErrorCode' -Default '')
        if($existingCode){throw}
            $code=Get-EpicVMPowerShellDirectFailureCode -ErrorRecord $_ -Phase $phase -SessionCreated $sessionCreated
            if($code -notin @('guest_credentials_rejected','hyperv_vm_not_found','hyperv_vm_not_running','hyperv_access_denied') -and
                -not $sessionCreated -and $null -ne $directHostServiceState -and [bool]$directHostServiceState.startFailed){
                $code='direct_service_not_ready'
            }
            throw (New-EpicVMPowerShellDirectFailure -Code $code -Phase $phase -SessionCreated $sessionCreated -CorrelationId $correlationId -ElapsedMilliseconds ([int]$started.ElapsedMilliseconds))
    } finally {
        if($null -ne $workerAsync){try{$workerAsync.AsyncWaitHandle.Dispose()}catch{}}
        if($null -ne $workerPipeline){$workerPipeline.Dispose()}
        if($null -ne $workerInput){try{$workerInput.Complete()}catch{}}
    }
}

function Test-EpicVMPowerShellDirectRecordKey {
    param(
        [AllowNull()][object]$Record,
        [Parameter(Mandatory)][string]$Name
    )
    if($null -eq $Record){return $false}
    if($Record -is [System.Collections.IDictionary]){return $Record.Contains($Name)}
    return $null -ne $Record.PSObject.Properties[$Name]
}

function ConvertTo-EpicVMDirectResult {
    param([AllowNull()][object]$Result)
    $items=@($Result | Where-Object { $null -ne $_ })
    if($items.Count -eq 0){return $null}
    if($items.Count -eq 1){return $items[0]}
    $withOk=@($items | Where-Object { $null -ne $_.PSObject.Properties['ok'] })
    if($withOk.Count -gt 0){return $withOk[-1]}
    return $items[-1]
}

function Get-EpicVMPowerShellDirectJobRecords {
    param(
        [AllowNull()][object]$Job,
        [AllowNull()][object[]]$Additional=@()
    )
    # PSRemotingJob can report only a generic parent reason even when the
    # guest script emitted an allowlisted marker on a child error stream. The
    # records are inspected in memory and never returned or logged verbatim.
    $records=@($Additional)
    if($null -ne $Job){
        foreach($child in @($Job.ChildJobs)){
            $stateInfo=Get-EpicVMHyperVValue -Object $child -Name 'JobStateInfo' -Default $null
            $records += @(Get-EpicVMHyperVValue -Object $stateInfo -Name 'Reason' -Default $null)
            $records += @(Get-EpicVMHyperVValue -Object $child -Name 'Error' -Default @())
            $streams=Get-EpicVMHyperVValue -Object $child -Name 'Streams' -Default $null
            $records += @(Get-EpicVMHyperVValue -Object $streams -Name 'Error' -Default @())
        }
    }
    return @($records | Where-Object { $null -ne $_ })
}

function Invoke-EpicVMPowerShellDirect {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$Script,
        [AllowNull()][object[]]$ArgumentList=@(),
        [int]$TimeoutSeconds=10,
        [int]$RetryCount=1,
        [AllowNull()][string]$VmId=''
    )
    $attempt=0
    while($true){
        try { return Invoke-EpicVMPowerShellDirectOnce -Provider $Provider -VmName $VmName -VmId $VmId -Credential $Credential -Script $Script -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds }
        catch {
            $message=[string]$_.Exception.Message
            $errorCode=[string](Get-EpicVMHyperVValue -Object $_.Exception -Name 'ErrorCode' -Default '')
            $maxRetries=[Math]::Max(0,[int]$RetryCount)
            if($attempt -ge $maxRetries -or ($errorCode -and $errorCode -notin @('direct_open_timeout','direct_transport_error')) -or (!$errorCode -and $message -notmatch '(?i)timeout|timed out|disconnect|connection reset|temporarily unavailable')){throw}
            $attempt++
            Start-Sleep -Milliseconds 250
        }
    }
}

function Invoke-EpicVMManagementTransportOnce {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$Script,
        [AllowNull()][object[]]$ArgumentList=@(),
        [int]$TimeoutSeconds=30,
        [int]$Port=5985,
        [bool]$UseSsl=$false
    )
    if($Address -notmatch '^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|[A-Za-z0-9][A-Za-z0-9.-]{0,252})$'){
        throw 'EPICVM_MANAGEMENT_UNAVAILABLE'
    }
    $invoker=Get-EpicVMHyperVValue -Object $Provider -Name 'ManagementInvoker' -Default $null
    if($null -ne $invoker){
        return (ConvertTo-EpicVMDirectResult -Result (& $invoker $Address $Credential $Script $ArgumentList $TimeoutSeconds $Port $UseSsl))
    }
    $clientBoundary=$null
    try {
        $clientBoundary=Enter-EpicVMManagementClientBoundary
        if(-not $UseSsl){Set-EpicVMManagementTrustedHost -Address $Address}
    }
    catch {
        Exit-EpicVMManagementClientBoundary -Context $clientBoundary
        throw
    }
    $pipeline=$null
    $async=$null
    $transportInput=$null
    $transportOutput=$null
    $stopAsync=$null
    # A timed-out remoting pipeline can block synchronously in Dispose while the
    # remote command is still unwinding. The agent listener is single-threaded,
    # so never let cleanup turn a bounded operation into an unbounded request.
    $disposePipeline=$true
    # The nested guest operation may throw an allowlisted Sunshine marker.
    # Preserve that marker across the WinRM wrapper instead of collapsing the
    # first concrete guest failure into EPICVM_MANAGEMENT_OPERATION_FAILED.
    $safeGuestMarkers=@(
        'EPICVM_SUNSHINE_INVALID_INPUT',
        'EPICVM_SUNSHINE_SERVICE_MISSING',
        'EPICVM_SUNSHINE_EXECUTABLE_MISSING',
        'EPICVM_SUNSHINE_VERSION_MISMATCH',
        'EPICVM_SUNSHINE_STATE_PATH_FAILED',
        'EPICVM_SUNSHINE_STATE_WRITE_FAILED',
        'EPICVM_SUNSHINE_STATE_ACL_FAILED',
        'EPICVM_SUNSHINE_FIREWALL_FAILED',
        'EPICVM_SUNSHINE_SERVICE_RESTART_FAILED',
        'EPICVM_SUNSHINE_LISTENER_FAILED',
        'EPICVM_SUNSHINE_VERIFICATION_FAILED',
        'EPICVM_GAMING_GPU_VALIDATION_FAILED',
        'EPICVM_GAMING_ENCODER_UNAVAILABLE',
        'EPICVM_CAPTURE_INVALID_INPUT',
        'EPICVM_CAPTURE_VDD_INF_MISSING',
        'EPICVM_CAPTURE_VDD_INSTALL_FAILED',
        'EPICVM_CAPTURE_VDD_DEVICE_NOT_OK',
        'EPICVM_CAPTURE_NEFCON_MISSING',
        'EPICVM_CAPTURE_STAGING_FAILED'
    )
    $transportScript={
        param($Target,$GuestCredential,$GuestScript,$GuestArguments,$TargetPort,$Ssl,$SafeMarkers)
        $ErrorActionPreference='Stop'
        $session=$null
        try {
            $newParams=@{ComputerName=$Target;Credential=$GuestCredential;Authentication='Negotiate';ErrorAction='Stop'}
            if([int]$TargetPort -gt 0 -and [int]$TargetPort -ne 5985){$newParams.Port=[int]$TargetPort}
            if([bool]$Ssl){$newParams.UseSSL=$true}
            try{$session=New-PSSession @newParams}catch{
                $message=[string]$_.Exception.Message
                # Only explicit logon/password wording is a credential
                # conclusion. Generic access denial can be WinRM/UAC/endpoint
                # policy and must remain a management transport failure.
                if($message -match '(?i)logon failure|user name or password|credentials? supplied.*not recognized|authentication failed'){throw 'EPICVM_MANAGEMENT_CREDENTIAL_REJECTED'}
                if($message -match '(?i)unauthorized|access is denied'){throw 'EPICVM_MANAGEMENT_OPEN_FAILED'}
                if($message -match '(?i)timed out|timeout'){throw 'EPICVM_MANAGEMENT_OPEN_TIMEOUT'}
                throw 'EPICVM_MANAGEMENT_OPEN_FAILED'
            }
            if($null -eq $session){throw 'EPICVM_MANAGEMENT_OPEN_FAILED'}
            $nestedErrors=@()
            try{
                if(@($GuestArguments).Count -gt 0){$result=Invoke-Command -Session $session -ScriptBlock $GuestScript -ArgumentList $GuestArguments -ErrorAction Stop -ErrorVariable nestedErrors}
                else{$result=Invoke-Command -Session $session -ScriptBlock $GuestScript -ErrorAction Stop -ErrorVariable nestedErrors}
                return [ordered]@{ok=$true;transportOpened=$true;result=$result}
            }catch{
                $remoteParts=@()
                foreach($record in @($_)+@($nestedErrors)){
                    $remoteParts += [string](Get-EpicVMHyperVValue -Object $record -Name 'Message' -Default '')
                    $remoteParts += [string](Get-EpicVMHyperVValue -Object $record -Name 'ErrorDetails' -Default '')
                    $remoteParts += [string](Get-EpicVMHyperVValue -Object $record -Name 'FullyQualifiedErrorId' -Default '')
                    $recordException=Get-EpicVMHyperVValue -Object $record -Name 'Exception' -Default $null
                    for($recordDepth=0;$null -ne $recordException -and $recordDepth -lt 5;$recordDepth++){
                        $remoteParts += [string](Get-EpicVMHyperVValue -Object $recordException -Name 'Message' -Default '')
                        $recordException=Get-EpicVMHyperVValue -Object $recordException -Name 'InnerException' -Default $null
                    }
                }
                $remoteException=Get-EpicVMHyperVValue -Object $_ -Name 'Exception' -Default $null
                for($depth=0;$null -ne $remoteException -and $depth -lt 5;$depth++){
                    $remoteParts += [string](Get-EpicVMHyperVValue -Object $remoteException -Name 'Message' -Default '')
                    $remoteException=Get-EpicVMHyperVValue -Object $remoteException -Name 'InnerException' -Default $null
                }
                $message=$remoteParts -join ' '
                $guestMarker=@($SafeMarkers | Where-Object { $message -match [regex]::Escape([string]$_) } | Select-Object -First 1)
                if($null -ne $guestMarker){return [ordered]@{ok=$false;transportOpened=$true;safeMarker=[string]$guestMarker}}
                if($message -match '(?i)logon failure|user name or password|credentials? supplied.*not recognized|authentication failed'){throw 'EPICVM_MANAGEMENT_CREDENTIAL_REJECTED'}
                if($message -match '(?i)unauthorized|access is denied'){throw 'EPICVM_MANAGEMENT_OPERATION_FAILED'}
                if($message -match '(?i)timed out|timeout'){throw 'EPICVM_MANAGEMENT_OPERATION_TIMEOUT'}
                throw 'EPICVM_MANAGEMENT_OPERATION_FAILED'
            }
        }finally{if($null -ne $session){try{Remove-PSSession -Session $session -ErrorAction SilentlyContinue}catch{}}}
    }
    try{
        $pipeline=[System.Management.Automation.PowerShell]::Create()
        [void]$pipeline.AddCommand('Invoke-Command')
        [void]$pipeline.AddParameter('ScriptBlock',$transportScript)
        [void]$pipeline.AddParameter('ArgumentList',@($Address,$Credential,$Script,$ArgumentList,$Port,$UseSsl,$safeGuestMarkers))
        # Use explicit input/output collections. The parameterless BeginInvoke
        # overload can leave remoting output in an internal collection and make
        # EndInvoke wait forever after the WSMan command itself has completed.
        $transportInput=[System.Management.Automation.PSDataCollection[psobject]]::new()
        $transportOutput=[System.Management.Automation.PSDataCollection[psobject]]::new()
        $async=$pipeline.BeginInvoke($transportInput,$transportOutput)
        $transportInput.Complete()
        if(-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds([Math]::Max(1,$TimeoutSeconds)))){
            # Stop() is synchronous and can reproduce the same remoting hang we
            # are bounding. BeginStop is observed briefly, then the caller gets
            # the explicit timeout even if WSMan cleanup is slow.
            $disposePipeline=$false
            try{
                $stopAsync=$pipeline.BeginStop($null,$null)
                if($null -ne $stopAsync -and $stopAsync.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(2)) -and $stopAsync.IsCompleted){
                    try{
                        $pipeline.EndStop($stopAsync)
                        $disposePipeline=$true
                    }catch{}
                }
            }catch{}
            throw 'EPICVM_MANAGEMENT_OPERATION_TIMEOUT'
        }
        try{
            $endResult=$pipeline.EndInvoke($async)
            $allOutput=@($transportOutput)+@($endResult)
            $envelope=ConvertTo-EpicVMDirectResult -Result $allOutput
        }catch{
            $marker=Get-EpicVMPowerShellDirectSafeMarker -Records @($pipeline.Streams.Error)+@($transportOutput) -ErrorRecord $_
            if($null -ne $marker){throw $marker}
            throw 'EPICVM_MANAGEMENT_OPERATION_FAILED'
        }
        $resultValue=Get-EpicVMHyperVValue -Object $envelope -Name 'result' -Default $null
        $nestedMarker=[string](Get-EpicVMHyperVValue -Object $resultValue -Name 'safeMarker' -Default '')
        $nestedStage=[string](Get-EpicVMHyperVValue -Object $resultValue -Name 'failureDetailCode' -Default '')
        if($nestedMarker -and $safeGuestMarkers -contains $nestedMarker){return (ConvertTo-EpicVMDirectResult -Result $resultValue)}
        if($nestedStage -like 'SUNSHINE_*'){return (ConvertTo-EpicVMDirectResult -Result $resultValue)}
        if($nestedStage -like 'CAPTURE_*'){return (ConvertTo-EpicVMDirectResult -Result $resultValue)}
        if($pipeline.HadErrors){
            $marker=Get-EpicVMPowerShellDirectSafeMarker -Records @($pipeline.Streams.Error)+@($transportOutput)
            if($null -ne $marker){throw $marker}
            throw 'EPICVM_MANAGEMENT_OPERATION_FAILED'
        }
        if($null -eq $envelope -or $null -eq $resultValue){throw 'EPICVM_MANAGEMENT_OPERATION_FAILED'}
        return (ConvertTo-EpicVMDirectResult -Result $resultValue)
    }finally{
        if($null -ne $async){try{$async.AsyncWaitHandle.Dispose()}catch{}}
        if($null -ne $stopAsync){try{$stopAsync.AsyncWaitHandle.Dispose()}catch{}}
        if($null -ne $transportInput){try{$transportInput.Complete()}catch{}}
        if($disposePipeline -and $null -ne $pipeline){$pipeline.Dispose()}
        Exit-EpicVMManagementClientBoundary -Context $clientBoundary
    }
}

function Test-EpicVMManagementPort {
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$Port=5985,
        [int]$TimeoutMilliseconds=2000
    )
    if($Address -notmatch '^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|[A-Za-z0-9][A-Za-z0-9.-]{0,252})$'){return $false}
    $client=[Net.Sockets.TcpClient]::new()
    try {
        $task=$client.ConnectAsync($Address,[int]$Port)
        if(-not $task.Wait([Math]::Max(250,[int]$TimeoutMilliseconds))){return $false}
        return [bool]$client.Connected
    } catch { return $false }
    finally { $client.Dispose() }
}

function Set-EpicVMManagementTrustedHost {
    param([Parameter(Mandatory)][string]$Address)
    if($Address -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$'){
        throw 'EPICVM_MANAGEMENT_UNAVAILABLE'
    }
    try {
        $path='WSMan:\localhost\Client\TrustedHosts'
        $providerAvailable=$false
        $current=''
        try {
            if(Test-Path -Path $path -ErrorAction Stop){
                $providerAvailable=$true
                $current=[string](Get-Item -Path $path -ErrorAction Stop).Value
            }
        } catch { $providerAvailable=$false; $current='' }
        # PowerShell 7 may not load the Windows WSMan provider even though
        # WinRM itself is installed.  The provider and WinRM both consume this
        # machine setting, so use the documented registry-backed value as a
        # narrow fallback instead of broadening TrustedHosts or invoking a
        # shell with secret-bearing arguments.
        $registryPath='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client'
        if(-not $providerAvailable){
            $registryValue=Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
            if($null -ne $registryValue -and $null -ne $registryValue.PSObject.Properties['TrustedHosts']){
                $current=[string]$registryValue.TrustedHosts
            } else {$current=''}
        }
        $entries=@($current -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_})
        if($entries -contains '*'){throw 'EPICVM_MANAGEMENT_TRUSTED_HOSTS_BROAD'}
        if($entries -notcontains $Address){
            $value=(($entries + $Address) -join ',')
            if($providerAvailable){
                Set-Item -Path $path -Value $value -Force -ErrorAction Stop | Out-Null
            } else {
                if(-not (Test-Path -LiteralPath $registryPath)){New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null}
                New-ItemProperty -LiteralPath $registryPath -Name 'TrustedHosts' -PropertyType String -Value $value -Force -ErrorAction Stop | Out-Null
            }
        }
    } catch {
        if([string]$_.Exception.Message -match 'EPICVM_MANAGEMENT_TRUSTED_HOSTS_BROAD'){throw 'EPICVM_MANAGEMENT_TRUSTED_HOSTS_BROAD'}
        throw 'EPICVM_MANAGEMENT_UNAVAILABLE'
    }
}

function New-EpicVMWinRMLocalCredential {
    <#
    WinRM to a Tailscale IP normally has no Kerberos context. For the local
    workgroup account used by EpicVM, an unqualified name can be interpreted
    as a name in the caller's authority and is rejected even when the same
    password works through Hyper-V/PowerShell Direct. Qualify only the
    management copy; the Direct bootstrap credential remains untouched.
    #>
    param([Parameter(Mandatory)][PSCredential]$Credential)
    $username = [string]$Credential.UserName
    if ([string]::IsNullOrWhiteSpace($username) -or $username -match '[\\@]') {
        return $Credential
    }
    return [PSCredential]::new('.\' + $username, $Credential.Password)
}

function Enter-EpicVMManagementClientBoundary {
    # Windows remoting uses the local WinRM service even when this machine is
    # only the outbound client. Keep the service lifecycle bounded and install
    # a persistent inbound block so starting the client cannot expose this PC.
    $service = Get-Service -Name 'WinRM' -ErrorAction Stop
    $wasRunning = ([string]$service.Status -ceq 'Running')
    $ruleName = 'EpicVM-Host-WinRM-Client-Isolation'
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($null -eq $rule) {
        New-NetFirewallRule -Name $ruleName -DisplayName 'EpicVM host WinRM client isolation' -Group 'EpicVM' -Direction Inbound -Action Block -Protocol TCP -LocalPort @('5985','5986') -RemoteAddress 'Any' -Profile Any -EdgeTraversalPolicy Block -ErrorAction Stop | Out-Null
    }
    if (-not $wasRunning) {
        Start-Service -Name 'WinRM' -ErrorAction Stop
        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 250
            $service = Get-Service -Name 'WinRM' -ErrorAction Stop
        } while ([string]$service.Status -ne 'Running' -and (Get-Date) -lt $deadline)
        if ([string]$service.Status -ne 'Running') { throw 'EPICVM_MANAGEMENT_CLIENT_SERVICE_FAILED' }
    }
    return [pscustomobject]@{ WasRunning = $wasRunning; StartedByEpicVM = (-not $wasRunning) }
}

function Exit-EpicVMManagementClientBoundary {
    param([AllowNull()][object]$Context)
    if ($null -eq $Context -or -not [bool](Get-EpicVMHyperVValue -Object $Context -Name 'StartedByEpicVM' -Default $false)) { return }
    try { Stop-Service -Name 'WinRM' -Force -ErrorAction SilentlyContinue } catch { }
}

function Invoke-EpicVMManagementTransport {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$Script,
        [AllowNull()][object[]]$ArgumentList=@(),
        [int]$TimeoutSeconds=30,
        [int]$RetryCount=0
    )
    $port=[int](Get-EpicVMHyperVValue -Object $Provider -Name 'ManagementPort' -Default 5985)
    $useSsl=[bool](Get-EpicVMHyperVValue -Object $Provider -Name 'ManagementUseSsl' -Default $false)
    $attempt=0
    while($true){
        try{return Invoke-EpicVMManagementTransportOnce -Provider $Provider -Address $Address -Credential $Credential -Script $Script -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -Port $port -UseSsl $useSsl}
        catch{
            $message=[string]$_.Exception.Message
            $maxRetries=[Math]::Max(0,[int]$RetryCount)
            if($attempt -ge $maxRetries -or $message -notmatch '(?i)timeout|timed out|temporarily unavailable|connection reset|connection closed'){throw}
            $attempt++; Start-Sleep -Milliseconds 250
        }
    }
}

function Get-EpicVMManagementReadinessScript {
    return {
        $ErrorActionPreference='Stop'
        [ordered]@{ok=$true;managementEndpoint=$true}
    }
}

$script:EpicVMGuestFailureDetailCodes = @(
    'account_create_failed', 'account_update_failed',
    'account_password_policy_failed', 'admin_membership_failed',
    'account_verification_failed'
)

function Get-EpicVMGuestProviderFailure {
    param([AllowNull()][object]$ErrorRecord)

    # Only stable, allowlisted classifications cross the provider boundary.
    # Exception text is inspected in memory and is never returned or logged.
    $exception = Get-EpicVMHyperVValue -Object $ErrorRecord -Name 'Exception' -Default $ErrorRecord
    $message = [string](Get-EpicVMHyperVValue -Object $exception -Name 'Message' -Default $exception)
    $code = [string](Get-EpicVMHyperVValue -Object $exception -Name 'ErrorCode' -Default '')
    $detail = [string](Get-EpicVMHyperVValue -Object $exception -Name 'FailureDetailCode' -Default '')
    if ($script:EpicVMGuestFailureDetailCodes -notcontains $detail) { $detail = $null }
    if ($message -match '(?i)EPICVM_GAMING_ENCODER_UNAVAILABLE') {
        return [pscustomobject]@{ Code = 'gaming_encoder_unavailable'; DetailCode = 'GAMING_GPU_ENCODER' }
    }
    if ($message -match '(?i)EPICVM_GAMING_GPU_VALIDATION_FAILED') {
        return [pscustomobject]@{ Code = 'gaming_gpu_validation_failed'; DetailCode = 'GAMING_GPU_DEVICE_ERROR' }
    }

    $marker = [regex]::Match($message, '(?i)\bguest_account_failed\|([a-z_]+)\b')
    if ($marker.Success -and $script:EpicVMGuestFailureDetailCodes -contains $marker.Groups[1].Value.ToLowerInvariant()) {
        return [pscustomobject]@{ Code = 'guest_account_failed'; DetailCode = $marker.Groups[1].Value.ToLowerInvariant() }
    }
    if ($code -in @('guest_account_failed','rdp_verification_failed','powershell_direct_failed',
            'guest_account_readiness_failed','bootstrap_cleanup_transport_failed','bootstrap_cleanup_failed',
            'management_transport_failed','management_transport_unavailable','management_handoff_failed',
            'hyperv_vm_not_found','hyperv_access_denied','hyperv_vm_not_running','guest_heartbeat_unhealthy',
            'direct_service_disabled','direct_service_not_ready','direct_not_supported','direct_open_timeout',
            'direct_transport_error','guest_credentials_rejected','guest_operation_failed','direct_parameter_failure',
            'direct_module_failure','direct_runtime_failure')) {
        return [pscustomobject]@{ Code = $code; DetailCode = $detail }
    }
    if ($message -match '(?i)EPICVM_POWERSHELL_DIRECT_') {
        return [pscustomobject]@{ Code = 'powershell_direct_failed'; DetailCode = $null }
    }
    if ($message -match '(?i)EPICVM_MANAGEMENT_CREDENTIAL_REJECTED|guest credential rejected') {
        return [pscustomobject]@{ Code = 'guest_credential_rejected'; DetailCode = $null }
    }
    if ($message -match '(?i)EPICVM_MANAGEMENT_') {
        return [pscustomobject]@{ Code = 'management_transport_failed'; DetailCode = $null }
    }
    if ($message -match '(?i)rdp_verification_failed|RDP/NLA/firewall|firewall verification') {
        return [pscustomobject]@{ Code = 'rdp_verification_failed'; DetailCode = $null }
    }
    if ($message -match '(?i)bootstrap_cleanup_transport_failed') {
        return [pscustomobject]@{ Code = 'bootstrap_cleanup_transport_failed'; DetailCode = $null }
    }
    if ($message -match '(?i)bootstrap_cleanup_failed') {
        return [pscustomobject]@{ Code = 'bootstrap_cleanup_failed'; DetailCode = $null }
    }
    if ($message -match '(?i)EPICVM_MANAGEMENT_|management transport|management endpoint') {
        return [pscustomobject]@{ Code = 'management_transport_failed'; DetailCode = $null }
    }
    if ($message -match '(?i)PowerShell Direct|PSRemoting|WinRM|logon failure|access is denied|cannot connect|connection') {
        return [pscustomobject]@{ Code = 'powershell_direct_failed'; DetailCode = $null }
    }
    return [pscustomobject]@{ Code = 'guest_configuration_failed'; DetailCode = $null }
}

function Get-EpicVMGuestProviderErrorCode {
    param([AllowNull()][object]$ErrorRecord)
    return [string](Get-EpicVMGuestProviderFailure -ErrorRecord $ErrorRecord).Code
}

function Get-EpicVMGuestProviderFailureDetailCode {
    param([AllowNull()][object]$ErrorRecord)
    return [string](Get-EpicVMGuestProviderFailure -ErrorRecord $ErrorRecord).DetailCode
}

function Get-EpicVMGuestBootstrapReadinessScript {
    return {
        $ErrorActionPreference='Stop'
        $os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        [ordered]@{ok=$null -ne $os; powershellDirect=$true}
    }
}

function Test-EpicVMGuestBootstrapReady {
    <#
        Returns $true only when PowerShell Direct authenticates with the stored
        bootstrap credential and the guest answers the readiness script.

        A failure is classified, not swallowed. A rejected credential, an unhealthy
        guest, and a slow boot are different operator problems, and collapsing them
        into a bare $false made a template/credential mismatch indistinguishable from
        a normal first boot. The classified code travels back to the caller so the
        job record and the API surface can name the actual cause.

        $Classification may be supplied by the caller to receive the code without
        handling an exception.
    #>
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$VmName,
        [AllowNull()][ref]$Classification
    )
    $credential=$null
    try {
        $loader=Get-EpicVMHyperVValue -Object $Provider -Name 'BootstrapCredentialLoader' -Default $null
        $path=[string](Get-EpicVMHyperVValue -Object $Config -Name 'BootstrapCredentialPath' -Default 'C:\ProgramData\EpicVM\agent\bootstrap.dpapi')
        $user=[string](Get-EpicVMHyperVValue -Object $Config -Name 'BootstrapUser' -Default 'EpicVMBootstrap')
        try {
            $credential=if($null -ne $loader){& $loader $path $user}else{Get-EpicVMBootstrapCredential -Path $path -Username $user}
        } catch {
            # The stored secret itself is unreadable. Never a boot-timing problem.
            if($null -ne $Classification){$Classification.Value='bootstrap_credential_unavailable'}
            return $false
        }
        $result=Invoke-EpicVMPowerShellDirect -Provider $Provider -VmName $VmName -Credential $credential -Script (Get-EpicVMGuestBootstrapReadinessScript)
        $ok=[bool](Get-EpicVMHyperVValue -Object $result -Name 'ok' -Default $false)
        if($null -ne $Classification){$Classification.Value=$(if($ok){'ready'}else{'guest_readiness_script_incomplete'})}
        return $ok
    }
    catch {
        $code=Get-EpicVMPowerShellDirectFailureCode -ErrorRecord $_ -Phase 'open' -SessionCreated $false
        if($null -ne $Classification){$Classification.Value=[string]$code}
        return $false
    }
    finally { $credential=$null }
}

function Wait-EpicVMGuestBootstrapReady {
    <#
        Polls the bootstrap gate until it passes or the window closes. The last
        observed classification is returned in $Classification so the caller can
        report why the guest never became ready, instead of a bare false.
    #>
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$VmName,
        [int]$TimeoutSeconds=180,
        [int]$PollMilliseconds=1000,
        [AllowNull()][ref]$Classification
    )
    $deadline=[DateTime]::UtcNow.AddSeconds([Math]::Max(1,$TimeoutSeconds))
    $last='bootstrap_not_attempted'
    do {
        $probe=$null
        if(Test-EpicVMGuestBootstrapReady -Provider $Provider -Config $Config -VmName $VmName -Classification ([ref]$probe)){
            if($null -ne $Classification){$Classification.Value='ready'}
            return $true
        }
        if(-not [string]::IsNullOrWhiteSpace([string]$probe)){ $last=[string]$probe }
        if([DateTime]::UtcNow -lt $deadline){ Start-Sleep -Milliseconds ([Math]::Max(100,$PollMilliseconds)) }
    } while([DateTime]::UtcNow -lt $deadline)
    if($null -ne $Classification){$Classification.Value=$last}
    return $false
}

function Get-EpicVMGuestConfigurationScript {
    return {
        param($DesiredUser,$DesiredPassword)
        $ErrorActionPreference='Stop'
        if($DesiredUser -notmatch '^[A-Za-z][A-Za-z0-9._-]{2,31}$'){throw 'Invalid desired user.'}
        if([string]::IsNullOrEmpty([string]$DesiredPassword)){throw 'Invalid desired password.'}
        function Get-AccountFailureDetail {
            param([AllowNull()][object]$ErrorRecord,[Parameter(Mandatory)][string]$Default)
            $exception=$ErrorRecord
            if($null -ne $ErrorRecord -and $ErrorRecord.PSObject.Properties.Name -contains 'Exception'){$exception=$ErrorRecord.Exception}
            $id=''; $native=''; $message=''
            if($null -ne $ErrorRecord -and $ErrorRecord.PSObject.Properties.Name -contains 'FullyQualifiedErrorId'){$id=[string]$ErrorRecord.FullyQualifiedErrorId}
            if($null -ne $exception -and $exception.PSObject.Properties.Name -contains 'NativeErrorCode'){$native=[string]$exception.NativeErrorCode}
            if($null -ne $exception -and $exception.PSObject.Properties.Name -contains 'Message'){$message=[string]$exception.Message}
            if($id -match '(?i)password.*(policy|complex|length|history)|passwordpolicy|invalidpassword' -or
                $native -match '^(1325|2245|2246)$' -or
                $message -match '(?i)password\s+(policy|complexity|history|length|requirements)|password does not meet|minimum password|password history'){
                return 'account_password_policy_failed'
            }
            return $Default
        }
        $secure=$null
        try {
            try { $secure=ConvertTo-SecureString $DesiredPassword -AsPlainText -Force }
            catch { throw "guest_account_failed|$(Get-AccountFailureDetail -ErrorRecord $_ -Default 'account_create_failed')" }
            $user=Get-LocalUser -Name $DesiredUser -ErrorAction SilentlyContinue
            if($null -eq $user){
                try { $user=New-LocalUser -Name $DesiredUser -Password $secure -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop }
                catch { throw "guest_account_failed|$(Get-AccountFailureDetail -ErrorRecord $_ -Default 'account_create_failed')" }
            } else {
                try {
                    Set-LocalUser -Name $DesiredUser -Password $secure -AccountNeverExpires -ErrorAction Stop
                    if(-not [bool]$user.Enabled){ Enable-LocalUser -Name $DesiredUser -ErrorAction Stop }
                } catch { throw "guest_account_failed|$(Get-AccountFailureDetail -ErrorRecord $_ -Default 'account_update_failed')" }
            }
            try {
                $user=Get-LocalUser -Name $DesiredUser -ErrorAction Stop
                if(-not [bool]$user.Enabled){ throw 'account disabled' }
                if($null -eq $user.SID){ throw 'account SID unavailable' }
            } catch { throw 'guest_account_failed|account_verification_failed' }
            try {
                $adminSid=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
                $adminGroup=Get-LocalGroup -SID $adminSid -ErrorAction Stop
                $userSid=[string]$user.SID
                $isMember=@(Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop | Where-Object { [string]$_.SID -eq $userSid }).Count -gt 0
                if(-not $isMember){
                    try { Add-LocalGroupMember -Group $adminGroup.Name -Member $userSid -ErrorAction Stop } catch { }
                    $isMember=@(Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop | Where-Object { [string]$_.SID -eq $userSid }).Count -gt 0
                }
                if(-not $isMember){ throw 'administrator membership did not verify' }
            } catch { throw 'guest_account_failed|admin_membership_failed' }
        } finally {
            $secure=$null
            $DesiredPassword=$null
        }
        [ordered]@{ok=$true;stage='guest_account';accountConfigured=$true;adminVerified=$true}
    }
}

function Get-EpicVMGuestRdpConfigurationScript {
    return {
        $ErrorActionPreference='Stop'
        try {
            New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -PropertyType DWord -Value 0 -Force | Out-Null
            New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -PropertyType DWord -Value 1 -Force | Out-Null
            Set-Service -Name TermService -StartupType Automatic
            Start-Service -Name TermService
            Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Disable-NetFirewallRule -ErrorAction SilentlyContinue
            Get-NetFirewallRule -Name 'EpicVM-RDP-Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            New-NetFirewallRule -Name 'EpicVM-RDP-Tailscale' -DisplayName 'EpicVM RDP (Tailscale only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress '100.64.0.0/10' -Profile Any -EdgeTraversalPolicy Block | Out-Null
            $listener=$null
            $listenerDeadline=[DateTime]::UtcNow.AddSeconds(45)
            do {
                $listener=Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
                if($null -ne $listener){break}
                Start-Sleep -Milliseconds 500
            } while([DateTime]::UtcNow -lt $listenerDeadline)
            $rule=Get-NetFirewallRule -Name 'EpicVM-RDP-Tailscale' -ErrorAction SilentlyContinue
            $addressFilter=if($null -ne $rule){Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue}else{$null}
            $nlaOk=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction Stop).UserAuthentication -eq 1
            $portOk=$null -ne $listener
            $expectedScopes=@('100.64.0.0/10','100.64.0.0/255.192.0.0')
            $ruleOk=$null -ne $rule -and [string]$rule.Direction -eq 'Inbound' -and [string]$rule.Action -eq 'Allow' -and $null -ne $addressFilter -and [bool](@($addressFilter.RemoteAddress)|Where-Object { $expectedScopes -contains [string]$_ })
            if(-not $portOk -or -not $ruleOk -or -not $nlaOk){throw 'RDP/NLA/firewall verification failed.'}
        } catch { throw 'rdp_verification_failed' }
        [ordered]@{ok=$true;stage='rdp_setup';listener=$portOk;nla=$nlaOk;firewallScoped=$ruleOk}
    }
}

function Get-EpicVMGuestBootstrapCleanupScript {
    return {
        param($BootstrapUser,$BootstrapCredentialPath,$DesiredUser)
        $ErrorActionPreference='Stop'
        $sameUser = $BootstrapUser -and $BootstrapUser -ceq $DesiredUser
        if(-not $sameUser -and $BootstrapUser){
            Remove-LocalUser -Name $BootstrapUser -ErrorAction SilentlyContinue
            if($BootstrapCredentialPath){Remove-Item -LiteralPath $BootstrapCredentialPath -Force -ErrorAction SilentlyContinue}
        }
        $userGone = $sameUser -or $null -eq (Get-LocalUser -Name $BootstrapUser -ErrorAction SilentlyContinue)
        $pathGone = $sameUser -or [string]::IsNullOrWhiteSpace([string]$BootstrapCredentialPath) -or -not (Test-Path -LiteralPath $BootstrapCredentialPath -PathType Leaf)
        [ordered]@{ok=($userGone -and $pathGone);bootstrapRemoved=($userGone -and $pathGone)}
    }
}

function Get-EpicVMGuestDesiredCredentialReadinessScript {
    return {
        $ErrorActionPreference='Stop'
        $os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        [ordered]@{ok=($null -ne $os -and $null -ne $identity);stage='guest_account_readiness'}
    }
}

function Invoke-EpicVMGuestConfiguration {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$DesiredUser,
        [Parameter(Mandatory)][string]$DesiredPassword
    )
    $loader=Get-EpicVMHyperVValue -Object $Provider -Name 'BootstrapCredentialLoader' -Default $null
    $path=[string](Get-EpicVMHyperVValue -Object $Config -Name 'BootstrapCredentialPath' -Default 'C:\ProgramData\EpicVM\agent\bootstrap.dpapi')
    $user=[string](Get-EpicVMHyperVValue -Object $Config -Name 'BootstrapUser' -Default 'EpicVMBootstrap')
    try {
        $credential=if($null -ne $loader){& $loader $path $user}else{Get-EpicVMBootstrapCredential -Path $path -Username $user}
    } catch {
        throw (New-EpicVMHyperVError -Code 'bootstrap_credential_unavailable' -Message 'The machine bootstrap credential could not open the guest channel.')
    }
    $accountScript=Get-EpicVMGuestConfigurationScript
    $rdpScript=Get-EpicVMGuestRdpConfigurationScript
    $cleanupCredential=$null
    $cleanupPassword=$null
    try {
        # Phase 1: create/update the requested account and verify local SID
        # membership. No RDP mutation is attempted before this succeeds.
        # Account creation/update is a guest write. Give Windows enough time
        # to apply local policy, but never replay it after an ambiguous
        # transport timeout.
        $accountResult=Invoke-EpicVMPowerShellDirect -Provider $Provider -VmName $VmName -Credential $credential -Script $accountScript -ArgumentList @($DesiredUser,$DesiredPassword) -TimeoutSeconds 45 -RetryCount 0
        $accountOk=[bool](Get-EpicVMHyperVValue -Object $accountResult -Name 'ok' -Default $false)
        $accountConfigured=[bool](Get-EpicVMHyperVValue -Object $accountResult -Name 'accountConfigured' -Default $false)
        $adminVerified=[bool](Get-EpicVMHyperVValue -Object $accountResult -Name 'adminVerified' -Default $false)
        if(-not $accountOk -or -not $accountConfigured -or -not $adminVerified){
            $detail=[string](Get-EpicVMHyperVValue -Object $accountResult -Name 'failureDetailCode' -Default 'account_verification_failed')
            if($script:EpicVMGuestFailureDetailCodes -notcontains $detail){$detail='account_verification_failed'}
            throw (New-EpicVMHyperVError -Code 'guest_account_failed' -Message 'The guest account setup did not verify.' -DetailCode $detail)
        }

        if($user -and $user -cne $DesiredUser){
            $cleanupPassword=ConvertTo-SecureString $DesiredPassword -AsPlainText -Force
            $cleanupCredential=[PSCredential]::new($DesiredUser,$cleanupPassword)
            $readiness=$null
            $readinessDeadline=[DateTime]::UtcNow.AddSeconds(30)
            do {
                try { $readiness=Invoke-EpicVMPowerShellDirect -Provider $Provider -VmName $VmName -Credential $cleanupCredential -Script (Get-EpicVMGuestDesiredCredentialReadinessScript) } catch { $readiness=$null }
                if([bool](Get-EpicVMHyperVValue -Object $readiness -Name 'ok' -Default $false)){ break }
                if([DateTime]::UtcNow -lt $readinessDeadline){ Start-Sleep -Milliseconds 500 }
            } while([DateTime]::UtcNow -lt $readinessDeadline)
            if(-not [bool](Get-EpicVMHyperVValue -Object $readiness -Name 'ok' -Default $false)){
                throw (New-EpicVMHyperVError -Code 'guest_account_failed' -Message 'The desired guest account did not pass readiness verification.' -DetailCode 'account_verification_failed')
            }

            # Phase 2: only an authenticated desired-account session may
            # configure RDP/NLA/firewall and perform bootstrap cleanup.
            # RDP/NLA/firewall setup includes a bounded listener wait and is a
            # write; do not blindly repeat it if the caller stops waiting.
            $rdpResult=Invoke-EpicVMPowerShellDirect -Provider $Provider -VmName $VmName -Credential $cleanupCredential -Script $rdpScript -TimeoutSeconds 60 -RetryCount 0
            $safe=@{
                ok=[bool](Get-EpicVMHyperVValue -Object $rdpResult -Name 'ok' -Default $false)
                listener=[bool](Get-EpicVMHyperVValue -Object $rdpResult -Name 'listener' -Default $false)
                firewallScoped=[bool](Get-EpicVMHyperVValue -Object $rdpResult -Name 'firewallScoped' -Default $false)
                bootstrapRemoved=$false
                accountConfigured=$accountConfigured
                adminVerified=$adminVerified
            }
            if(-not $safe.ok -or -not $safe.listener -or -not $safe.firewallScoped){throw (New-EpicVMHyperVError -Code 'rdp_verification_failed' -Message 'Guest RDP/NLA/firewall verification failed.')}
            try { $cleanup=Invoke-EpicVMPowerShellDirect -Provider $Provider -VmName $VmName -Credential $cleanupCredential -Script (Get-EpicVMGuestBootstrapCleanupScript) -ArgumentList @($user,$path,$DesiredUser) -TimeoutSeconds 30 -RetryCount 0 }
            catch { throw (New-EpicVMHyperVError -Code 'bootstrap_cleanup_transport_failed' -Message 'The guest bootstrap cleanup channel failed.') }
            if(-not [bool](Get-EpicVMHyperVValue -Object $cleanup -Name 'ok' -Default $false) -or -not [bool](Get-EpicVMHyperVValue -Object $cleanup -Name 'bootstrapRemoved' -Default $false)){
                throw (New-EpicVMHyperVError -Code 'bootstrap_cleanup_failed' -Message 'The guest bootstrap cleanup did not verify.')
            }
            $safe.bootstrapRemoved=$true
        } else {
            # Same-user bootstrap is intentionally retained; the account is
            # already the authenticated owner of the session.
            $rdpResult=Invoke-EpicVMPowerShellDirect -Provider $Provider -VmName $VmName -Credential $credential -Script $rdpScript -TimeoutSeconds 60 -RetryCount 0
            $safe=@{ok=[bool](Get-EpicVMHyperVValue -Object $rdpResult -Name 'ok' -Default $false);listener=[bool](Get-EpicVMHyperVValue -Object $rdpResult -Name 'listener' -Default $false);firewallScoped=[bool](Get-EpicVMHyperVValue -Object $rdpResult -Name 'firewallScoped' -Default $false);bootstrapRemoved=$true;accountConfigured=$accountConfigured;adminVerified=$adminVerified}
            if(-not $safe.ok -or -not $safe.listener -or -not $safe.firewallScoped){throw (New-EpicVMHyperVError -Code 'rdp_verification_failed' -Message 'Guest RDP/NLA/firewall verification failed.')}
        }
        $safe.stage='guest_setup'
        return $safe
    } catch {
        $failure=Get-EpicVMGuestProviderFailure -ErrorRecord $_
        throw (New-EpicVMHyperVError -Code ([string]$failure.Code) -Message 'The guest configuration gate failed.' -DetailCode ([string]$failure.DetailCode))
    }
    finally {$DesiredPassword=$null;$credential=$null;$cleanupCredential=$null;$cleanupPassword=$null}
}

function Get-EpicVMSunshineConfigurationScript {
    param([bool]$ForGaming)
    if ($ForGaming) { return (Get-EpicVMGamingSunshineCaptureScript) }
    return {
        param($SunshineUsername,$SunshinePassword,$ServiceName,$ExpectedVersion,$StatePaths)
        $ErrorActionPreference='Stop'
        function Set-EpicVMSunshineStage {
            param([Parameter(Mandatory)][string]$Stage)
            return $Stage
        }
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_INPUT_VALIDATION'
        try {
        if([string]::IsNullOrWhiteSpace([string]$SunshineUsername) -or [string]$SunshineUsername -match '[\r\n]' -or ([string]$SunshineUsername).Length -gt 128){throw 'EPICVM_SUNSHINE_INVALID_INPUT'}
        if([string]::IsNullOrEmpty([string]$SunshinePassword)){throw 'EPICVM_SUNSHINE_INVALID_INPUT'}
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_SERVICE_CIM_QUERY'
        $service=Get-CimInstance Win32_Service -Filter ("Name='" + ([string]$ServiceName).Replace("'","''") + "'") -ErrorAction SilentlyContinue
        if($null -eq $service){throw 'EPICVM_SUNSHINE_SERVICE_MISSING'}
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_EXECUTABLE_RESOLVE'
        $servicePath=[string]$service.PathName
        if($servicePath -match '^"([^"]+)"'){$servicePath=$Matches[1]}
        elseif($servicePath -match '^([^ ]+)'){$servicePath=$Matches[1]}
        if([string]::IsNullOrWhiteSpace($servicePath) -or -not (Test-Path -LiteralPath $servicePath -PathType Leaf)){throw 'EPICVM_SUNSHINE_EXECUTABLE_MISSING'}
        $serviceDirectory=Split-Path -Parent $servicePath
        # Sunshine's service command differs across installer revisions: some
        # point directly at sunshine.exe while others use a helper under
        # tools\. Check the service binary first, then only the two managed
        # install layouts; never search arbitrary paths.
        $mainSunshinePath=@(
            $servicePath,
            (Join-Path $serviceDirectory 'sunshine.exe'),
            (Join-Path (Split-Path -Parent $serviceDirectory) 'sunshine.exe')
        ) | Where-Object { (Test-Path -LiteralPath ([string]$_) -PathType Leaf) -and ([IO.Path]::GetFileName([string]$_) -ieq 'sunshine.exe') } | Select-Object -First 1
        if([string]::IsNullOrWhiteSpace([string]$mainSunshinePath)){throw 'EPICVM_SUNSHINE_EXECUTABLE_MISSING'}
        $mainSunshinePath=[string]$mainSunshinePath
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_VERSION_VERIFY'
        $installedVersion=[string]([Diagnostics.FileVersionInfo]::GetVersionInfo($mainSunshinePath).ProductVersion)
        if(-not [string]::IsNullOrWhiteSpace([string]$ExpectedVersion) -and $installedVersion -cne [string]$ExpectedVersion){throw 'EPICVM_SUNSHINE_VERSION_MISMATCH'}
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_STATE_PATH'
        $paths=@($StatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $sunshineRoot=Split-Path -Parent $serviceDirectory
        $derivedConfig=Join-Path $sunshineRoot 'config'
        $derivedState=Join-Path $derivedConfig 'sunshine_state.json'
        $configCandidates=@(
            (Join-Path $derivedConfig 'sunshine.conf'),
            (Join-Path (Join-Path $env:ProgramData 'Sunshine') 'config\sunshine.conf'),
            (Join-Path $env:ProgramData 'Sunshine\sunshine.conf')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        $configuredState=$null
        foreach($configPath in $configCandidates){
            foreach($line in @(Get-Content -LiteralPath $configPath -ErrorAction SilentlyContinue)){
                if($line -match '^\s*(?:credentials_file|file_state)\s*=\s*(.*?)\s*$'){
                    $candidate=[string]$Matches[1].Trim().Trim('"')
                    if([string]::IsNullOrWhiteSpace($candidate)){continue}
                    if(-not [IO.Path]::IsPathRooted($candidate)){$candidate=Join-Path (Split-Path -Parent $configPath) $candidate}
                    $configuredState=$candidate
                }
            }
        }
        $stateCandidates=@()
        if($configuredState){$stateCandidates += $configuredState}
        $stateCandidates += $derivedState
        $stateCandidates += @($paths)
        $stateCandidates += (Join-Path (Join-Path $env:ProgramData 'Sunshine') 'config\sunshine_state.json')
        $statePath=@($stateCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Where-Object {
            $parentPath=Split-Path -Parent ([string]$_)
            (Test-Path -LiteralPath ([string]$_) -PathType Leaf) -or (Test-Path -LiteralPath $parentPath -PathType Container)
        } | Select-Object -First 1)
        if($statePath.Count -eq 0){
            $statePath=@($derivedState)
        }
        $statePath=[string]$statePath[0]
        $parent=Split-Path -Parent $statePath
        try { if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null} } catch { throw 'EPICVM_SUNSHINE_STATE_PATH_FAILED' }

        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_STATE_WRITE'
        # Sunshine's supported state format is username + random salt +
        # SHA-256(UTF-8(password + salt)).  The clear password exists only in
        # this remoting process and is never passed to an executable.
        $saltBytes=New-Object byte[] 16
        $hashBytes=$null
        $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try{
            $rng.GetBytes($saltBytes)
            $salt=([BitConverter]::ToString($saltBytes)-replace '-','').ToLowerInvariant()
            $hashBytes=[Text.Encoding]::UTF8.GetBytes(([string]$SunshinePassword)+$salt)
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$digest=$sha.ComputeHash($hashBytes)}finally{$sha.Dispose()}
            [Array]::Reverse($digest)
            $passwordHash=([BitConverter]::ToString($digest)-replace '-','').ToUpperInvariant()
            $record=[ordered]@{username=[string]$SunshineUsername;salt=$salt;password=$passwordHash}
            $json=$record|ConvertTo-Json -Depth 4 -Compress
            $temporary=Join-Path $parent ('.sunshine_state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try{
                [IO.File]::WriteAllText($temporary,$json,(New-Object Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $temporary -Destination $statePath -Force -ErrorAction Stop
            } catch { throw 'EPICVM_SUNSHINE_STATE_WRITE_FAILED' }
            finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
        }finally{
            if($null -ne $hashBytes){[Array]::Clear($hashBytes,0,$hashBytes.Length)}
            if($null -ne $saltBytes){[Array]::Clear($saltBytes,0,$saltBytes.Length)}
            if($null -ne $rng){$rng.Dispose()}
            $SunshinePassword=$null;$json=$null;$passwordHash=$null;$digest=$null;$salt=$null
        }

        try{
            $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_STATE_ACL'
            $acl=Get-Acl -LiteralPath $statePath
            $acl.SetAccessRuleProtection($true,$false)
            @($acl.Access)|ForEach-Object{[void]$acl.RemoveAccessRule($_)}
            # Sunshine owns this credential state and must be able to update it
            # during startup/session handling. Read-only ACLs make the service
            # report "Couldn't write sunshine_state.json" after a reboot.
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('SYSTEM','Modify','Allow'))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Administrators','Read','Allow'))
            $serviceAccount=[string]$service.StartName
            if($serviceAccount -ieq 'LocalService'){$serviceAccount='NT AUTHORITY\LocalService'}
            elseif($serviceAccount -ieq 'NetworkService'){$serviceAccount='NT AUTHORITY\NetworkService'}
            if($serviceAccount -and $serviceAccount -notin @('LocalSystem','NT AUTHORITY\LocalSystem') -and $serviceAccount -match '^(NT SERVICE\\|NT AUTHORITY\\(LocalService|NetworkService)$|[A-Za-z0-9_.-]+\\)'){
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($serviceAccount,'Modify','Allow'))
            }
            Set-Acl -LiteralPath $statePath -AclObject $acl
        } catch { throw 'EPICVM_SUNSHINE_STATE_ACL_FAILED' }
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_FIREWALL_CONFIG'
        try{
            Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -match '(?i)Sunshine' } | Disable-NetFirewallRule -ErrorAction SilentlyContinue
            Get-NetFirewallRule -Name 'EpicVM-Sunshine-Tailscale-TCP','EpicVM-Sunshine-Tailscale-UDP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            New-NetFirewallRule -Name 'EpicVM-Sunshine-Tailscale-TCP' -DisplayName 'EpicVM Sunshine (Tailscale TCP)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47984,47989,47990,48010 -RemoteAddress '100.64.0.0/10' -Profile Any -EdgeTraversalPolicy Block | Out-Null
            New-NetFirewallRule -Name 'EpicVM-Sunshine-Tailscale-UDP' -DisplayName 'EpicVM Sunshine (Tailscale UDP)' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 47998,47999,48000,48002 -RemoteAddress '100.64.0.0/10' -Profile Any -EdgeTraversalPolicy Block | Out-Null
        } catch { throw 'EPICVM_SUNSHINE_FIREWALL_FAILED' }
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_SERVICE_RESTART'
        try { Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop; Restart-Service -Name $ServiceName -Force -ErrorAction Stop } catch { throw 'EPICVM_SUNSHINE_SERVICE_RESTART_FAILED' }
        $sunshineStage=Set-EpicVMSunshineStage 'SUNSHINE_LISTENER_VERIFY'
        $deadline=[DateTime]::UtcNow.AddSeconds(45)
        $running=$false;$listener=$false
        while([DateTime]::UtcNow -lt $deadline){
            $current=Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            $running=$null -ne $current -and [string]$current.Status -eq 'Running'
            $listener=$null -ne (Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue)
            if($running -and $listener){break}
            Start-Sleep -Milliseconds 500
        }
        if(-not $running -or -not $listener){throw 'EPICVM_SUNSHINE_LISTENER_FAILED'}
        [ordered]@{ok=$true;serviceRunning=$true;listener=$true;credentialsConfigured=$true;firewallScoped=$true}
        } catch {
            $safeMarkers=@(
                'EPICVM_SUNSHINE_INVALID_INPUT',
                'EPICVM_SUNSHINE_SERVICE_MISSING',
                'EPICVM_SUNSHINE_EXECUTABLE_MISSING',
                'EPICVM_SUNSHINE_VERSION_MISMATCH',
                'EPICVM_SUNSHINE_STATE_PATH_FAILED',
                'EPICVM_SUNSHINE_STATE_WRITE_FAILED',
                'EPICVM_SUNSHINE_STATE_ACL_FAILED',
                'EPICVM_SUNSHINE_FIREWALL_FAILED',
                'EPICVM_SUNSHINE_SERVICE_RESTART_FAILED',
                'EPICVM_SUNSHINE_LISTENER_FAILED',
                'EPICVM_CAPTURE_INVALID_INPUT','EPICVM_CAPTURE_VDD_INF_MISSING',
                'EPICVM_CAPTURE_VDD_INSTALL_FAILED','EPICVM_CAPTURE_VDD_DEVICE_NOT_OK',
                'EPICVM_CAPTURE_NEFCON_MISSING',
                'EPICVM_SUNSHINE_VERIFICATION_FAILED'
            )
            $message=@([string](Get-EpicVMHyperVValue -Object $_.Exception -Name 'Message' -Default ''),[string]$_.ToString()) -join ' '
            $reportedMarker=$null
            foreach($candidate in $safeMarkers){if($message -match [regex]::Escape($candidate)){$reportedMarker=$candidate;break}}
            [ordered]@{ok=$false;failureDetailCode=$sunshineStage;safeMarker=$reportedMarker}
        }
    }
}

function Get-EpicVMGamingCaptureStageScript {
    # Guest-side staging for the gaming capture artifacts. Each call writes
    # one chunk file plus a manifest entry; when all parts of an artifact are
    # present the reassembled archive is verified by length. Idempotent:
    # rewriting any part replaces it atomically (write-then-rename).
    return {
        param($ArtifactName,$TotalParts,$PartIndex,$TotalBase64Length,$Chunk)
        $ErrorActionPreference='Stop'
        $stageRoot=Join-Path $env:ProgramData 'EpicVM\capture'
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        $partsDir=Join-Path $stageRoot (Join-Path ([string]$ArtifactName) 'parts')
        New-Item -ItemType Directory -Path $partsDir -Force | Out-Null
        if([string]::IsNullOrEmpty([string]$Chunk)){throw 'EPICVM_CAPTURE_STAGING_FAILED'}
        $tmp=Join-Path $partsDir ("part-{0}.tmp" -f $PartIndex)
        $final=Join-Path $partsDir ("part-{0}.b64" -f $PartIndex)
        [IO.File]::WriteAllText($tmp,[string]$Chunk,[Text.Encoding]::ASCII)
        Move-Item -LiteralPath $tmp -Destination $final -Force
        $present=@(Get-ChildItem -LiteralPath $partsDir -Filter 'part-*.b64' -ErrorAction SilentlyContinue)
        if($present.Count -lt [int]$TotalParts){
            return [ordered]@{ok=$true;artifact=[string]$ArtifactName;received=$present.Count;of=[int]$TotalParts;complete=$false}
        }
        # All parts present: verify combined length, then assemble.
        $combined=-join ($present | Sort-Object { [int]($_.BaseName -replace 'part-','') } | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
        if($combined.Length -ne [int]$TotalBase64Length){throw 'EPICVM_CAPTURE_STAGING_FAILED'}
        $zipPath=Join-Path $stageRoot ([string]$ArtifactName + '.zip')
        $zipTmp=Join-Path $stageRoot ([string]$ArtifactName + '.zip.tmp')
        [IO.File]::WriteAllBytes($zipTmp,[Convert]::FromBase64String($combined))
        Move-Item -LiteralPath $zipTmp -Destination $zipPath -Force
        foreach($p in $present){Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue}
        return [ordered]@{ok=$true;artifact=[string]$ArtifactName;complete=$true;bytes=((Get-Item -LiteralPath $zipPath).Length)}
    }
}

function Get-EpicVMGamingSunshineCaptureScript {
    # Gaming guests run headless: GPU-P exposes no active console monitor, so
    # Sunshine has no display to capture and streams black frames. This script
    # installs the cached Virtual Display Driver (nefcon), pins an
    # IddSampleDriver-style output_name so Sunshine captures that virtual
    # monitor, configures Windows auto-logon for the provisioned guest user so
    # a real desktop session exists, and verifies the resulting state. It runs
    # inside the guest via the management transport with elevated rights.
    return {
        param($SunshineUsername,$SunshinePassword,$ServiceName,$ExpectedVersion,$StatePaths,
              $GuestUsername,$GuestPassword)
        $ErrorActionPreference='Stop'
        function Set-EpicVMGamingCaptureStage { param([Parameter(Mandatory)][string]$Stage) return $Stage }
        $captureStage=Set-EpicVMGamingCaptureStage 'CAPTURE_INPUT_VALIDATION'
        try {
        if([string]::IsNullOrWhiteSpace([string]$SunshineUsername) -or [string]::IsNullOrEmpty([string]$SunshinePassword)){throw 'EPICVM_CAPTURE_INVALID_INPUT'}
        if([string]::IsNullOrWhiteSpace([string]$GuestUsername) -or [string]::IsNullOrEmpty([string]$GuestPassword)){throw 'EPICVM_CAPTURE_INVALID_INPUT'}

        $captureStage=Set-EpicVMGamingCaptureStage 'CAPTURE_STAGING'
        $stageRoot=Join-Path $env:ProgramData 'EpicVM\capture'
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        $vddZip=Join-Path $stageRoot 'vdd.zip'
        $nefconZip=Join-Path $stageRoot 'nefcon.zip'
        if(-not (Test-Path -LiteralPath $vddZip -PathType Leaf)){throw 'EPICVM_CAPTURE_STAGING_FAILED'}
        if(-not (Test-Path -LiteralPath $nefconZip -PathType Leaf)){throw 'EPICVM_CAPTURE_STAGING_FAILED'}

        $captureStage=Set-EpicVMGamingCaptureStage 'CAPTURE_VDD_INSTALL'
        Expand-Archive -LiteralPath $vddZip -DestinationPath (Join-Path $stageRoot 'vdd') -Force
        $vddInf=@(Get-ChildItem -LiteralPath (Join-Path $stageRoot 'vdd') -Recurse -Filter '*.inf' | Select-Object -First 1)
        if($vddInf.Count -eq 0){throw 'EPICVM_CAPTURE_VDD_INF_MISSING'}
        $nefconHome=Join-Path $stageRoot 'nefcon'
        Expand-Archive -LiteralPath $nefconZip -DestinationPath $nefconHome -Force
        # The VDD catalog is signed by SignPath Foundation; a fresh guest does
        # not yet trust that publisher, and pnputil rejects the package until
        # it does. Import the signing cert into LocalMachine trust first
        # (idempotent), then install through pnputil, which both stages the
        # package in the driver store and binds it to the device node.
        $vddCatalog=@(Get-ChildItem -LiteralPath (Join-Path $stageRoot 'vdd') -Recurse -Filter '*.cat' | Select-Object -First 1)
        if($vddCatalog.Count -gt 0){
            $signature=Get-AuthenticodeSignature -LiteralPath $vddCatalog[0].FullName
            if($null -ne $signature -and $null -ne $signature.SignerCertificate){
                foreach($storeName in @('TrustedPublisher','TrustedPeople')){
                    try{
                        $store=[Security.Cryptography.X509Certificates.X509Store]::new($storeName,'LocalMachine')
                        $store.Open('ReadWrite')
                        try{ $store.Add($signature.SignerCertificate) } finally { $store.Close() }
                    }catch{}
                }
            }
        }
        # Create the ROOT device node first so pnputil binds the driver to a
        # persistent virtual display instead of waiting for a hardware match.
        $nefconc=@(Get-ChildItem -LiteralPath $nefconHome -Recurse -Filter 'nefconc.exe' | Where-Object { $_.DirectoryName -match 'x64' } | Select-Object -First 1)
        if($nefconc.Count -eq 0){$nefconc=@(Get-ChildItem -LiteralPath $nefconHome -Recurse -Filter 'nefconc.exe' | Select-Object -First 1)}
        $existingVdd=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -like 'ROOT\MTTVDD*' -or ($_.InstanceId -like 'ROOT\DISPLAY\*' -and $_.FriendlyName -match 'Virtual Display')
        })
        if($nefconc.Count -gt 0 -and $existingVdd.Count -eq 0){
            & $nefconc[0].FullName --create-device-node --hardware-id 'Root\MttVDD' --class-name Display --class-guid '{4d36e968-e325-11ce-bfc1-08002be10318}' 2>&1 | Out-Null
        }
        $pnputilExit=-1
        try {
            $pnputilOutput=& pnputil.exe /add-driver "$($vddInf[0].FullName)" /install 2>&1
            $pnputilExit=$LASTEXITCODE
        } catch { $pnputilExit=-1 }
        if($pnputilExit -ne 0){
            # Legacy fallback: nefconw GUI-subsystem binary. Its exit code is
            # unreliable, so only accept success if the PnP device settles.
            $nefconw=@(Get-ChildItem -LiteralPath $nefconHome -Recurse -Filter 'nefconw.exe' | Where-Object { $_.DirectoryName -match 'x64' } | Select-Object -First 1)
            if($nefconw.Count -eq 0){$nefconw=@(Get-ChildItem -LiteralPath $nefconHome -Recurse -Filter 'nefconw.exe' | Select-Object -First 1)}
            if($nefconw.Count -gt 0){
                & $nefconw[0].FullName create 'Root\MttVDD' --inf-path $vddInf[0].FullName 2>&1 | Out-Null
                if($LASTEXITCODE -ne 0){
                    & $nefconw[0].FullName update 'Root\MttVDD' --inf-path $vddInf[0].FullName 2>&1 | Out-Null
                }
            }
        }
        # Wait for the PnP device to settle in an OK state.
        $vddDeadline=[DateTime]::UtcNow.AddSeconds(60)
        do {
            $vddDevice=Get-PnpDevice -FriendlyName '*Virtual Display*' -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -like 'ROOT\MttVDD*' } | Select-Object -First 1
            if($null -eq $vddDevice){
                $vddDevice=Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { ($_.InstanceId -like 'ROOT\MttVDD*') -or ($_.InstanceId -eq 'ROOT\DISPLAY\0000' -and $_.FriendlyName -match 'Virtual Display') } | Select-Object -First 1
            }
            if($null -ne $vddDevice -and [string]$vddDevice.Status -ieq 'OK'){ $deviceOk=$true; break }
            Start-Sleep -Milliseconds 500
        } while([DateTime]::UtcNow -lt $vddDeadline)
        if(-not $deviceOk){ throw 'EPICVM_CAPTURE_VDD_DEVICE_NOT_OK' }

        # Sunshine must capture the virtual output by device ID; otherwise it falls
        # back to whatever default output exists and can pick a black target.
        $captureStage=Set-EpicVMGamingCaptureStage 'CAPTURE_SUNSHINE_CONF'
        $sunshineServiceCim=Get-CimInstance Win32_Service -Filter ("Name='" + ([string]$ServiceName).Replace("'","''") + "'") -ErrorAction SilentlyContinue
        if($null -eq $sunshineServiceCim){throw 'EPICVM_SUNSHINE_SERVICE_MISSING'}
        $servicePath=[string]$sunshineServiceCim.PathName
        if($servicePath -match '^"([^"]+)"'){$servicePath=$Matches[1]}elseif($servicePath -match '^([^ ]+)'){$servicePath=$Matches[1]}
        $serviceDirectory=Split-Path -Parent $servicePath
        $mainExe=Join-Path (Split-Path -Parent $serviceDirectory) 'sunshine.exe'
        if(-not (Test-Path -LiteralPath $mainExe -PathType Leaf)){
            $mainExe=Join-Path $serviceDirectory 'sunshine.exe'
            if(-not (Test-Path -LiteralPath $mainExe -PathType Leaf)){throw 'EPICVM_SUNSHINE_EXECUTABLE_MISSING'}
        }
        $installedVersion=[string]([Diagnostics.FileVersionInfo]::GetVersionInfo($mainExe).ProductVersion)
        if(-not [string]::IsNullOrWhiteSpace([string]$ExpectedVersion) -and $installedVersion -cne [string]$ExpectedVersion){throw 'EPICVM_SUNSHINE_VERSION_MISMATCH'}
        $sunshineRoot=Split-Path -Parent $serviceDirectory
        $configDir=Join-Path $sunshineRoot 'config'
        if(-not (Test-Path -LiteralPath $configDir)){New-Item -ItemType Directory -Path $configDir -Force | Out-Null}
        $confPath=Join-Path $configDir 'sunshine.conf'
        # Sunshine identifies Windows outputs by device GUID, not their
        # friendly label. Refresh its enumeration after installing the VDD.
        Set-Content -LiteralPath $confPath -Value @('capture = ddx','encoder = amdvce','min_log_level = 2') -Encoding ASCII
        $logPath=Join-Path $configDir 'sunshine.log'
        $enumerationStarted=[DateTime]::UtcNow
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
        $displayId=''
        $enumerationDeadline=[DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 500
            if(-not (Test-Path -LiteralPath $logPath)){continue}
            if((Get-Item -LiteralPath $logPath).LastWriteTimeUtc -lt $enumerationStarted){continue}
            $lists=[regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'(?s)Currently available display devices:\s*(\[.*?\r?\n\])')
            if($lists.Count -eq 0){continue}
            try {
                # Windows PowerShell 5.1 emits the JSON array as one pipeline
                # item. Assign it directly to avoid an extra nested array.
                $displays=$lists[$lists.Count-1].Groups[1].Value|ConvertFrom-Json
                $targets=@($displays|Where-Object {[string]$_.friendly_name -eq 'VDD by MTT'})
                # Older retries could create duplicate VDD nodes. Reuse the
                # primary virtual output, with a stable ID ordering fallback.
                $target=$targets | Sort-Object @{Expression={[bool]$_.info.primary};Descending=$true},device_id | Select-Object -First 1
                if($null -ne $target -and [string]$target.device_id -match '^\{[0-9a-f-]{36}\}$'){$displayId=[string]$target.device_id}
            }catch{}
        }while(-not $displayId -and [DateTime]::UtcNow -lt $enumerationDeadline)
        if(-not $displayId){throw 'EPICVM_CAPTURE_DISPLAY_NOT_FOUND'}
        $confLines=@(
            ('output_name = ' + $displayId),
            'capture = ddx',
            'encoder = amdvce',
            'dd_configuration_option = ensure_primary',
            'dd_resolution_option = manual',
            'dd_manual_resolution = 1920x1080',
            'dd_refresh_rate_option = manual',
            'dd_manual_refresh_rate = 60',
            'min_log_level = 2'
        )
        Set-Content -LiteralPath $confPath -Value $confLines -Encoding ASCII

        $captureStage=Set-EpicVMGamingCaptureStage 'CAPTURE_CREDENTIALS_AND_LOGON'
        # Reuse the proven credential-state write from the standard flow.
        $stateCandidates=@()
        foreach($configured in @($StatePaths)){if(-not [string]::IsNullOrWhiteSpace([string]$configured)){$stateCandidates+=[string]$configured}}
        $derivedState=Join-Path $configDir 'sunshine_state.json'
        $statePath=$derivedState
        foreach($candidate in $stateCandidates){
            $parent=Split-Path -Parent ([string]$candidate)
            if((Test-Path -LiteralPath ([string]$candidate) -PathType Leaf) -or (Test-Path -LiteralPath $parent -PathType Container)){ $statePath=[string]$candidate; break }
        }
        $stateParent=Split-Path -Parent $statePath
        if(-not (Test-Path -LiteralPath $stateParent)){New-Item -ItemType Directory -Path $stateParent -Force | Out-Null}
        # A prior capture run locks the state file to SYSTEM-only. This retry
        # runs as the guest user over WinRM, so reset the ACL before writing
        # (take ownership, grant Administrators full control, then rewrite).
        if(Test-Path -LiteralPath $statePath -PathType Leaf){
            try{
                & takeown.exe /F "$statePath" /A 2>&1 | Out-Null
                & icacls.exe "$statePath" /grant "*S-1-5-32-544:(F)" 2>&1 | Out-Null
                Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            }catch{}
        }
        $saltBytes=New-Object byte[] 16
        try{
            $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
            try{ $rng.GetBytes($saltBytes) } finally { $rng.Dispose() }
            $salt=([BitConverter]::ToString($saltBytes)-replace '-','').ToLowerInvariant()
            $sha=[Security.Cryptography.SHA256]::Create()
            try{
                $digest=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([string]$SunshinePassword)+$salt))
                [Array]::Reverse($digest)
            } finally { $sha.Dispose() }
            $passwordHash=([BitConverter]::ToString($digest)-replace '-','').ToUpperInvariant()
            $record=[ordered]@{username=[string]$SunshineUsername;salt=$salt;password=$passwordHash}
            Set-Content -LiteralPath $statePath -Value ($record|ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
            $acl=Get-Acl -LiteralPath $statePath
            $acl.SetAccessRuleProtection($true,$false)
            @($acl.Access)|ForEach-Object{[void]$acl.RemoveAccessRule($_)}
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('SYSTEM','Modify','Allow'))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Administrators','Read','Allow'))
            Set-Acl -LiteralPath $statePath -AclObject $acl
        } finally { [Array]::Clear($saltBytes,0,$saltBytes.Length) }

        # A real desktop session requires a logged-in interactive user.
        # Reapply the template policy for retained or older templates before
        # the claimed account's first login, so its desktop is usable.
        $oobePolicy=New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Force
        Set-ItemProperty -LiteralPath $oobePolicy.PSPath -Name 'DisablePrivacyExperience' -Value 1 -Type DWord
        $lsaPath='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $lsaPath -Name 'AutoAdminLogon' -Value '1' -Type String
        Set-ItemProperty -Path $lsaPath -Name 'DefaultUserName' -Value ([string]$GuestUsername) -Type String
        Set-ItemProperty -Path $lsaPath -Name 'DefaultDomainName' -Value '.' -Type String
        Set-ItemProperty -Path $lsaPath -Name 'DefaultPassword' -Value ([string]$GuestPassword) -Type String
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord

        $captureStage=Set-EpicVMGamingCaptureStage 'CAPTURE_FIREWALL_CONFIG'
        Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -match '(?i)Sunshine' } | Disable-NetFirewallRule -ErrorAction SilentlyContinue
        Get-NetFirewallRule -Name 'EpicVM-Sunshine-Tailscale-TCP','EpicVM-Sunshine-Tailscale-UDP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name 'EpicVM-Sunshine-Tailscale-TCP' -DisplayName 'EpicVM Sunshine (Tailscale TCP)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47984,47989,47990,48010 -RemoteAddress '100.64.0.0/10' -Profile Any -EdgeTraversalPolicy Block | Out-Null
        New-NetFirewallRule -Name 'EpicVM-Sunshine-Tailscale-UDP' -DisplayName 'EpicVM Sunshine (Tailscale UDP)' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 47998,47999,48000,48002 -RemoteAddress '100.64.0.0/10' -Profile Any -EdgeTraversalPolicy Block | Out-Null

        $captureStage=Set-EpicVMGamingCaptureStage 'CAPTURE_SERVICE_RESTART'
        try { Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop; Restart-Service -Name $ServiceName -Force -ErrorAction Stop } catch { throw 'EPICVM_SUNSHINE_SERVICE_RESTART_FAILED' }
        $listenerDeadline=[DateTime]::UtcNow.AddSeconds(45)
        $running=$false;$listener=$false
        while([DateTime]::UtcNow -lt $listenerDeadline){
            $current=Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            $running=$null -ne $current -and [string]$current.Status -eq 'Running'
            $listener=$null -ne (Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue)
            if($running -and $listener){break}
            Start-Sleep -Milliseconds 500
        }
        if(-not $running -or -not $listener){throw 'EPICVM_SUNSHINE_LISTENER_FAILED'}
        Remove-Item -LiteralPath $vddZip,$nefconZip -Force -ErrorAction SilentlyContinue
        $interactiveUser=[string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        $expectedUser=$env:COMPUTERNAME + '\' + $GuestUsername
        [ordered]@{ok=$true;vddInstalled=$deviceOk;captureConfWritten=(Test-Path -LiteralPath $confPath);autoLogonConfigured=$true;serviceRunning=$running;listener=$listener;desktopRestartRequired=($interactiveUser -ine $expectedUser);bootTime=([DateTime](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime().ToString('o')}
        } catch {
            $message=@([string]$_.Exception.Message,[string]$_.ToString()) -join ' '
            $safeMarkers=@(
                'EPICVM_CAPTURE_INVALID_INPUT','EPICVM_CAPTURE_VDD_INF_MISSING',
                'EPICVM_CAPTURE_STAGING_FAILED',
                'EPICVM_CAPTURE_VDD_INSTALL_FAILED','EPICVM_CAPTURE_VDD_DEVICE_NOT_OK',
                'EPICVM_CAPTURE_NEFCON_MISSING','EPICVM_SUNSHINE_SERVICE_MISSING',
                'EPICVM_CAPTURE_DISPLAY_NOT_FOUND',
                'EPICVM_SUNSHINE_EXECUTABLE_MISSING','EPICVM_SUNSHINE_VERSION_MISMATCH',
                'EPICVM_SUNSHINE_SERVICE_RESTART_FAILED','EPICVM_SUNSHINE_LISTENER_FAILED'
            )
            $reportedMarker=$null
            foreach($candidate in $safeMarkers){if($message -match [regex]::Escape($candidate)){$reportedMarker=$candidate;break}}
            [ordered]@{ok=$false;failureDetailCode=$captureStage;safeMarker=$reportedMarker}
        }
    }
}

function Get-EpicVMGamingAudioConfigurationScript {
    return {
        param($SunshineServiceName)
        $ErrorActionPreference='Stop'
        try {
            $stageRoot=Join-Path $env:ProgramData 'EpicVM\capture'
            $device=Get-PnpDevice -PresentOnly -Class MEDIA -ErrorAction SilentlyContinue | Where-Object {$_.FriendlyName -eq 'VB-Audio Virtual Cable' -and $_.Status -eq 'OK'} | Select-Object -First 1
            if($null -eq $device){
                # The administrator stages the Microsoft-signed driver in the
                # private VM template. EpicVM activates that approved driver
                # without bundling or downloading a third-party installer.
                $nefcon=Get-ChildItem -LiteralPath (Join-Path $stageRoot 'nefcon') -Recurse -Filter 'nefconc.exe' -ErrorAction SilentlyContinue | Where-Object {$_.DirectoryName -match 'x64'} | Select-Object -First 1
                if($null -eq $nefcon){throw 'Audio device activation tool missing'}
                & $nefcon.FullName --create-device-node --hardware-id 'VBAudioVACWDM' --class-name MEDIA --class-guid '{4d36e96c-e325-11ce-bfc1-08002be10318}' 2>&1 | Out-Null
                if($LASTEXITCODE -ne 0){throw 'Audio device creation failed'}
                & pnputil.exe /scan-devices 2>&1 | Out-Null
            }
            Set-Service AudioEndpointBuilder -StartupType Automatic
            Set-Service Audiosrv -StartupType Automatic
            Start-Service AudioEndpointBuilder
            Start-Service Audiosrv
            $deadline=[DateTime]::UtcNow.AddSeconds(30)
            do {
                $device=Get-PnpDevice -PresentOnly -Class MEDIA -ErrorAction SilentlyContinue | Where-Object {$_.FriendlyName -eq 'VB-Audio Virtual Cable' -and $_.Status -eq 'OK'} | Select-Object -First 1
                $speaker=Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction SilentlyContinue | Where-Object {$_.FriendlyName -match '^(Speakers|CABLE In 16 Ch).*VB-Audio Virtual Cable' -and $_.Status -eq 'OK'} | Select-Object -First 1
                if($null -ne $device -and $null -ne $speaker){
                    Restart-Service -Name ([string]$SunshineServiceName) -Force -ErrorAction Stop
                    $listenerDeadline=[DateTime]::UtcNow.AddSeconds(30)
                    while(-not (Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue)){
                        if([DateTime]::UtcNow -ge $listenerDeadline){throw 'Sunshine listener unavailable after audio activation'}
                        Start-Sleep -Milliseconds 500
                    }
                    return @{ok=$true;audioEndpointVerified=$true}
                }
                Start-Sleep -Milliseconds 500
            }while([DateTime]::UtcNow -lt $deadline)
            throw 'Audio endpoint unavailable'
        }catch{return @{ok=$false;failureDetailCode='CAPTURE_AUDIO_DEVICE'}}
    }
}

function Get-EpicVMGamingDesktopSessionScript {
    return {
        param($GuestUser,$PreviousBoot)
        $ErrorActionPreference='Stop'
        $user=[string](Get-CimInstance Win32_ComputerSystem).UserName
        $boot=([DateTime](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime().ToString('o')
        $desktop=@(Get-Process -Name explorer -ErrorAction SilentlyContinue|Where-Object {$_.SessionId -gt 0})
        [ordered]@{ok=($user -ieq ($env:COMPUTERNAME+'\'+$GuestUser) -and $desktop.Count -gt 0 -and $boot -ne $PreviousBoot)}
    }
}

function Wait-EpicVMGamingDesktopAfterRestart {
    param($Provider,[string]$VmName,[string]$VmId,[string]$GuestAddress,$Credential,$DirectCredential,[string]$GuestUser,[string]$PreviousBoot,[int]$TimeoutSeconds=240)
    # Setting AutoAdminLogon alone leaves a fresh clone on the sign-in screen.
    # Reboot only the guest being configured, then require its new interactive
    # desktop over the verified management path before pairing Sunshine.
    $restart=Invoke-EpicVMPowerShellDirectOnce -Provider $Provider -VmName $VmName -VmId $VmId -Credential $DirectCredential -Script {
        & "$env:SystemRoot\System32\shutdown.exe" /r /t 3 /f /d p:4:1 | Out-Null
        if($LASTEXITCODE -ne 0){throw 'EPICVM_CAPTURE_DESKTOP_RESTART_FAILED'}
        @{ok=$true}
    } -TimeoutSeconds 15
    if(-not [bool](Get-EpicVMHyperVValue -Object $restart -Name 'ok' -Default $false)){throw 'EPICVM_CAPTURE_DESKTOP_RESTART_FAILED'}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        try {
            $session=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $Credential -Script (Get-EpicVMGamingDesktopSessionScript) -ArgumentList @($GuestUser,$PreviousBoot) -TimeoutSeconds 10 -RetryCount 0
            if([bool](Get-EpicVMHyperVValue -Object $session -Name 'ok' -Default $false)){return}
        }catch{}
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'EPICVM_CAPTURE_DESKTOP_NOT_READY'
}

function Get-EpicVMSunshineReadinessScript {
    return {
        param($ServiceName)
        $ErrorActionPreference='SilentlyContinue'
        $deadline=[DateTime]::UtcNow.AddSeconds(45)
        do {
            $service=Get-Service -Name ([string]$ServiceName) -ErrorAction SilentlyContinue
            $running=$null -ne $service -and [string]$service.Status -eq 'Running'
            $listener=$null -ne (Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue)
            if($running -and $listener){
                return [ordered]@{ok=$true;serviceRunning=$true;listener=$true}
            }
            if([DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 500}
        } while([DateTime]::UtcNow -lt $deadline)
        [ordered]@{ok=$false;serviceRunning=$running;listener=$listener}
    }
}

function Get-EpicVMSunshineImmediateReadinessScript {
    return {
        param($ServiceName)
        $ErrorActionPreference='SilentlyContinue'
        $service=Get-Service -Name ([string]$ServiceName) -ErrorAction SilentlyContinue
        $running=$null -ne $service -and [string]$service.Status -eq 'Running'
        $listener=$null -ne (Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue)
        [ordered]@{ok=($running -and $listener);serviceRunning=$running;listener=$listener}
    }
}

function Get-EpicVMPowerShellDirectReadinessScript {
    return {
        $ErrorActionPreference='Stop'
        # This probe intentionally has no guest mutation and returns no guest
        # identity. It lets a VM that has just reached Running settle its
        # PowerShell Direct channel before the credential-bearing Sunshine
        # operation begins.
        $null=Get-Date -Format o
        [ordered]@{ok=$true;powershellDirect=$true}
    }
}

function Ensure-EpicVMPowerShellDirectHostService {
    <#
        vmicvmsession is trigger-start. It may legitimately return to
        Stopped when no Direct session is attached, so an idle Stopped state
        is never treated as a credential failure. This helper only best-effort
        starts the exact host service before the channel open and returns
        sanitized state for classification.
    #>
    $service=$null
    try { $service=Get-Service -Name 'vmicvmsession' -ErrorAction Stop }
    catch { throw (New-EpicVMHyperVError -Code 'direct_not_supported' -Message 'PowerShell Direct is not available on this host.') }
    if([string]$service.StartType -eq 'Disabled') {
        throw (New-EpicVMHyperVError -Code 'direct_service_disabled' -Message 'The Hyper-V VM Session Service is disabled.')
    }
    $state=[ordered]@{present=$true;before=[string]$service.Status;startAttempted=$false;startFailed=$false;after=[string]$service.Status}
    if([string]$service.Status -ne 'Running') {
        $state.startAttempted=$true
        try {
            Start-Service -Name 'vmicvmsession' -ErrorAction Stop
            $deadline=[DateTime]::UtcNow.AddSeconds(2)
            do {
                $state.after=[string](Get-Service -Name 'vmicvmsession' -ErrorAction Stop).Status
                if($state.after -eq 'Running'){break}
                if([DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
            } while([DateTime]::UtcNow -lt $deadline)
        } catch {
            $state.startFailed=$true
            $state.after='StartFailed'
        }
    }
    return [pscustomobject]$state
}

function Invoke-EpicVMPowerShellDirectDiagnostic {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [AllowNull()][string]$VmId=''
    )
    $correlationId=[Guid]::NewGuid().ToString('N')
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $base=[ordered]@{correlationId=$correlationId;sessionCreated=$false;code='direct_runtime_failure';durationBucket='<1s'}
    try {
        $vm=$null
        if([string]::IsNullOrWhiteSpace($VmId)){
            try{$items=@(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VM' -Parameters @{Name=$VmName;ErrorAction='Stop'})}catch{throw (New-EpicVMHyperVError -Code 'hyperv_access_denied' -Message 'The Hyper-V VM lookup was denied.')}
            if($items.Count -ne 1){throw (New-EpicVMHyperVError -Code 'hyperv_vm_not_found' -Message 'The Hyper-V VM was not found.')}
            $vm=$items[0];$VmId=[string](Get-EpicVMHyperVValue -Object $vm -Name 'Id' -Default '')
        }
        if([string]::IsNullOrWhiteSpace($VmId)){throw (New-EpicVMHyperVError -Code 'hyperv_vm_not_found' -Message 'The Hyper-V VM identifier is unavailable.')}
        if($null -eq $vm){
            try{$vm=@(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VM' -Parameters @{Id=([Guid]$VmId);ErrorAction='Stop'}) | Select-Object -First 1}catch{throw (New-EpicVMHyperVError -Code 'hyperv_access_denied' -Message 'The Hyper-V VM lookup was denied.')}
        }
        if($null -eq $vm){throw (New-EpicVMHyperVError -Code 'hyperv_vm_not_found' -Message 'The Hyper-V VM was not found.')}
        if([string](Get-EpicVMHyperVValue -Object $vm -Name 'State' -Default '') -ine 'Running'){
            throw (New-EpicVMHyperVError -Code 'hyperv_vm_not_running' -Message 'The Hyper-V VM is not running.')
        }
        $services=$null
        try{$services=@(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMIntegrationService' -Parameters @{VMName=$VmName;ErrorAction='Stop'})}catch{throw (New-EpicVMHyperVError -Code 'direct_not_supported' -Message 'Hyper-V integration-service diagnostics are unavailable.')}
        $heartbeat=$services | Where-Object {[string](Get-EpicVMHyperVValue -Object $_ -Name 'Name' -Default '') -match '(?i)^Heartbeat$'} | Select-Object -First 1
        if($null -ne $heartbeat){
            $hbStatus=[string](Get-EpicVMHyperVValue -Object $heartbeat -Name 'OperationalStatus' -Default '')
            $hbDesc=[string](Get-EpicVMHyperVValue -Object $heartbeat -Name 'PrimaryStatusDescription' -Default '')
            if(($hbStatus -and $hbStatus -notmatch '(?i)ok|operational') -or ($hbDesc -and $hbDesc -notmatch '(?i)ok|operational')){
                throw (New-EpicVMHyperVError -Code 'guest_heartbeat_unhealthy' -Message 'The guest heartbeat is not healthy.')
            }
        }
        # Guest Service Interface (vmicguestinterface) is a separate file-copy
        # integration service and may legitimately be disabled.  It must never
        # be used as a PowerShell Direct readiness signal.  PowerShell Direct is
        # backed by the VM Session Service (vmicvmsession), which is exposed as
        # a host service rather than a Get-VMIntegrationService entry.
        $direct=$services | Where-Object {[string](Get-EpicVMHyperVValue -Object $_ -Name 'Name' -Default '') -match '(?i)^PowerShell Direct$'} | Select-Object -First 1
        if($null -ne $direct){
            $enabled=Get-EpicVMHyperVValue -Object $direct -Name 'Enabled' -Default $true
            if(-not [bool]$enabled){throw (New-EpicVMHyperVError -Code 'direct_service_disabled' -Message 'PowerShell Direct is disabled.')}
            $status=[string](Get-EpicVMHyperVValue -Object $direct -Name 'OperationalStatus' -Default '')
            if($status -and $status -notmatch '(?i)ok|operational|running'){
                throw (New-EpicVMHyperVError -Code 'direct_service_not_ready' -Message 'PowerShell Direct is not ready.')
            }
        }
        $hostDirect=@(Get-CimInstance -ClassName Win32_Service -Filter "Name='vmicvmsession'" -ErrorAction SilentlyContinue | Select-Object -First 1)
        if($hostDirect.Count -eq 0 -and $null -eq $direct){
            throw (New-EpicVMHyperVError -Code 'direct_not_supported' -Message 'PowerShell Direct is not available on this host.')
        }
        if($hostDirect.Count -gt 0 -and [string]$hostDirect[0].StartMode -eq 'Disabled'){
            throw (New-EpicVMHyperVError -Code 'direct_service_disabled' -Message 'The Hyper-V VM Session Service is disabled.')
        }
        $probe=Invoke-EpicVMPowerShellDirectOnce -Provider $Provider -VmName $VmName -VmId $VmId -Credential $Credential -Script (Get-EpicVMPowerShellDirectReadinessScript) -TimeoutSeconds 10
        if(-not [bool](Get-EpicVMHyperVValue -Object $probe -Name 'ok' -Default $false)){throw (New-EpicVMHyperVError -Code 'guest_operation_failed' -Message 'The read-only guest probe did not verify.')}
        $base.code='ok';$base.sessionCreated=$true
    } catch {
        $base.code=[string](Get-EpicVMHyperVValue -Object $_.Exception -Name 'ErrorCode' -Default 'direct_runtime_failure')
        $base.sessionCreated=[bool](Get-EpicVMHyperVValue -Object $_.Exception -Name 'SessionCreated' -Default $base.sessionCreated)
    } finally {
        $base.durationBucket=ConvertTo-EpicVMOperationDurationBucket -Milliseconds ([int]$watch.ElapsedMilliseconds)
    }
    return [pscustomobject]$base
}

function Invoke-EpicVMSunshineConfiguration {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$GuestUsername,
        [Parameter(Mandatory)][string]$GuestPassword,
        [Parameter(Mandatory)][string]$SunshineUsername,
        [Parameter(Mandatory)][string]$SunshinePassword,
        [AllowNull()][string]$GuestAddress='',
        [AllowNull()][scriptblock]$ManagementCheckpoint=$null,
        [bool]$ManagementHandoffAlreadyVerified=$false,
        [bool]$IsGaming=$false
    )
    if($GuestUsername -notmatch '^[A-Za-z][A-Za-z0-9._-]{2,31}$' -or [string]::IsNullOrEmpty($GuestPassword) -or [string]::IsNullOrEmpty($SunshineUsername) -or [string]::IsNullOrEmpty($SunshinePassword)){
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'Guest and Sunshine credentials are required.')
    }
    $credential=$null
    $sunshineScript=Get-EpicVMSunshineConfigurationScript -ForGaming ([bool]$IsGaming)
    $serviceName=[string](Get-EpicVMHyperVValue -Object $Config -Name 'SunshineServiceName' -Default 'SunshineService')
    $expectedVersion=[string](Get-EpicVMHyperVValue -Object $Config -Name 'SunshineVersion' -Default '2026.516.143833')
    $statePaths=@(Get-EpicVMHyperVValue -Object $Config -Name 'SunshineStatePaths' -Default @('C:\Program Files\Sunshine\config\sunshine_state.json','C:\ProgramData\Sunshine\config\sunshine_state.json'))
    $sunshineStage='SUNSHINE_MANAGEMENT_READINESS'
    try{
        # Keep the original local credential for the bounded Direct recovery
        # path. WinRM receives a separate explicitly local-qualified copy;
        # this is required for local/workgroup accounts over a Tailscale IP.
        $directCredential=[PSCredential]::new($GuestUsername,(ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
        $credential=New-EpicVMWinRMLocalCredential -Credential $directCredential
        if([string]::IsNullOrWhiteSpace($GuestAddress)){$GuestAddress=[string](Get-EpicVMHyperVValue -Object (Get-EpicVMHyperVValue -Object $Provider -Name 'LastTailscaleEnrollment' -Default $null) -Name 'ip' -Default '')}
        if([string]::IsNullOrWhiteSpace($GuestAddress)){throw 'EPICVM_MANAGEMENT_UNAVAILABLE'}
        $managementPort=[int](Get-EpicVMHyperVValue -Object $Provider -Name 'ManagementPort' -Default 5985)
        $managementUseSsl=[bool](Get-EpicVMHyperVValue -Object $Provider -Name 'ManagementUseSsl' -Default $false)
        if($managementPort -lt 1 -or $managementPort -gt 65535){$managementPort=if($managementUseSsl){5986}else{5985}}
        # Tailscale and WinRM are separate gates. The selected 100.64/10
        # address must be reachable before the management transport is used.
        $transport=$null
        $managementInvoker=Get-EpicVMHyperVValue -Object $Provider -Name 'ManagementInvoker' -Default $null
        if($null -eq $managementInvoker){
            if($ManagementHandoffAlreadyVerified){
                # A restart can briefly withdraw the guest's Tailscale-facing
                # WinRM listener even while the VM is already Running. Test the
                # actual management transport, not optional RDP availability.
                $tailscaleDeadline=[DateTime]::UtcNow.AddSeconds(30)
                while(-not (Test-EpicVMManagementPort -Address $GuestAddress -Port $managementPort -TimeoutMilliseconds 2000)){
                    if([DateTime]::UtcNow -ge $tailscaleDeadline){throw (New-EpicVMHyperVError -Code 'tailscale_unreachable' -Message 'The guest Tailscale address is not reachable.')}
                    Start-Sleep -Seconds 2
                }
            } elseif(-not (Test-EpicVMGuestRdpReachability -Address $GuestAddress -Port 3389 -TimeoutMilliseconds 3000)){
                throw (New-EpicVMHyperVError -Code 'tailscale_unreachable' -Message 'The guest Tailscale address is not reachable.')
            }
        }
        $managementInitialTimeout=if($null -eq $managementInvoker){20}else{30}
        $managementRecoveryTimeout=if($null -eq $managementInvoker){20}else{30}
        $vmId=''
        try{$vmId=[string](@(& $Provider.GetVMs | Where-Object {[string](Get-EpicVMHyperVValue -Object $_ -Name 'name' -Default '') -ceq $VmName} | Select-Object -First 1 | ForEach-Object {Get-EpicVMHyperVValue -Object $_ -Name 'id' -Default ''}))}catch{}

        try {
            # A closed native WinRM port is a fast, read-only signal. Avoid
            # spending the full remoting timeout before the one allowed,
            # stage-limited management-handoff repair.
            if ($ManagementHandoffAlreadyVerified) {
                # A persisted handoff is a checkpoint, not proof that a reboot
                # left WinRM listening. Wait on the read-only management gate;
                # if the listener is still absent, the catch block below may
                # perform exactly one bounded LocalSystem management repair and
                # then requires a fresh Tailscale/WinRM readiness check. It
                # never replays the credential-bearing Sunshine write here.
                # An injected ManagementInvoker is a deterministic test seam
                # and has already represented the handoff checkpoint, so do not
                # manufacture an extra remoting call before the Sunshine test.
                if ($null -eq $managementInvoker) {
                    $managementDeadline = [DateTime]::UtcNow.AddSeconds(30)
                    while (-not (Test-EpicVMManagementPort -Address $GuestAddress -Port $managementPort -TimeoutMilliseconds 2000)) {
                        if ([DateTime]::UtcNow -ge $managementDeadline) {
                            throw 'EPICVM_MANAGEMENT_OPEN_TIMEOUT'
                        }
                        Start-Sleep -Seconds 2
                    }
                    $transport=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script (Get-EpicVMManagementReadinessScript) -TimeoutSeconds $managementRecoveryTimeout -RetryCount 1
                } else {
                    $transport=[ordered]@{ok=$true;managementEndpoint=$true;handoffAlreadyVerified=$true}
                }
            } else {
                if($null -eq $managementInvoker -and -not (Test-EpicVMManagementPort -Address $GuestAddress -Port $managementPort -TimeoutMilliseconds 2000)){
                    throw 'EPICVM_MANAGEMENT_OPEN_FAILED'
                }
                $transport=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script (Get-EpicVMManagementReadinessScript) -TimeoutSeconds $managementInitialTimeout -RetryCount 1
            }
        } catch {
            $managementMessage=[string]$_.Exception.Message
            if($managementMessage -match 'EPICVM_MANAGEMENT_CREDENTIAL_REJECTED') { throw }
            if($managementMessage -notmatch 'EPICVM_MANAGEMENT_(OPEN_FAILED|OPEN_TIMEOUT|OPERATION_FAILED|OPERATION_TIMEOUT|UNAVAILABLE)') { throw }
            if($ManagementHandoffAlreadyVerified -and $null -eq $managementInvoker){
                # After a VM restart the TCP listener can be open before the
                # WinRM endpoint accepts a real authenticated request. Retry
                # only the read-only readiness script inside a bounded window.
                # If the listener never returns, perform one stage-limited
                # LocalSystem repair of the WinRM endpoint, then verify the
                # repaired endpoint over Tailscale/WinRM before proceeding.
                # This repairs stale handoff checkpoints without replaying the
                # credential-bearing Sunshine operation.
                $readinessDeadline=[DateTime]::UtcNow.AddSeconds(30)
                $lastManagementError=$null
                $readinessVerified=$false
                while([DateTime]::UtcNow -lt $readinessDeadline){
                    try {
                        $transport=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script (Get-EpicVMManagementReadinessScript) -TimeoutSeconds $managementRecoveryTimeout -RetryCount 1
                        $readinessVerified=$true
                        break
                    } catch {
                        $lastManagementError=$_.Exception
                        $retryMessage=[string]$_.Exception.Message
                        if($retryMessage -notmatch 'EPICVM_MANAGEMENT_(OPEN_FAILED|OPEN_TIMEOUT|OPERATION_FAILED|OPERATION_TIMEOUT|UNAVAILABLE)') { throw }
                        Start-Sleep -Seconds 2
                    }
                }
                if(-not $readinessVerified){
                    $diagnostic=Invoke-EpicVMPowerShellDirectDiagnostic -Provider $Provider -VmName $VmName -VmId $vmId -Credential $directCredential
                    if([string]$diagnostic.code -ne 'ok'){
                        throw $lastManagementError
                    }
                    $repair=Invoke-EpicVMPowerShellDirectOnce -Provider $Provider -VmName $VmName -VmId $vmId -Credential $directCredential -Script (Get-EpicVMGuestManagementConfigurationScript) -ArgumentList @($managementPort,$managementUseSsl) -TimeoutSeconds 45
                    if(-not [bool](Get-EpicVMHyperVValue -Object $repair -Name 'ok' -Default $false) -or
                       -not [bool](Get-EpicVMHyperVValue -Object $repair -Name 'managementEndpoint' -Default $false) -or
                       -not [bool](Get-EpicVMHyperVValue -Object $repair -Name 'firewallScoped' -Default $false)){
                        throw (New-EpicVMHyperVError -Code 'management_handoff_failed' -Message 'The bounded management endpoint repair did not verify.')
                    }
                    $postRepairDeadline=[DateTime]::UtcNow.AddSeconds(30)
                    while($true){
                        try {
                            $transport=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script (Get-EpicVMManagementReadinessScript) -TimeoutSeconds $managementRecoveryTimeout -RetryCount 1
                            break
                        } catch {
                            $lastManagementError=$_.Exception
                            $retryMessage=[string]$_.Exception.Message
                            if($retryMessage -notmatch 'EPICVM_MANAGEMENT_(OPEN_FAILED|OPEN_TIMEOUT|OPERATION_FAILED|OPERATION_TIMEOUT|UNAVAILABLE)') { throw }
                            if([DateTime]::UtcNow -ge $postRepairDeadline){ throw $lastManagementError }
                            Start-Sleep -Seconds 2
                        }
                    }
                }
            } else {
                if(-not $ManagementHandoffAlreadyVerified -and $null -eq $managementInvoker){
                    # The LocalSystem diagnostic is read-only. Only if it is
                    # conclusively successful may Direct perform this one bounded
                    # WinRM handoff write. Sunshine never runs through Direct.
                    $diagnostic=Invoke-EpicVMPowerShellDirectDiagnostic -Provider $Provider -VmName $VmName -VmId $vmId -Credential $directCredential
                    if([string]$diagnostic.code -ne 'ok'){
                        throw (New-EpicVMHyperVError -Code ([string]$diagnostic.code) -Message 'The LocalSystem PowerShell Direct diagnostic did not pass.')
                    }
                    $repair=Invoke-EpicVMPowerShellDirectOnce -Provider $Provider -VmName $VmName -VmId $vmId -Credential $directCredential -Script (Get-EpicVMGuestManagementConfigurationScript) -ArgumentList @($managementPort,$managementUseSsl) -TimeoutSeconds 45
                    if(-not [bool](Get-EpicVMHyperVValue -Object $repair -Name 'ok' -Default $false)){throw 'EPICVM_MANAGEMENT_ENDPOINT_FAILED'}
                }
                $transport=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script (Get-EpicVMManagementReadinessScript) -TimeoutSeconds $managementRecoveryTimeout -RetryCount 1
            }
        }
        if(-not [bool](Get-EpicVMHyperVValue -Object $transport -Name 'ok' -Default $false)){throw 'EPICVM_MANAGEMENT_UNAVAILABLE'}
        if($null -ne $ManagementCheckpoint -and -not $ManagementHandoffAlreadyVerified){
            try { & $ManagementCheckpoint ([ordered]@{transport='tailscale_winrm';port=$managementPort;useSsl=$managementUseSsl;verified=$true}) }
            catch { throw (New-EpicVMHyperVError -Code 'management_handoff_failed' -Message 'The management handoff checkpoint could not be persisted.') }
        }
        # Sunshine setup performs credential-state writes, firewall changes,
        # and a service restart. Its guest-side listener gate is 45 seconds,
        # so it gets an explicit bounded operation window and no automatic
        # replay of the credential-bearing script.
        $sunshineStage='SUNSHINE_CONFIG_WRITE'
        # The gaming capture path stages the cached Virtual Display Driver and
        # nefcon installers into the guest BEFORE the credential-bearing
        # script. Guests have no internet access by design, and a single
        # ~3 MB remoting argument exceeds the guest's default WSMan envelope,
        # so each archive is shipped in envelope-safe chunks that the guest
        # reassembles; every call is idempotent (parts are replaced whole).
        if($IsGaming){
            $cacheRoot=Join-Path ([string](Get-EpicVMHyperVValue -Object $Config -Name 'AgentDataRoot' -Default 'C:\ProgramData\EpicVM')) 'cache'
            $vddZipPath=Join-Path $cacheRoot 'VirtualDisplayDriver-25.7.23\VirtualDisplayDriver-x86.Driver.Only.zip'
            $nefconZipPath=Join-Path $cacheRoot 'NefCon-1.14.0\nefcon_v1.14.0.zip'
            if(-not ((Test-Path -LiteralPath $vddZipPath -PathType Leaf) -and (Test-Path -LiteralPath $nefconZipPath -PathType Leaf))){
                throw (New-EpicVMHyperVError -Code 'gaming_capture_payload_unavailable' -Message 'The cached virtual display driver packages are unavailable for the Gaming capture configuration.' -DetailCode 'GAMING_GPU_FRAME')
            }
            $stageScript=Get-EpicVMGamingCaptureStageScript
            foreach($pair in @(@('vdd',$vddZipPath),@('nefcon',$nefconZipPath))){
                $artifactName=[string]$pair[0]
                $bytes=[IO.File]::ReadAllBytes([string]$pair[1])
                try {
                    $b64=[Convert]::ToBase64String($bytes)
                    # The guest's WSMan MaxEnvelopeSizekb is 500 KB and the
                    # whole SOAP envelope must fit, so keep each request far
                    # below that ceiling. 200 KB of base64 per call keeps the
                    # total envelope under ~300 KB after script/overhead.
                    $chunkSize=200000
                    $totalParts=[Math]::Ceiling($b64.Length / [double]$chunkSize)
                    for($part=0;$part -lt $totalParts;$part++){
                        $start=$part*$chunkSize
                        $length=[Math]::Min($chunkSize,$b64.Length-$start)
                        $piece=$b64.Substring($start,$length)
                        $sunshineStage='CAPTURE_STAGING'
                        $staged=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script $stageScript -ArgumentList @($artifactName,[int]$totalParts,[int]$part,[int]$b64.Length,$piece) -TimeoutSeconds 60 -RetryCount 0
                        $stagedStage=[string](Get-EpicVMHyperVValue -Object $staged -Name 'failureDetailCode' -Default '')
                        if($stagedStage -like 'CAPTURE_*'){$sunshineStage=$stagedStage}
                        if(-not [bool](Get-EpicVMHyperVValue -Object $staged -Name 'ok' -Default $false)){
                            throw 'EPICVM_CAPTURE_STAGING_FAILED'
                        }
                    }
                } finally { [Array]::Clear($bytes,0,$bytes.Length) }
            }
        }
        $sunshineArguments=@($SunshineUsername,$SunshinePassword,$serviceName,$expectedVersion,$statePaths)
        $sunshineTimeout=75
        if($IsGaming){
            $sunshineArguments=@($SunshineUsername,$SunshinePassword,$serviceName,$expectedVersion,$statePaths,$GuestUsername,$GuestPassword)
            # Driver installation plus device settle exceeds the standard
            # window; keep it explicit and bounded.
            $sunshineTimeout=240
        }
        $result=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script $sunshineScript -ArgumentList $sunshineArguments -TimeoutSeconds $sunshineTimeout -RetryCount 0
        $reportedStage=[string](Get-EpicVMHyperVValue -Object $result -Name 'failureDetailCode' -Default '')
        $reportedStages=@('SUNSHINE_INPUT_VALIDATION','SUNSHINE_SERVICE_DISCOVERY','SUNSHINE_SERVICE_CIM_QUERY','SUNSHINE_EXECUTABLE_RESOLVE','SUNSHINE_VERSION_VERIFY','SUNSHINE_STATE_PATH','SUNSHINE_STATE_WRITE','SUNSHINE_STATE_ACL','SUNSHINE_FIREWALL_CONFIG','SUNSHINE_SERVICE_RESTART','SUNSHINE_LISTENER_VERIFY','CAPTURE_INPUT_VALIDATION','CAPTURE_STAGING','CAPTURE_VDD_INSTALL','CAPTURE_SUNSHINE_CONF','CAPTURE_CREDENTIALS_AND_LOGON','CAPTURE_FIREWALL_CONFIG','CAPTURE_SERVICE_RESTART')
        if($reportedStages -contains $reportedStage){$sunshineStage=$reportedStage}
        if(-not [bool](Get-EpicVMHyperVValue -Object $result -Name 'ok' -Default $false) -or -not [bool](Get-EpicVMHyperVValue -Object $result -Name 'listener' -Default $false)){
            throw 'EPICVM_SUNSHINE_VERIFICATION_FAILED'
        }
        if($IsGaming -and [bool](Get-EpicVMHyperVValue -Object $result -Name 'desktopRestartRequired' -Default $false)){
            $sunshineStage='CAPTURE_DESKTOP_LOGON'
            Wait-EpicVMGamingDesktopAfterRestart -Provider $Provider -VmName $VmName -VmId $vmId -GuestAddress $GuestAddress -Credential $credential -DirectCredential $directCredential -GuestUser $GuestUsername -PreviousBoot ([string](Get-EpicVMHyperVValue -Object $result -Name 'bootTime' -Default ''))
        }
        # Recheck only read-only service/listener state. This is the sole
        # bounded retry permitted after the credential-bearing operation.
        $sunshineStage='SUNSHINE_STATUS_VERIFY'
        $readiness=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script (Get-EpicVMSunshineReadinessScript) -ArgumentList @($serviceName) -TimeoutSeconds 60 -RetryCount 1
        if(-not [bool](Get-EpicVMHyperVValue -Object $readiness -Name 'ok' -Default $false)){
            throw 'EPICVM_SUNSHINE_LISTENER_FAILED'
        }
        $gamingCaptureConfigured=$false
        $gamingCaptureAt=$null
        if($IsGaming){
            $sunshineStage='CAPTURE_AUDIO_DEVICE'
            $audioResult=Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential $credential -Script (Get-EpicVMGamingAudioConfigurationScript) -ArgumentList @($serviceName) -TimeoutSeconds 75 -RetryCount 0
            if(-not [bool](Get-EpicVMHyperVValue -Object $audioResult -Name 'audioEndpointVerified' -Default $false)){
                throw 'EPICVM_CAPTURE_AUDIO_DEVICE'
            }
            $gamingValidation=Invoke-EpicVMHyperVGamingGuestValidation -Provider $Provider -Name $VmName -GuestUsername $GuestUsername -GuestPassword $GuestPassword -GuestAddress $GuestAddress
            $gamingPayload=Get-EpicVMHyperVValue -Object $gamingValidation -Name 'validation' -Default $gamingValidation
            $renderFrameOk=[bool](Get-EpicVMHyperVValue -Object $gamingPayload -Name 'renderFrameOk' -Default $false)
            $encoderOk=[bool](Get-EpicVMHyperVValue -Object $gamingPayload -Name 'sunshineEncoderOk' -Default $false)
            if(-not $renderFrameOk){ throw (New-EpicVMHyperVError -Code 'sunshine_verification_failed' -Message 'The Gaming capture target did not produce a usable GPU frame.' -DetailCode 'GAMING_GPU_FRAME') }
            if(-not $encoderOk){ throw (New-EpicVMHyperVError -Code 'sunshine_verification_failed' -Message 'The Gaming capture target did not verify AMD hardware encoding.' -DetailCode 'GAMING_GPU_ENCODER') }
            $gamingCaptureConfigured=$true
            $gamingCaptureAt=[DateTime]::UtcNow.ToString('o')
        }
        return [ordered]@{ok=$true;managementTransport='tailscale_winrm';managementReady=$true;managementPort=$managementPort;managementUseSsl=$managementUseSsl;serviceRunning=[bool](Get-EpicVMHyperVValue -Object $result -Name 'serviceRunning' -Default $false);listener=$true;credentialsConfigured=$true;firewallScoped=[bool](Get-EpicVMHyperVValue -Object $result -Name 'firewallScoped' -Default $false);gamingCaptureConfigured=$gamingCaptureConfigured;gamingCaptureAt=$gamingCaptureAt}
    }catch{
        # Remoting can wrap a guest throw in a generic ErrorRecord. Scan only
        # the bounded, allowlisted marker text; never return or log the raw
        # exception, credentials, or guest paths.
        $message=@(
            [string](Get-EpicVMHyperVValue -Object $_.Exception -Name 'Message' -Default '')
            [string](Get-EpicVMHyperVValue -Object $_.Exception -Name 'ErrorDetails' -Default '')
            [string]$_.Exception.ToString()
            [string]$_.ToString()
        ) -join ' '
        $safeCode=[string](Get-EpicVMHyperVValue -Object $_.Exception -Name 'ErrorCode' -Default 'sunshine_setup_failed')
        $allowedCodes=@(
            'sunshine_invalid_input','sunshine_service_missing','sunshine_executable_missing',
            'sunshine_version_mismatch','sunshine_state_path_failed','sunshine_state_write_failed',
            'sunshine_state_acl_failed','sunshine_firewall_failed','sunshine_service_restart_failed',
            'sunshine_listener_failed','sunshine_verification_failed','powershell_direct_failed',
            'tailscale_unreachable','management_transport_failed','management_transport_unavailable',
            'management_handoff_failed','guest_credential_rejected','hyperv_vm_not_found',
            'hyperv_access_denied','hyperv_vm_not_running','guest_heartbeat_unhealthy',
            'direct_service_disabled','direct_service_not_ready','direct_not_supported',
            'direct_open_timeout','direct_transport_error','guest_operation_failed',
            'direct_parameter_failure','direct_module_failure','direct_runtime_failure'
        )
        if($allowedCodes -notcontains $safeCode){$safeCode='sunshine_setup_failed'}
        $map=[ordered]@{
            'EPICVM_SUNSHINE_INVALID_INPUT'='sunshine_invalid_input'
            'EPICVM_SUNSHINE_SERVICE_MISSING'='sunshine_service_missing'
            'EPICVM_SUNSHINE_EXECUTABLE_MISSING'='sunshine_executable_missing'
            'EPICVM_SUNSHINE_VERSION_MISMATCH'='sunshine_version_mismatch'
            'EPICVM_SUNSHINE_STATE_PATH_FAILED'='sunshine_state_path_failed'
            'EPICVM_SUNSHINE_STATE_WRITE_FAILED'='sunshine_state_write_failed'
            'EPICVM_SUNSHINE_STATE_ACL_FAILED'='sunshine_state_acl_failed'
            'EPICVM_SUNSHINE_FIREWALL_FAILED'='sunshine_firewall_failed'
            'EPICVM_SUNSHINE_SERVICE_RESTART_FAILED'='sunshine_service_restart_failed'
            'EPICVM_SUNSHINE_LISTENER_FAILED'='sunshine_listener_failed'
            'EPICVM_CAPTURE_INVALID_INPUT'='sunshine_invalid_input'
            'EPICVM_CAPTURE_VDD_INF_MISSING'='gaming_capture_vdd_failed'
            'EPICVM_CAPTURE_VDD_INSTALL_FAILED'='gaming_capture_vdd_failed'
            'EPICVM_CAPTURE_VDD_DEVICE_NOT_OK'='gaming_capture_vdd_failed'
            'EPICVM_CAPTURE_NEFCON_MISSING'='gaming_capture_vdd_failed'
            'EPICVM_CAPTURE_STAGING_FAILED'='gaming_capture_vdd_failed'
            'EPICVM_CAPTURE_DISPLAY_NOT_FOUND'='sunshine_verification_failed'
            'EPICVM_CAPTURE_DESKTOP_RESTART_FAILED'='sunshine_verification_failed'
            'EPICVM_CAPTURE_DESKTOP_NOT_READY'='sunshine_verification_failed'
            'EPICVM_CAPTURE_AUDIO_DEVICE'='gaming_audio_device_failed'
            'EPICVM_SUNSHINE_VERIFICATION_FAILED'='sunshine_verification_failed'
            'EPICVM_POWERSHELL_DIRECT_READINESS_FAILED'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_TIMEOUT'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_OPEN_TIMEOUT'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_OPERATION_TIMEOUT'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_OPEN_FAILED'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_OPERATION_FAILED'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_VM_UNAVAILABLE'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_VM_NOT_RUNNING'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_HEARTBEAT_UNHEALTHY'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_MODULE_UNAVAILABLE'='powershell_direct_failed'
            'EPICVM_POWERSHELL_DIRECT_CREDENTIAL_REJECTED'='guest_credential_rejected'
            'EPICVM_MANAGEMENT_OPEN_TIMEOUT'='management_transport_failed'
            'EPICVM_MANAGEMENT_OPERATION_TIMEOUT'='management_transport_failed'
            'EPICVM_MANAGEMENT_OPEN_FAILED'='management_transport_failed'
               'EPICVM_MANAGEMENT_OPERATION_FAILED'='management_transport_failed'
               'EPICVM_MANAGEMENT_CREDENTIAL_REJECTED'='guest_credential_rejected'
               'EPICVM_MANAGEMENT_UNAVAILABLE'='management_transport_unavailable'
               'EPICVM_MANAGEMENT_TRUSTED_HOSTS_BROAD'='management_handoff_failed'
        }
        foreach($marker in $map.Keys){if($message -match [regex]::Escape($marker)){$safeCode=[string]$map[$marker];break}}
        # Only explicit guest logon/password wording may become a credential
        # rejection. Generic access-denied text is commonly a WinRM/Direct
        # transport failure and is intentionally kept non-credential-specific.
        if($safeCode -eq 'sunshine_setup_failed' -and $message -match '(?i)logon failure|user name or password|credentials? supplied.*not recognized|authentication failed'){$safeCode='guest_credential_rejected'}
        if($safeCode -eq 'sunshine_setup_failed' -and $message -match '(?i)PowerShell Direct|PSRemoting'){$safeCode='powershell_direct_failed'}
        if($safeCode -eq 'sunshine_setup_failed' -and $message -match '(?i)management transport|WinRM|management endpoint|connection|timed out'){$safeCode='management_transport_failed'}
        throw (New-EpicVMHyperVError -Code $safeCode -Message 'Automatic Sunshine configuration failed.' -DetailCode $sunshineStage)
    }
    finally{$GuestPassword=$null;$SunshinePassword=$null;$credential=$null;$directCredential=$null}
}

function Test-EpicVMGuestConfiguration {
    param([Parameter(Mandatory)][object]$Provider,[Parameter(Mandatory)][string]$VmName,[Parameter(Mandatory)][PSCredential]$Credential)
    $script={
        $listener=Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
        $rule=Get-NetFirewallRule -Name 'EpicVM-RDP-Tailscale' -ErrorAction SilentlyContinue
        $nla=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication -eq 1
        [bool]($listener -and $rule -and $nla)
    }
    try{return [bool](Invoke-EpicVMPowerShellDirect -Provider $Provider -VmName $VmName -Credential $Credential -Script $script)}catch{return $false}
}

function Test-EpicVMGuestRdpReachability {
    param([Parameter(Mandatory)][string]$Address,[int]$Port=3389,[int]$TimeoutMilliseconds=3000)
    if($Address -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$'){return $false}
    $client=[Net.Sockets.TcpClient]::new()
    try {
        $task=$client.ConnectAsync($Address,$Port)
        if(-not $task.Wait($TimeoutMilliseconds)){return $false}
        return $client.Connected
    } catch { return $false }
    finally { $client.Dispose() }
}
