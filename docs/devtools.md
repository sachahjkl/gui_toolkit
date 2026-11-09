# devtools: drive a window over the Chrome DevTools Protocol

The `devtools` package serves a toolkit window over the Chrome DevTools Protocol (CDP), the protocol tools use to
drive Chrome: clicks, keys, text, the wheel, screenshots, the accessibility tree. A test, a script or an agent drives
the interface without the machine's mouse or keyboard, and the window does not need focus or to be on top: the events
go straight into its queue (`platform.inject_event`), as the system's would.

## In an application

```odin
import "gt:devtools"

srv := devtools.start_from_env(win, "My app")   // TOOLKIT_DEVTOOLS=9222 in the environment, else nil
defer devtools.stop(srv)

// each frame, before poll_events and begin_build:
devtools.service(srv, &ui_state, &renderer)
```

`start(win, port, title)` starts it on a port of your choosing. With nil (the variable unset) `service` and `stop` do
nothing, so the calls stay in a release build. A program that goes on after the server ends says so with `stop(srv, &ui_state)`:
the clients' edits, highlight and accessibility tree end with it. What a client held down goes up when it goes, or at `stop`.

## Who can reach it

It listens on 127.0.0.1 only, and 127.0.0.1 alone does not keep a browser out: a WebSocket is not bound by the
same-origin policy, so any page open on the machine could connect and drive the window, and a name made to resolve to
127.0.0.1 could read the endpoints. So these are refused:

- a request with an `Origin` header (403): what a browser's page sends and a tool's client does not. One is taken, on the
  WebSocket only: `devtools://devtools`, Chrome's own DevTools, which a page cannot send;
- a `Host` other than `127.0.0.1:<port>`, `localhost:<port>`, `[::1]:<port>` (403);
- a WebSocket on a path without the target's id (404), a random id given by `/json/list`.

What runs on the machine as any user can still connect, as with Chrome's own `--remote-debugging-port`. In an
application that acts on what it is told (an agent), that is running commands: keep it opt-in, and off for what you
ship to people. A client that stops reading is dropped after 5 s (the answers are written on the UI thread), so is a
connection that sends no request within 5 s, and a message over 16 MB ends its connection. A WebSocket needs `Upgrade: websocket`
and `Sec-WebSocket-Version: 13` (else 400), and a frame RFC 6455 does not allow (a continuation of nothing, a message within a
message, an unknown opcode, an extension's bit) ends the connection.

`service` runs on the UI thread: it takes the commands the connection threads received, injects their input for the
frame about to be built, reads the box tree of the last build, and answers. A command wakes the window
(`platform.wake`), so an idle program answers at once.

## Endpoints

- `GET http://127.0.0.1:<port>/json/version` and `/json/list`: the discovery documents Chrome serves, with the
  `webSocketDebuggerUrl` of the window (one "page" target).
- `ws://127.0.0.1:<port>/devtools/page/<id>`: the protocol (JSON messages `{"id", "method", "params"}`).

## Commands

| Method | What |
|---|---|
| `Input.dispatchMouseEvent` | `mouseMoved`, `mousePressed`, `mouseReleased` (`button`: left, right, middle), `mouseWheel` (`deltaY` in CSS pixels, 100 a notch, positive scrolls the content down). `x`, `y` in CSS pixels (the window's pixels / its DPI scale). |
| `Input.dispatchKeyEvent` | `keyDown` / `rawKeyDown` / `keyUp` with the DOM's `key` ("Enter", "ArrowDown", "a", "F3") or `code`; `keyDown` with `text` also types it; `modifiers`: Alt 1, Ctrl 2, Shift 8. |
| `Input.insertText` | text, as typed. |
| `Page.captureScreenshot` | PNG of the window's pixels (`clip` in CSS pixels), from the renderer's capture: the frame as presented. Encoded on a thread of its own (`png.encode`'s `.Fast`: [png.md](png.md)): the window goes on meanwhile. |
| `Page.getLayoutMetrics` | the window's size in CSS pixels, its DPI scale as the visual viewport's zoom. |
| `Accessibility.getFullAXTree` | the tree a screen reader gets (`ui.a11y_tree`, built while the server runs): role in Chrome's vocabulary (button, textbox, StaticText, checkbox...), name, value, properties (focused, disabled, expanded, selected, checked...), children; and, beyond the protocol, `bounds` in CSS pixels and `actions`. |
| `Accessibility.queryAXTree` | the nodes with a `role` and an `accessibleName` (contained, case ignored; `exact` for all of it). |
| `Browser.getVersion`, `Target.*`, `Page.getFrameTree` | discovery, and attaching in sessions (`Target.attachToTarget`, `setAutoAttach`, the browser's endpoint): what Puppeteer and Playwright use. |
| `Browser.close` | closes the window, as its close button. |
| `Page.startScreencast` `{minIntervalMs?}`, `Page.screencastFrameAck`, `Page.stopScreencast` | the window's frames as `Page.screencastFrame` events, PNG only (`format`, `quality`, `maxWidth` are ignored). One at a time (the next waits for the ack, with the frame's `sessionId`), no faster than `minIntervalMs` (200), none while nothing changes. Each is read back and compared on the UI thread and encoded on a thread of its own, which takes a core while it runs. One client at a time: another's start is refused, its stop and acks do nothing. |
| `*.enable`, `*.disable`, `*.set*` | accepted, nothing to do (what clients send on attaching). |
| `DOM.set*`, `CSS.set*` (but the edits below, `DOM.setInspectedNode`, `DOM.setNodeStackTracesEnabled`, `CSS.setLocalFontsEnabled`), `Page.setDocumentContent`, cookies, DOM storage | refused with an error: they cannot be done, and a client would show them as done. |
| `DOM.getDocument` `{depth?}`, `DOM.requestChildNodes` `{nodeId, depth?}` | the tree as deep as it is asked (1 by default, -1 for all). What the client has is not sent again: in Chrome's frontend each node of an answer is a new object, and the one it is unfolding would never get its children. |
| `DOM.setAttributeValue`, `DOM.setAttributesAsText`, `DOM.removeAttribute` | `aria-label` only: the name a reader gets. The others come from the program, and are refused with a message that says so. |
| `DOM.undo`, `DOM.redo`, `DOM.markUndoableState` | back and forth over the edits (styles, texts, boxes removed, `aria-label`), from mark to mark. |
| `Runtime.evaluate` | refused: there is no JavaScript. |

The `Toolkit` domain reads the box tree (rects in CSS pixels):

| Method | What |
|---|---|
| `Toolkit.getTree` `{all?}` | the tree: `key`, `name` (the id's hash part), `text` (rich paragraphs too), `x y w h`, `flags` (Clickable, Focusable, Text_Input, View_Scroll_Y...), `role`, `label`, `focused`, `hot`, `scroll` / `scrollMax`. Without `all`, only boxes named, with text, interactive, or holding such boxes. |
| `Toolkit.find` `{name? text?}` | boxes named `name` exactly, or whose text contains `text` (ignoring case), in tree order. |
| `Toolkit.click` `{name? text? index? count? button?}` | a click on the middle of the match (the nearest clickable box around it): a move and a press now, the release at the next frame; `count` 2 for a double click. |
| `Toolkit.state` | the build counter, the focused and hovered keys, the size and DPI scale. |
| `Toolkit.waitFor` `{name? text? gone? timeout?}` | answers when such a box is there (its nodes), or gone; an error after `timeout` ms (5000). It counts from two builds on, so input sent before it has been seen. |
| `Toolkit.waitIdle` `{timeout?}` | answers when three builds in a row had nothing moving: `{idle: true}`, or `{idle: false}` at the timeout (a page animating for good). Before a screenshot, in place of a sleep. |
| `Toolkit.metrics` `{reset?}` | the last 240 frames: `buildMs`, `layoutMs`, `totalMs`, `frameMs` (p50, p95, max), `boxes`, `lazyBuilt`, `animating`, `axNodes`, `axMs`; `latencyMs` input to screen in a build with `-define:RENDER_PROBE=true` (null otherwise). `frameMs` counts rests: a program at rest draws nothing. |
| `Toolkit.frames` `{after?}` | the same frames one by one, after build `after`: `build`, `t`, `frameMs`, `buildMs`, `layoutMs`, `totalMs`; `now` on the same clock as `t` (`ui.now_ms`). |
| `Toolkit.warnings` | the layout's warnings of this build (`ui.set_layout_warnings`). |
| `Toolkit.axAction` `{role? name? exact? index? nodeId? action? value?}` | an action on an accessible node, as a screen reader asks it (`ui.a11y_inject`): `Click` by default, `Focus`, `Set_Value`, `Increment`, `Scroll_Into_View`... (`platform.A11y_Action`). An error if the node does not offer it. |
| `Toolkit.axAudit` | `unnamed`: the enabled controls with no name, no text in them and no placeholder (`ui.a11y_unnamed`). A clickable box without one is not even a node: a reader does not know it exists. |
| `Toolkit.startRecording` `{injected?}`, `Toolkit.stopRecording` | what a person does in the window, as lines of a script for `tk cdp play`. Clicks by what they hit (a name, a text), drags and what names nothing by coordinates; typed text as is; the wheel both ways (`wheel x y notches across`). `injected`: the protocol's events too, and `Toolkit.axAction` as `press`. `Toolkit.pollRecording` gives the lines since the last time with when they happened (`t`, as `Toolkit.frames`). A recording is its asker's: another client's commands on it are refused, and when the asker goes it ends and what it held is dropped. A right drag is `down` and `up` with `--button right`; a drag cut by `stopRecording` gets its `up`. |

## tk cdp

The client for the command line is a command of the toolkit's tool, on the client of `src/cdp` ([cdp.md](cdp.md)):

```
$env:TOOLKIT_DEVTOOLS=9222; build\whatsnew.exe   # PowerShell; in bash: TOOLKIT_DEVTOOLS=9222 build/whatsnew
odin run tools/tk -- cdp tree
odin run tools/tk -- cdp click "Lazy column" , idle , wheel 700 400 30 , idle , shot out.png
odin run tools/tk -- cdp key ctrl+f , type odin , key Enter , wait-for "matches"
odin run tools/tk -- cdp press "Send" --role button
odin run tools/tk -- cdp audit
odin run tools/tk -- cdp metrics --reset , click "Lazy column" , idle , metrics
odin run tools/tk -- cdp record steps.txt      # until Enter; then: tk cdp play steps.txt
odin run tools/tk -- cdp cast frames/          # the window's frames as PNGs, until Enter
```

`--port <n>` comes first when the port is not 9222. The head of `tools/tk/cdp.odin` lists every command. For a tool of your own,
the same client is the `cdp` package (`src/cdp`, [cdp.md](cdp.md)); `tools/tk/timeline_test.odin` is an example of one. In the
program's own process, with no socket: `devtools.start_local` and `devtools.Local_Client` (`tests/examples/whatsnew_test.odin`).

## Timelines

A timeline is a run kept whole: each action with when it happened, a picture of the window after it, the time of every
frame in between.

```
odin run tools/tk -- cdp record --timeline run1                                  # what a person does, until Enter
odin run tools/tk -- cdp play run1/timeline.json --timeline run2                 # again; each picture compared with run1's
odin run tools/tk -- cdp play run1/timeline.json --timeline run2 --realtime      # with the recorded pauses
odin run tools/tk -- cdp play steps.txt --timeline run3 --against run1           # a script against a run
```

A folder per run:

- `index.html`: one file, the pictures in it. The steps, a strip of the frames' times (slow ones in red), the picture of
  each step (arrow keys, Play), what differs from the reference.
- `timeline.json`: the steps and frames, what `play` reads.
- `trace.json`: Chrome's trace format, for `chrome://tracing` or https://ui.perfetto.dev: a slice per build and layout, a
  mark per step, a counter of the frame time.
- `steps.txt`, `step-NNN.png`, `step-NNN.diff.png`.

`play` fails (exit code 1) if a step differs: over 0.4 % of its pixels by more than 32 of 255 (`--max-diff` for the share),
which lets numbers shown live pass. Each step waits for the window to rest (1.5 s at most; the page says when it was
still moving), and a picture is taken per action, not per frame. The window's encoder is built for rate, on a thread of its own, so the window
does not freeze for it; pictures stay in memory during the run, and are compressed, compared and written when it ends.
`cdp.record_timeline` and `cdp.play_timeline` are the same for a tool of your own; `tk timeline_test` tests them against
`examples/whatsnew` over a real socket.

**What was on screen and what was typed are in the folder as they were**: a run on real data is not to be shared as it
stands, and typed passwords are recorded like any other text.

## Chrome's DevTools

`tk cdp inspect` prints the address to paste in Chrome or Edge. The box tree stands for the DOM:

- **Elements**: the boxes worth showing, followed as the window changes. The tag says what a box does (`button`, `input`,
  `scroll`, `text`, `box`), its name is its `id`, its flags its `class`, `role` and `aria-label` what a reader gets. Search
  (Ctrl+F) by name, text or tag. Hovering a node lights its box in the window; the picker works in DevTools' picture of the window.
- **Styles, Computed, Layout**: the box's rect and what it is drawn with, colours in sRGB, as on the screen. In Styles the inline
  style can be edited, live: `background-color`, `border-color`, `color`, `opacity`, `width`, `height`, `font-size`, `padding`,
  `border-radius`, with the colour picker and the tick boxes; what comes from the layout is read only, under it. A box that paints
  itself (`custom`) does not follow its colours.
- **Editing**: double-click a text to change it, Delete removes a box. An edit lasts as long as DevTools is attached: closing it
  gives back the window as its program builds it. Ctrl+Z and Ctrl+Y go back and forth over the edits. One client at a time: the last to ask for the document or to
  edit gets the tree's events, and the edits of the one before it are undone.
- **Accessibility** tab: what a screen reader gets for the box.
- DevTools' picture of the window takes clicks and the wheel.

There is no JavaScript and no network: Console and Network stay empty. Of the attributes only `aria-label` can be edited (what a reader gets); for the others DevTools shows the error.

`chrome://inspect` finds the window too: Configure, add `localhost:<port>`, then `inspect fallback` or `inspect`: its picture of the window, with the picker, comes with it (`remoteFrontend=true` in the address does the same).

## Puppeteer and Playwright

Both attach (run on examples/whatsnew with puppeteer-core 25.16 and playwright-core 1.64: `puppeteer.connect({browserURL})`,
`chromium.connectOverCDP(url)`). What goes through the commands above works, what needs a DOM or JavaScript does not:

| | Puppeteer | Playwright |
|---|---|---|
| `page.mouse`, `page.keyboard` | yes | yes |
| a CDP session (`Toolkit.*`, `Page.captureScreenshot`...) | `page.createCDPSession()` | `context.newCDPSession(page)` |
| `page.screenshot()` | yes | no: it evaluates JavaScript first and times out. `Page.captureScreenshot` in a CDP session instead. |
| `page.evaluate`, locators, selectors | no | no |

## Limits

- One window per server (a program with several windows starts one server each, on different ports).
- A timeline's frames come from a ring of 240: a busy program pulled every 250 ms keeps them all; a step that takes longer
  loses the oldest.
- Input arrives as events, not as system input: what reads the system's cursor or key state directly does not see it
  (`Event.injected` says which events these are).
- A screenshot is the next presented frame: a window that is not drawing is woken for it.
- `Toolkit.click` clicks where the box is: a box scrolled out of its view is clicked outside it. `Toolkit.axAction` does
  not depend on where it is.
- While the server runs the accessibility tree is built each frame (`axMs` in the metrics says what that costs).
