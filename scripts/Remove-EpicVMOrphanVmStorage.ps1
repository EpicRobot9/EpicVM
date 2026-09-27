#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$registered = @(Get-VM)
$expected = @('d688f312-6a44-4190-8ff5-a7512efc4a5e','315b35c3-dead-4e01-90f2-fce7f59240e4')
if (@($registered).Count -ne 2 -or @($registered | Where-Object { [string]$_.Id -notin $expected }).Count) {
    throw 'Hyper-V inventory changed; orphan cleanup stopped.'
}
$roots = @(
    'E:\EpicVM\vms\gaming-gpup-pilot-01',
    'E:\EpicVM\vms\oobe-smoke-1',
    'E:\EpicVM\vms\testprov',
    'E:\EpicVM\vms\quarantine\gaming-e2e-0913-1789831093'
)
$base = [IO.Path]::GetFullPath('E:\EpicVM\vms').TrimEnd('\') + '\'
$records = @()
foreach ($root in $roots) {
    $full = [IO.Path]::GetFullPath($root)
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path: $full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $full" }
    $records += [pscustomobject]@{Path=$full;Status='pending'}
}
function Save-Report { [IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $records -Depth 3)) }
Save-Report
foreach ($record in $records) {
    Remove-Item -LiteralPath $record.Path -Recurse -Force -ErrorAction Stop
    $record.Status = 'removed'
    Save-Report
}
