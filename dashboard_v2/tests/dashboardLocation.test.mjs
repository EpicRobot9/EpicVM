import test from 'node:test'
import assert from 'node:assert/strict'

import { dashboardBasename } from '../src/lib/dashboardLocation.js'

test('uses the public dashboard basename for its root and child routes', () => {
  assert.equal(dashboardBasename('/Dashboard'), '/Dashboard')
  assert.equal(dashboardBasename('/Dashboard/'), '/Dashboard')
  assert.equal(dashboardBasename('/Dashboard/vm'), '/Dashboard')
})

test('uses the mounted EpicVM basename for canonical and unknown paths', () => {
  assert.equal(dashboardBasename('/EpicVM/Dashboard'), '/EpicVM/Dashboard')
  assert.equal(dashboardBasename('/EpicVM/Dashboard/vm'), '/EpicVM/Dashboard')
  assert.equal(dashboardBasename('/'), '/EpicVM/Dashboard')
})
