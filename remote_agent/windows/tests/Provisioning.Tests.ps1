# Requires -Version 7.0
# Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'EpicVM.Agent.ps1') -NoStart

    function New-ProvisioningTestProvider {
        [pscustomobject]@{
            Name='Mock'
            GetVMs={ @() }
            CreateVM={ param($request) @{ name=$request.name; state='Off'; managed=$true } }
            StartVM={ param($name) @{ name=$name; state='Running'; managed=$true } }
            TestBootstrapGuest={ param($name,$timeout,$poll) $true }
            StopVM={ param($name) @{ name=$name; state='Off'; managed=$true } }
            DeleteVM={ param($name) @{ name=$name; deleted=$true } }
        }
    }
}

Describe 'EpicVM provisioning safety' {
    It 'skips the expensive content hash only for capability readiness' {
        $text = Get-Content (Join-Path $windowsRoot 'Provisioning.ps1') -Raw
        $text | Should -Match 'Test-EpicVMTemplateManifest -Config \$Config -SkipContentHash'
        $text | Should -Match 'if \(-not \$SkipContentHash\)'
        $text | Should -Match 'Test-EpicVMTemplateManifest -Config \$State\.Config\)'
    }

    It 'requires bootstrap readiness before issuing a one-time claim' {
        $text = Get-Content (Join-Path $windowsRoot 'Provisioning.ps1') -Raw
        $text | Should -Match 'TestBootstrapGuest'
        $text | Should -Match 'guest_bootstrap_not_ready'
        $text | Should -Match 'Guest.*10-minute|\$Job\.name 600 1000'
    }

    It 'allows retry only for an unclaimed preclaim failure' {
        $preclaim = [pscustomobject]@{
            state = 'setup_failed:preclaim'
            claimConsumed = $false
            claimUsed = $false
            failureStage = 'preclaim'
        }
        $consumed = [pscustomobject]@{
            state = 'setup_failed:guest'
            claimConsumed = $true
            claimUsed = $true
            failureStage = 'guest'
        }
        $active = [pscustomobject]@{
            state = 'booting'
            claimConsumed = $false
            claimUsed = $false
            failureStage = ''
        }

        (Test-EpicVMProvisioningJobRetryable -Job $preclaim) | Should -BeTrue
        (Test-EpicVMProvisioningJobRetryable -Job $consumed) | Should -BeFalse
        (Test-EpicVMProvisioningJobRetryable -Job $active) | Should -BeFalse
    }

    It 'uses the locked standard and gaming resource profiles' {
        (Get-EpicVMProvisioningProfile -Profile standard).cpuCount | Should -Be 4
        (Get-EpicVMProvisioningProfile -Profile standard).memoryBytes | Should -Be 8589934592
        (Get-EpicVMProvisioningProfile -Profile standard).diskSizeBytes | Should -Be 103079215104
        (Get-EpicVMProvisioningProfile -Profile gaming).cpuCount | Should -Be 6
        (Get-EpicVMProvisioningProfile -Profile gaming).gpuPartition | Should -Be '50%'
        (Get-EpicVMDefaultConfig).VmRoot | Should -Be 'E:\EpicVM\vms'
    }

    It 'fails closed when the template manifest is absent' {
        $config=Get-EpicVMDefaultConfig
        $config.TemplateManifestPath=Join-Path $TestDrive 'missing.json'
        (Test-EpicVMTemplateManifest -Config $config) | Should -BeFalse
        (Test-EpicVMProvisioningPrerequisites -Config $config) | Should -BeFalse
    }

    It 'persists only redacted job fields and never claim material' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'jobs.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)
        $job=New-EpicVMProvisioningJob -State $state -Request @{ name='alpha'; profile='standard'; username='operator'; password='never-persist-this' }
        $raw=Get-Content -LiteralPath $config.ProvisioningStatePath -Raw
        $raw | Should -Not -Match 'never-persist-this'
        (ConvertTo-EpicVMRedactedJob -Job $job).Keys | Should -Not -Contain 'password'
        $job.failureDetailCode='account_create_failed'
        (ConvertTo-EpicVMRedactedJob -Job $job).failureDetailCode | Should -Be 'account_create_failed'
    }

    It 'requires exact-name confirmation before teardown' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'jobs.json'
        $provider=New-ProvisioningTestProvider
        $provider.GetVMs={ @(@{ name='alpha'; state='Off'; managed=$true }) }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        { New-EpicVMDeprovisioningJob -State $state -Request @{ name='alpha'; confirmName='ALPHA' } } | Should -Throw
    }

    It 'keeps gaming provisioning fail closed before the GPU-P pilot' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-jobs.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)
        { New-EpicVMProvisioningJob -State $state -Request @{ name='gaming-one'; profile='gaming' } } | Should -Throw
    }

    It 'uses a two-phase credential-free console completion gate' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'two-phase-jobs.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { param($name,$username,$password) @{ok=$true} }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password) @{ok=$true;ip='100.111.82.1';deviceId='device-1';managementReady=$true;managementTransport='tailscale_winrm'} }
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $ip -eq '100.111.82.1' }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-1' -Name 'alpha' -Profile 'standard' -State 'unclaimed'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'single-use'
        $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job
        $state.Provisioning.Claims[$job.id]=$job

        Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='single-use';username='operator';password='transient-password'}
        $job.state | Should -Be 'streaming_setup'
        $job.claimConsumed | Should -BeTrue
        $job.operationId | Should -Match '^[0-9a-f]{32}$'
        $job.completedStages | Should -Be @('claim','guest_setup','network_setup','management_handoff')
        $job.claimHash | Should -BeNullOrEmpty
        { Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='single-use';username='operator';password='transient-password'} } | Should -Throw
        $job.failureStage='streaming'
        $job.failureDetailCode='GAMING_GPU_WEBGL'
        $job.lastAttemptCode='guest_reverification_failed'
        $job.errorCode='guest_reverification_failed'
        $job.errorMessage='stale console failure'
        Complete-EpicVMProvisioningConsole -State $state -Job $job -Request @{
            routePrefix='/vm/alpha/'
            guestTcpVerified=$true
        }
        $job.failureDetailCode | Should -BeNullOrEmpty
        $job.lastAttemptCode | Should -BeNullOrEmpty
        $job.errorCode | Should -BeNullOrEmpty
        $job.errorMessage | Should -BeNullOrEmpty
        $job.state | Should -Be 'ready'
        $job.consoleRoutePrefix | Should -Be '/vm/alpha/'
        $job.streamValidationVerified | Should -BeTrue
        $job.completedStages | Should -Be @('claim','guest_setup','network_setup','management_handoff','streaming_setup','stream_validation')
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|single-use'
    }

    It 'automatically recovers a post-enrollment network failure before returning claim failure' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'automatic-network-recovery.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { param($name,$username,$password) @{ok=$true} }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password) throw (New-EpicVMProvisioningError -Code 'tailscale_enrollment_failed' -Message 'simulated post-enrollment verification race' -Status 422) }
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args)
            if($scriptBlock.ToString() -match 'Get-NetIPAddress') { return @{ok=$true;ip='100.111.82.1'} }
            return @{ok=$true;managementEndpoint=$true;firewallScoped=$true}
        }
        $provider | Add-Member NoteProperty TailscaleOAuthClientId 'client-id'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretPath 'mock://oauth-secret'
        $provider | Add-Member NoteProperty TailscaleTailnet 'example.ts.net'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretLoader { [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
        $provider | Add-Member NoteProperty TailscaleOAuthInvoker { @{access_token='access'} }
        $provider | Add-Member NoteProperty TailscaleHttpInvoker { param($method,$url,$headers,$body) @{devices=@(@{id='device-auto';hostname='automatic-recovery';addresses=@('100.111.82.1')})} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-automatic-network-recovery' -Name 'automatic-recovery' -Profile 'standard' -State 'unclaimed'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'automatic-claim'; $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job; $state.Provisioning.Claims[$job.id]=$job

        { Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='automatic-claim';username='operator';password='transient-password'} } | Should -Not -Throw

        $job.state | Should -Be 'streaming_setup'
        $job.tailnetIp | Should -Be '100.111.82.1'
        $job.tailnetDeviceId | Should -Be 'device-auto'
        $job.managementTransport | Should -Be 'tailscale_winrm'
        $job.completedStages | Should -Be @('claim','guest_setup','network_setup','management_handoff')
        $job.claimConsumed | Should -BeTrue
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|automatic-claim'
    }

    It 'returns one successful API response when automatic network recovery succeeds' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'automatic-network-recovery-api.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { param($name,$username,$password) @{ok=$true} }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password) throw (New-EpicVMProvisioningError -Code 'tailscale_enrollment_failed' -Message 'simulated post-enrollment verification race' -Status 422) }
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args)
            if($scriptBlock.ToString() -match 'Get-NetIPAddress') { return @{ok=$true;ip='100.111.82.1'} }
            return @{ok=$true;managementEndpoint=$true;firewallScoped=$true}
        }
        $provider | Add-Member NoteProperty TailscaleOAuthClientId 'client-id'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretPath 'mock://oauth-secret'
        $provider | Add-Member NoteProperty TailscaleTailnet 'example.ts.net'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretLoader { [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
        $provider | Add-Member NoteProperty TailscaleOAuthInvoker { @{access_token='access'} }
        $provider | Add-Member NoteProperty TailscaleHttpInvoker { param($method,$url,$headers,$body) @{devices=@(@{id='device-auto-api';hostname='automatic-recovery-api';addresses=@('100.111.82.1')})} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-automatic-network-recovery-api' -Name 'automatic-recovery-api' -Profile 'standard' -State 'unclaimed'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'automatic-api-claim'; $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job; $state.Provisioning.Claims[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        $response=Invoke-EpicVMApiRequest -State $state -Method 'POST' -Path ('/v1/provisioning-jobs/{0}/claim' -f $job.id) -Headers @{Authorization='Bearer agent-token'} -Body (@{claimToken='automatic-api-claim';username='operator';password='transient-password'} | ConvertTo-Json)

        @($response).Count | Should -Be 1
        $response.StatusCode | Should -Be 200
        $response.Body.ok | Should -BeTrue
        $response.Body.job.state | Should -Be 'streaming_setup'
        $response.Json | Should -Not -Match 'transient-password|automatic-api-claim'
    }

    It 'rejects automated console completion without verified guest transport' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'console-evidence-required.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $true }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'console-evidence-required' -Name 'evidence-required' -Profile 'standard' -State 'streaming_setup'
        $job.claimConsumed=$true
        $job.claimUsed=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff')
        $state.Provisioning.Jobs[$job.id]=$job

        { Complete-EpicVMProvisioningConsole -State $state -Job $job -Request @{routePrefix='/vm/evidence-required--epic-pc/';guestTcpVerified=$false} } | Should -Throw
        $job.state | Should -Not -Be 'ready'
        $job.streamValidationVerified | Should -BeFalse
    }

    It 'persists automated route readiness without manual keyboard or mouse evidence' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'console-evidence-persisted.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $true }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'console-evidence-persisted' -Name 'evidence-persisted' -Profile 'standard' -State 'streaming_setup'
        $job.claimConsumed=$true
        $job.claimUsed=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff')
        $state.Provisioning.Jobs[$job.id]=$job

        Complete-EpicVMProvisioningConsole -State $state -Job $job -Request @{
            routePrefix='/vm/evidence-persisted--epic-pc/'
            guestTcpVerified=$true
        }
        $job.state | Should -Be 'ready'
        $job.consoleFrameVerified | Should -BeFalse
        $job.keyboardInputVerified | Should -BeFalse
        $job.mouseInputVerified | Should -BeFalse
        $job.streamValidationVerified | Should -BeTrue
        (ConvertTo-EpicVMRedactedJob -Job $job).streamValidationVerified | Should -BeTrue
    }

    It 'accepts a validated host-scoped console route' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'scoped-route-jobs.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $true }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'scoped-job' -Name 'alpha' -Profile 'standard' -State 'streaming_setup'
        $job.claimConsumed=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff')
        $state.Provisioning.Jobs[$job.id]=$job
        Complete-EpicVMProvisioningConsole -State $state -Job $job -Request @{
            routePrefix='/vm/alpha--epic-pc/'
            guestTcpVerified=$true
        }
        $job.state | Should -Be 'ready'
        $job.consoleRoutePrefix | Should -Be '/vm/alpha--epic-pc/'
    }

    It 'retains a VM after a post-claim guest mutation failure' {
        $script:deletedAfterClaim=$false
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'retained-jobs.json'
        $provider=New-ProvisioningTestProvider
        $provider.DeleteVM={ param($name) $script:deletedAfterClaim=$true }
        $provider | Add-Member NoteProperty ConfigureGuest { throw 'guest mutation failed' }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-2' -Name 'retained' -Profile 'standard' -State 'unclaimed'
        $job.vmId='retained'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'single-use'
        $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job
        $state.Provisioning.Claims[$job.id]=$job
        { Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='single-use';username='operator';password='transient-password'} } | Should -Throw
        $job.state | Should -Be 'setup_failed:guest'
        $job.errorCode | Should -Be 'guest_account_failed'
        $job.claimConsumed | Should -BeTrue
        $script:deletedAfterClaim | Should -BeFalse
    }

    It 'retains the consumed claim and exposes only an allowlisted guest detail' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'guest-detail.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { throw (New-EpicVMHyperVError -Code 'guest_account_failed' -Message 'safe' -DetailCode 'account_create_failed') }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-detail' -Name 'detail' -Profile 'standard' -State 'unclaimed'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'detail-claim'; $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job; $state.Provisioning.Claims[$job.id]=$job
        try { Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='detail-claim';username='operator';password='transient-password'} } catch { }
        $job.errorCode | Should -Be 'guest_account_failed'
        $job.failureDetailCode | Should -Be 'account_create_failed'
        $job.claimConsumed | Should -BeTrue
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|operator'
    }

    It 'keeps the credential-free console gate stable across agent restart recovery' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'restart-jobs.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)
        $awaiting=New-EpicVMProvisioningJobObject -Id 'job-restart-1' -Name 'alpha' -Profile 'standard' -State 'streaming_setup'
        $awaiting.tailnetIp='100.111.82.1'
        $awaiting.completedStages=@('claim','guest_setup','network_setup')
        $inFlight=New-EpicVMProvisioningJobObject -Id 'job-restart-2' -Name 'beta' -Profile 'standard' -State 'guest_setup'
        $state.Provisioning.Jobs[$awaiting.id]=$awaiting
        $state.Provisioning.Jobs[$inFlight.id]=$inFlight
        Invoke-EpicVMProvisioningRecovery -State $state
        $awaiting.state | Should -Be 'streaming_setup'
        $awaiting.errorCode | Should -BeNullOrEmpty
        $inFlight.state | Should -Be 'setup_failed:agent_restart'
        $inFlight.errorCode | Should -Be 'agent_restarted'
    }

    It 'preserves a completed ready checkpoint across a transient restart re-verification failure' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'ready-recovery-jobs.json'
        $provider=New-ProvisioningTestProvider
        $provider.GetVMs={ @(@{ name='alpha'; state='Running'; managed=$true }) }
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $false }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-ready-recovery' -Name 'alpha' -Profile 'standard' -State 'ready'
        $job.claimConsumed=$true
        $job.claimUsed=$true
        $job.vmId='c7fd609d-5850-4f03-9a58-b425d8696711'
        $job.tailnetIp='100.111.82.1'
        $job.tailnetDeviceId='device-ready-recovery'
        $job.managementTransport='tailscale_winrm'
        $job.managementReadyAt=[DateTime]::UtcNow.AddMinutes(-3).ToString('o')
        $job.consoleRoutePrefix='/vm/alpha--epic-pc/'
        $job.consoleVerifiedAt=[DateTime]::UtcNow.AddMinutes(-2).ToString('o')
        $job.streamValidationVerified=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','streaming_setup','stream_validation')
        $job.failureStage='streaming'
        $job.failureDetailCode='GAMING_GPU_WEBGL'
        $job.lastAttemptCode='guest_reverification_failed'
        $job.errorCode='guest_reverification_failed'
        $job.errorMessage='stale console failure'
        $state.Provisioning.Jobs[$job.id]=$job

        Invoke-EpicVMProvisioningRecovery -State $state

        $job.state | Should -Be 'ready'
        $job.errorCode | Should -BeNullOrEmpty
        $job.failureStage | Should -BeNullOrEmpty
        $job.failureDetailCode | Should -BeNullOrEmpty
        $job.lastAttemptCode | Should -BeNullOrEmpty
        $job.errorMessage | Should -BeNullOrEmpty
        $job.consoleRoutePrefix | Should -Be '/vm/alpha--epic-pc/'
    }

    It 'persists a canonical rejection of legacy ready records missing the validated stream gate' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'legacy-ready-recovery.json'
        @([ordered]@{
            id='legacy-ready-job'
            name='legacy-ready'
            profile='standard'
            state='ready'
            completedStages=@('claim','guest_setup','network_setup','management_handoff','streaming_setup','stream_validation')
            claimConsumed=$true
            claimUsed=$true
            consoleVerifiedAt='2026-08-20T00:00:00Z'
            consoleRoutePrefix='/vm/legacy-ready--epic-pc/'
            tailnetIp='100.111.82.1'
        } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $config.ProvisioningStatePath -Encoding UTF8

        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)
        $job=$state.Provisioning.Jobs['legacy-ready-job']
        $persisted=@(Get-Content -LiteralPath $config.ProvisioningStatePath -Raw | ConvertFrom-Json | Select-Object -First 1)

        $job.state | Should -Be 'setup_failed:legacy_state_uncertain'
        $persisted.state | Should -Be 'setup_failed:legacy_state_uncertain'
        $persisted.errorCode | Should -Be 'legacy_state_uncertain'
        $persisted.consoleFrameVerified | Should -BeFalse
        $persisted.keyboardInputVerified | Should -BeFalse
        $persisted.mouseInputVerified | Should -BeFalse
    }

    It 'does not let reconcile-only Sunshine setup promote a failed job to ready' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'failed-reconcile.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureSunshine { param($name,$guestUsername,$guestPassword,$sunshineUsername,$sunshinePassword,$guestAddress,$managementCheckpoint,$managementAlreadyVerified,$isGaming)
            @{ok=$true;managementReady=$true;managementTransport='tailscale_winrm';gamingCaptureConfigured=$true}
        }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-failed-reconcile' -Name 'failed-reconcile' -Profile 'gaming' -State 'setup_failed:streaming'
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff')
        $job.claimConsumed=$true; $job.claimUsed=$true
        $state.Provisioning.Jobs[$job.id]=$job

        Set-EpicVMProvisioningConsoleCredentials -State $state -Job $job -Request @{
            reconcileOnly=$true; username='operator'; password='guest-pass'; sunshineUsername='sun-user'; sunshinePassword='sun-pass'
        }

        $job.state | Should -Be 'setup_failed:streaming'
        $job.gamingCaptureConfigured | Should -BeTrue
        $job.consoleRepairOutcome | Should -BeNullOrEmpty
    }

    It 'rejects reconcile-only setup for a legacy ready record without automated readiness evidence' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'legacy-ready-reconcile.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureSunshine { throw 'ConfigureSunshine must not run for legacy ready state' }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-legacy-ready' -Name 'legacy-ready-2' -Profile 'gaming' -State 'ready'
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','streaming_setup','stream_validation')
        $job.claimConsumed=$true; $job.claimUsed=$true; $job.streamValidationVerified=$true
        $state.Provisioning.Jobs[$job.id]=$job

        { Set-EpicVMProvisioningConsoleCredentials -State $state -Job $job -Request @{
            reconcileOnly=$true; username='operator'; password='guest-pass'; sunshineUsername='sun-user'; sunshinePassword='sun-pass'
        } } | Should -Throw

        $job.state | Should -Be 'setup_failed:legacy_state_uncertain'
        $job.errorCode | Should -Be 'legacy_state_uncertain'
    }

    It 'allows only an evidenced legacy record to re-enter stage-limited streaming setup' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'legacy-streaming-reconcile.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureSunshine { param($name,$guestUsername,$guestPassword,$sunshineUsername,$sunshinePassword,$guestAddress,$managementCheckpoint,$managementAlreadyVerified,$isGaming)
            $isGaming | Should -BeTrue
            @{ok=$true;managementReady=$true;managementTransport='tailscale_winrm';gamingCaptureConfigured=$true;gamingCaptureAt='2026-08-20T00:00:00Z'}
        }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-legacy-streaming' -Name 'legacy-streaming' -Profile 'gaming' -State 'setup_failed:legacy_state_uncertain'
        $job.vmId='c7fd609d-5850-4f03-9a58-b425d8696711'
        $job.tailnetIp='100.111.82.1'
        $job.tailnetDeviceId='device-legacy'
        $job.managementTransport='tailscale_winrm'
        $job.managementReadyAt=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        $job.claimConsumed=$true; $job.claimUsed=$true
        $job.streamValidationVerified=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','streaming_setup','stream_validation')
        $state.Provisioning.Jobs[$job.id]=$job

        Set-EpicVMProvisioningConsoleCredentials -State $state -Job $job -Request @{
            reconcileOnly=$true; username='operator'; password='guest-pass'; sunshineUsername='sun-user'; sunshinePassword='sun-pass'
        }

        $job.state | Should -Be 'streaming_setup'
        $job.gamingCaptureConfigured | Should -BeTrue
        $job.streamValidationVerified | Should -BeTrue
        $job.consoleVerifiedAt | Should -BeNullOrEmpty
    }

    It 'accepts request-only Sunshine credentials only at the console gate' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'sunshine-jobs.json'
        $script:sunshineReceived=$false
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { param($name,$username,$password) @{ok=$true} }
        $provider | Add-Member NoteProperty ConfigureSunshine { param($name,$guestUsername,$guestPassword,$sunshineUsername,$sunshinePassword) $script:sunshineReceived=($sunshineUsername -eq 'sun-user' -and $sunshinePassword -eq 'sun-pass'); @{ok=$true} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-sunshine' -Name 'sunshine' -Profile 'standard' -State 'streaming_setup'
        $state.Provisioning.Jobs[$job.id]=$job
        $response=Invoke-EpicVMApiRequest -State $state -Method 'POST' -Path '/v1/provisioning-jobs/job-sunshine/console-credentials' -Headers @{Authorization='Bearer agent-token'} -Body (@{username='operator';password='guest-pass';sunshineUsername='sun-user';sunshinePassword='sun-pass'} | ConvertTo-Json)
        $response.StatusCode | Should -Be 200
        $script:sunshineReceived | Should -BeTrue
        $response.Json | Should -Not -Match 'guest-pass|sun-pass'
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'guest-pass|sun-pass'
    }

    It 'persists the Gaming capture marker only after provider validation' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-capture-marker.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureSunshine { param($name,$guestUsername,$guestPassword,$sunshineUsername,$sunshinePassword,$guestAddress,$managementCheckpoint,$managementAlreadyVerified,$isGaming)
            $isGaming | Should -BeTrue
            @{ok=$true;managementReady=$true;managementTransport='tailscale_winrm';gamingCaptureConfigured=$true;gamingCaptureAt='2026-08-20T00:00:00Z'}
        }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-gaming-capture' -Name 'gaming-capture' -Profile 'gaming' -State 'streaming_setup'
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff')
        $state.Provisioning.Jobs[$job.id]=$job

        Set-EpicVMProvisioningConsoleCredentials -State $state -Job $job -Request @{username='operator';password='guest-pass';sunshineUsername='sun-user';sunshinePassword='sun-pass'}

        $job.gamingCaptureConfigured | Should -BeTrue
        $job.gamingCaptureAt | Should -Be '2026-08-20T00:00:00Z'
        $job.state | Should -Be 'streaming_setup'
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Match 'gamingCaptureConfigured'
    }

    It 'fails closed when Gaming capture validation is absent' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-capture-marker-missing.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureSunshine { param($name,$guestUsername,$guestPassword,$sunshineUsername,$sunshinePassword,$guestAddress,$managementCheckpoint,$managementAlreadyVerified,$isGaming)
            @{ok=$true;managementReady=$true;managementTransport='tailscale_winrm'}
        }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-gaming-capture-missing' -Name 'gaming-capture-missing' -Profile 'gaming' -State 'streaming_setup'
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff')
        $state.Provisioning.Jobs[$job.id]=$job

        { Set-EpicVMProvisioningConsoleCredentials -State $state -Job $job -Request @{username='operator';password='guest-pass';sunshineUsername='sun-user';sunshinePassword='sun-pass'} } | Should -Throw
        $job.state | Should -Be 'setup_failed:streaming'
        $job.gamingCaptureConfigured | Should -Not -BeTrue
    }

    It 'exposes a retained read-only Direct diagnostic without mutating the job' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'direct-diagnostic.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty CommandInvoker { param($command,$parameters)
            if($command -eq 'Get-VM'){ return @{Id='5b3c52d1-7fd9-4a85-86f8-467d54fa0710';State='Running'} }
            if($command -eq 'Get-VMIntegrationService'){ return @(@{Name='Heartbeat';OperationalStatus='OK'}) }
            return @()
        }
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args) @{ok=$true} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-direct' -Name 'direct' -Profile 'standard' -State 'setup_failed:streaming'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'; $job.claimConsumed=$true; $job.operationId='0123456789abcdef0123456789abcdef'; $job.errorCode='direct_transport_error'
        $state.Provisioning.Jobs[$job.id]=$job
        $response=Invoke-EpicVMApiRequest -State $state -Method 'POST' -Path '/v1/provisioning-jobs/job-direct/direct-diagnostic' -Headers @{Authorization='Bearer agent-token'} -Body (@{username='operator';password='transient-password'}|ConvertTo-Json)
        $response.StatusCode | Should -Be 200
        $response.Json | Should -Not -Match 'transient-password|operator'
        ($response.Body.diagnostic.code) | Should -BeIn @('ok','direct_not_supported','direct_runtime_failure')
        $job.state | Should -Be 'setup_failed:streaming'
        $job.claimConsumed | Should -BeTrue
    }
}

Describe 'EpicVM guest-stage recovery' {
    It 'recovers a retained consumed guest failure through network and management handoff' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'guest-recovery.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args) @{ok=$true;stage='guest_account_readiness'} }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password) @{ok=$true;ip='100.111.82.1';deviceId='device-recovery';managementReady=$true;managementTransport='tailscale_winrm'} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-guest-recovery' -Name 'recoverable' -Profile 'standard' -State 'setup_failed:guest'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'
        $job.claimConsumed=$true; $job.claimUsed=$true; $job.claimHash=$null
        $job.completedStages=@('claim'); $job.errorCode='guest_account_failed'; $job.failureStage='guest'
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        Invoke-EpicVMProvisioningGuestRecovery -State $state -Job $job -Request @{username='operator';password='transient-password'} | Out-Null

        $job.state | Should -Be 'streaming_setup'
        $job.guestSetupVerified | Should -BeTrue
        $job.managementTransport | Should -Be 'tailscale_winrm'
        $job.completedStages | Should -Be @('claim','guest_setup','network_setup','management_handoff')
        $job.claimConsumed | Should -BeTrue
        $job.claimUsed | Should -BeTrue
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|operator'
    }

    It 'rejects recovery when the consumed guest failure boundary is not exact' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'guest-recovery-reject.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)
        $job=New-EpicVMProvisioningJobObject -Id 'job-guest-recovery-reject' -Name 'not-recoverable' -Profile 'standard' -State 'streaming_setup'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'; $job.claimConsumed=$true; $job.claimUsed=$true; $job.completedStages=@('claim','guest_setup')
        $state.Provisioning.Jobs[$job.id]=$job
        $caught=$null
        try { Invoke-EpicVMProvisioningGuestRecovery -State $state -Job $job -Request @{username='operator';password='transient-password'} } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'guest_recovery_not_allowed'
    }

    It 'exposes guest recovery through the authenticated agent API without returning credentials' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'guest-recovery-api.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args) @{ok=$true;stage='guest_account_readiness'} }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password) @{ok=$true;ip='100.111.82.1';deviceId='device-api-recovery';managementReady=$true;managementTransport='tailscale_winrm'} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-guest-recovery-api' -Name 'api-recoverable' -Profile 'standard' -State 'setup_failed:guest'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'; $job.claimConsumed=$true; $job.claimUsed=$true; $job.claimHash=$null; $job.completedStages=@('claim')
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        $response=Invoke-EpicVMApiRequest -State $state -Method 'POST' -Path '/v1/provisioning-jobs/job-guest-recovery-api/guest-recovery' -Headers @{Authorization='Bearer agent-token'} -Body (@{username='operator';password='transient-password'} | ConvertTo-Json)

        $response.StatusCode | Should -Be 200
        $response.Body.ok | Should -BeTrue
        $response.Body.job.state | Should -Be 'streaming_setup'
        $response.Json | Should -Not -Match 'transient-password|operator'
    }
}

Describe 'EpicVM network-stage recovery' {
    It 'recovers an enrolled retained network failure without issuing a new claim' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'network-recovery.json'
        $script:networkDirectCalls=0
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args)
            $script:networkDirectCalls++
            if($scriptBlock.ToString() -match 'Get-NetIPAddress') { return @{ok=$true;ip='100.111.82.1'} }
            return @{ok=$true;managementEndpoint=$true;firewallScoped=$true}
        }
        $provider | Add-Member NoteProperty TailscaleOAuthClientId 'client-id'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretPath 'mock://oauth-secret'
        $provider | Add-Member NoteProperty TailscaleTailnet 'example.ts.net'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretLoader { [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
        $provider | Add-Member NoteProperty TailscaleOAuthInvoker { @{access_token='access'} }
        $provider | Add-Member NoteProperty TailscaleHttpInvoker { param($method,$url,$headers,$body) @{devices=@(@{id='device-network';hostname='network-recoverable';addresses=@('100.111.82.1')})} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-network-recovery' -Name 'network-recoverable' -Profile 'standard' -State 'setup_failed:network'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'
        $job.claimConsumed=$true; $job.claimUsed=$true; $job.claimHash=$null
        $job.completedStages=@('claim','guest_setup'); $job.guestSetupVerified=$true; $job.errorCode='tailscale_enrollment_failed'; $job.failureStage='network'
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        Invoke-EpicVMProvisioningNetworkRecovery -State $state -Job $job -Request @{username='operator';password='transient-password'} | Out-Null

        $job.state | Should -Be 'streaming_setup'
        $job.tailnetIp | Should -Be '100.111.82.1'
        $job.tailnetDeviceId | Should -Be 'device-network'
        $job.managementTransport | Should -Be 'tailscale_winrm'
        $job.completedStages | Should -Be @('claim','guest_setup','network_setup','management_handoff')
        $job.claimConsumed | Should -BeTrue
        $script:networkDirectCalls | Should -Be 2
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|operator'
    }

    It 'revalidates a ready retained VM when its guest network disappears without reissuing a claim' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'ready-network-recovery.json'
        $script:readyNetworkDirectCalls=0
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args)
            $script:readyNetworkDirectCalls++
            if($scriptBlock.ToString() -match 'Get-NetIPAddress') { return @{ok=$true;ip='100.111.82.2'} }
            return @{ok=$true;managementEndpoint=$true;firewallScoped=$true}
        }
        $provider | Add-Member NoteProperty TailscaleOAuthClientId 'client-id'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretPath 'mock://oauth-secret'
        $provider | Add-Member NoteProperty TailscaleTailnet 'example.ts.net'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretLoader { [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
        $provider | Add-Member NoteProperty TailscaleOAuthInvoker { @{access_token='access'} }
        $provider | Add-Member NoteProperty TailscaleHttpInvoker { param($method,$url,$headers,$body) @{devices=@(@{id='device-ready-network';hostname='ready-network-recoverable';addresses=@('100.111.82.2')})} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-ready-network-recovery' -Name 'ready-network-recoverable' -Profile 'standard' -State 'ready'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'
        $job.claimConsumed=$true; $job.claimUsed=$true; $job.claimHash=$null
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','streaming_setup','stream_validation')
        $job.guestSetupVerified=$true; $job.managementTransport='tailscale_winrm'; $job.managementReadyAt=[DateTime]::UtcNow.ToString('o'); $job.tailnetIp='100.111.82.1'; $job.tailnetDeviceId='device-old-network'
        $job.consoleRoutePrefix='/vm/ready-network-recoverable--epic-pc/'; $job.consoleVerifiedAt=[DateTime]::UtcNow.ToString('o'); $job.streamValidationVerified=$true
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        Invoke-EpicVMProvisioningNetworkRecovery -State $state -Job $job -Request @{username='operator';password='transient-password';reverify=$true} | Out-Null

        $job.state | Should -Be 'streaming_setup'
        $job.tailnetIp | Should -Be '100.111.82.2'
        $job.tailnetDeviceId | Should -Be 'device-ready-network'
        $job.managementTransport | Should -Be 'tailscale_winrm'
        $job.claimConsumed | Should -BeTrue
        $script:readyNetworkDirectCalls | Should -Be 2
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|operator'
    }

    It 'revalidates a retained streaming failure without issuing a new claim' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'streaming-network-recovery.json'
        $script:streamingNetworkDirectCalls=0
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args)
            $script:streamingNetworkDirectCalls++
            if($scriptBlock.ToString() -match 'Get-NetIPAddress') { return @{ok=$true;ip='100.111.82.3'} }
            return @{ok=$true;managementEndpoint=$true;firewallScoped=$true}
        }
        $provider | Add-Member NoteProperty TailscaleOAuthClientId 'client-id'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretPath 'mock://oauth-secret'
        $provider | Add-Member NoteProperty TailscaleTailnet 'example.ts.net'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretLoader { [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
        $provider | Add-Member NoteProperty TailscaleOAuthInvoker { @{access_token='access'} }
        $provider | Add-Member NoteProperty TailscaleHttpInvoker { param($method,$url,$headers,$body) @{devices=@(@{id='device-streaming-network';hostname='streaming-network-recoverable';addresses=@('100.111.82.3')})} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-streaming-network-recovery' -Name 'streaming-network-recoverable' -Profile 'standard' -State 'setup_failed:streaming'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'
        $job.claimConsumed=$true; $job.claimUsed=$true; $job.claimHash=$null
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','streaming_setup')
        $job.guestSetupVerified=$true; $job.managementTransport='tailscale_winrm'; $job.managementReadyAt=[DateTime]::UtcNow.ToString('o'); $job.tailnetIp='100.111.82.1'; $job.tailnetDeviceId='device-old-streaming-network'
        $job.failureStage='streaming'; $job.errorCode='tailscale_unreachable'; $job.errorMessage='Automatic Sunshine setup failed; the VM and stopped console data were retained.'
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        Invoke-EpicVMProvisioningNetworkRecovery -State $state -Job $job -Request @{username='operator';password='transient-password';reverify=$true} | Out-Null

        $job.state | Should -Be 'streaming_setup'
        $job.tailnetIp | Should -Be '100.111.82.3'
        $job.tailnetDeviceId | Should -Be 'device-streaming-network'
        $job.managementTransport | Should -Be 'tailscale_winrm'
        $job.claimConsumed | Should -BeTrue
        $script:streamingNetworkDirectCalls | Should -Be 2
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|operator'
    }

    It 're-enrolls a retained guest when its Tailscale state is lost after reboot' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'streaming-network-reenroll.json'
        $script:reenrollDirectCalls=0
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args)
            $script:reenrollDirectCalls++
            if(@($args).Count -gt 0) { return @{ok=$true;ip='100.111.82.4';deviceId='device-reenrolled'} }
            if($scriptBlock.ToString() -match 'Get-NetIPAddress') { throw 'retained Tailscale state is unavailable' }
            return @{ok=$true;managementEndpoint=$true;firewallScoped=$true}
        }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password)
            @{ok=$true;ip='100.111.82.4';deviceId='device-reenrolled';managementReady=$true;managementTransport='tailscale_winrm'}
        }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-streaming-network-reenroll' -Name 'streaming-network-reenroll' -Profile 'standard' -State 'setup_failed:streaming'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'
        $job.claimConsumed=$true; $job.claimUsed=$true; $job.claimHash=$null
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','streaming_setup')
        $job.guestSetupVerified=$true; $job.managementTransport='tailscale_winrm'; $job.tailnetIp='100.111.82.1'; $job.tailnetDeviceId='device-old-reenroll'
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        Invoke-EpicVMProvisioningNetworkRecovery -State $state -Job $job -Request @{username='operator';password='transient-password';reverify=$true} | Out-Null

        $job.state | Should -Be 'streaming_setup'
        $job.tailnetIp | Should -Be '100.111.82.4'
        $job.tailnetDeviceId | Should -Be 'device-reenrolled'
        $job.managementTransport | Should -Be 'tailscale_winrm'
        $script:reenrollDirectCalls | Should -Be 2
        (Get-Content -LiteralPath $config.ProvisioningStatePath -Raw) | Should -Not -Match 'transient-password|operator'
    }

    It 'rejects network recovery outside the exact retained boundary' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'network-recovery-reject.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)
        $job=New-EpicVMProvisioningJobObject -Id 'job-network-recovery-reject' -Name 'not-recoverable' -Profile 'standard' -State 'streaming_setup'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'; $job.claimConsumed=$true; $job.claimUsed=$true; $job.completedStages=@('claim','guest_setup','network_setup')
        $state.Provisioning.Jobs[$job.id]=$job
        $caught=$null
        try { Invoke-EpicVMProvisioningNetworkRecovery -State $state -Job $job -Request @{username='operator';password='transient-password'} } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'network_recovery_not_allowed'
        $job.state | Should -Be 'streaming_setup'
    }

    It 'exposes network recovery through the authenticated agent API without returning credentials' {
        $config=Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath=Join-Path $TestDrive 'network-recovery-api.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty PowerShellDirectInvoker { param($name,$credential,$scriptBlock,$args) if($scriptBlock.ToString() -match 'Get-NetIPAddress'){@{ok=$true;ip='100.111.82.1'}}else{@{ok=$true;managementEndpoint=$true;firewallScoped=$true}} }
        $provider | Add-Member NoteProperty TailscaleOAuthClientId 'client-id'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretPath 'mock://oauth-secret'
        $provider | Add-Member NoteProperty TailscaleTailnet 'example.ts.net'
        $provider | Add-Member NoteProperty TailscaleOAuthSecretLoader { [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
        $provider | Add-Member NoteProperty TailscaleOAuthInvoker { @{access_token='access'} }
        $provider | Add-Member NoteProperty TailscaleHttpInvoker { param($method,$url,$headers,$body) @{devices=@(@{id='device-api-network';hostname='api-network-recoverable';addresses=@('100.111.82.1')})} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'job-network-recovery-api' -Name 'api-network-recoverable' -Profile 'standard' -State 'setup_failed:network'
        $job.vmId='5b3c52d1-7fd9-4a85-86f8-467d54fa0710'; $job.claimConsumed=$true; $job.claimUsed=$true; $job.claimHash=$null; $job.completedStages=@('claim','guest_setup')
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning

        $response=Invoke-EpicVMApiRequest -State $state -Method 'POST' -Path '/v1/provisioning-jobs/job-network-recovery-api/network-recovery' -Headers @{Authorization='Bearer agent-token'} -Body (@{username='operator';password='transient-password'} | ConvertTo-Json)

        $response.StatusCode | Should -Be 200
        $response.Body.ok | Should -BeTrue
        $response.Body.job.state | Should -Be 'streaming_setup'
        $response.Json | Should -Not -Match 'transient-password|operator'
    }
}

Describe 'EpicVM claim state and migration boundaries' {
    It 'rejects malformed credential input without consuming the claim' {
        $config=Get-EpicVMDefaultConfig; $config.ProvisioningStatePath=Join-Path $TestDrive 'invalid-input.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)
        $job=New-EpicVMProvisioningJobObject -Id 'invalid-input' -Name 'invalid-input' -Profile 'standard' -State 'unclaimed'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'valid-claim'; $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job; $state.Provisioning.Claims[$job.id]=$job
        $caught=$null
        try { Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='valid-claim';username='bad';password=''} } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'invalid_credential_input'
        $job.state | Should -Be 'unclaimed'; $job.claimConsumed | Should -BeFalse; $job.claimHash | Should -Not -BeNullOrEmpty
    }

    It 'normalizes legacy labels without manufacturing checkpoints' {
        $legacy=New-EpicVMProvisioningJobObject -Id 'legacy' -Name 'legacy' -Profile 'standard' -State 'enrolling_tailscale'
        (ConvertTo-EpicVMCanonicalProvisioningState -Record $legacy) | Should -Be 'network_setup'
        $legacy.completedStages | Should -BeNullOrEmpty
        $legacy.state='awaiting_console'
        (ConvertTo-EpicVMCanonicalProvisioningState -Record $legacy) | Should -Be 'setup_failed:legacy_state_uncertain'
    }

    It 'does not resurrect a consumed claim after reload' {
        $config=Get-EpicVMDefaultConfig; $config.ProvisioningStatePath=Join-Path $TestDrive 'consumed.json'
        $job=New-EpicVMProvisioningJobObject -Id 'consumed' -Name 'consumed' -Profile 'standard' -State 'claim_in_progress'
        $job.claimConsumed=$true; $job.claimUsed=$true; $job.operationId='0123456789abcdef0123456789abcdef'; $job.completedStages=@('claim')
        $store=[pscustomobject]@{Path=$config.ProvisioningStatePath;Jobs=@{$job.id=$job};Deprovisioning=@{};Claims=@{}}
        Save-EpicVMProvisioningStore -Store $store
        $reloaded=New-EpicVMProvisioningStore -Config $config
        $reloaded.Claims.ContainsKey($job.id) | Should -BeFalse
        $reloaded.Jobs[$job.id].claimConsumed | Should -BeTrue
    }

    It 'does not consume a claim when the atomic state write fails' {
        $config=Get-EpicVMDefaultConfig; $config.ProvisioningStatePath=Join-Path $TestDrive 'atomic-failure.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { param($name,$username,$password) @{ok=$true} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'atomic-failure' -Name 'atomic-failure' -Profile 'standard' -State 'unclaimed'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'valid-claim'; $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job; $state.Provisioning.Claims[$job.id]=$job
        Mock -CommandName Save-EpicVMProvisioningStore -MockWith { throw 'simulated atomic write failure' }
        $caught=$null
        try { Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='valid-claim';username='operator';password='transient-password'} } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'claim_atomic_commit_failed'
        $job.state | Should -Be 'unclaimed'; $job.claimConsumed | Should -BeFalse
        $job.claimHash | Should -Be (ConvertTo-EpicVMClaimHash 'valid-claim')
        $state.Provisioning.Claims.ContainsKey($job.id) | Should -BeTrue
    }

    It 'serializes concurrent claim owners with the provisioning mutex' {
        $mutex=[Threading.Mutex]::new($false,'Local\EpicVM-ProvisioningState')
        $held=$false
        try {
            $held=$mutex.WaitOne(1000)
            $worker=Start-Job -ScriptBlock {
                $other=[Threading.Mutex]::new($false,'Local\EpicVM-ProvisioningState')
                try { [bool]$other.WaitOne(100) } finally { $other.Dispose() }
            }
            Wait-Job -Job $worker -Timeout 10 | Out-Null
            $acquired=[bool](Receive-Job -Job $worker -ErrorAction Stop | Select-Object -Last 1)
            Remove-Job -Job $worker -Force -ErrorAction SilentlyContinue
            $held | Should -BeTrue
            $acquired | Should -BeFalse
        } finally { if($held){$mutex.ReleaseMutex()};$mutex.Dispose() }
    }

    It 'keeps an expired legacy claim unclaimed only for diagnosis, never for reuse' {
        $legacy=New-EpicVMProvisioningJobObject -Id 'expired-legacy' -Name 'expired-legacy' -Profile 'standard' -State 'awaiting_claim'
        $legacy.claimHash='a' * 64
        $legacy.claimExpires=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        (ConvertTo-EpicVMCanonicalProvisioningState -Record $legacy) | Should -Be 'setup_failed:legacy_state_uncertain'
    }
}

Describe 'EpicVM Gaming provisioning contract' {
    It 'persists requested CPU, memory, storage, and GPU-P percentage at initialization' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-spec.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)

        $job=New-EpicVMProvisioningJob -State $state -Request @{
            name='gaming-spec'
            profile='gaming'
            cpuCount=8
            memoryGiB=14
            diskSizeGiB=160
            gpuPartitionPercent=65
        }

        $job.cpuCount | Should -Be 8
        $job.memoryBytes | Should -Be (14 * 1GB)
        $job.diskSizeBytes | Should -Be (160 * 1GB)
        $job.gpuPartitionPercent | Should -Be 65
        $job.gpuDeviceIdentity | Should -Be 'VEN_1002&DEV_73BF'
    }

    It 'reserves the single Gaming slot and counts active Gaming jobs' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-capacity.json'
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider (New-ProvisioningTestProvider)

        New-EpicVMProvisioningJob -State $state -Request @{name='gaming-one';profile='gaming'} | Out-Null
        { New-EpicVMProvisioningJob -State $state -Request @{name='gaming-two';profile='gaming'} } | Should -Throw
    }

    It 'does not reserve GPU capacity for a stopped guest awaiting console verification' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-stopped-capacity.json'
        $provider=New-ProvisioningTestProvider
        $provider.GetVMs={ @(@{name='retained';id='retained-id';state='Off';profile='gaming'}) }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'retained-job' -Name 'retained' -Profile gaming -State streaming_setup
        $job.vmId='retained-id'
        $state.Provisioning.Jobs[$job.id]=$job
        Save-EpicVMProvisioningStore -Store $state.Provisioning
        $created=New-EpicVMProvisioningJob -State $state -Request @{name='new-gaming';profile='gaming'}
        $created.state | Should -Be queued
        $state.Provisioning.Jobs['retained-job'].vmId | Should -Be 'retained-id'
    }

    It 'allows another Gaming VM to be queued while a ready Gaming VM is running' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-running-capacity.json'
        $provider=New-ProvisioningTestProvider
        $provider.GetVMs={ @(@{name='existing-gaming';id='existing-gaming-id';state='Running';profile='gaming'}) }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider

        $created=New-EpicVMProvisioningJob -State $state -Request @{name='new-gaming';profile='gaming'}

        $created.state | Should -Be queued
        $created.name | Should -Be 'new-gaming'
    }

    It 'requires and records the Gaming guest GPU validation gate before streaming setup' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-validation.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { param($name,$username,$password) @{ok=$true} }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password) @{ok=$true;ip='100.111.82.1';deviceId='gaming-device';managementReady=$true;managementTransport='tailscale_winrm'} }
        $provider | Add-Member NoteProperty ValidateGamingGuest { param($name,$username,$password,$address) @{ok=$true;name=$name;address=$address} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'gaming-validation' -Name 'gaming-validation' -Profile 'gaming' -State 'unclaimed'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'gaming-claim'
        $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job
        $state.Provisioning.Claims[$job.id]=$job

        Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='gaming-claim';username='operator';password='transient-password'}

        $job.state | Should -Be 'streaming_setup'
        $job.gamingGpuValidated | Should -BeTrue
        $job.gamingValidationAt | Should -Not -BeNullOrEmpty
        $job.completedStages | Should -Be @('claim','guest_setup','network_setup','management_handoff','gaming_gpu')
    }

    It 'fails the Gaming job at the GPU stage when validation is not clean' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'gaming-validation-failed.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty ConfigureGuest { param($name,$username,$password) @{ok=$true} }
        $provider | Add-Member NoteProperty EnrollTailscale { param($name,$username,$password) @{ok=$true;ip='100.111.82.1';deviceId='gaming-device';managementReady=$true;managementTransport='tailscale_winrm'} }
        $provider | Add-Member NoteProperty ValidateGamingGuest { param($name,$username,$password,$address) @{ok=$false;failureDetailCode='GAMING_GPU_ENCODER'} }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'gaming-validation-failed' -Name 'gaming-validation-failed' -Profile 'gaming' -State 'unclaimed'
        $job.claimHash=ConvertTo-EpicVMClaimHash 'gaming-failed-claim'
        $job.claimExpires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')
        $state.Provisioning.Jobs[$job.id]=$job
        $state.Provisioning.Claims[$job.id]=$job

        { Invoke-EpicVMProvisioningClaim -State $state -Job $job -Request @{claimToken='gaming-failed-claim';username='operator';password='transient-password'} } | Should -Throw

        $job.state | Should -Be 'setup_failed:gaming_gpu'
        $job.failureStage | Should -Be 'gaming_gpu'
        $job.failureDetailCode | Should -Be 'GAMING_GPU_ENCODER'
        $job.completedStages | Should -Not -Contain 'gaming_gpu'
        $job.state | Should -Not -Be 'streaming_setup'
    }

    It 'withholds gaming readiness without decoded browser metrics' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'frame-metrics-missing.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $true }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'frame-metrics-missing' -Name 'metrics-missing' -Profile 'gaming' -State 'streaming_setup'
        $job.claimConsumed=$true
        $job.claimUsed=$true
        $job.gamingCaptureConfigured=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','gaming_gpu')
        $state.Provisioning.Jobs[$job.id]=$job

        { Complete-EpicVMProvisioningConsole -State $state -Job $job -Request @{
            routePrefix='/vm/metrics-missing--epic-pc/'
            guestTcpVerified=$true
        } } | Should -Throw

        $job.state | Should -Not -Be 'ready'
        $job.streamValidationVerified | Should -BeFalse
        $job.gamingCaptureConfigured | Should -BeTrue
        $job.keyboardInputVerified | Should -BeFalse
        $job.mouseInputVerified | Should -BeFalse
    }

    It 'rejects console completion with invalid frame metrics: <Case>' -ForEach @(
        @{Case='black';Field='nonblackFraction';Value=0.0},
        @{Case='frozen';Field='decodedFramesDelta';Value=0},
        @{Case='infinite';Field='durationMs';Value=[double]::PositiveInfinity},
        @{Case='invalid fraction';Field='nonblackFraction';Value=1.5},
        @{Case='white';Field='meanLuma';Value=255},
        @{Case='invalid deviation';Field='stdDev';Value=130}
    ) {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'frame-metrics-black.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $true }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'frame-metrics-black' -Name 'metrics-black' -Profile 'gaming' -State 'streaming_setup'
        $job.claimConsumed=$true
        $job.claimUsed=$true
        $job.gamingCaptureConfigured=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','gaming_gpu')
        $state.Provisioning.Jobs[$job.id]=$job

        $metrics=@{nonblackFraction=0.74;meanLuma=40.5;stdDev=41.2;decodedFramesDelta=150;durationMs=5000}
        $metrics[$Field]=$Value
        { Complete-EpicVMProvisioningConsole -State $state -Job $job -Request @{
            routePrefix='/vm/metrics-black--epic-pc/'
            guestTcpVerified=$true
            frameMetrics=$metrics
        } } | Should -Throw

        $job.state | Should -Not -Be 'ready'
        $job.streamValidationVerified | Should -BeFalse
    }

    It 'accepts optional frame evidence without setting manual attestations' {
        $config=Get-EpicVMDefaultConfig
        $config.EnableGamingProvisioning=$true
        $config.ProvisioningStatePath=Join-Path $TestDrive 'frame-metrics-good.json'
        $provider=New-ProvisioningTestProvider
        $provider | Add-Member NoteProperty VerifyGuest { param($name,$ip) $true }
        $state=New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider
        $job=New-EpicVMProvisioningJobObject -Id 'frame-metrics-good' -Name 'metrics-good' -Profile 'gaming' -State 'streaming_setup'
        $job.claimConsumed=$true
        $job.claimUsed=$true
        $job.gamingCaptureConfigured=$true
        $job.completedStages=@('claim','guest_setup','network_setup','management_handoff','gaming_gpu')
        $state.Provisioning.Jobs[$job.id]=$job

        Complete-EpicVMProvisioningConsole -State $state -Job $job -Request @{
            routePrefix='/vm/metrics-good--epic-pc/'
            guestTcpVerified=$true
            frameMetrics=@{nonblackFraction=0.7452;meanLuma=40.76;stdDev=41.2;decodedFramesDelta=169;durationMs=5000}
        }

        $job.state | Should -Be 'ready'
        $job.streamValidationVerified | Should -BeTrue
        $job.consoleFrameVerified | Should -BeTrue
        $job.consoleFrameVerifiedAt | Should -Not -BeNullOrEmpty
        # Manual input attestations remain untouched by the automated
        # readiness transition.
        $job.keyboardInputVerified | Should -BeFalse
        $job.mouseInputVerified | Should -BeFalse
    }

    It 'selects the gaming capture configuration only for gaming Sunshine setup' {
        $guestText = Get-Content (Join-Path $windowsRoot 'providers' 'GuestProvider.ps1') -Raw
        $guestText | Should -Match 'function Get-EpicVMGamingSunshineCaptureScript'
        $guestText | Should -Match 'Get-EpicVMSunshineConfigurationScript -ForGaming \(\[bool\]\$IsGaming\)'
        $guestText | Should -Match "friendly_name -eq 'VDD by MTT'"
        $guestText | Should -Match 'output_name = .*displayId'
        $guestText | Should -Match 'encoder = amdvce'
        $guestText | Should -Match 'AutoAdminLogon'
        $guestText | Should -Match 'Root\\MttVDD'
    }
}
