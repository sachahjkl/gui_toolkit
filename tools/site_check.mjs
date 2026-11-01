#!/usr/bin/env node
// Checks the site's image viewer (site/gallery.js) in a real browser, Chrome or Edge with no window: a click on a capture opens
// it, the picture loads at its own size, the arrows go through the captures, Esc closes and gives the keyboard back to the link.
// Exit code 1 if something differs. Nothing is published: the folder is served on 127.0.0.1 for the time of the check.
//   node tools/site_check.mjs [--site folder] [--shot file.png] [--browser program]
import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { dirname, extname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { values: opt } = parseArgs({ options: { site: { type: 'string', default: join(repo, 'site') }, shot: { type: 'string' }, browser: { type: 'string' } } })
const root = resolve(opt.site)
const TYPES = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png' }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const browser = opt.browser ?? [
  process.env.CHROME,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
].find((b) => b && existsSync(b))
if (!browser) { console.error('no Chrome or Edge found: give --browser'); process.exit(2) }

const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname)
  const file = join(root, normalize(path === '/' ? 'index.html' : path))
  if (!file.startsWith(root) || !existsSync(file)) { res.writeHead(404); res.end(); return }
  res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' })
  res.end(readFileSync(file))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const page = `http://127.0.0.1:${server.address().port}/`

const profile = mkdtempSync(join(tmpdir(), 'site_check_'))
const chrome = spawn(browser, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--window-size=1400,900', '--no-first-run', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] })
const ws = await new Promise((ok, no) => {
  let text = ''
  chrome.stderr.on('data', (d) => { text += d; const m = text.match(/DevTools listening on (ws:\S+)/); if (m) ok(m[1]) })
  chrome.once('exit', () => no(new Error('the browser ended')))
})

let id = 0
const pending = new Map()
const events = []
const socket = new WebSocket(ws)
await new Promise((r) => socket.addEventListener('open', r, { once: true }))
socket.addEventListener('message', (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } else events.push(m)
})
const send = (method, params = {}, sessionId) => new Promise((ok, no) => {
  const n = ++id
  pending.set(n, (m) => (m.error ? no(new Error(`${method}: ${m.error.message}`)) : ok(m.result)))
  socket.send(JSON.stringify({ id: n, method, params, sessionId }))
})

const failures = []
const expect = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) failures.push(what) }

try {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
  const page_ = (m, p) => send(m, p, sessionId)
  const js = async (expression) => {
    const r = await page_('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? expression)
    return r.result.value
  }
  const key = async (key, code = key) => {
    await page_('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code, windowsVirtualKeyCode: { ArrowRight: 39, ArrowLeft: 37, Home: 36, End: 35, Escape: 27 }[key] })
    await page_('Input.dispatchKeyEvent', { type: 'keyUp', key, code })
    await sleep(100)
  }
  const loaded = () => js(`new Promise((ok) => { const i = document.querySelector('.lightbox img'); const f = () => i.complete && i.naturalWidth ? ok(i.naturalWidth) : setTimeout(f, 30); f() })`)
  await page_('Page.enable')
  await page_('Page.navigate', { url: page })
  for (let i = 0; i < 100 && (await js('document.readyState')) !== 'complete'; i++) await sleep(50)

  const count = await js(`document.querySelectorAll('.shot a.frame').length`)
  const pictures = await js(`document.querySelectorAll('.shot img').length`)
  expect(count > 0 && count === pictures, `every capture is a link (${count} of ${pictures})`)

  // a real click, on the third capture
  const at = await js(`(() => { const a = document.querySelectorAll('.shot a.frame')[2]; a.scrollIntoView({ block: 'center' }); const r = a.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()`)
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) await page_('Input.dispatchMouseEvent', { type, x: at[0], y: at[1], button: type === 'mouseMoved' ? 'none' : 'left', clickCount: type === 'mouseMoved' ? 0 : 1 })
  await sleep(150)
  expect(await js(`document.querySelector('dialog.lightbox').open`), 'a click opens the viewer')
  expect((await js(`location.pathname`)) === '/', 'the page stays where it is')
  expect((await loaded()) > 0, 'the picture loads')
  expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `3 / ${count}`, 'it is the capture clicked')
  expect((await js(`document.querySelector('.lightbox-caption').textContent.length`)) > 0, 'its caption is shown')
  const fills = await js(`(() => { const i = document.querySelector('.lightbox img').getBoundingClientRect(); return i.width > 900 && i.bottom <= innerHeight })()`)
  expect(fills, 'the picture is large and within the window')
  expect((await js(`document.documentElement.scrollWidth <= innerWidth`)), 'no sideways scrolling')
  if (opt.shot) {
    const { data } = await page_('Page.captureScreenshot', { format: 'png' })
    writeFileSync(opt.shot, Buffer.from(data, 'base64'))
    console.log('saved', opt.shot)
  }
  await key('ArrowRight'); await loaded()
  expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `4 / ${count}`, 'Right: the next one')
  await key('ArrowLeft'); await key('ArrowLeft')
  expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `2 / ${count}`, 'Left: the previous one')
  await key('End')
  expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `${count} / ${count}`, 'End: the last one')
  await key('ArrowRight')
  expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `1 / ${count}`, 'Right from the last: the first one')
  await key('Escape')
  expect(!(await js(`document.querySelector('dialog.lightbox').open`)), 'Esc closes')
  expect((await js(`document.activeElement === document.querySelectorAll('.shot a.frame')[0]`)), 'the keyboard is back on the link last shown')
  expect(!(await js(`document.documentElement.classList.contains('lightbox-open')`)), 'the page scrolls again')
} finally {
  chrome.removeAllListeners('exit')
  const ended = new Promise((r) => chrome.once('exit', r))
  await send('Browser.close').catch(() => chrome.kill())
  await Promise.race([ended, sleep(5000)])
  socket.close()
  server.close()
  // (the browser's helpers let go of the profile a moment after it ends)
  try { rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 }) } catch { console.warn(`left behind: ${profile}`) }
}
process.exit(failures.length ? 1 : 0)
