#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = 'C:\ProgramData\EpicVM\agent\config.json',
    [string] $ReportPath = (Join-Path $env:TEMP 'epicvm-restore-v12-active.json'),
    [string] $TemplateRoot,
    [string] $ActiveTemplateName = 'win11-25h2',
    [string] $DefectiveTemplateName = 'win11-25h2-prev-20260827-v1.4.0-defective',
    [string] $GoodTemplateName = 'win11-25h2-prev-20260826-v1.2.0',
    [string] $ImageName = 'win11-25h2.vhdx',
    [string] $ManifestName = 'manifest.json',
    [switch] $Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RecoveryPath { param([Parameter(Mandatory)][string]$Path) if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path_is_empty' }; [IO.Path]::GetFullPath($Path) }
function Test-RecoveryPathUnderRoot { param([string]$Path,[string]$Root) $p=(Resolve-RecoveryPath $Path).TrimEnd('\');$r=(Resolve-RecoveryPath $Root).TrimEnd('\');$p -ieq $r -or $p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase) }
function Assert-RecoveryPathSafe {
    param([string]$Path,[string]$Root)
    if(-not(Test-RecoveryPathUnderRoot $Path $Root)){throw 'path_outside_managed_root'}
    $full=Resolve-RecoveryPath $Path;$rootFull=(Resolve-RecoveryPath $Root).TrimEnd('\');$cursor=$full
    if(-not(Test-Path -LiteralPath $cursor)){$cursor=Split-Path -Parent $cursor}
    while($cursor -and $cursor.Length -ge $rootFull.Length){
        if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse_point_rejected'}}
        if($cursor.TrimEnd('\') -ieq $rootFull){break};$next=Split-Path -Parent $cursor;if($next -ieq $cursor){break};$cursor=$next
    }
}
function Write-RecoveryReport {
    param([object]$Report,[string]$Path)
    $WhatIfPreference = $false
    $parent=Split-Path -Parent $Path;if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $tmp="$Path.tmp-$([guid]::NewGuid().ToString('N'))";[IO.File]::WriteAllText($tmp,($Report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Assert-PlainName { param([string]$Name,[string]$Field) if([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\\/:]' -or $Name -in @('.','..')){throw ($Field+'_invalid')} }
function Assert-ExactLayout { param([string]$Path,[string[]]$Files) if(-not(Test-Path -LiteralPath $Path -PathType Container)){throw ('directory_missing_'+(Split-Path -Leaf $Path))};$actual=@(Get-ChildItem -LiteralPath $Path -Force|ForEach-Object Name|Sort-Object);$expected=@($Files|Sort-Object);if(Compare-Object $actual $expected){throw ('unexpected_layout_'+(Split-Path -Leaf $Path))} }
function Copy-RecoverySnapshot { param([string]$Source,[string]$Destination) New-Item -ItemType Directory -Path $Destination -Force|Out-Null;Copy-Item -LiteralPath $Source -Destination (Join-Path $Destination (Split-Path -Leaf $Source)) -Recurse -Force }
function Restore-RecoverySnapshot { param([string]$Snapshot,[string]$Target) if(Test-Path -LiteralPath $Target){$park="$Target.failed-$([guid]::NewGuid().ToString('N'))";Move-Item -LiteralPath $Target -Destination $park -Force};Copy-Item -LiteralPath (Join-Path $Snapshot (Split-Path -Leaf $Target)) -Destination $Target -Recurse -Force }

$report=[ordered]@{schemaVersion=1;operation='restore-v12-active';execute=[bool]$Execute;whatIf=[bool]$WhatIfPreference;status='failed';changed=$false}
$mutex=$null;$held=$false;$snapshot=$null;$active=$null;$defective=$null;$good=$null
try {
    $config=$null;if(Test-Path -LiteralPath $ConfigPath -PathType Leaf){$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json}
    if([string]::IsNullOrWhiteSpace($TemplateRoot)){$configured=[string]$config.TemplateManifestPath;if([string]::IsNullOrWhiteSpace($configured)){throw 'template_root_missing'};$TemplateRoot=Split-Path -Parent (Split-Path -Parent (Resolve-RecoveryPath $configured))}
    $root=Resolve-RecoveryPath $TemplateRoot;Assert-RecoveryPathSafe $root $root
    Assert-PlainName $ActiveTemplateName 'active_template_name';Assert-PlainName $DefectiveTemplateName 'defective_template_name';Assert-PlainName $GoodTemplateName 'good_template_name';Assert-PlainName $ImageName 'image_name';Assert-PlainName $ManifestName 'manifest_name'
    $active=Join-Path $root $ActiveTemplateName;$defective=Join-Path $root $DefectiveTemplateName;$good=Join-Path $root $GoodTemplateName
    foreach($path in @($active,$defective,$good)){Assert-RecoveryPathSafe $path $root}
    foreach($path in @((Join-Path $active $ImageName),(Join-Path $active $ManifestName),(Join-Path $good $ImageName),(Join-Path $good $ManifestName))){Assert-RecoveryPathSafe $path $root}
    if(Test-Path -LiteralPath $defective){throw 'defect_dir_already_exists'}
    Assert-ExactLayout $active @($ImageName,$ManifestName);Assert-ExactLayout $good @($ImageName,$ManifestName)
    $activeManifest=Get-Content -LiteralPath (Join-Path $active $ManifestName) -Raw -Encoding UTF8|ConvertFrom-Json;$goodManifest=Get-Content -LiteralPath (Join-Path $good $ManifestName) -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$activeManifest.templateVersion -ne '1.4.0'){throw ('active_version_unexpected_'+[string]$activeManifest.templateVersion)};if([string]$goodManifest.templateVersion -ne '1.2.0'){throw ('good_archive_not_v120_is_'+[string]$goodManifest.templateVersion)}
    $report.managedRoot=$root;$report.activePath=$active;$report.goodPath=$good;$report.wouldChange=$true
    if(-not $Execute){$report.status='planned';Write-RecoveryReport $report $ReportPath;return}
    if(-not $PSCmdlet.ShouldProcess($root,'snapshot and restore v1.2 template as active')){$report.status='whatif';Write-RecoveryReport $report $ReportPath;return}
    $created=$false;try{$mutex=[Threading.Mutex]::new($false,'Global\EpicVMTemplatesMutate',[ref]$created);try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true}}catch{throw 'another_instance_holds_mutex'};if(-not $held){throw 'another_instance_holds_mutex'}
    $snapshot=Join-Path $root ('.recovery-backup-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N'));Copy-RecoverySnapshot $active $snapshot;Copy-RecoverySnapshot $good $snapshot;$report.backupPath=$snapshot
    Import-Module Hyper-V -ErrorAction Stop
    foreach($path in @((Join-Path $active $ImageName),(Join-Path $good $ImageName))){try{$img=Get-DiskImage -ImagePath $path -ErrorAction Stop;if($img.Attached -and $PSCmdlet.ShouldProcess($path,'dismount VHD')){Dismount-VHD -Path $path|Out-Null}}catch{if($_.Exception.Message -notmatch 'cannot find|not found'){throw}}}
    Move-Item -LiteralPath $active -Destination $defective -Force
    Move-Item -LiteralPath $good -Destination $active -Force
    $check=Get-Content -LiteralPath (Join-Path $active $ManifestName) -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$check.templateVersion -ne '1.2.0'){throw 'post_swap_version_unexpected'}
    $hash=(Get-FileHash -LiteralPath (Join-Path $active $ImageName) -Algorithm SHA256).Hash.ToLowerInvariant();if($hash -ne ([string]$check.sha256).ToLowerInvariant()){throw 'validator_failed_full_hash'}
    $report.status='ok';$report.changed=$true
}
catch{$report.error=$_.Exception.Message;if($snapshot -and $Execute){try{if(Test-Path -LiteralPath $defective){$park="$defective.failed-$([guid]::NewGuid().ToString('N'))";Move-Item -LiteralPath $defective -Destination $park -Force};Restore-RecoverySnapshot $snapshot $active;Restore-RecoverySnapshot $snapshot $good;$report.rollback='restored_backups'}catch{$report.rollback='failed'}};Write-RecoveryReport $report $ReportPath;exit 1}
finally{if($mutex -and $held){try{$mutex.ReleaseMutex()}catch{}};if($mutex){$mutex.Dispose()}}
Write-RecoveryReport $report $ReportPath
