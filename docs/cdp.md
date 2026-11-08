# cdp: a client of the DevTools protocol for tools

`src/cdp` (package `tk_cdp`; import it as `cdp "<toolkit>/src/cdp"`, or `cdp "gt:cdp"` with the collection) drives a toolkit
window over the Chrome DevTools Protocol, or a browser's pages. A window serves the protocol when it runs with
`TOOLKIT_DEVTOOLS=<port>` ([devtools.md](devtools.md)). The package is for tools and tests: `tk cdp`, `tk screenshots`,
`tk timeline_test`, `site.check`, and the tools of the programs built on the toolkit. It names no product.

One connection serves a whole run. A call waits for its answer. The events that come before the answer are handled on the way:
the frames of a screencast are written as they come.

## A window

```odin
c, ok := cdp.connect(9222)                  // the first target of the port: a window
if !ok { return }                           // nothing listens there yet: try again later
defer cdp.close(&c)
cdp.wait_for(&c, "Lazy column", 5 * time.Second)
cdp.click_text(&c, "Lazy column")
cdp.key(&c, "ctrl+f")
cdp.type_text(&c, "odin")
cdp.wait_idle(&c, 5 * time.Second)
cdp.shot(&c, "out.png")
```

- `connect(port)`: the WebSocket of the first target of `/json/list`. `open(port, path)`: the WebSocket at a path (a browser's
  own, `/devtools/browser/...`, whose pages are sessions of one connection: set `c.session`). `targets(port)` lists them.
- `call(c, method, params)`: `params` is a JSON object as text. The result is in the temporary allocator. A failure prints
  "method: message (code)" once and is kept in `c.failure`; `c.quiet = true` keeps it silent for a caller that says it itself.
- `send(c, method, params)`: a call nobody waits for (an acknowledgement).
- `find`, `find_name`, `has`: the boxes whose text holds a text, or with a name (`Toolkit.find`), as `Box` values.
- `wait_for`, `wait_name` (with `gone`), `wait_idle`: the window waits; nothing in the tool sleeps.
- `click_name`, `click_text`, `type_text`, `key`: input. A key is a name: `Enter`, `Tab`, `Escape` (`esc`), `ArrowDown`
  (`down`), `PageUp`, `F3`, `a`, `ctrl+f`, `shift+Tab`. `key_parts` gives the key, its modifiers and the text it types.
- `screenshot` (the PNG's bytes) and `shot` (a file), optionally a `Clip` in CSS pixels. `window_size`.
- `quote(text)` writes a string as JSON. `number`, `integer` and `str` read a JSON value. `stringify` writes a value as
  `JSON.stringify` does, whole numbers without `.0`.

## Screencasts

```odin
sc := cdp.Screencast{dir = "frames"}
defer cdp.screencast_destroy(&sc)
cdp.screencast_start(&c, &sc, 0)     // 0: each frame drawn
// ... calls, or cdp.pump(&c, 100 * time.Millisecond) while nothing is asked
cdp.screencast_stop(&c)
// sc.names: frame-000000.png..., sc.times: each frame's time in seconds
```

## Scripts

A script is a command per line, as the window's recorder writes it (`Toolkit.startRecording`). `words(line)` splits a line
(JSON's quoted strings are one word). `options(words)` reads `--name value` and `--name` alone. `act(c, command, args)` runs an
action: `click`, `move`, `down`, `up`, `wheel`, `key`, `type`, `wait`, `wait-for`, `idle`, `press`. `read_script(file)` reads a
script, or the actions of a `timeline.json` with their times.

## Timelines

`record_timeline(c, {dir, stop, injected})` records what a person does until `stop` is set (from any thread).
`play_timeline(c, {source, dir, against, realtime, max_diff})` runs a script or a `timeline.json` again. Each takes a picture
after each action and writes the folder that [devtools.md](devtools.md) describes ("Timelines"). Each returns the number of
steps, those that differ from the reference, and the actions.

## Pictures

`png_decode` and `png_read` give RGBA8 (`Picture`) whatever the PNG's format. `png_encode` and `png_write` write one, its rows
filtered as fits each best. `compare(a, b, delta)` gives the share of pixels that differ by more than `delta` of 255 on a
colour channel, and a picture of where (red). `shrink(p, width)` makes a picture `width` pixels wide with a box filter (each
pixel the mean of the area it covers).

## Tests

`src/cdp/cdp_test.odin` tests what needs no window: the WebSocket frames both ways, the answers, the keys, the script's words
and options, the PNG round trip, the comparison and the shrink, a script and a timeline read. `tk timeline_test` runs the
timelines against `examples/whatsnew --headless` over a real socket.
