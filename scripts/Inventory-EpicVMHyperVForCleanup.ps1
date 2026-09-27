#Requires -RunAsAdministrator
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
$items = foreach ($vm in Get-VM) {
    [pscustomobject]@{
        Name = $vm.Name
        Id = [string]$vm.Id
        State = [string]$vm.State
        Notes = [string]$vm.Notes
        Path = [string]$vm.Path
        ConfigurationLocation = [string]$vm.ConfigurationLocation
        Disks = @((Get-VMHardDiskDrive -VM $vm | ForEach-Object { [string]$_.Path }))
        Checkpoints = @((Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }))
    }
}
$json = ConvertTo-Json -InputObject @($items) -Depth 5
[IO.File]::WriteAllText($OutputPath, $json)
