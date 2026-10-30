// A small client of the devtools package (Chrome DevTools Protocol): tools/cdp.mjs and tests/e2e use it. Node 22+ (its
// built-in WebSocket), no package.

export async function connect(port, { retryMs = 0 } = {}) {
  const until = Date.now() + retryMs
  let list
  for (;;) {
    try {
      list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
      break
    } catch (e) {
      if (Date.now() >= until) throw new Error(`nothing listens on port ${port} (TOOLKIT_DEVTOOLS=${port})`)
      await new Promise((r) => setTimeout(r, 100))
    }
  }
  const ws = new WebSocket(list[0].webSocketDebuggerUrl)
  await new Promise((ok, ko) => { ws.onopen = ok; ws.onerror = () => ko(new Error('the WebSocket did not open')) })
  let next = 1
  const waiting = new Map()
  const listeners = new Map()
  ws.onmessage = (m) => {
    const r = JSON.parse(m.data)
    if (r.method) { for (const f of listeners.get(r.method) || []) f(r.params); return }
    const w = waiting.get(r.id)
    if (!w) return
    waiting.delete(r.id)
    r.error ? w.ko(new Error(`${w.method}: ${r.error.message} (${r.error.code})`)) : w.ok(r.result)
  }
  ws.onclose = () => { for (const w of waiting.values()) w.ko(new Error(`${w.method}: the connection closed`)); waiting.clear() }
  const send = (method, params = {}) => new Promise((ok, ko) => {
    const id = next++
    waiting.set(id, { ok, ko, method })
    ws.send(JSON.stringify({ id, method, params }))
  })
  const on = (method, f) => { listeners.set(method, [...(listeners.get(method) || []), f]) }
  return { send, on, close: () => ws.close() }
}

const MODS = { alt: 1, ctrl: 2, control: 2, meta: 4, shift: 8 }
const NAMED = { enter: 'Enter', tab: 'Tab', escape: 'Escape', esc: 'Escape', backspace: 'Backspace', delete: 'Delete',
  up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight', home: 'Home', end: 'End',
  pageup: 'PageUp', pagedown: 'PageDown', space: ' ' }

// A key by its name ("Enter", "ctrl+f", "shift+Tab"): down and up.
export async function pressKey(send, name) {
  const parts = name.split('+'); let mods = 0
  for (const p of parts.slice(0, -1)) mods |= MODS[p.toLowerCase()] || 0
  const last = parts[parts.length - 1]
  const key = NAMED[last.toLowerCase()] || last
  const text = key.length === 1 && !(mods & 2) ? key : ''
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key, text, modifiers: mods })
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key, modifiers: mods })
}

export function opts(a) {
  const o = { _: [] }
  for (let i = 0; i < a.length; i++) {
    if (a[i].startsWith('--')) { const k = a[i].slice(2); const v = a[i + 1]; if (v === undefined || v.startsWith('--')) o[k] = true; else { o[k] = v; i++ } }
    else o._.push(a[i])
  }
  return o
}

// A line of a script: words, with JSON's quoted strings (what the recorder writes).
export function words(line) {
  const out = []
  const re = /"(?:[^"\\]|\\.)*"|\S+/g
  for (let m; (m = re.exec(line));) out.push(m[0][0] === '"' ? JSON.parse(m[0]) : m[0])
  return out
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// The commands that act on the window (what a script holds). False when `cmd` is not one of them.
export async function act(send, cmd, a) {
  const o = opts(a)
  const query = () => (o.name ? { name: o.name } : { text: o._.join(' ') })
  switch (cmd) {
    case 'click': await send('Toolkit.click', { ...query(), index: +(o.index || 0), count: +(o.count || 1), button: o.button || 'left' }); break
    case 'move': await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: +o._[0], y: +o._[1] }); break
    case 'down': await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: +o._[0], y: +o._[1], button: 'left', buttons: 1, clickCount: 1 }); break
    case 'up': await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: +o._[0], y: +o._[1], button: 'left', buttons: 0, clickCount: 1 }); break
    case 'wheel': await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: +o._[0], y: +o._[1], deltaX: 0, deltaY: +o._[2] * 100 }); break
    case 'key': await pressKey(send, o._[0]); break
    case 'type': await send('Input.insertText', { text: o._.join(' ') }); break
    case 'wait': await sleep(+o._[0]); break
    case 'wait-for': await send('Toolkit.waitFor', { ...query(), gone: !!o.gone, ...(o.timeout ? { timeout: +o.timeout } : {}) }); break
    case 'idle': {
      const r = await send('Toolkit.waitIdle', o.timeout ? { timeout: +o.timeout } : {})
      if (!r.idle) console.log('still moving at the timeout')
      break
    }
    case 'press': {
      const p = { name: o._.join(' '), action: o.action || 'Click', index: +(o.index || 0) }
      if (o.role) p.role = o.role
      if (o.value !== undefined) p.value = o.value
      await send('Toolkit.axAction', p); break
    }
    default: return false
  }
  return true
}
