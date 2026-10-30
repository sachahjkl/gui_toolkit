// A timeline of what happened in a toolkit window: each action with when it happened and a picture of the window after
// it, the time of every frame in between. One folder per run:
//
//   index.html     a page that stands alone (the pictures are in it): send it with a bug report
//   timeline.json  the steps and frames; `cdp.mjs play` runs it again and compares
//   trace.json     Chrome's trace format: chrome://tracing, https://ui.perfetto.dev
//   step-NNN.png   the pictures
//
// What was on screen and what was typed is in there as is: a run on real data is not to be shared as it stands.
//
// While it runs a step only takes its picture, as the window's encoder made it (fast, large) and keeps it in memory. Small
// pictures, comparisons and files all come at the end: a run does not wait for them, and what they cost does not show in
// the frames it measures.
// tools/cdp.mjs is the command line; this module is for scripts (tests/e2e).

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { act, words } from './cdp_client.mjs'
import { compare, decodePng, encodePng, encodePngAsync } from './png.mjs'

// A pixel counts as different over this (of 255 on any channel); a step may differ on this share of its pixels (numbers
// shown live, a caret).
const PIXEL_DELTA = 32
const MAX_SHARE = 0.004
// How long a step waits for the window to rest before its picture.
const SETTLE_MS = 1500

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// A script's lines, from a script or a timeline.json (its steps, with when they happened).
export function readScript(file) {
  const text = readFileSync(file, 'utf8')
  if (file.endsWith('.json')) {
    const steps = JSON.parse(text).steps.filter((s) => s.line !== 'start')
    return { lines: steps.map((s) => s.line), times: steps.map((s) => s.t), dir: dirname(file) }
  }
  return { lines: text.split(/\r?\n/).filter((l) => l.trim() && !l.startsWith('#')) }
}

class Run {
  constructor(send, dir, kind, against, maxDiff) {
    this.send = send
    this.dir = dir
    this.kind = kind
    this.steps = []
    this.frames = []
    this.lastBuild = 0
    this.base = 0
    this.against = against ? JSON.parse(readFileSync(join(against, 'timeline.json'), 'utf8')).steps : null
    this.againstDir = against
    this.maxDiff = maxDiff ?? MAX_SHARE
    this.failed = 0
    this.pictures = []
    mkdirSync(dir, { recursive: true })
  }

  async begin() {
    const r = await this.send('Toolkit.frames', { after: 1e15 })
    this.base = r.now
    this.lastBuild = (await this.send('Toolkit.state')).build
    await this.step('start', r.now)
  }

  // The frames since the last pull; the clock's time now.
  async pull() {
    const r = await this.send('Toolkit.frames', { after: this.lastBuild })
    for (const f of r.frames) {
      this.frames.push({ ...f, t: f.t - this.base })
      this.lastBuild = Math.max(this.lastBuild, f.build)
    }
    return r.now
  }

  // After an action: the window at rest, its picture, how it compares.
  async step(line, at) {
    const idle = await this.send('Toolkit.waitIdle', { timeout: SETTLE_MS })
    const png = Buffer.from((await this.send('Page.captureScreenshot', { format: 'png' })).data, 'base64')
    const image = `step-${String(this.steps.length).padStart(3, '0')}.png`
    this.pictures.push(png)
    this.steps.push({ t: at - this.base, line, image, settled: idle.idle })
    await this.pull()
  }

  // A step's picture made small, written, and compared with the reference.
  async settle(s, n) {
    const pic = decodePng(this.pictures[n])
    this.pictures[n] = null
    writeFileSync(join(this.dir, s.image), await encodePngAsync(pic.px, pic.width, pic.height))
    const other = this.against?.[n]
    if (other) {
      s.against = other.line
      const r = compare(decodePng(readFileSync(join(this.againstDir, other.image))), pic, PIXEL_DELTA)
      if (r.sizeDiffers) {
        s.share = 1
      } else {
        s.share = r.share
        if (r.share > this.maxDiff) {
          s.diff = s.image.replace('.png', '.diff.png')
          writeFileSync(join(this.dir, s.diff), encodePng(r.diff, r.width, r.height))
        }
      }
      s.differs = s.share > this.maxDiff
    } else if (this.against) {
      s.differs = true
      s.against = null
    }
    if (s.differs) this.failed++
  }

  async finish(error) {
    await Promise.all(this.steps.map((s, n) => this.settle(s, n)))
    if (this.against && this.against.length > this.steps.length && !error) this.failed += this.against.length - this.steps.length
    const end = this.steps.length ? Math.max(this.steps[this.steps.length - 1].t, this.frames.at(-1)?.t ?? 0) : 0
    const data = { kind: this.kind, when: new Date().toISOString(), durationMs: end, failed: this.failed, error: error || undefined, steps: this.steps, frames: this.frames }
    writeFileSync(join(this.dir, 'timeline.json'), JSON.stringify(data, null, 1))
    writeFileSync(join(this.dir, 'steps.txt'), this.steps.filter((s) => s.line !== 'start').map((s) => s.line).join('\n') + '\n')
    writeFileSync(join(this.dir, 'trace.json'), JSON.stringify(chromeTrace(data)))
    writeFileSync(join(this.dir, 'index.html'), page(data, this.dir))
    return { steps: this.steps.length, failed: this.failed, lines: this.steps.filter((s) => s.line !== 'start').map((s) => s.line) }
  }
}

// What a person does, until `stop` resolves (or the window goes away: what was seen is kept).
export async function recordTimeline(send, { dir, stop, injected = false }) {
  const run = new Run(send, dir, 'recorded')
  let stopped = false
  stop.then(() => { stopped = true })
  let error
  try {
    await send('Toolkit.startRecording', { injected })
    await run.begin()
    while (!stopped) {
      const { lines } = await send('Toolkit.pollRecording')
      for (const l of lines) if (l.line !== 'idle') await run.step(l.line, l.t)
      await run.pull()
      if (!lines.length) await Promise.race([sleep(250), stop])
    }
    const { lines } = await send('Toolkit.pollRecording')
    for (const l of lines) if (l.line !== 'idle') await run.step(l.line, l.t)
    await send('Toolkit.stopRecording')
  } catch (e) {
    error = e.message
    console.log(`the recording ended: ${e.message}`)
  }
  return await run.finish(error)
}

// A script or a timeline.json run again, a picture after each action. Compared with `against`, or the timeline it plays.
export async function playTimeline(send, { source, dir, against, realtime = false, maxDiff }) {
  const script = readScript(source)
  const reference = against ?? script.dir
  const run = new Run(send, dir, 'played', reference && existsSync(join(reference, 'timeline.json')) ? reference : null, maxDiff)
  let error
  try {
    await run.begin()
    let last = 0
    for (const [i, line] of script.lines.entries()) {
      if (line === 'idle') continue
      if (realtime && script.times) {
        const gap = script.times[i] - last
        last = script.times[i]
        if (gap > 0) await sleep(gap)
      }
      const w = words(line)
      if (!(await act(send, w[0], w.slice(1)))) throw new Error(`not an action: ${line}`)
      await run.step(line, await run.pull())
    }
  } catch (e) {
    error = e.message
    run.failed++
    console.log(`the run ended: ${e.message}`)
  }
  return await run.finish(error)
}

// Chrome's trace format: a slice per build and its layout, a mark per step.
function chromeTrace(d) {
  const us = (ms) => Math.round(ms * 1000)
  const ev = [
    { ph: 'M', pid: 1, tid: 1, name: 'process_name', args: { name: 'toolkit window' } },
    { ph: 'M', pid: 1, tid: 1, name: 'thread_name', args: { name: 'UI' } },
  ]
  for (const f of d.frames) {
    // (a frame is sampled at the next frame's start: its build ended before that; the order and lengths are what they were)
    const ts = f.t - f.totalMs
    ev.push({ ph: 'X', pid: 1, tid: 1, name: 'build', cat: 'ui', ts: us(ts), dur: us(f.totalMs), args: { build: f.build, frameMs: f.frameMs } })
    ev.push({ ph: 'X', pid: 1, tid: 1, name: 'layout', cat: 'ui', ts: us(ts + f.buildMs), dur: us(f.layoutMs) })
    ev.push({ ph: 'C', pid: 1, tid: 1, name: 'frame ms', ts: us(f.t), args: { frameMs: f.frameMs } })
  }
  for (const s of d.steps) ev.push({ ph: 'i', pid: 1, tid: 1, s: 'g', name: s.line, cat: 'step', ts: us(s.t) })
  return { traceEvents: ev, displayTimeUnit: 'ms' }
}

const inline = (dir, file) => `data:image/png;base64,${readFileSync(join(dir, file)).toString('base64')}`

// The page: one file, the pictures in it.
function page(d, dir) {
  const data = {
    ...d,
    steps: d.steps.map((s) => ({ ...s, image: inline(dir, s.image), diff: s.diff ? inline(dir, s.diff) : undefined })),
    frames: d.frames.map((f) => ({ t: f.t, totalMs: f.totalMs, build: f.build })),
  }
  const json = JSON.stringify(data).replace(/</g, '\\u003c')
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Window timeline</title>
<style>
:root { --bg:#f6f6f4; --panel:#fff; --line:#d9d9d4; --ink:#1c1c1a; --weak:#6b6b66; --accent:#a8560f; --bad:#b3261e; --good:#2e7d4f; }
@media (prefers-color-scheme: dark) { :root { --bg:#141413; --panel:#1e1e1c; --line:#33332f; --ink:#ecece8; --weak:#9b9b94; --accent:#fab283; --bad:#ff8a80; --good:#7fcf9f; } }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.45 system-ui,"Segoe UI",sans-serif; }
header { padding:16px; display:flex; flex-wrap:wrap; gap:6px 18px; align-items:baseline; border-bottom:1px solid var(--line); }
h1 { font-size:17px; margin:0; font-weight:600; }
.weak { color:var(--weak); }
.verdict.bad { color:var(--bad); font-weight:600; } .verdict.good { color:var(--good); font-weight:600; }
#strip { display:block; width:100%; height:64px; background:var(--panel); border-bottom:1px solid var(--line); cursor:pointer; }
main { display:grid; grid-template-columns:minmax(220px,320px) minmax(0,1fr); min-height:0; }
ol { list-style:none; margin:0; padding:0; border-right:1px solid var(--line); max-height:calc(100vh - 130px); overflow:auto; }
li button { all:unset; display:block; width:100%; box-sizing:border-box; padding:8px 12px; cursor:pointer; border-bottom:1px solid var(--line); overflow-wrap:anywhere; }
li button:hover { background:var(--panel); }
li button:focus-visible { outline:2px solid var(--accent); outline-offset:-2px; }
li button[aria-current=true] { background:var(--panel); box-shadow:inset 3px 0 0 var(--accent); }
li .t { font-variant-numeric:tabular-nums; color:var(--weak); font-size:12px; display:block; }
li code { font:12.5px ui-monospace,Consolas,monospace; }
li .differs { color:var(--bad); font-size:12px; display:block; }
section { padding:16px; min-width:0; }
.tools { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin-bottom:10px; }
.tools button { font:inherit; color:inherit; background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:5px 11px; cursor:pointer; min-height:32px; }
.tools button:disabled { opacity:.45; cursor:default; }
img { display:block; max-width:100%; height:auto; border:1px solid var(--line); border-radius:4px; }
@media (max-width:720px) { main { grid-template-columns:minmax(0,1fr); } ol { max-height:30vh; border-right:0; border-bottom:1px solid var(--line); } }
</style></head><body>
<header><h1>Window timeline</h1><span class="weak" id="meta"></span><span class="verdict" id="verdict"></span></header>
<svg id="strip" role="img" aria-label="Time of each frame, with a mark at each step"></svg>
<main><ol id="steps"></ol>
<section>
  <div class="tools"><button id="prev">Previous</button><button id="next">Next</button><button id="play">Play</button><button id="diff" hidden>Show the difference</button><span class="weak" id="info"></span></div>
  <img id="shot" alt="">
</section></main>
<script id="data" type="application/json">${json}</script>
<script type="module">
const d = JSON.parse(document.getElementById('data').textContent)
const $ = (id) => document.getElementById(id)
const fmt = (ms) => ms < 1000 ? ms.toFixed(0) + ' ms' : (ms / 1000).toFixed(2) + ' s'
$('meta').textContent = d.steps.length + ' steps, ' + fmt(d.durationMs) + ', ' + d.frames.length + ' frames, ' + d.kind + ' ' + d.when
const compared = d.steps.some((s) => s.against !== undefined)
if (d.error) { $('verdict').textContent = 'Ended early: ' + d.error; $('verdict').classList.add('bad') }
else if (compared) { $('verdict').textContent = d.failed ? d.failed + ' differ' : 'Same as the reference'; $('verdict').classList.add(d.failed ? 'bad' : 'good') }
let cur = 0, showDiff = false, timer = 0
const items = d.steps.map((s, i) => {
  const li = document.createElement('li'), b = document.createElement('button')
  const t = document.createElement('span'); t.className = 't'; t.textContent = fmt(s.t)
  const c = document.createElement('code'); c.textContent = s.line
  b.append(t, c)
  if (s.differs) { const x = document.createElement('span'); x.className = 'differs'; x.textContent = s.share !== undefined ? (s.share * 100).toFixed(2) + '% of the pixels differ' : 'not in the reference'; b.append(x) }
  b.onclick = () => show(i)
  li.append(b); $('steps').append(li)
  return b
})
function show(i) {
  cur = Math.max(0, Math.min(d.steps.length - 1, i))
  const s = d.steps[cur]
  items.forEach((b, k) => b.setAttribute('aria-current', k === cur))
  items[cur].scrollIntoView({ block: 'nearest' })
  $('diff').hidden = !s.diff
  $('diff').textContent = showDiff ? 'Show the picture' : 'Show the difference'
  $('shot').src = showDiff && s.diff ? s.diff : s.image
  $('shot').alt = 'The window after: ' + s.line
  $('info').textContent = 'Step ' + (cur + 1) + ' of ' + d.steps.length + (s.settled === false ? ', still moving when taken' : '')
  $('prev').disabled = cur === 0
  $('next').disabled = cur === d.steps.length - 1
  mark()
}
function stop() { clearTimeout(timer); timer = 0; $('play').textContent = 'Play' }
function advance() {
  if (cur >= d.steps.length - 1) { stop(); return }
  const gap = d.steps[cur + 1].t - d.steps[cur].t
  timer = setTimeout(() => { show(cur + 1); advance() }, Math.min(Math.max(gap, 150), 3000))
}
$('play').onclick = () => { if (timer) { stop(); return }; if (cur >= d.steps.length - 1) show(0); $('play').textContent = 'Pause'; advance() }
$('prev').onclick = () => { stop(); show(cur - 1) }
$('next').onclick = () => { stop(); show(cur + 1) }
$('diff').onclick = () => { showDiff = !showDiff; show(cur) }
addEventListener('keydown', (e) => { if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { e.preventDefault(); stop(); show(cur - 1) } if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { e.preventDefault(); stop(); show(cur + 1) } })
// the strip: a bar per frame (its work), a line per step
const svg = $('strip'), NS = 'http://www.w3.org/2000/svg'
const span = Math.max(d.durationMs, 1), peak = Math.max(1, ...d.frames.map((f) => f.totalMs))
const css = (n) => getComputedStyle(document.documentElement).getPropertyValue(n)
let cursor
function draw() {
  const W = svg.clientWidth || 800, H = svg.clientHeight || 64
  svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H); svg.replaceChildren()
  const el = (name, a) => { const e = document.createElementNS(NS, name); for (const k in a) e.setAttribute(k, a[k]); svg.append(e); return e }
  for (const f of d.frames) { const h = Math.max(1, f.totalMs / peak * (H - 8)); const e = el('rect', { x: f.t / span * W, y: H - h, width: 1.5, height: h, fill: f.totalMs > 16.7 ? css('--bad') : css('--weak') }); const title = document.createElementNS(NS, 'title'); title.textContent = 'build ' + f.build + ': ' + f.totalMs.toFixed(2) + ' ms'; e.append(title) }
  for (const s of d.steps) el('line', { x1: s.t / span * W, x2: s.t / span * W, y1: 0, y2: H, stroke: s.differs ? css('--bad') : css('--accent'), 'stroke-opacity': .55 })
  cursor = el('line', { y1: 0, y2: H, stroke: css('--ink'), 'stroke-width': 2 })
  mark()
}
function mark() { if (!cursor) return; const x = d.steps[cur].t / span * (svg.clientWidth || 800); cursor.setAttribute('x1', x); cursor.setAttribute('x2', x) }
svg.onclick = (e) => { const r = svg.getBoundingClientRect(), t = (e.clientX - r.left) / r.width * span; let best = 0; d.steps.forEach((s, i) => { if (Math.abs(s.t - t) < Math.abs(d.steps[best].t - t)) best = i }); stop(); show(best) }
addEventListener('resize', draw)
draw(); show(0)
</script></body></html>
`
}
