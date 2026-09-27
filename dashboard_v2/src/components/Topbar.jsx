import React, { useEffect, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { List, TerminalWindow, Bell, Question, UserCircle, SignOut, Sun, Moon } from '@phosphor-icons/react'
import { useTheme } from '../lib/theme.jsx'
import { MANAGER_NAME } from '../brand'
import apiFetch, { authStatus } from '../lib/fetchWrapper'

const titles = {'/':'Home Overview','/vm':'VM Manager','/resources':'Resource Usage','/logs':'Logs Viewer','/optimizer':'Optimizer Control','/settings':'Settings','/users':'Users & Access','/api':'API & System Info','/tools':'Advanced Tools'}

export default function Topbar({onLogout, onToggleMobile}){
  const {theme,toggle} = useTheme(); const [open,setOpen] = useState(false); const [notifications,setNotifications] = useState([]); const [notificationAdvice,setNotificationAdvice] = useState({}); const [jevBusy,setJevBusy] = useState(false); const [notificationOpen,setNotificationOpen] = useState(false); const [hostOnline,setHostOnline] = useState(false); const [username,setUsername] = useState('…'); const location = useLocation(); const navigate = useNavigate()
  useEffect(()=>{
    let live = true
    authStatus().then(body=>{ if(live && body?.username) setUsername(body.username) }).catch(()=>{})
    const checkHealth = () => apiFetch('/stats').then(res=>{ if(live) setHostOnline(res.ok) }).catch(()=>live && setHostOnline(false))
    const loadNotifications = () => apiFetch('/notifications').then(res=>res.json()).then(body=>{
      if(live && body?.ok && Array.isArray(body.items)) setNotifications(body.items)
    }).catch(()=>{})
    checkHealth(); loadNotifications()
    const timer = window.setInterval(()=>{ checkHealth(); loadNotifications() }, 10000)
    return ()=>{ live = false; window.clearInterval(timer) }
  }, [])
  const clearNotifications = async () => {
    try { await apiFetch('/notifications?clear=1'); setNotifications([]) } catch(e) {}
  }
  const prioritizeNotifications = async () => {
    setJevBusy(true)
    const next = {}
    await Promise.all(notifications.slice(0, 20).map(async item => {
      try{
        const response = await apiFetch('/jev/analyze', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({task:'notification_priority', state:{notification:item, otherNotifications:notifications.map(other=>({id:other.id,title:other.title,body:other.body,vmName:other.vmName||other.name}))}})})
        const body = await response.json().catch(()=>({}))
        if(response.ok && body.ok) next[item.id] = body.advisory
      }catch(e){}
    }))
    setNotificationAdvice(next); setJevBusy(false)
  }
  const orderedNotifications = [...notifications].sort((a,b)=>(notificationAdvice[b.id]?.answers?.priority?.score || 0) - (notificationAdvice[a.id]?.answers?.priority?.score || 0))
  return <div className="topbar-inner">
    <a href="/EpicVM/Management" title="Accounts, VM requests, and reports">Management</a>
    <a href="/EpicVM/settings" title="Your password and requests">My settings</a>
    <div className="topbar-title"><button onClick={onToggleMobile} className="icon-button nav-trigger" aria-label="Open navigation"><List size={22}/></button><strong>{titles[location.pathname] || MANAGER_NAME}</strong></div>
    <div className="topbar-actions"><span className={hostOnline ? 'host-online' : 'host-offline'}><i/>{hostOnline ? 'Host Online' : 'Host Unavailable'}</span><span className="topbar-divider"/><button className="icon-button" aria-label="Open terminal" onClick={()=>navigate('/tools')}><TerminalWindow size={20}/></button><div className="notification-wrap"><button className="icon-button notification-button" aria-label="Notifications" aria-expanded={notificationOpen} onClick={()=>setNotificationOpen(v=>!v)}><Bell size={20}/>{notifications.length > 0 && <b>{notifications.length}</b>}</button>{notificationOpen && <div className="menu-popover notification-popover" role="dialog" aria-label="Notifications"><div className="notification-heading"><strong>Notifications</strong>{notifications.length > 0 && <><button disabled={jevBusy} onClick={prioritizeNotifications}>{jevBusy ? 'Prioritizing…' : 'Prioritize with Jev'}</button><button onClick={clearNotifications}>Clear all</button></>}</div>{notifications.length === 0 ? <p className="notification-empty">No new notifications</p> : orderedNotifications.map(item=><div className="notification-item" key={item.id}><strong>{item.title || 'Notification'}</strong><span>{item.vmName || item.name}</span><p>{item.body || ''}</p>{notificationAdvice[item.id]?.answers?.priority && <small>Jev priority {Number(notificationAdvice[item.id].answers.priority.score || 0).toFixed(1)}{Number(notificationAdvice[item.id]?.answers?.duplicate?.noul || 0) >= .7 ? ' · possible duplicate' : ''}</small>}</div>)}</div>}</div><button className="icon-button" aria-label="Help" onClick={()=>navigate('/api')}><Question size={20}/></button><button className="icon-button" onClick={toggle} aria-label="Toggle color theme">{theme === 'dark' ? <Sun size={19}/> : <Moon size={19}/>}</button><div className="account-menu"><button className="account-trigger" onClick={()=>setOpen(v=>!v)} aria-expanded={open}><UserCircle size={21}/><span>{username}</span></button>{open && <div className="menu-popover" role="menu"><button role="menuitem" onClick={onLogout}><SignOut size={18}/>Logout</button></div>}</div></div>
  </div>
}
