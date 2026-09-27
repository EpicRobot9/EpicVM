#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'EpicVM.Agent.ps1') -NoStart -ConfigPath (Join-Path $windowsRoot 'config.example.json')
}

Describe 'Omarchy provisioning state machine' {
    It 'rejects Omarchy creation while the independent capability gate is disabled' {
        $config = Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath = Join-Path $TestDrive 'omarchy-disabled.json'
        $provider = [pscustomobject]@{
            GetVMs = { @() }
        }
        $state = New-EpicVMAgentState -Config $config -Token 'agent-token' -Provider $provider

        { New-EpicVMProvisioningJob -State $state -Request @{ name = 'omarchy-one'; profile = 'omarchy' } } |
            Should -Throw '*Omarchy provisioning remains disabled*'
    }

    It 'preserves Omarchy resource and GPU identity fields without applying Gaming capacity rules' {
        $config = Get-EpicVMDefaultConfig
        $spec = Get-EpicVMOmarchyProvisioningSpec -Config $config -Request @{
            cpuCount = 8
            memoryGiB = 16
            diskSizeGiB = 256
            gpuPartitionPercent = 65
            gpuDeviceIdentity = 'VEN_1002&DEV_73BF'
        }
        $job = New-EpicVMProvisioningJobObject -Id 'omarchy-job' -Name 'omarchy-one' -Profile 'omarchy'
        $job.cpuCount = $spec.cpuCount
        $job.memoryBytes = $spec.memoryBytes
        $job.diskSizeBytes = $spec.diskSizeBytes
        $job.gpuPartitionPercent = $spec.gpuPartitionPercent
        $job.gpuDeviceIdentity = $spec.gpuDeviceIdentity

        $job.profile | Should -Be 'omarchy'
        $job.cpuCount | Should -Be 8
        $job.memoryBytes | Should -Be 17179869184
        $job.diskSizeBytes | Should -Be 274877906944
        $job.gpuPartitionPercent | Should -Be 65
        $job.gpuDeviceIdentity | Should -Be 'VEN_1002&DEV_73BF'
        (Get-EpicVMProvisioningFailureState -Code 'omarchy_encoder_unavailable') | Should -Be 'setup_failed:omarchy_gpu'
    }

    It 'does not allow a historical Omarchy ready state without current GPU evidence' {
        $record = [pscustomobject]@{
            state = 'ready'
            profile = 'omarchy'
            claimConsumed = $true
            guestSetupVerified = $true
            tailnetIp = '100.111.82.1'
            tailnetDeviceId = 'device-1'
            managementTransport = 'tailscale_ssh'
            managementReadyAt = '2026-08-28T00:00:00Z'
            omarchyGpuValidated = $false
            consoleVerifiedAt = '2026-08-28T00:00:00Z'
            consoleFrameVerified = $true
            keyboardInputVerified = $true
            mouseInputVerified = $true
            streamValidationVerified = $true
            completedStages = @('claim','guest_setup','network_setup','management_handoff','streaming_setup','stream_validation')
        }

        (Test-EpicVMProvisioningEvidence -Record $record -Stage 'omarchy_gpu') | Should -BeFalse
        (ConvertTo-EpicVMCanonicalProvisioningState -Record $record) | Should -Be 'setup_failed:legacy_state_uncertain'
        $record.omarchyGpuValidated = $true
        (Test-EpicVMProvisioningEvidence -Record $record -Stage 'omarchy_gpu') | Should -BeTrue
    }

    It 'completes claim setup with Linux transport, removes the seed, and records only redacted fields' {
        $config = Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath = Join-Path $TestDrive 'omarchy-claim.json'
        $provider = [pscustomobject]@{
            Config = $config
            LastOmarchyGuestIp = $null
            ConfigureOmarchyGuest = { param($Name,$Username,$Password) @{ ok = $true; managementTransport = 'tailscale_ssh' } }
            WaitOmarchyGuestReady = { param($Name,$TimeoutSeconds,$PollMilliseconds,$ProbeUsername) @{ ok = $true } }
            RemoveOmarchySeed = { param($Name) @{ ok = $true; seedRemoved = $true } }
            ValidateOmarchyGuest = { param($Name,$Username,$Address,$RequireSunshine) @{ ok = $true; guestOs = 'Omarchy Linux' } }
        }
        $state = [pscustomobject]@{
            Config = $config
            Provider = $provider
            Provisioning = New-EpicVMProvisioningStore -Config $config
        }
        $job = New-EpicVMProvisioningJobObject -Id 'omarchy-claim' -Name 'omarchy-one' -Profile 'omarchy' -State 'unclaimed'
        $job.tailnetIp = '100.111.82.1'
        $job.tailnetDeviceId = 'device-1'
        $state.Provisioning.Jobs[$job.id] = $job

        Invoke-EpicVMProvisioningOmarchyPostClaimSetup -State $state -Job $job -Username 'operator' -Password 'transient-password' | Out-Null

        $job.state | Should -Be 'streaming_setup'
        $job.guestOs | Should -Be 'Omarchy Linux'
        $job.guestUsername | Should -Be 'operator'
        $job.managementTransport | Should -Be 'tailscale_ssh'
        $job.guestSetupVerified | Should -BeTrue
        $job.omarchyGpuValidated | Should -BeTrue
        $job.completedStages | Should -Contain 'omarchy_gpu'
        $raw = Get-Content -LiteralPath $config.ProvisioningStatePath -Raw
        $raw | Should -Not -Match 'transient-password'
    }

    It 'fails closed when the Omarchy renderer evidence is unavailable' {
        $config = Get-EpicVMDefaultConfig
        $config.ProvisioningStatePath = Join-Path $TestDrive 'omarchy-gpu-failed.json'
        $provider = [pscustomobject]@{
            Config = $config
            ValidateOmarchyGuest = { param($Name,$Username,$Address,$RequireSunshine) @{ ok = $false; failureDetailCode = 'OMARCHY_SOFTWARE_RENDERER' } }
        }
        $state = [pscustomobject]@{
            Config = $config
            Provider = $provider
            Provisioning = New-EpicVMProvisioningStore -Config $config
        }
        $job = New-EpicVMProvisioningJobObject -Id 'omarchy-gpu-failed' -Name 'omarchy-one' -Profile 'omarchy' -State 'streaming_setup'
        $job.guestUsername = 'operator'
        $job.tailnetIp = '100.111.82.1'
        $state.Provisioning.Jobs[$job.id] = $job

        { Invoke-EpicVMProvisioningOmarchyValidation -State $state -Job $job -RequireSunshine:$false } | Should -Throw
        $job.state | Should -Be 'setup_failed:omarchy_gpu'
        $job.failureDetailCode | Should -Be 'OMARCHY_SOFTWARE_RENDERER'
    }

    It 'retains the final management key while removing seed and bootstrap state after cleanup' {
        $text = Get-Content -LiteralPath (Join-Path $windowsRoot 'providers/OmarchyProvider.ps1') -Raw
        $text | Should -Match 'managementKeyRetained=\$true'
        $text | Should -Match 'seedRemoved=\$true'
        $text | Should -Match 'Remove-Item -LiteralPath \$bootstrapPasswordPath'
        $text | Should -Match 'epicvm-omarchy-bootstrap\.service'
    }
}
