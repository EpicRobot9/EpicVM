import React, { useEffect, useId, useRef } from 'react'

export default function Modal({open, title, onClose, children, width=800}){
  const maxW = typeof width === 'number' ? `${width}px` : width
  const dialogRef = useRef(null)
  const priorFocus = useRef(null)
  const closeCallback = useRef(onClose)
  closeCallback.current = onClose
  const titleId = useId()

  useEffect(()=>{
    if(!open) return undefined
    priorFocus.current = document.activeElement
    const dialog = dialogRef.current
    const focusable = () => [...dialog.querySelectorAll('button:not([disabled]), [href], iframe, input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])')]
    ;(focusable()[0] || dialog).focus()
    function onKeyDown(event){
      if(event.key === 'Escape'){ event.preventDefault(); closeCallback.current?.(); return }
      if(event.key !== 'Tab') return
      const items = focusable()
      if(!items.length){ event.preventDefault(); dialog.focus(); return }
      const first = items[0], last = items[items.length - 1]
      if(event.shiftKey && document.activeElement === first){ event.preventDefault(); last.focus() }
      if(!event.shiftKey && document.activeElement === last){ event.preventDefault(); first.focus() }
    }
    document.addEventListener('keydown', onKeyDown)
    return ()=>{
      document.removeEventListener('keydown', onKeyDown)
      priorFocus.current?.focus?.()
    }
  }, [open])

  if(!open) return null
  return (
    <div className="modal-backdrop" onMouseDown={event=>{ if(event.target === event.currentTarget) onClose?.() }}>
      <div ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex="-1" style={{width:'min(100%, 96vw)',maxWidth:maxW,maxHeight:'90vh',overflow:'auto',padding:12}} className="glass-card">
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'center'}}>
          <h3 id={titleId} style={{margin:0}}>{title}</h3>
          <button onClick={onClose} aria-label={`Close ${title}`} style={{background:'transparent',border:'none',color:'var(--muted)'}}>×</button>
        </div>
        <div style={{marginTop:12}}>{children}</div>
      </div>
    </div>
  )
}
