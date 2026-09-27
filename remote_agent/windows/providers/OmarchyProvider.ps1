#Requires -Version 7.0
<#
    Omarchy Linux / AMD GPU-P provider primitives.

    This file intentionally does not reuse the Windows guest transport. The
    golden image is an owner-neutral Omarchy install and each VM receives a
    disposable cidata drive. The only credential that survives the bootstrap
    boundary is a DPAPI-protected per-VM management key on the host.
#>

Set-StrictMode -Version Latest

$script:EpicVMOmarchyVersion = '3.8.3'
$script:EpicVMOmarchyIsoUrl = 'https://iso.omarchy.org/omarchy-3.8.3.iso'
$script:EpicVMOmarchyIsoSha256 = '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac'
$script:EpicVMOmarchyBootstrapUser = 'epicvm-bootstrap'
$script:EpicVMOmarchyManagementTransport = 'tailscale_ssh'

function New-EpicVMOmarchyError {
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Message,
        [int] $Status = 422
    )
    $exception = [System.InvalidOperationException]::new($Message)
    $exception | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $Code -Force
    $exception | Add-Member -MemberType NoteProperty -Name HttpStatus -Value $Status -Force
    return $exception
}

function Get-EpicVMOmarchyConfigValue {
    param(
        [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if (Get-Command -Name Get-EpicVMHyperVValue -ErrorAction SilentlyContinue) {
        return Get-EpicVMHyperVValue -Object $Object -Name $Name -Default $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                return $Object[$key]
            }
        }
        return $Default
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            return $property.Value
        }
    }
    return $Default
}

function Get-EpicVMOmarchyProvisioningProfile {
    return [ordered]@{
        profile = 'omarchy'
        cpuCount = 6
        memoryBytes = 12884901888
        diskSizeBytes = 137438953472
        gpu = $true
        gpuPartition = '50%'
        guestOs = 'Omarchy Linux'
        managementTransport = $script:EpicVMOmarchyManagementTransport
        console = 'Sunshine/Moonlight'
        experimental = $true
    }
}

function ConvertTo-EpicVMOmarchyInt64 {
    param(
        [AllowNull()] [object] $Value,
        [Parameter(Mandatory)] [string] $FieldName
    )
    try {
        return [long][System.Convert]::ToInt64($Value)
    }
    catch {
        throw (New-EpicVMOmarchyError -Code 'invalid_omarchy_spec' -Message ("The Omarchy field '{0}' is invalid." -f $FieldName) -Status 400)
    }
}

function Get-EpicVMOmarchyProvisioningSpec {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Request
    )
    $profile = Get-EpicVMOmarchyProvisioningProfile
    $cpuRaw = Get-EpicVMOmarchyConfigValue -Object $Request -Name 'cpuCount' -Default $profile.cpuCount
    $memoryRaw = Get-EpicVMOmarchyConfigValue -Object $Request -Name 'memoryBytes' -Default $null
    if ($null -eq $memoryRaw) {
        $memoryGiB = Get-EpicVMOmarchyConfigValue -Object $Request -Name 'memoryGiB' -Default $null
        $memoryRaw = if ($null -ne $memoryGiB) { [decimal]$memoryGiB * 1GB } else { $profile.memoryBytes }
    }
    $diskRaw = Get-EpicVMOmarchyConfigValue -Object $Request -Name 'diskSizeBytes' -Default $null
    if ($null -eq $diskRaw) {
        $diskGiB = Get-EpicVMOmarchyConfigValue -Object $Request -Name 'diskSizeGiB' -Default $null
        $diskRaw = if ($null -ne $diskGiB) { [decimal]$diskGiB * 1GB } else { $profile.diskSizeBytes }
    }
    $percentRaw = Get-EpicVMOmarchyConfigValue -Object $Request -Name 'gpuPartitionPercent' -Default (
        Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyGpuPartitionPercent' -Default 50
    )
    $cpu = ConvertTo-EpicVMOmarchyInt64 -Value $cpuRaw -FieldName 'cpuCount'
    $memory = ConvertTo-EpicVMOmarchyInt64 -Value $memoryRaw -FieldName 'memoryBytes'
    $disk = ConvertTo-EpicVMOmarchyInt64 -Value $diskRaw -FieldName 'diskSizeBytes'
    $percent = ConvertTo-EpicVMOmarchyInt64 -Value $percentRaw -FieldName 'gpuPartitionPercent'
    $minCpu = ConvertTo-EpicVMOmarchyInt64 -Value (Get-EpicVMOmarchyConfigValue -Object $Config -Name 'MinCpuCount' -Default 1) -FieldName 'MinCpuCount'
    $maxCpu = ConvertTo-EpicVMOmarchyInt64 -Value (Get-EpicVMOmarchyConfigValue -Object $Config -Name 'MaxCpuCount' -Default 16) -FieldName 'MaxCpuCount'
    $minMemory = ConvertTo-EpicVMOmarchyInt64 -Value (Get-EpicVMOmarchyConfigValue -Object $Config -Name 'MinMemoryBytes' -Default 536870912) -FieldName 'MinMemoryBytes'
    $maxMemory = ConvertTo-EpicVMOmarchyInt64 -Value (Get-EpicVMOmarchyConfigValue -Object $Config -Name 'MaxMemoryBytes' -Default 17179869184) -FieldName 'MaxMemoryBytes'
    $maxDisk = ConvertTo-EpicVMOmarchyInt64 -Value (Get-EpicVMOmarchyConfigValue -Object $Config -Name 'MaxDiskSizeBytes' -Default 549755813888) -FieldName 'MaxDiskSizeBytes'
    if ($cpu -lt $minCpu -or $cpu -gt $maxCpu) { throw (New-EpicVMOmarchyError -Code 'invalid_omarchy_spec' -Message 'Omarchy CPU count is outside the configured limits.' -Status 400) }
    if ($memory -lt $minMemory -or $memory -gt $maxMemory) { throw (New-EpicVMOmarchyError -Code 'invalid_omarchy_spec' -Message 'Omarchy memory is outside the configured limits.' -Status 400) }
    if ($disk -le 0 -or $disk -gt $maxDisk) { throw (New-EpicVMOmarchyError -Code 'invalid_omarchy_spec' -Message 'Omarchy storage is outside the configured limits.' -Status 400) }
    if ($percent -lt 1 -or $percent -gt 100) { throw (New-EpicVMOmarchyError -Code 'invalid_omarchy_spec' -Message 'Omarchy GPU-P partition percentage must be between 1 and 100.' -Status 400) }
    $identity = [string](Get-EpicVMOmarchyConfigValue -Object $Request -Name 'gpuDeviceIdentity' -Default (
        Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF'
    ))
    if ([string]::IsNullOrWhiteSpace($identity)) { throw (New-EpicVMOmarchyError -Code 'invalid_omarchy_spec' -Message 'The Omarchy AMD GPU device identity is not configured.' -Status 400) }
    return [ordered]@{
        cpuCount = $cpu
        memoryBytes = $memory
        diskSizeBytes = $disk
        gpuPartitionPercent = $percent
        gpuDeviceIdentity = $identity
        guestOs = 'Omarchy Linux'
        managementTransport = $script:EpicVMOmarchyManagementTransport
        experimental = $true
    }
}

function Test-EpicVMOmarchyTemplateManifest {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [switch] $SkipContentHash
    )
    $manifestPath = [string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyTemplateManifestPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($field in @(
            'templateVersion', 'build', 'sha256', 'isoUrl', 'isoSha256',
            'omarchyVersion', 'guestOs', 'bootMode', 'secureBoot', 'vTpm',
            'encrypted', 'network', 'immutable', 'fullCopy', 'diskType',
            'bootPolicy', 'imagePath', 'sunshine', 'sunshineVersion', 'managementTransport',
            'consoleBackend', 'noGuestSecrets'
        )) {
            if ($null -eq (Get-EpicVMOmarchyConfigValue -Object $manifest -Name $field -Default $null)) { return $false }
        }
        $expectedVersion = [string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyVersion' -Default $script:EpicVMOmarchyVersion)
        $expectedUrl = [string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyIsoUrl' -Default $script:EpicVMOmarchyIsoUrl)
        $expectedIsoHash = [string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyIsoSha256' -Default $script:EpicVMOmarchyIsoSha256)
        if ([string]$manifest.omarchyVersion -cne $expectedVersion -or
            [string]$manifest.isoUrl -cne $expectedUrl -or
            [string]$manifest.isoSha256 -cne $expectedIsoHash) { return $false }
        if ([string]$manifest.guestOs -notmatch '(?i)^omarchy(?:\s+linux)?$' -or [string]$manifest.bootMode -ine 'uefi' -or
            [string]$manifest.bootPolicy -ine 'gen2-uefi-no-secureboot-vtpm' -or
            [bool]$manifest.secureBoot -or [bool]$manifest.vTpm -or [bool]$manifest.encrypted) { return $false }
        if ([string]$manifest.network -ine 'builder-switch-with-egress' -or [string]$manifest.diskType -ine 'Dynamic' -or
            [string]$manifest.managementTransport -ine $script:EpicVMOmarchyManagementTransport -or
            [string]$manifest.consoleBackend -ine 'sunshine-moonlight' -or
            [bool]$manifest.noGuestSecrets -ne $true -or [bool]$manifest.immutable -ne $true -or
            [bool]$manifest.fullCopy -ne $true -or [string]$manifest.sunshine -ine 'installed') { return $false }
        if ([string]$manifest.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$manifest.isoSha256 -notmatch '^[0-9a-fA-F]{64}$') { return $false }
        $manifestDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $manifestPath)).TrimEnd([char[]]@([char]92, [char]47))
        $imagePath = [IO.Path]::GetFullPath([string]$manifest.imagePath)
        if (-not ($imagePath.Equals($manifestDirectory, [StringComparison]::OrdinalIgnoreCase) -or
                $imagePath.StartsWith($manifestDirectory + '\', [StringComparison]::OrdinalIgnoreCase))) { return $false }
        if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { return $false }
        $image = Get-Item -LiteralPath $imagePath -ErrorAction Stop
        if (($image.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if (-not $SkipContentHash) {
            $actual = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne ([string]$manifest.sha256).ToLowerInvariant()) { return $false }
        }
        if (Get-Command -Name Get-VHD -ErrorAction SilentlyContinue) {
            $vhd = Get-VHD -Path $imagePath -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$vhd.ParentPath) -or [string]$vhd.VhdType -ine 'Dynamic') { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-EpicVMOmarchyProvisioningReadiness {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [AllowNull()] [object] $Provider = $null
    )
    $checks = [ordered]@{
        template = $false
        isoPin = $false
        tailscaleOAuthClient = $false
        tailscaleTailnet = $false
        tailscaleOAuthSecret = $false
        gpuPartitionable = $false
        pilotValidated = $false
        secureBootDisabled = $false
        vtpmDisabled = $false
        guestValidationRequired = $true
        linuxSshTransport = $true
    }
    try { $checks.template = [bool](Test-EpicVMOmarchyTemplateManifest -Config $Config -SkipContentHash) } catch { }
    $manifestPath = [string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyTemplateManifestPath' -Default '')
    if ($checks.template -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $checks.isoPin = [string]$manifest.isoSha256 -ceq ([string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyIsoSha256' -Default $script:EpicVMOmarchyIsoSha256))
            $checks.secureBootDisabled = -not [bool]$manifest.secureBoot
            $checks.vtpmDisabled = -not [bool]$manifest.vTpm
        } catch { }
    }
    $secretPath = [string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'TailscaleOAuthSecretPath' -Default '')
    $checks.tailscaleOAuthSecret = -not [string]::IsNullOrWhiteSpace($secretPath) -and (Test-Path -LiteralPath $secretPath -PathType Leaf)
    $checks.tailscaleOAuthClient = -not [string]::IsNullOrWhiteSpace([string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'TailscaleOAuthClientId' -Default ''))
    $checks.tailscaleTailnet = -not [string]::IsNullOrWhiteSpace([string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'TailscaleTailnet' -Default ''))
    if ($null -ne $Provider -and (Get-Command -Name Test-EpicVMHyperVGpuPartitionable -ErrorAction SilentlyContinue)) {
        try {
            $identity = [string](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF')
            $checks.gpuPartitionable = [bool](Test-EpicVMHyperVGpuPartitionable -Provider $Provider -DeviceIdentity $identity)
        } catch { $checks.gpuPartitionable = $false }
    }
    $checks.pilotValidated = [bool](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'OmarchyPilotValidated' -Default $false)
    $base = $true
    foreach ($key in @('template','isoPin','tailscaleOAuthClient','tailscaleTailnet','tailscaleOAuthSecret','gpuPartitionable','secureBootDisabled','vtpmDisabled')) {
        if (-not [bool]$checks[$key]) { $base = $false }
    }
    return [ordered]@{
        omarchy_provisioning = [bool]($base -and $checks.pilotValidated -and [bool](Get-EpicVMOmarchyConfigValue -Object $Config -Name 'EnableOmarchyProvisioning' -Default $false))
        omarchyProvisioningChecks = $checks
    }
}

function ConvertTo-EpicVMOmarchyBase64 {
    param([AllowNull()] [string] $Value)
    if ($null -eq $Value) { $Value = '' }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Invoke-EpicVMOmarchyProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [AllowNull()] [string[]] $ArgumentList = @(),
        [AllowNull()] [string] $InputText = $null,
        [int] $TimeoutSeconds = 60
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @($ArgumentList)) { [void]$psi.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw (New-EpicVMOmarchyError -Code 'omarchy_process_start_failed' -Message 'The required Omarchy helper process could not be started.' -Status 503) }
        if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
            try { $process.WaitForExit() } catch { }
            throw (New-EpicVMOmarchyError -Code 'omarchy_process_timeout' -Message 'The Omarchy helper process exceeded its bounded timeout.' -Status 504)
        }
        return [ordered]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Get-EpicVMOmarchyPasswordHash {
    param([Parameter(Mandatory)] [string] $Password)
    $openssl = Get-Command -Name 'openssl.exe','openssl' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $openssl) { throw (New-EpicVMOmarchyError -Code 'omarchy_password_hash_unavailable' -Message 'OpenSSL is required to create the Omarchy unattended password hash.' -Status 503) }
    $result = Invoke-EpicVMOmarchyProcess -FilePath $openssl.Source -ArgumentList @('passwd','-6','-stdin') -InputText ($Password + [Environment]::NewLine) -TimeoutSeconds 15
    $hash = ([string]$result.stdout).Trim()
    if ([int]$result.exitCode -ne 0 -or $hash -notmatch '^\$6\$[^$]+\$[^\s]+$') {
        throw (New-EpicVMOmarchyError -Code 'omarchy_password_hash_failed' -Message 'OpenSSL did not produce a valid Omarchy password hash.' -Status 503)
    }
    return $hash
}

function Get-EpicVMOmarchyUserConfiguration {
    param(
        [Parameter(Mandatory)] [string] $Hostname,
        [string] $Timezone = 'America/New_York',
        [string] $Keyboard = 'us'
    )
    # This is the unencrypted, full-disk archinstall shape emitted by the
    # Omarchy configurator. No disk_encryption block is ever generated here.
    return [ordered]@{
        app_config = $null
        'archinstall-language' = 'English'
        auth_config = [ordered]@{}
        audio_config = [ordered]@{ audio = 'pipewire' }
        bootloader_config = [ordered]@{ bootloader = 'Limine'; uki = $false; removable = $false }
        custom_commands = @()
        disk_config = [ordered]@{
            config_type = 'default_layout'
            device_modifications = @([ordered]@{ device = '/dev/sda'; partitions = @() })
        }
        hostname = $Hostname
        kernels = @('linux')
        network_config = [ordered]@{ type = 'iso' }
        ntp = $true
        parallel_downloads = 8
        script = $null
        services = @()
        swap = $true
        timezone = $Timezone
        locale_config = [ordered]@{ kb_layout = $Keyboard; sys_enc = 'UTF-8'; sys_lang = 'en_US.UTF-8' }
        mirror_config = [ordered]@{
            custom_repositories = @()
            custom_servers = @(
                [ordered]@{ url = 'https://mirror.omarchy.org/$repo/os/$arch' },
                [ordered]@{ url = 'https://mirror.rackspace.com/archlinux/$repo/os/$arch' },
                [ordered]@{ url = 'https://geo.mirror.pkgbuild.com/$repo/os/$arch' }
            )
            mirror_regions = [ordered]@{}
            optional_repositories = @()
        }
        packages = @(
            'base-devel', 'git', 'omarchy-keyring',
            'pciutils', 'vulkan-tools', 'mesa-utils', 'libva-utils'
        )
    }
}

function New-EpicVMOmarchySeedFiles {
    param(
        [Parameter(Mandatory)] [string] $Hostname,
        [Parameter(Mandatory)] [string] $BootstrapPassword,
        [Parameter(Mandatory)] [string] $AuthorizedKey,
        [Parameter(Mandatory)] [string] $TailscaleAuthKey,
        [string] $Timezone = 'America/New_York',
        [string] $Keyboard = 'us'
    )
    $passwordHash = Get-EpicVMOmarchyPasswordHash -Password $BootstrapPassword
    try {
        $credentials = [ordered]@{
            root_enc_password = $passwordHash
            users = @([ordered]@{
                enc_password = $passwordHash
                groups = @()
                sudo = $true
                username = $script:EpicVMOmarchyBootstrapUser
            })
        }
        return [ordered]@{
            'user_configuration.json' = ((Get-EpicVMOmarchyUserConfiguration -Hostname $Hostname -Timezone $Timezone -Keyboard $Keyboard) | ConvertTo-Json -Depth 20)
            'user_credentials.json' = ($credentials | ConvertTo-Json -Depth 10)
            'authorized_keys' = ($AuthorizedKey.Trim() + [Environment]::NewLine)
            'tailscale_authkey' = ($TailscaleAuthKey.Trim() + [Environment]::NewLine)
            'user_encrypt_installation.txt' = ('false' + [Environment]::NewLine)
        }
    }
    finally { $passwordHash = $null }
}

function Protect-EpicVMOmarchySecretText {
    param(
        [Parameter(Mandatory)] [string] $SecretText,
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Get-Command -Name Protect-EpicVMMachineSecret -ErrorAction SilentlyContinue)) {
        throw (New-EpicVMOmarchyError -Code 'omarchy_secret_store_unavailable' -Message 'The protected host-secret mechanism is unavailable.' -Status 503)
    }
    $secure = $null
    try {
        $secure = ConvertTo-SecureString $SecretText -AsPlainText -Force
        Protect-EpicVMMachineSecret -Secret $secure -Path $Path
    }
    finally { $secure = $null }
}

function Unprotect-EpicVMOmarchySecretText {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $MissingCode = 'omarchy_management_key_missing',
        [string] $UnavailableCode = 'omarchy_management_key_unavailable',
        [string] $MissingMessage = 'The protected Omarchy management key is unavailable.',
        [string] $UnavailableMessage = 'The protected Omarchy management key could not be opened.'
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (New-EpicVMOmarchyError -Code $MissingCode -Message $MissingMessage -Status 503) }
    $sealed = [IO.File]::ReadAllBytes($Path)
    $bytes = $null
    try {
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect($sealed,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [Text.Encoding]::UTF8.GetString($bytes)
    }
    catch { throw (New-EpicVMOmarchyError -Code $UnavailableCode -Message $UnavailableMessage -Status 503) }
    finally {
        if ($null -ne $sealed) { [Array]::Clear($sealed,0,$sealed.Length) }
        if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
    }
}

function New-EpicVMOmarchySshKeyPair {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $ProtectedKeyPath
    )
    $sshKeygen = Get-Command -Name 'ssh-keygen.exe','ssh-keygen' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $sshKeygen) { throw (New-EpicVMOmarchyError -Code 'omarchy_ssh_keygen_unavailable' -Message 'OpenSSH key generation is required for Omarchy bootstrap.' -Status 503) }
    New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    $rawPath = Join-Path $Directory ('.omarchy-key-' + [guid]::NewGuid().ToString('N'))
    $publicPath = $rawPath + '.pub'
    $privateText = $null
    try {
        $result = Invoke-EpicVMOmarchyProcess -FilePath $sshKeygen.Source -ArgumentList @('-q','-t','ed25519','-N','','-f',$rawPath,'-C',('epicvm-' + $VmName)) -TimeoutSeconds 30
        if ([int]$result.exitCode -ne 0 -or -not (Test-Path -LiteralPath $rawPath) -or -not (Test-Path -LiteralPath $publicPath)) {
            throw (New-EpicVMOmarchyError -Code 'omarchy_ssh_keygen_failed' -Message 'OpenSSH could not create the Omarchy management key.' -Status 503)
        }
        $privateText = Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8
        $publicText = (Get-Content -LiteralPath $publicPath -Raw -Encoding UTF8).Trim()
        Protect-EpicVMOmarchySecretText -SecretText $privateText -Path $ProtectedKeyPath
        return [ordered]@{ publicKey = $publicText; protectedKeyPath = $ProtectedKeyPath }
    }
    finally {
        $privateText = $null
        foreach ($path in @($rawPath,$publicPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }
}

function New-EpicVMOmarchySeedDisk {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Files
    )
    if (-not (Get-Command -Name Invoke-EpicVMHyperVCmdlet -ErrorAction SilentlyContinue)) {
        throw (New-EpicVMOmarchyError -Code 'omarchy_seed_storage_unavailable' -Message 'The Hyper-V storage command boundary is unavailable.' -Status 503)
    }
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    $mounted = $false
    $drive = $null
    try {
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'New-VHD' -Parameters @{ Path=$Path; SizeBytes=67108864; Dynamic=$true; ErrorAction='Stop' } | Out-Null
        $mountedDisk = Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Mount-VHD' -Parameters @{ Path=$Path; Passthru=$true; ErrorAction='Stop' }
        $mounted = $true
        $diskNumber = Get-EpicVMOmarchyConfigValue -Object $mountedDisk -Name 'DiskNumber' -Default $null
        if ($null -eq $diskNumber) { throw (New-EpicVMOmarchyError -Code 'omarchy_seed_mount_failed' -Message 'The cidata disk number could not be resolved.' -Status 503) }
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Initialize-Disk' -Parameters @{ Number=[int]$diskNumber; PartitionStyle='GPT'; ErrorAction='Stop' } | Out-Null
        $partition = Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'New-Partition' -Parameters @{ DiskNumber=[int]$diskNumber; UseMaximumSize=$true; AssignDriveLetter=$true; ErrorAction='Stop' }
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Format-Volume' -Parameters @{ Partition=$partition; FileSystem='FAT32'; NewFileSystemLabel='cidata'; Confirm=$false; ErrorAction='Stop' } | Out-Null
        $letter = [string](Get-EpicVMOmarchyConfigValue -Object $partition -Name 'DriveLetter' -Default '')
        if ([string]::IsNullOrWhiteSpace($letter)) { throw (New-EpicVMOmarchyError -Code 'omarchy_seed_mount_failed' -Message 'The cidata drive letter could not be resolved.' -Status 503) }
        $drive = $letter + ':\'
        foreach ($entry in $Files.GetEnumerator()) {
            $target = Join-Path $drive $entry.Key
            [IO.File]::WriteAllText($target,[string]$entry.Value,[Text.UTF8Encoding]::new($false))
        }
        return [ordered]@{ path=$Path; label='cidata'; files=@($Files.Keys) }
    }
    catch {
        if ($_.Exception.PSObject.Properties['ErrorCode']) { throw }
        throw (New-EpicVMOmarchyError -Code 'omarchy_seed_failed' -Message 'The Omarchy cidata seed could not be prepared.' -Status 503)
    }
    finally {
        if ($mounted) {
            try { Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Dismount-VHD' -Parameters @{ Path=$Path; ErrorAction='SilentlyContinue' } | Out-Null } catch { }
        }
        $drive = $null
    }
}

function Prepare-EpicVMOmarchyBootstrap {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $vmRoot = Join-Path $root $VmName
    $seedPath = Join-Path $vmRoot ($VmName + '.cidata.vhdx')
    $protectedKeyPath = Join-Path $vmRoot 'omarchy-management-key.dpapi'
    $protectedBootstrapPasswordPath = Join-Path $vmRoot 'omarchy-bootstrap-password.dpapi'
    $bootstrapPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
    $authKey = $null
    $key = $null
    try {
        if (-not (Get-Command -Name New-EpicVMTailscaleAuthKey -ErrorAction SilentlyContinue)) {
            throw (New-EpicVMOmarchyError -Code 'omarchy_tailscale_unavailable' -Message 'The Tailscale auth-key provider is unavailable.' -Status 503)
        }
        $authKey = New-EpicVMTailscaleAuthKey -Provider $Provider -VmName $VmName
        Protect-EpicVMOmarchySecretText -SecretText $bootstrapPassword -Path $protectedBootstrapPasswordPath
        $key = New-EpicVMOmarchySshKeyPair -Directory $vmRoot -VmName $VmName -ProtectedKeyPath $protectedKeyPath
        $publicPath = Join-Path $vmRoot 'omarchy-management-public.key'
        [IO.File]::WriteAllText($publicPath,[string]$key.publicKey,[Text.UTF8Encoding]::new($false))
        $files = New-EpicVMOmarchySeedFiles -Hostname $VmName -BootstrapPassword $bootstrapPassword -AuthorizedKey $key.publicKey -TailscaleAuthKey $authKey -Timezone ([string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'OmarchyTimezone' -Default 'America/New_York')) -Keyboard ([string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'OmarchyKeyboard' -Default 'us'))
        $seed = New-EpicVMOmarchySeedDisk -Provider $Provider -Path $seedPath -Files $files
        return [ordered]@{
            seedPath = $seed.path
            protectedKeyPath = $key.protectedKeyPath
            protectedBootstrapPasswordPath = $protectedBootstrapPasswordPath
            publicKey = $key.publicKey
            bootstrapUser = $script:EpicVMOmarchyBootstrapUser
        }
    }
    catch {
        if (Test-Path -LiteralPath $seedPath) { Remove-Item -LiteralPath $seedPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $protectedKeyPath) { Remove-Item -LiteralPath $protectedKeyPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $protectedBootstrapPasswordPath) { Remove-Item -LiteralPath $protectedBootstrapPasswordPath -Force -ErrorAction SilentlyContinue }
        if ($_.Exception.PSObject.Properties['ErrorCode']) { throw }
        throw (New-EpicVMOmarchyError -Code 'omarchy_bootstrap_prepare_failed' -Message 'The Omarchy bootstrap material could not be prepared.' -Status 503)
    }
    finally {
        $bootstrapPassword = $null
        $authKey = $null
        $key = $null
        $files = $null
    }
}

function Invoke-EpicVMOmarchySsh {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $Address,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $ProtectedKeyPath,
        [Parameter(Mandatory)] [string] $Script,
        [AllowNull()] [string] $SudoPassword = $null,
        [int] $TimeoutSeconds = 90
    )
    if ($Address -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$') {
        throw (New-EpicVMOmarchyError -Code 'omarchy_ssh_address_invalid' -Message 'The Omarchy guest address is not a verified Tailscale address.' -Status 422)
    }
    $ssh = Get-Command -Name 'ssh.exe','ssh' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $ssh) { throw (New-EpicVMOmarchyError -Code 'omarchy_ssh_unavailable' -Message 'OpenSSH is required for the Omarchy management transport.' -Status 503) }
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $knownHostsPath = Join-Path (Join-Path $root $VmName) 'omarchy-known-hosts'
    $tempKey = Join-Path ([IO.Path]::GetTempPath()) ('epicvm-omarchy-' + [guid]::NewGuid().ToString('N') + '.key')
    $privateKey = $null
    try {
        $privateKey = Unprotect-EpicVMOmarchySecretText -Path $ProtectedKeyPath
        [IO.File]::WriteAllText($tempKey,$privateKey,[Text.UTF8Encoding]::new($false))
        $input = if ($null -ne $SudoPassword) { $SudoPassword + [Environment]::NewLine + $Script } else { $Script }
        $remoteCommand = if ($null -ne $SudoPassword) { 'sudo -S -p "" bash -s' } else { 'bash -s' }
        $args = @(
            '-o','BatchMode=yes',
            '-o','StrictHostKeyChecking=accept-new',
            '-o',('UserKnownHostsFile=' + $knownHostsPath),
            '-o','IdentitiesOnly=yes',
            '-o','ConnectTimeout=10',
            '-i',$tempKey,
            ($Username + '@' + $Address),
            $remoteCommand
        )
        return Invoke-EpicVMOmarchyProcess -FilePath $ssh.Source -ArgumentList $args -InputText $input -TimeoutSeconds $TimeoutSeconds
    }
    finally {
        $privateKey = $null
        if (Test-Path -LiteralPath $tempKey) { Remove-Item -LiteralPath $tempKey -Force -ErrorAction SilentlyContinue }
    }
}

function Get-EpicVMOmarchyGuestConfigurationScript {
    param(
        [Parameter(Mandatory)] [string] $DesiredUser,
        [Parameter(Mandatory)] [string] $DesiredPassword,
        [Parameter(Mandatory)] [string] $ManagementPublicKey
    )
    $userB64 = ConvertTo-EpicVMOmarchyBase64 -Value $DesiredUser
    $passwordB64 = ConvertTo-EpicVMOmarchyBase64 -Value $DesiredPassword
    $keyB64 = ConvertTo-EpicVMOmarchyBase64 -Value $ManagementPublicKey
    $template = @'
set -euo pipefail
decode() { printf '%s' "$1" | base64 -d; }
desired_user="$(decode '__USER_B64__')"
desired_password="$(decode '__PASSWORD_B64__')"
management_key="$(decode '__KEY_B64__')"
bootstrap_user='__BOOTSTRAP_USER__'
if ! id "$desired_user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups wheel "$desired_user"
else
  usermod --shell /bin/bash --append --groups wheel "$desired_user"
fi
printf '%s:%s\n' "$desired_user" "$desired_password" | chpasswd
install -d -m 700 -o "$desired_user" -g "$desired_user" "/home/$desired_user/.ssh"
printf '%s\n' "$management_key" > "/home/$desired_user/.ssh/authorized_keys"
chown "$desired_user:$desired_user" "/home/$desired_user/.ssh/authorized_keys"
chmod 600 "/home/$desired_user/.ssh/authorized_keys"
install -d -m 755 /etc/ssh/sshd_config.d
printf '%s\n' 'PubkeyAuthentication yes' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/epicvm.conf
sshd -t
systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh
if id "$bootstrap_user" >/dev/null 2>&1 && [ "$bootstrap_user" != "$desired_user" ]; then
  userdel --remove "$bootstrap_user" 2>/dev/null || userdel "$bootstrap_user" 2>/dev/null || true
fi
systemctl disable --now epicvm-omarchy-bootstrap.service 2>/dev/null || true
rm -f /etc/omarchy-epicvm-bootstrap /etc/systemd/system/epicvm-omarchy-bootstrap.service
systemctl daemon-reload 2>/dev/null || true
printf '%s\n' EPICVM_OMARCHY_GUEST_READY
'@
    return $template.Replace('__USER_B64__',$userB64).Replace('__PASSWORD_B64__',$passwordB64).Replace('__KEY_B64__',$keyB64).Replace('__BOOTSTRAP_USER__',$script:EpicVMOmarchyBootstrapUser)
}

function Invoke-EpicVMOmarchyGuestConfiguration {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $DesiredUser,
        [Parameter(Mandatory)] [string] $DesiredPassword
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $vmRoot = Join-Path $root $VmName
    $keyPath = Join-Path $vmRoot 'omarchy-management-key.dpapi'
    $bootstrapPasswordPath = Join-Path $vmRoot 'omarchy-bootstrap-password.dpapi'
    $publicKey = [string](Get-Content -LiteralPath (Join-Path $vmRoot 'omarchy-management-public.key') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($publicKey)) {
        throw (New-EpicVMOmarchyError -Code 'omarchy_management_key_metadata_missing' -Message 'The Omarchy management public-key metadata is unavailable.' -Status 503)
    }
    $guestIp = [string](Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'LastOmarchyGuestIp' -Default '')
    $scriptText = Get-EpicVMOmarchyGuestConfigurationScript -DesiredUser $DesiredUser -DesiredPassword $DesiredPassword -ManagementPublicKey $publicKey.Trim()
    $bootstrapPassword = $null
    try {
        $bootstrapPassword = Unprotect-EpicVMOmarchySecretText -Path $bootstrapPasswordPath `
            -MissingCode 'omarchy_bootstrap_password_missing' `
            -UnavailableCode 'omarchy_bootstrap_password_unavailable' `
            -MissingMessage 'The protected Omarchy bootstrap password is unavailable.' `
            -UnavailableMessage 'The protected Omarchy bootstrap password could not be opened.'
        $result = Invoke-EpicVMOmarchySsh -Provider $Provider -VmName $VmName -Address $guestIp -Username $script:EpicVMOmarchyBootstrapUser -ProtectedKeyPath $keyPath -Script $scriptText -SudoPassword $bootstrapPassword -TimeoutSeconds 120
    }
    finally {
        $bootstrapPassword = $null
    }
    $ok = [int]$result.exitCode -eq 0 -and [string]$result.stdout -match 'EPICVM_OMARCHY_GUEST_READY'
    if ($ok -and (Test-Path -LiteralPath $bootstrapPasswordPath)) { Remove-Item -LiteralPath $bootstrapPasswordPath -Force -ErrorAction SilentlyContinue }
    return [ordered]@{ ok=$ok; managementTransport=$script:EpicVMOmarchyManagementTransport; failureDetailCode=if($ok){$null}else{'account_verification_failed'} }
}

function Get-EpicVMOmarchyNetworkSnapshot {
    param([Parameter(Mandatory)] [object] $Provider)
    if (-not (Get-Command -Name Invoke-EpicVMTailscaleHttp -ErrorAction SilentlyContinue)) { throw 'Tailscale API provider unavailable.' }
    $tailnet = [string](Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'TailscaleTailnet' -Default '')
    $access = Get-EpicVMTailscaleAccessToken -Provider $Provider
    try {
        $response = Invoke-EpicVMTailscaleHttp -Provider $Provider -Method 'GET' -Path ('tailnet/' + [Uri]::EscapeDataString($tailnet) + '/devices') -AccessToken $access -TimeoutSeconds 20
        return @((Get-EpicVMOmarchyConfigValue -Object $response -Name 'devices' -Default @()))
    }
    finally { $access = $null }
}

function Wait-EpicVMOmarchyGuestReady {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName,
        [int] $TimeoutSeconds = 600,
        [int] $PollMilliseconds = 2000,
        [AllowNull()] [string] $ProbeUsername = $null
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $keyPath = Join-Path (Join-Path $root $VmName) 'omarchy-management-key.dpapi'
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1,$TimeoutSeconds))
    do {
        try {
            $devices = Get-EpicVMOmarchyNetworkSnapshot -Provider $Provider
            $device = @($devices | Where-Object { [string](Get-EpicVMOmarchyConfigValue -Object $_ -Name 'hostname' -Default '') -ceq $VmName }) | Select-Object -First 1
            $addresses = @((Get-EpicVMOmarchyConfigValue -Object $device -Name 'addresses' -Default @()))
            $ip = [string](@($addresses | Where-Object { [string]$_ -match '^100\.' }) | Select-Object -First 1)
            if ($ip -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$') {
                $probeScript = "set -e" + [Environment]::NewLine + "printf '%s\n' EPICVM_OMARCHY_SSH_READY" + [Environment]::NewLine
                $probeUser = if ([string]::IsNullOrWhiteSpace($ProbeUsername)) { $script:EpicVMOmarchyBootstrapUser } else { $ProbeUsername }
                $probe = Invoke-EpicVMOmarchySsh -Provider $Provider -VmName $VmName -Address $ip -Username $probeUser -ProtectedKeyPath $keyPath -Script $probeScript -TimeoutSeconds 30
                if ([int]$probe.exitCode -eq 0 -and [string]$probe.stdout -match 'EPICVM_OMARCHY_SSH_READY') {
                    $deviceId = [string](Get-EpicVMOmarchyConfigValue -Object $device -Name 'id' -Default '')
                    if ([string]::IsNullOrWhiteSpace($deviceId) -and (Get-Command -Name Get-EpicVMTailscaleDeviceId -ErrorAction SilentlyContinue)) {
                        $deviceId = [string](Get-EpicVMTailscaleDeviceId -Provider $Provider -VmName $VmName -GuestIp $ip)
                    }
                    if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
                        $Provider.LastOmarchyGuestIp = $ip
                        return [ordered]@{ ok=$true; ip=$ip; deviceId=$deviceId; managementReady=$true; managementTransport=$script:EpicVMOmarchyManagementTransport; guestOs='Omarchy Linux' }
                    }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds ([Math]::Max(250,$PollMilliseconds))
    } while ([DateTime]::UtcNow -lt $deadline)
    throw (New-EpicVMOmarchyError -Code 'omarchy_bootstrap_not_ready' -Message 'The Omarchy guest did not become reachable over Tailscale SSH before the bounded timeout.' -Status 503)
}

function Get-EpicVMOmarchyGuestValidationScript {
    return @'
set +e
gpu=false
render=false
accelerated=false
wayland=false
sunshine=false
encoder=false
gpu_detail="$(lspci -nn 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' | head -n 1)"
if printf '%s' "$gpu_detail" | grep -Eqi 'AMD|ATI|1002:'; then gpu=true; fi
render_devices="$(find /dev/dri -maxdepth 1 -type c -name 'renderD*' 2>/dev/null | sort)"
if [ -n "$render_devices" ]; then render=true; fi
renderer="$(vulkaninfo --summary 2>/dev/null || glxinfo -B 2>/dev/null || true)"
if printf '%s' "$renderer" | grep -Eqi 'AMD|RADV|Mesa.*AMD' && ! printf '%s' "$renderer" | grep -Eqi 'llvmpipe|softpipe|lavapipe'; then accelerated=true; fi
if pgrep -x Hyprland >/dev/null 2>&1 || pgrep -x hyprland >/dev/null 2>&1; then wayland=true; fi
if systemctl is-active --quiet sunshine.service 2>/dev/null || systemctl --user is-active --quiet sunshine.service 2>/dev/null || pgrep -x sunshine >/dev/null 2>&1; then sunshine=true; fi
while IFS= read -r render_device; do
  [ -n "$render_device" ] || continue
  va="$(vainfo --display drm --device "$render_device" 2>/dev/null || true)"
  if printf '%s' "$va" | grep -Eqi 'VAEntrypointEncSlice|VAEntrypointEncPicture|H264.*Enc|HEVC.*Enc|AV1.*Enc'; then
    encoder=true
    break
  fi
done <<EOF
$render_devices
EOF
printf 'EPICVM_OMARCHY_GPU=%s\n' "$gpu"
printf 'EPICVM_OMARCHY_RENDER=%s\n' "$render"
printf 'EPICVM_OMARCHY_ACCELERATED=%s\n' "$accelerated"
printf 'EPICVM_OMARCHY_WAYLAND=%s\n' "$wayland"
printf 'EPICVM_OMARCHY_SUNSHINE=%s\n' "$sunshine"
printf 'EPICVM_OMARCHY_ENCODER=%s\n' "$encoder"
'@
}

function Invoke-EpicVMOmarchyGuestValidation {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $GuestUsername,
        [Parameter(Mandatory)] [string] $GuestAddress,
        [bool] $RequireSunshine = $true
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $keyPath = Join-Path (Join-Path $root $VmName) 'omarchy-management-key.dpapi'
    $result = Invoke-EpicVMOmarchySsh -Provider $Provider -VmName $VmName -Address $GuestAddress -Username $GuestUsername -ProtectedKeyPath $keyPath -Script (Get-EpicVMOmarchyGuestValidationScript) -TimeoutSeconds 120
    $text = [string]$result.stdout
    $flags = [ordered]@{}
    foreach ($name in @('GPU','RENDER','ACCELERATED','WAYLAND','SUNSHINE','ENCODER')) {
        $flags[$name] = $text -match ('EPICVM_OMARCHY_' + $name + '=true')
    }
    $baseOk = $flags.GPU -and $flags.RENDER -and $flags.ACCELERATED -and $flags.WAYLAND
    $streamOk = $flags.SUNSHINE -and $flags.ENCODER
    $ok = [int]$result.exitCode -eq 0 -and $baseOk -and ((-not $RequireSunshine) -or $streamOk)
    $detail = if (-not $flags.GPU -or -not $flags.RENDER) { 'OMARCHY_GPU_DEVICE_MISSING' }
        elseif (-not $flags.ACCELERATED -or -not $flags.WAYLAND) { 'OMARCHY_SOFTWARE_RENDERER' }
        elseif ($RequireSunshine -and (-not $flags.SUNSHINE -or -not $flags.ENCODER)) { 'OMARCHY_SUNSHINE_ENCODER' }
        else { $null }
    return [ordered]@{
        ok = $ok
        guestOs = 'Omarchy Linux'
        gpuVisible = [bool]$flags.GPU
        renderDevice = [bool]$flags.RENDER
        acceleratedRenderer = [bool]$flags.ACCELERATED
        waylandSession = [bool]$flags.WAYLAND
        sunshine = [bool]$flags.SUNSHINE
        hardwareEncoder = [bool]$flags.ENCODER
        failureDetailCode = $detail
    }
}

function Get-EpicVMOmarchySunshineScript {
    param(
        [Parameter(Mandatory)] [string] $SunshineUsername,
        [Parameter(Mandatory)] [string] $SunshinePassword
    )
    $usernameB64 = ConvertTo-EpicVMOmarchyBase64 -Value $SunshineUsername
    $passwordB64 = ConvertTo-EpicVMOmarchyBase64 -Value $SunshinePassword
    $template = @'
set -euo pipefail
decode() { printf '%s' "$1" | base64 -d; }
sunshine_user="$(decode '__SUNSHINE_USER_B64__')"
sunshine_password="$(decode '__SUNSHINE_PASSWORD_B64__')"
mkdir -p "$HOME/.config/sunshine"
render_device="$(find /dev/dri -maxdepth 1 -type c -name 'renderD*' 2>/dev/null | sort | head -n 1)"
if [ -z "$render_device" ]; then
  printf '%s\n' 'No DRM render device is available for Sunshine.' >&2
  exit 42
fi
printf 'adapter = %s\nencoder = vaapi\n' "$render_device" > "$HOME/.config/sunshine/sunshine.conf"
if command -v sunshine >/dev/null 2>&1; then
  sunshine --creds "$sunshine_user" "$sunshine_password" >/dev/null 2>&1 || true
fi
systemctl --user enable --now sunshine.service 2>/dev/null || systemctl enable --now sunshine.service 2>/dev/null || true
printf '%s\n' EPICVM_OMARCHY_SUNSHINE_CONFIGURED
'@
    return $template.Replace('__SUNSHINE_USER_B64__',$usernameB64).Replace('__SUNSHINE_PASSWORD_B64__',$passwordB64)
}

function Invoke-EpicVMOmarchySunshineConfiguration {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $GuestUsername,
        [Parameter(Mandatory)] [string] $GuestPassword,
        [Parameter(Mandatory)] [string] $SunshineUsername,
        [Parameter(Mandatory)] [string] $SunshinePassword,
        [Parameter(Mandatory)] [string] $GuestAddress
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $keyPath = Join-Path (Join-Path $root $VmName) 'omarchy-management-key.dpapi'
        $result = Invoke-EpicVMOmarchySsh -Provider $Provider -VmName $VmName -Address $GuestAddress -Username $GuestUsername -ProtectedKeyPath $keyPath -Script (Get-EpicVMOmarchySunshineScript -SunshineUsername $SunshineUsername -SunshinePassword $SunshinePassword) -TimeoutSeconds 120
    if ([int]$result.exitCode -ne 0 -or [string]$result.stdout -notmatch 'EPICVM_OMARCHY_SUNSHINE_CONFIGURED') {
        throw (New-EpicVMOmarchyError -Code 'omarchy_sunshine_configuration_failed' -Message 'Omarchy Sunshine configuration did not verify.' -Status 422)
    }
    $validation = Invoke-EpicVMOmarchyGuestValidation -Provider $Provider -VmName $VmName -GuestUsername $GuestUsername -GuestAddress $GuestAddress -RequireSunshine $true
    if (-not [bool]$validation.ok) {
        throw (New-EpicVMOmarchyError -Code 'omarchy_encoder_unavailable' -Message 'Omarchy Sunshine hardware encoding and accelerated guest rendering were not verified.' -Status 422)
    }
    return [ordered]@{
        ok = $true
        managementReady = $true
        managementTransport = $script:EpicVMOmarchyManagementTransport
        sunshineReady = $true
        hardwareEncoder = $true
        guestValidation = $validation
    }
}

function Remove-EpicVMOmarchySeed {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $seedPath = Join-Path (Join-Path $root $VmName) ($VmName + '.cidata.vhdx')
    try {
        if (Get-Command -Name Invoke-EpicVMHyperVCmdlet -ErrorAction SilentlyContinue) {
            $drives = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMHardDiskDrive' -Parameters @{ VMName=$VmName; ErrorAction='SilentlyContinue' })
            foreach ($drive in $drives) {
                if ([string](Get-EpicVMOmarchyConfigValue -Object $drive -Name 'Path' -Default '') -ieq $seedPath) {
                    Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Remove-VMHardDiskDrive' -Parameters @{
                        VMName=$VmName
                        ControllerType=Get-EpicVMOmarchyConfigValue -Object $drive -Name 'ControllerType' -Default 'SCSI'
                        ControllerNumber=[int](Get-EpicVMOmarchyConfigValue -Object $drive -Name 'ControllerNumber' -Default 0)
                        ControllerLocation=[int](Get-EpicVMOmarchyConfigValue -Object $drive -Name 'ControllerLocation' -Default 1)
                        ErrorAction='SilentlyContinue'
                    } | Out-Null
                }
            }
        }
    } catch { }
    if (Test-Path -LiteralPath $seedPath) { Remove-Item -LiteralPath $seedPath -Force -ErrorAction SilentlyContinue }
    return [ordered]@{ ok=$true; seedRemoved=$true }
}

function Remove-EpicVMOmarchyBootstrapArtifacts {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $vmRoot = Join-Path $root $VmName
    # This callback is only used before a claim is consumed, when the VM is
    # being discarded. It removes exactly the generated per-VM bootstrap
    # files; it never searches or cleans a wider directory.
    Remove-EpicVMOmarchySeed -Provider $Provider -VmName $VmName | Out-Null
    foreach ($path in @(
        (Join-Path $vmRoot 'omarchy-bootstrap-password.dpapi'),
        (Join-Path $vmRoot 'omarchy-management-key.dpapi'),
        (Join-Path $vmRoot 'omarchy-management-public.key'),
        (Join-Path $vmRoot 'omarchy-known-hosts')
    )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    return [ordered]@{ ok=$true; bootstrapRemoved=$true; seedRemoved=$true }
}

function Invoke-EpicVMOmarchyBootstrapCleanup {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $GuestUsername,
        [Parameter(Mandatory)] [string] $GuestAddress
    )
    $config = Get-EpicVMOmarchyConfigValue -Object $Provider -Name 'Config' -Default @{}
    $root = [string](Get-EpicVMOmarchyConfigValue -Object $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    $vmRoot = Join-Path $root $VmName
    $keyPath = Join-Path $vmRoot 'omarchy-management-key.dpapi'
    $bootstrapPasswordPath = Join-Path $vmRoot 'omarchy-bootstrap-password.dpapi'
    $cleanupScript = @'
set -euo pipefail
if id '__BOOTSTRAP_USER__' >/dev/null 2>&1 && [ '__BOOTSTRAP_USER__' != '__GUEST_USER__' ]; then exit 41; fi
if test -e /etc/omarchy-epicvm-bootstrap || test -e /etc/systemd/system/epicvm-omarchy-bootstrap.service; then exit 42; fi
printf '%s\n' EPICVM_OMARCHY_BOOTSTRAP_CLEAN
'@
    $cleanupScript = $cleanupScript.Replace('__BOOTSTRAP_USER__',$script:EpicVMOmarchyBootstrapUser).Replace('__GUEST_USER__',$GuestUsername)
    $result = Invoke-EpicVMOmarchySsh -Provider $Provider -VmName $VmName -Address $GuestAddress -Username $GuestUsername -ProtectedKeyPath $keyPath -Script $cleanupScript -TimeoutSeconds 90
    Remove-EpicVMOmarchySeed -Provider $Provider -VmName $VmName | Out-Null
    if (Test-Path -LiteralPath $bootstrapPasswordPath) { Remove-Item -LiteralPath $bootstrapPasswordPath -Force -ErrorAction SilentlyContinue }
    $ok = [int]$result.exitCode -eq 0 -and [string]$result.stdout -match 'EPICVM_OMARCHY_BOOTSTRAP_CLEAN'
    if (-not $ok) { throw (New-EpicVMOmarchyError -Code 'omarchy_bootstrap_cleanup_failed' -Message 'Omarchy bootstrap cleanup did not verify.' -Status 422) }
    return [ordered]@{ ok=$true; bootstrapRemoved=$true; seedRemoved=$true; managementKeyRetained=$true }
}
