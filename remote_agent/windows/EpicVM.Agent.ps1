# Requires -Version 7.0
<#
    EpicVM RemoteVM host agent.

    The script is both a small HTTP service and a dot-sourceable request
    dispatcher.  Pester tests use -NoStart and call Invoke-EpicVMApiRequest
    directly, while the Windows service calls Start-EpicVMAgent.
#>

[CmdletBinding()]
param(
    [switch] $NoStart,
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $BindAddress,
    [int] $Port = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$providerPath = Join-Path $PSScriptRoot 'providers/HyperVProvider.ps1'
if (Test-Path -LiteralPath $providerPath) {
    . $providerPath
}
$provisioningPath = Join-Path $PSScriptRoot 'Provisioning.ps1'
if (Test-Path -LiteralPath $provisioningPath) {
    . $provisioningPath
}
foreach ($providerExtension in @('GuestProvider.ps1','TailscaleProvider.ps1')) {
    $extensionPath = Join-Path $PSScriptRoot ('providers/' + $providerExtension)
    if (Test-Path -LiteralPath $extensionPath) { . $extensionPath }
}
$sharedGamesPath = Join-Path $PSScriptRoot 'SharedGames.ps1'
if (Test-Path -LiteralPath $sharedGamesPath) { . $sharedGamesPath }
$hostGamingPath = Join-Path $PSScriptRoot 'HostGaming.ps1'
if (Test-Path -LiteralPath $hostGamingPath) { . $hostGamingPath }

function Get-EpicVMDefaultConfig {
    return [pscustomobject]@{
        BindAddress = '127.0.0.1'
        Port = 8765
        Provider = 'HyperV'
        TokenFile = 'C:\ProgramData\EpicVM\agent\agent.txt'
        ConfigFile = 'C:\ProgramData\EpicVM\agent\config.json'
        VmRoot = 'E:\EpicVM\vms'
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
        OmarchyTimezone = 'America/New_York'
        OmarchyKeyboard = 'us'
        OmarchyPilotValidated = $false
        ProvisioningStatePath = 'E:\EpicVM\provisioning-jobs.json'
        CatalogPath = 'E:\EpicVM\shared-games\catalog.json'
        GamingVMNames = @('testre')
        GamingGpuDeviceIdentity = 'VEN_1002&DEV_73BF'
        GamingGpuPartitionPercent = 50
        GamingDriverStoreRoot = 'C:\Windows\System32\DriverStore\FileRepository'
        GamingDriverSourcePaths = @()
        BootstrapUser = 'EpicVMBootstrap'
        BootstrapCredentialPath = 'C:\ProgramData\EpicVM\agent\bootstrap.dpapi'
        TailscaleOAuthClientId = ''
        TailscaleOAuthSecretPath = 'C:\ProgramData\EpicVM\agent\tailscale-oauth.dpapi'
        TailscaleTailnet = ''
        TailscaleGuestTag = 'tag:epicvm-guest'
        TailscaleExecutable = 'C:\Program Files\Tailscale\tailscale.exe'
        ManagementPort = 5985
        ManagementUseSsl = $false
        RequireManagementTransport = $true
        SunshineServiceName = 'SunshineService'
        SunshineVersion = '2026.516.143833'
        SunshineStatePaths = @(
            'C:\Program Files\Sunshine\config\sunshine_state.json',
            'C:\ProgramData\Sunshine\config\sunshine_state.json'
        )
        EnableGamingProvisioning = $false
        EnableOmarchyProvisioning = $false
    }
}

function Get-EpicVMProperty {
    param(
        [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Object[$key]
            }
        }
        return $Default
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $property.Value
        }
    }
    return $Default
}

function Read-EpicVMConfig {
    param([Parameter(Mandatory)] [string] $Path)
    $defaults = Get-EpicVMDefaultConfig
    if (-not (Test-Path -LiteralPath $Path)) { return $defaults }
    try {
        $loaded = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw 'The EpicVM agent configuration is invalid JSON.'
    }
    foreach ($property in $defaults.PSObject.Properties) {
        $value = Get-EpicVMProperty -Object $loaded -Name $property.Name -Default $property.Value
        $defaults.$($property.Name) = $value
    }
    return $defaults
}

function Get-EpicVMAgentToken {
    param([Parameter(Mandatory)] [object] $Config)
    $token = [string](Get-EpicVMProperty -Object $Config -Name 'Token' -Default '')
    if ($token) { return $token.Trim() }
    $tokenPath = [string](Get-EpicVMProperty -Object $Config -Name 'TokenFile' -Default '')
    if (-not $tokenPath -or -not (Test-Path -LiteralPath $tokenPath)) {
        throw 'The EpicVM agent token file is missing.'
    }
    $token = (Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8).Trim()
    if (-not $token) { throw 'The EpicVM agent token file is empty.' }
    return $token
}

function Test-EpicVMBearerToken {
    param(
        [AllowNull()] [string] $ProvidedToken,
        [AllowNull()] [string] $ExpectedToken
    )
    if ([string]::IsNullOrEmpty($ProvidedToken) -or [string]::IsNullOrEmpty($ExpectedToken)) { return $false }
    $left = [Text.Encoding]::UTF8.GetBytes($ProvidedToken)
    $right = [Text.Encoding]::UTF8.GetBytes($ExpectedToken)
    if ($left.Length -ne $right.Length) { return $false }
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($left, $right)
}

function Test-EpicVMName {
    param([AllowNull()] [string] $Name)
    if ($null -eq $Name) { return $false }
    return [regex]::IsMatch($Name, '\A[a-z0-9][a-z0-9._-]{0,62}\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Test-EpicVMBindAddress {
    param([AllowNull()] [string] $Address)
    if ([string]::IsNullOrWhiteSpace($Address) -or $Address -in @('0.0.0.0', '::', '[::]')) {
        return $false
    }
    try {
        $normalizedAddress = $Address.Trim()
        if ($normalizedAddress.StartsWith('[') -and $normalizedAddress.EndsWith(']')) {
            $normalizedAddress = $normalizedAddress.Substring(1, $normalizedAddress.Length - 2)
        }
        $ip = [System.Net.IPAddress]::Parse($normalizedAddress)
    }
    catch {
        return $false
    }
    if ([System.Net.IPAddress]::IsLoopback($ip)) {
        return $true
    }
    $bytes = $ip.GetAddressBytes()
    return (
        $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
        $bytes.Length -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127
    )
}

function New-EpicVMAgentState {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [object] $Provider
    )
    $agentState = [pscustomobject]@{
        Config = $Config
        Token = $Token
        Provider = $Provider
        StartedAt = [DateTime]::UtcNow
        SyncRoot = [object]::new()
        CompletedOperations = @{}
        DeferProvisioning = $false
    }
    if (Get-Command -Name New-EpicVMProvisioningStore -ErrorAction SilentlyContinue) {
        $agentState | Add-Member -MemberType NoteProperty -Name Provisioning -Value (New-EpicVMProvisioningStore -Config $Config)
        if (Get-Command -Name Invoke-EpicVMProvisioningRecovery -ErrorAction SilentlyContinue) {
            Invoke-EpicVMProvisioningRecovery -State $agentState
        }
    }
    return $agentState
}

function New-EpicVMApiError {
    param([Parameter(Mandatory)] [string] $Code, [Parameter(Mandatory)] [string] $Message)
    return [ordered]@{ ok = $false; error = [ordered]@{ code = $Code; message = $Message } }
}

function ConvertTo-EpicVMJsonResponse {
    param(
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [object] $Body
    )
    return [pscustomobject]@{
        StatusCode = $StatusCode
        Body = $Body
        Json = ($Body | ConvertTo-Json -Depth 16 -Compress)
        Headers = @{ 'Cache-Control' = 'no-store'; 'Pragma' = 'no-cache' }
    }
}

function Write-EpicVMSafeHttpResponse {
    <#
    The browser/dashboard may disconnect while a request is being handled.
    HttpListener then rejects response property writes (including
    ContentLength64).  A transport failure must not escape the per-request
    boundary and terminate the long-lived agent worker.
    #>
    param(
        [Parameter(Mandatory)] [object] $Response,
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [string] $Json,
        [AllowNull()] [object] $Headers = @{},
        [AllowNull()] [string] $RequestId = ''
    )
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $Response.StatusCode = $StatusCode
        if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
            $Response.Headers['X-Request-Id'] = $RequestId
        }
        $Response.ContentType = 'application/json; charset=utf-8'
        if ($null -ne $Headers) {
            foreach ($headerName in $Headers.Keys) {
                $Response.Headers[$headerName] = [string]$Headers[$headerName]
            }
        }
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        return $true
    }
    catch {
        # The client may already have closed/submitted the response.  Never
        # rethrow a transport-only failure from this response boundary.
        return $false
    }
}

function Get-EpicVMHeader {
    param([AllowNull()] [object] $Headers, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Headers) { return '' }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$Headers[$key] }
        }
    }
    return [string](Get-EpicVMProperty -Object $Headers -Name $Name -Default '')
}

function Get-EpicVMRequestBody {
    param([AllowNull()] [object] $Body)
    if ($null -eq $Body -or $Body -eq '') { return @{} }
    if ($Body -is [string]) {
        try { return ($Body | ConvertFrom-Json -AsHashtable) } catch { throw 'Request body is not valid JSON.' }
    }
    if ($Body -is [System.Collections.IDictionary]) { return $Body }
    return $Body
}

function New-EpicVMProvider {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [AllowNull()] [scriptblock] $CommandInvoker = $null
    )
    switch ([string](Get-EpicVMProperty -Object $Config -Name 'Provider' -Default 'HyperV')) {
        'HyperV' {
            return New-EpicVMHyperVProvider -Config $Config -CommandInvoker $CommandInvoker
        }
        default {
            throw ("Unsupported provider: {0}" -f (Get-EpicVMProperty -Object $Config -Name 'Provider' -Default ''))
        }
    }
}

function Get-EpicVMProviderCapabilities {
    param([Parameter(Mandatory)] [object] $Provider)
    try {
        $capabilities = & $Provider.GetCapabilities
        if ($capabilities -is [System.Collections.IDictionary]) { return $capabilities }
        return [ordered]@{ provider = [string]$Provider.Name; available = $false; features = @() }
    }
    catch {
        return [ordered]@{ provider = [string]$Provider.Name; available = $false; features = @(); error = 'provider_unavailable' }
    }
}

function Add-EpicVMProvisioningInventoryState {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object[]] $Vms)
    foreach ($vm in $Vms) {
        $name = [string](Get-EpicVMProperty -Object $vm -Name 'name' -Default '')
        $vmId = [string](Get-EpicVMProperty -Object $vm -Name 'id' -Default '')
        $job = @($State.Provisioning.Jobs.Values | Where-Object {
            [string]$_.name -ceq $name -and
            (-not $vmId -or [string](Get-EpicVMProperty -Object $_ -Name 'vmId' -Default '') -ieq $vmId)
        } | Sort-Object updatedAt -Descending | Select-Object -First 1)
        if ($job.Count -eq 0) { continue }
        if ($vm -is [System.Collections.IDictionary]) {
            $vm['provisioningState'] = [string]$job[0].state
            $vm['consoleReady'] = ([string]$job[0].state -ceq 'ready')
            if ([string]$job[0].state -ceq 'ready' -and [string]$job[0].consoleRoutePrefix -match '^/vm/[a-z0-9][a-z0-9._-]{0,62}/$') {
                $vm['consoleRoutePrefix'] = [string]$job[0].consoleRoutePrefix
            }
        }
        else {
            $vm | Add-Member -MemberType NoteProperty -Name provisioningState -Value ([string]$job[0].state) -Force
            $vm | Add-Member -MemberType NoteProperty -Name consoleReady -Value ([string]$job[0].state -ceq 'ready') -Force
            if ([string]$job[0].state -ceq 'ready' -and [string]$job[0].consoleRoutePrefix -match '^/vm/[a-z0-9][a-z0-9._-]{0,62}/$') {
                $vm | Add-Member -MemberType NoteProperty -Name consoleRoutePrefix -Value ([string]$job[0].consoleRoutePrefix) -Force
            }
        }
    }
    return $Vms
}

function Invalidate-EpicVMGamingConsoleEvidence {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Action
    )
    if ($null -eq $State.Provisioning) { return $false }
    $job = @($State.Provisioning.Jobs.Values | Where-Object {
        [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $Name
    } | Sort-Object updatedAt -Descending | Select-Object -First 1)
    if ($job.Count -ne 1 -or [string](Get-EpicVMProperty -Object $job[0] -Name 'profile' -Default 'standard') -ine 'gaming') {
        return $false
    }
    if ([string](Get-EpicVMProperty -Object $job[0] -Name 'state' -Default '') -cne 'ready') {
        return $false
    }

    # A VM lifecycle transition invalidates browser evidence from the prior
    # guest session. Keep the retained VM and its capture configuration, but
    # require the authenticated browser to prove fresh pixels and input again.
    $job[0].state = 'streaming_setup'
    $job[0].streamValidationVerified = $false
    $job[0].consoleFrameVerified = $false
    $job[0].keyboardInputVerified = $false
    $job[0].mouseInputVerified = $false
    $job[0].consoleVerifiedAt = $null
    $job[0].consoleFrameVerifiedAt = $null
    $job[0].keyboardInputVerifiedAt = $null
    $job[0].mouseInputVerifiedAt = $null
    $job[0].failureStage = $null
    $job[0].failureDetailCode = $null
    $job[0].errorCode = $null
    $job[0].errorMessage = $null
    $job[0].lastAttemptCode = "vm_${Action}_requires_reverification"
    $job[0].updatedAt = [DateTime]::UtcNow.ToString('o')
    $stages = @(Get-EpicVMProvisioningCompletedStages -Value (Get-EpicVMProperty -Object $job[0] -Name 'completedStages' -Default @()))
    $job[0].completedStages = @($stages | Where-Object { $_ -ne 'stream_validation' })
    Save-EpicVMProvisioningStore -Store $State.Provisioning
    return $true
}

function Invoke-EpicVMProviderAction {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Request = @{}
    )
    $result = $null
    switch ($Action.ToLowerInvariant()) {
        'start' { $result = & $Provider.StartVM $Name }
        'stop' { $result = & $Provider.StopVM $Name }
        'restart' { $result = & $Provider.RestartVM $Name }
        'delete' { $result = & $Provider.DeleteVM $Name }
        default { throw "Unsupported VM action: $Action" }
    }
    if ($Action.ToLowerInvariant() -in @('start', 'stop', 'restart')) {
        [void](Invalidate-EpicVMGamingConsoleEvidence -State $State -Name $Name -Action $Action.ToLowerInvariant())
    }
    return $result
}

function Invoke-EpicVMApiRequest {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] [object] $Headers = @{},
        [AllowNull()] [object] $Body = $null
    )
    $authorization = Get-EpicVMHeader -Headers $Headers -Name 'Authorization'
    $provided = ''
    if ($authorization -match '^Bearer\s+(.+)$') { $provided = $Matches[1].Trim() }
    if (-not (Test-EpicVMBearerToken -ProvidedToken $provided -ExpectedToken ([string]$State.Token))) {
        return ConvertTo-EpicVMJsonResponse -StatusCode 401 -Body (New-EpicVMApiError -Code 'unauthorized' -Message 'Authentication required.')
    }

    $normalizedPath = '/' + $Path.Trim('/')
    $segments = @($normalizedPath.Trim('/').Split('/') | Where-Object { $_ -ne '' } | ForEach-Object { [Uri]::UnescapeDataString($_) })
    try {
        if ($Method -eq 'GET' -and $normalizedPath -eq '/v1/health') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; status = 'ok'; agent = 'EpicVM'; provider = [string]$State.Provider.Name })
        }
        if ($normalizedPath -eq '/v1/host-gaming' -and $Method -eq 'GET') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Get-EpicVMHostGamingView)
        }
        if ($normalizedPath -eq '/v1/host-gaming/launch' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Start-EpicVMHostGame (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/host-gaming/desktop' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Start-EpicVMHostDesktop (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/host-gaming/account-credential/reveal' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Reveal-EpicVMHostAccountCredential (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/host-gaming/stop' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Stop-EpicVMHostGame (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/host-gaming/pair' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Pair-EpicVMHostGaming (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/host-gaming/recover' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Recover-EpicVMHostGaming (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/host-gaming/games' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Register-EpicVMHostGame (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/host-gaming/games/remove' -and $Method -eq 'POST') {
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (Unregister-EpicVMHostGame (Get-EpicVMRequestBody -Body $Body))
        }
        if ($normalizedPath -eq '/v1/game-library' -and $Method -eq 'GET') {
            $library = Get-EpicVMGameLibraryView
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (@{ok=$true} + $library)
        }
        if ($segments.Count -ge 2 -and $segments[0] -eq 'v1' -and $segments[1] -eq 'game-library') {
            try {
                if ($Method -eq 'POST' -and $segments.Count -eq 3 -and $segments[2] -eq 'upload') {
                    return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body (@{ok=$true} + (Receive-EpicVMGameUpload (Get-EpicVMRequestBody -Body $Body)))
                }
                if ($Method -eq 'POST' -and $segments.Count -eq 3 -and $segments[2] -eq 'jobs') {
                    $request = Get-EpicVMRequestBody -Body $Body
                    $job = Start-EpicVMGameJob $request
                    return ConvertTo-EpicVMJsonResponse -StatusCode 202 -Body @{ok=$true;job=$job}
                }
                if ($Method -eq 'GET' -and $segments.Count -eq 4 -and $segments[2] -eq 'jobs' -and $segments[3] -match '^[a-f0-9]{32}$') {
                    $path = Join-Path $script:GameLibraryRoot ('jobs\' + $segments[3] + '.json')
                    if (-not (Test-Path -LiteralPath $path)) { throw 'Game setup job was not found.' }
                    $job = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                    $job.Remove('request')
                    return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body @{ok=$true;job=$job}
                }
            } catch { return ConvertTo-EpicVMJsonResponse -StatusCode 400 -Body (New-EpicVMApiError -Code 'game_setup_failed' -Message $_.Exception.Message) }
        }
        if ($Method -eq 'GET' -and $normalizedPath -eq '/v1/capabilities') {
            $caps = Get-EpicVMProviderCapabilities -Provider $State.Provider
            $caps.ok = $true
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body $caps
        }
        if ($Method -eq 'GET' -and $segments.Count -eq 2 -and $segments[0] -eq 'v1' -and $segments[1] -eq 'vms') {
            $vms = @(& $State.Provider.GetVMs)
            if ($null -ne $State.Provisioning) { $vms = @(Add-EpicVMProvisioningInventoryState -State $State -Vms $vms) }
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; vms = $vms })
        }
        if ($Method -eq 'GET' -and $segments.Count -eq 2 -and $segments[0] -eq 'v1' -and $segments[1] -eq 'games') {
            $catalogPath = [string](Get-EpicVMProperty -Object $State.Config -Name 'CatalogPath' -Default 'E:\EpicVM\shared-games\catalog.json')
            if (-not (Test-Path -LiteralPath $catalogPath)) {
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; games = @() })
            }
            try {
                $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $games = @($catalog.games | ForEach-Object {
                    # Catalog entries are external data and may omit optional
                    # fields entirely; under StrictMode a bare $_.sizeBytes would
                    # throw PropertyNotFoundException and silently empty the list.
                    # Use Get-EpicVMProperty everywhere so a single malformed entry
                    # can only degrade its own row.
                    $exePath = [string](Get-EpicVMProperty -Object $_ -Name 'exe' -Default '')
                    $available = $false
                    if ($null -ne $exePath -and $exePath -ne '') {
                        try {
                            # The catalog stores exe as a UNC (\\host\EpicVMGames$\...). Under
                            # LocalSystem the agent cannot authenticate to the SMB share, so a
                            # direct Test-Path throws and would otherwise empty the whole list.
                            # Resolve the share to its local root when it points at
                            # this host. The share group must swallow the trailing '$'
                            # of hidden shares (EpicVMGames$) wholesale; splitting it
                            # out makes Get-SmbShare look up the wrong name.
                            $localExePath = $exePath
                            if ($exePath -match '^\\\\(?<host>[^\\]+)\\(?<share>[^\\$]+)\$\\(?<rest>.*)$') {
                                $shareRoot = $null
                                try { $shareRoot = (Get-SmbShare -Name $Matches['share'] -ErrorAction Stop).Path } catch { }
                                if ($null -ne $shareRoot) { $localExePath = Join-Path $shareRoot $Matches['rest'] }
                            }
                            if (Test-Path -LiteralPath $localExePath -ErrorAction SilentlyContinue) { $available = $true }
                            # Deliberately NO fallback Test-Path against the raw UNC:
                            # under a freshly started LocalSystem process the SMB
                            # self-session may not be established yet and the probe
                            # can block far longer than this route's timeout, making
                            # the whole endpoint appear dead. If the share root could
                            # not be resolved locally, report unavailable instead.
                        } catch { $available = $false }
                    }
                    $rawSize = Get-EpicVMProperty -Object $_ -Name 'sizeBytes' -Default 0
                    if ($null -eq $rawSize -or ([string]$rawSize) -eq '') { $rawSize = 0 }
                    $version = [string](Get-EpicVMProperty -Object $_ -Name 'version' -Default '')
                    $directLaunch = [bool](Get-EpicVMProperty -Object $_ -Name 'directLaunch' -Default $false)
                    [ordered]@{
                        id = [string](Get-EpicVMProperty -Object $_ -Name 'id' -Default '')
                        title = [string](Get-EpicVMProperty -Object $_ -Name 'title' -Default '')
                        platform = [string](Get-EpicVMProperty -Object $_ -Name 'platform' -Default '')
                        version = $version
                        exe = $exePath
                        sizeBytes = [long]$rawSize
                        available = $available
                        directLaunch = $directLaunch
                    }
                })
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; games = $games })
            } catch {
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; games = @() })
            }
        }
        if ($null -ne $State.Provisioning -and $Method -eq 'POST' -and $normalizedPath -eq '/v1/provisioning-jobs') {
            $request = Get-EpicVMRequestBody -Body $Body
            try { $job = New-EpicVMProvisioningJob -State $State -Request $request }
            catch {
                $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'invalid_request')
                $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422)
                return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body (New-EpicVMApiError -Code $code -Message ([string]$_.Exception.Message))
            }
            if ([bool](Get-EpicVMProperty -Object $State -Name 'DeferProvisioning' -Default $false)) {
                return ConvertTo-EpicVMJsonResponse -StatusCode 202 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
            }
            try { $claim = Start-EpicVMProvisioningJob -State $State -Job $job }
            catch {
                $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'provisioning_failed')
                $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422)
                return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body ([ordered]@{ ok=$false; error=[ordered]@{code=$code;message='Provisioning failed.'}; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
            }
            return ConvertTo-EpicVMJsonResponse -StatusCode 202 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job); claimToken=$claim })
        }
        if ($null -ne $State.Provisioning -and $Method -eq 'GET' -and $normalizedPath -eq '/v1/provisioning-jobs') {
            $jobs = @($State.Provisioning.Jobs.Values | ForEach-Object { ConvertTo-EpicVMRedactedJob -Job $_ })
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; jobs=$jobs })
        }
        if ($null -ne $State.Provisioning -and $segments.Count -ge 3 -and $segments[0] -eq 'v1' -and $segments[1] -eq 'provisioning-jobs') {
            $job = $State.Provisioning.Jobs[$segments[2]]
            if ($null -eq $job) { return ConvertTo-EpicVMJsonResponse -StatusCode 404 -Body (New-EpicVMApiError -Code 'not_found' -Message 'The provisioning job was not found.') }
            if ($Method -eq 'GET') { return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) }) }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'claim-reissue') {
                try { $claim = Invoke-EpicVMProvisioningClaimReissue -State $State -Job $job }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'claim_reissue_failed')
                    $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 409)
                    return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body ([ordered]@{ ok=$false; error=[ordered]@{code=$code;message=[string]$_.Exception.Message}; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
                }
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job); claimToken=$claim })
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'guest-recovery') {
                try {
                    $recovered = Invoke-EpicVMProvisioningGuestRecovery -State $State -Job $job -Request (Get-EpicVMRequestBody -Body $Body)
                    return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
                }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'guest_recovery_failed')
                    $allowed = @('invalid_credential_input','guest_recovery_not_allowed','guest_recovery_vm_missing','guest_account_failed',
                        'tailscale_unavailable','tailscale_verification_failed','tailscale_enrollment_failed',
                        'management_handoff_failed','management_transport_failed','management_transport_unavailable',
                        'management_trusted_hosts_broad','guest_recovery_failed')
                    if ($allowed -notcontains $code) { $code = 'guest_recovery_failed' }
                    $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422)
                    return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body ([ordered]@{
                        ok=$false
                        error=[ordered]@{code=$code;message='Guest recovery failed at a safe, identified stage.'}
                        job=(ConvertTo-EpicVMRedactedJob -Job $job)
                    })
                }
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'network-recovery') {
                try {
                    $recovered = Invoke-EpicVMProvisioningNetworkRecovery -State $State -Job $job -Request (Get-EpicVMRequestBody -Body $Body)
                    return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
                }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'network_recovery_failed')
                    $allowed = @('invalid_credential_input','network_recovery_not_allowed','network_recovery_vm_missing',
                        'tailscale_verification_failed','tailscale_enrollment_failed','tailscale_state_not_persisted',
                        'tailscale_auth_input_failed','tailscale_guest_command_failed','tailscale_system_task_timeout',
                        'tailscale_system_task_failed','tailscale_unattended_failed','tailscale_restart_failed',
                        'network_recovery_failed','management_handoff_failed')
                    if ($allowed -notcontains $code) { $code = 'network_recovery_failed' }
                    $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422)
                    return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body ([ordered]@{
                        ok=$false
                        error=[ordered]@{code=$code;message='Network recovery failed at a safe, identified stage.'}
                        job=(ConvertTo-EpicVMRedactedJob -Job $job)
                    })
                }
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'claim') {
                try { Invoke-EpicVMProvisioningClaim -State $State -Job $job -Request (Get-EpicVMRequestBody -Body $Body) | Out-Null }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'claim_failed')
                    $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422)
                    $safeMessage = switch ($code) {
                        'invalid_credential_input' { 'The credential input is empty or does not meet the request policy.'; break }
                        'invalid_claim' { 'The claim is invalid or expired.'; break }
                        'claim_expired' { 'The claim has expired.'; break }
                        'claim_not_allowed' { 'The VM is not awaiting a claim.'; break }
                        'claim_in_progress' { 'Another request already owns this claim.'; break }
                        default { 'Guest setup failed at a safe, identified stage.' }
                    }
                    if ($job.state -notmatch '^setup_failed:' -and $code -notin @('invalid_credential_input','invalid_claim','claim_expired','claim_not_allowed','claim_in_progress','claim_atomic_commit_failed','guest_configuration_unavailable')) {
                        $job.state = Get-EpicVMProvisioningFailureState -Code $code
                        $job.errorCode = $code
                        $job.errorMessage = 'Guest setup stopped safely; the owned VM was retained for diagnosis.'
                        Save-EpicVMProvisioningStore -Store $State.Provisioning
                    }
                    return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body ([ordered]@{ ok=$false; error=[ordered]@{code=$code;message=$safeMessage}; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
                }
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'direct-diagnostic') {
                # Read-only, stage-scoped proof of the LocalSystem PowerShell
                # Direct channel.  This endpoint never mutates the VM, job,
                # claim, or guest and returns only the diagnostic allowlist.
                if ([string]$job.state -ne 'setup_failed:streaming' -or -not [bool](Get-EpicVMProperty -Object $job -Name 'claimConsumed' -Default $false)) {
                    return ConvertTo-EpicVMJsonResponse -StatusCode 409 -Body (New-EpicVMApiError -Code 'direct_diagnostic_not_allowed' -Message 'The retained streaming diagnostic is not available for this job.')
                }
                $request = Get-EpicVMRequestBody -Body $Body
                $username = [string](Get-EpicVMProperty -Object $request -Name 'username' -Default '')
                $password = [string](Get-EpicVMProperty -Object $request -Name 'password' -Default '')
                if (-not (Test-EpicVMProvisioningCredentialInput -Username $username -Password $password)) {
                    return ConvertTo-EpicVMJsonResponse -StatusCode 400 -Body (New-EpicVMApiError -Code 'invalid_credential_input' -Message 'The credential input is empty or does not meet the request policy.')
                }
                $credential = $null
                try {
                    $credential = [PSCredential]::new($username, (ConvertTo-SecureString $password -AsPlainText -Force))
                    $vmId = Get-EpicVMJobImmutableVmId -State $State -Job $job
                    $diagnostic = Invoke-EpicVMPowerShellDirectDiagnostic -Provider $State.Provider -VmName ([string]$job.name) -VmId $vmId -Credential $credential
                    return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{
                        ok = $true
                        jobId = [string]$job.id
                        diagnostic = [ordered]@{
                            correlationId = [string](Get-EpicVMProperty -Object $diagnostic -Name 'correlationId' -Default '')
                            sessionCreated = [bool](Get-EpicVMProperty -Object $diagnostic -Name 'sessionCreated' -Default $false)
                            code = [string](Get-EpicVMProperty -Object $diagnostic -Name 'code' -Default 'direct_runtime_failure')
                            durationBucket = [string](Get-EpicVMProperty -Object $diagnostic -Name 'durationBucket' -Default '')
                        }
                    })
                }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'direct_runtime_failure')
                    $allowed = @('hyperv_vm_not_found','hyperv_access_denied','hyperv_vm_not_running','guest_heartbeat_unhealthy',
                        'direct_service_disabled','direct_service_not_ready','direct_not_supported','direct_open_timeout',
                        'direct_transport_error','guest_credentials_rejected','guest_operation_failed','direct_parameter_failure',
                        'direct_module_failure','direct_runtime_failure')
                    if ($allowed -notcontains $code) { $code = 'direct_runtime_failure' }
                    return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{
                        ok = $true
                        jobId = [string]$job.id
                        diagnostic = [ordered]@{ correlationId = ''; sessionCreated = $false; code = $code; durationBucket = '' }
                    })
                }
                finally {
                    $username = $password = $null
                    $credential = $null
                }
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'console-credentials') {
                try { Set-EpicVMProvisioningConsoleCredentials -State $State -Job $job -Request (Get-EpicVMRequestBody -Body $Body) }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'console_credentials_failed')
                    $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422)
                    return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body ([ordered]@{ ok=$false; error=[ordered]@{code=$code;message=[string]$_.Exception.Message}; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
                }
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'console-complete') {
                try { Complete-EpicVMProvisioningConsole -State $State -Job $job -Request (Get-EpicVMRequestBody -Body $Body) }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'console_verification_failed')
                    $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422)
                    return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body ([ordered]@{ ok=$false; error=[ordered]@{code=$code;message=[string]$_.Exception.Message}; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
                }
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'console-failed') {
                try { Set-EpicVMProvisioningConsoleFailed -State $State -Job $job -Request (Get-EpicVMRequestBody -Body $Body) }
                catch {
                    $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'console_failure_not_allowed')
                    $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 409)
                    return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body (New-EpicVMApiError -Code $code -Message ([string]$_.Exception.Message))
                }
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
            }
        }
        if ($null -ne $State.Provisioning -and $Method -eq 'POST' -and $normalizedPath -eq '/v1/deprovisioning-jobs') {
            try { $job=New-EpicVMDeprovisioningJob -State $State -Request (Get-EpicVMRequestBody -Body $Body) }
            catch { $code=[string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'teardown_rejected');$status=[int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default 422);return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body (New-EpicVMApiError -Code $code -Message ([string]$_.Exception.Message)) }
            return ConvertTo-EpicVMJsonResponse -StatusCode 202 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
        }
        if ($null -ne $State.Provisioning -and $segments.Count -eq 3 -and $segments[0] -eq 'v1' -and $segments[1] -eq 'deprovisioning-jobs' -and $Method -eq 'GET') {
            $job=$State.Provisioning.Deprovisioning[$segments[2]]
            if ($null -eq $job) { return ConvertTo-EpicVMJsonResponse -StatusCode 404 -Body (New-EpicVMApiError -Code 'not_found' -Message 'The deprovisioning job was not found.') }
            return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok=$true; job=(ConvertTo-EpicVMRedactedJob -Job $job) })
        }
        if ($Method -eq 'POST' -and $segments.Count -eq 2 -and $segments[0] -eq 'v1' -and $segments[1] -eq 'vms') {
            $request = Get-EpicVMRequestBody -Body $Body
            $name = [string](Get-EpicVMProperty -Object $request -Name 'name' -Default (Get-EpicVMProperty -Object $request -Name 'Name' -Default ''))
            if (-not (Test-EpicVMName -Name $name)) {
                return ConvertTo-EpicVMJsonResponse -StatusCode 400 -Body (New-EpicVMApiError -Code 'invalid_name' -Message 'The VM name is invalid.')
            }
            $vm = & $State.Provider.CreateVM $request
            return ConvertTo-EpicVMJsonResponse -StatusCode 201 -Body ([ordered]@{ ok = $true; vm = $vm })
        }
        if ($segments.Count -ge 3 -and $segments[0] -eq 'v1' -and $segments[1] -eq 'vms') {
            $name = $segments[2]
            if (-not (Test-EpicVMName -Name $name)) {
                return ConvertTo-EpicVMJsonResponse -StatusCode 400 -Body (New-EpicVMApiError -Code 'invalid_name' -Message 'The VM name is invalid.')
            }
            if ($Method -eq 'GET' -and $segments.Count -eq 3) {
                $vms = @(& $State.Provider.GetVMs)
                $vm = @($vms | Where-Object { [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -eq $name }) | Select-Object -First 1
                if ($null -eq $vm) { return ConvertTo-EpicVMJsonResponse -StatusCode 404 -Body (New-EpicVMApiError -Code 'not_found' -Message 'The requested VM was not found.') }
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; vm = $vm })
            }
            if ($Method -eq 'GET' -and $segments.Count -eq 4 -and $segments[3] -eq 'logs') {
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; logs = ''; supported = $false })
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -in @('start', 'stop', 'restart')) {
                $result = Invoke-EpicVMProviderAction -State $State -Provider $State.Provider -Action $segments[3] -Name $name
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; vm = $result })
            }
            if ($Method -eq 'POST' -and $segments.Count -eq 4 -and $segments[3] -eq 'gpu-partition') {
                $request = Get-EpicVMRequestBody -Body $Body
                $rawPercent = Get-EpicVMProperty -Object $request -Name 'percent' -Default $null
                if ($null -eq $rawPercent) {
                    return ConvertTo-EpicVMJsonResponse -StatusCode 400 -Body (New-EpicVMApiError -Code 'invalid_input' -Message 'The GPU-P partition percentage is required.')
                }
                try { $percent = [int][System.Convert]::ToInt32($rawPercent) }
                catch {
                    return ConvertTo-EpicVMJsonResponse -StatusCode 400 -Body (New-EpicVMApiError -Code 'invalid_input' -Message 'The GPU-P partition percentage must be an integer between 1 and 100.')
                }
                if ($percent -lt 1 -or $percent -gt 100) {
                    return ConvertTo-EpicVMJsonResponse -StatusCode 400 -Body (New-EpicVMApiError -Code 'invalid_input' -Message 'The GPU-P partition percentage must be between 1 and 100.')
                }
                $setter = Get-EpicVMProperty -Object $State.Provider -Name 'SetGamingGpuPercent' -Default $null
                if ($null -eq $setter) {
                    return ConvertTo-EpicVMJsonResponse -StatusCode 409 -Body (New-EpicVMApiError -Code 'gpu_partition_unavailable' -Message 'GPU-P controls are unavailable for this provider.')
                }
                $result = & $setter $name $percent
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; vm = $result })
            }
            # Keep the first draft's action route as a compatibility alias for
            # already-installed clients; new clients use the documented REST
            # lifecycle paths above and DELETE /v1/vms/{name}.
            if ($Method -eq 'POST' -and $segments.Count -eq 5 -and $segments[3] -eq 'actions') {
                $result = Invoke-EpicVMProviderAction -State $State -Provider $State.Provider -Action $segments[4] -Name $name
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; vm = $result })
            }
            if ($Method -eq 'DELETE' -and $segments.Count -eq 3) {
                $tailnetDeviceId = ''
                try {
                    $vmRecord = @(& $State.Provider.GetVMs | Where-Object {
                        [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $name
                    }) | Select-Object -First 1
                    if ($null -ne $vmRecord) { $tailnetDeviceId = [string](Get-EpicVMProperty -Object $vmRecord -Name 'tailnetDeviceId' -Default '') }
                } catch { }
                $result = Invoke-EpicVMProviderAction -State $State -Provider $State.Provider -Action 'delete' -Name $name
                # Best-effort tailnet cleanup: revoke the recorded device and
                # sweep any stale sibling records left by re-enrollments.
                try {
                    if ($tailnetDeviceId) {
                        $revokeFn = Get-EpicVMProperty -Object $State.Provider -Name 'RevokeTailscale' -Default $null
                        if ($null -ne $revokeFn) { & $revokeFn $tailnetDeviceId | Out-Null }
                    }
                    $pruneFn = Get-EpicVMProperty -Object $State.Provider -Name 'ClearTailscaleStaleDevices' -Default $null
                    if ($null -ne $pruneFn) { & $pruneFn $name $tailnetDeviceId | Out-Null }
                } catch { }
                return ConvertTo-EpicVMJsonResponse -StatusCode 200 -Body ([ordered]@{ ok = $true; vm = $result })
            }
        }
        return ConvertTo-EpicVMJsonResponse -StatusCode 404 -Body (New-EpicVMApiError -Code 'not_found' -Message 'Route not found.')
    }
    catch {
        $errorCode = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'provider_error')
        $message = [string]$_.Exception.Message
        if ($message -match 'token|authorization|secret|password') { $message = 'The provider request failed.' }
        $status = [int](Get-EpicVMProperty -Object $_.Exception -Name 'HttpStatus' -Default (if ($errorCode -eq 'NotFound') { 404 } elseif ($errorCode -eq 'InvalidInput') { 400 } elseif ($errorCode -eq 'Conflict') { 409 } elseif ($errorCode -eq 'UnmanagedVM') { 403 } else { 502 }))
        return ConvertTo-EpicVMJsonResponse -StatusCode $status -Body (New-EpicVMApiError -Code $errorCode.ToLowerInvariant() -Message $message)
    }
}

function Test-EpicVMMutationRequest {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path
    )
    if ($Method -eq 'DELETE' -and $Path -match '^/v1/vms/[^/]+$') { return $true }
    if ($Method -eq 'POST' -and $Path -match '^/v1/host-gaming/(launch|desktop|stop|pair|recover|games|games/remove)$') { return $true }
    if ($Method -eq 'POST' -and ($Path -eq '/v1/provisioning-jobs' -or $Path -eq '/v1/deprovisioning-jobs' -or $Path -match '^/v1/provisioning-jobs/[^/]+/(claim|claim-reissue|guest-recovery|network-recovery|direct-diagnostic|console-credentials|console-complete|console-failed)$')) { return $true }
    if ($Method -eq 'POST' -and ($Path -eq '/v1/vms' -or $Path -match '^/v1/vms/[^/]+/(start|stop|restart|gpu-partition)$' -or $Path -match '^/v1/vms/[^/]+/actions/(start|stop|restart|delete)$')) { return $true }
    return $false
}

function Read-EpicVMBoundedBody {
    param(
        [Parameter(Mandatory)] [System.IO.Stream] $Stream,
        [int] $MaxBytes = 1048576
    )
    $buffer = [byte[]]::new(8192)
    $memory = [System.IO.MemoryStream]::new()
    try {
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt $MaxBytes) {
                return [pscustomobject]@{ TooLarge = $true; Body = $null }
            }
            $memory.Write($buffer, 0, $read)
        }
        return [pscustomobject]@{
            TooLarge = $false
            Body = [Text.Encoding]::UTF8.GetString($memory.ToArray())
        }
    }
    finally {
        $memory.Dispose()
    }
}

function Start-EpicVMAgent {
    param(
        [Parameter(Mandatory)] [object] $State,
        [string] $Bind = '127.0.0.1',
        [int] $ListenPort = 8765
    )
    $listener = [Net.HttpListener]::new()
    if ([string]::IsNullOrWhiteSpace($Bind) -or $Bind -in @('0.0.0.0', '::', '[::]')) {
        throw 'BindAddress must be a specific Tailscale or loopback address; wildcard binding is refused.'
    }
    if (-not (Test-EpicVMBindAddress -Address $Bind)) {
        throw 'BindAddress must be a Tailscale 100.64.0.0/10 address or loopback.'
    }
    $prefixAddress = [string]$Bind
    if ($prefixAddress.Contains(':') -and -not $prefixAddress.StartsWith('[')) {
        $prefixAddress = "[$prefixAddress]"
    }
    $listener.Prefixes.Add("http://$prefixAddress`:$ListenPort/")
    try { $listener.Start() } catch { throw 'Unable to start the EpicVM agent listener. Run the installer as an administrator.' }
    Write-Verbose ("EpicVM remote agent listening on {0}:{1}" -f $Bind, $ListenPort)
    . (Join-Path $PSScriptRoot 'AgentTransport.ps1')
    try { Invoke-EpicVMAgentListener -State $State -Listener $listener -AgentPath (Join-Path $PSScriptRoot 'EpicVM.Agent.ps1') }
    finally { $listener.Stop(); $listener.Close() }
}

if (-not $NoStart) {
    $config = Read-EpicVMConfig -Path $ConfigPath
    if ($BindAddress) { $config.BindAddress = $BindAddress }
    if ($Port -gt 0) { $config.Port = $Port }
    $token = Get-EpicVMAgentToken -Config $config
    $providerConfig = @{}
    foreach ($property in $config.PSObject.Properties) { $providerConfig[$property.Name] = $property.Value }
    switch ([string]$config.Provider) {
        'HyperV' { $provider = New-EpicVMHyperVProvider -Config $providerConfig }
        default { throw ("Unsupported provider: {0}" -f $config.Provider) }
    }
    $state = New-EpicVMAgentState -Config $config -Token $token -Provider $provider
    Start-EpicVMAgent -State $state -Bind ([string]$config.BindAddress) -ListenPort ([int]$config.Port)
}
