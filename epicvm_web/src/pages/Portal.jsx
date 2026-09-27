import React, { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { Desktop, WindowsLogo, GameController, Power, Plug, ArrowClockwise, Stop, Spinner, Plus, CaretDown, Laptop } from '@phosphor-icons/react'
import { myVms, logout, startVm, stopVm, restartVm, addCloudPc, pairCloudPc } from '../api'
import { AvailableGames } from './SharedGames'
import EpiChat from '../components/EpiChat'

const TYPE_META = {
  linux: { label: 'Linux VM', icon: Desktop, cls: 't-linux', tag: 'BETA DEFAULT' },
  windows: { label: 'Windows VM', icon: WindowsLogo, cls: 't-windows', tag: 'LIMITED' },
  gaming: { label: 'Gaming VM', icon: GameController, cls: 't-gaming', tag: 'EXPERIMENTAL' },
  cloudpc: { label: 'Cloud PC', icon: Laptop, cls: 't-cloudpc', tag: 'YOUR PC' },
}

const PORTAL_CACHE_KEY = 'epicvm.portal.machines.v1'

function cachedMachines(username) {
  try {
    const value = JSON.parse(window.sessionStorage.getItem(PORTAL_CACHE_KEY) || 'null')
    if (value?.username === username && Array.isArray(value.vms)) return value
  } catch { /* a damaged cache should never block the portal */ }
  return null
}

function MachineSkeleton({ message }) {
  return <section className="evm-loading-shell" aria-live="polite" aria-busy="true">
    <div className="evm-loading-copy"><span className="evm-loading-check">✓</span><div><strong>Your account is connected</strong><p>{message}</p></div><Spinner size={24} className="spin" /></div>
    <div className="evm-grid evm-skeleton-grid" aria-hidden="true">{[0, 1, 2].map(index => <div className="evm-card evm-skeleton-card" key={index}><span /><b /><i /><i /><em /></div>)}</div>
  </section>
}

function readinessBadge(r) {
  const map = {
    ready: ['READY', 'rb-ready'],
    provisioning: ['PREPARING', 'rb-work'],
    offline: ['PC OFFLINE', 'rb-off'],
    stopped: ['OFFLINE', 'rb-off'],
    stopping: ['SHUTTING DOWN', 'rb-work'],
    failed: ['FAILED', 'rb-bad'],
    unavailable: ['HOST UNAVAILABLE', 'rb-bad'],
    'running-unready': ['RUNNING · NOT READY', 'rb-work'],
  }
  const [txt, cls] = map[r] || ['UNKNOWN', 'rb-off']
  return <span className={`evm-rbadge ${cls}`}>{txt}</span>
}

export default function Portal({ user, onSignout }) {
  const navigate = useNavigate()
  const username = user?.username || 'user'
  const initialCache = useRef(cachedMachines(username))
  const [vms, setVms] = useState(initialCache.current?.vms || null)
  const [summary, setSummary] = useState(initialCache.current?.summary || null)
  const [loading, setLoading] = useState(!initialCache.current)
  const [refreshing, setRefreshing] = useState(Boolean(initialCache.current))
  const [loadingMessage, setLoadingMessage] = useState('Finding your machines and checking their latest status…')
  const [err, setErr] = useState('')
  const loadingRef = useRef(false)
  const hasLoadedRef = useRef(Boolean(initialCache.current))

  const [showAddPc, setShowAddPc] = useState(false)
  const [addPc, setAddPc] = useState({ displayName: '', tailnetIp: '', sunshineUsername: '', sunshinePassword: '' })
  const [addPcBusy, setAddPcBusy] = useState(false)
  const [addPcErr, setAddPcErr] = useState('')

  const load = async ({ initial = false } = {}) => {
    if (loadingRef.current) return
    loadingRef.current = true
    if (initial && !hasLoadedRef.current) setLoading(true)
    if (hasLoadedRef.current) setRefreshing(true)
    try {
      const res = await myVms()
      if (!res.ok) { setErr('Could not load your machines.'); return }
      setVms(res.body.vms || [])
      setSummary(res.body.summary || null)
      hasLoadedRef.current = true
      window.sessionStorage.setItem(PORTAL_CACHE_KEY, JSON.stringify({ username, vms: res.body.vms || [], summary: res.body.summary || null }))
      setErr('')
    } catch (error) {
      setErr(error?.name === 'AbortError' ? 'Machine status took too long to respond. Try refreshing.' : 'Could not load your machines.')
    } finally {
      loadingRef.current = false
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    load({ initial: true })
    const timer = window.setInterval(() => load(), 10000)
    return () => window.clearInterval(timer)
  }, [])

  useEffect(() => {
    if (!loading) return undefined
    const checking = window.setTimeout(() => setLoadingMessage('Your account is connected. We’re checking live host status now…'), 1400)
    const slower = window.setTimeout(() => setLoadingMessage('This host is taking a little longer to answer. You can safely stay on this page.'), 5000)
    return () => { window.clearTimeout(checking); window.clearTimeout(slower) }
  }, [loading])

  async function signout() {
    await logout().catch(() => {})
    window.location.assign('/EpicVM/')
  }

  const [openName, setOpenName] = useState(null)
  const [busy, setBusy] = useState('')
  const [pairBusy, setPairBusy] = useState('')

  const toggleManage = (n) => setOpenName((o) => (o === n ? null : n))

  async function act(kind, vm) {
    const vmName = vm.name
    const hostId = vm.host_id
    setBusy(vmName + ':' + kind)
    let res
    if (kind === 'start') res = await startVm(vmName, hostId, vm.resourceKey)
    else if (kind === 'stop') res = await stopVm(vmName, hostId, vm.resourceKey)
    else if (kind === 'restart') res = await restartVm(vmName, hostId, vm.resourceKey, vm.resourceType)
    setBusy('')
    if (res && res.ok) { load() } else if (res) alert(res.body.error || 'Action failed')
  }

  async function submitAddPc(e) {
    e.preventDefault()
    setAddPcBusy(true)
    setAddPcErr('')
    const res = await addCloudPc({
      displayName: addPc.displayName.trim(),
      tailnetIp: addPc.tailnetIp.trim(),
      sunshineUsername: addPc.sunshineUsername.trim(),
      sunshinePassword: addPc.sunshinePassword,
    })
    setAddPcBusy(false)
    if (res.ok) {
      setShowAddPc(false)
      setAddPc({ displayName: '', tailnetIp: '', sunshineUsername: '', sunshinePassword: '' })
      load()
    } else {
      setAddPcErr(res.body.error || 'Could not add your PC')
    }
  }

  async function pairPc(vm) {
    setPairBusy(vm.name)
    const su = window.prompt('Sunshine username on your PC (used once to pair):')
    if (su === null) { setPairBusy(''); return }
    const sp = window.prompt('Sunshine password on your PC (used once to pair):')
    if (sp === null) { setPairBusy(''); return }
    const res = await pairCloudPc(vm.name, { sunshineUsername: su, sunshinePassword: sp })
    setPairBusy('')
    if (res.ok) { load() } else { alert(res.body.error || 'Pairing failed') }
  }

  return (
    <div className="evm-page evm-portal">
      <header className="evm-portal-head">
        <div className="evm-ph-left">
          <span className="evm-brand">
            <span className="evm-brand-mark">E</span> EpicVM
          </span>
          <span className="evm-beta-pill">BETA</span>
        </div>
        <div className="evm-ph-right">
          <span className="evm-who">@{username}</span>
          <a className="evm-btn evm-btn-ghost evm-btn-sm" href="/EpicVM/settings">Settings</a>
          {user?.isAdmin && <a className="evm-btn evm-btn-ghost evm-btn-sm" href="/EpicVM/Management">Management</a>}
          <button className="evm-btn evm-btn-ghost evm-btn-sm" onClick={signout}>Sign out</button>
        </div>
      </header>

      <section className="evm-hero2">
        <div className="evm-hero2-main">
          <h1 className="evm-hero2-title">Your machines</h1>
          <p className="evm-hero2-sub">Welcome back, {username}. This is your EpicVM control center.</p>
          {refreshing && <span className="evm-refreshing"><Spinner size={13} className="spin" /> Refreshing live status</span>}
        </div>
        <div className="evm-summary">
          {summary ? (
            <>
              <div className="evm-stat"><b>{summary.total}</b><span>TOTAL</span></div>
              <div className="evm-stat s-ready"><b>{summary.ready}</b><span>READY</span></div>
              <div className="evm-stat s-work"><b>{summary.provisioning}</b><span>PREPARING</span></div>
              <div className="evm-stat s-off"><b>{summary.stopped}</b><span>OFFLINE</span></div>
            </>
          ) : <div className="evm-stat"><b>–</b><span>…</span></div>}
        </div>
      </section>

      {err && <div className="evm-error">{err}</div>}
      <AvailableGames />

      {loading && !vms ? (
        <MachineSkeleton message={loadingMessage} />
      ) : (
        <section className="evm-grid">
          {(vms || []).map((vm) => {
            const tm = TYPE_META[vm.type] || TYPE_META.linux
            const Icon = tm.icon
            const ready = vm.readiness === 'ready'
            const provisioning = vm.readiness === 'provisioning'
            const open = openName === vm.name
            const isCloudPc = vm.type === 'cloudpc'
            const isRemote = vm.placement === 'remote'
            return (
              <article key={vm.resourceKey || `${vm.host_id}:${vm.name}`} className={`evm-card ${tm.cls}`}>
                <div className="evm-m-top">
                  <span className={`evm-type-tag ${tm.cls}`}><Icon size={14} /> {tm.tag}</span>
                  {readinessBadge(vm.readiness)}
                </div>
                <h2 className="evm-card-name">{vm.name}</h2>
                <div className="evm-card-os"><Icon size={16} /> {tm.label}{vm.os ? ` · ${vm.os}` : ''}</div>
                <p className="evm-card-desc">
                  {vm.type === 'linux' && 'Your personal Linux environment for coding, hosting, automation, and dev work.'}
                  {vm.type === 'windows' && 'A full Windows desktop for apps and workflows that need Windows.'}
                  {vm.type === 'gaming' && 'GPU-accelerated Windows built for remote gaming and GPU workloads.'}
                  {vm.type === 'cloudpc' && 'Your own PC, streamed over the web. No agent required — powered by Sunshine + Moonlight.'}
                </p>
                <div className="evm-card-meta">
                  {vm.cpu ? <span>CPU {vm.cpu}</span> : null}
                  {vm.memory ? <span>RAM {vm.memory}</span> : null}
                  {!vm.cpu && !vm.memory ? <span>Cloud computer</span> : null}
                </div>

                <div className="evm-card-actions">
                  {ready ? (
                    <a className="evm-btn evm-btn-primary evm-btn-block" href={vm.wrapperUrl || vm.url}>CONNECT <Plug size={18} /></a>
                  ) : provisioning ? (
                    <button className="evm-btn evm-btn-ghost evm-btn-block" disabled><Spinner size={16} className="spin" /> PREPARING…</button>
                  ) : (
                    <button className="evm-btn evm-btn-ghost evm-btn-block" disabled><Plug size={18} /> NOT READY</button>
                  )}
                  <button
                    className={`evm-btn evm-btn-sm evm-manage-btn ${open ? 'is-open' : ''}`}
                    onClick={() => toggleManage(vm.name)}
                    aria-expanded={open}
                  >
                    {open ? 'CLOSE' : 'MANAGE'} <CaretDown size={16} className={`evm-caret ${open ? 'up' : ''}`} />
                  </button>
                </div>
                <div className={`evm-card-manage-panel ${open ? 'open' : ''}`}>
                  {isCloudPc && !vm.paired && (
                    <button className="evm-btn evm-btn-block evm-mp-btn evm-btn-warn" disabled={pairBusy === vm.name} onClick={() => pairPc(vm)}>
                      {pairBusy === vm.name ? <Spinner size={16} className="spin" /> : null} PAIR
                    </button>
                  )}
                   <button className="evm-btn evm-btn-block evm-mp-btn" disabled={busy === vm.name + ':start' || provisioning || vm.capabilities?.powerStart === false && !isCloudPc} onClick={() => act('start', vm)}>
                    {busy === vm.name + ':start' ? <Spinner size={16} className="spin" /> : <Power size={16} />} START
                  </button>
                   <button className="evm-btn evm-btn-block evm-mp-btn" disabled={busy === vm.name + ':restart' || isCloudPc || vm.capabilities?.restart === false} onClick={() => act('restart', vm)}>
                    {busy === vm.name + ':restart' ? <Spinner size={16} className="spin" /> : <ArrowClockwise size={16} />} RESTART
                  </button>
                   <button className="evm-btn evm-btn-block evm-mp-btn evm-btn-danger" disabled={busy === vm.name + ':stop' || vm.capabilities?.powerStop === false && !isCloudPc} onClick={() => act('stop', vm)}>
                    {busy === vm.name + ':stop' ? <Spinner size={16} className="spin" /> : <Stop size={16} />} STOP
                  </button>
                   <a className="evm-mp-details" href={`/EpicVM/vm/${encodeURIComponent(vm.name)}/${isRemote && vm.host_id ? `?host_id=${encodeURIComponent(vm.host_id)}` : ''}`} onClick={(e) => { e.preventDefault(); window.location.assign(`/EpicVM/vm/${encodeURIComponent(vm.name)}/${isRemote && vm.host_id ? `?host_id=${encodeURIComponent(vm.host_id)}` : ''}`) }}>Open console →</a>
                </div>
              </article>
            )
          })}
          {/* Connect your PC CTA */}
          <button className="evm-card evm-add-card" onClick={() => setShowAddPc(true)}>
            <Plus size={32} />
            <h3>Connect your PC</h3>
            <p>Stream your own Sunshine-enabled PC. No agent to install.</p>
          </button>
          {!loading && vms && vms.length === 0 && (
            <div className="evm-empty">
              <Plus size={32} />
              <h3>No machines yet</h3>
              <p>Your account is approved, but EpicVM hasn't finished preparing a machine. Check back shortly.</p>
            </div>
          )}
        </section>
      )}

      {showAddPc && (
        <div className="evm-modal-backdrop" onClick={() => setShowAddPc(false)}>
          <div className="evm-modal" onClick={(e) => e.stopPropagation()}>
            <h2>Connect your PC</h2>
            <p className="evm-modal-sub">Your PC must already run <b>Sunshine</b> and be on the same Tailscale network as EpicVM.</p>
            <form onSubmit={submitAddPc}>
              <label>Display name</label>
              <input value={addPc.displayName} onChange={(e) => setAddPc({ ...addPc, displayName: e.target.value })} placeholder="My Rig" required />
              <label>Tailscale IP of your PC</label>
              <input value={addPc.tailnetIp} onChange={(e) => setAddPc({ ...addPc, tailnetIp: e.target.value })} placeholder="100.x.x.x" required />
              <label>Sunshine username (optional — to auto-pair now)</label>
              <input value={addPc.sunshineUsername} onChange={(e) => setAddPc({ ...addPc, sunshineUsername: e.target.value })} placeholder="sunshine" autoComplete="username" />
              <label>Sunshine password (optional)</label>
              <input type="password" value={addPc.sunshinePassword} onChange={(e) => setAddPc({ ...addPc, sunshinePassword: e.target.value })} placeholder="••••" autoComplete="current-password" />
              {addPcErr && <div className="evm-error">{addPcErr}</div>}
              <div className="evm-modal-actions">
                <button type="button" className="evm-btn evm-btn-ghost" onClick={() => setShowAddPc(false)}>Cancel</button>
                <button type="submit" className="evm-btn evm-btn-primary" disabled={addPcBusy}>
                  {addPcBusy ? <Spinner size={16} className="spin" /> : null} Add PC
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      <footer className="evm-portal-foot">
        <span>Beta · use at your own risk</span>
        <a href="https://techexplore.us/EpicVM/" onClick={(e) => { e.preventDefault(); window.location.assign('/EpicVM/') }}>Back to home</a>
      </footer>
      <EpiChat />
    </div>
  )
}
