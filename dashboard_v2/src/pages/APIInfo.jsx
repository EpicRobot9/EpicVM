import React, { useEffect, useState } from 'react'
import apiFetch from '../lib/fetchWrapper'

export default function APIInfo(){
  const [info, setInfo] = useState(null)
  const [error, setError] = useState('')

  useEffect(()=>{
    async function load(){
      try{
        const r = await apiFetch('/stats')
        const j = await r.json().catch(()=>null)
        if(!r.ok || !j) throw new Error(j?.error || 'Unable to load system stats')
        setInfo(j); setError('')
      }catch(e){ setError(e.message || 'Unable to load system stats') }
    }
    load()
  }, [])

  const endpoints = [
    '/dashboard/api/stats',
    '/dashboard/api/list',
    '/dashboard/api/vm/stats',
    '/dashboard/api/vm/logs/<name>',
    '/dashboard/api/overview',
    '/dashboard/api/notifications',
    '/dashboard/api/jobs',
    '/dashboard/api/apps',
    '/dashboard/api/optimizer/status',
    '/dashboard/api/optimizer/v2/summary',
    '/dashboard/api/auth/login',
    '/dashboard/api/auth/status'
  ]

  return (
    <div>
      <h1 style={{marginTop:0}}>API & System Info</h1>
      <div className="glass-card">
        <div style={{display:'grid',gridTemplateColumns:'1fr 360px',gap:12}}>
          <div>
            <div style={{fontSize:13,color:'var(--muted)'}}>System stats (live)</div>
            <pre style={{background:'rgba(255,255,255,0.02)',padding:12,borderRadius:8,overflow:'auto',maxHeight:420}}>{error ? `Unavailable: ${error}` : info ? JSON.stringify(info, null, 2) : 'Loading…'}</pre>
          </div>
          <div>
            <div style={{fontSize:13,color:'var(--muted)'}}>Useful endpoints</div>
            <div style={{marginTop:8,display:'flex',flexDirection:'column',gap:8}}>
              {endpoints.map(e=> <div key={e} style={{padding:8,background:'rgba(255,255,255,0.02)',borderRadius:8,fontFamily:'monospace'}}>{e}</div>)}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
