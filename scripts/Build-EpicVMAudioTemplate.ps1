#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SourceManifest = 'E:\EpicVM\templates\win11-25h2\manifest.json',
    [string]$DriverInf = 'C:\ProgramData\EpicVM\cache\VBCABLE-45\extract\vbMmeCable64_win10.inf',
    [string]$TargetRoot = 'E:\EpicVM\templates\win11-25h2-audio-v1',
    [string]$AgentConfig = 'C:\ProgramData\EpicVM\agent\config.json',
    [string]$ReportPath = 'C:\ProgramData\EpicVM\audio-template-result.json'
)

$ErrorActionPreference = 'Stop'
$mounted = $false
$targetDisk = Join-Path $TargetRoot 'win11-25h2.vhdx'
$targetManifest = Join-Path $TargetRoot 'manifest.json'
$report = [ordered]@{ok=$false;stage='preflight';target=$TargetRoot}
try {
    if(Test-Path -LiteralPath $TargetRoot){throw 'target_already_exists'}
    $source = Get-Content -LiteralPath $SourceManifest -Raw | ConvertFrom-Json
    $sourceDisk = [IO.Path]::GetFullPath([string]$source.imagePath)
    if(-not(Test-Path -LiteralPath $sourceDisk -PathType Leaf)){throw 'source_disk_missing'}
    if((Get-FileHash -LiteralPath $sourceDisk -Algorithm SHA256).Hash -ine [string]$source.sha256){throw 'source_hash_mismatch'}
    if(-not(Test-Path -LiteralPath $DriverInf -PathType Leaf)){throw 'driver_missing'}
    $catalog = Join-Path (Split-Path -Parent $DriverInf) 'vbaudio_cable64_win10.cat'
    $signature = Get-AuthenticodeSignature -LiteralPath $catalog
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher'){throw 'driver_signature_invalid'}
    $report.stage='copy'
    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourceDisk -Destination $targetDisk -ErrorAction Stop
    $report.stage='driver_injection'
    $disk = Mount-VHD -Path $targetDisk -Passthru | Get-Disk
    $mounted = $true
    $partition = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 10GB -and $_.Type -eq 'Basic' } | Sort-Object Size -Descending | Select-Object -First 1
    if($null -eq $partition){throw 'windows_partition_missing'}
    $letter = [string]$partition.DriveLetter
    if(-not $letter){
        $taken = @(Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter)
        $letter = @('R','S','T','U','V','W','X','Y','Z') | Where-Object { $taken -notcontains $_ } | Select-Object -First 1
        if(-not $letter){throw 'no_mount_letter'}
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath ($letter + ':\')
    }
    $offline = $letter + ':\'
    if(-not(Test-Path -LiteralPath (Join-Path $offline 'Windows\System32') -PathType Container)){throw 'windows_volume_missing'}
    $driver = Add-WindowsDriver -Path $offline -Driver $DriverInf -ErrorAction Stop
    if($null -eq $driver){throw 'driver_injection_failed'}
    Dismount-VHD -Path $targetDisk -ErrorAction Stop
    $mounted = $false
    $report.stage='manifest'
    $source.templateVersion = '1.2.1-audio'
    $source.build = 'win11-25h2-audio-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
    $source.imagePath = $targetDisk
    $source.sha256 = (Get-FileHash -LiteralPath $targetDisk -Algorithm SHA256).Hash.ToLowerInvariant()
    $source.createdAt = [DateTime]::UtcNow.ToString('o')
    $source | Add-Member -NotePropertyName audioDriver -NotePropertyValue 'VB-Audio Virtual Cable 3.3.1.7' -Force
    $source | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $targetManifest -Encoding utf8
    (Get-Item -LiteralPath $targetDisk).IsReadOnly = $true
    $report.stage='agent_config'
    $configAcl = Get-Acl -LiteralPath $AgentConfig
    $config = Get-Content -LiteralPath $AgentConfig -Raw | ConvertFrom-Json
    $config.TemplateManifestPath = $targetManifest
    $configBackup = $AgentConfig + '.before-audio-template'
    Copy-Item -LiteralPath $AgentConfig -Destination $configBackup -Force
    $temporary = $AgentConfig + '.new'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
    Set-Acl -LiteralPath $temporary -AclObject $configAcl
    Move-Item -LiteralPath $temporary -Destination $AgentConfig -Force
    Restart-Service EpicVMRemoteAgent -Force -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while((Get-Service EpicVMRemoteAgent).Status -ne 'Running'){
        if([DateTime]::UtcNow -ge $deadline){throw 'agent_restart_timeout'}
        Start-Sleep -Milliseconds 500
    }
    $report.ok=$true
    $report.stage='complete'
    $report.templateVersion=$source.templateVersion
    $report.sha256=$source.sha256
} catch {
    $report.failure=[string]$_.Exception.Message
    if($report.stage -eq 'agent_config' -and (Test-Path -LiteralPath ($AgentConfig + '.before-audio-template'))){
        Copy-Item -LiteralPath ($AgentConfig + '.before-audio-template') -Destination $AgentConfig -Force
        try {Restart-Service EpicVMRemoteAgent -Force -ErrorAction Stop} catch {}
    }
} finally {
    if($mounted){try{Dismount-VHD -Path $targetDisk -ErrorAction Stop}catch{}}
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding utf8
}
if(-not $report.ok){exit 1}
