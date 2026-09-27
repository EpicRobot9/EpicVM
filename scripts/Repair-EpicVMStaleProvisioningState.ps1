#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = 'C:\ProgramData\EpicVM\agent\config.json',
    [string] $ReportPath = (Join-Path $env:TEMP 'epicvm-stale-provisioning-state-repair.json'),
    [string] $ProvisioningStatePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]] $TargetName,
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
    $tmp="$Path.tmp-$([guid]::NewGuid().ToString('N'))";[IO.File]::WriteAllText($tmp,($Report|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Set-JobProperty { param([object]$Object,[string]$Name,[object]$Value) if($Object.PSObject.Properties.Name -contains $Name){$Object.$Name=$Value}else{$Object|Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force} }
function Get-StoreRecords {
    param([object]$Parsed)
    if($Parsed -is [Array]){return @($Parsed)}
    if($Parsed -and $Parsed.PSObject.Properties['jobs']){return @($Parsed.jobs)}
    return @($Parsed)
}

$report=[ordered]@{schemaVersion=1;operation='repair-stale-provisioning-state';execute=[bool]$Execute;whatIf=[bool]$WhatIfPreference;status='failed';changed=$false;targetNames=@($TargetName)}
$mutex=$null;$held=$false;$backupPath=$null;$storePath=$null
try {
    $config=$null;if(Test-Path -LiteralPath $ConfigPath -PathType Leaf){$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json}
    if([string]::IsNullOrWhiteSpace($ProvisioningStatePath)){$ProvisioningStatePath=[string]$config.ProvisioningStatePath};if([string]::IsNullOrWhiteSpace($ProvisioningStatePath)){throw 'provisioning_state_path_missing'}
    $storePath=Resolve-RecoveryPath $ProvisioningStatePath
    $managedRoot=$null
    foreach($property in @('ManagedRoot','EpicVMRoot')){if($config -and $config.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$config.$property)){$managedRoot=Resolve-RecoveryPath ([string]$config.$property);break}}
    if(-not $managedRoot){$managedRoot=Split-Path -Parent $storePath}
    Assert-RecoveryPathSafe $storePath $managedRoot
    if(-not(Test-Path -LiteralPath $storePath -PathType Leaf)){throw 'provisioning_store_missing'}
    $raw=Get-Content -LiteralPath $storePath -Raw -Encoding UTF8;$parsed=$raw|ConvertFrom-Json;$records=Get-StoreRecords $parsed;$changed=@()
    foreach($job in $records){if($TargetName -notcontains [string]$job.name){continue};$state=[string]$job.state;if($state -notlike 'setup_failed:*' -and $state -ne 'streaming_setup'){continue};Set-JobProperty $job 'state' 'setup_failed:preclaim';Set-JobProperty $job 'failureStage' 'preclaim';Set-JobProperty $job 'failureDetailCode' 'stale_test_state_repaired';Set-JobProperty $job 'errorCode' 'stale_test_state_repaired';Set-JobProperty $job 'errorMessage' 'Stale provisioning state was repaired before a new provisioning request.';Set-JobProperty $job 'claimConsumed' $false;Set-JobProperty $job 'claimUsed' $false;Set-JobProperty $job 'guestSetupVerified' $false;Set-JobProperty $job 'updatedAt' ([DateTime]::UtcNow.ToString('o'));$changed+=[string]$job.name}
    if($changed.Count -eq 0){throw 'no_target_records_found'}
    $report.managedRoot=$managedRoot;$report.storePath=$storePath;$report.changedRecords=@($changed);$report.wouldChange=$true
    if(-not $Execute){$report.status='planned';Write-RecoveryReport $report $ReportPath;return}
    if(-not $PSCmdlet.ShouldProcess($storePath,'backup and atomically replace stale provisioning state')){$report.status='whatif';Write-RecoveryReport $report $ReportPath;return}
    $created=$false;try{$mutex=[Threading.Mutex]::new($false,'Local\EpicVM-ProvisioningState',[ref]$created);try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true}}catch{throw 'provisioning_store_busy'};if(-not $held){throw 'provisioning_store_busy'}
    $backupPath="$storePath.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))";Copy-Item -LiteralPath $storePath -Destination $backupPath -Force;$report.backupPath=$backupPath
    $json=if($parsed -is [Array]){ConvertTo-Json -InputObject ([object[]]$records) -Depth 30}else{ConvertTo-Json -InputObject $parsed -Depth 30}
    $tmp="$storePath.tmp-$([guid]::NewGuid().ToString('N'))";[IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($false));try{Move-Item -LiteralPath $tmp -Destination $storePath -Force}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}}
    $report.status='ok';$report.changed=$true
}
catch{$report.error=$_.Exception.Message;if($backupPath -and (Test-Path -LiteralPath $backupPath) -and $Execute){try{$restore="$storePath.rollback-$([guid]::NewGuid().ToString('N'))";Copy-Item -LiteralPath $backupPath -Destination $restore -Force;Move-Item -LiteralPath $restore -Destination $storePath -Force;$report.rollback='restored_backup'}catch{$report.rollback='failed'}};Write-RecoveryReport $report $ReportPath;exit 1}
finally{if($mutex -and $held){try{$mutex.ReleaseMutex()}catch{}};if($mutex){$mutex.Dispose()}}
Write-RecoveryReport $report $ReportPath
