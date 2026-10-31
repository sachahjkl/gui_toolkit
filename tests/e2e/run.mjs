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
import { act, connect, pressKey, words } from '../../tools/cdp_client.mjs'
import { compare, decodePng, encodePng } from '../../tools/png.mjs'
import { playTimeline, recordTimeline } from '../../tools/timeline.mjs'

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

const { send, on, close } = await connect(port, { retryMs: 20000 })
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

  // what the recorder wrote does the same again
  await send('Toolkit.click', { name: 'nav0' })
  await idle()
  for (const l of lines) await act(send, ...((w) => [w[0], w.slice(1)])(words(l)))
  await idle()
  const again = compare(decodePng(readFileSync(join(baseline, 'merge.png'))), decodePng(await shot()), PIXEL_DELTA)
  if (again.share > MAX_SHARE) fail(`the recorder's script, played: ${(again.share * 100).toFixed(2)}% differ`)
  else pass("the recorder's script, played")

  // a timeline: its files, a run like it passes, a run that went elsewhere does not
  const SCRIPT = join(out, 'script.txt')
  writeFileSync(SCRIPT, 'click --name "nav0"\nidle\nclick --name "nav5"\nidle\n')
  const a = await playTimeline(send, { source: SCRIPT, dir: join(out, 'timeline-a') })
  if (a.steps !== 3 || a.failed) fail(`timeline: ${JSON.stringify(a)}`)
  const page = readFileSync(join(out, 'timeline-a', 'index.html'), 'utf8')
  const trace = JSON.parse(readFileSync(join(out, 'timeline-a', 'trace.json'), 'utf8'))
  const saved = JSON.parse(readFileSync(join(out, 'timeline-a', 'timeline.json'), 'utf8'))
  if (!page.includes('data:image/png;base64,')) fail('timeline: no picture in its page')
  if (!trace.traceEvents.some((e) => e.ph === 'X') || trace.traceEvents.filter((e) => e.ph === 'i').length !== 3) fail('timeline: its trace')
  if (saved.steps.length !== 3 || !saved.frames.length) fail('timeline: its json')
  const same = await playTimeline(send, { source: join(out, 'timeline-a', 'timeline.json'), dir: join(out, 'timeline-b') })
  if (same.failed) fail(`timeline: played again, ${same.failed} step(s) differ`)
  writeFileSync(SCRIPT, 'click --name "nav0"\nidle\nclick --name "nav3"\nidle\n')
  const other = await playTimeline(send, { source: SCRIPT, dir: join(out, 'timeline-c'), against: join(out, 'timeline-a') })
  if (other.failed !== 1) fail(`timeline: another page seen as ${other.failed} step(s) differing`)
  else pass('timeline: files, played again, a difference found')

  // the screencast: frames while something changes, none at rest
  let frames = 0, lastFrame
  on('Page.screencastFrame', (f) => {
    frames++
    lastFrame = decodePng(Buffer.from(f.data, 'base64'))
    send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {})
  })
  await send('Page.startScreencast', { format: 'png', minIntervalMs: 50 })
  await send('Toolkit.click', { name: 'nav1' })
  await idle()
  await new Promise((r) => setTimeout(r, 300))
  const moving = frames
  await new Promise((r) => setTimeout(r, 600))
  await send('Page.stopScreencast')
  if (moving < 1) fail('screencast: no frame')
  else if (frames > moving + 1) fail(`screencast: ${frames - moving} frames at rest`)
  else if (compare(decodePng(readFileSync(join(baseline, 'lazy.png'))), lastFrame, PIXEL_DELTA).share > 0.02) fail('screencast: the last frame is not what the window shows')
  else pass(`screencast: ${frames} frames, the last one what the window shows, none at rest`)

  // the box tree as Chrome's DevTools asks for it
  {
    const seen = []
    const off = ['DOM.childNodeRemoved', 'DOM.childNodeInserted'].map((m) => on(m, () => seen.push(m)))
    const attrs = (n) => { const o = {}; for (let i = 0; i + 1 < (n.attributes || []).length; i += 2) o[n.attributes[i]] = n.attributes[i + 1]; return o }
    const search = (n, f) => { if (f(n)) return n; for (const c of n.children || []) { const r = search(c, f); if (r) return r } return null }
    const root = (await send('DOM.getDocument', { depth: -1 })).root
    const button = search(root, (n) => n.localName === 'button' && attrs(n).id === 'nav0')
    if (root.children?.[0]?.localName !== 'html' || !button) fail('DOM: the tree')
    else {
      const text = search(button, (n) => n.nodeType === 3)
      const model = (await send('DOM.getBoxModel', { nodeId: button.nodeId })).model
      const style = (await send('CSS.getComputedStyleForNode', { nodeId: button.nodeId })).computedStyle
      const ax = (await send('Accessibility.getPartialAXTree', { nodeId: button.nodeId })).nodes[0]
      const at = await send('DOM.getNodeForLocation', { x: model.content[0] + 20, y: model.content[1] + 5 })
      if (!text?.nodeValue || !(model.width > 0) || !style.some((c) => c.name === 'width')) fail('DOM: a box, its text, its model, its style')
      else if (ax.role?.value !== 'button' || ax.backendDOMNodeId !== button.nodeId) fail('DOM: its accessible node')
      else if (!search(button, (n) => n.nodeId === at.nodeId)) fail('DOM: the node at a point')
      else {
        await send('Overlay.highlightNode', { nodeId: button.nodeId, highlightConfig: {} })
        await send('Overlay.hideHighlight')
        await send('Toolkit.click', { name: 'nav2' })
        await idle()
        if (!seen.includes('DOM.childNodeInserted') || !seen.includes('DOM.childNodeRemoved')) fail('DOM: a change of page sends no event')
        else pass(`DOM: ${button.nodeId}, its text "${text.nodeValue}", followed through a change of page`)
      }
    }
    await send('Toolkit.click', { name: 'nav1' })
    await idle()
  }

  // editing from DevTools: live, in sRGB, and gone with the client
  {
    const dt = await connect(port, { retryMs: 2000 })
    const attrs = (n) => { const o = {}; for (let i = 0; i + 1 < (n.attributes || []).length; i += 2) o[n.attributes[i]] = n.attributes[i + 1]; return o }
    const search = (n, f) => { if (f(n)) return n; for (const c of n.children || []) { const r = search(c, f); if (r) return r } return null }
    const root = (await dt.send('DOM.getDocument', { depth: -1 })).root
    const button = search(root, (n) => attrs(n).id === 'nav3')
    const m = (await dt.send('DOM.getBoxModel', { nodeId: button.nodeId })).model.content
    const dpr = (await dt.send('Toolkit.state')).dpi
    const pixel = async () => {
      const p = decodePng(await shot())
      const i = (Math.round((m[1] + 3) * dpr) * p.width + Math.round((m[0] + 4) * dpr)) * 4
      return [p.px[i], p.px[i + 1], p.px[i + 2]]
    }
    const near = (a, b) => a.every((v, k) => Math.abs(v - b[k]) <= 3)
    const rgb = (v) => v.match(/[\d.]+/g).slice(0, 3).map(Number)
    const styleOf = async () => (await dt.send('CSS.getMatchedStylesForNode', { nodeId: button.nodeId })).inlineStyle
    const before = await pixel()
    const style = await styleOf()
    const shown = style.cssProperties.find((p) => p.name === 'background-color')
    if (!shown || !near(rgb(shown.value), before)) fail(`DevTools' colour is not the screen's: ${shown?.value} and ${before}`)
    else {
      const text = style.cssText.replace(shown.value, '#ff0000')
      await dt.send('CSS.setStyleTexts', { edits: [{ styleSheetId: style.styleSheetId, range: style.range, text }] })
      await idle()
      const red = await pixel()
      const label = search(button, (n) => n.nodeType === 3)
      await dt.send('DOM.setNodeValue', { nodeId: label.nodeId, value: 'Edited' })
      await idle()
      const found = (await send('Toolkit.find', { text: 'Edited' })).nodes.length
      await dt.send('DOM.removeNode', { nodeId: search(root, (n) => attrs(n).id === 'nav4').nodeId })
      await idle()
      const removed = (await send('Toolkit.find', { name: 'nav4' })).nodes.length
      if (!near(red, [255, 0, 0])) fail(`a style edited: the box is ${red}`)
      else if (found !== 1) fail('a text edited')
      else if (removed !== 0) fail('a box removed')
      else {
        dt.close()
        await new Promise((r) => setTimeout(r, 150))
        await send('Toolkit.state')
        await idle()
        const back = await pixel()
        const again = (await send('Toolkit.find', { name: 'nav4' })).nodes.length
        if (!near(back, before) || again !== 1) fail(`edits still there without their client: ${back}, ${again}`)
        else pass('DevTools: a colour as on screen, a style, a text and a box edited, gone with the client')
      }
    }
    dt.close()
  }

  // recording a timeline: a picture per action, what a person types gathered, and it plays back the same
  let stopRecording
  const stop = new Promise((r) => { stopRecording = r })
  const rec = recordTimeline(send, { dir: join(out, 'timeline-r'), stop, injected: true })
  await new Promise((r) => setTimeout(r, 400))
  await send('Toolkit.click', { name: 'nav7' })
  await idle()
  await new Promise((r) => setTimeout(r, 400))
  await send('Input.insertText', { text: ' odin' })
  await new Promise((r) => setTimeout(r, 900))
  await send('Toolkit.click', { name: 'nav0' })
  await idle()
  await new Promise((r) => setTimeout(r, 400))
  stopRecording()
  const recorded = await rec
  const wanted = ['click --name "nav7"', 'type " odin"', 'click --name "nav0"']
  if (JSON.stringify(recorded.lines) !== JSON.stringify(wanted)) fail(`timeline recorded: ${JSON.stringify(recorded.lines)}`)
  else {
    const t = JSON.parse(readFileSync(join(out, 'timeline-r', 'timeline.json'), 'utf8')).steps.map((s) => s.t)
    if (!t.every((x, i) => i === 0 || x > t[i - 1])) fail(`timeline recorded: times ${t}`)
    const back = await playTimeline(send, { source: join(out, 'timeline-r', 'timeline.json'), dir: join(out, 'timeline-s'), realtime: true })
    // (the needle now has " odin" twice over: only the field's step and the page differ, the last step is back on the first page)
    const st = JSON.parse(readFileSync(join(out, 'timeline-s', 'timeline.json'), 'utf8')).steps
    if (st.length !== 4 || st[3].differs) fail(`timeline recorded, played: ${JSON.stringify(back)}`)
    else pass(`timeline recorded and played: ${wanted.length} actions at ${t.map((x) => Math.round(x)).join(', ')} ms`)
  }

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
