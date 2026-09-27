#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\ProgramData\EpicVM\agent',
    [string] $VmRoot = 'E:\EpicVM\vms',
    [int] $Port = 8765,
    [string] $TailscaleAddress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
. (Join-Path $sourceRoot 'ServiceRuntime.ps1')
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$pwsh = Resolve-EpicVMServiceRuntime -InstallRoot $InstallRoot
New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'providers') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'logs') -Force | Out-Null
$vmDrive = Split-Path -Qualifier $VmRoot
if ([string]::IsNullOrWhiteSpace($vmDrive) -or -not (Test-Path -LiteralPath $vmDrive)) {
    throw 'The configured EpicVM VM drive is unavailable.'
}
$VmRoot = [IO.Path]::GetFullPath($VmRoot)
New-Item -ItemType Directory -Path $VmRoot -Force | Out-Null
New-Item -ItemType Directory -Path 'E:\EpicVM\templates' -Force | Out-Null

$tokenPath = Join-Path $InstallRoot 'agent.txt'
$legacyTokenPath = Join-Path $InstallRoot 'agent.token'
if (Test-Path -LiteralPath $tokenPath) {
    $token = (Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8).Trim()
}
elseif (Test-Path -LiteralPath $legacyTokenPath) {
    $tokenPath = $legacyTokenPath
    $token = (Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8).Trim()
}
else {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    Set-Content -LiteralPath $tokenPath -Value $token -Encoding ascii -NoNewline
}

$agentPath = Join-Path $InstallRoot 'EpicVM.Agent.ps1'
$providerPath = Join-Path $InstallRoot 'providers/HyperVProvider.ps1'
Copy-Item -LiteralPath (Join-Path $sourceRoot 'EpicVM.Agent.ps1') -Destination $agentPath -Force
foreach ($sourceFile in @('Provisioning.ps1','TemplateBuilder.ps1','Set-TailscaleOAuthSecret.ps1','ServiceRuntime.ps1','AgentTransport.ps1','SharedGames.ps1','SharedGamesWorker.ps1','SharedGamesCodex.ps1','HostGaming.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $sourceFile) -Destination (Join-Path $InstallRoot $sourceFile) -Force
}
foreach ($providerFile in @('HyperVProvider.ps1','GuestProvider.ps1','TailscaleProvider.ps1','GamingGpuPProvider.ps1','OmarchyProvider.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot ('providers/' + $providerFile)) -Destination (Join-Path $InstallRoot ('providers/' + $providerFile)) -Force
}
$configPath = Join-Path $InstallRoot 'config.json'
if ([string]::IsNullOrWhiteSpace($TailscaleAddress)) {
    $tailscaleAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -match '^100\.(6[4-9]|[7-9][0-9])\.' } |
        Select-Object -ExpandProperty IPAddress)
    if ($tailscaleAddresses.Count -eq 1) {
        $TailscaleAddress = [string]$tailscaleAddresses[0]
    }
}
if ([string]::IsNullOrWhiteSpace($TailscaleAddress) -or $TailscaleAddress -notmatch '^100\.(6[4-9]|[7-9][0-9])\.(\d{1,3})\.(\d{1,3})$') {
    throw 'A single Tailscale IPv4 address is required. Pass -TailscaleAddress 100.x.y.z.'
}
$config = [ordered]@{
    BindAddress = $TailscaleAddress
    Port = $Port
    Provider = 'HyperV'
    TokenFile = $tokenPath
    ConfigFile = $configPath
    VmRoot = $VmRoot
    SwitchName = ''
    DefaultMemoryBytes = 4294967296
    DefaultCpuCount = 2
    DefaultDiskSizeBytes = 68719476736
    MinMemoryBytes = 536870912
    MaxMemoryBytes = 17179869184
    MinCpuCount = 1
    MaxCpuCount = 16
    MaxDiskSizeBytes = 549755813888
    Generation = 2
    TemplateManifestPath = 'E:\EpicVM\templates\win11-25h2\manifest.json'
    OmarchyTemplateManifestPath = 'E:\EpicVM\templates\omarchy-3.8.3\manifest.json'
    OmarchyVersion = '3.8.3'
    OmarchyIsoUrl = 'https://iso.omarchy.org/omarchy-3.8.3.iso'
    OmarchyIsoSha256 = '40c9368eeb7e021a13d0899b379517843b4839f6e7721473169369fbd0fe61ac'
    OmarchyGpuDeviceIdentity = 'VEN_1002&DEV_73BF'
    OmarchyGpuPartitionPercent = 50
    OmarchyPilotValidated = $false
    ProvisioningStatePath = 'E:\EpicVM\provisioning-jobs.json'
    GamingVMNames = @('testre')
    GamingGpuDeviceIdentity = 'VEN_1002&DEV_73BF'
    GamingGpuPartitionPercent = 50
    GamingDriverStoreRoot = 'C:\Windows\System32\DriverStore\FileRepository'
    GamingDriverSourcePaths = @()
    BootstrapUser = 'EpicVMBootstrap'
    BootstrapCredentialPath = (Join-Path $InstallRoot 'bootstrap.dpapi')
    TailscaleOAuthClientId = ''
    TailscaleOAuthSecretPath = (Join-Path $InstallRoot 'tailscale-oauth.dpapi')
    TailscaleTailnet = ''
    TailscaleGuestTag = 'tag:epicvm-guest'
    TailscaleExecutable = 'C:\Program Files\Tailscale\tailscale.exe'
    SunshineServiceName = 'SunshineService'
    SunshineVersion = '2026.516.143833'
    SunshineStatePaths = @(
        'C:\Program Files\Sunshine\config\sunshine_state.json',
        'C:\ProgramData\Sunshine\config\sunshine_state.json'
    )
    EnableGamingProvisioning = $false
    EnableOmarchyProvisioning = $false
}
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $existingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $existingConfig.PSObject.Properties) { $config[$property.Name] = $property.Value }
    }
    catch { throw 'The existing EpicVM agent configuration is invalid; it was not overwritten.' }
}
$config.BindAddress = $TailscaleAddress
$config.Port = $Port
$config.Provider = 'HyperV'
$config.TokenFile = $tokenPath
$config.ConfigFile = $configPath
$config.VmRoot = $VmRoot
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8

# Keep the credential readable only by LocalSystem and local administrators.
$acl = Get-Acl -LiteralPath $tokenPath
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
foreach ($identity in @('SYSTEM', 'Administrators')) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'Read', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $tokenPath -AclObject $acl

$serviceName = 'EpicVMRemoteAgent'
$nssm = Join-Path $InstallRoot 'nssm.exe'
if (-not (Test-Path -LiteralPath $nssm -PathType Leaf)) {
    throw 'The existing EpicVM NSSM service wrapper is required and was not found.'
}
$appParameters = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $agentPath, $configPath
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne 'Stopped') { Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue }
    # Preserve the existing LocalSystem service identity and restore the NSSM
    # wrapper if a previous installer accidentally pointed SCM at pwsh.exe.
    sc.exe config $serviceName binPath= ('"' + $nssm + '"') start= auto | Out-Null
}
else {
    & $nssm install $serviceName $pwsh $appParameters | Out-Null
    sc.exe config $serviceName DisplayName= 'EpicVM RemoteVM Agent' start= auto obj= LocalSystem | Out-Null
}
& $nssm set $serviceName Application $pwsh | Out-Null
& $nssm set $serviceName AppParameters $appParameters | Out-Null
& $nssm set $serviceName AppDirectory $InstallRoot | Out-Null
& $nssm set $serviceName Start SERVICE_AUTO_START | Out-Null

# Do not expose the API to the public network. Tailscale uses 100.64.0.0/10.
$ruleName = 'EpicVM RemoteVM Agent (Tailscale)'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null
Start-Service -Name $serviceName

$healthUri = "http://$TailscaleAddress`:$Port/v1/health"
$healthy = $false
for ($attempt = 0; $attempt -lt 10; $attempt++) {
    try {
        $health = Invoke-RestMethod -Uri $healthUri -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 2 -ErrorAction Stop
        if ($health.ok -eq $true) { $healthy = $true; break }
    }
    catch { Start-Sleep -Seconds 1 }
}
if (-not $healthy) {
    throw 'EpicVM RemoteVM agent did not pass its local health check after installation.'
}

Write-Output "EpicVM RemoteVM agent installed: $serviceName"
Write-Output "Agent endpoint: http://<tailscale-host>:${Port}/v1/health"
Write-Output "Token file: $tokenPath"
Write-Output 'Enrollment token is stored in the protected token file and is not printed.'
