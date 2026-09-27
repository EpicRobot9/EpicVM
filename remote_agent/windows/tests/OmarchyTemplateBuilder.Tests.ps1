#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $builderPath = Join-Path $repoRoot 'scripts/Build-EpicVMOmarchyTemplate.ps1'
    . $builderPath
}

Describe 'Omarchy golden-image builder' {
    It 'is plan-only by default and advertises the pinned boot and disk policy' {
        $plan = Get-EpicVMOmarchyBuilderPlan -OutputRoot 'E:\EpicVM\templates' -Name 'omarchy-3.8.3' -WorkRoot 'E:\EpicVM\template-work' -SwitchName 'EpicVM-Template-Private' -VmName 'EpicVM-Omarchy-TemplateBuilder'

        $plan.planOnly | Should -BeTrue
        $plan.profile | Should -Be 'omarchy'
        $plan.omarchyVersion | Should -Be '3.8.3'
        $plan.isoSha256 | Should -Be '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac'
        $plan.bootPolicy.generation | Should -Be 2
        $plan.bootPolicy.secureBoot | Should -BeFalse
        $plan.bootPolicy.vTpm | Should -BeFalse
        $plan.bootPolicy.encrypted | Should -BeFalse
        $plan.diskPolicy.type | Should -Be 'Dynamic'
        $plan.diskPolicy.immutable | Should -BeTrue
    }

    It 'uses disposable cidata credentials and records a hashed VHDX manifest' {
        $text = Get-Content -LiteralPath $builderPath -Raw

        $text | Should -Match 'user_configuration\.json'
        $text | Should -Match 'user_credentials\.json'
        $text | Should -Match 'user_encrypt_installation\.txt'
        $text | Should -Match 'temporary-seed-only'
        $text | Should -Match 'Get-FileHash -LiteralPath \$publishedDisk -Algorithm SHA256'
        $text | Should -Match 'sha256 = \$imageSha256'
        $text | Should -Match 'noGuestSecrets = \$true'
        $text | Should -Match 'bootstrapCredentials = .temporary-seed-only.'
    }

    It 'creates a network-capable Gen2 builder with Secure Boot and vTPM disabled' {
        $text = Get-Content -LiteralPath $builderPath -Raw

        $text | Should -Match 'Get-VMSwitch -Name \$BuilderSwitchName'
        $text | Should -Match 'SwitchType -notin @\(''Internal'',''External''\)'
        $text | Should -Match 'New-VM -Name \$BuilderVmName.*-Generation 2'
        $text | Should -Match 'Get-VMDvdDrive -VMName \$BuilderVmName'
        $text | Should -Match 'Set-VMFirmware -VMName \$BuilderVmName -EnableSecureBoot Off -FirstBootDevice \$dvd'
        $text | Should -Match 'CheckpointType Disabled'
        $text | Should -Match 'Add-VMHardDiskDrive -VMName \$BuilderVmName -Path \$seedPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 2'
        $text | Should -Not -Match 'Enable-VMTPM'
        $text | Should -Not -Match 'Set-VMKeyProtector'
    }

    It 'requires explicit guest sanitation confirmation before publishing and removes the disposable builder' {
        $text = Get-Content -LiteralPath $builderPath -Raw

        $text | Should -Match 'Read-Host .+type SANITIZED'
        $text | Should -Match 'guest_sanitation_not_confirmed'
        $text | Should -Match 'Remove-VM -Name \$BuilderVmName -Force'
        $text | Should -Match 'IsReadOnly -Value \$true'
        $text | Should -Match 'machine-id'
        $text | Should -Match 'ssh_host_'
        $text | Should -Match 'var/lib/tailscale'
        $text | Should -Match 'sunshine-state'
        $text | Should -Match 'required_command in sunshine tailscale sshd lspci vulkaninfo vainfo'
        $text | Should -Not -Match 'Invoke-Command\s+-VMName'
        $text | Should -Not -Match 'dxdiag|Edge WebGL|driver injection'
    }
}
