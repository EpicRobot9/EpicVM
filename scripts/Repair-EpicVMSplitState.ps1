#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = 'C:\ProgramData\EpicVM\agent\config.json',
    [string] $ReportPath = (Join-Path $env:TEMP 'epicvm-split-state-repair.json'),
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
    if (-not (Test-RecoveryPathUnderRoot $Path $Root)) { throw 'path_outside_managed_root' }
    $full=Resolve-RecoveryPath $Path;$rootFull=(Resolve-RecoveryPath $Root).TrimEnd('\');$cursor=$full
    if (-not (Test-Path -LiteralPath $cursor)) { $cursor=Split-Path -Parent $cursor }
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
function Assert-PlainName { param([string]$Name,[string]$Field) if([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\\/:]' -or $Name -eq '.' -or $Name -eq '..'){throw ($Field+'_invalid')} }
function Assert-ExactLayout {
    param([string]$Path,[string[]]$Files)
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){throw ('directory_missing_'+(Split-Path -Leaf $Path))}
    $actual=@(Get-ChildItem -LiteralPath $Path -Force|ForEach-Object Name|Sort-Object);$expected=@($Files|Sort-Object)
    if((Compare-Object $actual $expected)){throw ('unexpected_layout_'+(Split-Path -Leaf $Path))}
}
function Copy-RecoverySnapshot {
    param([string]$Source,[string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force|Out-Null
    Copy-Item -LiteralPath $Source -Destination (Join-Path $Destination (Split-Path -Leaf $Source)) -Recurse -Force
}
function Restore-RecoverySnapshot {
    param([string]$Snapshot,[string]$Target)
    if(Test-Path -LiteralPath $Target){$park="$Target.failed-$([guid]::NewGuid().ToString('N'))";Move-Item -LiteralPath $Target -Destination $park -Force}
    Copy-Item -LiteralPath (Join-Path $Snapshot (Split-Path -Leaf $Target)) -Destination $Target -Recurse -Force
}

$report=[ordered]@{schemaVersion=1;operation='repair-split-state';execute=[bool]$Execute;whatIf=[bool]$WhatIfPreference;status='failed';changed=$false}
$mutex=$null;$held=$false;$snapshot=$null
try {
    $config=$null;if(Test-Path -LiteralPath $ConfigPath -PathType Leaf){$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json}
    if([string]::IsNullOrWhiteSpace($TemplateRoot)){
        $configured=[string]$config.TemplateManifestPath;if([string]::IsNullOrWhiteSpace($configured)){throw 'template_root_missing'}
        $TemplateRoot=Split-Path -Parent (Split-Path -Parent (Resolve-RecoveryPath $configured))
    }
    $root=Resolve-RecoveryPath $TemplateRoot;Assert-RecoveryPathSafe -Path $root -Root $root
    Assert-PlainName $ActiveTemplateName 'active_template_name';Assert-PlainName $DefectiveTemplateName 'defective_template_name';Assert-PlainName $GoodTemplateName 'good_template_name';Assert-PlainName $ImageName 'image_name';Assert-PlainName $ManifestName 'manifest_name'
    $active=Join-Path $root $ActiveTemplateName;$defective=Join-Path $root $DefectiveTemplateName;$good=Join-Path $root $GoodTemplateName
    foreach($path in @($active,$defective,$good)){Assert-RecoveryPathSafe -Path $path -Root $root}
    $activeImage=Join-Path $active $ImageName;$activeManifest=Join-Path $active $ManifestName;$defectiveImage=Join-Path $defective $ImageName;$defectiveManifest=Join-Path $defective $ManifestName;$goodImage=Join-Path $good $ImageName;$goodManifest=Join-Path $good $ManifestName
    foreach($path in @($activeImage,$activeManifest,$defectiveImage,$defectiveManifest,$goodImage,$goodManifest)){Assert-RecoveryPathSafe -Path $path -Root $root}
    Assert-ExactLayout $active @($ImageName);Assert-ExactLayout $defective @($ManifestName);Assert-ExactLayout $good @($ManifestName,$ImageName)
    $goodManifestData=Get-Content -LiteralPath $goodManifest -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$goodManifestData.templateVersion -ne '1.2.0'){throw ('good_archive_not_v120_is_'+[string]$goodManifestData.templateVersion)}
    $report.managedRoot=$root;$report.activePath=$active;$report.defectivePath=$defective;$report.goodPath=$good;$report.wouldChange=$true
    if(-not $Execute){$report.status='planned';Write-RecoveryReport $report $ReportPath;return}
    if(-not $PSCmdlet.ShouldProcess($root,'snapshot and repair split template state')){$report.status='whatif';Write-RecoveryReport $report $ReportPath;return}
    $created=$false;try{$mutex=[Threading.Mutex]::new($false,'Global\EpicVMTemplatesMutate',[ref]$created);try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true}}catch{throw 'another_instance_holds_mutex'}
    if(-not $held){throw 'another_instance_holds_mutex'}
    $snapshot=Join-Path $root ('.recovery-backup-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N'))
    Copy-RecoverySnapshot $active $snapshot;Copy-RecoverySnapshot $defective $snapshot;Copy-RecoverySnapshot $good $snapshot;$report.backupPath=$snapshot
    Import-Module Hyper-V -ErrorAction Stop
    foreach($path in @($activeImage,$defectiveImage,$goodImage)){try{$img=Get-DiskImage -ImagePath $path -ErrorAction Stop;if($img.Attached -and $PSCmdlet.ShouldProcess($path,'dismount VHD')){Dismount-VHD -Path $path|Out-Null}}catch{if($_.Exception.Message -notmatch 'cannot find|not found'){throw}}}
    Move-Item -LiteralPath $activeImage -Destination $defective -Force
    Remove-Item -LiteralPath $active -Recurse -Force
    Move-Item -LiteralPath $good -Destination $active -Force
    $activeCheck=Get-Content -LiteralPath (Join-Path $active $ManifestName) -Raw -Encoding UTF8|ConvertFrom-Json
    $hash=(Get-FileHash -LiteralPath (Join-Path $active $ImageName) -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -ne ([string]$activeCheck.sha256).ToLowerInvariant()){throw 'validator_failed_full_hash'}
    $report.status='ok';$report.changed=$true
}
catch{
    $report.error=$_.Exception.Message
    if($snapshot -and $Execute){try{Restore-RecoverySnapshot $snapshot $active;Restore-RecoverySnapshot $snapshot $defective;Restore-RecoverySnapshot $snapshot $good;$report.rollback='restored_backups'}catch{$report.rollback='failed'}}
    Write-RecoveryReport $report $ReportPath;exit 1
}
finally{if($mutex -and $held){try{$mutex.ReleaseMutex()}catch{}};if($mutex){$mutex.Dispose()}}
Write-RecoveryReport $report $ReportPath
