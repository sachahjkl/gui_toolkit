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
  ws.onmessage = (m) => {
    const r = JSON.parse(m.data)
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
  return { send, close: () => ws.close() }
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
