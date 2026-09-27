import test from 'node:test'
import assert from 'node:assert/strict'
import { canClaimProvisioningJob, canOpenInventoryVm, canOpenProvisionedVm, canRetryProvisioningConsole, deprovisioningPayload, gamingPartitionPayload, provisioningClaimPayload, provisioningConsoleRetryPayload, provisioningCreatePayload, provisioningFailureReason, provisioningProgress } from '../src/lib/provisioningUi.js'

test('claim and open gates are state-specific', () => {
  assert.equal(canClaimProvisioningJob({ state:'unclaimed' }), true)
  assert.equal(canClaimProvisioningJob({ state:'ready' }), false)
  assert.equal(canOpenProvisionedVm({ state:'ready' }), true)
  assert.equal(canOpenProvisionedVm({ state:'verifying' }), false)
  assert.equal(canOpenInventoryVm({ provisioningState:'guest_setup' }), false)
  assert.equal(canOpenInventoryVm({ provisioningState:'ready' }), true)
  assert.equal(canRetryProvisioningConsole({ state:'setup_failed:streaming' }), true)
})

test('progress is monotonic across the approved state sequence', () => {
  assert.equal(provisioningProgress({ state:'queued' }), 0)
  assert.equal(provisioningProgress({ state:'unclaimed' }) > provisioningProgress({ state:'cloning' }), true)
  assert.equal(provisioningProgress({ state:'ready' }), 100)
})

test('claim payload keeps the token in the request boundary and teardown requires exact name', () => {
  assert.deepEqual(provisioningClaimPayload({ hostId:'epic-pc', username:'operator', password:'transient-password', claimToken:'one-use' }), {
    host_id:'epic-pc', username:'operator', password:'transient-password', claimToken:'one-use'
  })
  assert.deepEqual(deprovisioningPayload({ hostId:'epic-pc', name:' Alpha ' }), { host_id:'epic-pc', name:'alpha', confirmName:'alpha' })
  assert.deepEqual(provisioningConsoleRetryPayload({ hostId:'epic-pc', username:'operator', password:'transient-password' }), {
    host_id:'epic-pc', username:'operator', password:'transient-password'
  })
  assert.deepEqual(provisioningCreatePayload({ hostId:'epic-pc', name:' Alpha ', profile:'standard', mode:'claim' }), {
    host_id:'epic-pc', name:'alpha', profile:'standard', mode:'claim'
  })
  assert.deepEqual(provisioningCreatePayload({ hostId:'epic-pc', name:' Alpha ', mode:'unknown' }), {
    host_id:'epic-pc', name:'alpha', profile:'standard', mode:'automatic'
  })
  assert.deepEqual(provisioningClaimPayload({ hostId:'epic-pc', username:'operator', password:'transient-password', claimToken:'one-use', sunshineUsername:'ignored', sunshinePassword:'ignored' }), {
    host_id:'epic-pc', username:'operator', password:'transient-password', claimToken:'one-use'
  })
})

test('Gaming create payload carries initialization resources but standard payload stays unchanged', () => {
  assert.deepEqual(provisioningCreatePayload({ hostId:'epic-pc', name:' gamer ', profile:'gaming', mode:'claim', cpuCount:'8', memoryGiB:'16', diskSizeGiB:'256', gpuPartitionPercent:'65' }), {
    host_id:'epic-pc', name:'gamer', profile:'gaming', mode:'claim', cpuCount:8, memoryGiB:16, diskSizeGiB:256, gpuPartitionPercent:65
  })
  assert.deepEqual(provisioningCreatePayload({ hostId:'epic-pc', name:'standard', profile:'standard', cpuCount:16, memoryGiB:16, diskSizeGiB:512, gpuPartitionPercent:90 }), {
    host_id:'epic-pc', name:'standard', profile:'standard', mode:'automatic'
  })
  assert.deepEqual(gamingPartitionPayload({ hostId:'epic-pc', percent:'72' }), { host_id:'epic-pc', percent:72 })
  assert.deepEqual(gamingPartitionPayload({ hostId:'epic-pc', percent:999 }), { host_id:'epic-pc', percent:100 })
})

test('Omarchy create payload carries AMD GPU-P resources and remains explicitly experimental', () => {
  assert.deepEqual(provisioningCreatePayload({ hostId:'linux-pilot', name:' omarchy ', profile:'omarchy', mode:'claim', cpuCount:'8', memoryGiB:'16', diskSizeGiB:'256', gpuPartitionPercent:'65' }), {
    host_id:'linux-pilot', name:'omarchy', profile:'omarchy', mode:'claim', cpuCount:8, memoryGiB:16, diskSizeGiB:256, gpuPartitionPercent:65
  })
  assert.match(provisioningFailureReason({ profile:'omarchy', errorCode:'omarchy_not_validated' }), /experimental/)
  assert.match(provisioningFailureReason({ profile:'omarchy', errorCode:'omarchy_encoder_unavailable' }), /hardware encoder.*Omarchy Linux/i)
  assert.match(provisioningFailureReason({ profile:'omarchy', errorCode:'guest_account_failed', failureDetailCode:'admin_membership_failed' }), /Linux wheel membership/i)
})

test('safe provisioning failure codes explain the failed trust boundary', () => {
  assert.equal(provisioningFailureReason({ errorCode:'powershell_direct_failed' }), 'PowerShell Direct could not open the cloned guest.')
  assert.equal(provisioningFailureReason({ errorCode:'rdp_verification_failed' }), 'Guest RDP/NLA/firewall verification failed.')
  assert.equal(provisioningFailureReason({ errorCode:'guest_account_failed' }), 'Windows guest-account setup failed after the claim was consumed.')
  assert.equal(provisioningFailureReason({ errorCode:'guest_account_failed', failureDetailCode:'admin_membership_failed' }), 'Windows guest-account setup failed after the claim was consumed. Administrator membership could not be verified.')
  assert.equal(provisioningFailureReason({ errorCode:'guest_account_failed', failureDetailCode:'raw-secret' }), 'Windows guest-account setup failed after the claim was consumed.')
  assert.equal(provisioningFailureReason({ errorCode:'secret_leaked' }), '')
})
