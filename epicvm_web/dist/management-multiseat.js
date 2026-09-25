/* EpicVM Management MultiSeat overlay. Kept separate from the main SPA bundle. */
(() => {
  if (!/^\/EpicVM\/Management\/?$/i.test(location.pathname)) return
  const api = '/EpicVM/api'
  const id = 'epicvm-multiseat-assignment'
  const request = async (path, options = {}) => {
    const response = await fetch(api + path, { credentials: 'same-origin', cache: 'no-store', ...options })
    const body = await response.json()
    if (!response.ok || body.ok === false) throw new Error(body.error || 'Request failed.')
    return body
  }
  const option = (value, label) => {
    const element = document.createElement('option')
    element.value = value
    element.textContent = label
    return element
  }
  const label = (title, control) => {
    const wrapper = document.createElement('label')
    wrapper.textContent = title
    wrapper.append(control)
    return wrapper
  }
  async function mount(form) {
    if (form.parentElement.querySelector('#' + id)) return
    form.hidden = true
    const panel = document.createElement('section')
    panel.id = id
    panel.setAttribute('aria-label', 'MultiSeat desktop assignments')
    const heading = document.createElement('h3')
    heading.textContent = 'Assign a MultiSeat desktop'
    const description = document.createElement('p')
    description.textContent = 'Choose a Windows desktop and an approved account. Each account gets its own seat on the selected host.'
    const host = document.createElement('select')
    host.setAttribute('aria-label', 'MultiSeat Windows desktop')
    const user = document.createElement('select')
    user.setAttribute('aria-label', 'Approved account for personal desktop')
    const button = document.createElement('button')
    button.type = 'submit'
    button.textContent = 'Assign personal desktop'
    const status = document.createElement('p')
    status.setAttribute('role', 'status')
    const grants = document.createElement('div')
    const assignment = document.createElement('form')
    assignment.append(label('MultiSeat Windows desktop', host), label('Approved account', user), button)
    panel.append(heading, description, assignment, status, grants)
    form.after(panel)
    let hosts = [], users = []
    async function loadGrants() {
      grants.replaceChildren()
      user.replaceChildren(option('', 'Choose an approved account'))
      if (!host.value) return
      const result = await request('/management/host-gaming?hostId=' + encodeURIComponent(host.value))
      const assigned = new Set((result.desktopGrants || []).filter(item => item.realm === 'portal').map(item => item.username))
      for (const account of users) if (!assigned.has(account.username)) user.append(option(account.username, account.username))
      const title = document.createElement('strong')
      title.textContent = 'Assigned to this desktop'
      grants.append(title)
      const list = document.createElement('ul')
      for (const username of [...assigned].sort()) {
        const item = document.createElement('li')
        item.textContent = username
        list.append(item)
      }
      if (!assigned.size) {
        const empty = document.createElement('p')
        empty.textContent = 'No accounts assigned to this desktop.'
        grants.append(empty)
      } else grants.append(list)
      button.disabled = !user.value
    }
    try {
      const [inventory, overview] = await Promise.all([
        request('/management/host-gaming/desktops'), request('/management/overview')
      ])
      hosts = inventory.desktops || []
      users = (overview.users || []).filter(item => item.accountStatus === 'approved')
      host.replaceChildren(option('', 'Choose a Windows desktop'))
      for (const desktop of hosts) host.append(option(desktop.hostId, desktop.displayName || desktop.hostId))
      if (hosts.length) host.value = hosts[0].hostId
      await loadGrants()
      if (!hosts.length) status.textContent = 'No available MultiSeat Windows desktops.'
    } catch (error) { status.textContent = error.message }
    host.addEventListener('change', () => { status.textContent = ''; loadGrants().catch(error => { status.textContent = error.message }) })
    user.addEventListener('change', () => { button.disabled = !user.value })
    assignment.addEventListener('submit', async event => {
      event.preventDefault()
      if (!host.value || !user.value || button.disabled) return
      button.disabled = true
      status.textContent = 'Assigning desktop…'
      try {
        const session = await request('/account/session')
        await request('/management/host-gaming/desktop-grants', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': session.csrfToken },
          body: JSON.stringify({ hostId: host.value, username: user.value, enabled: true })
        })
        await loadGrants()
        status.textContent = 'Desktop assigned.'
      } catch (error) { status.textContent = error.message }
      button.disabled = !user.value
    })
  }
  let scheduled = false
  const observe = () => {
    if (scheduled) return
    scheduled = true
    queueMicrotask(() => {
      scheduled = false
      const native = [...document.querySelectorAll('details')].find(element => element.querySelector('summary')?.textContent?.trim() === 'Native game sessions')
      const oldForm = [...(native?.querySelectorAll('form') || [])].find(element =>
        [...element.querySelectorAll('button')].some(button => button.textContent?.trim() === 'Assign personal desktop'))
      if (oldForm && !oldForm.parentElement.querySelector('#' + id)) mount(oldForm)
    })
  }
  new MutationObserver(observe).observe(document.documentElement, { childList: true, subtree: true })
  observe()
})()
