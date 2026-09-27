# Requires -Version 7.0
<#
    Dependency-free Hyper-V adapter for the EpicVM remote agent.

    The adapter deliberately keeps all Hyper-V command calls behind
    Invoke-EpicVMHyperVCmdlet.  The optional CommandInvoker argument is used by
    the Pester suite and by integrators that provide a controlled command
    boundary; production uses the native Hyper-V cmdlets.
#>

Set-StrictMode -Version Latest

$guestProviderPath = Join-Path $PSScriptRoot 'GuestProvider.ps1'
if (Test-Path -LiteralPath $guestProviderPath) { . $guestProviderPath }
$tailscaleProviderPath = Join-Path $PSScriptRoot 'TailscaleProvider.ps1'
if (Test-Path -LiteralPath $tailscaleProviderPath) { . $tailscaleProviderPath }
$gamingGpuProviderPath = Join-Path $PSScriptRoot 'GamingGpuPProvider.ps1'
if (Test-Path -LiteralPath $gamingGpuProviderPath) { . $gamingGpuProviderPath }
$omarchyProviderPath = Join-Path $PSScriptRoot 'OmarchyProvider.ps1'
if (Test-Path -LiteralPath $omarchyProviderPath) { . $omarchyProviderPath }

$script:EpicVMHyperVOwnershipMarker = 'EpicVM-Managed: true'

function Get-EpicVMHyperVValue {
    param(
        [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

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

function New-EpicVMHyperVError {
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Message,
        [AllowNull()] [string] $DetailCode = $null
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $Code -Force
    $allowedDetails = @(
        'account_create_failed', 'account_update_failed',
        'account_password_policy_failed', 'admin_membership_failed',
        'account_verification_failed',
        'SUNSHINE_MANAGEMENT_READINESS', 'SUNSHINE_CONFIG_WRITE',
        'SUNSHINE_STATUS_VERIFY', 'SUNSHINE_INPUT_VALIDATION',
        'SUNSHINE_SERVICE_DISCOVERY', 'SUNSHINE_SERVICE_CIM_QUERY',
        'SUNSHINE_EXECUTABLE_RESOLVE', 'SUNSHINE_VERSION_VERIFY',
        'SUNSHINE_STATE_PATH',
        'SUNSHINE_STATE_WRITE', 'SUNSHINE_STATE_ACL',
        'SUNSHINE_FIREWALL_CONFIG', 'SUNSHINE_SERVICE_RESTART',
        'SUNSHINE_LISTENER_VERIFY', 'CAPTURE_INPUT_VALIDATION',
        'CAPTURE_STAGING', 'CAPTURE_VDD_INSTALL', 'CAPTURE_SUNSHINE_CONF',
        'CAPTURE_CREDENTIALS_AND_LOGON', 'CAPTURE_FIREWALL_CONFIG',
        'CAPTURE_SERVICE_RESTART',
        'GAMING_GPU_DEVICE_MISSING', 'GAMING_GPU_DEVICE_ERROR',
        'GAMING_GPU_DRIVER_INJECTION', 'GAMING_GPU_DXDIAG',
        'GAMING_GPU_WEBGL', 'GAMING_GPU_FRAME', 'GAMING_GPU_ENCODER'
    )
    if ($DetailCode -and $allowedDetails -contains $DetailCode) {
        $exception | Add-Member -MemberType NoteProperty -Name FailureDetailCode -Value $DetailCode -Force
    }
    return $exception
}

function Test-EpicVMHyperVName {
    param([AllowNull()] [string] $Name)

    if ($null -eq $Name) {
        return $false
    }

    return [regex]::IsMatch(
        $Name,
        '\A[a-z0-9][a-z0-9._-]{0,62}\z',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Get-EpicVMHyperVRequiredCmdlets {
    return @(
        'Get-VM',
        'Get-VMHost',
        'Get-VMSwitch',
        'New-VM',
        'New-VHD',
        'Set-VM',
        'Set-VMProcessor',
        'Start-VM',
        'Stop-VM',
        'Restart-VM',
        'Remove-VM'
    )
}

function Invoke-EpicVMHyperVCmdlet {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [string] $CommandName,
        [AllowNull()] [hashtable] $Parameters = $null
    )

    $parametersToUse = if ($null -eq $Parameters) { @{} } else { $Parameters }
    $invoker = Get-EpicVMHyperVValue -Object $Provider -Name 'CommandInvoker'

    if ($null -ne $invoker) {
        return & $invoker $CommandName $parametersToUse
    }

    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw (New-EpicVMHyperVError -Code 'ProviderUnavailable' -Message 'The configured Hyper-V provider is unavailable.')
    }

    return & $CommandName @parametersToUse
}

function Get-EpicVMHyperVVM {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name
    )

    try {
        $items = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VM' -Parameters @{
                Name = $Name
                ErrorAction = 'Stop'
            })
    }
    catch {
        throw (New-EpicVMHyperVError -Code 'NotFound' -Message 'The requested VM was not found.')
    }

    if ($items.Count -eq 0 -or $null -eq $items[0]) {
        throw (New-EpicVMHyperVError -Code 'NotFound' -Message 'The requested VM was not found.')
    }

    return $items[0]
}

function Test-EpicVMHyperVOwned {
    param([AllowNull()] [object] $VM)

    $notes = [string](Get-EpicVMHyperVValue -Object $VM -Name 'Notes' -Default '')
    foreach ($line in ($notes -split '[\r\n]+')) {
        if ($line.Trim() -ceq $script:EpicVMHyperVOwnershipMarker) {
            return $true
        }
    }
    return $false
}

function Test-EpicVMHyperVManagedRoot {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [AllowNull()] [object] $VM
    )

    $root = [string](Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'VmRoot' -Default '')
    if ([string]::IsNullOrWhiteSpace($root) -or $null -eq $VM) { return $false }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([char[]]@([char]92, [char]47))
    }
    catch { return $false }

    $candidatePaths = @()
    foreach ($propertyName in @('Path', 'ConfigurationLocation')) {
        $candidate = [string](Get-EpicVMHyperVValue -Object $VM -Name $propertyName -Default '')
        if ($candidate) { $candidatePaths += $candidate }
    }
    if ($candidatePaths.Count -eq 0) {
        try {
            $name = [string](Get-EpicVMHyperVValue -Object $VM -Name 'Name' -Default '')
            $disks = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMHardDiskDrive' -Parameters @{ VMName = $name; ErrorAction = 'Stop' })
            foreach ($disk in $disks) {
                $candidate = [string](Get-EpicVMHyperVValue -Object $disk -Name 'Path' -Default '')
                if ($candidate) { $candidatePaths += $candidate }
            }
        }
        catch { return $false }
    }
    foreach ($candidate in $candidatePaths) {
        try {
            $candidateFull = [System.IO.Path]::GetFullPath($candidate).TrimEnd([char[]]@([char]92, [char]47))
            if ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                $candidateFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch { }
    }
    return $false
}

function ConvertTo-EpicVMHyperVVMInfo {
    param([Parameter(Mandatory)] [object] $VM)

    $name = [string](Get-EpicVMHyperVValue -Object $VM -Name 'Name' -Default '')
    $id = [string](Get-EpicVMHyperVValue -Object $VM -Name 'Id' -Default '')
    $state = [string](Get-EpicVMHyperVValue -Object $VM -Name 'State' -Default 'Unknown')
    if ([string]::IsNullOrWhiteSpace($state)) { $state = 'Unknown' }
    # Hyper-V's Status field is provider health text (often "Operating normally"),
    # not the power state shown by Get-VM.State. Preserve it for diagnostics, but
    # expose the actual VM state as the dashboard-facing status.
    $providerStatus = Get-EpicVMHyperVValue -Object $VM -Name 'Status' -Default $null
    $status = $state
    $memory = Get-EpicVMHyperVValue -Object $VM -Name 'MemoryAssigned' -Default $null
    $cpuUsage = Get-EpicVMHyperVValue -Object $VM -Name 'CPUUsage' -Default $null
    $uptime = Get-EpicVMHyperVValue -Object $VM -Name 'Uptime' -Default $null
    $uptimeSeconds = $null
    if ($null -ne $uptime) {
        try { $uptimeSeconds = [long]([System.TimeSpan]$uptime).TotalSeconds } catch { $uptimeSeconds = $null }
    }
    $notes = [string](Get-EpicVMHyperVValue -Object $VM -Name 'Notes' -Default '')
    $profile = if ($notes -match '(?m)^EpicVM-Profile:\s*omarchy\s*$') { 'omarchy' }
        elseif ($notes -match '(?m)^EpicVM-Profile:\s*gaming\s*$') { 'gaming' }
        else { 'standard' }
    $path = [string](Get-EpicVMHyperVValue -Object $VM -Name 'Path' -Default '')

    return [ordered]@{
        name = $name
        id = $id
        state = $state
        status = $status
        providerStatus = $providerStatus
        managed = Test-EpicVMHyperVOwned -VM $VM
        profile = $profile
        path = $path
        cpuUsagePercent = $cpuUsage
        memoryAssignedBytes = $memory
        uptimeSeconds = $uptimeSeconds
    }
}

function Get-EpicVMHyperVOption {
    param(
        [AllowNull()] [object] $Config,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Default = $null
    )

    return Get-EpicVMHyperVValue -Object $Config -Name $Name -Default $Default
}

function ConvertTo-EpicVMHyperVInt64 {
    param(
        [Parameter(Mandatory)] [object] $Value,
        [Parameter(Mandatory)] [string] $FieldName
    )

    try {
        return [System.Convert]::ToInt64($Value)
    }
    catch {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message ("The {0} value is invalid." -f $FieldName))
    }
}

function Get-EpicVMHyperVCreateOptions {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [object] $Request
    )

    $config = Get-EpicVMHyperVValue -Object $Provider -Name 'Config'
    $name = [string](Get-EpicVMHyperVValue -Object $Request -Name 'Name' -Default '')
    if (-not (Test-EpicVMHyperVName -Name $name)) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The VM name is invalid.')
    }

    $memoryRaw = Get-EpicVMHyperVValue -Object $Request -Name 'MemoryBytes' -Default $null
    $memory = if ($null -eq $memoryRaw) {
        ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'DefaultMemoryBytes' -Default 4294967296) -FieldName 'memoryBytes'
    }
    else {
        ConvertTo-EpicVMHyperVInt64 -Value $memoryRaw -FieldName 'memoryBytes'
    }

    $cpuRaw = Get-EpicVMHyperVValue -Object $Request -Name 'CpuCount' -Default $null
    $cpu = if ($null -eq $cpuRaw) {
        ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'DefaultCpuCount' -Default 2) -FieldName 'cpuCount'
    }
    else {
        ConvertTo-EpicVMHyperVInt64 -Value $cpuRaw -FieldName 'cpuCount'
    }

    $diskRaw = Get-EpicVMHyperVValue -Object $Request -Name 'DiskSizeBytes' -Default $null
    $disk = if ($null -eq $diskRaw) {
        ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'DefaultDiskSizeBytes' -Default 68719476736) -FieldName 'diskSizeBytes'
    }
    else {
        ConvertTo-EpicVMHyperVInt64 -Value $diskRaw -FieldName 'diskSizeBytes'
    }

    $minMemory = ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'MinMemoryBytes' -Default 536870912) -FieldName 'minMemoryBytes'
    $maxMemory = ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'MaxMemoryBytes' -Default 17179869184) -FieldName 'maxMemoryBytes'
    $minCpu = ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'MinCpuCount' -Default 1) -FieldName 'minCpuCount'
    $maxCpu = ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'MaxCpuCount' -Default 16) -FieldName 'maxCpuCount'
    $maxDisk = ConvertTo-EpicVMHyperVInt64 -Value (Get-EpicVMHyperVOption -Config $config -Name 'MaxDiskSizeBytes' -Default 549755813888) -FieldName 'maxDiskSizeBytes'

    if ($memory -lt $minMemory -or $memory -gt $maxMemory) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The requested memory is outside the configured limit.')
    }
    if ($cpu -lt $minCpu -or $cpu -gt $maxCpu) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The requested CPU count is outside the configured limit.')
    }
    if ($disk -le 0 -or $disk -gt $maxDisk) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The requested disk size is outside the configured limit.')
    }

    $generationRaw = Get-EpicVMHyperVValue -Object $Request -Name 'Generation' -Default (Get-EpicVMHyperVOption -Config $config -Name 'Generation' -Default 2)
    $generation = ConvertTo-EpicVMHyperVInt64 -Value $generationRaw -FieldName 'generation'
    if ($generation -ne 1 -and $generation -ne 2) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The Hyper-V generation must be 1 or 2.')
    }

    $switchName = [string](Get-EpicVMHyperVValue -Object $Request -Name 'SwitchName' -Default (Get-EpicVMHyperVOption -Config $config -Name 'SwitchName' -Default ''))
    $profile = [string](Get-EpicVMHyperVValue -Object $Request -Name 'Profile' -Default 'standard').ToLowerInvariant()
    $gpu = [bool](Get-EpicVMHyperVValue -Object $Request -Name 'Gpu' -Default ($profile -in @('gaming','omarchy')))
    if ($profile -notin @('standard','gaming','omarchy')) { throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The VM profile is invalid.') }
    if ($profile -in @('gaming','omarchy') -and -not $gpu) { throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'GPU-P profiles require GPU-P.') }
    if ($profile -eq 'omarchy' -and $generation -ne 2) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'Omarchy VMs require Hyper-V generation 2.')
    }
    $gpuPercentDefault = if ($profile -eq 'omarchy') {
        Get-EpicVMHyperVOption -Config $config -Name 'OmarchyGpuPartitionPercent' -Default 50
    } else {
        Get-EpicVMHyperVOption -Config $config -Name 'GamingGpuPartitionPercent' -Default 50
    }
    $gpuPercentRaw = Get-EpicVMHyperVValue -Object $Request -Name 'GpuPartitionPercent' -Default $gpuPercentDefault
    try { $gpuPercent = [int][System.Convert]::ToInt32($gpuPercentRaw) }
    catch { throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The GPU-P partition percentage is invalid.') }
    if ($gpu -and ($gpuPercent -lt 1 -or $gpuPercent -gt 100)) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The GPU-P partition percentage must be between 1 and 100.')
    }
    $gpuDeviceIdentity = if ($profile -eq 'omarchy') {
        [string](Get-EpicVMHyperVOption -Config $config -Name 'OmarchyGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF')
    } else {
        [string](Get-EpicVMHyperVOption -Config $config -Name 'GamingGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF')
    }
    $vmRoot = [string](Get-EpicVMHyperVOption -Config $config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
    if ([string]::IsNullOrWhiteSpace($vmRoot)) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The Hyper-V VM root is not configured.')
    }

    return [ordered]@{
        name = $name
        memoryBytes = $memory
        cpuCount = $cpu
        diskSizeBytes = $disk
        generation = $generation
        switchName = $switchName
        vmRoot = $vmRoot
        profile = $profile
        gpu = $gpu
        gpuPartitionPercent = $gpuPercent
        gpuDeviceIdentity = $gpuDeviceIdentity
        bootstrapSeedPath = [string](Get-EpicVMHyperVValue -Object $Request -Name 'BootstrapSeedPath' -Default '')
        templateRequired = [bool](Get-EpicVMHyperVValue -Object $Request -Name 'TemplateRequired' -Default $false)
    }
}

function Get-EpicVMHyperVCapabilities {
    param([Parameter(Mandatory)] [object] $Provider)

    $available = [bool](Get-EpicVMHyperVValue -Object $Provider -Name 'Available' -Default $false)
    $missing = @(Get-EpicVMHyperVValue -Object $Provider -Name 'MissingCmdlets' -Default @())
    $hostInfo = $null
    $switches = @()

    if ($available) {
        try {
            $hostResults = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMHost' -Parameters @{ ErrorAction = 'Stop' })
            if ($hostResults.Count -gt 0) { $hostInfo = $hostResults[0] }
        }
        catch {
            $hostInfo = $null
        }
        try {
            $switches = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMSwitch' -Parameters @{ ErrorAction = 'Stop' })
        }
        catch {
            $switches = @()
        }
    }

    $logicalProcessors = Get-EpicVMHyperVValue -Object $hostInfo -Name 'LogicalProcessorCount' -Default $null
    $memoryCapacity = Get-EpicVMHyperVValue -Object $hostInfo -Name 'MemoryCapacity' -Default $null
    $defaultSwitch = Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'SwitchName' -Default ''
    $readiness = [ordered]@{
        provisioning = $false
        gaming_provisioning = $false
        omarchy_provisioning = $false
        provisioningChecks = [ordered]@{
            template = $false
            bootstrapCredential = $false
            tailscaleOAuthClient = $false
            tailscaleTailnet = $false
            tailscaleOAuthSecret = $false
            gpuPartitionable = $false
        }
        omarchyProvisioningChecks = [ordered]@{}
    }
    if ($available -and (Get-Command -Name Test-EpicVMProvisioningPrerequisites -ErrorAction SilentlyContinue)) {
        try {
            $readiness = Test-EpicVMProvisioningPrerequisites -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Provider $Provider -Detailed
        }
        catch { }
    }
    if ($available -and (Get-Command -Name Get-EpicVMOmarchyProvisioningReadiness -ErrorAction SilentlyContinue)) {
        try {
            $omarchyReadiness = Get-EpicVMOmarchyProvisioningReadiness -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Provider $Provider
            $readiness.omarchy_provisioning = [bool]$omarchyReadiness.omarchy_provisioning
            $readiness.omarchyProvisioningChecks = $omarchyReadiness.omarchyProvisioningChecks
        }
        catch { }
    }

    return [ordered]@{
        provider = 'HyperV'
        available = $available
        missingCmdlets = $missing
        ownershipMarker = $script:EpicVMHyperVOwnershipMarker
        # Emit the normalized control-plane contract as well as the human-readable
        # feature list. The dashboard must not have to infer lifecycle support
        # from provider-specific feature names.
        create_vm = $available
        start = $available
        stop = $available
        restart = $available
        delete = $available
        console = $false
        provisioning = [bool]$readiness.provisioning
        gaming_provisioning = [bool]$readiness.gaming_provisioning
        omarchy_provisioning = [bool]$readiness.omarchy_provisioning
        provisioningChecks = $readiness.provisioningChecks
        omarchyProvisioningChecks = $readiness.omarchyProvisioningChecks
        features = @('capabilities', 'list', 'create', 'lifecycle', 'delete-owned', 'full-copy-template', 'powershell-direct', 'tailscale-enrollment', 'omarchy-linux', 'tailscale-ssh')
        resources = [ordered]@{
            logicalProcessorCount = $logicalProcessors
            memoryCapacityBytes = $memoryCapacity
            switchCount = $switches.Count
            configuredSwitch = $defaultSwitch
        }
        limits = [ordered]@{
            minMemoryBytes = Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'MinMemoryBytes' -Default 536870912
            maxMemoryBytes = Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'MaxMemoryBytes' -Default 17179869184
            minCpuCount = Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'MinCpuCount' -Default 1
            maxCpuCount = Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'MaxCpuCount' -Default 16
            maxDiskSizeBytes = Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'MaxDiskSizeBytes' -Default 549755813888
        }
    }
}

function Test-EpicVMHyperVGpuPartitionable {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [string] $DeviceIdentity = ''
    )

    if (-not [bool](Get-EpicVMHyperVValue -Object $Provider -Name 'Available' -Default $false)) { return $false }
    try {
        # The cmdlet is optional on hosts without GPU-P.  A provider or Pester
        # invoker that cannot resolve it is a clean "not ready", never a reason
        # to expose GPU provisioning.
        $items = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMHostPartitionableGpu' -Parameters @{ ErrorAction = 'Stop' })
        if ([string]::IsNullOrWhiteSpace($DeviceIdentity)) {
            $DeviceIdentity = [string](Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'GamingGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF')
        }
        if ($items.Count -eq 0) { return $false }
        Resolve-EpicVMGamingPartitionableGpu -PartitionableGpus $items -DeviceIdentity $DeviceIdentity | Out-Null
        return $true
    }
    catch { return $false }
}

function Get-EpicVMHyperVGamingGpu {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [string] $DeviceIdentity = '',
        [string] $ProfileName = 'gaming'
    )

    if ([string]::IsNullOrWhiteSpace($DeviceIdentity)) {
        $identityConfigName = if ($ProfileName -ieq 'omarchy') { 'OmarchyGpuDeviceIdentity' } else { 'GamingGpuDeviceIdentity' }
        $DeviceIdentity = [string](Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name $identityConfigName -Default 'VEN_1002&DEV_73BF')
    }
    try {
        $items = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMHostPartitionableGpu' -Parameters @{ ErrorAction = 'Stop' })
    }
    catch {
        throw (New-EpicVMHyperVError -Code 'GpuUnavailable' -Message ("GPU-P support is unavailable for the {0} profile." -f $ProfileName))
    }
    if ($items.Count -eq 0) {
        throw (New-EpicVMHyperVError -Code 'GpuUnavailable' -Message ("No partitionable GPU is available for the {0} profile." -f $ProfileName))
    }
    try {
        return Resolve-EpicVMGamingPartitionableGpu -PartitionableGpus $items -DeviceIdentity $DeviceIdentity
    }
    catch {
        if ($_.Exception.PSObject.Properties['ErrorCode']) {
            throw (New-EpicVMHyperVError -Code 'GpuUnavailable' -Message $_.Exception.Message)
        }
        throw
    }
}

function Set-EpicVMHyperVGamingVmProperties {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name
    )

    $settings = Get-EpicVMGamingVmSettings
    $parameters = @{ Name = $Name; ErrorAction = 'Stop' }
    foreach ($key in $settings.Keys) { $parameters[$key] = $settings[$key] }
    Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VM' -Parameters $parameters | Out-Null
    return $settings
}

function Set-EpicVMHyperVStaticMemory {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [long] $MemoryBytes
    )

    if ($MemoryBytes -le 0) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'Static memory must be greater than zero.')
    }
    Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VMMemory' -Parameters @{
        VMName = $Name
        StartupBytes = $MemoryBytes
        DynamicMemoryEnabled = $false
        ErrorAction = 'Stop'
    } | Out-Null
    return [ordered]@{
        ok = $true
        memoryBytes = $MemoryBytes
        dynamicMemoryEnabled = $false
    }
}

function Test-EpicVMHyperVGamingAdapterIdentity {
    param(
        [Parameter(Mandatory)] [object] $Adapter,
        [Parameter(Mandatory)] [string] $DeviceIdentity
    )

    $path = [string](Get-EpicVMGamingProperty -Object $Adapter -Name 'InstancePath' -Default '')
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = [string](Get-EpicVMGamingProperty -Object $Adapter -Name 'Name' -Default '')
    }
    return $path.IndexOf($DeviceIdentity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Set-EpicVMHyperVGamingGpuPartitionAdapter {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateRange(1, 100)] [int] $Percent,
        [string] $DeviceIdentity = '',
        [ValidateSet('gaming','omarchy')] [string] $ProfileName = 'gaming'
    )

    foreach ($commandName in @('Get-VMHostPartitionableGpu','Get-VMGpuPartitionAdapter','Add-VMGpuPartitionAdapter','Set-VMGpuPartitionAdapter')) {
        if ($null -eq (Get-EpicVMHyperVValue -Object $Provider -Name 'CommandInvoker' -Default $null) -and
            $null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw (New-EpicVMHyperVError -Code 'GpuUnavailable' -Message ("GPU-P support is unavailable for the {0} profile." -f $ProfileName))
        }
    }

    $config = Get-EpicVMHyperVValue -Object $Provider -Name 'Config'
    if ([string]::IsNullOrWhiteSpace($DeviceIdentity)) {
        $identityConfigName = if ($ProfileName -ieq 'omarchy') { 'OmarchyGpuDeviceIdentity' } else { 'GamingGpuDeviceIdentity' }
        $DeviceIdentity = [string](Get-EpicVMHyperVOption -Config $config -Name $identityConfigName -Default 'VEN_1002&DEV_73BF')
    }
    $gpu = Get-EpicVMHyperVGamingGpu -Provider $Provider -DeviceIdentity $DeviceIdentity -ProfileName $ProfileName
    $identity = $DeviceIdentity
    $plan = Get-EpicVMGamingGpuPartitionPlan -PartitionableGpu $gpu -Percent $Percent
    $adapters = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMGpuPartitionAdapter' -Parameters @{ VMName=$Name; ErrorAction='Stop' })
    if ($adapters.Count -gt 1) {
        throw (New-EpicVMHyperVError -Code 'GpuAdapterCountInvalid' -Message ("{0} VMs must have exactly one GPU partition adapter." -f $ProfileName))
    }
    if ($adapters.Count -eq 1 -and -not (Test-EpicVMHyperVGamingAdapterIdentity -Adapter $adapters[0] -DeviceIdentity $identity)) {
        throw (New-EpicVMHyperVError -Code 'GpuIdentityMismatch' -Message ("The existing {0} GPU partition adapter does not match the configured AMD device identity." -f $ProfileName))
    }
    if ($adapters.Count -eq 0) {
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Add-VMGpuPartitionAdapter' -Parameters @{
            VMName = $Name
            InstancePath = [string]$plan.instancePath
            ErrorAction = 'Stop'
        } | Out-Null
    }

    $gpuParameters = @{ VMName=$Name; ErrorAction='Stop' }
    foreach ($key in @(
            'minPartitionVRAM','maxPartitionVRAM','optimalPartitionVRAM',
            'minPartitionDecode','maxPartitionDecode','optimalPartitionDecode',
            'minPartitionCompute','maxPartitionCompute','optimalPartitionCompute',
            'minPartitionEncode','maxPartitionEncode','optimalPartitionEncode')) {
        $gpuParameters[$key] = [long]$plan[$key]
    }
    Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VMGpuPartitionAdapter' -Parameters $gpuParameters | Out-Null

    $finalAdapters = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMGpuPartitionAdapter' -Parameters @{ VMName=$Name; ErrorAction='Stop' })
    if ($finalAdapters.Count -ne 1 -or -not (Test-EpicVMHyperVGamingAdapterIdentity -Adapter $finalAdapters[0] -DeviceIdentity $identity)) {
        throw (New-EpicVMHyperVError -Code 'GpuAdapterVerificationFailed' -Message ("GPU-P adapter verification did not produce exactly one matching AMD adapter for {0}." -f $ProfileName))
    }
    $adapterPath = [string](Get-EpicVMGamingProperty -Object $finalAdapters[0] -Name 'InstancePath' -Default (Get-EpicVMGamingProperty -Object $finalAdapters[0] -Name 'Name' -Default ''))
    return [ordered]@{
        ok = $true
        name = $Name
        plan = $plan
        adapterCount = $finalAdapters.Count
        adapterInstancePath = $adapterPath
    }
}

function Test-EpicVMHyperVGamingProfile {
    param(
        [AllowNull()] [object] $VM,
        [ValidateSet('gaming','omarchy')] [string] $ProfileName = 'gaming'
    )

    $notes = [string](Get-EpicVMHyperVValue -Object $VM -Name 'Notes' -Default '')
    foreach ($line in ($notes -split [char]10)) {
        if ($line.Trim() -ceq ('EpicVM-Profile: ' + $ProfileName)) { return $true }
    }
    return $false
}

function Wait-EpicVMHyperVState {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Running','Off')] [string] $DesiredState,
        [int] $TimeoutSeconds = 120,
        [int] $PollMilliseconds = 1000
    )

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    do {
        $current = Get-EpicVMHyperVVM -Provider $Provider -Name $Name
        $state = [string](Get-EpicVMHyperVValue -Object $current -Name 'State' -Default '')
        if ($state -ieq $DesiredState) { return $current }
        Start-Sleep -Milliseconds ([Math]::Max(100, $PollMilliseconds))
    } while ([DateTime]::UtcNow -lt $deadline)

    throw (New-EpicVMHyperVError -Code 'HyperVStateTimeout' -Message ("VM '{0}' did not reach the expected '{1}' state." -f $Name, $DesiredState))
}

function Set-EpicVMHyperVGamingGpuPartitionPercent {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [int] $Percent
    )

    if ($Percent -lt 1 -or $Percent -gt 100) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The GPU-P partition percentage must be between 1 and 100.')
    }
    $vm = Get-EpicVMHyperVVM -Provider $Provider -Name $Name
    if (-not (Test-EpicVMHyperVOwned -VM $vm) -or -not (Test-EpicVMHyperVManagedRoot -Provider $Provider -VM $vm)) {
        throw (New-EpicVMHyperVError -Code 'UnmanagedVM' -Message ("VM '{0}' is not an EpicVM-managed Gaming VM." -f $Name))
    }
    $profileName = if (Test-EpicVMHyperVGamingProfile -VM $vm -ProfileName 'gaming') { 'gaming' }
        elseif (Test-EpicVMHyperVGamingProfile -VM $vm -ProfileName 'omarchy') { 'omarchy' }
        else { '' }
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'GPU-P partition changes are available only for GPU-P profiles.')
    }

    $wasRunning = [string](Get-EpicVMHyperVValue -Object $vm -Name 'State' -Default 'Unknown') -ieq 'Running'
    $result = $null
    try {
        if ($wasRunning) {
            # Hyper-V can report the stop request before the VM is actually
            # Off. Applying GPU-P quotas during that transition can leave the
            # guest render device in a stale state until a second cold boot.
            Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Stop-VM' -Parameters @{ Name=$Name; ErrorAction='Stop' } | Out-Null
            Wait-EpicVMHyperVState -Provider $Provider -Name $Name -DesiredState 'Off' | Out-Null
        }
        $config = Get-EpicVMHyperVValue -Object $Provider -Name 'Config'
        $identityName = if ($profileName -eq 'omarchy') { 'OmarchyGpuDeviceIdentity' } else { 'GamingGpuDeviceIdentity' }
        $identity = [string](Get-EpicVMHyperVOption -Config $config -Name $identityName -Default 'VEN_1002&DEV_73BF')
        $result = Set-EpicVMHyperVGamingGpuPartitionAdapter -Provider $Provider -Name $Name -Percent $Percent -DeviceIdentity $identity -ProfileName $profileName
    }
    finally {
        if ($wasRunning) {
            $current = Get-EpicVMHyperVVM -Provider $Provider -Name $Name
            $currentState = [string](Get-EpicVMHyperVValue -Object $current -Name 'State' -Default '')
            if ($currentState -ine 'Running') {
                Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Start-VM' -Parameters @{ Name=$Name; ErrorAction='Stop' } | Out-Null
            }
            Wait-EpicVMHyperVState -Provider $Provider -Name $Name -DesiredState 'Running' | Out-Null
        }
    }

    return [ordered]@{
        ok = $true
        name = $Name
        percent = $Percent
        wasRunning = $wasRunning
        restarted = $wasRunning
        adapter = $result
    }
}

function Invoke-EpicVMHyperVGamingGuestValidation {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $GuestUsername,
        [Parameter(Mandatory)] [string] $GuestPassword,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $GuestAddress,
        [bool] $RequireEncoder = $true
    )

    if ($GuestAddress -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$') {
        throw (New-EpicVMHyperVError -Code 'gaming_guest_validation_failed' -Message 'The Gaming guest address is not a verified Tailscale address.' -DetailCode 'GAMING_GPU_DEVICE_ERROR')
    }
    $credential = $null
    try {
        $credential = [PSCredential]::new($GuestUsername, (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
        $config = Get-EpicVMHyperVValue -Object $Provider -Name 'Config'
        $serviceName = [string](Get-EpicVMHyperVOption -Config $config -Name 'SunshineServiceName' -Default 'SunshineService')
        $statePaths = @(Get-EpicVMHyperVOption -Config $config -Name 'SunshineStatePaths' -Default @())
        $result = Invoke-EpicVMManagementTransport -Provider $Provider -Address $GuestAddress -Credential (New-EpicVMWinRMLocalCredential -Credential $credential) -Script (Get-EpicVMGamingGuestValidationScript) -ArgumentList @([string](Get-EpicVMHyperVOption -Config $config -Name 'GamingGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF'), $serviceName, $statePaths, $RequireEncoder) -TimeoutSeconds 240 -RetryCount 1
        $payload = Get-EpicVMHyperVValue -Object $result -Name 'result' -Default $result
        $safeMarker = [string](Get-EpicVMHyperVValue -Object $result -Name 'safeMarker' -Default (Get-EpicVMHyperVValue -Object $payload -Name 'safeMarker' -Default ''))
        if ($safeMarker -eq 'EPICVM_GAMING_ENCODER_UNAVAILABLE') {
            throw (New-EpicVMHyperVError -Code 'gaming_encoder_unavailable' -Message 'Sunshine AMD hardware encoding was not verified.' -DetailCode 'GAMING_GPU_ENCODER')
        }
        $ok = [bool](Get-EpicVMHyperVValue -Object $payload -Name 'ok' -Default $false)
        if (-not $ok) {
            $detail = [string](Get-EpicVMHyperVValue -Object $payload -Name 'failureDetailCode' -Default 'GAMING_GPU_DEVICE_ERROR')
            if ($detail -notin @('GAMING_GPU_DEVICE_MISSING','GAMING_GPU_DEVICE_ERROR','GAMING_GPU_DRIVER_INJECTION','GAMING_GPU_DXDIAG','GAMING_GPU_WEBGL','GAMING_GPU_ENCODER')) { $detail = 'GAMING_GPU_DEVICE_ERROR' }
            throw (New-EpicVMHyperVError -Code 'gaming_gpu_validation_failed' -Message 'The Gaming guest GPU validation gate failed.' -DetailCode $detail)
        }
        return [ordered]@{ ok = $true; name = $Name; address = $GuestAddress; validation = $payload }
    }
    catch {
        if ($_.Exception.PSObject.Properties['ErrorCode']) { throw }
        throw (New-EpicVMHyperVError -Code 'gaming_guest_validation_failed' -Message 'The Gaming guest GPU validation transport failed.' -DetailCode 'GAMING_GPU_DEVICE_ERROR')
    }
    finally { $credential = $null }
}

function Get-EpicVMHyperVVMs {
    param([Parameter(Mandatory)] [object] $Provider)

    if (-not [bool](Get-EpicVMHyperVValue -Object $Provider -Name 'Available' -Default $false)) {
        throw (New-EpicVMHyperVError -Code 'ProviderUnavailable' -Message 'The configured Hyper-V provider is unavailable.')
    }

    $items = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VM' -Parameters @{ ErrorAction = 'Stop' })
    return @($items | ForEach-Object { ConvertTo-EpicVMHyperVVMInfo -VM $_ })
}

function New-EpicVMHyperVVM {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [object] $Request
    )

    if (-not [bool](Get-EpicVMHyperVValue -Object $Provider -Name 'Available' -Default $false)) {
        throw (New-EpicVMHyperVError -Code 'ProviderUnavailable' -Message 'The configured Hyper-V provider is unavailable.')
    }

    $options = Get-EpicVMHyperVCreateOptions -Provider $Provider -Request $Request
    $config = Get-EpicVMHyperVValue -Object $Provider -Name 'Config'
    $name = [string]$options.name

    try {
        $existing = Get-EpicVMHyperVVM -Provider $Provider -Name $name
        if ($null -ne $existing) {
            throw (New-EpicVMHyperVError -Code 'Conflict' -Message 'A VM with that name already exists.')
        }
    }
    catch {
        if ($_.Exception.PSObject.Properties['ErrorCode'] -and $_.Exception.ErrorCode -eq 'Conflict') {
            throw
        }
        # Get-VM reports a missing VM as an error on native Hyper-V.  That is
        # the expected path while creating a new VM.
    }

    $vmPath = Join-Path -Path ([string]$options.vmRoot) -ChildPath $name
    $diskPath = Join-Path -Path $vmPath -ChildPath ("{0}.vhdx" -f $name)
    if (Test-Path -LiteralPath $diskPath) {
        throw (New-EpicVMHyperVError -Code 'Conflict' -Message 'The VM disk path already exists.')
    }

    $switchName = [string]$options.switchName
    if (-not [string]::IsNullOrWhiteSpace($switchName)) {
        $switches = @(Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VMSwitch' -Parameters @{
                Name = $switchName
                ErrorAction = 'Stop'
            })
        if ($switches.Count -eq 0) {
            throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The configured Hyper-V switch was not found.')
        }
    }

    $createdVm = $false
    $createdDisk = $false
    try {
        New-Item -ItemType Directory -Path $vmPath -Force -ErrorAction Stop | Out-Null
        $templateDiskPath = [string](Get-EpicVMHyperVValue -Object $Request -Name 'templateDiskPath' -Default '')
        $templateRequired = [bool](Get-EpicVMHyperVValue -Object $Request -Name 'templateRequired' -Default $false)
        if ($templateRequired) {
            if ([string]::IsNullOrWhiteSpace($templateDiskPath) -or -not (Test-Path -LiteralPath $templateDiskPath -PathType Leaf)) {
                throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The validated template disk is unavailable.')
            }
            # Full independent copy.  Differencing disks are intentionally not
            # used because template identity and recovery depend on isolation.
            Copy-Item -LiteralPath $templateDiskPath -Destination $diskPath -Force -ErrorAction Stop
            # The golden image is immutable and therefore read-only. Copy-Item
            # preserves that attribute, but the independent guest disk must be
            # writable before Resize-VHD and Hyper-V can use it.
            (Get-Item -LiteralPath $diskPath -ErrorAction Stop).IsReadOnly = $false
            $templateVhd = Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Get-VHD' -Parameters @{ Path=$diskPath; ErrorAction='Stop' }
            if (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMHyperVValue -Object $templateVhd -Name 'ParentPath' -Default '')) -or
                [string](Get-EpicVMHyperVValue -Object $templateVhd -Name 'VhdType' -Default '') -ine 'Dynamic') {
                throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The template disk must be a consolidated dynamic VHDX.')
            }
            $templateSize = [long](Get-EpicVMHyperVValue -Object $templateVhd -Name 'Size' -Default 0)
            if ($templateSize -gt [long]$options.diskSizeBytes) {
                throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The validated template is larger than the requested profile disk.')
            }
            if ($templateSize -lt [long]$options.diskSizeBytes) {
                Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Resize-VHD' -Parameters @{ Path=$diskPath; SizeBytes=[long]$options.diskSizeBytes; ErrorAction='Stop' } | Out-Null
            }
        }
        else {
            Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'New-VHD' -Parameters @{
                Path = $diskPath
                SizeBytes = [long]$options.diskSizeBytes
                Dynamic = $true
                ErrorAction = 'Stop'
            } | Out-Null
        }
        $createdDisk = $true

        if ($options.gpu -and $options.profile -eq 'gaming') {
            $driverSources = Resolve-EpicVMGamingGpuDriverSourcePaths -Config $config -DeviceIdentity $options.gpuDeviceIdentity
            Invoke-EpicVMGamingGpuDriverInjection -DiskPath $diskPath -DriverSourcePaths $driverSources -DeviceIdentity $options.gpuDeviceIdentity | Out-Null
        }
        if ($options.profile -eq 'omarchy') {
            $seedPath = [string]$options.bootstrapSeedPath
            if ([string]::IsNullOrWhiteSpace($seedPath) -or -not (Test-Path -LiteralPath $seedPath -PathType Leaf)) {
                throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The Omarchy cidata bootstrap seed is unavailable.')
            }
            $vmRootFull = [IO.Path]::GetFullPath($vmPath).TrimEnd([char[]]@([char]92, [char]47))
            $seedFull = [IO.Path]::GetFullPath($seedPath)
            if (-not $seedFull.StartsWith($vmRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw (New-EpicVMHyperVError -Code 'InvalidInput' -Message 'The Omarchy cidata bootstrap seed is outside the managed VM root.')
            }
        }

        $newVmParameters = @{
            Name = $name
            MemoryStartupBytes = [long]$options.memoryBytes
            Generation = [long]$options.generation
            VHDPath = $diskPath
            Path = $vmPath
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($switchName)) {
            $newVmParameters.SwitchName = $switchName
        }
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'New-VM' -Parameters $newVmParameters | Out-Null
        $createdVm = $true
        if ($options.profile -eq 'omarchy') {
            Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Add-VMHardDiskDrive' -Parameters @{
                VMName = $name
                Path = [string]$options.bootstrapSeedPath
                ControllerType = 'SCSI'
                ControllerNumber = 0
                ControllerLocation = 1
                ErrorAction = 'Stop'
            } | Out-Null
        }

        if ($options.profile -eq 'gaming') {
            Set-EpicVMHyperVStaticMemory -Provider $Provider -Name $name -MemoryBytes ([long]$options.memoryBytes) | Out-Null
        }

        $notes = $script:EpicVMHyperVOwnershipMarker
        if ($options.profile -eq 'gaming') { $notes = $notes + "`r`nEpicVM-Profile: gaming" }
        if ($options.profile -eq 'omarchy') { $notes = $notes + [Environment]::NewLine + 'EpicVM-Profile: omarchy' }
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VM' -Parameters @{
            Name = $name
            Notes = $notes
            ErrorAction = 'Stop'
        } | Out-Null
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VMProcessor' -Parameters @{
            VMName = $name
            Count = [long]$options.cpuCount
            ErrorAction = 'Stop'
        } | Out-Null

        # Every provisioned VM receives an explicit locally-administered MAC;
        # Hyper-V's automatic allocation is not an identity contract.
        $macBytes = [byte[]]::new(6)
        [Security.Cryptography.RandomNumberGenerator]::Fill($macBytes)
        $macBytes[0] = ($macBytes[0] -bor 0x02) -band 0xfe
        $mac = ($macBytes | ForEach-Object { $_.ToString('X2') }) -join '-'
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VMNetworkAdapter' -Parameters @{
            VMName = $name
            StaticMacAddress = $mac
            ErrorAction = 'Stop'
        } | Out-Null

        if ($options.gpu) {
            if ($options.profile -eq 'gaming') {
                Set-EpicVMHyperVGamingVmProperties -Provider $Provider -Name $name | Out-Null
            }
            Set-EpicVMHyperVGamingGpuPartitionAdapter -Provider $Provider -Name $name -Percent ([int]$options.gpuPartitionPercent) -DeviceIdentity ([string]$options.gpuDeviceIdentity) -ProfileName ([string]$options.profile) | Out-Null
        }

        if ($options.profile -eq 'omarchy') {
            $secureBoot = Get-Command -Name 'Set-VMFirmware' -ErrorAction SilentlyContinue
            if ($null -eq (Get-EpicVMHyperVValue -Object $Provider -Name 'CommandInvoker' -Default $null) -and $null -eq $secureBoot) {
                throw (New-EpicVMHyperVError -Code 'SecurityUnavailable' -Message 'Explicit Omarchy UEFI/Secure Boot control is unavailable.')
            }
            Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VMFirmware' -Parameters @{ VMName=$name; EnableSecureBoot='Off'; ErrorAction='Stop' } | Out-Null
        }
        elseif ($options.templateRequired) {
            $keyProtector = Get-Command -Name 'Set-VMKeyProtector' -ErrorAction SilentlyContinue
            $enableTpm = Get-Command -Name 'Enable-VMTPM' -ErrorAction SilentlyContinue
            $secureBoot = Get-Command -Name 'Set-VMFirmware' -ErrorAction SilentlyContinue
            if ($null -eq (Get-EpicVMHyperVValue -Object $Provider -Name 'CommandInvoker' -Default $null) -and ($null -eq $keyProtector -or $null -eq $enableTpm -or $null -eq $secureBoot)) {
                throw (New-EpicVMHyperVError -Code 'SecurityUnavailable' -Message 'Unique vTPM/key-protector support is unavailable.')
            }
            Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VMFirmware' -Parameters @{ VMName=$name; EnableSecureBoot='On'; ErrorAction='Stop' } | Out-Null
            Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Set-VMKeyProtector' -Parameters @{ VMName=$name; NewLocalKeyProtector=$true; ErrorAction='Stop' } | Out-Null
            Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Enable-VMTPM' -Parameters @{ VMName=$name; ErrorAction='Stop' } | Out-Null
        }

        return ConvertTo-EpicVMHyperVVMInfo -VM (Get-EpicVMHyperVVM -Provider $Provider -Name $name)
    }
    catch {
        if ($createdVm) {
            try {
                Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Remove-VM' -Parameters @{
                    Name = $name
                    Force = $true
                    ErrorAction = 'SilentlyContinue'
                } | Out-Null
            }
            catch { }
        }
        if ($createdDisk -and (Test-Path -LiteralPath $diskPath)) {
            try { Remove-Item -LiteralPath $diskPath -Force -ErrorAction SilentlyContinue } catch { }
        }
        throw
    }
}

function Invoke-EpicVMHyperVLifecycle {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Start', 'Stop', 'Restart')] [string] $Action
    )

    if (-not [bool](Get-EpicVMHyperVValue -Object $Provider -Name 'Available' -Default $false)) {
        throw (New-EpicVMHyperVError -Code 'ProviderUnavailable' -Message 'The configured Hyper-V provider is unavailable.')
    }

    $vm = Get-EpicVMHyperVVM -Provider $Provider -Name $Name
    if (-not (Test-EpicVMHyperVOwned -VM $vm)) {
        throw (New-EpicVMHyperVError -Code 'UnmanagedVM' -Message ("VM '{0}' is not owned by EpicVM and cannot be changed." -f $Name))
    }
    if (-not (Test-EpicVMHyperVManagedRoot -Provider $Provider -VM $vm)) {
        throw (New-EpicVMHyperVError -Code 'UnmanagedVM' -Message ("VM '{0}' is outside the EpicVM managed root and cannot be changed." -f $Name))
    }

    $state = [string](Get-EpicVMHyperVValue -Object $vm -Name 'State' -Default 'Unknown')
    if ($Action -eq 'Start' -and $state -ieq 'Running') {
        return ConvertTo-EpicVMHyperVVMInfo -VM $vm
    }
    if ($Action -eq 'Stop' -and $state -ieq 'Off') {
        return ConvertTo-EpicVMHyperVVMInfo -VM $vm
    }
    if ($Action -eq 'Restart' -and $state -ieq 'Off') {
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Start-VM' -Parameters @{ Name = $Name; ErrorAction = 'Stop' } | Out-Null
    }
    elseif ($Action -eq 'Start') {
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Start-VM' -Parameters @{ Name = $Name; ErrorAction = 'Stop' } | Out-Null
    }
    elseif ($Action -eq 'Stop') {
        # Do not use -Force here: a normal stop lets the guest shut down cleanly.
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Stop-VM' -Parameters @{ Name = $Name; ErrorAction = 'Stop' } | Out-Null
    }
    elseif ($Action -eq 'Restart') {
        # A graceful guest restart can block the single-threaded agent listener
        # indefinitely when the guest integration service is unhealthy.  Force
        # is scoped to this already ownership-checked Hyper-V VM so lifecycle
        # recovery returns to the caller instead of wedging the agent.
        Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Restart-VM' -Parameters @{ Name = $Name; Force = $true; ErrorAction = 'Stop' } | Out-Null
    }

    return ConvertTo-EpicVMHyperVVMInfo -VM (Get-EpicVMHyperVVM -Provider $Provider -Name $Name)
}

function Remove-EpicVMHyperVVM {
    param(
        [Parameter(Mandatory)] [object] $Provider,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name
    )

    if (-not [bool](Get-EpicVMHyperVValue -Object $Provider -Name 'Available' -Default $false)) {
        throw (New-EpicVMHyperVError -Code 'ProviderUnavailable' -Message 'The configured Hyper-V provider is unavailable.')
    }

    $vm = Get-EpicVMHyperVVM -Provider $Provider -Name $Name
    if (-not (Test-EpicVMHyperVOwned -VM $vm)) {
        throw (New-EpicVMHyperVError -Code 'UnmanagedVM' -Message ("VM '{0}' is not owned by EpicVM and cannot be changed." -f $Name))
    }
    if (-not (Test-EpicVMHyperVManagedRoot -Provider $Provider -VM $vm)) {
        throw (New-EpicVMHyperVError -Code 'UnmanagedVM' -Message ("VM '{0}' is outside the EpicVM managed root and cannot be changed." -f $Name))
    }
    if ([string](Get-EpicVMHyperVValue -Object $vm -Name 'State' -Default '') -ieq 'Running') {
        throw (New-EpicVMHyperVError -Code 'Conflict' -Message 'Stop the VM before deleting it.')
    }

    # Remove-VM unregisters the VM.  It intentionally does not remove the VHDX.
    Invoke-EpicVMHyperVCmdlet -Provider $Provider -CommandName 'Remove-VM' -Parameters @{
        Name = $Name
        Force = $true
        ErrorAction = 'Stop'
    } | Out-Null

    return [ordered]@{
        name = $Name
        deleted = $true
        disksPreserved = $true
    }
}

function Move-EpicVMHyperVQuarantine {
    param([Parameter(Mandatory)][object]$Provider,[Parameter(Mandatory)][string]$Name)
    $root=[string](Get-EpicVMHyperVOption -Config (Get-EpicVMHyperVValue -Object $Provider -Name 'Config') -Name 'VmRoot' -Default '')
    $source=Join-Path $root $Name
    if(-not(Test-Path -LiteralPath $source)){return [ordered]@{ok=$true;quarantined=$false}}
    try {
        $rootFull=[IO.Path]::GetFullPath($root).TrimEnd('\')
        $sourceFull=[IO.Path]::GetFullPath($source)
        if(-not($sourceFull.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase))){throw 'VM path is outside the managed root.'}
        $quarantineRoot=Join-Path $root 'quarantine'
        $destination=Join-Path $quarantineRoot ($Name + '-' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        New-Item -ItemType Directory -Path $quarantineRoot -Force|Out-Null
        Move-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
        return [ordered]@{ok=$true;quarantined=$true;path=$destination;quarantineUntil=[DateTime]::UtcNow.AddDays(7).ToString('o')}
    }catch{throw (New-EpicVMHyperVError -Code 'QuarantineFailed' -Message 'The named VM resources could not be quarantined.')}
}

function New-EpicVMHyperVProvider {
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $Config = @{},
        [AllowNull()] [scriptblock] $CommandInvoker = $null,
        [AllowNull()] [scriptblock] $PowerShellDirectInvoker = $null,
        [AllowNull()] [scriptblock] $ManagementInvoker = $null,
        [AllowNull()] [scriptblock] $BootstrapCredentialLoader = $null,
        [AllowNull()] [scriptblock] $TailscaleHttpInvoker = $null,
        [AllowNull()] [scriptblock] $TailscaleOAuthInvoker = $null,
        [AllowNull()] [scriptblock] $TailscaleOAuthSecretLoader = $null
    )

    $missing = @()
    if ($null -eq $CommandInvoker) {
        foreach ($commandName in (Get-EpicVMHyperVRequiredCmdlets)) {
            if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                $missing += $commandName
            }
        }
    }

    $configuredManagementPort = 0
    try { $configuredManagementPort = [int](Get-EpicVMHyperVValue -Object $Config -Name 'ManagementPort' -Default 5985) } catch { $configuredManagementPort = 5985 }
    if ($configuredManagementPort -lt 1 -or $configuredManagementPort -gt 65535) { $configuredManagementPort = 5985 }

    $provider = [pscustomobject]@{
        Name = 'HyperV'
        Config = $Config
        Available = ($null -ne $CommandInvoker -or $missing.Count -eq 0)
        MissingCmdlets = $missing
        CommandInvoker = $CommandInvoker
        PowerShellDirectInvoker = $PowerShellDirectInvoker
        ManagementInvoker = $ManagementInvoker
        ManagementPort = $configuredManagementPort
        ManagementUseSsl = [bool](Get-EpicVMHyperVValue -Object $Config -Name 'ManagementUseSsl' -Default $false)
        # The post-network handoff is mandatory for new provisioning. An old
        # config may contain false from the pre-handoff agent; normalize that
        # stale value in memory and let the config repair script persist it.
        RequireManagementTransport = $true
        BootstrapCredentialLoader = $BootstrapCredentialLoader
        TailscaleHttpInvoker = $TailscaleHttpInvoker
        TailscaleOAuthInvoker = $TailscaleOAuthInvoker
        TailscaleOAuthSecretLoader = $TailscaleOAuthSecretLoader
        TailscaleOAuthClientId = [string](Get-EpicVMHyperVValue -Object $Config -Name 'TailscaleOAuthClientId' -Default '')
        TailscaleOAuthSecretPath = [string](Get-EpicVMHyperVValue -Object $Config -Name 'TailscaleOAuthSecretPath' -Default '')
        TailscaleTailnet = [string](Get-EpicVMHyperVValue -Object $Config -Name 'TailscaleTailnet' -Default '')
        TailscaleGuestTag = [string](Get-EpicVMHyperVValue -Object $Config -Name 'TailscaleGuestTag' -Default 'tag:epicvm-guest')
        TailscaleApiBaseUrl = [string](Get-EpicVMHyperVValue -Object $Config -Name 'TailscaleApiBaseUrl' -Default 'https://api.tailscale.com/api/v2')
        LastTailscaleEnrollment = $null
        LastOmarchyGuestIp = $null
        GetCapabilities = $null
        GetVMs = $null
        CreateVM = $null
        StartVM = $null
        StopVM = $null
        RestartVM = $null
        DeleteVM = $null
        SetGamingGpuPercent = $null
        ValidateGamingGuest = $null
        PrepareOmarchyBootstrap = $null
        WaitOmarchyGuestReady = $null
        ConfigureOmarchyGuest = $null
        ValidateOmarchyGuest = $null
        CleanupOmarchyBootstrap = $null
        RemoveOmarchySeed = $null
        DiscardOmarchyBootstrap = $null
        ConfigureGuest = $null
        TestBootstrapGuest = $null
        ConfigureSunshine = $null
        EnrollTailscale = $null
        VerifyGuest = $null
        RevokeTailscale = $null
        ClearTailscaleStaleDevices = $null
        TeardownConsole = $null
        QuarantineVM = $null
    }

    $getCapabilities = ${function:Get-EpicVMHyperVCapabilities}
    $getVMs = ${function:Get-EpicVMHyperVVMs}
    $createVM = ${function:New-EpicVMHyperVVM}
    $startVM = ${function:Invoke-EpicVMHyperVLifecycle}
    $stopVM = ${function:Invoke-EpicVMHyperVLifecycle}
    $restartVM = ${function:Invoke-EpicVMHyperVLifecycle}
    $deleteVM = ${function:Remove-EpicVMHyperVVM}
    $setGamingGpuPercent = ${function:Set-EpicVMHyperVGamingGpuPartitionPercent}
    $validateGamingGuest = ${function:Invoke-EpicVMHyperVGamingGuestValidation}
    $provider.GetCapabilities = ({ & $getCapabilities -Provider $provider }.GetNewClosure())
    $provider.GetVMs = ({ & $getVMs -Provider $provider }.GetNewClosure())
    $provider.CreateVM = ({ param($Request) & $createVM -Provider $provider -Request $Request }.GetNewClosure())
    $provider.StartVM = ({ param($Name) & $startVM -Provider $provider -Name $Name -Action Start }.GetNewClosure())
    $provider.StopVM = ({ param($Name) & $stopVM -Provider $provider -Name $Name -Action Stop }.GetNewClosure())
    $provider.RestartVM = ({ param($Name) & $restartVM -Provider $provider -Name $Name -Action Restart }.GetNewClosure())
    $provider.DeleteVM = ({ param($Name) & $deleteVM -Provider $provider -Name $Name }.GetNewClosure())
    $provider.SetGamingGpuPercent = ({ param($Name,$Percent) & $setGamingGpuPercent -Provider $provider -Name $Name -Percent ([int]$Percent) }.GetNewClosure())
    $provider.ValidateGamingGuest = ({ param($Name,$Username,$Password,$Address)
            # The pre-console gate verifies GPU rendering. Hardware encoding
            # is required after Sunshine and the desktop are configured.
            & $validateGamingGuest -Provider $provider -Name $Name -GuestUsername $Username -GuestPassword $Password -GuestAddress $Address -RequireEncoder $false
        }.GetNewClosure())
    $provider.PrepareOmarchyBootstrap = ({ param($Name)
            Prepare-EpicVMOmarchyBootstrap -Provider $provider -VmName $Name
        }.GetNewClosure())
    $provider.WaitOmarchyGuestReady = ({ param($Name,$TimeoutSeconds,$PollMilliseconds,$ProbeUsername)
            Wait-EpicVMOmarchyGuestReady -Provider $provider -VmName $Name -TimeoutSeconds ([int]$TimeoutSeconds) -PollMilliseconds ([int]$PollMilliseconds) -ProbeUsername $ProbeUsername
        }.GetNewClosure())
    $provider.ConfigureOmarchyGuest = ({ param($Name,$Username,$Password)
            Invoke-EpicVMOmarchyGuestConfiguration -Provider $provider -VmName $Name -DesiredUser $Username -DesiredPassword $Password
        }.GetNewClosure())
    $provider.ValidateOmarchyGuest = ({ param($Name,$Username,$Address,$RequireSunshine)
            $require = if ($null -eq $RequireSunshine) { $true } else { [bool]$RequireSunshine }
            Invoke-EpicVMOmarchyGuestValidation -Provider $provider -VmName $Name -GuestUsername $Username -GuestAddress $Address -RequireSunshine $require
        }.GetNewClosure())
    $provider.CleanupOmarchyBootstrap = ({ param($Name,$Username,$Address)
            Invoke-EpicVMOmarchyBootstrapCleanup -Provider $provider -VmName $Name -GuestUsername $Username -GuestAddress $Address
        }.GetNewClosure())
    $provider.RemoveOmarchySeed = ({ param($Name)
            Remove-EpicVMOmarchySeed -Provider $provider -VmName $Name
        }.GetNewClosure())
    $provider.DiscardOmarchyBootstrap = ({ param($Name)
            Remove-EpicVMOmarchyBootstrapArtifacts -Provider $provider -VmName $Name
        }.GetNewClosure())
    $provider.ConfigureGuest = ({ param($Name,$Username,$Password)
            $result = Invoke-EpicVMGuestConfiguration -Provider $provider -Config $provider.Config -VmName $Name -DesiredUser $Username -DesiredPassword $Password
            return $result
        }.GetNewClosure())
    $provider.TestBootstrapGuest = ({ param($Name,$TimeoutSeconds,$PollMilliseconds)
            # Returns the classified failure code to the caller instead of discarding
            # it, so a credential mismatch is distinguishable from a slow boot.
            $classification=$null
            $ok=Wait-EpicVMGuestBootstrapReady -Provider $provider -Config $provider.Config -VmName $Name -TimeoutSeconds ([int]$TimeoutSeconds) -PollMilliseconds ([int]$PollMilliseconds) -Classification ([ref]$classification)
            return [ordered]@{ ok=[bool]$ok; failureCode=[string]$classification }
        }.GetNewClosure())
    $provider.ConfigureSunshine = ({ param($Name,$GuestUsername,$GuestPassword,$SunshineUsername,$SunshinePassword,$GuestAddress,$ManagementCheckpoint,$ManagementHandoffAlreadyVerified,$IsGaming,$IsOmarchy)
             if([bool]$IsOmarchy){
                 return Invoke-EpicVMOmarchySunshineConfiguration -Provider $provider -VmName $Name -GuestUsername $GuestUsername -GuestPassword $GuestPassword -SunshineUsername $SunshineUsername -SunshinePassword $SunshinePassword -GuestAddress $GuestAddress
             }
             if($null -ne $ManagementCheckpoint){
                # The checkpoint callback is invoked only after the verified
                # WinRM probe and before the credential-bearing Sunshine write.
                $result = Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $provider.Config -VmName $Name -GuestUsername $GuestUsername -GuestPassword $GuestPassword -SunshineUsername $SunshineUsername -SunshinePassword $SunshinePassword -GuestAddress $GuestAddress -ManagementCheckpoint $ManagementCheckpoint -ManagementHandoffAlreadyVerified ([bool]$ManagementHandoffAlreadyVerified) -IsGaming ([bool]$IsGaming)
            } else {
                $result = Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $provider.Config -VmName $Name -GuestUsername $GuestUsername -GuestPassword $GuestPassword -SunshineUsername $SunshineUsername -SunshinePassword $SunshinePassword -GuestAddress $GuestAddress -ManagementHandoffAlreadyVerified ([bool]$ManagementHandoffAlreadyVerified) -IsGaming ([bool]$IsGaming)
            }
            return $result
        }.GetNewClosure())
    $provider.EnrollTailscale = ({ param($Name,$Username,$Password)
            $result = Invoke-EpicVMTailscaleEnrollment -Provider $provider -Config $provider.Config -VmName $Name -Username $Username -Password $Password
            $provider.LastTailscaleEnrollment = $result
            return $result
        }.GetNewClosure())
    $provider.VerifyGuest = ({ param($Name,$GuestIp,$GuestUsername)
            $vm = @(& $provider.GetVMs | Where-Object {
                [string](Get-EpicVMHyperVValue -Object $_ -Name 'name' -Default '') -ceq $Name
            }) | Select-Object -First 1
            if ($null -eq $vm -or -not [bool](Get-EpicVMHyperVValue -Object $vm -Name 'managed' -Default $false)) { return $false }
            if ([string](Get-EpicVMHyperVValue -Object $vm -Name 'state' -Default '') -ine 'Running') { return $false }
            if ([string](Get-EpicVMHyperVValue -Object $vm -Name 'profile' -Default '') -ieq 'omarchy') {
                if ([string]::IsNullOrWhiteSpace($GuestUsername)) { return $false }
                try { return [bool](Invoke-EpicVMOmarchyGuestValidation -Provider $provider -VmName $Name -GuestUsername $GuestUsername -GuestAddress $GuestIp -RequireSunshine $true).ok } catch { return $false }
            }
            return Test-EpicVMGuestRdpReachability -Address ([string]$GuestIp)
        }.GetNewClosure())
    $provider.RevokeTailscale = ({ param($DeviceId) Revoke-EpicVMTailscaleDevice -Provider $provider -DeviceId $DeviceId }.GetNewClosure())
    $provider.ClearTailscaleStaleDevices = ({ param($VmName, $KeepDeviceId) Clear-EpicVMTailscaleStaleDevices -Provider $provider -VmName $VmName -KeepDeviceId $KeepDeviceId }.GetNewClosure())
    $provider.QuarantineVM = ({ param($Name) Move-EpicVMHyperVQuarantine -Provider $provider -Name $Name }.GetNewClosure())

    return $provider
}
