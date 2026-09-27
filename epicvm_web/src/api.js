// EpicVM web API client. All endpoints are same-origin under /EpicVM/api or /portal/api.
const PORTAL = '/portal'
const EPICVM = '/EpicVM/api'

function hostQuery(hostId) {
  const host = String(hostId || '').trim()
  return host && host !== 'local' ? `?host_id=${encodeURIComponent(host)}` : ''
}

async function apiFetch(path, opts = {}) {
  const { timeoutMs = 15000, ...fetchOptions } = opts
  const controller = new AbortController()
  const timer = window.setTimeout(() => controller.abort(), timeoutMs)
  let res
  try {
    res = await fetch(path, {
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      ...fetchOptions,
      signal: fetchOptions.signal || controller.signal,
    })
  } finally {
    window.clearTimeout(timer)
  }
  let body = {}
  try { body = await res.json() } catch { /* ignore */ }
  return { ok: res.ok, status: res.status, body }
}

export async function signup({ username, password, displayName, email, who }) {
  return apiFetch(`${EPICVM}/signup`, {
    method: 'POST',
    body: JSON.stringify({ username, password, displayName, email, who }),
  })
}

export async function login(username, password) {
  const res = await apiFetch(`${PORTAL}/api/auth/login`, {
    method: 'POST',
    body: JSON.stringify({ username, password }),
  })
  return res
}

export async function logout() {
  return apiFetch(`${PORTAL}/api/auth/logout`, { method: 'POST' })
}

export async function me() {
  const res = await apiFetch(`${EPICVM}/me`)
  return res.body && res.body.authenticated ? res.body : null
}

// Portal VM list for an approved user (used by the portal-redirect status view).
export async function myVms() {
  return apiFetch(`${PORTAL}/api/vms`)
}

export async function startVm(name, hostId, resourceKey) {
  return apiFetch(`${PORTAL}/api/start/${encodeURIComponent(name)}${hostQuery(hostId)}`, {
    method: 'POST', body: JSON.stringify({ hostId, resourceKey }),
  })
}
export async function stopVm(name, hostId, resourceKey) {
  return apiFetch(`${PORTAL}/api/stop/${encodeURIComponent(name)}${hostQuery(hostId)}`, {
    method: 'POST', body: JSON.stringify({ hostId, resourceKey }),
  })
}
export async function restartVm(name, hostId, resourceKey, resourceType) {
  if (resourceType === 'cloudpc') return { ok: false, status: 409, body: { error: 'Cloud PC restart is not a physical power cycle and is unsupported.' } }
  // No dedicated backend endpoint; restart = stop, wait for it to actually stop, then start.
  const s = await stopVm(name, hostId, resourceKey)
  if (!s.ok) return s
  // Poll the VM status until it reports stopped/offline (or timeout), so start
  // doesn't race a still-shutting-down container on slow hosts.
  const deadline = Date.now() + 30000
  let stopped = false
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1500))
    try {
      const st = await apiFetch(`${PORTAL}/api/vm/${encodeURIComponent(name)}/status${hostQuery(hostId)}`)
      const state = (st.body && (st.body.state || st.body.status) || '').toLowerCase()
      if (state === 'stopped' || state === 'off' || state === 'offline' || state === 'exited' || state === 'dead') { stopped = true; break }
    } catch { /* ignore, keep waiting */ }
  }
  if (!stopped) return { ok: false, status: 409, body: { error: 'Stop did not complete before the restart timeout. The VM was not started again.' } }
  return startVm(name, hostId, resourceKey)
}

// --- Cloud PC (bring-your-own Sunshine over Tailscale) ---
export async function addCloudPc({ displayName, tailnetIp, sunshineUsername, sunshinePassword }) {
  return apiFetch(`${PORTAL}/api/cloudpc`, {
    method: 'POST',
    body: JSON.stringify({
      displayName,
      tailnetIp,
      sunshineUsername: sunshineUsername || '',
      sunshinePassword: sunshinePassword || '',
    }),
  })
}

export async function pairCloudPc(name, { sunshineUsername, sunshinePassword }) {
  return apiFetch(`${PORTAL}/api/cloudpc/${encodeURIComponent(name)}/pair`, {
    method: 'POST',
    body: JSON.stringify({
      sunshineUsername: sunshineUsername || '',
      sunshinePassword: sunshinePassword || '',
    }),
  })
}
