#!/usr/bin/env node
// Checks the site in a real browser, Chrome or Edge with no window, on the pages tools/site_changelog.mjs makes of it (in a
// folder of its own, removed after). The image viewer (site/gallery.js), on the home page and the classic screenshots: a click
// on a capture opens it, the picture loads at its own size, the arrows go through the captures, Esc closes and gives the
// keyboard back to the link. Every page: its links, pictures, styles and scripts are there, and the anchors they point at; it
// links the same page in the other presentation ("Classic version", "Modern version"). The classic pages: no sideways
// scrolling on a phone or a desktop, a skip link the keyboard reaches first and shows, a main landmark, a text for every
// picture, light and dark; the classic home about a screen high.
// Exit code 1 if something differs. Nothing is published: the folder is served on 127.0.0.1 for the time of the check.
//   node tools/site_check.mjs [--site folder] [--shot file.png] [--browser program]
import { execFileSync, spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { dirname, extname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { values: opt } = parseArgs({ options: { site: { type: 'string', default: join(repo, 'site') }, shot: { type: 'string' }, browser: { type: 'string' } } })
const TYPES = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png' }
const CLASSIC = 'classic/'
const DESKTOP = { width: 1400, height: 900 }
const PHONE = { width: 375, height: 812 }
const HOME_SCREENS = 1.5   // the classic home's height, in screens of the desktop at most
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

const made = mkdtempSync(join(tmpdir(), 'site_check_site_'))
const root = join(made, 'site')
execFileSync(process.execPath, [join(repo, 'tools/site_changelog.mjs'), resolve(opt.site), root], { cwd: repo, stdio: 'inherit' })
const pages = readdirSync(root, { recursive: true }).map((f) => f.replaceAll('\\', '/')).filter((f) => f.endsWith('.html')).sort()
const fileOf = (path) => join(root, normalize(path.endsWith('/') ? path + 'index.html' : path))

const server = createServer((req, res) => {
  const file = fileOf(decodeURIComponent(new URL(req.url, 'http://x').pathname))
  if (!file.startsWith(root) || !existsSync(file)) { res.writeHead(404); res.end(); return }
  res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' })
  res.end(readFileSync(file))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const origin = `http://127.0.0.1:${server.address().port}`

const profile = mkdtempSync(join(tmpdir(), 'site_check_'))
const chrome = spawn(browser, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, `--window-size=${DESKTOP.width},${DESKTOP.height}`, '--no-first-run', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] })
const ws = await new Promise((ok, no) => {
  let text = ''
  chrome.stderr.on('data', (d) => { text += d; const m = text.match(/DevTools listening on (ws:\S+)/); if (m) ok(m[1]) })
  chrome.once('exit', () => no(new Error('the browser ended')))
})

let id = 0
const pending = new Map()
const socket = new WebSocket(ws)
await new Promise((r) => socket.addEventListener('open', r, { once: true }))
socket.addEventListener('message', (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
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
    await page_('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code, windowsVirtualKeyCode: { ArrowRight: 39, ArrowLeft: 37, Home: 36, End: 35, Escape: 27, Tab: 9 }[key] })
    await page_('Input.dispatchKeyEvent', { type: 'keyUp', key, code })
    await sleep(100)
  }
  const view = (size) => page_('Emulation.setDeviceMetricsOverride', { ...size, deviceScaleFactor: 1, mobile: size === PHONE })
  const scheme = (value) => page_('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value }] })
  const go = async (path) => {
    await page_('Page.navigate', { url: origin + '/' + path })
    for (let i = 0; i < 100 && (await js('document.readyState')) !== 'complete'; i++) await sleep(50)
  }
  const loaded = () => js(`new Promise((ok) => { const i = document.querySelector('.lightbox img'); const f = () => i.complete && i.naturalWidth ? ok(i.naturalWidth) : setTimeout(f, 30); f() })`)
  await page_('Page.enable')
  await view(DESKTOP)

  for (const path of ['index.html', CLASSIC + 'screenshots.html']) {
    await go(path)
    const count = await js(`document.querySelectorAll('.shot a.frame').length`)
    const pictures = await js(`document.querySelectorAll('.shot img').length`)
    expect(count > 0 && count === pictures, `${path}: every capture is a link (${count} of ${pictures})`)

    // a real click, on the third capture
    const at = await js(`(() => { const a = document.querySelectorAll('.shot a.frame')[2]; a.scrollIntoView({ block: 'center' }); const r = a.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()`)
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) await page_('Input.dispatchMouseEvent', { type, x: at[0], y: at[1], button: type === 'mouseMoved' ? 'none' : 'left', clickCount: type === 'mouseMoved' ? 0 : 1 })
    await sleep(150)
    expect(await js(`document.querySelector('dialog.lightbox').open`), `${path}: a click opens the viewer`)
    expect((await js(`location.pathname`)) === '/' + path, `${path}: the page stays where it is`)
    expect((await loaded()) > 0, `${path}: the picture loads`)
    expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `3 / ${count}`, `${path}: it is the capture clicked`)
    expect((await js(`document.querySelector('.lightbox-caption').textContent.length`)) > 0, `${path}: its caption is shown`)
    const fills = await js(`(() => { const i = document.querySelector('.lightbox img').getBoundingClientRect(); return i.width > 900 && i.bottom <= innerHeight })()`)
    expect(fills, `${path}: the picture is large and within the window`)
    expect((await js(`document.documentElement.scrollWidth <= innerWidth`)), `${path}: no sideways scrolling`)
    if (opt.shot && path === 'index.html') {
      const { data } = await page_('Page.captureScreenshot', { format: 'png' })
      writeFileSync(opt.shot, Buffer.from(data, 'base64'))
      console.log('saved', opt.shot)
    }
    await key('ArrowRight'); await loaded()
    expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `4 / ${count}`, `${path}: Right: the next one`)
    await key('ArrowLeft'); await key('ArrowLeft')
    expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `2 / ${count}`, `${path}: Left: the previous one`)
    await key('End')
    expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `${count} / ${count}`, `${path}: End: the last one`)
    await key('ArrowRight')
    expect((await js(`document.querySelector('.lightbox-count').textContent`)) === `1 / ${count}`, `${path}: Right from the last: the first one`)
    await key('Escape')
    expect(!(await js(`document.querySelector('dialog.lightbox').open`)), `${path}: Esc closes`)
    expect((await js(`document.activeElement === document.querySelectorAll('.shot a.frame')[0]`)), `${path}: the keyboard is back on the link last shown`)
    expect(!(await js(`document.documentElement.classList.contains('lightbox-open')`)), `${path}: the page scrolls again`)
  }

  for (const path of pages) {
    await go(path)
    // what the page loads or links on this site, as paths with their anchor
    const links = await js(`[...document.querySelectorAll('a[href], img[src], link[href], script[src]')].map((e) => new URL(e.href || e.src)).filter((u) => u.origin === location.origin).map((u) => [u.pathname, decodeURIComponent(u.hash.slice(1))])`)
    const broken = links.filter(([p, anchor]) => {
      const file = fileOf(p)
      return !existsSync(file) || (anchor && !readFileSync(file, 'utf8').includes(`id="${anchor}"`))
    }).map(([p, anchor]) => p + (anchor ? '#' + anchor : ''))
    expect(!broken.length, `${path}: its ${links.length} links resolve${broken.length ? ': not ' + broken.join(', ') : ''}`)

    const classic = path.startsWith(CLASSIC)
    const other = classic ? 'Modern version' : 'Classic version'
    const to = await js(`[...document.querySelectorAll('footer a')].filter((a) => a.textContent === ${JSON.stringify(other)}).map((a) => new URL(a.href).pathname)`)
    const same = classic ? path.slice(CLASSIC.length) : CLASSIC + path
    const want = '/' + (classic && !pages.includes(same) ? 'index.html' : same)
    expect(to.length === 1 && fileOf(to[0]) === fileOf(want), `${path}: "${other}" is ${want} (${to.join(', ')})`)
    if (!classic) continue

    expect(await js(`document.querySelectorAll('main#main').length === 1 && !!document.querySelector('header') && !!document.querySelector('nav[aria-label]') && !!document.querySelector('footer')`), `${path}: a main, a header, a nav and a footer`)
    expect(await js(`[...document.images].filter((i) => i.hasAttribute('src')).every((i) => i.hasAttribute('alt'))`), `${path}: every picture shown has a text`)
    await key('Tab')
    expect(await js(`(() => { const a = document.activeElement, r = a.getBoundingClientRect(); return a.matches('a.skip[href="#main"]') && r.left >= 0 && r.top >= 0 && getComputedStyle(a).outlineStyle !== 'none' })()`), `${path}: Tab reaches the skip link first, shown with its focus ring`)
    for (const size of [PHONE, DESKTOP]) {
      await view(size)
      expect(await js(`document.documentElement.scrollWidth <= innerWidth`), `${path}: no sideways scrolling at ${size.width} px`)
    }
    if (path === CLASSIC + 'index.html') {
      const high = await js(`document.documentElement.scrollHeight / innerHeight`)
      expect(high <= HOME_SCREENS, `${path}: ${high.toFixed(2)} screens high (${HOME_SCREENS} at most)`)
    }
    const colors = []
    for (const value of ['light', 'dark']) { await scheme(value); colors.push(await js(`getComputedStyle(document.body).backgroundColor + ' ' + getComputedStyle(document.body).color`)) }
    await scheme('')
    expect(colors[0] !== colors[1], `${path}: light and dark (${colors.join(' / ')})`)
  }
} finally {
  chrome.removeAllListeners('exit')
  const ended = new Promise((r) => chrome.once('exit', r))
  await send('Browser.close').catch(() => chrome.kill())
  await Promise.race([ended, sleep(5000)])
  socket.close()
  server.close()
  rmSync(made, { recursive: true, force: true })
  // (the browser's helpers let go of the profile a moment after it ends)
  try { rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 }) } catch { console.warn(`left behind: ${profile}`) }
}
process.exit(failures.length ? 1 : 0)
