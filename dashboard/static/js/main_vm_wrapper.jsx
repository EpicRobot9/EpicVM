(function(){
  const React = window.React;
  const ReactDOM = window.ReactDOM;
  const init = window.__VM_WRAPPER_INIT || { vmname:null, vmurl:null };
  const MIN_LOADING_MS = 0;
  const MAX_STREAM_RECOVERIES = 2;

  async function cancelAndWaitForFreshStream(){
    if(!init.moonlightHostId || !init.moonlightUserId || !init.vmurl) return false;
    const attempts = Number(window.sessionStorage.getItem('epicvm-stream-recoveries') || 0);
    if(attempts >= MAX_STREAM_RECOVERIES) return false;
    const source = new URL(init.vmurl, window.location.href);
    const marker = '/stream.html';
    const markerIndex = source.pathname.indexOf(marker);
    if(markerIndex < 0) return false;
    const cancelPath = source.pathname.slice(0, markerIndex) + '/api/host/cancel';
    const response = await fetch(cancelPath, {
      method:'POST', headers:{'Content-Type':'application/json'}, credentials:'same-origin',
      body: JSON.stringify({user:Number(init.moonlightUserId), host_id:Number(init.moonlightHostId)})
    });
    // A closed WebRTC session can make Moonlight return 500 because there is
    // nothing left to cancel. That is already the clean state we need here.
    if(!response.ok && response.status !== 500) return false;
    window.sessionStorage.setItem('epicvm-stream-recoveries', String(attempts + 1));
    await new Promise(resolve => window.setTimeout(resolve, 6000));
    return true;
  }
  window.__epicvmCancelAndRetry = cancelAndWaitForFreshStream;

  function App(){
    const vm = window.useVMStatus(init.vmname, { interval: 1600 });
    const [iframeReady, setIframeReady] = React.useState(true);
    const [frameLoaded, setFrameLoaded] = React.useState(true);
    const [panelOpen, setPanelOpen] = React.useState(false);
    const [panelMounted, setPanelMounted] = React.useState(false);
    const [actionMsg, setActionMsg] = React.useState('');
    const [actionTone, setActionTone] = React.useState('ok');
    const [stopBusy, setStopBusy] = React.useState(false);
     const [logoutBusy, setLogoutBusy] = React.useState(false);
     const [isFullscreen, setIsFullscreen] = React.useState(false);
    const [notification, setNotification] = React.useState(null);
    const [notificationSeenId, setNotificationSeenId] = React.useState('');
    const startMsRef = React.useRef(Date.now());
    const readySinceRef = React.useRef(null);
    const closeTimerRef = React.useRef(null);
    const lastActivitySentRef = React.useRef(0);
    const fullscreenAttemptedRef = React.useRef(false);
    const prefersFullscreen = String(init.vmname || '').trim().toLowerCase() === 'indo';

    React.useEffect(()=>{
      if(!(vm && vm.running)){
        startMsRef.current = Date.now();
        readySinceRef.current = null;
        setIframeReady(false);
        setFrameLoaded(false);
      } else {
        setIframeReady(true);
      }
    }, [vm && vm.running]);

     const goToPortal = React.useCallback(()=>{
       try {
         if(document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(()=>{});
       } catch (_) {}
       window.location.assign('/EpicVM/portal');
     }, []);

     const requestFrameFullscreen = React.useCallback(async()=>{
       const frame = document.getElementById('vmframe');
       if(!frame || !frame.requestFullscreen) throw new Error('Fullscreen is not supported by this browser.');
       try {
         await frame.requestFullscreen({ navigationUI:'hide' });
       } catch (_) {
         await frame.requestFullscreen();
       }
     }, []);

     const installFrameExitHook = React.useCallback((frame)=>{
       try {
         if(frame.contentWindow) frame.contentWindow.close = goToPortal;
         const doc = frame.contentDocument;
         if(!doc) return;
         if(doc.__epicvmExitHandler) doc.removeEventListener('click', doc.__epicvmExitHandler, true);
         const onClick = (event)=>{
           const button = event.target && event.target.closest ? event.target.closest('button') : null;
           if(button && String(button.textContent || '').trim().toLowerCase() === 'exit') {
             window.setTimeout(goToPortal, 350);
           }
          };
           doc.addEventListener('click', onClick, true);
           doc.__epicvmExitHandler = onClick;
           if(prefersFullscreen) {
             let fitStyle = doc.getElementById('epicvm-indo-fit');
             if(!fitStyle) {
               fitStyle = doc.createElement('style');
               fitStyle.id = 'epicvm-indo-fit';
               (doc.head || doc.documentElement).appendChild(fitStyle);
             }
             fitStyle.textContent = '.video-stream{width:100vw!important;height:100vh!important;min-width:0!important;min-height:0!important;max-width:100vw!important;max-height:100vh!important;object-fit:contain!important;}';
           }
           if(doc.__epicvmFullscreenHandler) {
            doc.removeEventListener('pointerdown', doc.__epicvmFullscreenHandler, true);
            doc.removeEventListener('keydown', doc.__epicvmFullscreenHandler, true);
          }
          if(prefersFullscreen) {
            const onFullscreenIntent = ()=>{
              if(document.fullscreenElement || fullscreenAttemptedRef.current) return;
              fullscreenAttemptedRef.current = true;
              requestFrameFullscreen().catch(()=>{ fullscreenAttemptedRef.current = false; });
            };
            doc.addEventListener('pointerdown', onFullscreenIntent, true);
            doc.addEventListener('keydown', onFullscreenIntent, true);
            doc.__epicvmFullscreenHandler = onFullscreenIntent;
          }
       } catch (_) {}
     }, [goToPortal, prefersFullscreen, requestFrameFullscreen]);

     React.useEffect(()=>{
       const frame = document.getElementById('vmframe');
       if(!frame) return;
       const onLoad = ()=> { setFrameLoaded(true); setIframeReady(true); installFrameExitHook(frame); };
       frame.addEventListener('load', onLoad);
       if(frame.contentDocument) installFrameExitHook(frame);
       return ()=> frame.removeEventListener('load', onLoad);
     }, [installFrameExitHook]);

     React.useEffect(()=>{
       const onFullscreenChange = ()=> setIsFullscreen(!!document.fullscreenElement);
       document.addEventListener('fullscreenchange', onFullscreenChange);
       onFullscreenChange();
       return ()=> document.removeEventListener('fullscreenchange', onFullscreenChange);
     }, []);

     const toggleFullscreen = React.useCallback(async()=>{
       try {
          if(document.fullscreenElement) {
            await document.exitFullscreen();
            return;
          }
          fullscreenAttemptedRef.current = true;
          await requestFrameFullscreen();
        } catch (e) {
          fullscreenAttemptedRef.current = false;
          setActionTone('err');
          setActionMsg('Fullscreen was blocked by the browser. Use the browser fullscreen shortcut instead.');
        }
      }, [requestFrameFullscreen]);

    const sendActivity = React.useCallback(async (source)=>{
      const now = Date.now();
      if(now - lastActivitySentRef.current < 15000) return;
      lastActivitySentRef.current = now;
      try { await window.api.noteOptimizerActivity(init.vmname, source || 'vm-wrapper'); } catch (_) {}
    }, []);

    React.useEffect(()=>{
      sendActivity('wrapper-open');
      const onUserSignal = ()=> sendActivity('user-input');
      const onVisible = ()=> { if(document.visibilityState === 'visible') sendActivity('visible'); };
      const events = ['pointerdown', 'keydown', 'mousemove', 'focus'];
      events.forEach(ev => window.addEventListener(ev, onUserSignal, { passive:true }));
      document.addEventListener('visibilitychange', onVisible);
      const timer = setInterval(()=>{
        if(document.visibilityState === 'visible') sendActivity('heartbeat');
      }, 20000);
      return ()=>{
        events.forEach(ev => window.removeEventListener(ev, onUserSignal));
        document.removeEventListener('visibilitychange', onVisible);
        clearInterval(timer);
      };
    }, [sendActivity]);

    React.useEffect(()=>{
      let cancelled = false;
      async function pollNotifications(){
        try{
          const res = await window.api.getVMNotifications(init.vmname, false);
          const items = (res.body && res.body.items) || [];
          const next = items.length ? items[items.length - 1] : null;
          if(!cancelled && next && next.id !== notificationSeenId){
            setNotification(next);
            setNotificationSeenId(next.id);
          }
        }catch(_){ }
      }
      pollNotifications();
      const t = setInterval(pollNotifications, 2000);
      return ()=>{ cancelled = true; clearInterval(t); };
    }, [notificationSeenId]);

    React.useEffect(()=>{
      if(!notification) return;
      const ttlMs = Math.max(4000, (((notification.extra || {}).leadSeconds || 10) + 3) * 1000);
      const t = window.setTimeout(()=> setNotification(null), ttlMs);
      return ()=> window.clearTimeout(t);
    }, [notification]);

    const closePanel = React.useCallback(()=>{
      setPanelOpen(false);
      if(closeTimerRef.current) window.clearTimeout(closeTimerRef.current);
      closeTimerRef.current = window.setTimeout(()=>{
        setPanelMounted(false);
        closeTimerRef.current = null;
      }, 220);
    }, []);

    const openPanel = React.useCallback(()=>{
      if(closeTimerRef.current){
        window.clearTimeout(closeTimerRef.current);
        closeTimerRef.current = null;
      }
      setPanelMounted(true);
      window.requestAnimationFrame(()=> setPanelOpen(true));
    }, []);

    React.useEffect(()=>()=>{
      if(closeTimerRef.current) window.clearTimeout(closeTimerRef.current);
    }, []);

    async function stopVm(){
      if(stopBusy) return;
      setStopBusy(true);
      setActionMsg('');
      try {
        const res = await window.api.stopVMViaPortal(init.vmname);
        if(!res.ok) throw new Error((res.body && (res.body.error || res.body.message)) || `HTTP ${res.status}`);
        setActionTone('ok');
        setActionMsg('Stop request sent. The VM should shut down in a moment.');
      } catch (e) {
        setActionTone('err');
        setActionMsg(String(e));
      }
      setStopBusy(false);
    }

    async function logoutPortal(){
      if(logoutBusy) return;
      setLogoutBusy(true);
      setActionMsg('');
      try {
        const res = await window.api.logoutPortal();
        if(!res.ok) throw new Error((res.body && (res.body.error || res.body.message)) || `HTTP ${res.status}`);
        window.location.href = '/portal/login?next=' + encodeURIComponent(window.location.pathname + window.location.search);
      } catch (e) {
        setActionTone('err');
        setActionMsg(String(e));
      }
      setLogoutBusy(false);
    }

     const bpMode = !!window.__VM_WRAPPER_BP;
     async function setSteamMode(mode){
      try {
        const res = await fetch(`/portal/api/vm/${encodeURIComponent(init.vmname)}/console-pref`, {
          method:'POST', headers:{'Content-Type':'application/json'}, credentials:'same-origin',
          body: JSON.stringify({ bigpicture: mode === 'bp' })
        });
        if(!res.ok){
          const b = await res.json().catch(()=>({}));
          throw new Error(b.error || ('HTTP ' + res.status));
        }
        window.location.reload();
      } catch (e) {
        setActionTone('err');
        setActionMsg('Could not save Steam launch mode: ' + String(e));
        setPanelOpen(true); setPanelMounted(true);
      }
    }

    React.useEffect(()=>{
      let cancelled = false;
      async function check(){
        if(!(vm && vm.running) || !init.vmurl){
          if(!cancelled) {
            setIframeReady(false);
            setFrameLoaded(false);
          }
          return;
        }
        try {
          const res = await fetch(init.vmurl, { method:'GET', cache:'no-store', credentials:'same-origin' });
          const ok = !!(res && res.ok);
          if(ok){
            if(!readySinceRef.current) readySinceRef.current = Date.now();
          } else {
            readySinceRef.current = null;
          }
          const stableReady = ok && !!readySinceRef.current;
          if(!cancelled) setIframeReady(!!stableReady);
        } catch (e) {
          readySinceRef.current = null;
        }
      }
      check();
      const t = setInterval(check, 1200);
      return ()=>{ cancelled = true; clearInterval(t); };
    }, [vm && vm.running, init.vmurl]);

     React.useEffect(()=>{
       const frame = document.getElementById('vmframe');
       if(!frame) return;
       const minElapsed = Date.now() - startMsRef.current >= MIN_LOADING_MS;
       const showFrame = !!(vm && vm.running && iframeReady && frameLoaded && minElapsed);
       if(showFrame){
         if(init.vmurl && frame.src !== init.vmurl){
           if(prefersFullscreen && frame.contentWindow){
             try {
               const stored = JSON.parse(frame.contentWindow.localStorage.getItem('mlSettings') || '{}');
               stored.videoSize = 'native';
               stored.videoSizeCustom = { width:1920, height:1080 };
               frame.contentWindow.localStorage.setItem('mlSettings', JSON.stringify(stored));
             } catch (_) {}
           }
           frame.src = init.vmurl;
         }
         frame.style.display = 'block';
      } else {
        if(vm && vm.running && init.vmurl && frame.src !== init.vmurl){
          frame.src = init.vmurl;
        }
        frame.style.display = 'none';
      }
     }, [vm && vm.running, iframeReady, frameLoaded, init.vmurl, prefersFullscreen]);

    const readyForReveal = !!(vm && vm.running && iframeReady && frameLoaded && (Date.now() - startMsRef.current >= MIN_LOADING_MS));
    const controls = React.createElement(React.Fragment, null,
      notification ? React.createElement('div', {
        style:{position:'fixed',top:18,left:'50%',transform:'translateX(-50%)',zIndex:90,maxWidth:'min(720px,calc(100vw - 24px))',padding:'14px 18px',borderRadius:'18px',border:'1px solid rgba(255,255,255,.14)',background:'linear-gradient(180deg, rgba(120,53,15,.95), rgba(69,26,3,.95))',color:'#fff7ed',boxShadow:'0 18px 40px rgba(0,0,0,.35)',backdropFilter:'blur(16px)'}
      },
        React.createElement('div', { style:{fontWeight:800, marginBottom:4} }, notification.title || 'Optimizer notification'),
        React.createElement('div', { style:{fontSize:14, lineHeight:1.45} }, notification.body || '')
      ) : null,
      !panelOpen ? React.createElement('button', {
        className:'vm-controls-handle',
        type:'button',
        onClick: openPanel,
        title:'Open VM controls'
      }, '≡') : null,
      prefersFullscreen && !isFullscreen ? React.createElement('button', {
        className:'vm-fullscreen-cta',
        type:'button',
        onClick: toggleFullscreen,
        title:'Open Indo in browser fullscreen'
      }, 'Enter fullscreen') : null,
      React.createElement('div', { className:'vm-controls-shell' },
        panelMounted ? React.createElement('div', { className:`vm-controls-panel ${panelOpen ? 'open' : 'closed'}` },
          React.createElement('div', { className:'vm-controls-title' }, 'VM Controls'),
          React.createElement('div', { className:'vm-controls-copy' }, 'Quick wrapper controls for the current VM.'),
          React.createElement('div', { className:'vm-controls-row' },
            React.createElement('button', { className:'btn btn-danger', onClick: stopVm, disabled: stopBusy || !(vm && vm.running) }, stopBusy ? 'Stopping…' : ((vm && vm.running) ? 'Stop VM' : 'VM already stopped')),
             React.createElement('button', { className:'btn btn-secondary', onClick: toggleFullscreen }, isFullscreen ? 'Exit fullscreen' : 'Fullscreen'),
             React.createElement('button', { className:'btn btn-secondary', onClick: goToPortal }, 'Open Portal'),
            React.createElement('button', { className:'btn btn-secondary', onClick: logoutPortal, disabled: logoutBusy }, logoutBusy ? 'Logging out…' : 'Log out'),
            React.createElement('button', { className:'btn btn-ghost', onClick: closePanel }, 'Close')
          ),
          React.createElement('div', { style:{marginTop:'12px'} },
            React.createElement('div', { style:{fontSize:'12px', color:'#9db0d1', marginBottom:'6px'} }, 'Steam launch mode'),
            React.createElement('div', { className:'vm-controls-row' },
              React.createElement('button', {
                className: ('btn ' + (bpMode ? 'btn-primary' : 'btn-secondary')),
                onClick: ()=>setSteamMode('bp'), disabled: bpMode, title:'Launch Steam in Big Picture mode'
              }, 'Big Picture'),
              React.createElement('button', {
                className: ('btn ' + (!bpMode ? 'btn-primary' : 'btn-secondary')),
                onClick: ()=>setSteamMode('win'), disabled: !bpMode, title:'Launch Steam in windowed mode'
              }, 'Windowed')
            )
          ),
          actionMsg ? React.createElement('div', { className:`vm-toast ${actionTone}` }, actionMsg) : null
        ) : null
      )
    );

    return React.createElement(React.Fragment, null,
      controls,
      readyForReveal ? null : React.createElement(window.VMFallback, { vmname:init.vmname, vmurl:init.vmurl, iframeReady: iframeReady || frameLoaded })
    );
  }

  try {
    const root = ReactDOM.createRoot(document.getElementById('root'));
    root.render(React.createElement(App));
  } catch (e) {
    console.error('VM wrapper mount failed', e);
  }
})();
