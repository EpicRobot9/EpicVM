import test from 'node:test'
import assert from 'node:assert/strict'
import {
  canUseRemotePlacement,
  createPlacementPayload,
  getEligibleRemoteHosts,
  getPlacementValidationReason,
  hostOptionLabel,
  normalizeHostInventory,
  provisioningProfileDisabledReason,
  remotePlacementDisabledReason
} from '../src/lib/hostPlacement.js'

const hosts = [
  {
    id: 'offline-pc',
    display_name: 'Offline PC',
    platform: 'windows',
    provider: 'hyperv',
    online: false,
    capabilities: { create_vm: true }
  },
  {
    id: 'no-create-pc',
    display_name: 'No Create PC',
    platform: 'windows',
    provider: 'hyperv',
    online: true,
    capabilities: { create_vm: false }
  },
  {
    id: 'epic-pc',
    display_name: 'Epic PC',
    platform: 'windows',
    provider: 'hyperv',
    online: true,
    capabilities: { create_vm: true, provisioning: true },
    resources: {
      memory_available_bytes: 17179869184,
      storage_free_bytes: 536870912000
    }
  }
]

test('remote placement is disabled when no capable host is online', () => {
  const unavailableHosts = hosts.slice(0, 2)

  assert.equal(canUseRemotePlacement(unavailableHosts), false)
  assert.equal(remotePlacementDisabledReason(unavailableHosts), 'No remote hosts connected')
})

test('eligible hosts excludes offline and create-incapable hosts', () => {
  const eligible = getEligibleRemoteHosts(hosts)

  assert.deepEqual(eligible.map(host => host.id), ['epic-pc'])
  assert.match(hostOptionLabel(eligible[0]), /Epic PC/)
  assert.match(hostOptionLabel(eligible[0]), /windows.*hyperv/)
  assert.match(hostOptionLabel(eligible[0]), /RAM 16 GB free/)
  assert.match(hostOptionLabel(eligible[0]), /disk 500 GB free/)
})

test('eligible hosts excludes a host whose template or OAuth prerequisites are not ready', () => {
  const notReady = [{ id: 'not-ready', kind: 'remote', online: true, capabilities: { create_vm: true, provisioning: false } }]
  assert.deepEqual(getEligibleRemoteHosts(notReady), [])
})

test('host inventory accepts the normalized API envelope and host aliases', () => {
  const normalized = normalizeHostInventory({ hosts: [{ host_id: 'lab-pc', name: 'Lab PC', online: true }] })

  assert.deepEqual(normalized, [{ host_id: 'lab-pc', name: 'Lab PC', online: true, id: 'lab-pc', display_name: 'Lab PC' }])
})

test('create payload defaults to local for compatibility', () => {
  assert.deepEqual(createPlacementPayload({ name: ' Alpha ' }), {
    name: 'alpha',
    placement: 'local',
    host_id: 'local'
  })
})

test('remote create payload and validation require an eligible selected host', () => {
  assert.deepEqual(createPlacementPayload({ name: 'alpha', placement: 'remote', hostId: 'epic-pc' }), {
    name: 'alpha',
    placement: 'remote',
    host_id: 'epic-pc'
  })
  assert.equal(getPlacementValidationReason({ placement: 'remote', hostId: 'offline-pc', hosts }), 'Selected remote host is no longer available')
  assert.equal(getPlacementValidationReason({ placement: 'remote', hostId: 'epic-pc', hosts }), '')
})

test('Omarchy host placement is independent from the Windows provisioning gate', () => {
  const omarchyOnly = [{
    id: 'linux-pilot',
    display_name: 'Linux Pilot',
    platform: 'windows',
    provider: 'hyperv',
    online: true,
    capabilities: { create_vm: true, provisioning: false, omarchy_provisioning: true }
  }]

  assert.equal(canUseRemotePlacement(omarchyOnly), true)
  assert.equal(getPlacementValidationReason({ placement: 'remote', hostId: 'linux-pilot', hosts: omarchyOnly, profile: 'standard' }), 'Selected remote host is no longer available')
  assert.equal(getPlacementValidationReason({ placement: 'remote', hostId: 'linux-pilot', hosts: omarchyOnly, profile: 'omarchy' }), '')
  assert.equal(provisioningProfileDisabledReason(omarchyOnly[0], 'omarchy'), '')
  assert.match(provisioningProfileDisabledReason(omarchyOnly[0], 'standard'), /Standard provisioning unavailable/)
})
