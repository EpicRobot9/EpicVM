(function(){
  const React = window.React;
  const { useState, useEffect, useMemo } = React;

  function statusTone(vm){
    if(vm && vm.running) return 'live';
    if(vm && vm.crashed) return 'crashed';
    if(vm && vm.state === 'restarting') return 'recovering';
    return 'down';
  }

  function humanState(vm){
    const recovery = String((vm && vm.recoveryState) || '').toLowerCase();
    if(!vm) return 'Checking VM status…';
    if(recovery.startsWith('protected-degraded')) return 'Protected VM is degraded';
    if(recovery.startsWith('protected-restart') || recovery.startsWith('protected-recover')) return 'Protected VM is recovering carefully';
    if(recovery === 'restart-loop') return 'This VM is stuck in a restart loop';
    if(recovery === 'recovering') return 'This VM is being rebuilt or recovered';
    if(recovery === 'restarting' || vm.state === 'restarting') return 'This VM is restarting';
    if(recovery === 'degraded') return 'This VM is degraded';
    if(vm.running && vm.healthy) return 'Online and healthy';
    if(vm.running) return 'VM is online';
    if(vm.crashed) return 'This VM crashed';
    if(vm.state === 'not-found') return 'This VM is not provisioned correctly';
    return 'This VM is currently down';
  }

  function VMFallback(props){
    const vmname = props.vmname;
    const vmurl = props.vmurl;
    const iframeReady = !!props.iframeReady;
    const vm = window.useVMStatus(vmname, { interval: 1600 });
    const [phase, setPhase] = useState('idle'); // idle | starting | recovering | sending | error | sent
    const [errorMsg, setErrorMsg] = useState('');
    const [details, setDetails] = useState('');
    const [lastCrashAt, setLastCrashAt] = useState(null);

    const tone = useMemo(()=>statusTone(vm), [vm]);

    useEffect(()=>{
      const frame = document.getElementById('vmframe');
      if(frame) frame.style.display = (vm && vm.running && iframeReady) ? 'block' : 'none';
      if(vm && vm.running && vmurl && frame && frame.src !== vmurl){
        frame.src = vmurl;
      }
      if(vm && vm.running && iframeReady){
        if(phase !== 'sent') setPhase('idle');
        setErrorMsg('');
      }
    }, [vm && vm.running, vmurl, iframeReady]);

    async function probeVmUrl(){
      if(!vmurl) return false;
      try{
        const res = await fetch(vmurl, { method:'GET', cache:'no-store', credentials:'same-origin' });
        return !!(res && res.ok);
      }catch(e){
        return false;
      }
    }

    useEffect(()=>{
      if(vm && vm.crashed){
        setLastCrashAt(Date.now());
        if(phase !== 'recovering' && phase !== 'starting'){
          attemptRecover('The VM crashed while loading or in use.', true);
        }
      }
    }, [vm && vm.crashed]);

    async function waitForUp(timeoutMs){
      const started = Date.now();
      let runningSeenAt = null;
      while(Date.now() - started < timeoutMs){
        const status = await window.api.getVMStatus(vmname);
        if(status && status.running){
          if(!runningSeenAt) runningSeenAt = Date.now();
          const ready = await probeVmUrl();
          const runningForMs = Date.now() - runningSeenAt;
          if(ready && runningForMs >= 3000){
            const frame = document.getElementById('vmframe');
            if(frame){
              frame.src = vmurl || frame.src;
              frame.style.display = 'block';
            }
            setPhase('idle');
            return { ok:true, status };
          }
        } else {
          runningSeenAt = null;
        }
        await new Promise(r=>setTimeout(r, 1500));
      }
      return { ok:false, error:`${vmname} did not come online before the timeout.` };
    }

    async function attemptStart(){
      setPhase('starting');
      setErrorMsg('');
      setDetails('');
      try{
        const res = await window.api.startVM(vmname);
        if(!res.ok && !(res.body && /already running/i.test(res.body.error || ''))){
          throw new Error((res.body && (res.body.error || res.body.message)) || `HTTP ${res.status}`);
        }
        const waited = await waitForUp(90000);
        if(!waited.ok){
          setPhase('error');
          setErrorMsg(waited.error || 'Startup timed out.');
          return;
        }
      }catch(e){
        setPhase('error');
        setErrorMsg(String(e));
      }
    }

    async function attemptRecover(reason, autoTriggered){
      setPhase('recovering');
      setErrorMsg('');
      setDetails('');
      try{
        const recovery = String((vm && vm.recoveryState) || '').toLowerCase();
        const mode = recovery === 'restart-loop' ? 'aggressive' : (recovery.startsWith('protected-') ? 'cautious' : 'standard');
        const aggressive = mode === 'aggressive';
        const res = await window.api.recoverVM(vmname, { aggressive, mode, reason });
        const body = res.body || {};
        const attempts = Array.isArray(body.attempts) ? body.attempts : [];
        setDetails(attempts.map(a => `${a.action}: ${a.ok ? 'ok' : (a.stderr || 'failed')}`).join('\n'));
        if(!res.ok || !body.recovered){
          setPhase('error');
          setErrorMsg(autoTriggered ? 'The VM crashed and automatic recovery failed.' : (body.message || 'Recovery failed.'));
          return;
        }
        const waited = await waitForUp(90000);
        if(!waited.ok){
          setPhase('error');
          setErrorMsg('The VM was told to recover, but it still never came back online.');
        }
      }catch(e){
        setPhase('error');
        setErrorMsg(String(e));
      }
    }

    async function sendToHermes(){
      if(phase === 'sending' || phase === 'sent') return;
      setPhase('sending');
      setDetails('');
      try{
        const res = await window.api.escalateVM(vmname, {
          reason: errorMsg || 'User requested Hermes recovery help from VM fallback screen.',
          vmStatus: vm,
          lastCrashAt
        });
        if(!res.ok){
          throw new Error((res.body && res.body.error) || `HTTP ${res.status}`);
        }
        const esc = res.body && res.body.escalation ? res.body.escalation : {};
        const rec = res.body && res.body.recovery ? res.body.recovery : {};
        setPhase('sent');
        setDetails([
          esc.path ? `Saved escalation: ${esc.path}` : null,
          esc.queued ? 'Sent to Hermes successfully.' : (esc.cliError ? `Hermes handoff issue: ${esc.cliError}` : 'Saved locally for Hermes review.'),
          rec && rec.message ? `Recovery: ${rec.message}` : null
        ].filter(Boolean).join('\n'));
      }catch(e){
        setPhase('error');
        setErrorMsg(`Failed to contact Hermes: ${String(e)}`);
      }
    }

    const title = humanState(vm);
    const recovery = String((vm && vm.recoveryState) || '').toLowerCase();
    const subtitle = recovery === 'restart-loop'
      ? 'This VM has been bounced repeatedly. Recreate or escalate it instead of spamming normal restart forever.'
      : (recovery.startsWith('protected-')
        ? 'This VM is being preserved because it looks active or important. Recovery is intentionally more cautious.'
        : (vm && vm.crashed
          ? 'I tried to bring it back automatically. If that failed, you can send the diagnostics to Hermes below.'
          : 'You can power it on here and I’ll switch you over once it is actually alive.'));

    return (
      React.createElement('div', { className:`fallback tone-${tone}`, role:'status' },
        React.createElement('div', { className:'shell' },
          React.createElement('div', { className:'status-pill' }, vm && vm.crashed ? 'Crash detected' : (vm && vm.running ? 'Live' : 'Offline')),
          React.createElement('div', { className:'card hero-card' },
            React.createElement('div', { className:'orb orb-a' }),
            React.createElement('div', { className:'orb orb-b' }),
            React.createElement('div', { className:'hero-content' },
              React.createElement('div', { className:'vm-name' }, vmname),
              React.createElement('h1', { className:'hero-title' }, title),
              React.createElement('p', { className:'hero-subtitle' }, subtitle),
              React.createElement('div', { className:'meta-row' },
                React.createElement('div', { className:'meta-chip' }, `State: ${(vm && (vm.state || vm.status)) || 'checking'}`),
                React.createElement('div', { className:'meta-chip' }, `Recovery: ${(vm && vm.recoveryState) || 'healthy'}`),
                React.createElement('div', { className:'meta-chip' }, `Profile: ${(vm && vm.profile) || 'desktop'}`),
                React.createElement('div', { className:'meta-chip' }, `Exit: ${vm && vm.exitCode != null ? vm.exitCode : '—'}`),
                React.createElement('div', { className:'meta-chip' }, `Health: ${vm && vm.healthy ? 'healthy' : 'unknown'}`)
              ),
              ((phase === 'starting' || phase === 'recovering') || (vm && vm.running && !iframeReady)) && React.createElement('div', { className:'loading-wrap' },
                React.createElement('div', { className:'spinner', 'aria-hidden': true }),
                React.createElement('div', { className:'loading-title' }, phase === 'recovering' ? 'Recovering crashed VM…' : ((vm && vm.running && !iframeReady) ? 'VM is starting up…' : 'Powering on VM…')),
                React.createElement('div', { className:'loading-subtitle' }, 'Waiting for a real healthy response before switching you over.')
              ),
              phase !== 'starting' && phase !== 'recovering' && !(vm && vm.running && !iframeReady) && React.createElement('div', { className:'actions' },
                React.createElement('button', {
                  className:'btn btn-primary',
                  onClick: recovery === 'restart-loop' ? ()=>attemptRecover('Manual aggressive recovery requested from restart-loop state', false) : attemptStart
                }, recovery === 'restart-loop' ? 'Aggressive recovery' : 'Turn on VM'),
                React.createElement('button', {
                  className:'btn btn-secondary',
                  onClick: ()=>attemptRecover(recovery.startsWith('protected-') ? 'Cautious recovery requested for protected VM from dashboard' : 'Manual recovery requested from dashboard', false)
                }, recovery.startsWith('protected-') ? 'Cautious recovery' : 'Try recovery'),
                React.createElement('button', { className:'btn btn-secondary', onClick: ()=>{ window.location.href = '/EpicVM/portal'; } }, 'Open Portal'),
                React.createElement('button', { className:'btn btn-ghost', onClick: ()=>window.location.reload() }, 'Refresh')
              ),
              errorMsg && React.createElement('div', { className:'error-box' },
                React.createElement('div', { className:'error-title' }, vm && vm.crashed ? 'The VM crashed and recovery failed.' : 'An error occurred while starting the VM.'),
                React.createElement('div', { className:'error-message' }, errorMsg),
                React.createElement('div', { className:'actions subactions' },
                  React.createElement('button', {
                    className:'btn btn-primary',
                    onClick: ()=>attemptRecover(errorMsg || 'Retry requested after error', false)
                  }, recovery === 'restart-loop' ? 'Retry aggressive recovery' : (recovery.startsWith('protected-') ? 'Retry cautious recovery' : 'Try again')),
                  React.createElement('button', { className:'btn btn-danger', disabled: phase === 'sending' || phase === 'sent', onClick: sendToHermes }, phase === 'sending' ? 'Sending to Hermes…' : (recovery === 'restart-loop' ? 'Send restart loop to Hermes' : 'Send error to Hermes')),
                  React.createElement('button', { className:'btn btn-secondary', onClick: ()=>window.location.reload() }, 'Reload page')
                )
              ),
              phase === 'sent' && React.createElement('div', { className:'sent-box' },
                React.createElement('strong', null, 'Hermes recovery request sent.'),
                React.createElement('div', { style:{marginTop:8} }, 'Hermes received the diagnostics and will investigate whether the VM can be recovered.')
              ),
              details && React.createElement('pre', { className:'details-box' }, details)
            )
          )
        )
      )
    );
  }

  window.VMFallback = VMFallback;
})();
