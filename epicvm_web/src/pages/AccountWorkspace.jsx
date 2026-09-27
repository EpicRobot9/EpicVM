import React, { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { Gear, Users, Desktop, ChatCircle, ShieldCheck, ArrowLeft, CheckCircle } from '@phosphor-icons/react'
import './AccountWorkspace.css'
import SharedGames from './SharedGames'
import EpiChat from '../components/EpiChat'

const API = '/EpicVM/api'
const kinds = { vm: 'VM request', feedback: 'Feedback', bug: 'Bug report' }
const label = resource => `${resource.name} · ${resource.hostId || 'unavailable'}`
const provisionStages = [
  ['queued', 'Queued'], ['cloning', 'Clone VM'], ['booting', 'First boot'],
  ['claim', 'Secure claim'], ['guest_setup', 'Guest setup'], ['network_setup', 'Private network'],
  ['management_handoff', 'Management handoff'], ['gaming_gpu_validation', 'GPU validation'],
  ['omarchy_gpu_validation', 'GPU validation'], ['streaming_setup', 'Streaming setup'],
  ['stream_validation', 'Console validation'], ['ready', 'Ready'],
]

function stagesFor(job) {
  const profile = String(job?.profile || 'standard').toLowerCase()
  return provisionStages.filter(([key]) => key !== 'gaming_gpu_validation' && key !== 'omarchy_gpu_validation'
    || key === `${profile}_gpu_validation`)
}

function failedStageFor(job, stages) {
  const code = `${job?.state || ''} ${job?.errorCode || ''}`.toLowerCase()
  const matches = [
    ['stream', 'streaming_setup'], ['console', 'streaming_setup'], ['gpu', String(job?.profile).toLowerCase() === 'omarchy' ? 'omarchy_gpu_validation' : 'gaming_gpu_validation'],
    ['network', 'network_setup'], ['tailscale', 'network_setup'], ['management', 'management_handoff'], ['guest', 'guest_setup'], ['claim', 'claim'], ['clone', 'cloning'], ['boot', 'booting'],
  ]
  return matches.find(([needle, key]) => code.includes(needle) && stages.some(([stage]) => stage === key))?.[1] || stages[Math.max(0, Math.min(stages.length - 1, (job?.completedStages || []).length))]?.[0] || 'queued'
}

async function read(path, options = {}) {
  const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...options })
  const body = await response.json().catch(() => ({}))
  if (!response.ok || body.ok === false) throw new Error(body.error || `Request failed (${response.status}).`)
  return body
}

function Login({ onLogin, management }) {
  const [realm, setRealm] = useState(management ? 'dashboard' : 'portal')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    const fields = new FormData(event.currentTarget)
    try {
      // Choose the credential realm explicitly: identical names are not linked accounts.
      await read(realm === 'dashboard' ? '/Dashboard/api/auth/login' : '/portal/api/auth/login', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: fields.get('username'), password: fields.get('password') })
      })
      // Prevent an older dashboard cookie from masking a newly selected portal identity.
      if (realm === 'portal') await fetch('/Dashboard/api/auth/logout', { method: 'POST', credentials: 'same-origin' })
      await onLogin()
    } catch (err) { setError(err.message) }
    setBusy(false)
  }
  return <section className="aw-card aw-login"><ShieldCheck size={32} /><h1>Welcome to EpicVM</h1>
    <p>Sign in to {management ? 'manage accounts and requests' : 'manage your account'}.</p>
    <form onSubmit={submit}>
      <label>Account type<select value={realm} onChange={e => setRealm(e.target.value)}><option value="portal">EpicVM account</option><option value="dashboard">Dashboard administrator</option></select></label>
      <label>Username<input name="username" autoComplete="username" required /></label>
      <label>Password<input name="password" type="password" autoComplete="current-password" required /></label>
      {error && <p role="alert" className="aw-error">{error}</p>}
      <button className="aw-primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
    </form>
  </section>
}

function TicketForm({ send, onSaved }) {
  const [kind, setKind] = useState('vm')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [requestKey, setRequestKey] = useState(() => crypto.randomUUID())
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    const form = event.currentTarget, fields = new FormData(form)
    try {
      await send('/account/tickets', { kind, title: fields.get('title'), body: fields.get('body'), requestKey })
      form.reset(); setRequestKey(crypto.randomUUID()); await onSaved('Sent. You can track the response below.')
    } catch (err) { setError(err.message) }
    setBusy(false)
  }
  return <section className="aw-card"><h2>How can we help?</h2><p>Requests and reports go directly to your EpicVM administrators.</p>
    <form onSubmit={submit}>
      <label>Type<select value={kind} onChange={e => { setKind(e.target.value); setRequestKey(crypto.randomUUID()) }}><option value="vm">Request a VM</option><option value="feedback">Send feedback</option><option value="bug">Report a bug</option></select></label>
      <label>Subject<input name="title" maxLength={120} placeholder={kind === 'vm' ? 'A Windows VM for development' : 'A short summary'} required /></label>
      <label>{kind === 'vm' ? 'What do you need?' : 'Details'}<textarea name="body" minLength={5} maxLength={6000} rows={5} placeholder={kind === 'vm' ? 'Tell us the operating system, resources, and what you will use it for.' : kind === 'bug' ? 'What happened? What did you expect? Include steps to reproduce, but no passwords or access tokens.' : 'Tell us what could be better.'} required /></label>
      {error && <p role="alert" className="aw-error">{error}</p>}
      <button className="aw-primary" disabled={busy}>{busy ? 'Sending…' : 'Send request or report'}</button>
    </form></section>
}

function PasswordForm({ send, refresh }) {
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    const form = event.currentTarget, fields = new FormData(form)
    try {
      if (fields.get('newPassword') !== fields.get('confirmPassword')) throw new Error('The new passwords do not match.')
      await send('/account/password', { currentPassword: fields.get('currentPassword'), newPassword: fields.get('newPassword') })
      form.reset(); await refresh('Password updated. Your other sessions have been signed out.')
    } catch (err) { setError(err.message) }
    setBusy(false)
  }
  return <section className="aw-card"><h2>Password</h2><p>Choose a unique password with at least 8 characters.</p><form onSubmit={submit}>
    <label>Current password<input name="currentPassword" type="password" autoComplete="current-password" required /></label>
    <label>New password<input name="newPassword" type="password" autoComplete="new-password" minLength={8} maxLength={256} required /></label>
    <label>Confirm new password<input name="confirmPassword" type="password" autoComplete="new-password" minLength={8} maxLength={256} required /></label>
    {error && <p role="alert" className="aw-error">{error}</p>}<button disabled={busy}>{busy ? 'Updating…' : 'Update password'}</button>
  </form></section>
}

function Ticket({ ticket, admin, resources = [], send, onSaved }) {
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  const [status, setStatus] = useState('in_review')
  const [jevBusy, setJevBusy] = useState(false), [advisory, setAdvisory] = useState(null)
  const formRef = useRef(null)
  const closed = ['fulfilled', 'declined', 'resolved'].includes(ticket.status)
  async function askJev(task, extra = {}) {
    setJevBusy(true); setError('')
    try {
      const result = await send('/management/jev/analyze', { task, state: { ticket: { kind: ticket.kind, title: ticket.title, body: ticket.body }, ...extra } })
      setAdvisory(result.advisory)
    } catch (err) { setError(err.message) }
    setJevBusy(false)
  }
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    const fields = new FormData(event.currentTarget)
    try {
      await send(`/management/tickets/${ticket.id}`, { status, response: fields.get('response'), resourceKey: fields.get('resourceKey') })
      await onSaved('Request updated. The response is visible in account settings.')
    } catch (err) { setError(err.message) }
    setBusy(false)
  }
  return <article className="aw-ticket"><div className="aw-row"><span className="aw-eyebrow">{kinds[ticket.kind]}</span><span className={`aw-badge ${closed ? 'closed' : ''}`}>{ticket.status.replaceAll('_', ' ')}</span></div>
    <h3>{ticket.title}</h3>{admin && <p className="aw-meta">{ticket.username} · {ticket.realm === 'portal' ? 'EpicVM account' : 'Dashboard administrator'}</p>}
    <p className="aw-body">{ticket.body}</p><p className="aw-meta">{new Date(ticket.created_at * 1000).toLocaleString()}</p>
    {admin && <div className="aw-jev"><div className="aw-row"><strong>Jev advisory</strong><button type="button" disabled={jevBusy} onClick={() => askJev(ticket.kind === 'vm' ? 'vm_request' : 'ticket_triage')}>{jevBusy ? 'Analyzing…' : 'Analyze request'}</button></div>
      <small>Read-only semantic guidance. It never approves, assigns, closes, or changes a machine.</small>
      {advisory && <div className="aw-jev-results">{Object.entries(advisory.answers || {}).map(([key, answer]) => <span key={key}><b>{key.replaceAll('_', ' ')}</b>{String(answer.choice ?? (answer.score !== undefined ? Number(answer.score).toFixed(1) : `${Math.round(Number(answer.noul || 0) * 100)}%`))}{answer.confidence !== undefined ? ` · ${Math.round(answer.confidence * 100)}% confidence` : ''}</span>)}</div>}
    </div>}
    {ticket.response && <div className="aw-reply"><strong>Administrator response</strong><p>{ticket.response}</p></div>}
    {admin && !closed && <form ref={formRef} onSubmit={submit}>
      <label>Next step<select value={status} onChange={e => setStatus(e.target.value)}><option value="in_review">Reviewing</option>{ticket.kind === 'vm' ? <option value="fulfilled">Accept and assign a VM</option> : <option value="resolved">Resolved</option>}<option value="declined">Declined</option></select></label>
      {status === 'fulfilled' && <label>Assign VM<select name="resourceKey" required defaultValue=""><option value="" disabled>Choose an available VM</option>{resources.filter(r => r.resourceType === 'vm' && r.classification === 'managed' && r.available !== false).map(r => <option key={r.resourceKey} value={r.resourceKey}>{label(r)}</option>)}</select><small>Need a new machine? Create it in the Machines section, then refresh before assigning it.</small></label>}
      <label>Reply<textarea name="response" rows={3} maxLength={3000} required placeholder="Let them know what happens next." /></label>
      <button type="button" disabled={jevBusy} onClick={() => askJev('response_verification', { proposedResponse: formRef.current?.elements?.response?.value || '', evidence: { selectedStatus: status } })}>Check reply with Jev</button>
      {error && <p role="alert" className="aw-error">{error}</p>}<button disabled={busy}>{busy ? 'Saving…' : 'Send update'}</button>
    </form>}
  </article>
}

function UserCard({ user, resources, send, onSaved, self }) {
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  const [grants, setGrants] = useState(() => (user.assignedResources || []).map(r => r.resourceKey))
  const options = new Map(resources.filter(r => r.resourceType === 'vm' && r.classification === 'managed').map(r => [r.resourceKey, r]))
  for (const r of user.assignedResources || []) if (!options.has(r.resourceKey)) options.set(r.resourceKey, { ...r, available: false })
  async function act(action, extra = {}) {
    setBusy(true); setError('')
    try { await send(`/management/users/${encodeURIComponent(user.username)}`, { action, ...extra }); await onSaved('Account updated.') }
    catch (err) { setError(err.message) }
    setBusy(false)
  }
  return <article className="aw-ticket"><div className="aw-row"><h3>{user.username}</h3><span className="aw-badge">{user.disabled ? 'disabled' : user.accountStatus}</span></div>
    <p className="aw-meta">{user.isAdmin ? 'Administrator' : 'Member'}{user.email ? ` · ${user.email}` : ''}</p>{user.who && <p>{user.who}</p>}
    {self ? <p>Manage your password in <Link to="/settings">Settings</Link>. Another administrator can update your account access.</p> : <fieldset disabled={busy}>
      <div className="aw-actions">{user.accountStatus !== 'approved' && <button onClick={() => act('approve')}>Approve account</button>}{user.accountStatus === 'pending' && <button onClick={() => act('reject')}>Reject account</button>}<button onClick={() => act(user.disabled ? 'enable' : 'disable')}>{user.disabled ? 'Enable' : 'Disable'} account</button></div>
      <details><summary>VM assignments · {grants.length}</summary><div className="aw-checks">{[...options.values()].map(r => <label key={r.resourceKey}><input type="checkbox" checked={grants.includes(r.resourceKey)} onChange={e => setGrants(old => e.target.checked ? [...old, r.resourceKey] : old.filter(k => k !== r.resourceKey))} /><span>{label(r)}{r.available === false ? ' · unavailable' : ''}</span></label>)}</div><button onClick={() => act('access', { assignedResources: grants })}>Save assignments</button></details>
      <details><summary>Reset password</summary><form onSubmit={async e => { e.preventDefault(); const form = e.currentTarget; await act('password', { newPassword: new FormData(form).get('newPassword') }); form.reset() }}><label>New password<input name="newPassword" type="password" autoComplete="new-password" minLength={8} maxLength={256} required /></label><small>Other sessions will be signed out. Share the new password with the account owner securely.</small><button>Reset password</button></form></details>
    </fieldset>}{error && <p role="alert" className="aw-error">{error}</p>}
  </article>
}

function AccessRequest({ item, send, onSaved }) {
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  async function act(action) {
    setBusy(true); setError('')
    try { await send(`/management/access-requests/${item.id}`, { action }); await onSaved('Machine access request updated.') }
    catch (err) { setError(err.message) }
    setBusy(false)
  }
  return <article className="aw-ticket"><h3>{item.username} requested {item.vm_name}</h3><p className="aw-meta">{item.host_id || 'Unresolved host'} · {item.status}</p><p className="aw-body">{item.note}</p>{item.status === 'pending' && <div className="aw-actions"><button disabled={busy || !item.resource_key} onClick={() => act('approve')}>Grant access</button><button disabled={busy} onClick={() => act('deny')}>Decline</button></div>}{error && <p role="alert" className="aw-error">{error}</p>}</article>
}

function HostHealth({ hosts = [] }) {
  const visible = hosts.filter(host => host.id !== 'local')
  return <section className="aw-card aw-compact"><div className="aw-row"><div><h2>Hosts</h2><p>Where your remote VMs run.</p></div><div className="aw-hosts">{visible.length ? visible.map(host => {
    const profiles = ['standard', host.capabilities?.gaming_provisioning && 'gaming', host.capabilities?.omarchy_provisioning && 'omarchy'].filter(Boolean)
    return <div className={`aw-host ${host.online ? 'online' : 'offline'}`} key={host.id}><span className="aw-dot" /><div><strong>{host.display_name || host.id}</strong><small>{host.online ? `${profiles.join(' · ')} ready` : 'Offline'}</small></div></div>
  }) : <span className="aw-meta">No remote hosts enrolled.</span>}</div></div></section>
}

function MachineFleet({ resources = [], send, onSaved }) {
  const machines = resources.filter(item => item.resourceType === 'vm' && item.classification === 'managed')
  const [busy, setBusy] = useState(''), [error, setError] = useState('')
  async function act(machine, action) {
    const key = `${machine.resourceKey}:${action}`; setBusy(key); setError('')
    try { await send(`/management/machines/${encodeURIComponent(machine.name)}`, { action, host_id: machine.hostId || 'local' }); await onSaved(`${machine.name}: ${action} requested.`) }
    catch (err) { setError(err.message) }
    setBusy('')
  }
  return <section className="aw-card"><div className="aw-row"><div><h2>Managed machines</h2><p>Everyday controls without the full operations dashboard.</p></div><span className="aw-count">{machines.length}</span></div>
    {error && <p role="alert" className="aw-error">{error}</p>}
    {!machines.length ? <div className="aw-empty">No managed VMs are available yet.</div> : <div className="aw-machine-grid">{machines.map(machine => {
      const state = String(machine.state || machine.status || (machine.running ? 'running' : 'stopped')).toLowerCase()
      const running = machine.running === true || state === 'running' || state === 'ready'
      const unavailable = machine.available === false || machine.host_online === false
      const remote = String(machine.placement || '').toLowerCase() === 'remote'
      const caps = machine.capabilities || {}
      const consoleUrl = `/EpicVM/vm/${encodeURIComponent(machine.name)}/${remote && machine.hostId ? `?host_id=${encodeURIComponent(machine.hostId)}` : ''}`
      return <article className="aw-machine" key={machine.resourceKey}><div className="aw-row"><div><h3>{machine.name}</h3><p>{machine.hostName || machine.hostId || 'EpicVM server'} · {machine.profile || 'standard'}</p></div><span className={`aw-state ${unavailable ? 'bad' : running ? 'good' : ''}`}>{unavailable ? 'host offline' : state.replaceAll('_', ' ')}</span></div>
        <div className="aw-actions"><button disabled={!!busy || unavailable || running || caps.powerStart === false} onClick={() => act(machine, 'start')}>{busy === `${machine.resourceKey}:start` ? 'Starting…' : 'Start'}</button><button disabled={!!busy || unavailable || !running || caps.powerStop === false} onClick={() => act(machine, 'stop')}>{busy === `${machine.resourceKey}:stop` ? 'Stopping…' : 'Stop'}</button><button disabled={!!busy || unavailable || caps.restart === false} onClick={() => act(machine, 'restart')}>{busy === `${machine.resourceKey}:restart` ? 'Restarting…' : 'Restart'}</button><a className="aw-button" href={consoleUrl}>Open console</a></div>
      </article>
    })}</div>}
  </section>
}

function ProvisioningHistory({ entries = [], onSelect }) {
  const terminal = entries.filter(entry => {
    const state = String(entry?.job?.state || '')
    return state === 'ready' || state.startsWith('setup_failed:') || state === 'failed'
  })
  if (!terminal.length) return null
  return <details className="aw-card aw-history"><summary>Recent creation history · {terminal.length}</summary><div>{terminal.map(entry => <button type="button" key={`${entry.host_id}:${entry.job.id}`} onClick={() => onSelect(entry)}><span><strong>{entry.job.name}</strong><small>{entry.host_name || entry.host_id} · {entry.job.profile || 'standard'}</small></span><span className={`aw-state ${entry.job.state === 'ready' ? 'good' : 'bad'}`}>{String(entry.job.state).replaceAll('_', ' ')}</span></button>)}</div></details>
}

function VmCreator({ content, readManagement, send, onSaved }) {
  const remoteHosts = (content?.hosts || []).filter(host => host.id !== 'local')
  const hosts = [{ id: 'local', display_name: 'EpicVM server (normal VM)', online: true, capabilities: { create_vm: true } }, ...remoteHosts]
  const [hostId, setHostId] = useState('local'), [profile, setProfile] = useState('standard')
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [job, setJob] = useState(null)
  const pendingJobs = content?.jobs || []
  const selected = hosts.find(host => host.id === hostId) || hosts[0]
  const capability = profile === 'gaming' ? 'gaming_provisioning' : profile === 'omarchy' ? 'omarchy_provisioning' : 'provisioning'
  const local = hostId === 'local'
  const eligible = local || selected?.online === true && selected?.capabilities?.create_vm === true && selected?.capabilities?.[capability] === true
  useEffect(() => { if (!hostId && hosts[0]) setHostId(hosts[0].id) }, [hostId, hosts])
  useEffect(() => {
    if (job?.id || !pendingJobs.length) return
    const entry = pendingJobs[0]
    if (entry?.job) setJob({ ...entry.job, hostId: entry.host_id })
  }, [job?.id, pendingJobs])
  useEffect(() => {
    if (!job?.id || !job.hostId || job.state === 'ready' || String(job.state || '').startsWith('setup_failed:')) return undefined
    const timer = setInterval(async () => {
      try {
        const next = await readManagement(`/management/provisioning/${encodeURIComponent(job.id)}?host_id=${encodeURIComponent(job.hostId)}`)
        if (next.job) setJob({ ...next.job, hostId: next.host_id || job.hostId })
      } catch (err) { setError(err.message) }
    }, 3000)
    return () => clearInterval(timer)
  }, [job?.id, job?.hostId, job?.state])
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('')
    const form = event.currentTarget, fields = new FormData(form)
    try {
      const result = await send(local ? '/management/vms' : '/management/provisioning', {
        host_id: hostId, name: String(fields.get('name') || '').trim().toLowerCase(), profile,
        cpuCount: fields.get('cpuCount'), memoryGiB: fields.get('memoryGiB'),
        diskSizeGiB: fields.get('diskSizeGiB'), gpuPartitionPercent: fields.get('gpuPartitionPercent')
      })
      setJob(result.job ? { ...result.job, hostId: result.host_id || hostId } : local ? { name: fields.get('name'), state: 'created', hostId: 'local' } : null)
      form.reset(); await onSaved(local ? 'Normal server VM created and started.' : 'VM creation started. Provisioning continues automatically.')
    } catch (err) { setError(err.message) }
    setBusy(false)
  }
  async function recover(action) {
    setBusy(true); setError('')
    try {
      const result = await send(`/management/provisioning/${encodeURIComponent(job.id)}/${action}`, { host_id: job.hostId })
      if (result.job) setJob({ ...result.job, hostId: result.host_id || job.hostId })
      await onSaved(action === 'continue' ? 'Provisioning continued with protected defaults.' : 'Console retry started.')
    } catch (err) { setError(err.message) }
    setBusy(false)
  }
  const rawState = String(job?.autonomousPending ? job?.autonomousStage : job?.state || job?.autonomousStage || 'queued')
  const completed = new Set(job?.completedStages || [])
  const stages = stagesFor(job)
  const failed = rawState.startsWith('setup_failed:') || rawState === 'failed'
  const currentState = failed ? failedStageFor(job, stages) : ['unclaimed', 'claim_in_progress'].includes(rawState) ? 'claim' : rawState
  const currentIndex = Math.max(0, stages.findIndex(([key]) => key === currentState))
  const progress = job?.state === 'ready' ? 100 : Math.max(Math.round((currentIndex / Math.max(1, stages.length - 1)) * 100), Math.round((completed.size / Math.max(1, stages.length - 1)) * 100))
  return <section className="aw-card aw-create"><h2>Create a new VM</h2><p>Provision a machine on an enrolled host. Setup and readiness checks run automatically.</p>
    {!hosts.length ? <div className="aw-empty">No online provisioning hosts are available.</div> : <form onSubmit={submit}>
      <div className="aw-form-grid"><label>VM name<input name="name" pattern="[a-z0-9][a-z0-9._-]{0,62}" placeholder="epic-workstation-02" required /></label>
        <label>Host<select value={hostId} onChange={e => setHostId(e.target.value)}>{hosts.map(host => <option key={host.id} value={host.id} disabled={host.id !== 'local' && (host.online !== true || host.capabilities?.create_vm !== true)}>{host.display_name || host.id}{host.id !== 'local' && host.online !== true ? ' · offline' : ''}</option>)}</select></label>
        {!local && <><label>Profile<select value={profile} onChange={e => setProfile(e.target.value)}><option value="standard">Standard Windows</option><option value="gaming">Gaming Windows</option><option value="omarchy">Omarchy Linux</option></select></label>
          <label>vCPU<input name="cpuCount" type="number" min="1" max="16" defaultValue="6" /></label>
          <label>Memory (GiB)<input name="memoryGiB" type="number" min="1" max="16" defaultValue="12" /></label>
          <label>Disk (GiB)<input name="diskSizeGiB" type="number" min="1" max="512" defaultValue="128" /></label>
          {['gaming', 'omarchy'].includes(profile) && <label>GPU-P share (%)<input name="gpuPartitionPercent" type="number" min="1" max="100" defaultValue="50" /></label>}</>}
      </div>
      {!eligible && <p role="alert" className="aw-error">This host is not ready for the selected profile.</p>}
      {local && <small>This creates the same normal server VM offered by the full dashboard and starts it immediately.</small>}
      {error && <p role="alert" className="aw-error">{error}</p>}<button className="aw-primary" disabled={busy || !eligible}>{busy ? 'Starting…' : local ? 'Create normal VM' : 'Create VM'}</button>
    </form>}
    {pendingJobs.length > 0 && <div className="aw-job-picker"><strong>VMs currently being created</strong>{pendingJobs.map(entry => <button type="button" key={`${entry.host_id}:${entry.job.id}`} aria-pressed={job?.id === entry.job.id && job?.hostId === entry.host_id} onClick={() => setJob({ ...entry.job, hostId: entry.host_id })}>{entry.job.name} · {String(entry.job.state || entry.job.autonomousStage || 'queued').replaceAll('_', ' ')}</button>)}</div>}
    {job && !job.id && <div className="aw-job" role="status"><strong>{job.name || 'New VM'}</strong><span>{String(job.state || 'created').replaceAll('_', ' ')}</span></div>}
    {job && job.id && <div className={`aw-progress ${failed ? 'failed' : ''}`} role="status" aria-live="polite">
      <div className="aw-row"><div><strong>{job.name || 'New VM'}</strong><p>{job.hostId} · {String(job.profile || 'standard').replaceAll('_', ' ')}</p></div><span className="aw-badge">{currentState.replaceAll('_', ' ')}</span></div>
      <div className="aw-progress-track" aria-label={`Provisioning ${progress}% complete`}><span style={{ width: `${progress}%` }} /></div>
      <ol className="aw-stages">{stages.map(([key, title], index) => {
        const done = completed.has(key) || job.state === 'ready' || index < currentIndex
        const active = key === currentState || (failed && index === currentIndex)
        return <li key={key} className={done ? 'done' : active ? 'active' : ''}><span>{done ? '✓' : active ? '●' : '○'}</span><div><strong>{title}</strong>{active && <small>{failed ? 'Stopped safely at this stage' : 'In progress'}</small>}</div></li>
      })}</ol>
      {job.autonomousPending && <p>Automatic setup is continuing with protected server credentials. You can leave this page and return without losing progress.</p>}
      {failed && <p className="aw-error">Creation stopped safely during {stages.find(([key]) => key === currentState)?.[1] || 'setup'}{job.errorCode ? `: ${String(job.errorCode).replaceAll('_', ' ')}` : '.'} The VM was retained for diagnosis.</p>}
      {String(job.state || '') === 'unclaimed' && <button type="button" onClick={() => recover('continue')} disabled={busy}>{busy ? 'Continuing…' : 'Continue automatically'}</button>}
      {job.state === 'setup_failed:streaming' && <button type="button" onClick={() => recover('retry-console')} disabled={busy}>{busy ? 'Retrying…' : 'Retry console'}</button>}
      {job.state === 'ready' && <a className="aw-primary aw-open-vm" href={`/EpicVM/vm/${encodeURIComponent(job.name)}/?host_id=${encodeURIComponent(job.hostId)}`}>Open VM</a>}
    </div>}
    <ProvisioningHistory entries={content?.recentJobs || []} onSelect={entry => setJob({ ...entry.job, hostId: entry.host_id })} />
  </section>
}

export default function AccountWorkspace({ management = false }) {
  const [session, setSession] = useState(null), [checking, setChecking] = useState(true)
  const [content, setContent] = useState(null), [error, setError] = useState(''), [notice, setNotice] = useState('')
  const [tab, setTab] = useState(management ? 'machines' : 'requests'), [search, setSearch] = useState(''), [closed, setClosed] = useState(false)
  async function loadSession() {
    try { const next = await read(`${API}/account/session`); setSession(next); return next }
    catch { setSession(null); return null }
    finally { setChecking(false) }
  }
  async function loadContent() {
    setError('')
    try {
      if (management) {
        const [overview, provisioning] = await Promise.all([read(`${API}/management/overview`), read(`${API}/management/provisioning`)])
        setContent({ ...overview, ...provisioning })
      } else setContent(await read(`${API}/account/tickets`))
    }
    catch (err) { setError(err.message) }
  }
  useEffect(() => { loadSession() }, [])
  useEffect(() => { setTab(management ? 'machines' : 'requests') }, [management])
  useEffect(() => { setContent(null); if (session && !session.user.reauthenticate && (!management || session.user.isAdmin)) loadContent() }, [management, session?.user.username, session?.user.realm])
  async function send(path, body) {
    return read(API + path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': session.csrfToken }, body: JSON.stringify(body) })
  }
  async function readManagement(path) { return read(API + path) }
  async function saved(message) { setNotice(message); await loadContent() }
  async function signout() {
    await read(session.user.realm === 'dashboard-config' ? '/Dashboard/api/auth/logout' : '/portal/api/auth/logout', { method: 'POST' })
    setSession(null); setContent(null)
  }
  const who = session?.user
  const tickets = content?.tickets || []
  const filtered = tickets.filter(t => closed || !['fulfilled', 'resolved', 'declined'].includes(t.status)).filter(t => tab === 'reports' ? t.kind !== 'vm' : t.kind === 'vm')
  return <div className="aw"><header className="aw-header"><Link to="/" className="aw-brand"><span>E</span> EpicVM</Link><nav aria-label="Account navigation"><Link to="/portal">My machines</Link><Link to="/settings" aria-current={!management ? 'page' : undefined}><Gear /> Settings</Link>{who?.isAdmin && <Link to="/Management" aria-current={management ? 'page' : undefined}><ShieldCheck /> Management</Link>}{who && <button onClick={() => signout().catch(err => setError(err.message))}>Sign out</button>}</nav></header>
    <main className="aw-main">{checking ? <p role="status">Checking your session…</p> : !who || who.reauthenticate ? <><Login management={management || who?.realm === 'dashboard-config'} onLogin={loadSession} />{who?.reauthenticate && <p className="aw-meta">Your older admin session needs a fresh sign-in for account settings.</p>}</> : management && !who.isAdmin ? <section className="aw-card"><h1>Administrator access required</h1><p>Your settings and requests are available in your account.</p><Link to="/settings">Open Settings</Link></section> : <>
      <div className="aw-heading"><div><div className="aw-eyebrow">{management ? 'EPICVM ADMIN' : 'YOUR ACCOUNT'}</div><h1>{management ? 'Management' : 'Settings'}</h1><p>{management ? 'Machines, people, and requests in one focused workspace.' : `Signed in as ${who.username} · ${who.realm === 'portal' ? 'EpicVM account' : 'Dashboard administrator'}`}</p></div>{management && <a href="/Dashboard/" className="aw-full">Advanced dashboard ↗</a>}</div>
      {notice && <div className="aw-notice" role="status"><CheckCircle size={20} />{notice}<button aria-label="Dismiss notification" onClick={() => setNotice('')}>×</button></div>}{error && <div className="aw-error" role="alert">{error} <button onClick={loadContent}>Retry</button></div>}
      {!management ? <><div className="aw-columns"><PasswordForm send={send} refresh={async message => { await loadSession(); setNotice(message) }} /><TicketForm send={send} onSaved={saved} /></div><section className="aw-card"><div className="aw-row"><h2>Your requests & reports</h2><button onClick={loadContent}>Refresh</button></div><p>Administrator replies and status updates appear here.</p>{!content ? <p>Loading…</p> : !tickets.length ? <div className="aw-empty">Nothing sent yet. Your first request or report will appear here.</div> : tickets.map(t => <Ticket key={t.id + t.updated_at} ticket={t} />)}</section></> : <>
        <div className="aw-tabs aw-tabs-four" role="group" aria-label="Management sections">{[['machines', Desktop, 'Machines', (content?.jobs || []).length], ['requests', ChatCircle, 'Requests', tickets.filter(t => t.kind === 'vm' && ['pending','in_review'].includes(t.status)).length + (content?.requests || []).filter(r => r.status === 'pending').length], ['accounts', Users, 'Accounts', (content?.users || []).filter(u => u.accountStatus === 'pending').length], ['reports', ChatCircle, 'Feedback', tickets.filter(t => t.kind !== 'vm' && ['pending','in_review'].includes(t.status)).length]].map(([key, Icon, title, count]) => <button key={key} aria-pressed={tab === key} onClick={() => setTab(key)}><Icon size={22} />{title}<span>{count}</span></button>)}</div>
        {tab === 'machines' && <><HostHealth hosts={content?.hosts || []} /><VmCreator content={content} readManagement={readManagement} send={send} onSaved={saved} /><MachineFleet resources={content?.resources || []} send={send} onSaved={saved} /><SharedGames resources={content?.resources || []} users={content?.users || []} send={send} /></>}
        {tab === 'requests' && content?.requests?.length > 0 && <section className="aw-card"><h2>Machine access requests</h2><p>Requests from the machine browser. Account approval remains separate.</p>{content.requests.filter(r => closed || r.status === 'pending').map(r => <AccessRequest key={r.id + r.status} item={r} send={send} onSaved={saved} />)}</section>}
        {tab !== 'machines' && <section className="aw-card"><div className="aw-row"><h2>{tab === 'accounts' ? 'Accounts & assignments' : tab === 'requests' ? 'VM requests' : 'Feedback & bug reports'}</h2><button onClick={loadContent}>Refresh</button></div>
          {!content ? <p>Loading…</p> : tab === 'accounts' ? <><label>Find an account<input type="search" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search by username or email" /></label>{content.users.filter(u => `${u.username} ${u.email || ''}`.toLowerCase().includes(search.toLowerCase())).map(u => <UserCard key={u.username + JSON.stringify(u)} user={u} resources={content.resources || []} send={send} onSaved={saved} self={who.realm === 'portal' && who.username === u.username} />)}<details><summary>Dashboard administrator identities</summary><p>These are separate from EpicVM accounts. Administrators change their own passwords in Settings.</p>{(content.adminIdentities || []).map(u => <p key={u.source}>{u.username} · {u.source}</p>)}</details></> : <><label className="aw-toggle"><input type="checkbox" checked={closed} onChange={e => setClosed(e.target.checked)} />Include closed requests</label>{filtered.length ? filtered.map(t => <Ticket key={t.id + t.updated_at} ticket={t} admin resources={content.resources || []} send={send} onSaved={saved} />) : <div className="aw-empty">You're all caught up. New {tab === 'requests' ? 'VM requests' : 'feedback and bug reports'} will appear here.</div>}</>}
        </section>}
      </>}
    </>}</main><footer className="aw-footer"><Link to="/"><ArrowLeft /> Back to EpicVM</Link><span>EpicVM · Your workspace, connected.</span></footer>{who && <EpiChat />}</div>
}
