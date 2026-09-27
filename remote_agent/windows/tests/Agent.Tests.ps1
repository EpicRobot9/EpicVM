# Requires -Version 7.0
# Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'providers/HyperVProvider.ps1')
    . (Join-Path $windowsRoot 'EpicVM.Agent.ps1') -NoStart

    Add-Type -TypeDefinition @'
public sealed class EpicVMThrowingHttpResponse {
    public int StatusCode { get; set; }
    public System.Collections.Specialized.NameValueCollection Headers { get; } = new System.Collections.Specialized.NameValueCollection();
    public string ContentType { get; set; }
    public long ContentLength64 { set { throw new System.InvalidOperationException("response already submitted"); } }
    public System.IO.Stream OutputStream { get; } = new System.IO.MemoryStream();
}
'@

    function New-TestProvider {
        [pscustomobject]@{
            Name = 'Mock'
            GetCapabilities = { @{ provider = 'Mock'; available = $true; features = @('lifecycle') } }
            GetVMs = { @(@{ name = 'alpha'; state = 'Off'; managed = $true }) }
            CreateVM = { param($request) @{ name = $request.Name; state = 'Off'; managed = $true } }
            StartVM = { param($name) @{ name = $name; state = 'Running'; managed = $true } }
            StopVM = { param($name) @{ name = $name; state = 'Off'; managed = $true } }
            RestartVM = { param($name) @{ name = $name; state = 'Running'; managed = $true } }
            DeleteVM = { param($name) @{ name = $name; deleted = $true } }
        }
    }
}

Describe 'EpicVM agent authentication' {
    It 'compares bearer tokens without accepting a near match' {
        Test-EpicVMBearerToken -ProvidedToken 'correct-token' -ExpectedToken 'correct-token' | Should -BeTrue
        Test-EpicVMBearerToken -ProvidedToken 'correct-toke' -ExpectedToken 'correct-token' | Should -BeFalse
        Test-EpicVMBearerToken -ProvidedToken 'correct-tokenx' -ExpectedToken 'correct-token' | Should -BeFalse
        Test-EpicVMBearerToken -ProvidedToken '' -ExpectedToken 'correct-token' | Should -BeFalse
    }

    It 'requires the bearer token and never echoes it in the error response' {
        $state = New-EpicVMAgentState -Config (Get-EpicVMDefaultConfig) -Token 'test-secret-token' -Provider (New-TestProvider)
        $response = Invoke-EpicVMApiRequest -State $state -Method 'GET' -Path '/v1/health' -Headers @{ Authorization = 'Bearer wrong-token' }

        $response.StatusCode | Should -Be 401
        ($response.Body | ConvertTo-Json -Depth 10) | Should -Not -Match 'test-secret-token'
        ($response.Body | ConvertTo-Json -Depth 10) | Should -Not -Match 'wrong-token'
    }
}

Describe 'EpicVM agent capabilities and routing' {
    BeforeEach {
        $config = Get-EpicVMDefaultConfig
        $config.Provider = 'Mock'
        $script:state = New-EpicVMAgentState -Config $config -Token 'test-secret-token' -Provider (New-TestProvider)
    }

    It 'returns JSON-ready capabilities for an authenticated request' {
        $response = Invoke-EpicVMApiRequest -State $state -Method 'GET' -Path '/v1/capabilities' -Headers @{ Authorization = 'Bearer test-secret-token' }

        $response.StatusCode | Should -Be 200
        $response.Body.provider | Should -Be 'Mock'
        $response.Body.available | Should -BeTrue
    }

    It 'rejects unknown routes with a clean JSON error' {
        $response = Invoke-EpicVMApiRequest -State $state -Method 'GET' -Path '/v1/does-not-exist' -Headers @{ Authorization = 'Bearer test-secret-token' }

        $response.StatusCode | Should -Be 404
        $response.Body.error.code | Should -Be 'not_found'
    }

    It 'uses the documented lifecycle routes and DELETE verb' {
        $start = Invoke-EpicVMApiRequest -State $state -Method 'POST' -Path '/v1/vms/alpha/start' -Headers @{ Authorization = 'Bearer test-secret-token' }
        $delete = Invoke-EpicVMApiRequest -State $state -Method 'DELETE' -Path '/v1/vms/alpha' -Headers @{ Authorization = 'Bearer test-secret-token' }

        $start.StatusCode | Should -Be 200
        $delete.StatusCode | Should -Be 200
        $delete.Body.ok | Should -BeTrue
    }

    It 'invalidates stale Gaming visual and input evidence after a VM lifecycle transition' {
        $config = Get-EpicVMDefaultConfig
        $config.Provider = 'Mock'
        $config.ProvisioningStatePath = Join-Path $TestDrive 'lifecycle-jobs.json'
        $lifecycleState = New-EpicVMAgentState -Config $config -Token 'test-secret-token' -Provider (New-TestProvider)
        $job = New-EpicVMProvisioningJobObject -Id 'gaming-lifecycle-job' -Name 'alpha' -Profile 'gaming' -State 'ready'
        $job.claimConsumed = $true
        $job.claimUsed = $true
        $job.vmId = 'c7fd609d-5850-4f03-9a58-b425d8696711'
        $job.tailnetIp = '100.111.87.90'
        $job.consoleRoutePrefix = '/vm/alpha--epic-pc/'
        $job.consoleVerifiedAt = [DateTime]::UtcNow.ToString('o')
        $job.consoleFrameVerified = $true
        $job.keyboardInputVerified = $true
        $job.mouseInputVerified = $true
        $job.streamValidationVerified = $true
        $job.gamingCaptureConfigured = $true
        $job.completedStages = @('claim','guest_setup','network_setup','management_handoff','gaming_gpu','streaming_setup','stream_validation')
        $lifecycleState.Provisioning.Jobs[$job.id] = $job

        $response = Invoke-EpicVMApiRequest -State $lifecycleState -Method 'POST' -Path '/v1/vms/alpha/restart' -Headers @{ Authorization = 'Bearer test-secret-token' }

        $response.StatusCode | Should -Be 200
        $job.state | Should -Be 'streaming_setup'
        $job.streamValidationVerified | Should -BeFalse
        $job.consoleFrameVerified | Should -BeFalse
        $job.keyboardInputVerified | Should -BeFalse
        $job.mouseInputVerified | Should -BeFalse
        $job.consoleVerifiedAt | Should -BeNullOrEmpty
        $job.completedStages | Should -Not -Contain 'stream_validation'
        $job.gamingCaptureConfigured | Should -BeTrue
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Match 'vm_restart_requires_reverification'
    }

    It 'validates VM names against the public contract' {
        $longName = ('a' * 63) -join ''
        foreach ($name in @('alpha', 'dev.box-01', $longName)) {
            Test-EpicVMName -Name $name | Should -BeTrue
        }

        $tooLongName = ('a' * 64) -join ''
        foreach ($name in @('', 'Aalpha', '-alpha', 'alpha/', $tooLongName, 'alpha name')) {
            Test-EpicVMName -Name $name | Should -BeFalse
        }
    }
}

Describe 'EpicVM provider selection' {
    It 'selects the configured Hyper-V adapter and rejects unknown providers' {
        $config = Get-EpicVMDefaultConfig
        $config.Provider = 'HyperV'
        $provider = New-EpicVMProvider -Config $config -CommandInvoker { param($commandName, $parameters) @() }
        $provider.Name | Should -Be 'HyperV'

        $config.Provider = 'OtherProvider'
        { New-EpicVMProvider -Config $config } | Should -Throw '*Unsupported provider*'
    }
}

Describe 'EpicVM agent binding defaults' {
    It 'does not default to an all-interface listener' {
        (Get-EpicVMDefaultConfig).BindAddress | Should -Not -Be '0.0.0.0'
    }

    It 'bounds request bodies before JSON dispatch' {
        $stream = [System.IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('12345'))
        try {
            $result = Read-EpicVMBoundedBody -Stream $stream -MaxBytes 4
        }
        finally {
            $stream.Dispose()
        }
        $result.TooLarge | Should -BeTrue
    }

    It 'accepts only Tailscale or loopback addresses' {
        Test-EpicVMBindAddress -Address '100.64.12.34' | Should -BeTrue
        Test-EpicVMBindAddress -Address '127.0.0.1' | Should -BeTrue
        Test-EpicVMBindAddress -Address '192.168.1.20' | Should -BeFalse
        Test-EpicVMBindAddress -Address '0.0.0.0' | Should -BeFalse
    }

    It 'contains client disconnect failures without throwing from response emission' {
        $response = [EpicVMThrowingHttpResponse]::new()

        { Write-EpicVMSafeHttpResponse -Response $response -StatusCode 500 -Json '{"ok":false}' -RequestId 'request-test' } | Should -Not -Throw
        (Write-EpicVMSafeHttpResponse -Response $response -StatusCode 500 -Json '{"ok":false}' -RequestId 'request-test') | Should -BeFalse
    }

    It 'ships a guided Windows setup wrapper' {
        $setupPath = Join-Path $windowsRoot 'setup.ps1'
        Test-Path -LiteralPath $setupPath | Should -BeTrue
        $setup = Get-Content -LiteralPath $setupPath -Raw
        $setup | Should -Match 'TailscaleAddress'
        $setup | Should -Match 'SwitchName'
        $setup | Should -Match 'install.ps1'
    }

    It 'keeps the PowerShell agent behind the NSSM service wrapper' {
        $install = Get-Content -LiteralPath (Join-Path $windowsRoot 'install.ps1') -Raw
        $install | Should -Match 'nssm\.exe'
        $install | Should -Match 'AppParameters'
        $install | Should -Not -Match 'New-Service'
    }

    It 'ships a downloader that invokes guided setup' {
        $downloadPath = Join-Path $windowsRoot 'download-setup.ps1'
        Test-Path -LiteralPath $downloadPath | Should -BeTrue
        $download = Get-Content -LiteralPath $downloadPath -Raw
        $download | Should -Match 'Invoke-WebRequest'
        $download | Should -Match 'setup.ps1'
        $download | Should -Match 'RemoteVM'
    }
}

Describe 'EpicVM agent shared games endpoint' {
    BeforeAll {
        $catalogMissingSize = '{"library":"test","version":2,"games":[' +
            '{"id":"g1","title":"No Size","platform":"windows","version":"1","exe":"C:/definitely/missing/g1.exe"},' +
            '{"id":"g2","title":"Has Size","platform":"windows","version":"2","exe":"C:/definitely/missing/g2.exe","sizeBytes":123456}]}'
    }

    It 'returns every catalog entry even when optional fields are missing' {
        $config = Get-EpicVMDefaultConfig
        $config.Provider = 'Mock'
        $config.CatalogPath = Join-Path (Get-PSDrive TestDrive).Root 'catalog.json'
        Set-Content -LiteralPath $config.CatalogPath -Value $catalogMissingSize -Encoding UTF8

        $state = New-EpicVMAgentState -Config $config -Token 'test-secret-token' -Provider (New-TestProvider)
        $response = Invoke-EpicVMApiRequest -State $state -Method 'GET' -Path '/v1/games' -Headers @{ Authorization = 'Bearer test-secret-token' }

        $response.StatusCode | Should -Be 200
        $response.Body.ok | Should -BeTrue
        $response.Body.games.Count | Should -Be 2
        $response.Body.games[0].id | Should -Be 'g1'
        $response.Body.games[0].sizeBytes | Should -Be 0
        $response.Body.games[0].available | Should -BeFalse
        $response.Body.games[1].sizeBytes | Should -Be 123456
    }

    It 'serves an empty list when the catalog file is absent instead of erroring' {
        $config = Get-EpicVMDefaultConfig
        $config.Provider = 'Mock'
        $config.CatalogPath = Join-Path (Get-PSDrive TestDrive).Root 'missing-catalog.json'

        $state = New-EpicVMAgentState -Config $config -Token 'test-secret-token' -Provider (New-TestProvider)
        $response = Invoke-EpicVMApiRequest -State $state -Method 'GET' -Path '/v1/games' -Headers @{ Authorization = 'Bearer test-secret-token' }

        $response.StatusCode | Should -Be 200
        $response.Body.ok | Should -BeTrue
        $response.Body.games | Should -BeNullOrEmpty
    }

    It 'marks unresolvable UNC exes unavailable without probing the network path' {
        $config = Get-EpicVMDefaultConfig
        $config.Provider = 'Mock'
        $config.CatalogPath = Join-Path (Get-PSDrive TestDrive).Root 'unc-catalog.json'
        Set-Content -LiteralPath $config.CatalogPath -Value '{"library":"test","version":2,"games":[{"id":"u1","title":"Unc Game","platform":"windows","version":"1","exe":"\\\\no-such-host-epicvm\\share$\\games\\g.exe"}]}' -Encoding UTF8

        $state = New-EpicVMAgentState -Config $config -Token 'test-secret-token' -Provider (New-TestProvider)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-EpicVMApiRequest -State $state -Method 'GET' -Path '/v1/games' -Headers @{ Authorization = 'Bearer test-secret-token' }
        $sw.Stop()

        $response.StatusCode | Should -Be 200
        $response.Body.games.Count | Should -Be 1
        $response.Body.games[0].available | Should -BeFalse
        ($sw.ElapsedMilliseconds -lt 15000) | Should -BeTrue
    }
}

Describe 'EpicVM tailscale stale device sweep' {
    BeforeAll {
        $script:testDevices = @(
            @{ id = 'dev-old'; hostname = 'reusedvm'; addresses = @('100.64.0.9') },
            @{ id = 'dev-live'; hostname = 'reusedvm'; addresses = @('100.64.0.10') },
            @{ id = 'dev-broken'; hostname = 'reusedvm'; addresses = @('100.64.0.11') },
            @{ id = ''; hostname = 'reusedvm' }
        )
    }

    It 'selects only same-hostname records, skipping blanks and the kept device' {
        $stale = Get-EpicVMTailscaleStaleDeviceIds -Devices $testDevices -VmName 'reusedvm' -KeepDeviceId 'dev-live'
        $stale | Should -Be 'dev-old','dev-broken'
    }

    It 'handles null devices and missing hostnames without throwing' {
        { Get-EpicVMTailscaleStaleDeviceIds -Devices $null -VmName 'x' -KeepDeviceId '' } | Should -Not -Throw
        Get-EpicVMTailscaleStaleDeviceIds -Devices $null -VmName 'x' -KeepDeviceId '' | Should -BeNullOrEmpty
    }

    It 'sweeps stale devices via the API and reports failures per device' {
        $calls = New-Object System.Collections.Generic.List[object]
        $provider = [pscustomobject]@{
            TailscaleTailnet = '-'
            TailscaleOAuthClientId = 'cid'
            TailscaleOAuthSecretPath = 'unused-path'
            TailscaleApiBaseUrl = 'https://api.test/api/v2'
            TailscaleOAuthInvoker = { param($body) @{ access_token = 'token-x' } }
            TailscaleHttpInvoker = {
                param($Method, $Url, $Headers, $Body)
                $calls.Add(@{ Method = $Method; Url = $Url }) | Out-Null
                if ($Method -eq 'GET') { return @{ devices = $script:testDevices } }
                if ($Url -like '*device/dev-old*') { return @{ ok = $true } }
                throw 'tailscale api 500'
            }
        }
        $result = Clear-EpicVMTailscaleStaleDevices -Provider $provider -VmName 'reusedvm' -KeepDeviceId 'dev-live' -AccessToken 'token-x'

        $result.ok | Should -BeTrue
        $result.skipped | Should -Be ''
        $result.revoked | Should -Be 'dev-old'
        $result.failed | Should -Be 'dev-broken'
        $deletes = @($calls | Where-Object { $_.Method -eq 'DELETE' })
        $deletes.Count | Should -Be 2
        (@($deletes | Where-Object { $_.Url -like '*dev-live*' })).Count | Should -Be 0
    }

    It 'reports a tailnet skip instead of calling the API when unconfigured' {
        $called = $false
        $provider = [pscustomobject]@{
            TailscaleTailnet = ''
            TailscaleOAuthClientId = ''
            TailscaleOAuthSecretPath = ''
            TailscaleHttpInvoker = { param($m,$u,$h,$b) $script:called = $true; return @{} }
        }
        $result = Clear-EpicVMTailscaleStaleDevices -Provider $provider -VmName 'x'
        $result.skipped | Should -Be 'tailnet_not_configured'
        $called | Should -BeFalse
    }
}
