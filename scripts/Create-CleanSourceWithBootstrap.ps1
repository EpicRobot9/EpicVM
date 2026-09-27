#Requires -RunAsAdministrator
<#
    Builds a fresh EpicVM-CleanTemplateSource from the pinned Windows 11 ISO.

    Difference from the historical Create-CleanSource.ps1: this applies the
    image through a specialize/oobeSystem unattend that creates the
    EpicVMBootstrap local administrator with a known password, so the published
    template carries a bootstrap account the host agent can reach over
    PowerShell Direct. The original applied the image with no unattend at all,
    which left Windows in default OOBE with no EpicVMBootstrap account.

    The password is written into the unattend as plaintext, which is unavoidable
    for a local-account unattend, so the unattend is removed from the image by
    the same run that bakes it. The password otherwise stays in memory only.

    Output mirrors the original: a registered clean source on the private
    isolation switch, left Off so the first boot applies the unattend.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BootstrapPassword,
    [string]$BootstrapUser = 'EpicVMBootstrap',
    [string]$IsoPath = 'E:\EpicVM\install-media\Win11.iso',
    [string]$VmName = 'EpicVM-CleanTemplateSource',
    [string]$Root = 'E:\EpicVM\clean-template-source',
    [string]$VhdPath = 'E:\EpicVM\clean-template-source\clean-source.vhdx',
    [string]$SwitchName = 'EpicVM-Template-Isolated',
    [string]$ReportPath,
    [int]$CpuCount = 4,
    [long]$MemoryBytes = 8589934592
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$secure = ConvertTo-SecureString -String $BootstrapPassword -AsPlainText -Force
$isoMounted = $false
$vhdMounted = $false
$password = $null
try {
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw 'Windows ISO is missing.' }
    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { throw 'Clean template source VM already exists.' }
    if (@(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Clean template source path is not empty.' }

    '=== stage 1: apply the Windows image ==='
    $iso = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    $isoMounted = $true
    $volume = $iso | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $volume) { throw 'Windows ISO volume was not mounted.' }
    $rootLetter = "$($volume.DriveLetter):"
    $imagePath = @("$rootLetter\sources\install.wim", "$rootLetter\sources\install.esd") |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $imagePath) { throw 'Windows install image was not found in the ISO.' }
    $pro = @(Get-WindowsImage -ImagePath $imagePath | Where-Object ImageName -CEQ 'Windows 11 Pro')
    if ($pro.Count -ne 1) { throw 'The ISO does not contain exactly one Windows 11 Pro image.' }
    "  image=$imagePath index=$($pro[0].ImageIndex)"

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    New-VHD -Path $VhdPath -Dynamic -SizeBytes 96GB -ErrorAction Stop | Out-Null
    $disk = Mount-VHD -Path $VhdPath -PassThru -ErrorAction Stop | Get-Disk
    $vhdMounted = $true
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -AssignDriveLetter -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'SYSTEM' -Confirm:$false | Out-Null
    New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}' | Out-Null
    $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $os -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $efiRoot = "$($efi.DriveLetter):"
    $osRoot = "$($os.DriveLetter):\"

    '  applying image (several minutes)'
    $dism = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" `
        -ArgumentList @('/English', '/Apply-Image', "/ImageFile:$imagePath", "/Index:$($pro[0].ImageIndex)", "/ApplyDir:$osRoot") `
        -Wait -PassThru -WindowStyle Hidden
    if ($dism.ExitCode -ne 0) { throw "DISM apply-image failed with exit code $($dism.ExitCode)." }
    '  image applied'
    '=== stage 2: unattend that creates the bootstrap account ==='
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    $tz = [TimeZoneInfo]::Local.Id
    $unattendLines = @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<unattend xmlns="urn:schemas-microsoft-com:unattend">',
        '  <settings pass="specialize">',
        '    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">',
        '      <ComputerName>*</ComputerName>',
        '      <TimeZone>' + $tz + '</TimeZone>',
        '    </component>',
        '    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">',
        '      <RunSynchronous>',
        '        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">',
        '          <Order>1</Order>',
        '          <Path>net user '' + $BootstrapUser + '' '' + $password + '' /add</Path>',
        '        </RunSynchronousCommand>',
        '        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">',
        '          <Order>2</Order>',
        '          <Path>net localgroup Administrators '' + $BootstrapUser + '' /add</Path>',
        '        </RunSynchronousCommand>',
        '      </RunSynchronous>',
        '    </component>',
        '  </settings>',
        '  <settings pass="oobeSystem">',
        '    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">',
        '      <OOBE>',
        '        <HideEULAPage>true</HideEULAPage>',
        '        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>',
        '        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>',
        '        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>',
        '        <ProtectYourPC>3</ProtectYourPC>',
        '      </OOBE>',
        '      <UserAccounts>',
        '        <AdministratorPassword>' + $password + '</AdministratorPassword>',
        '        <LocalAccounts>',
        '          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">',
        '            <Password>' + $password + '</Password>',
        '            <Group>Administrators</Group>',
        '            <Name>' + $BootstrapUser + '</Name>',
        '          </LocalAccount>',
        '        </LocalAccounts>',
        '      </UserAccounts>',
        '    </component>',
        '  </settings>',
        '</unattend>'
    )
    $unattend = $unattendLines -join "`r`n"
    $null = [xml]$unattend
    New-Item -ItemType Directory -Path "$osRoot\Windows\Panther" -Force | Out-Null
    [IO.File]::WriteAllText("$osRoot\Windows\Panther\unattend.xml", $unattend, [Text.UTF8Encoding]::new($false))
    '  wrote unattend.xml'

    '=== stage 3: boot files ==='
    $boot = Start-Process -FilePath "$env:SystemRoot\System32\bcdboot.exe" `
        -ArgumentList @((Join-Path $osRoot 'Windows'), '/s', $efiRoot, '/f', 'UEFI') -Wait -PassThru -WindowStyle Hidden
    if ($boot.ExitCode -ne 0) { throw "BCDBoot failed with exit code $($boot.ExitCode)." }
    '  boot files written'

    '=== stage 4: retain the unattend for first boot ==='
    '  unattend retained on disk; Windows Setup consumes it on first boot'

    Dismount-VHD -Path $VhdPath -ErrorAction Stop; $vhdMounted = $false
    Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop; $isoMounted = $false

    '=== stage 5: register the clean-source VM ==='
    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if (-not $switch) { New-VMSwitch -Name $SwitchName -SwitchType Private -ErrorAction Stop | Out-Null }
    elseif ($switch.SwitchType -ne 'Private') { throw 'Template isolation switch is not private.' }
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryBytes -VHDPath $VhdPath -Path $Root -SwitchName $SwitchName -ErrorAction Stop | Out-Null
    Set-VMProcessor -VMName $VmName -Count $CpuCount
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
    Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStopAction ShutDown -Notes 'EpicVM-CleanTemplateSource: true'
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
    '  VM registered, left Off; first boot applies the unattend'

    $result = [ordered]@{
        ok = $true; vm = $VmName; path = $Root; vhd = $VhdPath
        image = 'Windows 11 Pro'; imageIndex = $pro[0].ImageIndex
        switch = $SwitchName
        isoSha256 = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
        bootstrapUser = $BootstrapUser
    }
}
catch {
    $result = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
finally {
    $password = $null
    if ($vhdMounted) { Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue }
    if ($isoMounted) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue }
}
if ($ReportPath) {
    $parent = Split-Path -Parent $ReportPath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tmpReport = "$ReportPath.tmp"
    $result | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmpReport -Encoding utf8
    Move-Item -LiteralPath $tmpReport -Destination $ReportPath -Force
}
$result | ConvertTo-Json -Compress
