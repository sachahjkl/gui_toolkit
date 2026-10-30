#!/usr/bin/env node
// End to end: examples/whatsnew with no window (--headless, WARP), driven over the devtools protocol as a tool would.
// Each page is opened, must show no layout warning and nothing a screen reader cannot name, and must look like its
// reference image; then the scenarios of what broke before (a wheel burst in the lazy column, find with a scope gone, the
// recorder's script played again). The program must end by itself with exit code 0: a crash anywhere is a failure.
//
//   node tests/e2e/run.mjs [--exe build/whatsnew.exe] [--update] [--out build/e2e] [--port 9477]
//
// --update writes the reference images (tests/e2e/baseline, made on WARP: review them like code). What differs goes to
// <out>/<page>.{actual,diff}.png.

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { connect, pressKey } from '../../tools/cdp_client.mjs'
import { compare, decodePng, encodePng } from './png.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const flag = (name, def) => { const i = process.argv.indexOf(`--${name}`); return i < 0 ? def : process.argv[i + 1] }
const update = process.argv.includes('--update')
const exe = flag('exe', 'build/whatsnew.exe')
const out = flag('out', 'build/e2e')
const port = +flag('port', 9477)
const baseline = join(here, 'baseline')
mkdirSync(out, { recursive: true })
if (update) mkdirSync(baseline, { recursive: true })

// A pixel counts as different over this (of 255 on any channel); a page may differ on this share of its pixels (the
// numbers a page shows live: its frame counters, its timings).
const PIXEL_DELTA = 32
const MAX_SHARE = 0.004

const PAGES = [
  ['pacing', '1  Frame pacing'], ['lazy', '2  Lazy column'], ['warning', '3  Layout warnings'], ['emboss', '4  Emboss'],
  ['rich', '5  Rich text'], ['merge', '6  next_merge'], ['wheel', '7  Wheel'], ['find', '8  Find'],
  ['smooth', '9  Smooth'], ['box_at', '10  box_at'], ['webgpu', '11  WebGPU'], ['tests', '12  Test guard'],
]

let failed = 0
const fail = (what) => { failed++; console.log(`FAIL ${what}`) }
const pass = (what) => console.log(`ok   ${what}`)

const child = spawn(exe, ['--headless'], { env: { ...process.env, TOOLKIT_DEVTOOLS: String(port) }, stdio: ['ignore', 'ignore', 'pipe'] })
let stderr = ''
child.stderr.on('data', (d) => { stderr += d })
const ended = new Promise((r) => child.on('exit', (code, signal) => r({ code, signal })))
let dead = false
ended.then((e) => { dead = true; if (e.code !== 0 && !closing) console.log(`the program ended early: ${JSON.stringify(e)}`) })
let closing = false

const { send, close } = await connect(port, { retryMs: 20000 })
const idle = async () => {
  const r = await send('Toolkit.waitIdle', { timeout: 10000 })
  if (!r.idle) fail('still moving after 10 s')
}

async function shot() {
  const r = await send('Page.captureScreenshot', { format: 'png' })
  return Buffer.from(r.data, 'base64')
}

async function checkPage(name) {
  const w = (await send('Toolkit.warnings')).layout
  if (w.length) fail(`${name}: layout warnings: ${w.join(' | ')}`)
  const { unnamed } = await send('Toolkit.axAudit')
  if (unnamed.length) fail(`${name}: ${unnamed.length} control(s) a screen reader cannot name: ${JSON.stringify(unnamed.slice(0, 3))}`)
  const png = await shot()
  const file = join(baseline, `${name}.png`)
  if (update) { writeFileSync(file, png); pass(`${name}: reference written`); return }
  if (!existsSync(file)) { fail(`${name}: no reference image`); writeFileSync(join(out, `${name}.actual.png`), png); return }
  const r = compare(decodePng(readFileSync(file)), decodePng(png), PIXEL_DELTA)
  if (r.sizeDiffers) { fail(`${name}: another size`); return }
  if (r.share > MAX_SHARE) {
    fail(`${name}: ${(r.share * 100).toFixed(2)}% of the pixels differ (see ${out})`)
    writeFileSync(join(out, `${name}.actual.png`), png)
    writeFileSync(join(out, `${name}.diff.png`), encodePng(r.diff, r.width, r.height))
  } else {
    pass(`${name} (${(r.share * 100).toFixed(3)}% differ)`)
  }
}

try {
  // each page, by what a screen reader calls its button
  for (const [name, label] of PAGES) {
    await send('Toolkit.axAction', { role: 'button', name: label, action: 'Click' })
    await idle()
    await checkPage(name)
  }

  // the lazy column: a burst of the wheel, and items in view at the end (it once showed an empty view)
  await send('Toolkit.click', { text: '2  Lazy column' })
  await idle()
  for (let i = 0; i < 12; i++) await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: 700, y: 400, deltaX: 0, deltaY: 1500 })
  await idle()
  const m = await send('Toolkit.metrics')
  if (m.lazyBuilt <= 0 || m.lazyBuilt > 200) fail(`lazy column: ${m.lazyBuilt} items built`)
  else pass(`lazy column after a burst: ${m.lazyBuilt} items built, a build at ${m.buildMs.max} ms at most`)
  const { nodes } = await send('Toolkit.find', { text: 'Item ' })
  if (!nodes.some((n) => n.y >= 0 && n.y < 720)) fail('lazy column: nothing in view after a burst')

  // find in a page, then leave the page with its scope gone (it once crashed)
  await send('Toolkit.click', { text: '8  Find' })
  await idle()
  await pressKey(send, 'ctrl+f')
  await send('Input.insertText', { text: 'the' })
  await idle()
  await send('Toolkit.click', { text: '1  Frame pacing' })
  await idle()
  await send('Toolkit.waitFor', { text: '1  Frame pacing', timeout: 2000 })
  pass('find, then leaving its page')

  // a wait that must time out says so
  const timedOut = await send('Toolkit.waitFor', { text: 'no such text anywhere', timeout: 100 }).then(() => false, () => true)
  if (!timedOut) fail('waitFor did not time out')
  else pass('waitFor times out')

  // the recorder: what is done becomes a script that does the same
  await send('Toolkit.startRecording', { injected: true })
  await send('Toolkit.click', { text: '6  next_merge' })
  await idle()
  const { lines } = await send('Toolkit.stopRecording')
  if (lines[0] !== 'click --name "nav5"') fail(`recorder: ${JSON.stringify(lines)}`)
  else pass(`recorder: ${lines.join(' ; ')}`)

  // a crash waits here: ends by itself, exit code 0
  closing = true
  await send('Browser.close').catch(() => {})
} catch (e) {
  fail(`${e.message}`)
  closing = true
} finally {
  close()
}

const timer = setTimeout(() => child.kill(), 15000)
const end = await ended
clearTimeout(timer)
if (end.code !== 0) { fail(`exit code ${end.code} ${end.signal || ''}`); console.log(stderr.split('\n').slice(-30).join('\n')) }
else pass('ended with exit code 0')
if (failed) { console.log(`${failed} failed`); process.exit(1) }
console.log('e2e: all good')
