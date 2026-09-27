export const PROVISIONING_STATES = ['queued','cloning','booting','unclaimed','claim_in_progress','guest_setup','network_setup','management_handoff','gaming_gpu_validation','omarchy_gpu_validation','streaming_setup','stream_validation','ready']
export const PROVISIONING_MODES = ['automatic','claim']

export function canClaimProvisioningJob(job){
  return String(job?.state || '') === 'unclaimed'
}

export function canOpenProvisionedVm(job){
  return String(job?.state || '') === 'ready'
}

export function canRetryProvisioningConsole(job){
  return String(job?.state || '') === 'setup_failed:streaming'
}

export function canOpenInventoryVm(vm){
  const state = String(vm?.provisioningState || '')
  return !state || state === 'ready'
}

export function provisioningProgress(job){
  const state = String(job?.state || 'queued')
  if(state === 'ready') return 100
  if(state.startsWith('setup_failed:')) return 75
  const index = Math.max(0, PROVISIONING_STATES.indexOf(state))
  return Math.round((index / (PROVISIONING_STATES.length - 1)) * 100)
}

export function provisioningCreatePayload({ hostId, name, profile = 'standard', mode = 'automatic', cpuCount = 6, memoryGiB = 12, diskSizeGiB = 128, gpuPartitionPercent = 50 } = {}){
  const safeMode = PROVISIONING_MODES.includes(String(mode || '').toLowerCase()) ? String(mode).toLowerCase() : 'automatic'
  const safeProfile = String(profile || 'standard').trim().toLowerCase()
  const payload = {
    host_id:String(hostId || ''),
    name:String(name || '').trim().toLowerCase(),
    profile:safeProfile,
    mode:safeMode,
  }
  if(safeProfile === 'gaming' || safeProfile === 'omarchy'){
    payload.cpuCount = normalizeGamingInteger(cpuCount, 6, 1, 16)
    payload.memoryGiB = normalizeGamingInteger(memoryGiB, 12, 1, 16)
    payload.diskSizeGiB = normalizeGamingInteger(diskSizeGiB, 128, 1, 512)
    payload.gpuPartitionPercent = normalizeGamingInteger(gpuPartitionPercent, 50, 1, 100)
  }
  return payload
}

function normalizeGamingInteger(value, fallback, min, max){
  const parsed = Number.parseInt(String(value ?? ''), 10)
  if(!Number.isFinite(parsed)) return fallback
  return Math.max(min, Math.min(max, parsed))
}

export function gamingPartitionPayload({ hostId, percent } = {}){
  return {
    host_id:String(hostId || ''),
    percent:normalizeGamingInteger(percent, 50, 1, 100),
  }
}

export function provisioningClaimPayload({ hostId, username, password, claimToken } = {}){
  const payload = { host_id:String(hostId || ''), username:String(username || ''), password:String(password || ''), claimToken:String(claimToken || '') }
  return payload
}

export function provisioningFailureReason(job){
  const code = String(job?.errorCode || '').trim().toLowerCase()
  const isOmarchy = String(job?.profile || '').trim().toLowerCase() === 'omarchy'
  const reasons = {
    bootstrap_credential_unavailable: 'The machine bootstrap channel was unavailable.',
    bootstrap_readiness_unavailable: 'The host lacks the secure guest-readiness check.',
    guest_bootstrap_not_ready: 'The cloned guest did not become ready for secure setup.',
    powershell_direct_failed: 'PowerShell Direct could not open the cloned guest.',
    direct_service_disabled: 'The Hyper-V PowerShell Direct service is disabled.',
    direct_service_not_ready: 'The Hyper-V PowerShell Direct service was not ready; no credential conclusion was made.',
    direct_not_supported: 'PowerShell Direct is not available on this host.',
    direct_open_timeout: 'PowerShell Direct did not open before the bounded timeout.',
    direct_transport_error: 'The PowerShell Direct transport failed; no credential conclusion was made.',
    guest_credential_rejected: 'The guest channel explicitly rejected the supplied credential.',
    rdp_verification_failed: 'Guest RDP/NLA/firewall verification failed.',
    guest_configuration_failed: 'Guest configuration failed at the secure setup gate.',
    invalid_credential_input: 'The credential input is empty or does not meet the request policy.',
    claim_in_progress: 'Another request already owns this claim.',
    claim_atomic_commit_failed: 'The claim could not be committed safely; no guest work was started.',
    guest_configuration_unavailable: 'The secure guest configuration channel is unavailable; no claim was consumed.',
    guest_account_failed: isOmarchy ? 'Linux guest-account setup failed after the claim was consumed.' : 'Windows guest-account setup failed after the claim was consumed.',
    guest_account_readiness_failed: isOmarchy ? 'The desired Linux account did not pass readiness verification.' : 'The desired Windows account did not pass readiness verification.',
    bootstrap_cleanup_failed: 'Guest bootstrap cleanup did not verify.',
    bootstrap_cleanup_transport_failed: 'The guest bootstrap cleanup channel failed.',
    tailscale_enrollment_failed: 'Tailscale guest enrollment failed after guest setup.',
    management_handoff_failed: 'The private management handoff did not verify after Tailscale enrollment.',
    management_transport_failed: 'The private guest management channel failed safely; the VM was retained for diagnosis.',
    management_transport_unavailable: 'The private guest management channel is unavailable; the VM was retained for diagnosis.',
    gaming_guest_validation_failed: 'The Gaming guest GPU validation did not pass.',
    gaming_guest_validation_unavailable: 'The Gaming guest GPU validation channel is unavailable.',
    gaming_gpu_validation_failed: 'The GPU-P guest validation gate failed; the VM was retained for diagnosis.',
    gaming_encoder_unavailable: 'Sunshine did not report an AMD hardware encoder for the Gaming VM.',
    gaming_webgl_unavailable: 'The Gaming guest did not report WebGL hardware acceleration.',
    omarchy_not_validated: 'Omarchy Linux remains experimental until the pinned image, AMD GPU-P path, and accelerated guest pilot are verified.',
    omarchy_provisioning_unavailable: 'Omarchy Linux provisioning is unavailable on this host.',
    omarchy_template_invalid: 'The pinned Omarchy Linux template manifest failed validation.',
    omarchy_bootstrap_not_ready: 'The Omarchy Linux guest did not become reachable over Tailscale SSH.',
    omarchy_guest_configuration_unavailable: 'The Omarchy Linux guest configuration transport is unavailable.',
    omarchy_guest_configuration_failed: 'Omarchy Linux guest configuration failed at the secure setup gate.',
    omarchy_gpu_validation_failed: 'Omarchy accelerated rendering did not pass the AMD GPU-P guest validation gate.',
    omarchy_guest_validation_unavailable: 'The Omarchy AMD GPU and renderer validation channel is unavailable.',
    omarchy_encoder_unavailable: 'Sunshine did not report a working hardware encoder in Omarchy Linux.',
    omarchy_sunshine_configuration_failed: 'Sunshine hardware encoding could not be configured in Omarchy Linux.',
    omarchy_bootstrap_cleanup_failed: 'Omarchy Linux bootstrap cleanup did not verify; readiness was withheld.',
    omarchy_network_recovery_failed: 'Omarchy Linux Tailscale SSH recovery stopped safely; the VM was retained for diagnosis.',
     streaming_setup_failed: 'Moonlight/Sunshine setup failed after guest and network setup.',
     sunshine_invalid_input: 'The Sunshine credential input was rejected before guest setup.',
     sunshine_service_missing: 'The retained guest does not have the pinned Sunshine service.',
     sunshine_executable_missing: 'The pinned Sunshine executable could not be verified in the guest.',
     sunshine_version_mismatch: 'The guest Sunshine version does not match the pinned release.',
     sunshine_state_path_failed: 'The Sunshine state path could not be prepared safely.',
     sunshine_state_write_failed: 'The Sunshine credential state could not be written safely.',
     sunshine_state_acl_failed: 'The Sunshine credential state permissions could not be verified.',
     sunshine_firewall_failed: 'The narrow Sunshine firewall scope could not be applied.',
     sunshine_service_restart_failed: 'The Sunshine service could not be restarted safely.',
     sunshine_listener_failed: 'Sunshine did not pass its service/listener verification.',
     sunshine_verification_failed: 'Sunshine configuration did not pass verification.',
     console_failed: 'The retained console repair failed safely; the VM was retained for diagnosis.',
     host_unavailable: 'The remote host became unavailable while repairing the retained console.',
     legacy_state_uncertain: 'Persisted provisioning checkpoints are inconsistent; the VM was retained for diagnosis.',
  }
  const base = reasons[code] || ''
  if(code === 'gaming_gpu_validation_failed'){
    const detail = String(job?.failureDetailCode || '').trim().toLowerCase()
    if(detail === 'gaming_gpu_frame') return `${base} The guest produced no usable rendered frame; it will not be published as ready.`
    if(detail === 'gaming_gpu_webgl') return `${base} Hardware WebGL did not pass the render gate.`
  }
  if(code === 'guest_account_failed'){
    const detail = String(job?.failureDetailCode || '').trim().toLowerCase()
    const detailReasons = {
      account_create_failed: isOmarchy ? 'The requested Linux account could not be created.' : 'The requested Windows account could not be created.',
      account_update_failed: isOmarchy ? 'The requested Linux account could not be updated.' : 'The requested Windows account could not be updated.',
      account_password_policy_failed: isOmarchy ? 'Linux rejected the password under its local policy.' : 'Windows rejected the password under its local policy.',
      admin_membership_failed: isOmarchy ? 'The Linux wheel membership could not be verified.' : 'Administrator membership could not be verified.',
      account_verification_failed: isOmarchy ? 'The requested Linux account could not be verified after setup.' : 'The requested Windows account could not be verified after setup.',
    }
    if(detailReasons[detail]) return `${base} ${detailReasons[detail]}`
  }
  return base
}

export function provisioningConsoleRetryPayload({ hostId, username, password } = {}){
  return { host_id:String(hostId || ''), username:String(username || ''), password:String(password || '') }
}

export function deprovisioningPayload({ hostId, name } = {}){
  const safeName = String(name || '').trim().toLowerCase()
  return { host_id:String(hostId || ''), name:safeName, confirmName:safeName }
}
