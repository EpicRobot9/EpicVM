BeforeAll {
    . (Join-Path $PSScriptRoot '..\ServiceRuntime.ps1')
}
Describe 'The agent service has a durable PowerShell runtime' {
    It 'rejects Microsoft Store paths even if the executable is present' {
        Mock Test-Path { $true }
        Test-EpicVMServiceRuntime -Path 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.5_x64\pwsh.exe' | Should -BeFalse
    }
    It 'prefers a working machine installation' {
        Mock Test-EpicVMServiceRuntime { $Path -eq 'C:\machine\pwsh.exe' }
        Resolve-EpicVMServiceRuntime -InstallRoot $TestDrive -MachineRuntime 'C:\machine\pwsh.exe' | Should -Be 'C:\machine\pwsh.exe'
    }
    It 'reuses the existing managed runtime without copying over a running executable' {
        Mock Test-EpicVMServiceRuntime { $Path -like '*pwsh7*' }
        Mock Copy-Item { throw 'Existing runtime must not be overwritten.' }
        Resolve-EpicVMServiceRuntime -InstallRoot $TestDrive -MachineRuntime 'C:\missing\pwsh.exe' | Should -Be (Join-Path $TestDrive 'pwsh7\pwsh.exe')
    }
    It 'copies the complete distribution when only a user runtime is available' {
        $source = Join-Path $TestDrive 'source'
        $target = Join-Path $TestDrive 'agent'
        New-Item -ItemType Directory -Path $source | Out-Null
        foreach ($name in @('pwsh.exe','System.Management.Automation.dll','pwsh.runtimeconfig.json')) {
            Set-Content -LiteralPath (Join-Path $source $name) -Value 'fixture'
        }
        Mock Test-EpicVMServiceRuntime { Test-Path -LiteralPath $Path }
        $runtime = Resolve-EpicVMServiceRuntime -InstallRoot $target -SourceHome $source -MachineRuntime 'C:\missing\pwsh.exe'
        $runtime | Should -Be (Join-Path $target 'pwsh7\pwsh.exe')
        Test-Path -LiteralPath (Join-Path $target 'pwsh7\System.Management.Automation.dll') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'pwsh7\pwsh.runtimeconfig.json') | Should -BeTrue
    }
}
