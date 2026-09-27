(function(){
  window.api = window.api || {};

  async function readJson(res){
    try { return await res.json(); } catch (e) { return { ok:false, error:'Invalid JSON response' }; }
  }

  function hostQuery(hostId){
    try{
      const host = hostId || new URLSearchParams(window.location.search).get('host_id');
      return host ? `?host_id=${encodeURIComponent(host)}` : '';
    }catch(_){ return ''; }
  }

  window.api.startVM = async function(vmname, hostId){
    const res = await fetch(`/portal/api/start/${encodeURIComponent(vmname)}${hostQuery(hostId)}`, {method:'POST'});
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };

  window.api.getVMStatus = async function(vmname, hostId){
    const res = await fetch(`/portal/api/vm/${encodeURIComponent(vmname)}/status${hostQuery(hostId)}`, { cache:'no-store' });
    return await readJson(res);
  };

  window.api.recoverVM = async function(vmname, payload){
    const res = await fetch(`/portal/api/vm/${encodeURIComponent(vmname)}/recover${hostQuery()}`, {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify(payload || {})
    });
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };

  window.api.optimizerSummary = async function(){
    const res = await fetch('/dashboard/api/optimizer/v2/summary', { cache:'no-store' });
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };

  window.api.escalateVM = async function(vmname, payload){
    const res = await fetch(`/portal/api/vm/${encodeURIComponent(vmname)}/escalate${hostQuery()}`, {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify(payload || {})
    });
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };

  window.api.stopVMViaPortal = async function(vmname, hostId){
    const res = await fetch(`/portal/api/stop/${encodeURIComponent(vmname)}${hostQuery(hostId)}`, { method:'POST' });
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };

  window.api.logoutPortal = async function(){
    const res = await fetch('/portal/api/auth/logout', { method:'POST' });
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };
  window.api.getVMNotifications = async function(vmname, clear){
    const suffix = clear ? `?clear=1${hostQuery() ? '&' + hostQuery().slice(1) : ''}` : hostQuery();
    const res = await fetch(`/dashboard/api/vm/${encodeURIComponent(vmname)}/notifications${suffix}`, { cache:'no-store' });
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };

  window.api.noteOptimizerActivity = async function(vmname, source){
    const apiRoot = window.location.pathname.startsWith('/dashboard/')
      ? '/dashboard/api/optimizer/activity/'
      : '/portal/api/optimizer/activity/';
    const res = await fetch(`${apiRoot}${encodeURIComponent(vmname)}`, {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ source: source || 'vm-wrapper' })
    });
    const body = await readJson(res);
    return { ok: !!(res.ok && body && body.ok), status: res.status, body };
  };
})();
