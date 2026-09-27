import React, { useState, useEffect } from 'react'
import { Routes, Route, Navigate, useLocation, useNavigate } from 'react-router-dom'
import Landing from './pages/Landing'
import Signup from './pages/Signup'
import Signin from './pages/Signin'
import Pending from './pages/Pending'
import Portal from './pages/Portal'
import { me } from './api'
import AccountWorkspace from './pages/AccountWorkspace'

function PortalGate({ user, status, children }) {
  if (!user) return <Navigate to="/signin" replace />
  if (status === 'pending' || status === 'rejected') return <Navigate to="/pending" replace />
  return children
}

export default function App() {
  const [user, setUser] = useState(null) // null = loading, false = anon, object = authed
  const [checking, setChecking] = useState(true)
  const location = useLocation()
  const navigate = useNavigate()

  useEffect(() => {
    let live = true
    me().then((u) => {
      if (!live) return
      setUser(u)
      setChecking(false)
    }).catch(() => {
      if (!live) return
      setUser(false)
      setChecking(false)
    })
    return () => { live = false }
  }, [location.pathname])

  useEffect(() => {
    if (!user || !['pending', 'approved'].includes(user.accountStatus || 'approved')) return
    let live = true
    const timer = window.setInterval(() => {
      me().then((next) => { if (live && next) setUser(next) }).catch(() => {})
    }, 7000)
    return () => { live = false; window.clearInterval(timer) }
  }, [user && user.username, user && user.accountStatus])

  if (/^\/(settings|Management)\/?$/i.test(location.pathname)) {
    return <AccountWorkspace management={location.pathname.toLowerCase().startsWith('/management')} />
  }

  if (checking) {
    return <div className="evm-loading" role="status">Loading…</div>
  }

  // Status gating for /portal/*: pending/rejected users get the status view, not the console.
  const status = user ? (user.accountStatus || 'approved') : 'anon'

  return (
    <Routes>
      <Route path="/signup" element={<Signup setUser={setUser} />} />
      <Route path="/signin" element={<Signin setUser={setUser} />} />
      <Route path="/pending" element={<Pending user={user} />} />
      <Route
        path="/portal"
        element={<PortalGate user={user} status={status}><Portal user={user} onSignout={() => { setUser(false); window.location.assign('/EpicVM/') }} /></PortalGate>}
      />
      <Route
        path="/"
        element={<Landing authed={!!user} onSignout={() => { setUser(false); window.location.assign('/EpicVM/') }} />}
      />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
