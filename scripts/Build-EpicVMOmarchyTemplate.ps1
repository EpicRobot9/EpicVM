#Requires -Version 7.0

<#
    EpicVM Omarchy golden-image builder.

    The default invocation is a read-only plan.  The Hyper-V mutation path is
    available only with -Execute and requires an operator to confirm that the
    disposable guest was sanitized from its local console.  The builder never
    writes a Tailscale identity, SSH host key, Sunshine state, or long-lived
    credential into the published VHDX.
#>

[CmdletBinding()]
param(
    [switch] $Execute,
    [switch] $PlanOnly,
    [string] $TemplateRoot = 'E:\EpicVM\templates',
    [string] $TemplateName = 'omarchy-3.8.3',
    [string] $WorkingRoot = 'E:\EpicVM\template-work',
    [Alias('PrivateSwitchName')]
    [string] $BuilderSwitchName = 'Default Switch',
    [string] $BuilderVmName = 'EpicVM-Omarchy-TemplateBuilder',
    [string] $IsoUrl = 'https://iso.omarchy.org/omarchy-3.8.3.iso',
    [string] $IsoSha256 = '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac',
    [long] $DiskSizeBytes = 137438953472,
    [string] $SunshineVersion = 'operator-verified',
    [switch] $ConfirmGuestSanitized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EpicVMOmarchyBuilderVersion = '3.8.3'
$script:EpicVMOmarchyBuilderIsoUrl = 'https://iso.omarchy.org/omarchy-3.8.3.iso'
$script:EpicVMOmarchyBuilderIsoSha256 = '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac'
$script:EpicVMOmarchyBuilderBootstrapUser = 'epicvm-image-builder'

# Reuse the production cidata contract, but keep this script runnable from a
# source checkout without requiring the agent service to be installed.
$providerPath = Join-Path $PSScriptRoot '..\remote_agent\windows\providers\OmarchyProvider.ps1'
if (Test-Path -LiteralPath $providerPath -PathType Leaf) {
    . $providerPath
}

function New-EpicVMOmarchyBuilderError {
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Message
    )
    $exception = [System.InvalidOperationException]::new($Message)
    $exception | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $Code -Force
    return $exception
}

function Test-EpicVMOmarchyBuilderPathUnderRoot {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Root
    )
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([char]92, [char]47))
        $base = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([char]92, [char]47))
        return $full.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Get-EpicVMOmarchyBuilderPlan {
    param(
        [string] $OutputRoot = $TemplateRoot,
        [string] $Name = $TemplateName,
        [string] $WorkRoot = $WorkingRoot,
        [string] $SwitchName = $BuilderSwitchName,
        [string] $VmName = $BuilderVmName,
        [string] $PinnedIsoUrl = $IsoUrl,
        [string] $PinnedIsoSha256 = $IsoSha256
    )
    return [ordered]@{
        ok = $true
        planOnly = $true
        profile = 'omarchy'
        omarchyVersion = $script:EpicVMOmarchyBuilderVersion
        isoUrl = $PinnedIsoUrl
        isoSha256 = $PinnedIsoSha256
        templateRoot = $OutputRoot
        templateName = $Name
        workingRoot = $WorkRoot
        builderVmName = $VmName
        network = 'builder-switch-with-egress'
        builderSwitchName = $SwitchName
        networkRequirement = 'existing NAT or external switch with Internet egress'
        bootPolicy = [ordered]@{
            generation = 2
            bootMode = 'uefi'
            secureBoot = $false
            vTpm = $false
            encrypted = $false
        }
        diskPolicy = [ordered]@{
            type = 'Dynamic'
            fullCopy = $true
            immutable = $true
            perVmClone = $true
        }
        seedFiles = @(
            'user_configuration.json',
            'user_credentials.json',
            'authorized_keys',
            'user_encrypt_installation.txt',
            'epicvm-golden-image-sanitize.sh'
        )
        secretPolicy = 'temporary builder credential exists only on disposable cidata until cleanup'
        sanitation = @(
            'machine-id',
            'SSH host keys',
            'Tailscale identity',
            'Sunshine state and credentials',
            'builder user and authorized_keys'
        )
        guestOs = 'Omarchy Linux'
        managementTransport = 'tailscale_ssh'
        consoleBackend = 'sunshine-moonlight'
        gpuPolicy = 'AMD GPU-P is attached per VM; the image builder itself receives no GPU partition'
        pilotRequired = $true
    }
}

function New-EpicVMOmarchyBuilderTemporaryPassword {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^*-_'
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
        $builder = [Text.StringBuilder]::new()
        foreach ($byte in $bytes) {
            [void]$builder.Append($alphabet[[int]$byte % $alphabet.Length])
        }
        return $builder.ToString()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $rng.Dispose()
    }
}

function Get-EpicVMOmarchyBuilderPasswordHash {
    param([Parameter(Mandatory)] [string] $Password)
    if (Get-Command -Name Get-EpicVMOmarchyPasswordHash -ErrorAction SilentlyContinue) {
        return Get-EpicVMOmarchyPasswordHash -Password $Password
    }
    throw (New-EpicVMOmarchyBuilderError -Code 'omarchy_password_hash_unavailable' -Message 'The Omarchy password-hash helper is unavailable.')
}

function Get-EpicVMOmarchyGoldenImageSanitationScript {
    return @'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  printf '%s\n' 'This sanitation script must run as root.' >&2
  exit 20
fi

# Preserve installed software, but remove all machine-, user-, and stream-
# identity from the disposable installer account before publication.
for required_command in sunshine tailscale sshd lspci vulkaninfo vainfo; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Missing required Omarchy image tool: %s\n' "$required_command" >&2
    exit 30
  fi
done
systemctl disable --now sunshine.service 2>/dev/null || true
rm -rf /var/lib/tailscale /var/cache/tailscale /etc/tailscale /root/.config/tailscale
rm -rf /var/lib/sunshine /etc/sunshine /root/.config/sunshine
find /home -type f \( -path '*/.ssh/authorized_keys' -o -path '*/.config/sunshine/*' \) -delete 2>/dev/null || true
rm -f /etc/ssh/ssh_host_* /etc/sudoers.d/epicvm-image-builder
rm -rf /home/epicvm-image-builder
userdel -r epicvm-image-builder 2>/dev/null || true

# Let systemd create a new identity on the first real VM boot.
rm -f /etc/machine-id /var/lib/dbus/machine-id
mkdir -p /var/lib/epicvm
rm -f /var/lib/epicvm/omarchy-bootstrap-state
touch /var/lib/epicvm/omarchy-golden-clean
chmod 0644 /var/lib/epicvm/omarchy-golden-clean
printf '%s\n' EPICVM_OMARCHY_GOLDEN_CLEAN
'@
}

function New-EpicVMOmarchyBuilderSeed {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Hostname,
        [Parameter(Mandatory)] [string] $SanitationScript
    )
    $password = New-EpicVMOmarchyBuilderTemporaryPassword
    $passwordHash = $null
    $mounted = $null
    try {
        $passwordHash = Get-EpicVMOmarchyBuilderPasswordHash -Password $password
        if ($null -eq (Get-Command -Name New-VHD -ErrorAction SilentlyContinue) -or
            $null -eq (Get-Command -Name Mount-VHD -ErrorAction SilentlyContinue)) {
            throw (New-EpicVMOmarchyBuilderError -Code 'hyperv_storage_unavailable' -Message 'Hyper-V storage cmdlets are required to create the Omarchy cidata seed.')
        }
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        New-VHD -Path $Path -SizeBytes 67108864 -Dynamic -ErrorAction Stop | Out-Null
        $mounted = Mount-VHD -Path $Path -Passthru -ErrorAction Stop
        $diskNumber = [int]$mounted.DiskNumber
        $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $diskNumber -PartitionStyle GPT -ErrorAction Stop | Out-Null
        }
        $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel 'cidata' -Confirm:$false -ErrorAction Stop | Out-Null
        $letter = [string]$partition.DriveLetter
        if ([string]::IsNullOrWhiteSpace($letter)) {
            throw (New-EpicVMOmarchyBuilderError -Code 'omarchy_seed_mount_failed' -Message 'The Omarchy builder seed did not receive a drive letter.')
        }
        $seedRoot = $letter + ':\'
        $userConfiguration = if (Get-Command -Name Get-EpicVMOmarchyUserConfiguration -ErrorAction SilentlyContinue) {
            Get-EpicVMOmarchyUserConfiguration -Hostname $Hostname -Timezone 'America/New_York' -Keyboard 'us'
        }
        else {
            throw (New-EpicVMOmarchyBuilderError -Code 'omarchy_config_unavailable' -Message 'The Omarchy unattended configuration helper is unavailable.')
        }
        $credentials = [ordered]@{
            root_enc_password = $passwordHash
            users = @([ordered]@{
                    enc_password = $passwordHash
                    groups = @()
                    sudo = $true
                    username = $script:EpicVMOmarchyBuilderBootstrapUser
                })
        }
        $files = [ordered]@{
            'user_configuration.json' = ($userConfiguration | ConvertTo-Json -Depth 20)
            'user_credentials.json' = ($credentials | ConvertTo-Json -Depth 10)
            'authorized_keys' = ([Environment]::NewLine)
            'user_encrypt_installation.txt' = ('false' + [Environment]::NewLine)
            'epicvm-golden-image-sanitize.sh' = $SanitationScript
        }
        foreach ($name in $files.Keys) {
            Set-Content -LiteralPath (Join-Path $seedRoot $name) -Value ([string]$files[$name]) -Encoding UTF8 -NoNewline -ErrorAction Stop
        }
        return [ordered]@{ path = $Path; label = 'cidata'; fileNames = @($files.Keys) }
    }
    finally {
        $password = $null
        $passwordHash = $null
        if ($null -ne $mounted) {
            try { Dismount-VHD -Path $Path -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Invoke-EpicVMOmarchyTemplateBuild {
    if ($Execute -and $PlanOnly) {
        throw (New-EpicVMOmarchyBuilderError -Code 'invalid_mode' -Message 'Choose either -Execute or -PlanOnly, not both.')
    }
    if (-not $Execute) {
        return Get-EpicVMOmarchyBuilderPlan -OutputRoot $TemplateRoot -Name $TemplateName -WorkRoot $WorkingRoot -SwitchName $BuilderSwitchName -VmName $BuilderVmName -PinnedIsoUrl $IsoUrl -PinnedIsoSha256 $IsoSha256
    }
    if ($IsoUrl -cne $script:EpicVMOmarchyBuilderIsoUrl -or $IsoSha256 -cne $script:EpicVMOmarchyBuilderIsoSha256) {
        throw (New-EpicVMOmarchyBuilderError -Code 'omarchy_pin_update_required' -Message 'The Omarchy builder accepts only the pinned v3.8.3 ISO URL and SHA-256.')
    }
    if ([string]::IsNullOrWhiteSpace($SunshineVersion)) {
        throw (New-EpicVMOmarchyBuilderError -Code 'sunshine_version_required' -Message 'A non-empty Sunshine version marker is required in the template manifest.')
    }
    if ($DiskSizeBytes -lt 64GB) {
        throw (New-EpicVMOmarchyBuilderError -Code 'disk_size_invalid' -Message 'The Omarchy builder disk must be at least 64 GiB.')
    }
    if (-not (Test-EpicVMOmarchyBuilderPathUnderRoot -Path $TemplateRoot -Root $TemplateRoot) -or
        -not (Test-EpicVMOmarchyBuilderPathUnderRoot -Path $WorkingRoot -Root (Split-Path -Parent ([IO.Path]::GetFullPath($TemplateRoot)))) -or
        [IO.Path]::GetFullPath($TemplateRoot).TrimEnd('\') -ieq [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TemplateRoot)).TrimEnd('\')) {
        throw (New-EpicVMOmarchyBuilderError -Code 'path_gate' -Message 'Template and working paths failed the managed-root safety gate.')
    }
    $requiredCommands = @('Import-Module', 'Get-VMSwitch', 'Get-VMDvdDrive', 'Get-VM', 'New-VM', 'Set-VM', 'Set-VMFirmware', 'Add-VMDvdDrive', 'Add-VMHardDiskDrive', 'Start-VM', 'Stop-VM', 'Remove-VM', 'New-VHD', 'Get-VHD', 'Mount-VHD', 'Dismount-VHD', 'Get-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume')
    foreach ($commandName in $requiredCommands) {
        if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw (New-EpicVMOmarchyBuilderError -Code 'hyperv_provider_unavailable' -Message 'Hyper-V and storage cmdlets are required for the Omarchy template build.')
        }
    }
    Import-Module Hyper-V -ErrorAction Stop

    $finalRoot = Join-Path $TemplateRoot $TemplateName
    $buildRoot = Join-Path $WorkingRoot ('omarchy-' + [guid]::NewGuid().ToString('N'))
    $builderDisk = Join-Path $buildRoot ($TemplateName + '-builder.vhdx')
    $seedPath = Join-Path $buildRoot ($TemplateName + '.cidata.vhdx')
    $isoPath = Join-Path $buildRoot ($TemplateName + '.iso')
    $stageRoot = Join-Path $buildRoot 'stage'
    $builderCreated = $false
    $templatePublished = $false
    try {
        if (Test-Path -LiteralPath $finalRoot) {
            throw (New-EpicVMOmarchyBuilderError -Code 'immutable_exists' -Message 'The immutable Omarchy template directory already exists.')
        }
        $existingBuilder = Get-VM -Name $BuilderVmName -ErrorAction SilentlyContinue
        if ($null -ne $existingBuilder) {
            throw (New-EpicVMOmarchyBuilderError -Code 'builder_exists' -Message 'The disposable Omarchy builder VM name is already in use.')
        }
        New-Item -ItemType Directory -Path $buildRoot, $stageRoot -Force | Out-Null
        Invoke-WebRequest -Uri $IsoUrl -OutFile $isoPath -UseBasicParsing -ErrorAction Stop
        $actualIsoSha256 = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualIsoSha256 -cne $IsoSha256.ToLowerInvariant()) {
            throw (New-EpicVMOmarchyBuilderError -Code 'omarchy_iso_hash_mismatch' -Message 'The downloaded Omarchy ISO did not match the pinned SHA-256.')
        }
        New-VHD -Path $builderDisk -SizeBytes $DiskSizeBytes -Dynamic -ErrorAction Stop | Out-Null
        $builderVhd = Get-VHD -Path $builderDisk -ErrorAction Stop
        if ([string]$builderVhd.VhdType -ine 'Dynamic' -or -not [string]::IsNullOrWhiteSpace([string]$builderVhd.ParentPath)) {
            throw (New-EpicVMOmarchyBuilderError -Code 'builder_disk_invalid' -Message 'The Omarchy builder disk is not standalone Dynamic VHDX.')
        }
        $sanitationScript = Get-EpicVMOmarchyGoldenImageSanitationScript
        New-EpicVMOmarchyBuilderSeed -Path $seedPath -Hostname 'epicvm-omarchy-builder' -SanitationScript $sanitationScript | Out-Null
        $switch = Get-VMSwitch -Name $BuilderSwitchName -ErrorAction SilentlyContinue
        if ($null -eq $switch) {
            throw (New-EpicVMOmarchyBuilderError -Code 'builder_switch_missing' -Message 'The Omarchy builder requires an existing NAT or external Hyper-V switch with Internet egress.')
        }
        if ([string]$switch.SwitchType -notin @('Internal','External')) {
            throw (New-EpicVMOmarchyBuilderError -Code 'network_egress_gate' -Message 'The Omarchy builder switch must provide NAT or external Internet egress; a Private switch cannot install Omarchy packages.')
        }
        New-VM -Name $BuilderVmName -MemoryStartupBytes 8589934592 -Generation 2 -VHDPath $builderDisk -Path $buildRoot -SwitchName $BuilderSwitchName -ErrorAction Stop | Out-Null
        $builderCreated = $true
        Set-VM -Name $BuilderVmName -Notes 'EpicVM-Omarchy-TemplateBuilder: true' -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -ErrorAction Stop | Out-Null
        Add-VMDvdDrive -VMName $BuilderVmName -Path $isoPath -ErrorAction Stop | Out-Null
        $dvd = @(Get-VMDvdDrive -VMName $BuilderVmName -ErrorAction Stop | Where-Object { [string]$_.Path -ieq $isoPath }) | Select-Object -First 1
        if ($null -eq $dvd) {
            throw (New-EpicVMOmarchyBuilderError -Code 'builder_dvd_missing' -Message 'The Omarchy installer DVD was not attached to the disposable builder.')
        }
        Set-VMFirmware -VMName $BuilderVmName -EnableSecureBoot Off -FirstBootDevice $dvd -ErrorAction Stop
        # Gen2's DVD drive is attached at SCSI 0:1, so keep the removable
        # cidata seed at the next slot instead of colliding with the installer.
        Add-VMHardDiskDrive -VMName $BuilderVmName -Path $seedPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 2 -ErrorAction Stop | Out-Null
        Start-VM -Name $BuilderVmName -ErrorAction Stop | Out-Null

        $confirmation = if ($ConfirmGuestSanitized) { 'SANITIZED' } else {
            Read-Host 'Install Omarchy from cidata, run "omarchy install service sunshine", verify the required tools, run epicvm-golden-image-sanitize.sh as root, then type SANITIZED'
        }
        if ($confirmation -cne 'SANITIZED') {
            throw (New-EpicVMOmarchyBuilderError -Code 'guest_sanitation_not_confirmed' -Message 'The disposable Omarchy guest was not explicitly confirmed as sanitized.')
        }
        $builderState = [string](Get-VM -Name $BuilderVmName -ErrorAction Stop).State
        if ($builderState -ieq 'Running') {
            Stop-VM -Name $BuilderVmName -Force -ErrorAction Stop | Out-Null
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        do {
            $builderState = [string](Get-VM -Name $BuilderVmName -ErrorAction Stop).State
            if ($builderState -ieq 'Off') { break }
            if ([DateTime]::UtcNow -gt $deadline) {
                throw (New-EpicVMOmarchyBuilderError -Code 'builder_shutdown_timeout' -Message 'The disposable Omarchy builder did not reach Off state.')
            }
            Start-Sleep -Milliseconds 250
        } while ($true)
        Remove-VM -Name $BuilderVmName -Force -ErrorAction Stop
        $builderCreated = $false
        if (Test-Path -LiteralPath $seedPath) { Remove-Item -LiteralPath $seedPath -Force -ErrorAction Stop }
        $publishedDisk = Join-Path $stageRoot ($TemplateName + '.vhdx')
        Move-Item -LiteralPath $builderDisk -Destination $publishedDisk -Force -ErrorAction Stop
        $publishedVhd = Get-VHD -Path $publishedDisk -ErrorAction Stop
        if ([string]$publishedVhd.VhdType -ine 'Dynamic' -or -not [string]::IsNullOrWhiteSpace([string]$publishedVhd.ParentPath)) {
            throw (New-EpicVMOmarchyBuilderError -Code 'published_disk_invalid' -Message 'The published Omarchy disk is not standalone Dynamic VHDX.')
        }
        $imageSha256 = (Get-FileHash -LiteralPath $publishedDisk -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $manifest = [ordered]@{
            templateVersion = '1.0.0'
            name = $TemplateName
            build = ($TemplateName + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd'))
            omarchyVersion = $script:EpicVMOmarchyBuilderVersion
            isoUrl = $IsoUrl
            isoSha256 = $IsoSha256.ToLowerInvariant()
            sha256 = $imageSha256
            imagePath = (Join-Path $finalRoot ($TemplateName + '.vhdx'))
            guestOs = 'Omarchy Linux'
            bootMode = 'uefi'
            bootPolicy = 'gen2-uefi-no-secureboot-vtpm'
            secureBoot = $false
            vTpm = $false
            encrypted = $false
            network = 'builder-switch-with-egress'
            builderSwitchName = $BuilderSwitchName
            networkRequirement = 'existing NAT or external switch with Internet egress'
            diskType = 'Dynamic'
            fullCopy = $true
            immutable = $true
            noGuestSecrets = $true
            bootstrap = 'disposable-cidata'
            bootstrapCredentials = 'temporary-seed-only'
            tailscale = 'per-vm-first-boot-only'
            sunshine = 'installed'
            sunshineVersion = $SunshineVersion
            sunshineState = 'cleared-before-publication'
            managementTransport = 'tailscale_ssh'
            consoleBackend = 'sunshine-moonlight'
            gpu = 'AMD GPU-P per VM'
            gpuPartition = 'one adapter with requested quota'
            sanitation = 'machine-id;ssh-host-keys;tailscale-identity;sunshine-state;builder-user;authorized-keys'
            createdAt = [DateTime]::UtcNow.ToString('o')
        }
        Move-Item -LiteralPath $stageRoot -Destination $finalRoot -Force -ErrorAction Stop
        $finalDisk = Join-Path $finalRoot ($TemplateName + '.vhdx')
        $finalManifest = Join-Path $finalRoot 'manifest.json'
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $finalManifest -Encoding UTF8 -NoNewline -ErrorAction Stop
        Set-ItemProperty -LiteralPath $finalDisk -Name IsReadOnly -Value $true -ErrorAction Stop
        Set-ItemProperty -LiteralPath $finalManifest -Name IsReadOnly -Value $true -ErrorAction Stop
        $manifestHash = (Get-FileHash -LiteralPath $finalManifest -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $templatePublished = $true
        return [ordered]@{
            ok = $true
            profile = 'omarchy'
            templatePath = $finalRoot
            imagePath = $finalDisk
            manifestPath = $finalManifest
            imageSha256 = $imageSha256
            manifestSha256 = $manifestHash
            isoSha256 = $actualIsoSha256
            guestOs = 'Omarchy Linux'
            bootPolicy = $manifest.bootPolicy
            livePilotRequired = $true
        }
    }
    finally {
        if ($builderCreated) {
            try {
                $builder = Get-VM -Name $BuilderVmName -ErrorAction SilentlyContinue
                if ($null -ne $builder) {
                    if ([string]$builder.State -ieq 'Running') { Stop-VM -Name $BuilderVmName -Force -ErrorAction SilentlyContinue | Out-Null }
                    Remove-VM -Name $BuilderVmName -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }
        if (Test-Path -LiteralPath $seedPath -PathType Leaf) { Remove-Item -LiteralPath $seedPath -Force -ErrorAction SilentlyContinue }
        if (-not $templatePublished -and (Test-Path -LiteralPath $finalRoot)) { Remove-Item -LiteralPath $finalRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ([string]$MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-EpicVMOmarchyTemplateBuild
        $result | ConvertTo-Json -Depth 20
    }
    catch {
        $code = if ($_.Exception.PSObject.Properties.Name -contains 'ErrorCode') { [string]$_.Exception.ErrorCode } else { 'omarchy_template_build_failed' }
        [ordered]@{ ok = $false; error = $code } | ConvertTo-Json -Compress
        exit 1
    }
}
