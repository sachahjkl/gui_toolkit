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
//   play <file>                  runs a script: a command per line, # for comments
//   close                        closes the window (Browser.close)
//   raw <Method.name> [json]     any command
//
// Commands separated by a lone "," run in order on one connection:
//   node tools/cdp.mjs click "Lazy column" , idle , wheel 600 500 10 , idle , shot out.png

import { readFileSync, writeFileSync } from 'node:fs'
import { connect, pressKey } from './cdp_client.mjs'

const args = process.argv.slice(2)
let port = 9222
if (args[0] === '--port') { port = +args[1]; args.splice(0, 2) }

const { send, close } = await connect(port)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function opts(a) {
  const o = { _: [] }
  for (let i = 0; i < a.length; i++) {
    if (a[i].startsWith('--')) { const k = a[i].slice(2); const v = a[i + 1]; if (v === undefined || v.startsWith('--')) o[k] = true; else { o[k] = v; i++ } }
    else o._.push(a[i])
  }
  return o
}

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

// A line of a script: words, with JSON's quoted strings (what the recorder writes).
function words(line) {
  const out = []
  const re = /"(?:[^"\\]|\\.)*"|\S+/g
  for (let m; (m = re.exec(line));) out.push(m[0][0] === '"' ? JSON.parse(m[0]) : m[0])
  return out
}

async function run(cmd, a) {
  const o = opts(a)
  const query = () => (o.name ? { name: o.name } : { text: o._.join(' ') })
  switch (cmd) {
    case 'tree': printTree((await send('Toolkit.getTree', { all: !!o.all })).root); break
    case 'find': for (const n of (await send('Toolkit.find', query())).nodes) console.log(`${n.name || '·'} "${n.text}" @${n.x},${n.y} ${n.w}x${n.h}`); break
    case 'click': {
      const r = await send('Toolkit.click', { ...query(), index: +(o.index || 0), count: +(o.count || 1), button: o.button || 'left' })
      console.log(`clicked at ${r.x},${r.y}`); break
    }
    case 'move': await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: +o._[0], y: +o._[1] }); break
    case 'down': await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: +o._[0], y: +o._[1], button: 'left', buttons: 1, clickCount: 1 }); break
    case 'up': await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: +o._[0], y: +o._[1], button: 'left', buttons: 0, clickCount: 1 }); break
    case 'wheel': await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: +o._[0], y: +o._[1], deltaX: 0, deltaY: +o._[2] * 100 }); break
    case 'key': await pressKey(send, o._[0]); break
    case 'type': await send('Input.insertText', { text: o._.join(' ') }); break
    case 'shot': {
      const p = {}
      if (o._.length >= 5) p.clip = { x: +o._[1], y: +o._[2], width: +o._[3], height: +o._[4], scale: 1 }
      const r = await send('Page.captureScreenshot', { format: 'png', ...p })
      writeFileSync(o._[0], Buffer.from(r.data, 'base64'))
      console.log(`saved ${o._[0]}`); break
    }
    case 'state': console.log(JSON.stringify(await send('Toolkit.state'))); break
    case 'wait': await sleep(+o._[0]); break
    case 'wait-for': await send('Toolkit.waitFor', { ...query(), gone: !!o.gone, ...(o.timeout ? { timeout: +o.timeout } : {}) }); break
    case 'idle': {
      const r = await send('Toolkit.waitIdle', o.timeout ? { timeout: +o.timeout } : {})
      if (!r.idle) console.log('still moving at the timeout')
      break
    }
    case 'metrics': console.log(JSON.stringify(await send('Toolkit.metrics', { reset: !!o.reset }), null, 2)); break
    case 'warnings': for (const w of (await send('Toolkit.warnings')).layout) console.log(w); break
    case 'ax': {
      const q = {}
      if (o._[0]) q.role = o._[0]
      if (o.name) q.accessibleName = o.name
      printAx((await send(o._[0] || o.name ? 'Accessibility.queryAXTree' : 'Accessibility.getFullAXTree', q)).nodes)
      break
    }
    case 'press': {
      const p = { name: o._.join(' '), action: o.action || 'Click', index: +(o.index || 0) }
      if (o.role) p.role = o.role
      if (o.value !== undefined) p.value = o.value
      await send('Toolkit.axAction', p); break
    }
    case 'audit': {
      const { unnamed } = await send('Toolkit.axAudit')
      for (const b of unnamed) console.log(`${b.name || '·'} ${b.key} @${b.x},${b.y} ${b.w}x${b.h}`)
      console.log(`${unnamed.length} without a name`)
      break
    }
    case 'record': {
      await send('Toolkit.startRecording')
      console.log('recording what is done in the window: Enter here to stop')
      await new Promise((r) => process.stdin.once('data', r))
      process.stdin.pause()
      const { lines } = await send('Toolkit.stopRecording')
      writeFileSync(o._[0], lines.join('\n') + '\n')
      console.log(`${lines.length} lines in ${o._[0]}`)
      break
    }
    case 'play':
      for (const line of readFileSync(o._[0], 'utf8').split(/\r?\n/)) {
        if (!line.trim() || line.startsWith('#')) continue
        const w = words(line)
        await run(w[0], w.slice(1))
      }
      break
    case 'close': await send('Browser.close'); break
    case 'raw': console.log(JSON.stringify(await send(o._[0], o._[1] ? JSON.parse(o._[1]) : {}), null, 2)); break
    default: throw new Error(`unknown command: ${cmd}`)
  }
}

const cmds = [[]]
for (const a of args) a === ',' ? cmds.push([]) : cmds[cmds.length - 1].push(a)
try {
  for (const c of cmds) if (c.length) await run(c[0], c.slice(1))
} catch (e) { console.error(e.message); process.exitCode = 1 }
close()
