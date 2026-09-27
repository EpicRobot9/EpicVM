import { createRequire } from 'node:module'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const require = createRequire('C:/Users/Epic/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/package.json')
const { chromium } = require('playwright')
const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const base = process.env.EPICVM_STYLE_BASE || 'http://127.0.0.1:5201'
const out = new URL('../recovery-evidence/landing-portal-unified-style/', import.meta.url)
fs.mkdirSync(out, { recursive: true })

const context = await browser.newContext({ viewport: { width: 1365, height: 1000 }, deviceScaleFactor: 1 })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => errors.push(error.message))

await page.route('**/EpicVM/api/me', route => route.fulfill({
  status: 200,
  contentType: 'application/json',
  body: JSON.stringify({ authenticated: true, username: 'alice', accountStatus: 'approved', isAdmin: true }),
}))
await page.route('**/portal/api/vms', route => route.fulfill({
  status: 200,
  contentType: 'application/json',
  body: JSON.stringify({
    summary: { total: 1, ready: 1, provisioning: 0, stopped: 0 },
    vms: [{
      resourceKey: 'vm:epic-pc:one', resourceType: 'vm', host_id: 'epic-pc', name: 'Fixture gaming PC',
      type: 'gaming', placement: 'remote', readiness: 'ready', os: 'Windows 11', cpu: '6 vCPU', memory: '12 GiB',
      wrapperUrl: '#connect', capabilities: { powerStart: true, powerStop: true, restart: true },
    }],
  }),
}))
await page.route('**/EpicVM/api/account/games', route => route.fulfill({
  status: 200,
  contentType: 'application/json',
  body: JSON.stringify({ machines: [] }),
}))

try {
  await page.goto(base + '/EpicVM/', { waitUntil: 'networkidle' })
  await page.getByRole('heading', { name: /Your PC/i }).waitFor()
  for (const section of await page.locator('.evm-section').all()) await section.scrollIntoViewIfNeeded()
  await page.locator('.evm-nav').scrollIntoViewIfNeeded()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  assert.equal(await page.locator('.evm-landing').evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(5, 13, 18)')
  assert.equal(await page.locator('.evm-step').first().evaluate(el => getComputedStyle(el).borderTopWidth), '1px')
  await page.screenshot({ path: new URL('landing-desktop.png', out).pathname.replace(/^\/(\w:)/, '$1'), fullPage: true })

  await page.goto(base + '/EpicVM/portal', { waitUntil: 'networkidle' })
  await page.getByRole('heading', { name: /Your Machines/i }).waitFor()
  await page.getByRole('heading', { name: 'Fixture gaming PC', exact: true }).waitFor()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  assert.equal(await page.locator('.evm-card').first().evaluate(el => getComputedStyle(el).borderTopWidth), '1px')
  assert.equal(await page.locator('.evm-card').first().evaluate(el => getComputedStyle(el).clipPath), 'none')
  await page.screenshot({ path: new URL('portal-desktop.png', out).pathname.replace(/^\/(\w:)/, '$1'), fullPage: true })

  await page.goto(base + '/EpicVM/signin', { waitUntil: 'networkidle' })
  await page.getByRole('heading', { name: 'Sign In', exact: true }).waitFor()
  assert.equal(await page.locator('.evm-auth-page').evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(5, 13, 18)')
  assert.equal(await page.locator('.evm-auth-card').evaluate(el => getComputedStyle(el).borderTopWidth), '3px')
  await page.screenshot({ path: new URL('signin-desktop.png', out).pathname.replace(/^\/(\w:)/, '$1'), fullPage: true })

  await page.goto(base + '/EpicVM/signup', { waitUntil: 'networkidle' })
  await page.getByRole('heading', { name: 'Request Access', exact: true }).waitFor()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: new URL('signup-desktop.png', out).pathname.replace(/^\/(\w:)/, '$1'), fullPage: true })

  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto(base + '/EpicVM/signin', { waitUntil: 'networkidle' })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: new URL('signin-mobile.png', out).pathname.replace(/^\/(\w:)/, '$1'), fullPage: true })
  await page.goto(base + '/EpicVM/signup', { waitUntil: 'networkidle' })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: new URL('signup-mobile.png', out).pathname.replace(/^\/(\w:)/, '$1'), fullPage: true })
  await page.goto(base + '/EpicVM/', { waitUntil: 'networkidle' })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: new URL('landing-mobile.png', out).pathname.replace(/^\/(\w:)/, '$1'), fullPage: true })
  assert.deepEqual(errors, [])
  console.log('PASS: unified landing/portal styling, desktop and mobile overflow, and no page errors.')
} finally {
  await browser.close()
}
