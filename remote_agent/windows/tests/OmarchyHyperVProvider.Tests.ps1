#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'providers/HyperVProvider.ps1')
    $script:omarchyGpu = [pscustomobject]@{
        Name = 'AMD Radeon RX 6800 XT'
        InstancePath = '\\?\PCI#VEN_1002&DEV_73BF#rx6800'
        MaxPartitionVRAM = 1000000000
        MaxPartitionDecode = 1000000000
        MaxPartitionCompute = 1000000000
        MaxPartitionEncode = 1000000000
    }
    $script:omarchyAdapters = @()
    $script:omarchyCalls = [System.Collections.Generic.List[object]]::new()

    function Invoke-OmarchyHyperVTestCommand {
        param([Parameter(Mandatory)][string]$CommandName,[hashtable]$Parameters)
        $script:omarchyCalls.Add([pscustomobject]@{ Name = $CommandName; Parameters = $Parameters })
        switch ($CommandName) {
            'Get-VMHostPartitionableGpu' { return @($script:omarchyGpu) }
            'Get-VMGpuPartitionAdapter' { return @($script:omarchyAdapters) }
            'Add-VMGpuPartitionAdapter' {
                $script:omarchyAdapters = @([pscustomobject]@{ InstancePath = $Parameters.InstancePath })
                return $null
            }
            'Set-VMGpuPartitionAdapter' { return $null }
            default { throw "Unexpected Hyper-V command: $CommandName" }
        }
    }
}

Describe 'Omarchy Hyper-V GPU-P integration' {
    BeforeEach {
        $script:omarchyAdapters = @()
        $script:omarchyCalls.Clear()
        $script:provider = New-EpicVMHyperVProvider -Config @{
            VmRoot = 'E:\EpicVM\vms'
            OmarchyGpuDeviceIdentity = 'VEN_1002&DEV_73BF'
            OmarchyGpuPartitionPercent = 50
            DefaultMemoryBytes = 12884901888
            DefaultCpuCount = 6
            DefaultDiskSizeBytes = 137438953472
            MinMemoryBytes = 536870912
            MaxMemoryBytes = 17179869184
            MinCpuCount = 1
            MaxCpuCount = 16
            MaxDiskSizeBytes = 549755813888
            Generation = 2
        } -CommandInvoker ${function:Invoke-OmarchyHyperVTestCommand}
    }

    It 'normalizes Omarchy creation to Gen2 with the configured AMD identity and quota' {
        $options = Get-EpicVMHyperVCreateOptions -Provider $script:provider -Request @{
            Name = 'omarchy-alpha'
            Profile = 'omarchy'
            Generation = 2
            Gpu = $true
            GpuPartitionPercent = 65
            BootstrapSeedPath = 'E:\EpicVM\vms\omarchy-alpha\omarchy-alpha.cidata.vhdx'
        }

        $options.profile | Should -Be 'omarchy'
        $options.generation | Should -Be 2
        $options.gpu | Should -BeTrue
        $options.gpuPartitionPercent | Should -Be 65
        $options.gpuDeviceIdentity | Should -Be 'VEN_1002&DEV_73BF'
        $options.bootstrapSeedPath | Should -Match 'omarchy-alpha\.cidata\.vhdx'
    }

    It 'attaches exactly one matching AMD GPU-P adapter with the requested quota' {
        $result = Set-EpicVMHyperVGamingGpuPartitionAdapter `
            -Provider $script:provider `
            -Name 'omarchy-alpha' `
            -Percent 65 `
            -DeviceIdentity 'VEN_1002&DEV_73BF' `
            -ProfileName 'omarchy'

        $result.ok | Should -BeTrue
        $result.adapterCount | Should -Be 1
        $result.plan.percent | Should -Be 65
        $result.adapterInstancePath | Should -Match 'VEN_1002&DEV_73BF'
        @($script:omarchyCalls | Where-Object Name -eq 'Add-VMGpuPartitionAdapter').Count | Should -Be 1
        @($script:omarchyCalls | Where-Object Name -eq 'Set-VMGpuPartitionAdapter').Count | Should -Be 1
    }

    It 'uses the Omarchy AMD identity when checking host partitionability' {
        (Test-EpicVMHyperVGpuPartitionable -Provider $script:provider -DeviceIdentity 'VEN_1002&DEV_73BF') | Should -BeTrue
    }

    It 'keeps Windows driver injection and Windows-only validation behind the gaming profile' {
        $text = Get-Content -LiteralPath (Join-Path $windowsRoot 'providers/HyperVProvider.ps1') -Raw

        $text | Should -Match "options\.profile -eq 'gaming'"
        $text | Should -Match 'Resolve-EpicVMGamingGpuDriverSourcePaths'
        $text | Should -Match "options\.profile -eq 'omarchy'"
        $text | Should -Match "EnableSecureBoot='Off'"
        (Get-Content -LiteralPath (Join-Path $windowsRoot 'providers/OmarchyProvider.ps1') -Raw) | Should -Match 'tailscale_ssh'
    }
}
