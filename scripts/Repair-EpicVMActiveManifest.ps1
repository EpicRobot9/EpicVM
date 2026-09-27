#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = 'C:\ProgramData\EpicVM\agent\config.json',
    [string] $ReportPath = (Join-Path $env:TEMP 'epicvm-active-manifest-repair.json'),
    [string] $TemplateManifestPath,
    [string] $ImagePath,
    [switch] $Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RecoveryPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path_is_empty' }
    return [IO.Path]::GetFullPath($Path)
}

function Test-RecoveryPathUnderRoot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $p = (Resolve-RecoveryPath $Path).TrimEnd('\')
    $r = (Resolve-RecoveryPath $Root).TrimEnd('\')
    return $p -ieq $r -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-RecoveryPathSafe {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    if (-not (Test-RecoveryPathUnderRoot -Path $Path -Root $Root)) { throw 'path_outside_managed_root' }
    $full = Resolve-RecoveryPath $Path
    $rootFull = (Resolve-RecoveryPath $Root).TrimEnd('\')
    $cursor = $full
    if (-not (Test-Path -LiteralPath $cursor)) { $cursor = Split-Path -Parent $cursor }
    while ($cursor -and $cursor.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse_point_rejected' }
        }
        if ($cursor.TrimEnd('\') -ieq $rootFull) { break }
        $next = Split-Path -Parent $cursor
        if ($next -ieq $cursor) { break }
        $cursor = $next
    }
}

function Get-RecoveryManagedRoot {
    param([object]$Config, [string]$ManifestPath)
    foreach ($property in @('ManagedRoot', 'EpicVMRoot', 'VmRoot')) {
        if ($Config -and $Config.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$property)) {
            $candidate = Resolve-RecoveryPath ([string]$Config.$property)
            if ($property -eq 'VmRoot') { return (Split-Path -Parent $candidate) }
            return $candidate
        }
    }
    $dir = Split-Path -Parent (Resolve-RecoveryPath $ManifestPath)
    return (Split-Path -Parent $dir)
}

function Write-RecoveryReport {
    param([Parameter(Mandatory)][object]$Report, [Parameter(Mandatory)][string]$Path)
    $WhatIfPreference = $false
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($tmp, ($Report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

$report = [ordered]@{
    schemaVersion = 1; operation = 'repair-active-manifest'; execute = [bool]$Execute
    whatIf = [bool]$WhatIfPreference; status = 'failed'; changed = $false
}
$backupPath = $null
try {
    $config = $null
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ([string]::IsNullOrWhiteSpace($TemplateManifestPath)) { $TemplateManifestPath = [string]$config.TemplateManifestPath }
    if ([string]::IsNullOrWhiteSpace($TemplateManifestPath)) { throw 'template_manifest_path_missing' }
    $manifestPath = Resolve-RecoveryPath $TemplateManifestPath
    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        $ImagePath = Join-Path (Split-Path -Parent $manifestPath) ((Split-Path -Leaf (Split-Path -Parent $manifestPath)) + '.vhdx')
    }
    $imagePath = Resolve-RecoveryPath $ImagePath
    $managedRoot = Get-RecoveryManagedRoot -Config $config -ManifestPath $manifestPath
    Assert-RecoveryPathSafe -Path $manifestPath -Root $managedRoot
    Assert-RecoveryPathSafe -Path $imagePath -Root $managedRoot
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'manifest_missing' }
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { throw 'image_missing' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $actualHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $declaredHash = ([string]$manifest.sha256).ToLowerInvariant()
    if ($actualHash -ne $declaredHash) { throw 'active_image_hash_mismatch' }
    $report.managedRoot = $managedRoot; $report.manifestPath = $manifestPath; $report.imagePath = $imagePath
    $report.sha256 = $actualHash; $report.wouldChange = ([string]$manifest.imagePath -ine $imagePath)
    if (-not $Execute) { $report.status = 'planned'; Write-RecoveryReport $report $ReportPath; return }
    if (-not $PSCmdlet.ShouldProcess($manifestPath, 'repair imagePath and atomically replace manifest')) { $report.status = 'whatif'; Write-RecoveryReport $report $ReportPath; return }

    $backupPath = "$manifestPath.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))"
    Copy-Item -LiteralPath $manifestPath -Destination $backupPath -Force
    $report.backupPath = $backupPath
    $manifest.imagePath = $imagePath
    $json = $manifest | ConvertTo-Json -Depth 20
    $tmp = "$manifestPath.tmp-$([guid]::NewGuid().ToString('N'))"
    $item = Get-Item -LiteralPath $manifestPath -Force
    $readOnly = [bool]$item.IsReadOnly
    try {
        if ($readOnly) { $item.IsReadOnly = $false }
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    $check = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([IO.Path]::GetFullPath([string]$check.imagePath) -ine $imagePath) { throw 'manifest_path_repair_failed' }
    (Get-Item -LiteralPath $manifestPath -Force).IsReadOnly = $readOnly
    $report.status = 'ok'; $report.changed = $true
}
catch {
    $report.error = $_.Exception.Message
    if ($backupPath -and (Test-Path -LiteralPath $backupPath) -and $Execute) {
        try {
            $restore = "$manifestPath.rollback-$([guid]::NewGuid().ToString('N'))"
            Copy-Item -LiteralPath $backupPath -Destination $restore -Force
            Move-Item -LiteralPath $restore -Destination $manifestPath -Force
            $report.rollback = 'restored_backup'
        } catch { $report.rollback = 'failed' }
    }
    Write-RecoveryReport $report $ReportPath
    exit 1
}
Write-RecoveryReport $report $ReportPath
