import React, { useEffect, useState, useRef } from 'react'
import apiFetch from '../lib/fetchWrapper'
import Button from '../components/Button'

export default function Logs(){
  const [source, setSource] = useState('optimizer')
  const [vms, setVms] = useState([])
  const [selectedVm, setSelectedVm] = useState('')
  const [logs, setLogs] = useState('')
  const [running, setRunning] = useState(true)
  const [filterText, setFilterText] = useState('')
  const [limit, setLimit] = useState(500)
  const [jev, setJev] = useState(null)
  const [jevBusy, setJevBusy] = useState(false)
  const ivRef = useRef(null)

  async function loadVms(){
    try{
      const r = await apiFetch('/list')
      const j = await r.json().catch(()=>({instances:[]}))
      setVms((j.instances||[]).map(i=>i.name))
      if(!selectedVm && (j.instances||[]).length) setSelectedVm((j.instances||[])[0].name)
    }catch(e){ console.error('load vms', e) }
  }

  async function fetchLogs(){
    try{
      let txt = ''
      if(source === 'optimizer'){
        const r = await apiFetch('/optimizer/logs')
        txt = await r.text().catch(()=>'')
      }else{
        if(!selectedVm) return
        const r = await apiFetch(`/vm/logs/${encodeURIComponent(selectedVm)}`)
        const j = await r.json().catch(()=>({ok:false, logs:''}))
        txt = j.logs || j.error || ''
      }
      if(filterText){
        const re = new RegExp(filterText, 'i')
        txt = txt.split('\n').filter(l=>re.test(l)).slice(-limit).join('\n')
      }else{
        txt = txt.split('\n').slice(-limit).join('\n')
      }
      setLogs(txt)
    }catch(e){ setLogs('Error: '+String(e)) }
  }

  useEffect(()=>{ loadVms() }, [])

  useEffect(()=>{
    // polling interval taken from settings
    const iv = parseInt(localStorage.getItem('nbv2_update_interval')||'3000',10)
    if(running){ fetchLogs(); ivRef.current = setInterval(fetchLogs, Math.max(1000, iv)) }
    return ()=>{ if(ivRef.current) clearInterval(ivRef.current); ivRef.current=null }
  }, [running, source, selectedVm, filterText, limit])

  function downloadLogs(){
    const blob = new Blob([logs], {type:'text/plain;charset=utf-8'})
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    const name = source === 'optimizer' ? 'optimizer-logs.txt' : `vm-${selectedVm||'logs'}.txt`
    a.download = name
    document.body.appendChild(a)
    a.click()
    a.remove()
    URL.revokeObjectURL(url)
  }

  async function analyzeLogs(){
    setJevBusy(true)
    try{
      const r = await apiFetch('/jev/analyze', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({task:'log_triage', state:{source, vm:selectedVm, logs:logs.slice(-24000)}})})
      const body = await r.json().catch(()=>({}))
      if(!r.ok || !body.ok) throw new Error(body.error || 'Jev analysis failed')
      setJev(body.advisory)
    }catch(error){ setJev({error:String(error)}) }
    setJevBusy(false)
  }

  return (
    <div>
      <h1 style={{marginTop:0}}>Logs Viewer</h1>
      <div className="glass-card">
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'center'}}>
          <div style={{display:'flex',gap:12,alignItems:'center'}}>
            <label style={{color:'var(--muted)'}}>Source</label>
            <select value={source} onChange={e=>setSource(e.target.value)} style={{padding:6,borderRadius:6}}>
              <option value="optimizer">Optimizer</option>
              <option value="vm">VM</option>
            </select>

            {source === 'vm' ? (
              <>
                <label style={{color:'var(--muted)'}}>VM</label>
                <select value={selectedVm} onChange={e=>setSelectedVm(e.target.value)} style={{padding:6,borderRadius:6}}>
                  {vms.map(v=> <option key={v} value={v}>{v}</option>)}
                </select>
              </>
            ) : null}
          </div>
          <div style={{display:'flex',gap:8,alignItems:'center'}}>
            <input placeholder="filter (regex)" value={filterText} onChange={e=>setFilterText(e.target.value)} style={{padding:6,borderRadius:6}} />
            <input type="number" value={limit} onChange={e=>setLimit(Number(e.target.value||0))} style={{width:100,padding:6,borderRadius:6}} />
            <Button onClick={()=>setRunning(r=>!r)}>{running ? 'Pause' : 'Resume'}</Button>
            <Button onClick={()=>{ setLogs(''); }}>Clear</Button>
            <Button onClick={downloadLogs}>Download</Button>
            <Button disabled={jevBusy || !logs.trim()} onClick={analyzeLogs}>{jevBusy ? 'Analyzing…' : 'Analyze with Jev'}</Button>
          </div>
        </div>

        <div style={{marginTop:12}}>
          <div style={{background:'#000',color:'#0ff',padding:8,borderRadius:6,height:480,overflow:'auto',fontFamily:'monospace',fontSize:12}}>
            <pre style={{whiteSpace:'pre-wrap',margin:0}}>{logs}</pre>
          </div>
        </div>
        {jev && <div className="glass-card" style={{marginTop:12,borderLeft:'3px solid #02bdf3'}}><strong>Jev log advisory</strong><p style={{color:'var(--muted)',fontSize:12}}>Read-only prioritization. Raw logs and deterministic status remain authoritative.</p>{jev.error ? <p>{jev.error}</p> : <div style={{display:'flex',gap:10,flexWrap:'wrap'}}>{Object.entries(jev.answers||{}).map(([key,answer])=><span key={key} style={{padding:'8px 10px',border:'1px solid rgba(255,255,255,.1)',borderRadius:7}}><b>{key.replaceAll('_',' ')}</b>: {String(answer.choice ?? (answer.score !== undefined ? Number(answer.score).toFixed(1) : `${Math.round(Number(answer.noul||0)*100)}%`))}</span>)}</div>}</div>}
      </div>
    </div>
  )
}
