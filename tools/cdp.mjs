#!/usr/bin/env node
// Drive a toolkit window over the Chrome DevTools Protocol (devtools package; the program runs with
// TOOLKIT_DEVTOOLS=<port>). No mouse or keyboard of the machine is touched. Node 22+ (its built-in WebSocket).
//
//   node tools/cdp.mjs [--port 9222] <command> [args] [, <command> [args]]...
//
//   tree [--all]                 the box tree: name, text, rect (CSS pixels), flags
//   find <text> | --name <id>    boxes whose text contains <text> (or named <id>)
//   click <text> | --name <id> [--index n] [--count 2] [--button right]
//   move <x> <y>                 the pointer
//   down <x> <y> | up <x> <y>    a press, a release (left)
//   wheel <x> <y> <notches>      positive scrolls the content down
//   key <name>                   Enter, Tab, Escape, ArrowDown, F3, a, ctrl+f, shift+Tab...
//   type <text>                  text input
//   shot <file.png> [x y w h]    a screenshot (the window's pixels)
//   state                        the build counter, focus, hover, size
//   wait <ms>                    a pause (better: wait-for, idle)
//   wait-for <text> | --name <id> [--gone] [--timeout ms]    until the box is there (or gone); an error after the timeout
//   idle [--timeout ms]          until nothing moves
//   metrics [--reset]            what the frames cost: build, layout, frame times, boxes, latency in a probe build
//   warnings                     the layout's warnings of this build
//   ax [role] [--name text]      the accessibility tree a screen reader gets, or the nodes that answer
//   press <name> [--role button] [--action Click] [--value v] [--index n]   an action as a screen reader asks it
//   audit                        what a screen reader cannot name
//   record <file>                records what a person does until Enter, as a script for `play`
//   record [<file>] --timeline <dir>   the same with a picture after each action: dir/index.html, timeline.json, trace.json
//   play <file>                  runs a script: a command per line, # for comments
//   play <script or timeline.json> --timeline <dir> [--against <dir>] [--realtime] [--max-diff 0.004]
//                                the same with a picture after each action, compared with another run (by default, the
//                                timeline.json it plays); exit code 1 if one differs. --realtime keeps the recorded pauses
//   cast <dir> [--every ms]      the window's frames as PNGs until Enter (Page.startScreencast)
//   close                        closes the window (Browser.close)
//   raw <Method.name> [json]     any command
//
// Commands separated by a lone "," run in order on one connection:
//   node tools/cdp.mjs click "Lazy column" , idle , wheel 600 500 10 , idle , shot out.png

import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { act, connect, opts, words } from './cdp_client.mjs'
import { playTimeline, recordTimeline, readScript } from './timeline.mjs'

const args = process.argv.slice(2)
let port = 9222
if (args[0] === '--port') { port = +args[1]; args.splice(0, 2) }

const { send, on, close } = await connect(port)

const enter = () => new Promise((r) => {
  process.stdin.once('data', r)
  process.once('SIGINT', r)
})

function printTree(n, depth = 0) {
  if (!n) return
  const t = n.text ? ` "${n.text.length > 60 ? n.text.slice(0, 57) + '...' : n.text}"` : ''
  const f = n.flags ? ` [${n.flags.join(' ')}]` : ''
  const st = (n.focused ? ' *focus' : '') + (n.hot ? ' *hot' : '') + (n.scroll !== undefined ? ` scroll ${n.scroll}/${n.scrollMax}` : '')
  console.log(`${'  '.repeat(depth)}${n.name || '·'}${t}  @${n.x},${n.y} ${n.w}x${n.h}${f}${st}`)
  for (const c of n.children || []) printTree(c, depth + 1)
}

function printAx(nodes) {
  const byId = new Map(nodes.map((n) => [n.nodeId, n]))
  const depth = (n) => { let d = 0; for (let p = byId.get(n.parentId); p; p = byId.get(p.parentId)) d++; return d }
  for (const n of nodes) {
    const props = (n.properties || []).map((p) => `${p.name}=${p.value.value}`).join(' ')
    const value = n.value ? ` = "${n.value.value}"` : ''
    console.log(`${'  '.repeat(depth(n))}${n.role.value} "${n.name.value}"${value}${props ? ' ' + props : ''}${n.actions?.length ? ' [' + n.actions.join(' ') + ']' : ''}`)
  }
}

async function run(cmd, a) {
  const o = opts(a)
  const query = () => (o.name ? { name: o.name } : { text: o._.join(' ') })
  switch (cmd) {
    case 'tree': printTree((await send('Toolkit.getTree', { all: !!o.all })).root); break
    case 'find': for (const n of (await send('Toolkit.find', query())).nodes) console.log(`${n.name || '·'} "${n.text}" @${n.x},${n.y} ${n.w}x${n.h}`); break
    case 'shot': {
      const p = {}
      if (o._.length >= 5) p.clip = { x: +o._[1], y: +o._[2], width: +o._[3], height: +o._[4], scale: 1 }
      const r = await send('Page.captureScreenshot', { format: 'png', ...p })
      writeFileSync(o._[0], Buffer.from(r.data, 'base64'))
      console.log(`saved ${o._[0]}`); break
    }
    case 'state': console.log(JSON.stringify(await send('Toolkit.state'))); break
    case 'metrics': console.log(JSON.stringify(await send('Toolkit.metrics', { reset: !!o.reset }), null, 2)); break
    case 'warnings': for (const w of (await send('Toolkit.warnings')).layout) console.log(w); break
    case 'ax': {
      const q = {}
      if (o._[0]) q.role = o._[0]
      if (o.name) q.accessibleName = o.name
      printAx((await send(o._[0] || o.name ? 'Accessibility.queryAXTree' : 'Accessibility.getFullAXTree', q)).nodes)
      break
    }
    case 'audit': {
      const { unnamed } = await send('Toolkit.axAudit')
      for (const b of unnamed) console.log(`${b.name || '·'} ${b.key} @${b.x},${b.y} ${b.w}x${b.h}`)
      console.log(`${unnamed.length} without a name`)
      break
    }
    case 'record': {
      if (o.timeline) {
        console.log('recording what is done in the window, with its pictures and typed text: Enter here to stop')
        const stop = enter().then(() => process.stdin.pause())
        const r = await recordTimeline(send, { dir: o.timeline, stop })
        if (o._[0]) writeFileSync(o._[0], r.lines.join('\n') + '\n')
        console.log(`${r.steps} steps in ${join(o.timeline, 'index.html')}`)
        break
      }
      await send('Toolkit.startRecording')
      console.log('recording what is done in the window: Enter here to stop')
      await enter()
      process.stdin.pause()
      const { lines } = await send('Toolkit.stopRecording')
      writeFileSync(o._[0], lines.join('\n') + '\n')
      console.log(`${lines.length} lines in ${o._[0]}`)
      break
    }
    case 'play': {
      if (o.timeline) {
        const r = await playTimeline(send, { source: o._[0], dir: o.timeline, against: o.against, realtime: !!o.realtime, maxDiff: o['max-diff'] ? +o['max-diff'] : undefined })
        console.log(`${r.steps} steps, ${r.failed} differ: ${join(o.timeline, 'index.html')}`)
        if (r.failed) process.exitCode = 1
        break
      }
      for (const line of readScript(o._[0]).lines) {
        const w = words(line)
        await run(w[0], w.slice(1))
      }
      break
    }
    case 'cast': {
      const { mkdirSync } = await import('node:fs')
      mkdirSync(o._[0], { recursive: true })
      let n = 0
      on('Page.screencastFrame', (f) => {
        n++
        writeFileSync(join(o._[0], `frame-${String(n).padStart(5, '0')}.png`), Buffer.from(f.data, 'base64'))
        send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {})
      })
      await send('Page.startScreencast', { format: 'png', minIntervalMs: +(o.every || 200) })
      console.log('the frames go to the folder: Enter here to stop')
      await enter()
      process.stdin.pause()
      await send('Page.stopScreencast')
      console.log(`${n} frames in ${o._[0]}`)
      break
    }
    case 'close': await send('Browser.close'); break
    case 'raw': console.log(JSON.stringify(await send(o._[0], o._[1] ? JSON.parse(o._[1]) : {}), null, 2)); break
    default: if (!(await act(send, cmd, a))) throw new Error(`unknown command: ${cmd}`)
  }
}

const cmds = [[]]
for (const a of args) a === ',' ? cmds.push([]) : cmds[cmds.length - 1].push(a)
try {
  for (const c of cmds) if (c.length) await run(c[0], c.slice(1))
} catch (e) { console.error(e.message); process.exitCode = 1 }
close()
