# EpicVM provisioning primitives. Persisted records are deliberately redacted;
# claim passwords and the one-time claim token exist only in process memory.

Set-StrictMode -Version Latest
$script:EpicVMProvisioningStates = @(
    'queued', 'cloning', 'booting', 'unclaimed', 'claim_in_progress',
    'guest_setup', 'network_setup', 'management_handoff', 'gaming_gpu_validation', 'omarchy_gpu_validation', 'streaming_setup', 'stream_validation', 'ready',
    'deprovisioning', 'quarantined', 'purged'
)

$script:EpicVMProvisioningStageOrder = @('claim', 'guest_setup', 'network_setup', 'management_handoff', 'gaming_gpu', 'omarchy_gpu', 'streaming_setup', 'stream_validation')
$script:EpicVMProvisioningFailureDetailCodes = @(
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
    'CAPTURE_DESKTOP_LOGON',
    'GAMING_GPU_DEVICE_MISSING', 'GAMING_GPU_DEVICE_ERROR',
    'GAMING_GPU_DRIVER_INJECTION', 'GAMING_GPU_DXDIAG',
    'GAMING_GPU_WEBGL', 'GAMING_GPU_FRAME', 'GAMING_GPU_ENCODER',
    'OMARCHY_GPU_DEVICE_MISSING', 'OMARCHY_SOFTWARE_RENDERER', 'OMARCHY_SUNSHINE_ENCODER'
)

function New-EpicVMProvisioningOperationId {
    return [Guid]::NewGuid().ToString('N')
}

function Get-EpicVMProvisioningFailureState {
    param([AllowNull()][string]$Code)
    $safeCode = [string]$Code
    if ([string]::IsNullOrWhiteSpace($safeCode)) { return 'setup_failed:unknown' }
    if ($safeCode -match '^setup_failed:') { return $safeCode }
    if ($safeCode -in @('guest_account_failed','guest_configuration_failed','rdp_verification_failed',
            'powershell_direct_failed','guest_account_readiness_failed','bootstrap_cleanup_failed',
            'bootstrap_cleanup_transport_failed','guest_setup_unavailable','bootstrap_credential_unavailable',
            'hyperv_vm_not_found','hyperv_access_denied','hyperv_vm_not_running','guest_heartbeat_unhealthy',
            'direct_service_disabled','direct_service_not_ready','direct_not_supported','direct_open_timeout',
            'direct_transport_error','guest_credentials_rejected','guest_operation_failed','direct_parameter_failure',
            'direct_module_failure','direct_runtime_failure',
            'omarchy_guest_validation_failed','omarchy_ssh_unavailable','omarchy_ssh_address_invalid',
            'omarchy_management_key_missing','omarchy_management_key_unavailable',
            'omarchy_bootstrap_password_missing','omarchy_bootstrap_password_unavailable',
            'omarchy_secret_store_unavailable','omarchy_seed_cleanup_failed','omarchy_bootstrap_cleanup_failed',
            'omarchy_guest_configuration_unavailable','omarchy_guest_configuration_failed','omarchy_bootstrap_prepare_failed')) { return 'setup_failed:guest' }
    if ($safeCode -in @('tailscale_enrollment_failed','tailscale_state_not_persisted','tailscale_auth_input_failed','tailscale_guest_command_failed','tailscale_system_task_timeout','tailscale_system_task_failed','tailscale_unattended_failed','tailscale_restart_failed','TailscaleEnrollmentFailed','tailscale_verification_failed','tailscale_unavailable','omarchy_bootstrap_not_ready','omarchy_network_recovery_failed',
            'network_setup_failed','network_recovery_failed','tailscale_unreachable')) { return 'setup_failed:network' }
    if ($safeCode -in @('management_handoff_failed','management_transport_failed','management_transport_unavailable','management_trusted_hosts_broad')) {
        return 'setup_failed:management'
    }
    if ($safeCode -in @('streaming_setup_failed','sunshine_setup_failed','sunshine_invalid_input',
            'sunshine_service_missing','sunshine_executable_missing','sunshine_version_mismatch',
            'sunshine_state_path_failed','sunshine_state_write_failed','sunshine_state_acl_failed',
            'sunshine_firewall_failed','sunshine_service_restart_failed','sunshine_listener_failed',
            'sunshine_verification_failed','powershell_direct_failed','SunshineConfigurationFailed',
                        'sunshine_setup_unavailable','console_verification_failed','console_evidence_incomplete','gaming_capture_configuration_required','guest_reverification_failed',
                        'gaming_capture_vdd_failed','gaming_audio_device_failed',
            'console_failed')) { return 'setup_failed:streaming' }
    if ($safeCode -in @('GpuUnavailable','GpuIdentityUnavailable','GpuIdentityAmbiguous','GpuQuotaUnavailable',
            'GpuAdapterCountInvalid','GpuIdentityMismatch','GpuAdapterVerificationFailed','DriverInjectionFailed',
                        'gaming_guest_validation_failed','gaming_guest_validation_unavailable','gaming_gpu_validation_failed','gaming_encoder_unavailable','gaming_webgl_unavailable')) { return 'setup_failed:gaming_gpu' }
    if ($safeCode -in @('omarchy_gpu_validation_failed','omarchy_encoder_unavailable','omarchy_sunshine_configuration_failed','omarchy_sunshine_failed')) {
        return 'setup_failed:omarchy_gpu'
    }
    if ($safeCode -in @('agent_restarted','reverification_failed')) { return 'setup_failed:agent_restart' }
    if ($safeCode -match '^legacy_') { return 'setup_failed:legacy_state_uncertain' }
    return 'setup_failed:unknown'
}

function Get-EpicVMProvisioningCompletedStages {
    param([AllowNull()][object]$Value)
    $seen = @{}
    $result = @()
    foreach ($stage in @($Value)) {
        $name = [string]$stage
        if ($script:EpicVMProvisioningStageOrder -contains $name -and -not $seen.ContainsKey($name)) {
            $seen[$name] = $true
            $result += $name
        }
    }
    return @($script:EpicVMProvisioningStageOrder | Where-Object { $seen.ContainsKey($_) })
}

function Test-EpicVMProvisioningEvidence {
    param([Parameter(Mandatory)][object]$Record,[Parameter(Mandatory)][string]$Stage)
    $completed = @(Get-EpicVMProvisioningCompletedStages -Value (Get-EpicVMProperty -Object $Record -Name 'completedStages' -Default @()))
    # A historical completed stage is not sufficient for the final console
    # validation gate. Re-evaluate the persisted automated route/transport
    # result and the profile-specific capture gate.
    if ($Stage -eq 'stream_validation') {
        if ([string](Get-EpicVMProperty -Object $Record -Name 'profile' -Default 'standard') -ieq 'gaming' -and
            -not [bool](Get-EpicVMProperty -Object $Record -Name 'gamingCaptureConfigured' -Default $false)) { return $false }
        return [bool](Get-EpicVMProperty -Object $Record -Name 'streamValidationVerified' -Default $false)
    }
    if ($completed -contains $Stage) { return $true }
    switch ($Stage) {
        'claim' { return [bool](Get-EpicVMProperty -Object $Record -Name 'claimConsumed' -Default (Get-EpicVMProperty -Object $Record -Name 'claimUsed' -Default $false)) }
        'guest_setup' { return [bool](Get-EpicVMProperty -Object $Record -Name 'guestSetupVerified' -Default $false) }
        'network_setup' {
            return (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'tailnetIp' -Default ''))) -and
                (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'tailnetDeviceId' -Default '')))
        }
        'management_handoff' {
            return (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'managementTransport' -Default ''))) -and
                (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'managementReadyAt' -Default '')))
        }
        'gaming_gpu' { return [bool](Get-EpicVMProperty -Object $Record -Name 'gamingGpuValidated' -Default $false) }
        'omarchy_gpu' { return [bool](Get-EpicVMProperty -Object $Record -Name 'omarchyGpuValidated' -Default $false) }
        'streaming_setup' { return -not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'consoleVerifiedAt' -Default '')) }
        default { return $false }
    }
}

function Test-EpicVMProvisioningReadyIdentity {
    param([Parameter(Mandatory)][object]$Record)
    $vmIdValid = $false
    try {
        [void][guid]::Parse([string](Get-EpicVMProperty -Object $Record -Name 'vmId' -Default ''))
        $vmIdValid = $true
    }
    catch { $vmIdValid = $false }
    $name = [string](Get-EpicVMProperty -Object $Record -Name 'name' -Default '')
    $route = [string](Get-EpicVMProperty -Object $Record -Name 'consoleRoutePrefix' -Default '')
    $expectedRoute = '/vm/' + $name + '/'
    $scopedRoutePattern = '^/vm/' + [regex]::Escape($name) + '--[a-z0-9][a-z0-9._-]{0,62}/$'
    $routeValid = ($route -ceq $expectedRoute) -or ($route -cmatch $scopedRoutePattern)
    return $vmIdValid -and
        ([string](Get-EpicVMProperty -Object $Record -Name 'tailnetIp' -Default '') -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$') -and
        (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'tailnetDeviceId' -Default ''))) -and
        (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'managementTransport' -Default ''))) -and
        (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'managementReadyAt' -Default ''))) -and
        (-not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Record -Name 'consoleVerifiedAt' -Default ''))) -and
        $routeValid
}

function ConvertTo-EpicVMCanonicalProvisioningState {
    param([Parameter(Mandatory)][object]$Record)
    $state = [string](Get-EpicVMProperty -Object $Record -Name 'state' -Default 'failed')
    if ($state -match '^setup_failed:(preclaim|guest|network|management|gaming_gpu|omarchy_gpu|streaming|agent_restart|legacy_state_uncertain|unknown)$') { return $state }
    if ($state -in @('queued','cloning','booting','unclaimed','claim_in_progress','guest_setup','network_setup','management_handoff','gaming_gpu_validation','omarchy_gpu_validation','streaming_setup','stream_validation','deprovisioning','quarantined','purged')) { return $state }
    if ($state -eq 'awaiting_claim') {
        $claimHash = [string](Get-EpicVMProperty -Object $Record -Name 'claimHash' -Default '')
        $claimUsed = [bool](Get-EpicVMProperty -Object $Record -Name 'claimConsumed' -Default (Get-EpicVMProperty -Object $Record -Name 'claimUsed' -Default $false))
        $expires = $null
        try { $expires = [DateTime]::Parse([string](Get-EpicVMProperty -Object $Record -Name 'claimExpires' -Default '')) } catch { }
        if (-not $claimUsed -and $claimHash -match '^[0-9a-fA-F]{64}$' -and $null -ne $expires -and $expires.ToUniversalTime() -gt [DateTime]::UtcNow) { return 'unclaimed' }
        return 'setup_failed:legacy_state_uncertain'
    }
    if ($state -eq 'configuring_guest') { return 'guest_setup' }
    if ($state -eq 'enrolling_tailscale') { return 'network_setup' }
    if ($state -eq 'awaiting_console') {
        if (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'network_setup') { return 'streaming_setup' }
        return 'setup_failed:legacy_state_uncertain'
    }
    if ($state -in @('console_failed','verifying')) { return 'setup_failed:streaming' }
    if ($state -eq 'ready') {
        if ((Test-EpicVMProvisioningEvidence -Record $Record -Stage 'claim') -and
            (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'guest_setup') -and
            (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'network_setup') -and
            (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'management_handoff') -and
            (([string](Get-EpicVMProperty -Object $Record -Name 'profile' -Default 'standard') -ne 'gaming') -or (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'gaming_gpu')) -and
            (([string](Get-EpicVMProperty -Object $Record -Name 'profile' -Default 'standard') -ne 'omarchy') -or (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'omarchy_gpu')) -and
            (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'streaming_setup') -and
            (Test-EpicVMProvisioningEvidence -Record $Record -Stage 'stream_validation') -and
            (Test-EpicVMProvisioningReadyIdentity -Record $Record)) { return 'ready' }
        return 'setup_failed:legacy_state_uncertain'
    }
    if ($state -eq 'failed') { return (Get-EpicVMProvisioningFailureState -Code ([string](Get-EpicVMProperty -Object $Record -Name 'errorCode' -Default 'legacy_unknown'))) }
    return 'setup_failed:legacy_state_uncertain'
}

function Copy-EpicVMProvisioningJobFields {
    param([Parameter(Mandatory)][object]$Source,[Parameter(Mandatory)][object]$Target)
    foreach ($name in @('id','name','profile','state','createdAt','updatedAt','templateVersion','vmId',
            'tailnetIp','tailnetDeviceId','managementTransport','managementReadyAt',
                        'consoleRoutePrefix','consoleVerifiedAt','streamValidationVerified',
                        'consoleFrameVerified','consoleFrameVerifiedAt','keyboardInputVerified','keyboardInputVerifiedAt',
                        'mouseInputVerified','mouseInputVerifiedAt','gamingCaptureConfigured','gamingCaptureAt','quarantineUntil',
            'errorCode','errorMessage','claimHash','claimExpires','claimUsed','claimConsumed',
            'operationId','completedStages','failureStage','failureDetailCode','guestSetupVerified','retryCount','lastAttemptCode',
            'cpuCount','memoryBytes','diskSizeBytes','gpuPartitionPercent','gpuDeviceIdentity','gamingGpuValidated','gamingValidationAt',
            'omarchyGpuValidated','omarchyValidationAt','guestUsername','guestOs')) {
        $value = Get-EpicVMProperty -Object $Source -Name $name -Default $null
        if ($null -ne $value -or $Target.PSObject.Properties.Name -contains $name) { $Target.$name = $value }
    }
    return $Target
}

function Test-EpicVMProvisioningCredentialInput {
    param([AllowNull()][string]$Username,[AllowNull()][string]$Password)
    if ([string]::IsNullOrWhiteSpace($Username) -or $Username -notmatch '^[A-Za-z][A-Za-z0-9._-]{2,31}$') { return $false }
    if ([string]::IsNullOrEmpty($Password) -or $Password.Length -gt 256) { return $false }
    return $true
}

function Get-EpicVMJobImmutableVmId {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job
    )
    $candidate = [string](Get-EpicVMProperty -Object $Job -Name 'vmId' -Default '')
    $parsed = [Guid]::Empty
    if ([Guid]::TryParse($candidate, [ref]$parsed)) { return $parsed.ToString() }
    # Older retained records stored the VM name in vmId.  Resolve that legacy
    # value once by name, but never pass the name to a Direct channel and never
    # treat it as an immutable identity.
    $name = [string](Get-EpicVMProperty -Object $Job -Name 'name' -Default '')
    try {
        $vm = @(& $State.Provider.GetVMs | Where-Object {
            [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $name
        } | Select-Object -First 1)
        if ($vm.Count -eq 1) {
            $resolved = [string](Get-EpicVMProperty -Object $vm[0] -Name 'id' -Default (Get-EpicVMProperty -Object $vm[0] -Name 'Id' -Default ''))
            if ([Guid]::TryParse($resolved, [ref]$parsed)) { return $parsed.ToString() }
        }
    }
    catch { }
    throw (New-EpicVMProvisioningError -Code 'hyperv_vm_not_found' -Message 'The immutable Hyper-V VM identity could not be resolved.' -Status 422)
}

function Invoke-EpicVMProvisioningStoreLocked {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $mutex = $null
    $held = $false
    try {
        $mutex = [Threading.Mutex]::new($false, 'Local\EpicVM-ProvisioningState')
        try { $held = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw (New-EpicVMProvisioningError -Code 'claim_store_busy' -Message 'The provisioning claim store is busy.' -Status 409) }
        return & $Action
    }
    finally {
        if ($held -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function New-EpicVMProvisioningError {
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Message,
        [int] $Status = 422,
        [AllowNull()] [string] $DetailCode = $null
    )
    $exception = [System.InvalidOperationException]::new($Message)
    $exception | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $Code -Force
    $exception | Add-Member -MemberType NoteProperty -Name HttpStatus -Value $Status -Force
    if ($DetailCode -and $script:EpicVMProvisioningFailureDetailCodes -contains $DetailCode) {
        $exception | Add-Member -MemberType NoteProperty -Name FailureDetailCode -Value $DetailCode -Force
    }
    return $exception
}

function Get-EpicVMProvisioningProfile {
    param([Parameter(Mandatory)] [string] $Profile)
    switch ($Profile.ToLowerInvariant()) {
        'standard' {
            return [ordered]@{
                profile = 'standard'
                cpuCount = 4
                memoryBytes = 8589934592
                diskSizeBytes = 103079215104
                gpu = $false
            }
        }
        'gaming' {
            return [ordered]@{
                profile = 'gaming'
                cpuCount = 6
                memoryBytes = 12884901888
                diskSizeBytes = 137438953472
                gpu = $true
                gpuPartition = '50%'
            }
        }
        'omarchy' {
            if (Get-Command -Name Get-EpicVMOmarchyProvisioningProfile -ErrorAction SilentlyContinue) {
                return Get-EpicVMOmarchyProvisioningProfile
            }
            return [ordered]@{
                profile = 'omarchy'
                cpuCount = 6
                memoryBytes = 12884901888
                diskSizeBytes = 137438953472
                gpu = $true
                gpuPartition = '50%'
                guestOs = 'Omarchy Linux'
                managementTransport = 'tailscale_ssh'
                console = 'Sunshine/Moonlight'
                experimental = $true
            }
        }
        default { throw 'Unsupported EpicVM profile.' }
    }
}

function ConvertTo-EpicVMProvisioningInt64 {
    param(
        [AllowNull()] [object] $Value,
        [Parameter(Mandatory)] [string] $FieldName
    )
    try {
        return [long][System.Convert]::ToInt64($Value)
    }
    catch {
        throw (New-EpicVMProvisioningError -Code 'invalid_gaming_spec' -Message ("The Gaming field '{0}' is invalid." -f $FieldName) -Status 400)
    }
}

function Get-EpicVMGamingProvisioningSpec {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Request
    )

    $profile = Get-EpicVMProvisioningProfile -Profile 'gaming'
    $cpuRaw = Get-EpicVMProperty -Object $Request -Name 'cpuCount' -Default $profile.cpuCount
    $memoryRaw = Get-EpicVMProperty -Object $Request -Name 'memoryBytes' -Default $null
    if ($null -eq $memoryRaw) {
        $memoryGiB = Get-EpicVMProperty -Object $Request -Name 'memoryGiB' -Default $null
        if ($null -ne $memoryGiB) { $memoryRaw = [decimal]$memoryGiB * 1GB } else { $memoryRaw = $profile.memoryBytes }
    }
    $diskRaw = Get-EpicVMProperty -Object $Request -Name 'diskSizeBytes' -Default $null
    if ($null -eq $diskRaw) {
        $diskGiB = Get-EpicVMProperty -Object $Request -Name 'diskSizeGiB' -Default $null
        if ($null -ne $diskGiB) { $diskRaw = [decimal]$diskGiB * 1GB } else { $diskRaw = $profile.diskSizeBytes }
    }
    $percentRaw = Get-EpicVMProperty -Object $Request -Name 'gpuPartitionPercent' -Default (Get-EpicVMProperty -Object $Request -Name 'GpuPartitionPercent' -Default (Get-EpicVMProperty -Object $Config -Name 'GamingGpuPartitionPercent' -Default 50))
    $cpu = ConvertTo-EpicVMProvisioningInt64 -Value $cpuRaw -FieldName 'cpuCount'
    $memory = ConvertTo-EpicVMProvisioningInt64 -Value $memoryRaw -FieldName 'memoryBytes'
    $disk = ConvertTo-EpicVMProvisioningInt64 -Value $diskRaw -FieldName 'diskSizeBytes'
    $percent = ConvertTo-EpicVMProvisioningInt64 -Value $percentRaw -FieldName 'gpuPartitionPercent'
    $minCpu = ConvertTo-EpicVMProvisioningInt64 -Value (Get-EpicVMProperty -Object $Config -Name 'MinCpuCount' -Default 1) -FieldName 'MinCpuCount'
    $maxCpu = ConvertTo-EpicVMProvisioningInt64 -Value (Get-EpicVMProperty -Object $Config -Name 'MaxCpuCount' -Default 16) -FieldName 'MaxCpuCount'
    $minMemory = ConvertTo-EpicVMProvisioningInt64 -Value (Get-EpicVMProperty -Object $Config -Name 'MinMemoryBytes' -Default 536870912) -FieldName 'MinMemoryBytes'
    $maxMemory = ConvertTo-EpicVMProvisioningInt64 -Value (Get-EpicVMProperty -Object $Config -Name 'MaxMemoryBytes' -Default 17179869184) -FieldName 'MaxMemoryBytes'
    $maxDisk = ConvertTo-EpicVMProvisioningInt64 -Value (Get-EpicVMProperty -Object $Config -Name 'MaxDiskSizeBytes' -Default 549755813888) -FieldName 'MaxDiskSizeBytes'
    if ($cpu -lt $minCpu -or $cpu -gt $maxCpu) { throw (New-EpicVMProvisioningError -Code 'invalid_gaming_spec' -Message 'Gaming CPU count is outside the configured limits.' -Status 400) }
    if ($memory -lt $minMemory -or $memory -gt $maxMemory) { throw (New-EpicVMProvisioningError -Code 'invalid_gaming_spec' -Message 'Gaming memory is outside the configured limits.' -Status 400) }
    if ($disk -le 0 -or $disk -gt $maxDisk) { throw (New-EpicVMProvisioningError -Code 'invalid_gaming_spec' -Message 'Gaming storage is outside the configured limits.' -Status 400) }
    if ($percent -lt 1 -or $percent -gt 100) { throw (New-EpicVMProvisioningError -Code 'invalid_gaming_spec' -Message 'Gaming GPU-P partition percentage must be between 1 and 100.' -Status 400) }
    $identity = [string](Get-EpicVMProperty -Object $Request -Name 'gpuDeviceIdentity' -Default (Get-EpicVMProperty -Object $Config -Name 'GamingGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF'))
    if ([string]::IsNullOrWhiteSpace($identity)) { throw (New-EpicVMProvisioningError -Code 'invalid_gaming_spec' -Message 'The Gaming GPU device identity is not configured.' -Status 400) }
    return [ordered]@{
        cpuCount = $cpu
        memoryBytes = $memory
        diskSizeBytes = $disk
        gpuPartitionPercent = $percent
        gpuDeviceIdentity = $identity
    }
}

function ConvertTo-EpicVMRedactedJob {
    param([Parameter(Mandatory)] [object] $Job)
    $safe = [ordered]@{}
    foreach ($name in @(
        'id', 'name', 'profile', 'state', 'createdAt', 'updatedAt', 'errorCode',
        'errorMessage', 'templateVersion', 'vmId', 'tailnetIp',
                'tailnetDeviceId', 'managementTransport', 'managementReadyAt',
                'consoleRoutePrefix', 'consoleVerifiedAt', 'streamValidationVerified',
                'consoleFrameVerified', 'consoleFrameVerifiedAt', 'keyboardInputVerified', 'keyboardInputVerifiedAt',
                'mouseInputVerified', 'mouseInputVerifiedAt', 'gamingCaptureConfigured', 'gamingCaptureAt',
                'quarantineUntil', 'operationId', 'claimConsumed', 'completedStages',
        'failureStage', 'failureDetailCode', 'guestSetupVerified', 'retryCount', 'lastAttemptCode',
        'cpuCount', 'memoryBytes', 'diskSizeBytes', 'gpuPartitionPercent', 'gpuDeviceIdentity',
        'gamingGpuValidated', 'gamingValidationAt', 'omarchyGpuValidated', 'omarchyValidationAt',
        'guestUsername', 'guestOs'
    )) {
        $value = Get-EpicVMProperty -Object $Job -Name $name -Default $null
        if ($null -ne $value) { $safe[$name] = $value }
    }
    return $safe
}

function New-EpicVMProvisioningJobObject {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Profile,
        [string] $State = 'queued'
    )
    $now = [DateTime]::UtcNow.ToString('o')
    return [pscustomobject]@{
        id = $Id
        name = $Name
        profile = $Profile
        state = $State
        createdAt = $now
        updatedAt = $now
        templateVersion = $null
        vmId = $null
        tailnetIp = $null
        tailnetDeviceId = $null
        managementTransport = $null
        managementReadyAt = $null
        consoleRoutePrefix = $null
        consoleVerifiedAt = $null
        streamValidationVerified = $false
        consoleFrameVerified = $false
        consoleFrameVerifiedAt = $null
        keyboardInputVerified = $false
        keyboardInputVerifiedAt = $null
        mouseInputVerified = $false
        mouseInputVerifiedAt = $null
        gamingCaptureConfigured = $false
        gamingCaptureAt = $null
        quarantineUntil = $null
        errorCode = $null
        errorMessage = $null
        failureDetailCode = $null
        operationId = $null
        claimConsumed = $false
        completedStages = @()
        failureStage = $null
        guestSetupVerified = $false
        retryCount = 0
        lastAttemptCode = $null
        cpuCount = $null
        memoryBytes = $null
        diskSizeBytes = $null
        gpuPartitionPercent = $null
        gpuDeviceIdentity = $null
        gamingGpuValidated = $false
        gamingValidationAt = $null
        omarchyGpuValidated = $false
        omarchyValidationAt = $null
        guestUsername = $null
        guestOs = $null
        # Only the one-way verifier is persisted. The claim itself never is.
        claimHash = $null
        claimExpires = $null
        claimUsed = $false
    }
}

function New-EpicVMProvisioningStore {
    param([Parameter(Mandatory)] [object] $Config)
    $path = [string](Get-EpicVMProperty -Object $Config -Name 'ProvisioningStatePath' -Default '')
    if ([string]::IsNullOrWhiteSpace($path)) {
        $root = [string](Get-EpicVMProperty -Object $Config -Name 'VmRoot' -Default 'E:\EpicVM\vms')
        $path = Join-Path $root '..\provisioning-jobs.json'
    }
    $store = [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($path)
        Jobs = @{}
        Deprovisioning = @{}
        Claims = @{}
        SyncRoot = [object]::new()
        NeedsSave = $false
    }
    if (-not (Test-Path -LiteralPath $store.Path -PathType Leaf)) { return $store }

    try {
        $raw = Get-Content -LiteralPath $store.Path -Raw -Encoding UTF8
        $records = @($raw | ConvertFrom-Json)
        foreach ($record in $records) {
            $kind = [string](Get-EpicVMProperty -Object $record -Name 'kind' -Default 'provisioning')
            $job = New-EpicVMProvisioningJobObject `
                -Id ([string](Get-EpicVMProperty -Object $record -Name 'id' -Default '')) `
                -Name ([string](Get-EpicVMProperty -Object $record -Name 'name' -Default '')) `
                -Profile ([string](Get-EpicVMProperty -Object $record -Name 'profile' -Default 'standard')) `
                -State ([string](Get-EpicVMProperty -Object $record -Name 'state' -Default 'failed'))
            foreach ($name in @(
                'createdAt', 'updatedAt', 'templateVersion', 'vmId', 'tailnetIp',
                'tailnetDeviceId', 'managementTransport', 'managementReadyAt',
                                'consoleRoutePrefix', 'consoleVerifiedAt', 'streamValidationVerified',
                                'consoleFrameVerified', 'consoleFrameVerifiedAt', 'keyboardInputVerified', 'keyboardInputVerifiedAt',
                                'mouseInputVerified', 'mouseInputVerifiedAt', 'gamingCaptureConfigured', 'gamingCaptureAt',
                                'quarantineUntil', 'errorCode', 'errorMessage',
                'claimHash', 'claimExpires', 'claimUsed', 'claimConsumed', 'operationId',
                'completedStages', 'failureStage', 'guestSetupVerified', 'retryCount', 'lastAttemptCode',
                'cpuCount','memoryBytes','diskSizeBytes','gpuPartitionPercent','gpuDeviceIdentity',
                'gamingGpuValidated','gamingValidationAt','omarchyGpuValidated','omarchyValidationAt',
                'guestUsername','guestOs'
            )) {
                $job.$name = Get-EpicVMProperty -Object $record -Name $name -Default $job.$name
            }
            $rawState = [string](Get-EpicVMProperty -Object $record -Name 'state' -Default 'failed')
            $canonical = ConvertTo-EpicVMCanonicalProvisioningState -Record $record
            $job.state = $canonical
            if ($canonical -ne $rawState) { $store.NeedsSave = $true }
            if ($canonical -eq 'setup_failed:legacy_state_uncertain') {
                $job.errorCode = 'legacy_state_uncertain'
                $job.errorMessage = 'Persisted provisioning checkpoints were insufficient or contradictory.'
                $job.failureStage = 'legacy_state_uncertain'
            }
            $job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value $job.completedStages)
            $job.claimConsumed = [bool](Get-EpicVMProperty -Object $record -Name 'claimConsumed' -Default (Get-EpicVMProperty -Object $record -Name 'claimUsed' -Default $false))
            $job.claimUsed = $job.claimConsumed
            if ([string]::IsNullOrWhiteSpace($job.id) -or -not (Test-EpicVMName $job.name)) { continue }
            if ($kind -eq 'deprovisioning') {
                $store.Deprovisioning[$job.id] = $job
                continue
            }
            $store.Jobs[$job.id] = $job
            $claimHashValid = [string]$job.claimHash -match '^[0-9a-fA-F]{64}$'
            if ($job.state -eq 'unclaimed' -and $claimHashValid -and -not [bool]$job.claimConsumed) {
                try {
                    [void][DateTime]::Parse($job.claimExpires)
                    $store.Claims[$job.id] = $job
                }
                catch {
                    $job.state = 'setup_failed:legacy_state_uncertain'
                    $job.errorCode = 'claim_state_invalid'
                    $job.errorMessage = 'The persisted claim state was invalid.'
                    $job.failureStage = 'legacy_state_uncertain'
                }
            }
        }
    }
    catch {
        throw (New-EpicVMProvisioningError -Code 'state_store_invalid' -Message 'The provisioning state store is invalid.' -Status 503)
    }
    return $store
}

function Save-EpicVMProvisioningStore {
    param([Parameter(Mandatory)] [object] $Store)
    $parent = Split-Path -Parent $Store.Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $records = @(
        $Store.Jobs.Values | ForEach-Object {
            $safe = ConvertTo-EpicVMRedactedJob -Job $_
            $safe.kind = 'provisioning'
            # A verifier is not a credential and is needed to survive restart;
            # the raw claim token is intentionally absent from this record.
            $safe.claimHash = [string](Get-EpicVMProperty -Object $_ -Name 'claimHash' -Default '')
            $safe.claimExpires = [string](Get-EpicVMProperty -Object $_ -Name 'claimExpires' -Default '')
            $safe.claimUsed = [bool](Get-EpicVMProperty -Object $_ -Name 'claimUsed' -Default $false)
            $safe.claimConsumed = [bool](Get-EpicVMProperty -Object $_ -Name 'claimConsumed' -Default $safe.claimUsed)
            $safe.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (Get-EpicVMProperty -Object $_ -Name 'completedStages' -Default @()))
            $safe
        }
        $Store.Deprovisioning.Values | ForEach-Object {
            $safe = ConvertTo-EpicVMRedactedJob -Job $_
            $safe.kind = 'deprovisioning'
            $safe
        }
    )
    $tmp = "$($Store.Path).tmp"
    try {
        $records | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tmp -Destination $Store.Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-EpicVMTemplateManifest {
    param([Parameter(Mandatory)] [object] $Config, [switch] $SkipContentHash)
    $manifestPath = [string](Get-EpicVMProperty -Object $Config -Name 'TemplateManifestPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($field in @('templateVersion', 'build', 'sha256', 'bootstrap', 'gpu', 'network', 'sysprep', 'immutable', 'fullCopy', 'diskType', 'imagePath', 'sunshine', 'sunshineVersion')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $manifest -Name $field -Default ''))) { return $false }
        }
        if (-not [bool]$manifest.immutable -or -not [bool]$manifest.fullCopy) { return $false }
        if ([string]$manifest.network -ne 'private-switch' -or [string]$manifest.diskType -ine 'Dynamic') { return $false }
        if ([string]$manifest.sysprep -notmatch '(?i)/generalize') { return $false }
        if ([string]$manifest.sunshine -ine 'installed') { return $false }
        $expectedSunshineVersion = [string](Get-EpicVMProperty -Object $Config -Name 'SunshineVersion' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($expectedSunshineVersion) -and [string]$manifest.sunshineVersion -cne $expectedSunshineVersion) { return $false }
        if ([string]$manifest.sha256 -notmatch '^[0-9a-fA-F]{64}$') { return $false }

        $manifestDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $manifestPath)).TrimEnd([char[]]@([char]92, [char]47))
        $imagePath = [IO.Path]::GetFullPath([string]$manifest.imagePath)
        if (-not ($imagePath.Equals($manifestDirectory, [StringComparison]::OrdinalIgnoreCase) -or
                $imagePath.StartsWith($manifestDirectory + '\', [StringComparison]::OrdinalIgnoreCase))) { return $false }
        $image = Get-Item -LiteralPath $imagePath -ErrorAction Stop
        if (($image.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        # Capability discovery runs frequently and must not hash a multi-GB
        # template on every request. The provisioning mutation path omits this
        # switch and performs the full SHA-256 gate immediately before cloning.
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

function Get-EpicVMProvisioningReadiness {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [AllowNull()] [object] $Provider = $null
    )

    # These are deliberately boolean-only diagnostics.  Paths, secret values,
    # tokens, and provider exception text never cross the capability boundary.
    $checks = [ordered]@{
        template = $false
        bootstrapCredential = $false
        tailscaleOAuthClient = $false
        tailscaleTailnet = $false
        tailscaleOAuthSecret = $false
        gpuPartitionable = $false
    }
    try { $checks.template = [bool](Test-EpicVMTemplateManifest -Config $Config -SkipContentHash) } catch { $checks.template = $false }
    foreach ($pathField in @('BootstrapCredentialPath', 'TailscaleOAuthSecretPath')) {
        $path = [string](Get-EpicVMProperty -Object $Config -Name $pathField -Default '')
        $exists = -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)
        if ($pathField -eq 'BootstrapCredentialPath') { $checks.bootstrapCredential = [bool]$exists }
        else { $checks.tailscaleOAuthSecret = [bool]$exists }
    }
    $checks.tailscaleOAuthClient = -not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Config -Name 'TailscaleOAuthClientId' -Default ''))
    $checks.tailscaleTailnet = -not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Config -Name 'TailscaleTailnet' -Default ''))
    if ($null -ne $Provider -and (Get-Command -Name Test-EpicVMHyperVGpuPartitionable -ErrorAction SilentlyContinue)) {
        try { $checks.gpuPartitionable = [bool](Test-EpicVMHyperVGpuPartitionable -Provider $Provider) } catch { $checks.gpuPartitionable = $false }
    }
    $standardKeys = @('template', 'bootstrapCredential', 'tailscaleOAuthClient', 'tailscaleTailnet', 'tailscaleOAuthSecret')
    $standard = $true
    foreach ($key in $standardKeys) { if (-not [bool]$checks[$key]) { $standard = $false } }
    $omarchyReadiness = [ordered]@{
        omarchy_provisioning = $false
        omarchyProvisioningChecks = [ordered]@{}
    }
    if (Get-Command -Name Get-EpicVMOmarchyProvisioningReadiness -ErrorAction SilentlyContinue) {
        try {
            $omarchyReadiness = Get-EpicVMOmarchyProvisioningReadiness -Config $Config -Provider $Provider
        }
        catch { }
    }
    return [ordered]@{
        provisioning = [bool]$standard
        gaming_provisioning = [bool]($standard -and [bool](Get-EpicVMProperty -Object $Config -Name 'EnableGamingProvisioning' -Default $false) -and [bool]$checks.gpuPartitionable)
        provisioningChecks = $checks
        omarchy_provisioning = [bool](Get-EpicVMProperty -Object $omarchyReadiness -Name 'omarchy_provisioning' -Default $false)
        omarchyProvisioningChecks = Get-EpicVMProperty -Object $omarchyReadiness -Name 'omarchyProvisioningChecks' -Default ([ordered]@{})
    }
}

function Test-EpicVMProvisioningPrerequisites {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [AllowNull()] [object] $Provider = $null,
        [switch] $Detailed
    )

    $readiness = Get-EpicVMProvisioningReadiness -Config $Config -Provider $Provider
    if ($Detailed) { return $readiness }
    return [bool]$readiness.provisioning
}

function ConvertTo-EpicVMClaimHash {
    param([Parameter(Mandatory)] [string] $Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($bytes)
        return (([BitConverter]::ToString($hash)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $algorithm.Dispose()
    }
}

function Test-EpicVMClaim {
    param([Parameter(Mandatory)] [object] $Job, [Parameter(Mandatory)] [string] $Claim)
    if ([string]::IsNullOrWhiteSpace([string]$Job.claimHash) -or [bool]$Job.claimUsed) { return $false }
    try { $expires = [DateTime]::Parse([string]$Job.claimExpires) } catch { return $false }
    if ([DateTime]::UtcNow -gt $expires.ToUniversalTime()) { return $false }
    $actual = [Text.Encoding]::UTF8.GetBytes((ConvertTo-EpicVMClaimHash -Value $Claim))
    $expected = [Text.Encoding]::UTF8.GetBytes(([string]$Job.claimHash).ToLowerInvariant())
    try {
        return $actual.Length -eq $expected.Length -and [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($actual, $expected)
    }
    finally {
        [Array]::Clear($actual, 0, $actual.Length)
        [Array]::Clear($expected, 0, $expected.Length)
    }
}

function Invoke-EpicVMProvisioningFailedCleanup {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Job)
    $isOmarchy = [string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ieq 'omarchy'
    $claimConsumed = [bool](Get-EpicVMProperty -Object $Job -Name 'claimConsumed' -Default $false)
    if ($isOmarchy -and -not $claimConsumed) {
        try {
            $discard = Get-EpicVMProperty -Object $State.Provider -Name 'DiscardOmarchyBootstrap' -Default $null
            if ($null -ne $discard) { & $discard $Job.name | Out-Null }
            else {
                $removeSeed = Get-EpicVMProperty -Object $State.Provider -Name 'RemoveOmarchySeed' -Default $null
                if ($null -ne $removeSeed) { & $removeSeed $Job.name | Out-Null }
            }
        }
        catch { }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Job.vmId)) { return }
    try {
        $vm = @(& $State.Provider.GetVMs | Where-Object { [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $Job.name }) | Select-Object -First 1
        if ($null -eq $vm) { return }
        $teardown = Get-EpicVMProperty -Object $State.Provider -Name 'TeardownConsole' -Default $null
        if ($null -ne $teardown) { & $teardown $Job.name $Job.name ([string]$Job.tailnetDeviceId) | Out-Null }
    }
    catch { }
    try {
        $revoke = Get-EpicVMProperty -Object $State.Provider -Name 'RevokeTailscale' -Default $null
        if ($null -ne $revoke) { & $revoke ([string]$Job.tailnetDeviceId) | Out-Null }
    }
    catch { }
    try {
        if ([string](Get-EpicVMProperty -Object $vm -Name 'state' -Default '') -ieq 'Running') { & $State.Provider.StopVM $Job.name | Out-Null }
        & $State.Provider.DeleteVM $Job.name | Out-Null
    }
    catch { return }
    try {
        $quarantine = Get-EpicVMProperty -Object $State.Provider -Name 'QuarantineVM' -Default $null
        if ($null -ne $quarantine) { & $quarantine $Job.name | Out-Null }
    }
    catch { }
}

function Invoke-EpicVMProvisioningRecovery {
    param([Parameter(Mandatory)] [object] $State)
    $changed = [bool](Get-EpicVMProperty -Object $State.Provisioning -Name 'NeedsSave' -Default $false)
    foreach ($job in @($State.Provisioning.Jobs.Values)) {
        $canonical = ConvertTo-EpicVMCanonicalProvisioningState -Record $job
        if ($canonical -ne [string]$job.state) {
            $job.state = $canonical
            $changed = $true
        }
        if ($job.state -eq 'streaming_setup') {
            $job.failureStage = $null
            $job.failureDetailCode = $null
            $job.errorCode = $null
            $job.errorMessage = $null
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $changed = $true
            continue
        }
        $restartStages = @(Get-EpicVMProvisioningCompletedStages -Value $job.completedStages)
        $restartRecoverable = $job.state -eq 'setup_failed:agent_restart' -and
            [string]$job.errorCode -eq 'agent_restarted' -and
            [bool](Get-EpicVMProperty -Object $job -Name 'claimConsumed' -Default $false) -and
            [bool](Get-EpicVMProperty -Object $job -Name 'claimUsed' -Default $false) -and
            $restartStages -contains 'claim' -and $restartStages -contains 'guest_setup' -and
            $restartStages -contains 'network_setup' -and $restartStages -contains 'management_handoff' -and
            (([string](Get-EpicVMProperty -Object $job -Name 'profile' -Default 'standard') -ine 'gaming') -or $restartStages -contains 'gaming_gpu') -and
            (([string](Get-EpicVMProperty -Object $job -Name 'profile' -Default 'standard') -ine 'omarchy') -or $restartStages -contains 'omarchy_gpu') -and
            [string](Get-EpicVMProperty -Object $job -Name 'tailnetIp' -Default '') -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$'
        if ($restartRecoverable) {
            $job.state = 'streaming_setup'
            $job.failureStage = $null
            $job.failureDetailCode = $null
            $job.errorCode = $null
            $job.errorMessage = $null
            $job.lastAttemptCode = 'agent_restart_recovery'
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $changed = $true
            continue
        }
        $readyStages = @(Get-EpicVMProvisioningCompletedStages -Value $job.completedStages)
        $readyCheckpoint =
            [bool](Get-EpicVMProperty -Object $job -Name 'claimConsumed' -Default $false) -and
            [bool](Get-EpicVMProperty -Object $job -Name 'claimUsed' -Default $false) -and
            $readyStages -contains 'claim' -and $readyStages -contains 'guest_setup' -and
            $readyStages -contains 'network_setup' -and $readyStages -contains 'management_handoff' -and
            $readyStages -contains 'streaming_setup' -and $readyStages -contains 'stream_validation' -and
            [bool](Get-EpicVMProperty -Object $job -Name 'streamValidationVerified' -Default $false) -and
            (([string](Get-EpicVMProperty -Object $job -Name 'profile' -Default 'standard') -ine 'gaming') -or [bool](Get-EpicVMProperty -Object $job -Name 'gamingCaptureConfigured' -Default $false)) -and
            (([string](Get-EpicVMProperty -Object $job -Name 'profile' -Default 'standard') -ine 'omarchy') -or [bool](Get-EpicVMProperty -Object $job -Name 'omarchyGpuValidated' -Default $false)) -and
            (Test-EpicVMProvisioningReadyIdentity -Record $job)
        $readyVmRunning = $false
        try {
            $readyVm = @(& $State.Provider.GetVMs | Where-Object {
                [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq [string]$job.name
            }) | Select-Object -First 1
            $readyVmRunning = $null -ne $readyVm -and
                [bool](Get-EpicVMProperty -Object $readyVm -Name 'managed' -Default $false) -and
                [string](Get-EpicVMProperty -Object $readyVm -Name 'state' -Default '') -ieq 'Running'
        }
        catch { $readyVmRunning = $false }
        $retainedReadyRecovery = $job.state -eq 'setup_failed:agent_restart' -and
            [string]$job.errorCode -eq 'reverification_failed' -and $readyCheckpoint -and $readyVmRunning
        if ($retainedReadyRecovery) {
            $job.state = 'ready'
            $job.failureStage = $null
            $job.failureDetailCode = $null
            $job.errorCode = $null
            $job.errorMessage = $null
            $job.lastAttemptCode = 'agent_restart_recovery'
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $changed = $true
            continue
        }
        if ($job.state -eq 'queued') {
            $job.state = 'setup_failed:preclaim'
            $job.errorCode = 'agent_restarted'
            $job.failureStage = 'preclaim'
            $job.errorMessage = 'The worker restarted before cloning began. This job can be retried.'
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $changed = $true
            continue
        }
        if ($job.state -in @('cloning', 'booting', 'claim_in_progress', 'guest_setup', 'network_setup', 'management_handoff', 'gaming_gpu_validation', 'omarchy_gpu_validation', 'stream_validation')) {
            $job.state = 'setup_failed:agent_restart'
            $job.errorCode = 'agent_restarted'
            $job.failureStage = 'agent_restart'
            $job.errorMessage = 'The worker restarted before verification completed.'
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $changed = $true
            continue
        }
        if ($job.state -eq 'ready') {
            if (-not ($readyCheckpoint -and $readyVmRunning)) {
                $verify = Get-EpicVMProperty -Object $State.Provider -Name 'VerifyGuest' -Default $null
                $verified = $false
                if ($null -ne $verify) {
                    try {
                        if ([string]$job.profile -ieq 'omarchy') { $verified = [bool](& $verify $job.name $job.tailnetIp ([string]$job.guestUsername)) }
                        else { $verified = [bool](& $verify $job.name $job.tailnetIp) }
                    } catch { $verified = $false }
                }
                if (-not $verified) {
                    $job.state = 'setup_failed:agent_restart'
                    $job.errorCode = 'reverification_failed'
                    $job.failureStage = 'agent_restart'
                    $job.errorMessage = 'Readiness verification is required after agent restart.'
                }
            }
            if ($job.state -eq 'ready') {
                $job.failureStage = $null
                $job.failureDetailCode = $null
                $job.lastAttemptCode = $null
                $job.errorCode = $null
                $job.errorMessage = $null
            }
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $changed = $true
        }
    }
    if ($changed) {
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        if ($State.Provisioning.PSObject.Properties.Name -contains 'NeedsSave') { $State.Provisioning.NeedsSave = $false }
    }
}

function Test-EpicVMProvisioningJobRetryable {
    param([AllowNull()] [object] $Job)
    if ($null -eq $Job) { return $false }
    $state = [string](Get-EpicVMProperty -Object $Job -Name 'state' -Default '')
    $failureStage = [string](Get-EpicVMProperty -Object $Job -Name 'failureStage' -Default '')
    $claimConsumed = [bool](Get-EpicVMProperty -Object $Job -Name 'claimConsumed' -Default $false)
    $claimUsed = [bool](Get-EpicVMProperty -Object $Job -Name 'claimUsed' -Default $false)
    return ($state -like 'setup_failed:*' -and -not $claimConsumed -and -not $claimUsed -and $failureStage -eq 'preclaim')
}

function New-EpicVMProvisioningJob {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Request)
    $name = [string](Get-EpicVMProperty -Object $Request -Name 'name' -Default '')
    $profileName = [string](Get-EpicVMProperty -Object $Request -Name 'profile' -Default 'standard')
    if (-not (Test-EpicVMName $name)) { throw (New-EpicVMProvisioningError -Code 'invalid_name' -Message 'The VM name is invalid.' -Status 400) }
    try { $profile = Get-EpicVMProvisioningProfile -Profile $profileName }
    catch { throw (New-EpicVMProvisioningError -Code 'invalid_profile' -Message 'The VM profile is invalid.' -Status 400) }
    if ($profile.profile -eq 'gaming' -and -not [bool](Get-EpicVMProperty -Object $State.Config -Name 'EnableGamingProvisioning' -Default $false)) {
        throw (New-EpicVMProvisioningError -Code 'gaming_not_validated' -Message 'Gaming provisioning remains disabled until a GPU-P pilot passes.' -Status 409)
    }

    if ($profile.profile -eq 'omarchy') {
        $readiness = Get-EpicVMProvisioningReadiness -Config $State.Config -Provider $State.Provider
        if (-not [bool](Get-EpicVMProperty -Object $readiness -Name 'omarchy_provisioning' -Default $false)) {
            throw (New-EpicVMProvisioningError -Code 'omarchy_not_validated' -Message 'Omarchy provisioning remains disabled until the pinned image, AMD GPU-P path, and accelerated guest pilot are verified.' -Status 409)
        }
        if (-not (Get-Command -Name Get-EpicVMOmarchyProvisioningSpec -ErrorAction SilentlyContinue)) {
            throw (New-EpicVMProvisioningError -Code 'omarchy_provisioning_unavailable' -Message 'The Omarchy provisioning profile is unavailable.' -Status 503)
        }
        $omarchySpec = Get-EpicVMOmarchyProvisioningSpec -Config $State.Config -Request $Request
        $createOmarchy = {
            $freshStore = New-EpicVMProvisioningStore -Config $State.Config
            $existingJob = @($freshStore.Jobs.Values | Where-Object {
                [string]$_.name -ceq $name -and -not (Test-EpicVMProvisioningJobRetryable -Job $_)
            }) | Select-Object -First 1
            if ($null -ne $existingJob) { throw (New-EpicVMProvisioningError -Code 'conflict' -Message 'The requested VM name already exists.' -Status 409) }
            $existing = @(& $State.Provider.GetVMs | Where-Object {
                [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $name
            })
            if ($existing.Count -gt 0) { throw (New-EpicVMProvisioningError -Code 'conflict' -Message 'The requested VM name already exists.' -Status 409) }

            $job = New-EpicVMProvisioningJobObject -Id ([guid]::NewGuid().ToString('N')) -Name $name -Profile $profile.profile
            $job.cpuCount = [long]$omarchySpec.cpuCount
            $job.memoryBytes = [long]$omarchySpec.memoryBytes
            $job.diskSizeBytes = [long]$omarchySpec.diskSizeBytes
            $job.gpuPartitionPercent = [int]$omarchySpec.gpuPartitionPercent
            $job.gpuDeviceIdentity = [string]$omarchySpec.gpuDeviceIdentity
            $job.guestOs = [string]$omarchySpec.guestOs
            $freshStore.Jobs[$job.id] = $job
            Save-EpicVMProvisioningStore -Store $freshStore
            $State.Provisioning = $freshStore
            return $job
        }
        return Invoke-EpicVMProvisioningStoreLocked -Action $createOmarchy
    }

    if ($profile.profile -eq 'gaming') {
        $gamingSpec = Get-EpicVMGamingProvisioningSpec -Config $State.Config -Request $Request
        $createGaming = {
            $freshStore = New-EpicVMProvisioningStore -Config $State.Config
            $existingJob = @($freshStore.Jobs.Values | Where-Object {
                [string]$_.name -ceq $name -and -not (Test-EpicVMProvisioningJobRetryable -Job $_)
            }) | Select-Object -First 1
            if ($null -ne $existingJob) { throw (New-EpicVMProvisioningError -Code 'conflict' -Message 'The requested VM name already exists.' -Status 409) }
            $inventory = @(& $State.Provider.GetVMs)
            $existing = @($inventory | Where-Object { [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $name })
            if ($existing.Count -gt 0) { throw (New-EpicVMProvisioningError -Code 'conflict' -Message 'The requested VM name already exists.' -Status 409) }

            # Keep the clone reservation, but a stopped retained guest awaiting
            # a console does not consume GPU capacity. Match immutable IDs so
            # historical jobs for reused names cannot block a new VM.
            $activeStates = @('queued','cloning','booting','unclaimed','claim_in_progress','guest_setup','network_setup','management_handoff','gaming_gpu_validation','streaming_setup','stream_validation')
            $activeJobs = @($freshStore.Jobs.Values | Where-Object {
                $candidateJob = $_
                $jobState = [string](Get-EpicVMProperty -Object $candidateJob -Name 'state' -Default '')
                $matchingVm = @($inventory | Where-Object {
                    [string](Get-EpicVMProperty -Object $_ -Name 'id' -Default '') -ieq [string](Get-EpicVMProperty -Object $candidateJob -Name 'vmId' -Default 'missing') -and
                    [string](Get-EpicVMProperty -Object $_ -Name 'state' -Default '') -notin @('Off','Saved')
                })
                [string](Get-EpicVMProperty -Object $candidateJob -Name 'profile' -Default 'standard') -ieq 'gaming' -and
                $activeStates -contains $jobState -and ($jobState -in @('queued','cloning') -or $matchingVm.Count -gt 0)
            })
            if ($activeJobs.Count -gt 0) {
                throw (New-EpicVMProvisioningError -Code 'gaming_capacity' -Message 'A Gaming VM is already being provisioned or is awaiting console completion.' -Status 409)
            }
            $job = New-EpicVMProvisioningJobObject -Id ([guid]::NewGuid().ToString('N')) -Name $name -Profile $profile.profile
            $job.cpuCount = [long]$gamingSpec.cpuCount
            $job.memoryBytes = [long]$gamingSpec.memoryBytes
            $job.diskSizeBytes = [long]$gamingSpec.diskSizeBytes
            $job.gpuPartitionPercent = [int]$gamingSpec.gpuPartitionPercent
            $job.gpuDeviceIdentity = [string]$gamingSpec.gpuDeviceIdentity
            $freshStore.Jobs[$job.id] = $job
            Save-EpicVMProvisioningStore -Store $freshStore
            $State.Provisioning = $freshStore
            return $job
        }
        return Invoke-EpicVMProvisioningStoreLocked -Action $createGaming
    }

    $existingJob = @($State.Provisioning.Jobs.Values | Where-Object {
        [string]$_.name -ceq $name -and -not (Test-EpicVMProvisioningJobRetryable -Job $_)
    }) | Select-Object -First 1
    if ($null -ne $existingJob) { throw (New-EpicVMProvisioningError -Code 'conflict' -Message 'The requested VM name already exists.' -Status 409) }
    $existing = @(& $State.Provider.GetVMs | Where-Object {
        [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $name
    })
    if ($existing.Count -gt 0) { throw (New-EpicVMProvisioningError -Code 'conflict' -Message 'The requested VM name already exists.' -Status 409) }

    $job = New-EpicVMProvisioningJobObject -Id ([guid]::NewGuid().ToString('N')) -Name $name -Profile $profile.profile
    $State.Provisioning.Jobs[$job.id] = $job
    Save-EpicVMProvisioningStore -Store $State.Provisioning
    return $job
}

function Invoke-EpicVMProvisioningGamingValidation {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password
    )

    if ([string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ine 'gaming') {
        return $Job
    }

    $validate = Get-EpicVMProperty -Object $State.Provider -Name 'ValidateGamingGuest' -Default $null
    if ($null -eq $validate) {
        throw (New-EpicVMProvisioningError -Code 'gaming_guest_validation_unavailable' -Message 'The Gaming GPU guest validation gate is unavailable.' -Status 503)
    }

    $Job.state = 'gaming_gpu_validation'
    $Job.failureStage = $null
    $Job.failureDetailCode = $null
    $Job.errorCode = $null
    $Job.errorMessage = $null
    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-EpicVMProvisioningStore -Store $State.Provisioning

    try {
        $result = & $validate $Job.name $Username $Password ([string](Get-EpicVMProperty -Object $Job -Name 'tailnetIp' -Default ''))
        if ($null -eq $result -or -not [bool](Get-EpicVMProperty -Object $result -Name 'ok' -Default $false)) {
            $detail = [string](Get-EpicVMProperty -Object $result -Name 'failureDetailCode' -Default 'GAMING_GPU_DEVICE_ERROR')
            if ($script:EpicVMProvisioningFailureDetailCodes -notcontains $detail) { $detail = 'GAMING_GPU_DEVICE_ERROR' }
            throw (New-EpicVMProvisioningError -Code 'gaming_gpu_validation_failed' -Message 'The Gaming guest GPU validation gate failed.' -Status 422 -DetailCode $detail)
        }

        $Job.gamingGpuValidated = $true
        $Job.gamingValidationAt = [DateTime]::UtcNow.ToString('o')
        $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('gaming_gpu')))
        $Job.state = 'streaming_setup'
        $Job.failureStage = $null
        $Job.failureDetailCode = $null
        $Job.errorCode = $null
        $Job.errorMessage = $null
        $Job.lastAttemptCode = $null
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        return $Job
    }
    catch {
        $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'gaming_guest_validation_failed')
        if ($code -notin @('gaming_guest_validation_unavailable','gaming_guest_validation_failed','gaming_gpu_validation_failed','gaming_encoder_unavailable','gaming_webgl_unavailable')) {
            $code = 'gaming_guest_validation_failed'
        }
        $Job.state = Get-EpicVMProvisioningFailureState -Code $code
        $Job.failureStage = 'gaming_gpu'
        $Job.errorCode = $code
        $detail = [string](Get-EpicVMProperty -Object $_.Exception -Name 'FailureDetailCode' -Default '')
        if ($script:EpicVMProvisioningFailureDetailCodes -contains $detail) { $Job.failureDetailCode = $detail } else { $Job.failureDetailCode = $null }
        $Job.lastAttemptCode = $code
        $Job.errorMessage = 'Gaming GPU validation stopped safely; the owned VM was retained for diagnosis.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw
    }
    finally {
        $Username = $null
        $Password = $null
    }
}

function Start-EpicVMProvisioningJob {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Job)
    if ([string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ieq 'omarchy') {
        return Start-EpicVMOmarchyProvisioningJob -State $State -Job $Job
    }
    try {
        if ($Job.state -ne 'queued') { return $null }
        if (-not (Test-EpicVMTemplateManifest -Config $State.Config)) {
            throw (New-EpicVMProvisioningError -Code 'template_invalid' -Message 'The EpicVM template manifest is missing or invalid.' -Status 503)
        }
        $Job.state = 'cloning'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        $profile = Get-EpicVMProvisioningProfile -Profile $Job.profile
        $manifestPath = [string](Get-EpicVMProperty -Object $State.Config -Name 'TemplateManifestPath' -Default '')
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Job.templateVersion = [string]$manifest.templateVersion
        # Get-EpicVMProperty returns an existing property's value even when
        # that value is $null, so standard-profile jobs (whose spec fields are
        # created null) would cast [long]$null = 0 and fail CreateVM
        # validation. Coalesce null/empty to the profile defaults explicitly.
        $cpuRaw = Get-EpicVMProperty -Object $Job -Name 'cpuCount' -Default $null
        if ($null -eq $cpuRaw -or [string]$cpuRaw -eq '') { $cpuRaw = $profile.cpuCount }
        $memoryRaw = Get-EpicVMProperty -Object $Job -Name 'memoryBytes' -Default $null
        if ($null -eq $memoryRaw -or [string]$memoryRaw -eq '') { $memoryRaw = $profile.memoryBytes }
        $diskRaw = Get-EpicVMProperty -Object $Job -Name 'diskSizeBytes' -Default $null
        if ($null -eq $diskRaw -or [string]$diskRaw -eq '') { $diskRaw = $profile.diskSizeBytes }
        $cpuCount = [long]$cpuRaw
        $memoryBytes = [long]$memoryRaw
        $diskSizeBytes = [long]$diskRaw
        $createRequest = [ordered]@{
            name = $Job.name; profile = $profile.profile; cpuCount = $cpuCount
            memoryBytes = $memoryBytes; diskSizeBytes = $diskSizeBytes
            fullCopy = $true; templateRequired = $true; templateDiskPath = [string]$manifest.imagePath
        }
        if ($profile.profile -eq 'gaming') {
            $createRequest.gpu = $true
            $createRequest.gpuPartitionPercent = [int](Get-EpicVMProperty -Object $Job -Name 'gpuPartitionPercent' -Default 50)
            $createRequest.gpuDeviceIdentity = [string](Get-EpicVMProperty -Object $Job -Name 'gpuDeviceIdentity' -Default (Get-EpicVMProperty -Object $State.Config -Name 'GamingGpuDeviceIdentity' -Default 'VEN_1002&DEV_73BF'))
        }
        $vm = & $State.Provider.CreateVM $createRequest
        $Job.vmId = Get-EpicVMJobImmutableVmId -State $State -Job ([pscustomobject]@{ name = $Job.name; vmId = [string](Get-EpicVMProperty -Object $vm -Name 'id' -Default (Get-EpicVMProperty -Object $vm -Name 'Id' -Default '')) })
        $Job.state = 'booting'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        & $State.Provider.StartVM $Job.name | Out-Null

        # Do not issue a one-time claim while the clone is still in OOBE or
        # before PowerShell Direct can authenticate with the machine bootstrap
        # account.  This is a read-only guest probe; it never receives or
        # persists the operator's claim credentials.
        $bootstrapReady = Get-EpicVMProperty -Object $State.Provider -Name 'TestBootstrapGuest' -Default $null
        if($null -eq $bootstrapReady){
            throw (New-EpicVMProvisioningError -Code 'bootstrap_readiness_unavailable' -Message 'The guest bootstrap readiness gate is unavailable.' -Status 503)
        }
        $ready=$false
        $bootstrapFailureCode=''
        # A generalized Windows 11 clone can spend several minutes completing
        # its first boot before PowerShell Direct accepts the bootstrap account.
        # Keep each transport probe bounded, but allow one bounded 10-minute
        # readiness window before failing closed.
        #
        # The provider returns { ok; failureCode }. Preserve that code so a rejected
        # bootstrap credential is reported as a credential fault instead of being
        # flattened into the generic not-ready message. A template whose baked
        # EpicVMBootstrap password no longer matches the host credential store is a
        # credential fault and must be legible from the job record.
        try {
            $probe=& $bootstrapReady $Job.name 600 1000
            $ready=[bool](Get-EpicVMProperty -Object $probe -Name 'ok' -Default $false)
            if(-not $ready){ $bootstrapFailureCode=[string](Get-EpicVMProperty -Object $probe -Name 'failureCode' -Default '') }
        }
        catch { $ready=$false; $bootstrapFailureCode='bootstrap_probe_failed' }
        if(-not $ready){
            $Job.lastAttemptCode=$(if([string]::IsNullOrWhiteSpace($bootstrapFailureCode)){'guest_bootstrap_not_ready'}else{[string]$bootstrapFailureCode})
            $code=$(if([string]::IsNullOrWhiteSpace($bootstrapFailureCode)){'guest_bootstrap_not_ready'}else{[string]$bootstrapFailureCode})
            $message=$(if($code -eq 'guest_credentials_rejected'){
                'The guest rejected the stored bootstrap credential. The published template and the host credential store are out of sync.'
            }elseif($code -eq 'bootstrap_credential_unavailable'){
                'The stored bootstrap credential could not be opened on the host.'
            }else{
                'The cloned guest did not become ready for secure setup.'
            })
            throw (New-EpicVMProvisioningError -Code $code -Message $message -Status 503)
        }

        $claim = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
        $Job.claimHash = ConvertTo-EpicVMClaimHash -Value $claim
        $Job.claimExpires = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
        $Job.claimUsed = $false
        $State.Provisioning.Claims[$Job.id] = $Job
        $Job.state = 'unclaimed'
        $Job.claimConsumed = $false
        $Job.completedStages = @()
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        return $claim
    }
    catch {
        Invoke-EpicVMProvisioningFailedCleanup -State $State -Job $Job
        $Job.errorCode = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'provisioning_failed')
        $Job.state = 'setup_failed:preclaim'
        $Job.failureStage = 'preclaim'
        $Job.lastAttemptCode = $Job.errorCode
        $Job.errorMessage = 'Provisioning stopped before guest claim; no claim was consumed.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw
    }
}

function Invoke-EpicVMProvisioningClaimCommit {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [string] $Claim
    )
    return Invoke-EpicVMProvisioningStoreLocked -Action {
        $diskStore = New-EpicVMProvisioningStore -Config $State.Config
        $persisted = @($diskStore.Jobs.Values | Where-Object { [string]$_.id -ceq [string]$Job.id } | Select-Object -First 1)
        if ($persisted.Count -gt 0) { Copy-EpicVMProvisioningJobFields -Source $persisted[0] -Target $Job | Out-Null }
        $canonical = ConvertTo-EpicVMCanonicalProvisioningState -Record $Job
        $Job.state = $canonical
        if ($canonical -ne 'unclaimed') {
            if ($canonical -eq 'claim_in_progress') { throw (New-EpicVMProvisioningError -Code 'claim_in_progress' -Message 'Another request already owns this claim.' -Status 409) }
            throw (New-EpicVMProvisioningError -Code 'claim_not_allowed' -Message 'The VM is not awaiting a claim.' -Status 409)
        }
        if (-not (Test-EpicVMClaim -Job $Job -Claim $Claim)) {
            throw (New-EpicVMProvisioningError -Code 'invalid_claim' -Message 'The claim is invalid or expired.' -Status 409)
        }
        $previous = [ordered]@{
            state = $Job.state; claimHash = $Job.claimHash; claimExpires = $Job.claimExpires
            claimUsed = $Job.claimUsed; claimConsumed = $Job.claimConsumed; operationId = $Job.operationId
            completedStages = @($Job.completedStages)
        }
        try {
            $Job.operationId = New-EpicVMProvisioningOperationId
            $Job.claimHash = $null
            $Job.claimExpires = $null
            $Job.claimUsed = $true
            $Job.claimConsumed = $true
            $Job.completedStages = @('claim')
            $Job.state = 'claim_in_progress'
            $Job.failureStage = $null
            $Job.failureDetailCode = $null
            $Job.errorCode = $null
            $Job.errorMessage = $null
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $State.Provisioning.Jobs[$Job.id] = $Job
            [void]$State.Provisioning.Claims.Remove($Job.id)
            Save-EpicVMProvisioningStore -Store $State.Provisioning
        }
        catch {
            $Job.state = $previous.state; $Job.claimHash = $previous.claimHash; $Job.claimExpires = $previous.claimExpires
            $Job.claimUsed = $previous.claimUsed; $Job.claimConsumed = $previous.claimConsumed; $Job.operationId = $previous.operationId
            $Job.completedStages = $previous.completedStages
            $State.Provisioning.Claims[$Job.id] = $Job
            throw (New-EpicVMProvisioningError -Code 'claim_atomic_commit_failed' -Message 'The claim could not be committed safely.' -Status 503)
        }
        return [ordered]@{ operationId = [string]$Job.operationId }
    }
}

function Invoke-EpicVMProvisioningClaim {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Job, [Parameter(Mandatory)] [object] $Request)
    $claim = [string](Get-EpicVMProperty -Object $Request -Name 'claimToken' -Default '')
    $username = [string](Get-EpicVMProperty -Object $Request -Name 'username' -Default '')
    $password = [string](Get-EpicVMProperty -Object $Request -Name 'password' -Default '')
    if (-not (Test-EpicVMProvisioningCredentialInput -Username $username -Password $password)) {
        throw (New-EpicVMProvisioningError -Code 'invalid_credential_input' -Message 'The credential input is empty or does not meet the request policy.' -Status 400)
    }
    if ([string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ieq 'omarchy') {
        return Invoke-EpicVMProvisioningOmarchyClaim -State $State -Job $Job -Claim $claim -Username $username -Password $password
    }
    $configure = Get-EpicVMProperty -Object $State.Provider -Name 'ConfigureGuest' -Default $null
    if ($null -eq $configure) { throw (New-EpicVMProvisioningError -Code 'guest_configuration_unavailable' -Message 'PowerShell Direct guest configuration is unavailable.' -Status 503) }

    $operation = Invoke-EpicVMProvisioningClaimCommit -State $State -Job $Job -Claim $claim

    try {
        $Job.state = 'guest_setup'; $Job.updatedAt = [DateTime]::UtcNow.ToString('o'); Save-EpicVMProvisioningStore -Store $State.Provisioning
        $guestResult = & $configure $Job.name $username $password
        if ($null -eq $guestResult -or -not [bool](Get-EpicVMProperty -Object $guestResult -Name 'ok' -Default $false)) {
            $detail = [string](Get-EpicVMProperty -Object $guestResult -Name 'failureDetailCode' -Default 'account_verification_failed')
            if ($script:EpicVMProvisioningFailureDetailCodes -notcontains $detail) { $detail = 'account_verification_failed' }
            throw (New-EpicVMProvisioningError -Code 'guest_account_failed' -Message 'The guest account setup did not verify.' -Status 422 -DetailCode $detail)
        }
        $Job.guestSetupVerified = $true
        $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('guest_setup')))
        $Job.state = 'network_setup'; $Job.updatedAt = [DateTime]::UtcNow.ToString('o'); Save-EpicVMProvisioningStore -Store $State.Provisioning
        $enroll = Get-EpicVMProperty -Object $State.Provider -Name 'EnrollTailscale' -Default $null
        if ($null -eq $enroll) { throw (New-EpicVMProvisioningError -Code 'tailscale_unavailable' -Message 'Tailscale enrollment is unavailable.' -Status 503) }
        $tailnet = & $enroll $Job.name $username $password
        $Job.tailnetIp = [string](Get-EpicVMProperty -Object $tailnet -Name 'ip' -Default '')
        $Job.tailnetDeviceId = [string](Get-EpicVMProperty -Object $tailnet -Name 'deviceId' -Default '')
        if ($Job.tailnetIp -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$' -or [string]::IsNullOrWhiteSpace($Job.tailnetDeviceId)) {
            throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'Tailscale enrollment did not return a verified device.' -Status 422)
        }
        # Re-enrollments of a reused VM name orphan the previous enrollment's
        # device record; sweep it while keeping the freshly enrolled one.
        try {
            $prune = Get-EpicVMProperty -Object $State.Provider -Name 'ClearTailscaleStaleDevices' -Default $null
            if ($null -ne $prune) { & $prune ([string]$Job.name) ([string]$Job.tailnetDeviceId) | Out-Null }
        } catch { }
        $managementReady = [bool](Get-EpicVMProperty -Object $tailnet -Name 'managementReady' -Default $false)
        $managementTransport = [string](Get-EpicVMProperty -Object $tailnet -Name 'managementTransport' -Default '')
        if (-not $managementReady -or [string]::IsNullOrWhiteSpace($managementTransport)) {
            throw (New-EpicVMProvisioningError -Code 'management_handoff_failed' -Message 'The post-network management handoff did not verify.' -Status 422)
        }
        $Job.managementTransport = $managementTransport
        $Job.managementReadyAt = [DateTime]::UtcNow.ToString('o')
        # The Windows trust boundary ends here. The HTTPS dashboard retains the
        # request credentials only long enough to build the isolated console on
        # kvm2, then calls console-complete without any credential material.
        $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('network_setup','management_handoff')))
        if ([string]$Job.profile -ieq 'gaming') {
            Invoke-EpicVMProvisioningGamingValidation -State $State -Job $Job -Username $username -Password $password | Out-Null
        }
        else {
            $Job.state = 'streaming_setup'
            $Job.errorCode = $null
            $Job.errorMessage = $null
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-EpicVMProvisioningStore -Store $State.Provisioning
        }
    }
    catch {
        # Guest mutation may already have happened. Retain the exact owned VM
        # for diagnosis instead of deleting it automatically.
        $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'guest_configuration_failed')
        if ($code -eq 'guest_configuration_failed') { $code = if ($Job.state -eq 'guest_setup') { 'guest_account_failed' } else { 'network_setup_failed' } }
        $Job.state = Get-EpicVMProvisioningFailureState -Code $code
        $Job.failureStage = switch -Regex ($Job.state) { 'guest' { 'guest' }; 'network' { 'network' }; 'management' { 'management_handoff' }; 'gaming_gpu' { 'gaming_gpu' }; 'streaming' { 'streaming' }; default { 'unknown' } }
        $Job.errorCode = $code
        $detail = [string](Get-EpicVMProperty -Object $_.Exception -Name 'FailureDetailCode' -Default '')
        if ($script:EpicVMProvisioningFailureDetailCodes -contains $detail) { $Job.failureDetailCode = $detail } else { $Job.failureDetailCode = $null }
        $Job.lastAttemptCode = $code
        $Job.claimConsumed = $true
        $Job.errorMessage = 'Guest setup stopped safely; the owned VM was retained for diagnosis.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning

        # A guest can finish Tailscale enrollment just before the initial
        # verification/control-plane lookup races it.  The claim is already
        # consumed at this point, so retrying the claim or issuing another
        # auth key would be unsafe.  Use the existing read-only, stage-limited
        # network recovery path automatically for this exact boundary.
        $completed = @($Job.completedStages)
        $autoRecoverable = $Job.state -eq 'setup_failed:network' -and
            $completed -contains 'claim' -and $completed -contains 'guest_setup' -and
            $completed -notcontains 'network_setup' -and
            $code -in @('tailscale_enrollment_failed','tailscale_verification_failed','management_handoff_failed','network_setup_failed')
        if ($autoRecoverable) {
            try {
                Invoke-EpicVMProvisioningNetworkRecovery -State $State -Job $Job -Request $Request | Out-Null
                return
            }
            catch {
                # The recovery function persists its own safe, identified
                # failure.  Re-throw the original operation error so callers
                # retain the original correlation and error contract.
            }
        }
        throw
    }
    finally {
        $claim = $null; $username = $null; $password = $null
    }
}

function Invoke-EpicVMProvisioningOmarchyValidation {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [bool] $RequireSunshine = $false
    )
    $validate = Get-EpicVMProperty -Object $State.Provider -Name 'ValidateOmarchyGuest' -Default $null
    if ($null -eq $validate) {
        throw (New-EpicVMProvisioningError -Code 'omarchy_guest_validation_unavailable' -Message 'The Omarchy AMD guest validation gate is unavailable.' -Status 503)
    }

    $Job.state = 'omarchy_gpu_validation'
    $Job.failureStage = $null
    $Job.failureDetailCode = $null
    $Job.errorCode = $null
    $Job.errorMessage = $null
    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-EpicVMProvisioningStore -Store $State.Provisioning

    try {
        $result = $null
        $parameterCount = 0
        try { $parameterCount = @($validate.Ast.ParamBlock.Parameters).Count } catch { $parameterCount = 0 }
        if ($parameterCount -ge 4) {
            $result = & $validate $Job.name ([string]$Job.guestUsername) ([string]$Job.tailnetIp) ([bool]$RequireSunshine)
        }
        elseif ($RequireSunshine) {
            $result = & $validate $Job.name ([string]$Job.guestUsername) ([string]$Job.tailnetIp)
        }
        else {
            throw (New-EpicVMProvisioningError -Code 'omarchy_guest_validation_unavailable' -Message 'The Omarchy guest validator cannot perform the pre-console GPU check.' -Status 503)
        }
        if ($null -eq $result -or -not [bool](Get-EpicVMProperty -Object $result -Name 'ok' -Default $false)) {
            $detail = [string](Get-EpicVMProperty -Object $result -Name 'failureDetailCode' -Default 'OMARCHY_GPU_DEVICE_MISSING')
            if ($script:EpicVMProvisioningFailureDetailCodes -notcontains $detail) { $detail = 'OMARCHY_GPU_DEVICE_MISSING' }
            throw (New-EpicVMProvisioningError -Code 'omarchy_gpu_validation_failed' -Message 'The Omarchy guest GPU, accelerated renderer, and Wayland validation gate failed.' -Status 422 -DetailCode $detail)
        }

        $Job.omarchyGpuValidated = $true
        $Job.omarchyValidationAt = [DateTime]::UtcNow.ToString('o')
        $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('omarchy_gpu')))
        $Job.state = 'streaming_setup'
        $Job.failureStage = $null
        $Job.failureDetailCode = $null
        $Job.errorCode = $null
        $Job.errorMessage = $null
        $Job.lastAttemptCode = $null
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        return $Job
    }
    catch {
        $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'omarchy_gpu_validation_failed')
        if ($code -notin @('omarchy_guest_validation_unavailable','omarchy_gpu_validation_failed','omarchy_encoder_unavailable','omarchy_sunshine_configuration_failed')) {
            $code = 'omarchy_gpu_validation_failed'
        }
        $Job.state = Get-EpicVMProvisioningFailureState -Code $code
        $Job.failureStage = 'omarchy_gpu'
        $Job.errorCode = $code
        $detail = [string](Get-EpicVMProperty -Object $_.Exception -Name 'FailureDetailCode' -Default '')
        if ($script:EpicVMProvisioningFailureDetailCodes -contains $detail) { $Job.failureDetailCode = $detail } else { $Job.failureDetailCode = $null }
        $Job.lastAttemptCode = $code
        $Job.errorMessage = 'Omarchy AMD GPU validation stopped safely; the owned VM was retained for diagnosis.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw
    }
}

function Invoke-EpicVMProvisioningOmarchyPostClaimSetup {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password
    )
    $configure = Get-EpicVMProperty -Object $State.Provider -Name 'ConfigureOmarchyGuest' -Default $null
    if ($null -eq $configure) { throw (New-EpicVMProvisioningError -Code 'omarchy_guest_configuration_unavailable' -Message 'Omarchy Linux guest configuration is unavailable.' -Status 503) }
    $wait = Get-EpicVMProperty -Object $State.Provider -Name 'WaitOmarchyGuestReady' -Default $null
    if ($null -eq $wait) { throw (New-EpicVMProvisioningError -Code 'omarchy_bootstrap_not_ready' -Message 'The Omarchy Tailscale SSH readiness provider is unavailable.' -Status 503) }

    $Job.guestUsername = $Username
    $Job.guestOs = 'Omarchy Linux'
    if ($State.Provider.PSObject.Properties.Name -contains 'LastOmarchyGuestIp') {
        $State.Provider.LastOmarchyGuestIp = [string]$Job.tailnetIp
    }
    $Job.state = 'guest_setup'
    $Job.failureStage = $null
    $Job.failureDetailCode = $null
    $Job.errorCode = $null
    $Job.errorMessage = $null
    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-EpicVMProvisioningStore -Store $State.Provisioning

    $guestResult = & $configure $Job.name $Username $Password
    if ($null -eq $guestResult -or -not [bool](Get-EpicVMProperty -Object $guestResult -Name 'ok' -Default $false)) {
        $detail = [string](Get-EpicVMProperty -Object $guestResult -Name 'failureDetailCode' -Default 'account_verification_failed')
        if ($script:EpicVMProvisioningFailureDetailCodes -notcontains $detail) { $detail = 'account_verification_failed' }
        throw (New-EpicVMProvisioningError -Code 'guest_account_failed' -Message 'The Omarchy Linux account setup did not verify.' -Status 422 -DetailCode $detail)
    }
    $Job.guestSetupVerified = $true
    $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('guest_setup')))
    $Job.state = 'network_setup'
    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-EpicVMProvisioningStore -Store $State.Provisioning

    # The bootstrap identity is removed by the privileged guest transition,
    # so a post-transition readiness check must use the final management key.
    # The initial Tailscale/SSH checkpoint is retained and re-used here.
    if ([string]$Job.tailnetIp -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$' -or
        [string]::IsNullOrWhiteSpace([string]$Job.tailnetDeviceId)) {
        throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'The Omarchy Tailscale device checkpoint is unavailable.' -Status 422)
    }
    $removeSeed = Get-EpicVMProperty -Object $State.Provider -Name 'RemoveOmarchySeed' -Default $null
    if ($null -ne $removeSeed) {
        $removed = & $removeSeed $Job.name
        if ($null -eq $removed -or -not [bool](Get-EpicVMProperty -Object $removed -Name 'seedRemoved' -Default $false)) {
            throw (New-EpicVMProvisioningError -Code 'omarchy_seed_cleanup_failed' -Message 'The Omarchy cidata seed could not be removed after guest configuration.' -Status 422)
        }
    }
    $transport = [string](Get-EpicVMProperty -Object $guestResult -Name 'managementTransport' -Default 'tailscale_ssh')
    $Job.managementTransport = $transport
    $Job.managementReadyAt = [DateTime]::UtcNow.ToString('o')
    $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('network_setup','management_handoff')))
    Save-EpicVMProvisioningStore -Store $State.Provisioning

    Invoke-EpicVMProvisioningOmarchyValidation -State $State -Job $Job -RequireSunshine $false | Out-Null
    return $Job
}

function Start-EpicVMOmarchyProvisioningJob {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Job)
    try {
        if ($Job.state -ne 'queued') { return $null }
        if (-not (Get-Command -Name Test-EpicVMOmarchyTemplateManifest -ErrorAction SilentlyContinue) -or
            -not (Test-EpicVMOmarchyTemplateManifest -Config $State.Config)) {
            throw (New-EpicVMProvisioningError -Code 'omarchy_template_invalid' -Message 'The pinned Omarchy template manifest is missing or invalid.' -Status 503)
        }
        $readiness = Get-EpicVMProvisioningReadiness -Config $State.Config -Provider $State.Provider
        if (-not [bool](Get-EpicVMProperty -Object $readiness -Name 'omarchy_provisioning' -Default $false)) {
            throw (New-EpicVMProvisioningError -Code 'omarchy_not_validated' -Message 'Omarchy provisioning remains disabled until the pinned image and AMD GPU-P pilot are validated.' -Status 409)
        }
        $Job.state = 'cloning'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning

        $profile = Get-EpicVMProvisioningProfile -Profile 'omarchy'
        $manifestPath = [string](Get-EpicVMProperty -Object $State.Config -Name 'OmarchyTemplateManifestPath' -Default '')
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Job.templateVersion = [string]$manifest.templateVersion
        $Job.guestOs = 'Omarchy Linux'
        $spec = Get-EpicVMOmarchyProvisioningSpec -Config $State.Config -Request $Job
        $prepare = Get-EpicVMProperty -Object $State.Provider -Name 'PrepareOmarchyBootstrap' -Default $null
        if ($null -eq $prepare) { throw (New-EpicVMProvisioningError -Code 'omarchy_bootstrap_prepare_failed' -Message 'The Omarchy bootstrap provider is unavailable.' -Status 503) }
        $bootstrap = & $prepare $Job.name
        $seedPath = [string](Get-EpicVMProperty -Object $bootstrap -Name 'seedPath' -Default '')
        if ([string]::IsNullOrWhiteSpace($seedPath)) { throw (New-EpicVMProvisioningError -Code 'omarchy_bootstrap_prepare_failed' -Message 'The Omarchy cidata seed was not prepared.' -Status 503) }

        $createRequest = [ordered]@{
            name = $Job.name
            profile = $profile.profile
            cpuCount = [long]$spec.cpuCount
            memoryBytes = [long]$spec.memoryBytes
            diskSizeBytes = [long]$spec.diskSizeBytes
            generation = 2
            gpu = $true
            gpuPartitionPercent = [int]$spec.gpuPartitionPercent
            gpuDeviceIdentity = [string]$spec.gpuDeviceIdentity
            fullCopy = $true
            templateRequired = $true
            templateDiskPath = [string]$manifest.imagePath
            bootstrapSeedPath = $seedPath
        }
        $vm = & $State.Provider.CreateVM $createRequest
        $candidateId = [string](Get-EpicVMProperty -Object $vm -Name 'id' -Default (Get-EpicVMProperty -Object $vm -Name 'Id' -Default ''))
        $Job.vmId = Get-EpicVMJobImmutableVmId -State $State -Job ([pscustomobject]@{ name = $Job.name; vmId = $candidateId })
        $Job.state = 'booting'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        & $State.Provider.StartVM $Job.name | Out-Null

        $wait = Get-EpicVMProperty -Object $State.Provider -Name 'WaitOmarchyGuestReady' -Default $null
        if ($null -eq $wait) { throw (New-EpicVMProvisioningError -Code 'omarchy_bootstrap_not_ready' -Message 'The Omarchy Tailscale SSH readiness provider is unavailable.' -Status 503) }
        $ready = & $wait $Job.name 600 2000
        if ($null -eq $ready -or -not [bool](Get-EpicVMProperty -Object $ready -Name 'ok' -Default $false)) {
            throw (New-EpicVMProvisioningError -Code 'omarchy_bootstrap_not_ready' -Message 'The Omarchy guest did not become ready over Tailscale SSH.' -Status 503)
        }
        $Job.tailnetIp = [string](Get-EpicVMProperty -Object $ready -Name 'ip' -Default '')
        $Job.tailnetDeviceId = [string](Get-EpicVMProperty -Object $ready -Name 'deviceId' -Default '')
        $Job.managementTransport = [string](Get-EpicVMProperty -Object $ready -Name 'managementTransport' -Default 'tailscale_ssh')
        $Job.managementReadyAt = [DateTime]::UtcNow.ToString('o')
        if ($Job.tailnetIp -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$' -or
            [string]::IsNullOrWhiteSpace($Job.tailnetDeviceId)) {
            throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'The Omarchy Tailscale device did not pass verification.' -Status 422)
        }
        $removeSeed = Get-EpicVMProperty -Object $State.Provider -Name 'RemoveOmarchySeed' -Default $null
        if ($null -eq $removeSeed) { throw (New-EpicVMProvisioningError -Code 'omarchy_seed_cleanup_failed' -Message 'The Omarchy seed cleanup provider is unavailable.' -Status 503) }
        $removed = & $removeSeed $Job.name
        if ($null -eq $removed -or -not [bool](Get-EpicVMProperty -Object $removed -Name 'seedRemoved' -Default $false)) {
            throw (New-EpicVMProvisioningError -Code 'omarchy_seed_cleanup_failed' -Message 'The Omarchy cidata seed could not be removed after bootstrap.' -Status 422)
        }

        $claim = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
        $Job.claimHash = ConvertTo-EpicVMClaimHash -Value $claim
        $Job.claimExpires = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
        $Job.claimUsed = $false
        $Job.claimConsumed = $false
        $State.Provisioning.Claims[$Job.id] = $Job
        $Job.state = 'unclaimed'
        $Job.completedStages = @()
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        return $claim
    }
    catch {
        Invoke-EpicVMProvisioningFailedCleanup -State $State -Job $Job
        $Job.errorCode = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'omarchy_provisioning_failed')
        $Job.state = 'setup_failed:preclaim'
        $Job.failureStage = 'preclaim'
        $Job.lastAttemptCode = $Job.errorCode
        $Job.errorMessage = 'Omarchy provisioning stopped before guest claim; no claim was consumed.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw
    }
}

function Invoke-EpicVMProvisioningOmarchyClaim {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [string] $Claim,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password
    )
    $operation = Invoke-EpicVMProvisioningClaimCommit -State $State -Job $Job -Claim $Claim
    try {
        Invoke-EpicVMProvisioningOmarchyPostClaimSetup -State $State -Job $Job -Username $Username -Password $Password | Out-Null
        return $Job
    }
    catch {
        $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'omarchy_guest_configuration_failed')
        $Job.state = Get-EpicVMProvisioningFailureState -Code $code
        $Job.failureStage = switch -Regex ($Job.state) {
            'guest' { 'guest' }
            'network' { 'network' }
            'management' { 'management_handoff' }
            'omarchy_gpu' { 'omarchy_gpu' }
            default { 'unknown' }
        }
        $Job.errorCode = $code
        $detail = [string](Get-EpicVMProperty -Object $_.Exception -Name 'FailureDetailCode' -Default '')
        if ($script:EpicVMProvisioningFailureDetailCodes -contains $detail) { $Job.failureDetailCode = $detail } else { $Job.failureDetailCode = $null }
        $Job.lastAttemptCode = $code
        $Job.claimConsumed = $true
        $Job.errorMessage = 'Omarchy guest setup stopped safely; the owned VM was retained for diagnosis.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw
    }
    finally {
        $Claim = $null; $Username = $null; $Password = $null; $operation = $null
    }
}

function Invoke-EpicVMProvisioningOmarchyGuestRecovery {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [object] $Request
    )
    $username = [string](Get-EpicVMProperty -Object $Request -Name 'username' -Default (Get-EpicVMProperty -Object $Job -Name 'guestUsername' -Default ''))
    $password = [string](Get-EpicVMProperty -Object $Request -Name 'password' -Default '')
    if (-not (Test-EpicVMProvisioningCredentialInput -Username $username -Password $password)) {
        throw (New-EpicVMProvisioningError -Code 'invalid_credential_input' -Message 'The credential input is empty or does not meet the request policy.' -Status 400)
    }

    Invoke-EpicVMProvisioningStoreLocked -Action {
        $diskStore = New-EpicVMProvisioningStore -Config $State.Config
        $persisted = @($diskStore.Jobs.Values | Where-Object { [string]$_.id -ceq [string]$Job.id } | Select-Object -First 1)
        if ($persisted.Count -gt 0) { Copy-EpicVMProvisioningJobFields -Source $persisted[0] -Target $Job | Out-Null }
        $Job.state = ConvertTo-EpicVMCanonicalProvisioningState -Record $Job
        $stages = @(Get-EpicVMProvisioningCompletedStages -Value $Job.completedStages)
        if ($Job.state -ne 'setup_failed:guest' -or
            -not [bool](Get-EpicVMProperty -Object $Job -Name 'claimConsumed' -Default $false) -or
            -not [bool](Get-EpicVMProperty -Object $Job -Name 'claimUsed' -Default $false) -or
            ($stages -notcontains 'claim') -or ($stages -contains 'guest_setup') -or
            -not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Job -Name 'claimHash' -Default ''))) {
            throw (New-EpicVMProvisioningError -Code 'guest_recovery_not_allowed' -Message 'Only a retained, consumed Omarchy guest-stage failure may be recovered.' -Status 409)
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Job -Name 'vmId' -Default ''))) {
            throw (New-EpicVMProvisioningError -Code 'guest_recovery_vm_missing' -Message 'The retained Omarchy guest identity is unavailable.' -Status 409)
        }
        $Job.state = 'guest_setup'
        $Job.failureStage = $null
        $Job.failureDetailCode = $null
        $Job.errorCode = $null
        $Job.errorMessage = $null
        $Job.lastAttemptCode = 'omarchy_guest_recovery_started'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        $State.Provisioning.Jobs[$Job.id] = $Job
        Save-EpicVMProvisioningStore -Store $State.Provisioning
    } | Out-Null

    try {
        Invoke-EpicVMProvisioningOmarchyPostClaimSetup -State $State -Job $Job -Username $username -Password $password | Out-Null
        return $Job
    }
    catch {
        $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'omarchy_guest_recovery_failed')
        $Job.state = Get-EpicVMProvisioningFailureState -Code $code
        $Job.failureStage = switch -Regex ($Job.state) {
            'guest' { 'guest' }
            'network' { 'network' }
            'omarchy_gpu' { 'omarchy_gpu' }
            default { 'guest' }
        }
        $Job.errorCode = $code
        $detail = [string](Get-EpicVMProperty -Object $_.Exception -Name 'FailureDetailCode' -Default '')
        if ($script:EpicVMProvisioningFailureDetailCodes -contains $detail) { $Job.failureDetailCode = $detail } else { $Job.failureDetailCode = $null }
        $Job.lastAttemptCode = $code
        $Job.claimConsumed = $true
        $Job.errorMessage = 'Omarchy guest recovery stopped safely; the owned VM was retained for diagnosis.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw
    }
    finally { $username = $password = $null }
}

function Invoke-EpicVMProvisioningOmarchyNetworkRecovery {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [object] $Request
    )
    $username = [string](Get-EpicVMProperty -Object $Request -Name 'username' -Default (Get-EpicVMProperty -Object $Job -Name 'guestUsername' -Default ''))
    if ($username -notmatch '^[A-Za-z][A-Za-z0-9._-]{2,31}$') {
        throw (New-EpicVMProvisioningError -Code 'invalid_credential_input' -Message 'The Linux account name is required for Omarchy network recovery.' -Status 400)
    }
    $savedUsername = [string](Get-EpicVMProperty -Object $Job -Name 'guestUsername' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($savedUsername) -and $savedUsername -cne $username) {
        throw (New-EpicVMProvisioningError -Code 'invalid_credential_input' -Message 'The Omarchy recovery account does not match the retained Linux account.' -Status 400)
    }
    $reverify = [bool](Get-EpicVMProperty -Object $Request -Name 'reverify' -Default $false)
    $started = $false
    $previousState = $null
    $previousStages = @()
    try {
        Invoke-EpicVMProvisioningStoreLocked -Action {
            $diskStore = New-EpicVMProvisioningStore -Config $State.Config
            $persisted = @($diskStore.Jobs.Values | Where-Object { [string]$_.id -ceq [string]$Job.id } | Select-Object -First 1)
            if ($persisted.Count -gt 0) { Copy-EpicVMProvisioningJobFields -Source $persisted[0] -Target $Job | Out-Null }
            $Job.state = ConvertTo-EpicVMCanonicalProvisioningState -Record $Job
            $stages = @(Get-EpicVMProvisioningCompletedStages -Value $Job.completedStages)
            $claimReady = [bool](Get-EpicVMProperty -Object $Job -Name 'claimConsumed' -Default $false) -and
                [bool](Get-EpicVMProperty -Object $Job -Name 'claimUsed' -Default $false) -and
                ($stages -contains 'claim') -and ($stages -contains 'guest_setup')
            $normalAllowed = $Job.state -eq 'setup_failed:network' -and $claimReady -and
                ($stages -notcontains 'network_setup') -and ($stages -notcontains 'management_handoff')
            $readyAllowed = $reverify -and $Job.state -in @('ready','setup_failed:streaming','setup_failed:agent_restart') -and
                $claimReady -and ($stages -contains 'network_setup') -and ($stages -contains 'management_handoff')
            if (-not ($normalAllowed -or $readyAllowed)) {
                throw (New-EpicVMProvisioningError -Code 'network_recovery_not_allowed' -Message 'Only a retained Omarchy network failure or an explicitly requested revalidation may be recovered.' -Status 409)
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Job -Name 'vmId' -Default ''))) {
                throw (New-EpicVMProvisioningError -Code 'network_recovery_vm_missing' -Message 'The retained Omarchy VM identity is unavailable.' -Status 409)
            }
            if ($readyAllowed) {
                $previousState = [string]$Job.state
                $previousStages = @($stages)
            }
            $Job.state = 'network_setup'
            $Job.failureStage = $null
            $Job.failureDetailCode = $null
            $Job.errorCode = $null
            $Job.errorMessage = $null
            $Job.lastAttemptCode = if ($readyAllowed) { 'omarchy_network_reverify_started' } else { 'omarchy_network_recovery_started' }
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $State.Provisioning.Jobs[$Job.id] = $Job
            Save-EpicVMProvisioningStore -Store $State.Provisioning
            $script:EpicVMOmarchyNetworkRecoveryStarted = $true
        } | Out-Null
        $started = $true

        if ($State.Provider.PSObject.Properties.Name -contains 'LastOmarchyGuestIp') {
            $State.Provider.LastOmarchyGuestIp = [string]$Job.tailnetIp
        }
        $wait = Get-EpicVMProperty -Object $State.Provider -Name 'WaitOmarchyGuestReady' -Default $null
        if ($null -eq $wait) { throw (New-EpicVMProvisioningError -Code 'omarchy_bootstrap_not_ready' -Message 'The Omarchy Tailscale SSH recovery provider is unavailable.' -Status 503) }
        $ready = & $wait $Job.name 120 1000 $username
        $ip = [string](Get-EpicVMProperty -Object $ready -Name 'ip' -Default '')
        $deviceId = [string](Get-EpicVMProperty -Object $ready -Name 'deviceId' -Default '')
        if ($null -eq $ready -or -not [bool](Get-EpicVMProperty -Object $ready -Name 'ok' -Default $false) -or
            $ip -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$' -or
            [string]::IsNullOrWhiteSpace($deviceId)) {
            throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'The retained Omarchy Tailscale SSH endpoint could not be verified.' -Status 422)
        }
        $Job.tailnetIp = $ip
        $Job.tailnetDeviceId = $deviceId
        $Job.managementTransport = [string](Get-EpicVMProperty -Object $ready -Name 'managementTransport' -Default 'tailscale_ssh')
        $Job.managementReadyAt = [DateTime]::UtcNow.ToString('o')
        $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('network_setup','management_handoff')))
        if ($reverify -or -not [bool]$Job.omarchyGpuValidated) {
            Invoke-EpicVMProvisioningOmarchyValidation -State $State -Job $Job -RequireSunshine ([bool]$reverify) | Out-Null
        }
        else {
            $Job.state = 'streaming_setup'
            $Job.failureStage = $null
            $Job.failureDetailCode = $null
            $Job.errorCode = $null
            $Job.errorMessage = $null
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-EpicVMProvisioningStore -Store $State.Provisioning
        }
        if ($reverify -and -not [string]::IsNullOrWhiteSpace($previousState)) {
            $Job.state = $previousState
            $Job.completedStages = @($previousStages)
            $Job.failureStage = $null
            $Job.failureDetailCode = $null
            $Job.errorCode = $null
            $Job.errorMessage = $null
            $Job.lastAttemptCode = $null
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-EpicVMProvisioningStore -Store $State.Provisioning
        }
        return $Job
    }
    catch {
        if ($started) {
            $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'omarchy_network_recovery_failed')
            if ([string]::IsNullOrWhiteSpace($code) -or $code -in @('network_recovery_not_allowed','network_recovery_vm_missing')) { $code = 'omarchy_network_recovery_failed' }
            if ($reverify -and -not [string]::IsNullOrWhiteSpace($previousState)) {
                $Job.state = $previousState
                $Job.completedStages = @($previousStages)
                $Job.failureStage = $null
                $Job.failureDetailCode = $null
                $Job.errorCode = $null
                $Job.errorMessage = $null
            }
            else {
                $Job.state = Get-EpicVMProvisioningFailureState -Code $code
                $Job.failureStage = if ($Job.state -match 'omarchy_gpu') { 'omarchy_gpu' } else { 'network' }
                $Job.errorCode = $code
                $Job.failureDetailCode = $null
                $Job.claimConsumed = $true
                $Job.errorMessage = 'Omarchy network recovery stopped safely; the owned VM was retained for diagnosis.'
            }
            $Job.lastAttemptCode = $code
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-EpicVMProvisioningStore -Store $State.Provisioning
        }
        throw
    }
    finally { $username = $null }
}

function Invoke-EpicVMProvisioningGuestRecovery {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [object] $Request
    )
    if ([string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ieq 'omarchy') {
        return Invoke-EpicVMProvisioningOmarchyGuestRecovery -State $State -Job $Job -Request $Request
    }
    $username = [string](Get-EpicVMProperty -Object $Request -Name 'username' -Default '')
    $password = [string](Get-EpicVMProperty -Object $Request -Name 'password' -Default '')
    if (-not (Test-EpicVMProvisioningCredentialInput -Username $username -Password $password)) {
        throw (New-EpicVMProvisioningError -Code 'invalid_credential_input' -Message 'The credential input is empty or does not meet the request policy.' -Status 400)
    }

    Invoke-EpicVMProvisioningStoreLocked -Action {
        $diskStore = New-EpicVMProvisioningStore -Config $State.Config
        $persisted = @($diskStore.Jobs.Values | Where-Object { [string]$_.id -ceq [string]$Job.id } | Select-Object -First 1)
        if ($persisted.Count -gt 0) { Copy-EpicVMProvisioningJobFields -Source $persisted[0] -Target $Job | Out-Null }
        $Job.state = ConvertTo-EpicVMCanonicalProvisioningState -Record $Job
        $stages = @($Job.completedStages)
        $claimHash = [string](Get-EpicVMProperty -Object $Job -Name 'claimHash' -Default '')
        if ($Job.state -ne 'setup_failed:guest' -or
            -not [bool](Get-EpicVMProperty -Object $Job -Name 'claimConsumed' -Default $false) -or
            -not [bool](Get-EpicVMProperty -Object $Job -Name 'claimUsed' -Default $false) -or
            ($stages -notcontains 'claim') -or ($stages -contains 'guest_setup') -or
            -not [string]::IsNullOrWhiteSpace($claimHash)) {
            throw (New-EpicVMProvisioningError -Code 'guest_recovery_not_allowed' -Message 'Only a retained, consumed guest-stage failure may be recovered.' -Status 409)
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Job -Name 'vmId' -Default ''))) {
            throw (New-EpicVMProvisioningError -Code 'guest_recovery_vm_missing' -Message 'The retained guest identity is unavailable.' -Status 409)
        }
        $Job.state = 'guest_setup'
        $Job.failureStage = $null
        $Job.failureDetailCode = $null
        $Job.errorCode = $null
        $Job.errorMessage = $null
        $Job.lastAttemptCode = 'guest_recovery_started'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        $State.Provisioning.Jobs[$Job.id] = $Job
        Save-EpicVMProvisioningStore -Store $State.Provisioning
    } | Out-Null

    $credential = $null
    try {
        $vmId = Get-EpicVMJobImmutableVmId -State $State -Job $Job
        $credential = [PSCredential]::new($username, (ConvertTo-SecureString $password -AsPlainText -Force))
        $readiness = Invoke-EpicVMPowerShellDirectOnce -Provider $State.Provider -VmName $Job.name -VmId $vmId -Credential $credential -Script (Get-EpicVMGuestDesiredCredentialReadinessScript) -TimeoutSeconds 30
        if (-not [bool](Get-EpicVMHyperVValue -Object $readiness -Name 'ok' -Default $false)) {
            throw (New-EpicVMProvisioningError -Code 'guest_account_failed' -Message 'The retained guest account did not pass readiness verification.' -Status 422 -DetailCode 'account_verification_failed')
        }
        $Job.guestSetupVerified = $true
        $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('guest_setup')))
        $Job.state = 'network_setup'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning

        $enroll = Get-EpicVMProperty -Object $State.Provider -Name 'EnrollTailscale' -Default $null
        if ($null -eq $enroll) { throw (New-EpicVMProvisioningError -Code 'tailscale_unavailable' -Message 'Tailscale enrollment is unavailable.' -Status 503) }
        $tailnet = & $enroll $Job.name $username $password
        $Job.tailnetIp = [string](Get-EpicVMProperty -Object $tailnet -Name 'ip' -Default '')
        $Job.tailnetDeviceId = [string](Get-EpicVMProperty -Object $tailnet -Name 'deviceId' -Default '')
        if ($Job.tailnetIp -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$' -or [string]::IsNullOrWhiteSpace($Job.tailnetDeviceId)) {
            throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'Tailscale enrollment did not return a verified device.' -Status 422)
        }
        # Re-enrollments of a reused VM name orphan the previous enrollment's
        # device record; sweep it while keeping the freshly enrolled one.
        try {
            $prune = Get-EpicVMProperty -Object $State.Provider -Name 'ClearTailscaleStaleDevices' -Default $null
            if ($null -ne $prune) { & $prune ([string]$Job.name) ([string]$Job.tailnetDeviceId) | Out-Null }
        } catch { }
        $managementReady = [bool](Get-EpicVMProperty -Object $tailnet -Name 'managementReady' -Default $false)
        $managementTransport = [string](Get-EpicVMProperty -Object $tailnet -Name 'managementTransport' -Default '')
        if (-not $managementReady -or [string]::IsNullOrWhiteSpace($managementTransport)) {
            throw (New-EpicVMProvisioningError -Code 'management_handoff_failed' -Message 'The post-network management handoff did not verify.' -Status 422)
        }
        $Job.managementTransport = $managementTransport
        $Job.managementReadyAt = [DateTime]::UtcNow.ToString('o')
        $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('network_setup','management_handoff')))
        if ([string]$Job.profile -ieq 'gaming') {
            Invoke-EpicVMProvisioningGamingValidation -State $State -Job $Job -Username $username -Password $password | Out-Null
        }
        else {
            $Job.state = 'streaming_setup'
            $Job.errorCode = $null
            $Job.errorMessage = $null
            $Job.failureStage = $null
            $Job.failureDetailCode = $null
            $Job.lastAttemptCode = $null
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-EpicVMProvisioningStore -Store $State.Provisioning
        }
        return $Job
    }
    catch {
        $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'guest_recovery_failed')
        if ($code -eq 'guest_recovery_failed') { $code = if ($Job.state -eq 'guest_setup') { 'guest_account_failed' } else { 'network_setup_failed' } }
        $Job.state = Get-EpicVMProvisioningFailureState -Code $code
        $Job.failureStage = switch -Regex ($Job.state) { 'guest' { 'guest' }; 'network' { 'network' }; 'management' { 'management_handoff' }; 'gaming_gpu' { 'gaming_gpu' }; default { 'unknown' } }
        $Job.errorCode = $code
        $detail = [string](Get-EpicVMProperty -Object $_.Exception -Name 'FailureDetailCode' -Default '')
        if ($script:EpicVMProvisioningFailureDetailCodes -contains $detail) { $Job.failureDetailCode = $detail } else { $Job.failureDetailCode = $null }
        $Job.lastAttemptCode = $code
        $Job.claimConsumed = $true
        $Job.errorMessage = 'Guest recovery stopped safely; the owned VM was retained for diagnosis.'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw
    }
    finally {
            $username = $password = $null
            $credential = $null
        }
    }

    function Invoke-EpicVMProvisioningNetworkRecovery {
        param(
            [Parameter(Mandatory)] [object] $State,
            [Parameter(Mandatory)] [object] $Job,
            [Parameter(Mandatory)] [object] $Request
        )
        if ([string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ieq 'omarchy') {
            return Invoke-EpicVMProvisioningOmarchyNetworkRecovery -State $State -Job $Job -Request $Request
        }
        $username = [string](Get-EpicVMProperty -Object $Request -Name 'username' -Default '')
        $password = [string](Get-EpicVMProperty -Object $Request -Name 'password' -Default '')
        if (-not (Test-EpicVMProvisioningCredentialInput -Username $username -Password $password)) {
            throw (New-EpicVMProvisioningError -Code 'invalid_credential_input' -Message 'The credential input is empty or does not meet the request policy.' -Status 400)
        }

        $started = $false
        $reverify = [bool](Get-EpicVMProperty -Object $Request -Name 'reverify' -Default $false)
        $recoveryContext = [pscustomobject]@{
            ReadyReverify = $false
            PreviousState = $null
            PreviousStages = @()
            PreviousTailnetIp = $null
            PreviousTailnetDeviceId = $null
            PreviousManagementTransport = $null
            PreviousManagementReadyAt = $null
            PreviousFailureStage = $null
            PreviousFailureDetailCode = $null
            PreviousErrorCode = $null
            PreviousErrorMessage = $null
        }
        try {
            Invoke-EpicVMProvisioningStoreLocked -Action {
                $diskStore = New-EpicVMProvisioningStore -Config $State.Config
                $persisted = @($diskStore.Jobs.Values | Where-Object { [string]$_.id -ceq [string]$Job.id } | Select-Object -First 1)
                if ($persisted.Count -gt 0) { Copy-EpicVMProvisioningJobFields -Source $persisted[0] -Target $Job | Out-Null }
                $Job.state = ConvertTo-EpicVMCanonicalProvisioningState -Record $Job
                $stages = @(Get-EpicVMProvisioningCompletedStages -Value $Job.completedStages)
                $claimHash = [string](Get-EpicVMProperty -Object $Job -Name 'claimHash' -Default '')
                $claimConsumed = [bool](Get-EpicVMProperty -Object $Job -Name 'claimConsumed' -Default $false)
                $claimUsed = [bool](Get-EpicVMProperty -Object $Job -Name 'claimUsed' -Default $false)
                $hasVmId = -not [string]::IsNullOrWhiteSpace([string](Get-EpicVMProperty -Object $Job -Name 'vmId' -Default ''))
                $networkFailureRecoveryAllowed = $Job.state -eq 'setup_failed:network' -and
                    $claimConsumed -and $claimUsed -and
                    ($stages -contains 'claim') -and ($stages -contains 'guest_setup') -and
                    ($stages -notcontains 'network_setup') -and ($stages -notcontains 'management_handoff') -and
                    [string]::IsNullOrWhiteSpace($claimHash)
                $readyReverifyAllowed = $reverify -and $Job.state -in @('ready','streaming_setup','setup_failed:streaming','setup_failed:gaming_gpu','setup_failed:agent_restart') -and
                    $claimConsumed -and $claimUsed -and $hasVmId -and
                    ($stages -contains 'claim') -and ($stages -contains 'guest_setup') -and
                    ($stages -contains 'network_setup') -and ($stages -contains 'management_handoff')
                $recoveryContext.ReadyReverify = [bool]$readyReverifyAllowed
                if (-not ($networkFailureRecoveryAllowed -or $readyReverifyAllowed)) {
                    throw (New-EpicVMProvisioningError -Code 'network_recovery_not_allowed' -Message 'Only a retained, consumed network-stage failure or an explicitly requested retained guest-network revalidation may be recovered.' -Status 409)
                }
                if (-not $hasVmId) {
                    throw (New-EpicVMProvisioningError -Code 'network_recovery_vm_missing' -Message 'The retained VM identity is unavailable.' -Status 409)
                }
                if ($readyReverifyAllowed) {
                    $recoveryContext.PreviousState = [string]$Job.state
                    $recoveryContext.PreviousStages = @($stages)
                    $recoveryContext.PreviousTailnetIp = Get-EpicVMProperty -Object $Job -Name 'tailnetIp' -Default $null
                    $recoveryContext.PreviousTailnetDeviceId = Get-EpicVMProperty -Object $Job -Name 'tailnetDeviceId' -Default $null
                    $recoveryContext.PreviousManagementTransport = Get-EpicVMProperty -Object $Job -Name 'managementTransport' -Default $null
                    $recoveryContext.PreviousManagementReadyAt = Get-EpicVMProperty -Object $Job -Name 'managementReadyAt' -Default $null
                    $recoveryContext.PreviousFailureStage = Get-EpicVMProperty -Object $Job -Name 'failureStage' -Default $null
                    $recoveryContext.PreviousFailureDetailCode = Get-EpicVMProperty -Object $Job -Name 'failureDetailCode' -Default $null
                    $recoveryContext.PreviousErrorCode = Get-EpicVMProperty -Object $Job -Name 'errorCode' -Default $null
                    $recoveryContext.PreviousErrorMessage = Get-EpicVMProperty -Object $Job -Name 'errorMessage' -Default $null
                }
                $Job.state = 'network_setup'
                $Job.failureStage = $null
                $Job.failureDetailCode = $null
                $Job.errorCode = $null
                $Job.errorMessage = $null
                $Job.lastAttemptCode = if ($readyReverifyAllowed) { 'network_reverify_started' } else { 'network_recovery_started' }
                $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
                $State.Provisioning.Jobs[$Job.id] = $Job
                Save-EpicVMProvisioningStore -Store $State.Provisioning
                $script:EpicVMNetworkRecoveryStarted = $true
            } | Out-Null
            $started = $true

            $vmId = Get-EpicVMJobImmutableVmId -State $State -Job $Job
            $credential = [PSCredential]::new($username, (ConvertTo-SecureString $password -AsPlainText -Force))
            $tailscaleExecutable = [string](Get-EpicVMProperty -Object $State.Config -Name 'TailscaleExecutable' -Default 'C:\Program Files\Tailscale\tailscale.exe')
            $addressResult = $null
            try {
                $addressResult = Invoke-EpicVMPowerShellDirectOnce -Provider $State.Provider -VmName $Job.name -VmId $vmId -Credential $credential -Script (Get-EpicVMTailscaleGuestAddressScript) -ArgumentList @($tailscaleExecutable) -TimeoutSeconds 30
            } catch {
                # A reboot can leave the retained VM running while Tailscale
                # loses its durable node state. Re-enroll only this already-
                # claimed guest; never issue another provisioning claim.
                $enroll = Get-EpicVMProperty -Object $State.Provider -Name 'EnrollTailscale' -Default $null
                if ($null -eq $enroll) {
                    throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'The retained guest Tailscale address could not be verified.' -Status 422)
                }
                try {
                    $addressResult = & $enroll $Job.name $username $password
                } catch {
                    $enrollCode = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'tailscale_verification_failed')
                    $allowedEnrollCodes = @(
                        'tailscale_enrollment_failed','tailscale_state_not_persisted',
                        'tailscale_auth_input_failed','tailscale_guest_command_failed',
                        'tailscale_system_task_timeout','tailscale_system_task_failed',
                        'tailscale_unattended_failed','tailscale_restart_failed',
                        'management_handoff_failed'
                    )
                    if ($allowedEnrollCodes -notcontains $enrollCode) { $enrollCode = 'tailscale_verification_failed' }
                    throw (New-EpicVMProvisioningError -Code $enrollCode -Message 'The retained guest Tailscale address could not be verified.' -Status 422)
                }
            }
            $ip = [string](Get-EpicVMHyperVValue -Object $addressResult -Name 'ip' -Default '')
            if (-not [bool](Get-EpicVMHyperVValue -Object $addressResult -Name 'ok' -Default $false) -or
                $ip -notmatch '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$') {
                throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'The retained guest Tailscale address could not be verified.' -Status 422)
            }
            $deviceId = [string](Get-EpicVMHyperVValue -Object $addressResult -Name 'deviceId' -Default '')
            if ([string]::IsNullOrWhiteSpace($deviceId)) {
                try {
                    $deviceId = Get-EpicVMTailscaleDeviceId -Provider $State.Provider -VmName ([string]$Job.name) -GuestIp $ip
                } catch {
                    throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'The retained Tailscale device could not be identified.' -Status 422)
                }
            }
            if ([string]::IsNullOrWhiteSpace($deviceId)) {
                throw (New-EpicVMProvisioningError -Code 'tailscale_verification_failed' -Message 'The retained Tailscale device could not be identified.' -Status 422)
            }

            $managementPort = 5985
            try { $managementPort = [int](Get-EpicVMHyperVValue -Object $State.Config -Name 'ManagementPort' -Default 5985) } catch { $managementPort = 5985 }
            if ($managementPort -lt 1 -or $managementPort -gt 65535) { $managementPort = 5985 }
            $managementUseSsl = [bool](Get-EpicVMHyperVValue -Object $State.Config -Name 'ManagementUseSsl' -Default $false)
            $management = $null
            try {
                $management = Invoke-EpicVMPowerShellDirectOnce -Provider $State.Provider -VmName $Job.name -VmId $vmId -Credential $credential -Script (Get-EpicVMGuestManagementConfigurationScript) -ArgumentList @($managementPort,$managementUseSsl) -TimeoutSeconds 45
            } catch {
                throw (New-EpicVMProvisioningError -Code 'management_handoff_failed' -Message 'The retained guest management endpoint could not be verified.' -Status 422)
            }
            if (-not [bool](Get-EpicVMHyperVValue -Object $management -Name 'ok' -Default $false) -or
                -not [bool](Get-EpicVMHyperVValue -Object $management -Name 'managementEndpoint' -Default $false) -or
                -not [bool](Get-EpicVMHyperVValue -Object $management -Name 'firewallScoped' -Default $false)) {
                throw (New-EpicVMProvisioningError -Code 'management_handoff_failed' -Message 'The retained guest management endpoint could not be verified.' -Status 422)
            }

            $Job.tailnetIp = $ip
            $Job.tailnetDeviceId = [string]$deviceId
            $Job.managementTransport = 'tailscale_winrm'
            $Job.managementReadyAt = [DateTime]::UtcNow.ToString('o')
            $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('network_setup','management_handoff')))
            if ([string]$Job.profile -ieq 'gaming') {
                Invoke-EpicVMProvisioningGamingValidation -State $State -Job $Job -Username $username -Password $password | Out-Null
            }
            else {
                $Job.state = 'streaming_setup'
                $Job.failureStage = $null
                $Job.failureDetailCode = $null
                $Job.errorCode = $null
                $Job.errorMessage = $null
                $Job.lastAttemptCode = $null
                $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
                Save-EpicVMProvisioningStore -Store $State.Provisioning
            }
            return $Job
        }
        catch {
            if ($started) {
                $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'network_recovery_failed')
                if ([string]::IsNullOrWhiteSpace($code) -or $code -in @('network_recovery_not_allowed','network_recovery_vm_missing')) { $code = 'network_recovery_failed' }
                if ($recoveryContext.ReadyReverify) {
                    # Ready-state revalidation is not a provisioning transition.
                    # Restore the last known-good checkpoint if the guest cannot be
                    # revalidated; the dashboard will retry without consuming a
                    # claim or falsely reporting the guest as healthy.
                    $Job.state = if ([string]::IsNullOrWhiteSpace([string]$recoveryContext.PreviousState)) { 'ready' } else { [string]$recoveryContext.PreviousState }
                    $Job.completedStages = @($recoveryContext.PreviousStages)
                    $Job.tailnetIp = $recoveryContext.PreviousTailnetIp
                    $Job.tailnetDeviceId = $recoveryContext.PreviousTailnetDeviceId
                    $Job.managementTransport = $recoveryContext.PreviousManagementTransport
                    $Job.managementReadyAt = $recoveryContext.PreviousManagementReadyAt
                    if ($Job.state -eq 'ready') {
                        $Job.failureStage = $null
                        $Job.failureDetailCode = $null
                        $Job.errorCode = $null
                        $Job.errorMessage = $null
                    }
                    else {
                        $Job.failureStage = $recoveryContext.PreviousFailureStage
                        $Job.failureDetailCode = $recoveryContext.PreviousFailureDetailCode
                        $Job.errorCode = $recoveryContext.PreviousErrorCode
                        $Job.errorMessage = $recoveryContext.PreviousErrorMessage
                    }
                    $Job.lastAttemptCode = $code
                    $Job.consoleRepairOutcome = 'failed'
                    $Job.consoleRepairErrorCode = $code
                    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
                    Save-EpicVMProvisioningStore -Store $State.Provisioning
                }
                else {
                    $Job.state = Get-EpicVMProvisioningFailureState -Code $code
                    $Job.failureStage = switch -Regex ($Job.state) { 'network' { 'network' }; 'management' { 'management_handoff' }; 'gaming_gpu' { 'gaming_gpu' }; default { 'network' } }
                    $Job.errorCode = $code
                    $Job.failureDetailCode = $null
                    $Job.lastAttemptCode = $code
                    $Job.claimConsumed = $true
                    $Job.errorMessage = 'Network recovery stopped safely; the owned VM was retained for diagnosis.'
                    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
                    Save-EpicVMProvisioningStore -Store $State.Provisioning
                }
            }
            throw
        }
        finally {
            $username = $password = $null
            $credential = $null
        }
    }

    function Invoke-EpicVMConfigureSunshineProvider {
    param(
        [Parameter(Mandatory)][scriptblock]$Invoker,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Job,
        [Parameter(Mandatory)][string]$GuestUsername,
        [Parameter(Mandatory)][string]$GuestPassword,
        [Parameter(Mandatory)][string]$SunshineUsername,
        [Parameter(Mandatory)][string]$SunshinePassword
    )
    # Older controlled providers accepted five arguments. Keep that test and
    # compatibility seam while passing the verified Tailscale address to the
    # production provider when its sixth parameter is present.
    $parameterCount=0
    try { $parameterCount=@($Invoker.Ast.ParamBlock.Parameters).Count } catch { $parameterCount=0 }
    $args=@($Job.name,$GuestUsername,$GuestPassword,$SunshineUsername,$SunshinePassword)
    if($parameterCount -ge 6){$args += [string](Get-EpicVMProperty -Object $Job -Name 'tailnetIp' -Default '')}
    if($parameterCount -ge 7){
        $args += ({ param($handoff)
            if($null -eq $handoff -or -not [bool](Get-EpicVMProperty -Object $handoff -Name 'verified' -Default $false)){
                throw (New-EpicVMProvisioningError -Code 'management_handoff_failed' -Message 'The management handoff did not verify.' -Status 422)
            }
            $Job.managementTransport=[string](Get-EpicVMProperty -Object $handoff -Name 'transport' -Default '')
            $Job.managementReadyAt=[DateTime]::UtcNow.ToString('o')
            $Job.completedStages=@(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('management_handoff')))
            $Job.state='streaming_setup'
            $Job.failureStage=$null
            $Job.errorCode=$null
            $Job.errorMessage=$null
            $Job.updatedAt=[DateTime]::UtcNow.ToString('o')
            Save-EpicVMProvisioningStore -Store $State.Provisioning
        }.GetNewClosure())
    }
    if($parameterCount -ge 8){
        $args += [bool](@($Job.completedStages) -contains 'management_handoff')
    }
    if($parameterCount -ge 9){
        $args += [bool]([string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ieq 'gaming')
    }
    if($parameterCount -ge 10){
        $args += [bool]([string](Get-EpicVMProperty -Object $Job -Name 'profile' -Default 'standard') -ieq 'omarchy')
    }
    return & $Invoker @args
}

function Invoke-EpicVMProvisioningClaimReissue {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Job)

    # The agent keeps its store in memory between requests.  If a browser
    # request was interrupted after the atomic store write, that object can
    # lag the persisted verifier/expiry.  Adopt only a newer, still-valid
    # redacted record for this exact job; never recover a plaintext claim.
    try {
        $diskStore = New-EpicVMProvisioningStore -Config $State.Config
        $persisted = @($diskStore.Jobs.Values | Where-Object { [string]$_.id -ceq [string]$Job.id } | Select-Object -First 1)
        if ($persisted.Count -gt 0) {
            $diskUpdated = [DateTime]::MinValue
            $memoryUpdated = [DateTime]::MinValue
            try { $diskUpdated = [DateTime]::Parse([string]$persisted[0].updatedAt) } catch { }
            try { $memoryUpdated = [DateTime]::Parse([string]$Job.updatedAt) } catch { }
            if ($diskUpdated -gt $memoryUpdated) {
                foreach ($property in @('state', 'claimHash', 'claimExpires', 'claimUsed', 'updatedAt')) {
                    $Job.$property = Get-EpicVMProperty -Object $persisted[0] -Name $property -Default $Job.$property
                }
            }
        }
    }
    catch { }
    return Invoke-EpicVMProvisioningStoreLocked -Action {
        $diskStore = New-EpicVMProvisioningStore -Config $State.Config
        $persisted = @($diskStore.Jobs.Values | Where-Object { [string]$_.id -ceq [string]$Job.id } | Select-Object -First 1)
        if ($persisted.Count -gt 0) { Copy-EpicVMProvisioningJobFields -Source $persisted[0] -Target $Job | Out-Null }
        $Job.state = ConvertTo-EpicVMCanonicalProvisioningState -Record $Job
        if ($Job.state -ne 'unclaimed' -or [bool]$Job.claimConsumed) {
            throw (New-EpicVMProvisioningError -Code 'claim_reissue_not_allowed' -Message 'A claim can only be reissued while the VM is awaiting its first claim.' -Status 409)
        }
        if ([string]::IsNullOrWhiteSpace([string]$Job.claimHash) -or
            [string]$Job.claimHash -notmatch '^[0-9a-fA-F]{64}$') {
            throw (New-EpicVMProvisioningError -Code 'claim_state_invalid' -Message 'The pending claim state is invalid.' -Status 409)
        }
        # Replacing the verifier invalidates every previously issued claim. The
        # plaintext value exists only in this request/response and is never saved.
        $claim = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
        $Job.claimHash = ConvertTo-EpicVMClaimHash -Value $claim
        $Job.claimExpires = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
        $Job.claimUsed = $false
        $Job.claimConsumed = $false
        $Job.completedStages = @()
        $Job.operationId = $null
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        $State.Provisioning.Jobs[$Job.id] = $Job
        $State.Provisioning.Claims[$Job.id] = $Job
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        return $claim
    }
}

function Set-EpicVMProvisioningConsoleCredentials {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Job,
        [Parameter(Mandatory)] [object] $Request
    )
    $reconcileOnly = [bool](Get-EpicVMProperty -Object $Request -Name 'reconcileOnly' -Default $false)
    $reconcileState = [string]$Job.state
    foreach ($propertyName in @('consoleRepairOutcome', 'consoleRepairErrorCode', 'lastAttemptCode', 'failureDetailCode', 'failureStage', 'errorCode', 'errorMessage')) {
        if (-not ($Job.PSObject.Properties.Name -contains $propertyName)) {
            $Job | Add-Member -MemberType NoteProperty -Name $propertyName -Value $null
        }
    }
    $reconcileEvidenceComplete =
        (Test-EpicVMProvisioningEvidence -Record $Job -Stage 'stream_validation') -and
        (@(Get-EpicVMProvisioningCompletedStages -Value $Job.completedStages) -contains 'management_handoff') -and
        (Test-EpicVMProvisioningReadyIdentity -Record $Job)
    if ($reconcileState -eq 'ready' -and -not $reconcileEvidenceComplete) {
        $Job.state = 'setup_failed:legacy_state_uncertain'
        $Job.failureStage = 'legacy_state_uncertain'
        $Job.failureDetailCode = $null
        $Job.errorCode = 'legacy_state_uncertain'
        $Job.errorMessage = 'Persisted readiness lacked required automated provisioning, stream, or route evidence.'
        $Job.lastAttemptCode = 'legacy_ready_rejected'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw (New-EpicVMProvisioningError -Code 'legacy_state_uncertain' -Message 'Persisted readiness lacked required automated provisioning, stream, or route evidence.' -Status 422)
    }
    $completedStages = @(Get-EpicVMProvisioningCompletedStages -Value $Job.completedStages)
    $legacyVmValid = $false
    try { [void][guid]::Parse([string](Get-EpicVMProperty -Object $Job -Name 'vmId' -Default '')); $legacyVmValid = $true } catch { }
    $legacyTailnetIp = [string](Get-EpicVMProperty -Object $Job -Name 'tailnetIp' -Default '')
    $legacyTailnetValid = $legacyTailnetIp -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$'
    $legacyReconcileAllowed = $reconcileOnly -and
        $reconcileState -eq 'setup_failed:legacy_state_uncertain' -and
        [bool]$Job.claimConsumed -and [bool]$Job.claimUsed -and
        $legacyVmValid -and $legacyTailnetValid -and
        @(@('claim', 'guest_setup', 'network_setup', 'management_handoff') | Where-Object { $completedStages -notcontains $_ }).Count -eq 0
    if ($legacyReconcileAllowed) {
        # A legacy-ready record may re-enter only the stage-limited streaming
        # setup path after its identity, claim, network, and management
        # checkpoints are still authoritative. It must never become ready here.
        $Job.state = 'streaming_setup'
        $Job.failureStage = $null
        $Job.failureDetailCode = $null
        $Job.errorCode = $null
        $Job.errorMessage = $null
        $Job.lastAttemptCode = 'legacy_ready_reconciliation'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
    }
    $readyReconcile = $reconcileOnly -and $reconcileState -eq 'ready' -and $reconcileEvidenceComplete
    if ($Job.state -notin @('streaming_setup', 'setup_failed:streaming', 'setup_failed:agent_restart') -and -not $readyReconcile) {
        throw (New-EpicVMProvisioningError -Code 'console_credentials_not_allowed' -Message 'The job is not awaiting console configuration.' -Status 409)
    }
    $guestUsername = [string](Get-EpicVMProperty -Object $Request -Name 'username' -Default '')
    $guestPassword = [string](Get-EpicVMProperty -Object $Request -Name 'password' -Default '')
    $sunshineUsername = [string](Get-EpicVMProperty -Object $Request -Name 'sunshineUsername' -Default '')
    $sunshinePassword = [string](Get-EpicVMProperty -Object $Request -Name 'sunshinePassword' -Default '')
    if ($guestUsername -notmatch '^[A-Za-z][A-Za-z0-9._-]{2,31}$' -or [string]::IsNullOrEmpty($guestPassword) -or
        [string]::IsNullOrEmpty($sunshineUsername) -or [string]::IsNullOrEmpty($sunshinePassword)) {
        throw (New-EpicVMProvisioningError -Code 'invalid_console_credentials' -Message 'Guest and Sunshine credentials are required.' -Status 400)
    }
    $configureSunshine = Get-EpicVMProperty -Object $State.Provider -Name 'ConfigureSunshine' -Default $null
    if ($null -eq $configureSunshine) {
        throw (New-EpicVMProvisioningError -Code 'sunshine_setup_unavailable' -Message 'Automatic Sunshine setup is unavailable.' -Status 503)
    }
    try {
        # This endpoint is deliberately stage-limited: guest setup and
        # Tailscale enrollment already completed before streaming_setup. A
        # console retry must not recreate the account, rerun bootstrap cleanup,
        # or consume another enrollment key. The supplied guest credential is
        # used only for the stage-limited management handoff/repair and
        # Sunshine setup, and neither credential is assigned to the persisted
        # job or returned to the caller.
        $sunshineResult = Invoke-EpicVMConfigureSunshineProvider -Invoker $configureSunshine -State $State -Job $Job -GuestUsername $guestUsername -GuestPassword $guestPassword -SunshineUsername $sunshineUsername -SunshinePassword $sunshinePassword
        if($null -ne $sunshineResult){
            $transport=[string](Get-EpicVMProperty -Object $sunshineResult -Name 'managementTransport' -Default '')
            if(-not [string]::IsNullOrWhiteSpace($transport)){$Job.managementTransport=$transport}
            if([bool](Get-EpicVMProperty -Object $sunshineResult -Name 'managementReady' -Default $false)){$Job.managementReadyAt=[DateTime]::UtcNow.ToString('o')}
            if([string]$Job.profile -ieq 'omarchy') {
                $guestValidation = Get-EpicVMProperty -Object $sunshineResult -Name 'guestValidation' -Default $null
                if(-not [bool](Get-EpicVMProperty -Object $sunshineResult -Name 'hardwareEncoder' -Default $false) -or
                   $null -eq $guestValidation -or -not [bool](Get-EpicVMProperty -Object $guestValidation -Name 'ok' -Default $false)) {
                    throw (New-EpicVMProvisioningError -Code 'omarchy_encoder_unavailable' -Message 'The Omarchy Sunshine hardware encoder and accelerated renderer were not verified.' -Status 422 -DetailCode 'OMARCHY_SUNSHINE_ENCODER')
                }
                $Job.guestUsername = $guestUsername
                $Job.guestOs = 'Omarchy Linux'
                $Job.omarchyGpuValidated = $true
                $Job.omarchyValidationAt = if([string]::IsNullOrWhiteSpace([string]$Job.omarchyValidationAt)){[DateTime]::UtcNow.ToString('o')}else{$Job.omarchyValidationAt}
                $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('omarchy_gpu')))
            }
            if([string]$Job.profile -ieq 'gaming') {
                if(-not [bool](Get-EpicVMProperty -Object $sunshineResult -Name 'gamingCaptureConfigured' -Default $false)) {
                    throw (New-EpicVMProvisioningError -Code 'gaming_capture_configuration_required' -Message 'The Gaming Sunshine capture target was not verified.' -Status 422 -DetailCode 'GAMING_GPU_ENCODER')
                }
                $Job.gamingCaptureConfigured=$true
                $captureAt=[string](Get-EpicVMProperty -Object $sunshineResult -Name 'gamingCaptureAt' -Default '')
                $Job.gamingCaptureAt=if([string]::IsNullOrWhiteSpace($captureAt)){[DateTime]::UtcNow.ToString('o')}else{$captureAt}
            }
        }
        elseif([string]$Job.profile -ieq 'gaming') {
            throw (New-EpicVMProvisioningError -Code 'gaming_capture_configuration_required' -Message 'The Gaming Sunshine capture target was not verified.' -Status 422 -DetailCode 'GAMING_GPU_ENCODER')
        }
        if ($readyReconcile) {
            $Job.state = 'ready'
            $Job.failureStage = $null
            $Job.consoleRepairOutcome = 'ready'
            $Job.consoleRepairErrorCode = $null
        }
        $Job.errorCode = $null
        $Job.errorMessage = $null
        $Job.failureDetailCode = $null
        $Job.lastAttemptCode = $null
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
    }
    catch {
        $code = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'sunshine_setup_failed')
        $detail = [string](Get-EpicVMProperty -Object $_.Exception -Name 'FailureDetailCode' -Default '')
        if ($readyReconcile) {
            # A repair is not a provisioning transition. Preserve the ready
            # checkpoint and expose only a safe retry diagnostic; the dashboard
            # may attempt reconciliation again without sending the VM through
            # the failed-streaming state machine.
            $Job.state = if ($reconcileState -eq 'ready') { 'ready' } else { 'setup_failed:streaming' }
            $Job.failureStage = if ($reconcileState -eq 'ready') { $null } else { 'streaming' }
            $Job.errorCode = if ($reconcileState -eq 'ready') { $null } else { $code }
            $Job.errorMessage = if ($reconcileState -eq 'ready') { $null } else { 'Automatic Sunshine setup failed; the VM and stopped console data were retained.' }
            $Job.failureDetailCode = $null
            $Job.lastAttemptCode = $code
            $Job.consoleRepairOutcome = 'failed'
            $Job.consoleRepairErrorCode = $code
        }
        else {
            $Job.state = 'setup_failed:streaming'
            $Job.failureStage = 'streaming'
            $Job.errorCode = $code
            if ($script:EpicVMProvisioningFailureDetailCodes -contains $detail) { $Job.failureDetailCode = $detail } else { $Job.failureDetailCode = $null }
            $Job.errorMessage = 'Automatic Sunshine setup failed; the VM and stopped console data were retained.'
        }
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw (New-EpicVMProvisioningError -Code $code -Message 'Automatic Sunshine setup failed.' -Status 422 -DetailCode $detail)
    }
    finally {
        $guestUsername = $guestPassword = $sunshineUsername = $sunshinePassword = $null
    }
}

function Set-EpicVMProvisioningConsoleFailed {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Job, [Parameter(Mandatory)] [object] $Request)
    if ($Job.state -notin @('streaming_setup', 'setup_failed:streaming')) {
        throw (New-EpicVMProvisioningError -Code 'console_failure_not_allowed' -Message 'The job is not awaiting console configuration.' -Status 409)
    }
    $code = [string](Get-EpicVMProperty -Object $Request -Name 'code' -Default 'console_failed')
    if ($code -notmatch '^[a-z][a-z0-9_]{2,63}$') { $code = 'console_failed' }
    $Job.state = 'setup_failed:streaming'
    $Job.failureStage = 'streaming'
    $Job.errorCode = $code
    $Job.errorMessage = 'Console configuration failed; the VM and stopped console data were retained.'
    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-EpicVMProvisioningStore -Store $State.Provisioning
}

function Complete-EpicVMProvisioningConsole {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Job, [Parameter(Mandatory)] [object] $Request)
    if ($Job.state -notin @('streaming_setup', 'setup_failed:streaming', 'setup_failed:agent_restart', 'ready')) {
        throw (New-EpicVMProvisioningError -Code 'console_complete_not_allowed' -Message 'The job is not awaiting console verification.' -Status 409)
    }
    $expectedRoute = '/vm/' + $Job.name + '/'
    $route = [string](Get-EpicVMProperty -Object $Request -Name 'routePrefix' -Default '')
    $scopedRoutePattern = '^/vm/' + [regex]::Escape([string]$Job.name) + '--[a-z0-9][a-z0-9._-]{0,62}/$'
    $routeAllowed = ($route -ceq $expectedRoute) -or ($route -cmatch $scopedRoutePattern)
    $serverVerified = [bool](Get-EpicVMProperty -Object $Request -Name 'guestTcpVerified' -Default $false)
    if (-not $routeAllowed -or -not $serverVerified) {
        throw (New-EpicVMProvisioningError -Code 'console_verification_failed' -Message 'The kvm2 console evidence is incomplete.' -Status 422)
    }
    # Optional quantified diagnostics: when a caller supplies browser frame
    # metrics they must be genuine (never black, frozen, or static video).
    # Automatic provisioning sends none, so absent metrics never block the
    # trusted automated readiness transition.
    $metrics = Get-EpicVMProperty -Object $Request -Name 'frameMetrics' -Default $null
    $hasMetrics = $false
    if ($null -ne $metrics) {
        foreach ($metricName in @('nonblackFraction','meanLuma','stdDev','decodedFramesDelta','durationMs')) {
            $rawMetric = Get-EpicVMProperty -Object $metrics -Name $metricName -Default $null
            if ($null -ne $rawMetric -and [string]$rawMetric -ne '') { $hasMetrics = $true; break }
        }
    }
    if ($hasMetrics) {
        foreach ($entry in @(
            @{ Name='nonblackFraction'; Min=0.20; Max=1.0 },
            @{ Name='meanLuma'; Min=12.0; Max=252.0 },
            @{ Name='decodedFramesDelta'; Min=3.0; Max=[double]::MaxValue },
            @{ Name='durationMs'; Min=1500.0; Max=[double]::MaxValue })) {
            $raw = Get-EpicVMProperty -Object $metrics -Name $entry.Name -Default $null
            try { $value = [double]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture) } catch { $value = [double]::NaN }
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt [double]$entry.Min -or $value -gt [double]$entry.Max) {
                throw (New-EpicVMProvisioningError -Code 'frame_evidence_rejected' -Message ("Quantified frame evidence failed the '{0}' readiness threshold." -f $entry.Name) -Status 422)
            }
        }
        $stdRaw = Get-EpicVMProperty -Object $metrics -Name 'stdDev' -Default $null
        try { $stdDev = [double]::Parse([string]$stdRaw, [Globalization.CultureInfo]::InvariantCulture) } catch { $stdDev = [double]::NaN }
        if ([double]::IsNaN($stdDev) -or [double]::IsInfinity($stdDev) -or $stdDev -lt 8.0 -or $stdDev -gt 127.5) {
            throw (New-EpicVMProvisioningError -Code 'frame_evidence_rejected' -Message "Quantified frame evidence failed the 'stdDev' readiness threshold." -Status 422)
        }
    }
    if ([string]$Job.profile -ieq 'gaming' -and -not $hasMetrics) {
        throw (New-EpicVMProvisioningError -Code 'frame_evidence_required' -Message 'Decoded browser video evidence is required for Gaming VM readiness.' -Status 422)
    }
    if ([string]$Job.profile -ieq 'gaming' -and -not [bool](Get-EpicVMProperty -Object $Job -Name 'gamingCaptureConfigured' -Default $false)) {
        throw (New-EpicVMProvisioningError -Code 'gaming_capture_configuration_required' -Message 'The Gaming Sunshine capture target was not verified.' -Status 422 -DetailCode 'GAMING_GPU_ENCODER')
    }
    $isOmarchy = [string]$Job.profile -ieq 'omarchy'
    if ($isOmarchy -and -not [bool](Get-EpicVMProperty -Object $Job -Name 'omarchyGpuValidated' -Default $false)) {
        throw (New-EpicVMProvisioningError -Code 'omarchy_gpu_validation_failed' -Message 'Omarchy accelerated rendering and hardware encoding have not been verified.' -Status 422 -DetailCode 'OMARCHY_GPU_DEVICE_MISSING')
    }
    $Job.state = 'streaming_setup'
    $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-EpicVMProvisioningStore -Store $State.Provisioning
    $verify = Get-EpicVMProperty -Object $State.Provider -Name 'VerifyGuest' -Default $null
    $verified = $false
    if ($null -ne $verify) {
        if ($isOmarchy) { $verified = [bool](& $verify $Job.name $Job.tailnetIp ([string]$Job.guestUsername)) }
        else { $verified = [bool](& $verify $Job.name $Job.tailnetIp) }
    }
    if (-not $verified) {
        $Job.state = 'setup_failed:streaming'
        $Job.failureStage = 'streaming'
        $Job.errorCode = 'guest_reverification_failed'
        $Job.errorMessage = if ($isOmarchy) { 'The Omarchy guest did not pass credential-free Tailscale SSH readiness verification.' } else { 'The guest did not pass credential-free RDP reachability verification.' }
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw (New-EpicVMProvisioningError -Code 'guest_reverification_failed' -Message 'Guest verification failed.' -Status 422)
    }
    if ($isOmarchy) {
        $cleanup = Get-EpicVMProperty -Object $State.Provider -Name 'CleanupOmarchyBootstrap' -Default $null
        $cleanupOk = $false
        try {
            if ($null -ne $cleanup) {
                $cleanupResult = & $cleanup $Job.name ([string]$Job.guestUsername) ([string]$Job.tailnetIp)
                $cleanupOk = $null -ne $cleanupResult -and [bool](Get-EpicVMProperty -Object $cleanupResult -Name 'ok' -Default $false)
            }
        }
        catch { $cleanupOk = $false }
        if (-not $cleanupOk) {
            $Job.state = 'setup_failed:streaming'
            $Job.failureStage = 'streaming'
            $Job.errorCode = 'omarchy_bootstrap_cleanup_failed'
            $Job.errorMessage = 'The Omarchy bootstrap cleanup did not verify; readiness was withheld.'
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-EpicVMProvisioningStore -Store $State.Provisioning
            throw (New-EpicVMProvisioningError -Code 'omarchy_bootstrap_cleanup_failed' -Message 'Omarchy bootstrap cleanup failed.' -Status 422)
        }
    }
    $now = [DateTime]::UtcNow.ToString('o')
    $Job.consoleRoutePrefix = $route
    $Job.consoleVerifiedAt = $now
    $Job.streamValidationVerified = $true
    $Job.consoleFrameVerified = $hasMetrics
    $Job.consoleFrameVerifiedAt = if ($hasMetrics) { $now } else { $null }
    $Job.completedStages = @(Get-EpicVMProvisioningCompletedStages -Value (@($Job.completedStages) + @('streaming_setup','stream_validation')))
    $Job.state = 'ready'
    $Job.failureStage = $null
    $Job.failureDetailCode = $null
    $Job.lastAttemptCode = $null
    $Job.errorCode = $null
    $Job.errorMessage = $null
    $Job.updatedAt = $now
    Save-EpicVMProvisioningStore -Store $State.Provisioning
}

function New-EpicVMDeprovisioningJob {
    param([Parameter(Mandatory)] [object] $State, [Parameter(Mandatory)] [object] $Request)
    $name = [string](Get-EpicVMProperty -Object $Request -Name 'name' -Default '')
    $confirm = [string](Get-EpicVMProperty -Object $Request -Name 'confirmName' -Default '')
    if (-not (Test-EpicVMName $name) -or $confirm -cne $name) {
        throw (New-EpicVMProvisioningError -Code 'confirmation_required' -Message 'Exact VM name confirmation is required.' -Status 400)
    }
    $vm = @(& $State.Provider.GetVMs | Where-Object {
        [string](Get-EpicVMProperty -Object $_ -Name 'name' -Default '') -ceq $name
    }) | Select-Object -First 1
    if ($null -eq $vm -or -not [bool](Get-EpicVMProperty -Object $vm -Name 'managed' -Default $false)) {
        throw (New-EpicVMProvisioningError -Code 'ownership_required' -Message 'The VM is not an EpicVM-managed resource.' -Status 403)
    }
    $job = New-EpicVMProvisioningJobObject -Id ([guid]::NewGuid().ToString('N')) -Name $name -Profile 'standard'
    $State.Provisioning.Deprovisioning[$job.id] = $job
    Save-EpicVMProvisioningStore -Store $State.Provisioning
    try {
        # Use the newest record for this exact VM name.  Older pilot attempts
        # may carry a device ID for a different enrollment; selecting the
        # first dictionary entry could revoke an unrelated device and block
        # teardown before the owned VM is removed.
        $provisioned = @($State.Provisioning.Jobs.Values |
            Where-Object { [string]$_.name -ceq $name } |
            Sort-Object -Property @{ Expression = {
                        try { [DateTime]::Parse([string]$_.updatedAt) }
                        catch { [DateTime]::MinValue }
                    }; Descending = $true } |
            Select-Object -First 1)
        $deviceId = [string](Get-EpicVMProperty -Object $vm -Name 'tailnetDeviceId' -Default '')
        $routePrefix = [string](Get-EpicVMProperty -Object $vm -Name 'consoleRoutePrefix' -Default '')
        if ($provisioned.Count -gt 0) {
            if (-not $deviceId) { $deviceId = [string](Get-EpicVMProperty -Object $provisioned[0] -Name 'tailnetDeviceId' -Default '') }
            if (-not $routePrefix) { $routePrefix = [string](Get-EpicVMProperty -Object $provisioned[0] -Name 'consoleRoutePrefix' -Default '') }
        }
        $console = Get-EpicVMProperty -Object $State.Provider -Name 'TeardownConsole' -Default $null
        # A failed guest claim never reaches the console gate, so there is no
        # route to tear down. Calling the remote orchestrator in that state
        # turns an otherwise safe, idempotent VM cleanup into a false failure.
        if ($null -ne $console -and -not [string]::IsNullOrWhiteSpace($routePrefix)) { & $console $name $confirm $deviceId | Out-Null }
        $revoke = Get-EpicVMProperty -Object $State.Provider -Name 'RevokeTailscale' -Default $null
        if ($null -ne $revoke) { & $revoke $deviceId | Out-Null }
        # Re-enrollments leave older control-plane records under the same
        # hostname; sweep them so deprovisioning does not leak devices.
        try {
            $prune = Get-EpicVMProperty -Object $State.Provider -Name 'ClearTailscaleStaleDevices' -Default $null
            if ($null -ne $prune) { & $prune $name $deviceId | Out-Null }
        } catch { }
        if ([string](Get-EpicVMProperty -Object $vm -Name 'state' -Default '') -ieq 'Running') { & $State.Provider.StopVM $name | Out-Null }
        & $State.Provider.DeleteVM $name | Out-Null
        $quarantine = Get-EpicVMProperty -Object $State.Provider -Name 'QuarantineVM' -Default $null
        if ($null -eq $quarantine) { throw (New-EpicVMProvisioningError -Code 'quarantine_unavailable' -Message 'Quarantine is unavailable.' -Status 503) }
        $quarantineResult = & $quarantine $name
        $job.state = 'quarantined'
        $job.quarantineUntil = [string](Get-EpicVMProperty -Object $quarantineResult -Name 'quarantineUntil' -Default ([DateTime]::UtcNow.AddDays(7).ToString('o')))
        $job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
    }
    catch {
        $job.state = 'failed'
        $job.errorCode = [string](Get-EpicVMProperty -Object $_.Exception -Name 'ErrorCode' -Default 'deprovisioning_failed')
        $job.errorMessage = 'Teardown was not completed.'
        $job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-EpicVMProvisioningStore -Store $State.Provisioning
        throw (New-EpicVMProvisioningError -Code $job.errorCode -Message 'Teardown was not completed.' -Status 422)
    }
    return $job
}
