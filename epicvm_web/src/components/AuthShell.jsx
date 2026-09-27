import React from 'react'
import { useNavigate } from 'react-router-dom'

// Shared chrome for the auth pages so Sign In / Request Access / Pending feel
// like part of the same EpicVM management and portal experience.
// `rightLink` overrides the default contextual link (Sign In <-> Request Access).
// Pass rightLink={null} to hide it (e.g. on the status/pending screens).
export default function AuthShell({ children, title, rightLink }) {
  const navigate = useNavigate()
  let link = rightLink
  if (link === undefined) {
    link = title === 'Sign In'
      ? <a className="evm-link-btn" href="/EpicVM/signup" onClick={(e) => { e.preventDefault(); navigate('/signup') }}>Request Access</a>
      : <a className="evm-link-btn" href="/EpicVM/signin" onClick={(e) => { e.preventDefault(); navigate('/signin') }}>Sign In</a>
  }
  return (
    <div className="evm-page evm-auth-page">
      <header className="evm-portal-head">
        <div className="evm-ph-left">
          <button className="evm-brand evm-brand-btn" onClick={() => navigate('/')} aria-label="EpicVM home">
            <span className="evm-brand-mark">E</span> EpicVM
          </button>
          <span className="evm-beta-pill">BETA</span>
        </div>
        <div className="evm-ph-right">
          <a className="evm-link-btn" href="/EpicVM/settings">Settings</a>
          {link}
        </div>
      </header>
      <div className="evm-auth-wrap">
        {children}
      </div>
    </div>
  )
}
