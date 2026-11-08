package tk_cdp

import "core:strings"

// The page of a timeline: one file, the pictures in it. `data`: timeline_json with the pictures inline.
@(private)
timeline_page :: proc(data: string) -> string {
	json_, _ := strings.replace_all(data, "<", "\\u003c", context.temp_allocator)
	return strings.concatenate({PAGE_HEAD, json_, PAGE_TAIL}, context.temp_allocator)
}

@(private)
PAGE_HEAD :: `<!doctype html>
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
<script id="data" type="application/json">`
@(private)
PAGE_TAIL :: `</script>
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
