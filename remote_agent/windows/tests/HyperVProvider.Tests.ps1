# Requires -Version 7.0
# Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'providers/HyperVProvider.ps1')

    $script:vmState = @{
        alpha = [pscustomobject]@{ Name = 'alpha'; State = 'Off'; Notes = 'EpicVM-Managed: true'; Path = 'C:\EpicVM\VMs\alpha' }
        manual = [pscustomobject]@{ Name = 'manual'; State = 'Off'; Notes = 'Owned by the Windows administrator'; Path = 'C:\EpicVM\VMs\manual' }
    }
    $script:commandCalls = [System.Collections.Generic.List[object]]::new()

    function Invoke-MockHyperVCmdlet {
        param(
            [Parameter(Mandatory)] [string] $CommandName,
            [hashtable] $Parameters
        )

        $script:commandCalls.Add([pscustomobject]@{
                Name = $CommandName
                Parameters = if ($null -eq $Parameters) { @{} } else { $Parameters }
            })

        switch ($CommandName) {
            'Get-VM' {
                if ($Parameters.ContainsKey('Name')) {
                    $candidate = $script:vmState[$Parameters.Name]
                    if ($null -eq $candidate) { throw "VM was not found" }
                    return $candidate
                }
                return @($script:vmState.Values)
            }
            'Get-VMHost' {
                return [pscustomobject]@{
                    LogicalProcessorCount = 16
                    MemoryCapacity = 68719476736
                    VirtualMachinePath = 'C:\Hyper-V'
                }
            }
            'Get-VMSwitch' { return [pscustomobject]@{ Name = 'EpicVM'; SwitchType = 'Internal' } }
            'Start-VM' {
                $script:vmState[$Parameters.Name].State = 'Running'
                return $script:vmState[$Parameters.Name]
            }
            'Stop-VM' {
                $script:vmState[$Parameters.Name].State = 'Off'
                return $script:vmState[$Parameters.Name]
            }
            'Restart-VM' {
                $script:vmState[$Parameters.Name].State = 'Running'
                return $script:vmState[$Parameters.Name]
            }
            'Remove-VM' {
                $script:vmState.Remove($Parameters.Name)
                return $null
            }
            'New-VHD' { return [pscustomobject]@{ Path = $Parameters.Path; Size = $Parameters.SizeBytes } }
            'New-VM' {
                $vm = [pscustomobject]@{ Name = $Parameters.Name; State = 'Off'; Notes = ''; Path = $Parameters.Path }
                $script:vmState[$Parameters.Name] = $vm
                return $vm
            }
            'Set-VM' {
                $script:vmState[$Parameters.Name].Notes = $Parameters.Notes
                return $script:vmState[$Parameters.Name]
            }
            'Set-VMProcessor' { return $null }
            default { throw "Unexpected mocked Hyper-V command: $CommandName" }
        }
    }

    function New-TestHyperVProvider {
        $config = @{
            VmRoot = 'C:\EpicVM\VMs'
            SwitchName = 'EpicVM'
            DefaultMemoryBytes = 4294967296
            DefaultCpuCount = 2
            DefaultDiskSizeBytes = 68719476736
            MinMemoryBytes = 536870912
            MaxMemoryBytes = 17179869184
            MinCpuCount = 1
            MaxCpuCount = 16
            MaxDiskSizeBytes = 549755813888
            Generation = 2
        }
        New-EpicVMHyperVProvider -Config $config -CommandInvoker ${function:Invoke-MockHyperVCmdlet}
    }
}

Describe 'Hyper-V provider capabilities' {
    BeforeEach {
        $script:commandCalls.Clear()
        $script:provider = New-TestHyperVProvider
    }

    It 'reports cmdlet-backed host resources and feature capabilities' {
        $capabilities = & $provider.GetCapabilities

        $capabilities.provider | Should -Be 'HyperV'
        $capabilities.available | Should -BeTrue
        $capabilities.create_vm | Should -BeTrue
        $capabilities.start | Should -BeTrue
        $capabilities.stop | Should -BeTrue
        $capabilities.restart | Should -BeTrue
        $capabilities.delete | Should -BeTrue
        $capabilities.provisioning | Should -BeFalse
        $capabilities.features | Should -Contain 'lifecycle'
        $capabilities.resources.logicalProcessorCount | Should -Be 16
        $capabilities.resources.memoryCapacityBytes | Should -Be 68719476736
    }

    It 'projects allowlisted Tailscale configuration onto the enrollment provider' {
        $provider = New-EpicVMHyperVProvider -Config @{
            TailscaleOAuthClientId='client-id'
            TailscaleOAuthSecretPath='C:\ProgramData\EpicVM\agent\tailscale-oauth.dpapi'
            TailscaleTailnet='example.ts.net'
            TailscaleGuestTag='tag:epicvm-guest'
        } -CommandInvoker ${function:Invoke-MockHyperVCmdlet}

        $provider.TailscaleOAuthClientId | Should -Be 'client-id'
        $provider.TailscaleOAuthSecretPath | Should -Be 'C:\ProgramData\EpicVM\agent\tailscale-oauth.dpapi'
        $provider.TailscaleTailnet | Should -Be 'example.ts.net'
        $provider.TailscaleGuestTag | Should -Be 'tag:epicvm-guest'
    }

    It 'normalizes stale management settings to the protected handoff defaults' {
        $provider = New-EpicVMHyperVProvider -Config @{ ManagementPort = 0; RequireManagementTransport = $false } -CommandInvoker ${function:Invoke-MockHyperVCmdlet}
        $provider.ManagementPort | Should -Be 5985
        $provider.RequireManagementTransport | Should -BeTrue
    }
}

Describe 'Hyper-V provider lifecycle safety' {
    BeforeEach {
        $script:commandCalls.Clear()
        $script:vmState = @{
            alpha = [pscustomobject]@{ Name = 'alpha'; State = 'Off'; Notes = 'EpicVM-Managed: true'; Path = 'C:\EpicVM\VMs\alpha' }
            manual = [pscustomobject]@{ Name = 'manual'; State = 'Off'; Notes = 'Owned by the Windows administrator'; Path = 'C:\EpicVM\VMs\manual' }
        }
        $script:provider = New-TestHyperVProvider
    }

    It 'starts, stops, and restarts a managed VM through the adapter' {
        (& $provider.StartVM 'alpha').state | Should -Be 'Running'
        (& $provider.StopVM 'alpha').state | Should -Be 'Off'
        $script:vmState.alpha.State = 'Running'
        (& $provider.RestartVM 'alpha').state | Should -Be 'Running'

        $restartCall = @($script:commandCalls | Where-Object Name -eq 'Restart-VM') | Select-Object -First 1
        $restartCall.Parameters.Force | Should -BeTrue
    }

    It 'uses the actual Hyper-V state instead of generic provider health text' {
        $vm = [pscustomobject]@{
            Name = 'alpha'
            Id = '11111111-1111-1111-1111-111111111111'
            State = 'Off'
            Status = 'Operating normally'
            Notes = 'EpicVM-Managed: true'
            Path = 'C:\EpicVM\VMs\alpha'
        }

        $info = ConvertTo-EpicVMHyperVVMInfo -VM $vm

        $info.state | Should -Be 'Off'
        $info.status | Should -Be 'Off'
        $info.providerStatus | Should -Be 'Operating normally'
    }

    It 'refuses to delete a VM without the EpicVM ownership marker' {
        { & $provider.DeleteVM 'manual' } | Should -Throw '*not owned by EpicVM*'
        @($script:commandCalls | Where-Object Name -eq 'Remove-VM') | Should -BeNullOrEmpty
    }

    It 'deletes only a managed VM and uses force-free removal parameters' {
        $result = & $provider.DeleteVM 'alpha'

        $result.deleted | Should -BeTrue
        $script:vmState.ContainsKey('alpha') | Should -BeFalse
        $removeCall = @($script:commandCalls | Where-Object Name -eq 'Remove-VM') | Select-Object -First 1
        $removeCall.Parameters.Force | Should -BeTrue
    }

    It 'refuses to delete a marked VM outside the configured EpicVM root' {
        $script:vmState.outside = [pscustomobject]@{
            Name = 'outside'; State = 'Off'; Notes = 'EpicVM-Managed: true'; Path = 'C:\Other\outside'
        }

        { & $provider.DeleteVM 'outside' } | Should -Throw '*managed root*'
        @($script:commandCalls | Where-Object Name -eq 'Remove-VM') | Should -BeNullOrEmpty
    }
}

Describe 'Hyper-V Gaming guest validation' {
    It 'does not revalidate credential parameters during cleanup' {
        $script:validationCalls = @()
        $config = [pscustomobject]@{
            GamingGpuDeviceIdentity = 'VEN_1002&DEV_73BF'
            SunshineServiceName = 'SunshineService'
            SunshineStatePaths = @()
            ManagementPort = 5985
        }
        $provider = New-EpicVMHyperVProvider -Config $config -CommandInvoker ${function:Invoke-MockHyperVCmdlet} -ManagementInvoker {
            param($address, $credential, $scriptBlock, $arguments, $timeout, $port, $useSsl)
            $script:validationCalls += [pscustomobject]@{
                address = $address
                username = $credential.UserName
                timeout = [int]$timeout
                requireEncoder = $arguments[3]
            }
            return @{
                ok = $true
                transportOpened = $true
                result = @{
                    ok = $true
                    displayOk = $true
                    videoControllerOk = $true
                    dxdiagOk = $true
                    webglOk = $true
                    sunshineEncoderOk = $true
                }
            }
        }

        $result = & $provider.ValidateGamingGuest 'alpha' 'operator' ('p' * 16) '100.111.82.1'

        $result.ok | Should -BeTrue
        $result.address | Should -Be '100.111.82.1'
        $script:validationCalls.Count | Should -Be 1
        $script:validationCalls[0].username | Should -Be '.\operator'
        $script:validationCalls[0].timeout | Should -Be 240
        $script:validationCalls[0].requireEncoder | Should -BeFalse

        $result = Invoke-EpicVMHyperVGamingGuestValidation -Provider $provider -Name 'alpha' -GuestUsername 'operator' -GuestPassword ('p' * 16) -GuestAddress '100.111.82.1'
        $result.ok | Should -BeTrue
        $script:validationCalls.Count | Should -Be 2
        $script:validationCalls[1].requireEncoder | Should -BeTrue
    }
}
