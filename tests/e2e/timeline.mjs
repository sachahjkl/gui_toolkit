#!/usr/bin/env node
// tools/timeline.mjs and tools/cdp_client.mjs, which are Node programs, against examples/whatsnew as a program of its own (--headless, WARP) over a real socket:
// a timeline's files, played again, a difference found, a timeline recorded and played back. The program must end by itself with exit code 0. (What the protocol
// does is tested in the process: tests/examples/whatsnew_test.odin; the socket by itself: tests/devtools.)
//
//   odin build examples/whatsnew -vet -out:build/whatsnew.exe && node tests/e2e/timeline.mjs [--exe build/whatsnew.exe] [--out build/e2e] [--port 9477]

import { spawn } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { connect } from '../../tools/cdp_client.mjs'
import { playTimeline, recordTimeline } from '../../tools/timeline.mjs'

const flag = (name, def) => { const i = process.argv.indexOf(`--${name}`); return i < 0 ? def : process.argv[i + 1] }
const exe = flag('exe', 'build/whatsnew.exe')
const out = flag('out', 'build/e2e')
const port = +flag('port', 9477)
mkdirSync(out, { recursive: true })

// What the recording waits around each action: what a person leaves between two.
const RECORD_PAUSE_MS = 400
const TYPED_PAUSE_MS = 900
// A program that has been told to close has this long.
const END_LIMIT_MS = 15000

let failed = 0
const fail = (what) => { failed++; console.log(`FAIL ${what}`) }
const pass = (what) => console.log(`ok   ${what}`)

const child = spawn(exe, ['--headless'], { env: { ...process.env, TOOLKIT_DEVTOOLS: String(port) }, stdio: ['ignore', 'ignore', 'pipe'] })
let stderr = ''
child.stderr.on('data', (d) => { stderr += d })
const ended = new Promise((r) => child.on('exit', (code, signal) => r({ code, signal })))

const { send, close } = await connect(port, { retryMs: 20000 })
const idle = async () => {
  const r = await send('Toolkit.waitIdle', { timeout: 10000 })
  if (!r.idle) fail('still moving after 10 s')
}

try {
  // a timeline: its files, a run like it passes, a run that went elsewhere does not (each starts with the pointer where the last one left it)
  await send('Toolkit.click', { name: 'nav5' })
  await idle()
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

  // recording a timeline: a picture per action, what a person types gathered, and it plays back the same
  let stopRecording
  const stop = new Promise((r) => { stopRecording = r })
  const rec = recordTimeline(send, { dir: join(out, 'timeline-r'), stop, injected: true })
  await new Promise((r) => setTimeout(r, RECORD_PAUSE_MS))
  await send('Toolkit.click', { name: 'nav7' })
  await idle()
  await new Promise((r) => setTimeout(r, RECORD_PAUSE_MS))
  await send('Input.insertText', { text: ' odin' })
  await new Promise((r) => setTimeout(r, TYPED_PAUSE_MS))
  await send('Toolkit.click', { name: 'nav0' })
  await idle()
  await new Promise((r) => setTimeout(r, RECORD_PAUSE_MS))
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
  await send('Browser.close').catch(() => {})
} catch (e) {
  fail(`${e.message}`)
} finally {
  close()
}

const timer = setTimeout(() => child.kill(), END_LIMIT_MS)
const end = await ended
clearTimeout(timer)
for (const l of stderr.split('\n')) { if (l.includes('render.damage.')) console.log(l) }   // (a program built with -define:TOOLKIT_DAMAGE_CHECK=true)
if (end.code !== 0) { fail(`exit code ${end.code} ${end.signal || ''}`); console.log(stderr.split('\n').slice(-30).join('\n')) }
else pass('ended with exit code 0')
if (failed) { console.log(`${failed} failed`); process.exit(1) }
console.log('timeline: all good')
