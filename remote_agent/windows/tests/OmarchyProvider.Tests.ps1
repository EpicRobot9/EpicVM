#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'providers/OmarchyProvider.ps1')
}

Describe 'Omarchy profile contract' {
    It 'registers a separate experimental Linux profile with AMD GPU-P and Tailscale SSH' {
        $profile = Get-EpicVMOmarchyProvisioningProfile

        $profile.profile | Should -Be 'omarchy'
        $profile.guestOs | Should -Be 'Omarchy Linux'
        $profile.gpu | Should -BeTrue
        $profile.gpuPartition | Should -Be '50%'
        $profile.managementTransport | Should -Be 'tailscale_ssh'
        $profile.experimental | Should -BeTrue
    }

    It 'uses the exact unattended cidata file names and never stores the plaintext password in the seed map' {
        Mock -CommandName Get-EpicVMOmarchyPasswordHash -MockWith { return 'hashed-password-only' }

        $files = New-EpicVMOmarchySeedFiles `
            -Hostname 'omarchy-alpha' `
            -BootstrapPassword 'temporary-password-never-persisted' `
            -AuthorizedKey 'ssh-ed25519 AAAA bootstrap' `
            -TailscaleAuthKey 'tskey-auth-ephemeral'

        @($files.Keys) | Should -Be @(
            'user_configuration.json',
            'user_credentials.json',
            'authorized_keys',
            'tailscale_authkey',
            'user_encrypt_installation.txt'
        )
        $files['user_credentials.json'] | Should -Not -Match 'temporary-password-never-persisted'
        $credentials = $files['user_credentials.json'] | ConvertFrom-Json
        $credentials.users[0].username | Should -Be 'epicvm-bootstrap'
        $credentials.users[0].sudo | Should -BeTrue
        $files['user_configuration.json'] | Should -Match 'omarchy-alpha'
        $files['user_configuration.json'] | Should -Not -Match 'disk_encryption'
        $files['user_encrypt_installation.txt'].Trim() | Should -Be 'false'
    }

    It 'validates the pinned Omarchy manifest and accepts Omarchy Linux as the guest OS label' {
        $templateRoot = Join-Path $TestDrive 'omarchy-3.8.3'
        New-Item -ItemType Directory -Path $templateRoot -Force | Out-Null
        $imagePath = Join-Path $templateRoot 'omarchy-3.8.3.vhdx'
        Set-Content -LiteralPath $imagePath -Value 'source-level-placeholder' -Encoding UTF8 -NoNewline
        $manifest = [ordered]@{
            templateVersion = '1.0.0'
            build = 'omarchy-3.8.3-20260828'
            sha256 = ('a' * 64)
            isoUrl = 'https://iso.omarchy.org/omarchy-3.8.3.iso'
            isoSha256 = '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac'
            omarchyVersion = '3.8.3'
            guestOs = 'Omarchy Linux'
            bootMode = 'uefi'
            secureBoot = $false
            vTpm = $false
            encrypted = $false
            bootPolicy = 'gen2-uefi-no-secureboot-vtpm'
            network = 'builder-switch-with-egress'
            immutable = $true
            fullCopy = $true
            diskType = 'Dynamic'
            imagePath = $imagePath
            sunshine = 'installed'
            sunshineVersion = 'operator-verified'
            managementTransport = 'tailscale_ssh'
            consoleBackend = 'sunshine-moonlight'
            noGuestSecrets = $true
        }
        $manifestPath = Join-Path $templateRoot 'manifest.json'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -NoNewline
        $config = [pscustomobject]@{
            OmarchyTemplateManifestPath = $manifestPath
            OmarchyVersion = '3.8.3'
            OmarchyIsoUrl = 'https://iso.omarchy.org/omarchy-3.8.3.iso'
            OmarchyIsoSha256 = '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac'
        }
        if (Get-Command -Name Get-VHD -ErrorAction SilentlyContinue) {
            Mock -CommandName Get-VHD -MockWith { [pscustomobject]@{ ParentPath = ''; VhdType = 'Dynamic' } }
        }

        (Test-EpicVMOmarchyTemplateManifest -Config $config -SkipContentHash) | Should -BeTrue
        $manifest.guestOs = 'Windows 11'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -NoNewline
        (Test-EpicVMOmarchyTemplateManifest -Config $config -SkipContentHash) | Should -BeFalse
    }

    It 'reports Omarchy readiness separately and fails closed before the pilot' {
        $config = [pscustomobject]@{
            OmarchyTemplateManifestPath = Join-Path $TestDrive 'missing-manifest.json'
            OmarchyVersion = '3.8.3'
            OmarchyIsoUrl = 'https://iso.omarchy.org/omarchy-3.8.3.iso'
            OmarchyIsoSha256 = '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac'
            TailscaleOAuthClientId = ''
            TailscaleOAuthSecretPath = Join-Path $TestDrive 'missing-secret.dpapi'
            TailscaleTailnet = ''
            OmarchyPilotValidated = $false
            EnableOmarchyProvisioning = $false
        }

        $readiness = Get-EpicVMOmarchyProvisioningReadiness -Config $config

        $readiness.omarchy_provisioning | Should -BeFalse
        $readiness.omarchyProvisioningChecks.template | Should -BeFalse
        $readiness.omarchyProvisioningChecks.pilotValidated | Should -BeFalse
        $readiness.omarchyProvisioningChecks.guestValidationRequired | Should -BeTrue
        $readiness.omarchyProvisioningChecks.linuxSshTransport | Should -BeTrue
    }

    It 'requires real AMD accelerated guest evidence and rejects software renderers' {
        $text = (Get-EpicVMOmarchyGuestValidationScript)

        $text | Should -Match 'lspci'
        $text | Should -Match '/dev/dri'
        $text | Should -Match 'renderD\*'
        $text | Should -Match 'vulkaninfo'
        $text | Should -Match 'Hyprland'
        $text | Should -Match 'vainfo'
        $text | Should -Match 'llvmpipe'
        $text | Should -Match 'softpipe'
        $text | Should -Match 'lavapipe'
        $text | Should -Match 'EPICVM_OMARCHY_ACCELERATED'
        $text | Should -Match 'EPICVM_OMARCHY_ENCODER'
    }

    It 'keeps the Omarchy transport on Tailscale SSH and gives bootstrap cleanup a separate verification step' {
        $provider = Get-Content -LiteralPath (Join-Path $windowsRoot 'providers/OmarchyProvider.ps1') -Raw

        $provider | Should -Match 'StrictHostKeyChecking=accept-new'
        $provider | Should -Match 'tailscale_ssh'
        $provider | Should -Match 'Remove-EpicVMOmarchyBootstrapArtifacts'
        $provider | Should -Match 'omarchy-bootstrap-password\.dpapi'
        $provider | Should -Match 'omarchy-management-key\.dpapi'
        $provider | Should -Match 'EPICVM_OMARCHY_BOOTSTRAP_CLEAN'
        $provider | Should -Not -Match 'Invoke-Command\s+-VMName'
    }
}
