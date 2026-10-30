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
//   wait <ms>
//   raw <Method.name> [json]     any command
//
// Commands separated by a lone "," run in order on one connection:
//   node tools/cdp.mjs click "Lazy column" , wait 200 , wheel 600 500 10 , wait 300 , shot out.png

const args = process.argv.slice(2)
let port = 9222
if (args[0] === '--port') { port = +args[1]; args.splice(0, 2) }

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
const ws = new WebSocket(list[0].webSocketDebuggerUrl)
await new Promise((ok, ko) => { ws.onopen = ok; ws.onerror = ko })
let next = 1
const waiting = new Map()
ws.onmessage = (m) => {
  const r = JSON.parse(m.data)
  const w = waiting.get(r.id)
  if (!w) return
  waiting.delete(r.id)
  r.error ? w.ko(new Error(`${r.error.message} (${r.error.code})`)) : w.ok(r.result)
}
const send = (method, params = {}) => new Promise((ok, ko) => {
  const id = next++
  waiting.set(id, { ok, ko })
  ws.send(JSON.stringify({ id, method, params }))
})
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const MODS = { alt: 1, ctrl: 2, control: 2, meta: 4, shift: 8 }
const NAMED = { enter: 'Enter', tab: 'Tab', escape: 'Escape', esc: 'Escape', backspace: 'Backspace', delete: 'Delete',
  up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight', home: 'Home', end: 'End',
  pageup: 'PageUp', pagedown: 'PageDown', space: ' ' }

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
    case 'key': {
      const parts = o._[0].split('+'); let mods = 0
      for (const p of parts.slice(0, -1)) mods |= MODS[p.toLowerCase()] || 0
      const last = parts[parts.length - 1]
      const key = NAMED[last.toLowerCase()] || last
      const text = key.length === 1 && !(mods & 2) ? key : ''
      await send('Input.dispatchKeyEvent', { type: 'keyDown', key, text, modifiers: mods })
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key, modifiers: mods })
      break
    }
    case 'type': await send('Input.insertText', { text: o._.join(' ') }); break
    case 'shot': {
      const p = {}
      if (o._.length >= 5) p.clip = { x: +o._[1], y: +o._[2], width: +o._[3], height: +o._[4], scale: 1 }
      const r = await send('Page.captureScreenshot', { format: 'png', ...p })
      const { writeFileSync } = await import('node:fs')
      writeFileSync(o._[0], Buffer.from(r.data, 'base64'))
      console.log(`saved ${o._[0]}`); break
    }
    case 'state': console.log(JSON.stringify(await send('Toolkit.state'))); break
    case 'wait': await sleep(+o._[0]); break
    case 'raw': console.log(JSON.stringify(await send(o._[0], o._[1] ? JSON.parse(o._[1]) : {}), null, 2)); break
    default: throw new Error(`unknown command: ${cmd}`)
  }
}

const cmds = [[]]
for (const a of args) a === ',' ? cmds.push([]) : cmds[cmds.length - 1].push(a)
try {
  for (const c of cmds) if (c.length) await run(c[0], c.slice(1))
} catch (e) { console.error(e.message); process.exitCode = 1 }
ws.close()
