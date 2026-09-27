export function dashboardBasename(pathname = '') {
  return pathname === '/Dashboard' || pathname.startsWith('/Dashboard/')
    ? '/Dashboard'
    : '/EpicVM/Dashboard'
}
