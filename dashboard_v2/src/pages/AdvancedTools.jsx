import React, { useEffect, useState } from 'react'
import apiFetch from '../lib/fetchWrapper'
import Button from '../components/Button'

export default function AdvancedTools(){
  const [vms, setVms] = useState([])
  const [selected, setSelected] = useState('')
  const [doctor, setDoctor] = useState({running:false, result:null})

  useEffect(()=>{
    async function load(){
      try{
        const r = await apiFetch('/list')
        const j = await r.json().catch(()=>({instances:[]}))
        setVms((j.instances||[]).map(i=>i.name))
        if((j.instances||[]).length) setSelected((j.instances||[])[0].name)
      }catch(e){ console.error('load vms', e) }
    }
    load()
  }, [])

  async function runDoctor(){
    setDoctor({running:true, result:null})
    try{
      const r = await apiFetch('/doctor')
      const result = await r.json().catch(()=>({ok:false,error:'Invalid response'}))
      setDoctor({running:false, result})
    }catch(e){
      setDoctor({running:false, result:{ok:false,error:e.message || 'Doctor failed'}})
    }
  }

  return (
    <div>
      <h1 style={{marginTop:0}}>Advanced Tools</h1>
      <section className="glass-card" style={{marginBottom:16}} aria-labelledby="doctor-title">
        <div style={{display:'flex',gap:12,alignItems:'center',justifyContent:'space-between',flexWrap:'wrap'}}>
          <div>
            <h2 id="doctor-title" style={{margin:'0 0 6px'}}>System Doctor</h2>
            <div style={{fontSize:13,color:'var(--muted)'}}>Read-only checks for Docker, routing, dashboard health, and VM configuration.</div>
          </div>
          <Button onClick={runDoctor} disabled={doctor.running}>{doctor.running ? 'Running checks…' : 'Run diagnostics'}</Button>
        </div>
        {doctor.result && <div role="status" style={{marginTop:14}}>
          <div style={{fontWeight:700,color:doctor.result.ok ? '#86efac' : '#fca5a5'}}>
            {doctor.result.ok ? 'Healthy enough' : 'Attention needed'}
          </div>
          <pre style={{margin:'10px 0 0',padding:12,borderRadius:10,background:'rgba(2,6,23,.55)',whiteSpace:'pre-wrap',overflowWrap:'anywhere',maxHeight:360,overflow:'auto'}}>{doctor.result.output || doctor.result.error || 'No details returned.'}</pre>
        </div>}
      </section>
      <div className="glass-card">
        <div style={{display:'flex',gap:12,alignItems:'center',marginBottom:12}}>
          <div style={{fontSize:13,color:'var(--muted)'}}>Select VM</div>
          <select value={selected} onChange={e=>setSelected(e.target.value)} style={{padding:8,borderRadius:8}}>
            {vms.map(v=> <option key={v} value={v}>{v}</option>)}
          </select>
          <a href={selected ? `/EpicVM/vm/${encodeURIComponent(selected)}/` : '/EpicVM/Dashboard'} target="_blank" rel="noreferrer"><Button>Open selected VM</Button></a>
        </div>
        <div style={{marginTop:12,fontSize:13,color:'var(--muted)'}}>For VM maintenance, use the supported read-only diagnostics above and connect through the VM console for interactive work.</div>
      </div>
    </div>
  )
}
