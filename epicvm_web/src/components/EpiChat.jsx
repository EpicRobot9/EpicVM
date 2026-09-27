import React, { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { ChatCircleDots, PaperPlaneRight, Sparkle, X, Brain, Trash } from '@phosphor-icons/react'
import './EpiChat.css'
import EpiMascot from './EpiMascot'

const API = '/EpicVM/api'

async function request(path, options = {}) {
  const response = await fetch(API + path, {credentials:'same-origin',cache:'no-store',...options})
  const body = await response.json().catch(()=>({}))
  if(!response.ok || body.ok === false) {
    const error = new Error(body.error || 'Epi could not complete that request.')
    error.retryAfter = body.retryAfter
    throw error
  }
  return body
}

export default function EpiChat(){
  const [open,setOpen] = useState(false), [busy,setBusy] = useState(false), [error,setError] = useState('')
  const [draft,setDraft] = useState(''), [session,setSession] = useState(null), [showMemory,setShowMemory] = useState(false)
  const [memories,setMemories] = useState([])
  const [messages,setMessages] = useState([{role:'assistant',text:"Hi, I’m Epi ✦ I can help with EpicVM, check your machines, handle basic troubleshooting, and notify an admin when something needs a human."}])
  const endRef = useRef(null)
  useEffect(()=>{ if(open) request('/account/session').then(setSession).catch(()=>setSession(null)) },[open])
  useEffect(()=>{ endRef.current?.scrollIntoView({behavior:'smooth'}) },[messages,busy,open])
  async function loadMemories(){
    try{ const result=await request('/epi/memories'); setMemories(result.items||[]); setShowMemory(true) }
    catch(e){ setError(e.message) }
  }
  async function send(event){
    event.preventDefault(); const text=draft.trim(); if(!text || busy || !session) return
    setDraft(''); setError(''); setBusy(true); setMessages(items=>[...items,{role:'user',text}])
    try{
      const result=await request('/epi/chat',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':session.csrfToken},body:JSON.stringify({message:text})})
      setMessages(items=>[...items,{role:'assistant',text:result.reply,events:result.toolEvents||[]}])
    }catch(e){
      setError(e.retryAfter ? `${e.message} Try again in about ${e.retryAfter} seconds.` : e.message)
    }finally{ setBusy(false) }
  }
  async function forget(id){
    try{ await request(`/epi/memories/${encodeURIComponent(id)}`,{method:'DELETE',headers:{'Content-Type':'application/json','X-CSRF-Token':session.csrfToken},body:'{}'}); setMemories(items=>items.filter(item=>item.id!==id)) }
    catch(e){ setError(e.message) }
  }
  async function clearMemory(){
    if(!window.confirm('Clear everything Epi remembers for this account, including chat history?')) return
    try{ await request('/epi/memories/clear',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':session.csrfToken},body:'{}'}); setMemories([]); setMessages([{role:'assistant',text:'All cleared. We can start fresh ✦'}]) }
    catch(e){ setError(e.message) }
  }
  return createPortal(<div className={`epi-shell ${open?'is-open':''}`}>
    {!open && <button className="epi-launch" onClick={()=>setOpen(true)} aria-label="Chat with Epi, your EpicVM helper">
      <span className="epi-launch-art"><EpiMascot /></span>
      <span className="epi-launch-copy"><strong>Hi, I’m Epi! <Sparkle size={15} weight="fill" /></strong><span>Need a hand with your VM?</span><span className="epi-launch-action">Chat with me <span aria-hidden="true">↗</span></span></span>
    </button>}
    {open && <section className="epi-panel" aria-label="Chat with Epi">
      <header><div className="epi-avatar"><EpiMascot small /></div><div><strong>Epi</strong><span>{session?.user?.isAdmin?'Admin agent':'EpicVM helper'} · she/her</span></div><button onClick={loadMemories} title="What Epi remembers"><Brain size={20}/></button><button onClick={()=>setOpen(false)} aria-label="Close Epi"><X size={20}/></button></header>
      {showMemory ? <div className="epi-memory"><div className="epi-memory-head"><div><strong>What Epi remembers</strong><span>Only this signed-in account can access these memories.</span></div><button onClick={()=>setShowMemory(false)}>Back</button></div>
        {!memories.length?<p>Nothing saved yet.</p>:memories.map(item=><article key={item.id} className={`${item.state==='outdated'?'outdated':''} ${item.recall_count?'recalled':''}`} style={{marginLeft:`${Math.min(Number(item.depth||0),5)*12}px`}}><span>{item.category}{item.state==='outdated'?' · outdated':item.recall_count?` · recalled ${item.recall_count}×`:''}</span><p>{item.exact_text}</p><button onClick={()=>forget(item.id)} aria-label="Forget this memory"><Trash size={16}/></button></article>)}
        {!!memories.length&&<button className="epi-clear" onClick={clearMemory}>Clear all memory</button>}
      </div> : <><div className="epi-messages">{messages.map((message,index)=><div key={index} className={`epi-message ${message.role}`}><p>{message.text}</p>{message.events?.some(event=>event.notificationSent)&&<small>✓ Administrator notified</small>}</div>)}{busy&&<div className="epi-message assistant thinking"><i/><i/><i/></div>}<div ref={endRef}/></div>
        {error&&<div className="epi-error" role="alert">{error}</div>}
        <form onSubmit={send}><textarea value={draft} onChange={e=>setDraft(e.target.value)} placeholder="Ask about EpicVM or your machines…" maxLength={12000} rows={2} onKeyDown={e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();e.currentTarget.form.requestSubmit()}}}/><button disabled={busy||!draft.trim()||!session} aria-label="Send to Epi"><PaperPlaneRight size={19}/></button></form><footer><ChatCircleDots size={14}/> Epi can make mistakes. Machine permissions stay enforced by EpicVM.</footer></>}
    </section>}
  </div>, document.body)
}
