#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$targets = [ordered]@{
    'astra-testmann' = 'd542813d-04eb-441d-9043-c742e916fce8'
    'epicvm-local-gaming-1' = '725d9f9c-bdc9-4c9c-89f3-4fa16f1a49d9'
    'gaming-e2e-0919' = 'd9be8f7c-a8fd-403c-acc2-ae56c9cfcc78'
    'indogaming' = '0c828c4c-cfda-4979-ab02-fae6c178e63a'
    'prod-gaming-verify-1' = 'b23705f7-3633-4580-ae0c-1f928a28d920'
    'testre' = 'e050ae4b-10e7-435e-9745-4b70059c7ec6'
    'Windows 11 dev environment' = '6e689095-25d6-4a05-9737-3e87585eaf9c'
}
$goldenIds = @('d688f312-6a44-4190-8ff5-a7512efc4a5e','315b35c3-dead-4e01-90f2-fce7f59240e4')
$all = @(Get-VM)
foreach ($id in $goldenIds) {
    if (@($all | Where-Object { [string]$_.Id -eq $id }).Count -ne 1) { throw "Golden reference VM missing: $id" }
}
$selected = foreach ($name in $targets.Keys) {
    $vm = @($all | Where-Object Name -EQ $name)
    if ($vm.Count -ne 1 -or [string]$vm[0].Id -ne $targets[$name]) { throw "VM identity changed: $name" }
    $vm[0]
}
$goldenDisks = @($all | Where-Object { [string]$_.Id -in $goldenIds } | ForEach-Object { Get-VMHardDiskDrive -VM $_ | ForEach-Object Path })
$records = @()
foreach ($vm in $selected) {
    $name = $vm.Name
    $disks = @((Get-VMHardDiskDrive -VM $vm | ForEach-Object Path))
    if (@($disks | Where-Object { $_ -in $goldenDisks }).Count) { throw "VM shares a golden disk: $name" }
    $records += [pscustomobject]@{Name=$name;Id=[string]$vm.Id;Disks=$disks;Status='pending'}
}
function Save-Report {
    $json = ConvertTo-Json -InputObject $records -Depth 5
    [IO.File]::WriteAllText($ReportPath, $json)
}
Save-Report
foreach ($record in $records) {
    $vm = Get-VM -Id ([guid]$record.Id) -ErrorAction Stop
    if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop }
    Remove-VM -VM $vm -Force -ErrorAction Stop
    if ($record.Name -ne 'Windows 11 dev environment') {
        $root = [IO.Path]::GetFullPath((Join-Path 'E:\EpicVM\vms' $record.Name))
        $expected = [IO.Path]::GetFullPath('E:\EpicVM\vms').TrimEnd('\') + '\'
        if (-not $root.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase) -or
            $root -ne [IO.Path]::GetFullPath((Join-Path $expected $record.Name))) { throw "Unsafe VM directory: $root" }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
    } else {
        $disk = 'C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\Windows 11 dev environment.vhdx'
        if ($record.Disks.Count -ne 1 -or $record.Disks[0] -ne $disk) { throw 'Unexpected development VM disk path.' }
        if (Test-Path -LiteralPath $disk) { Remove-Item -LiteralPath $disk -Force -ErrorAction Stop }
    }
    $record.Status = 'removed'
    Save-Report
}
