# devtools: drive a window over the Chrome DevTools Protocol

The `devtools` package serves a toolkit window over the Chrome DevTools Protocol (CDP), the protocol tools use to
drive Chrome: clicks, keys, text, the wheel, screenshots, the accessibility tree. A test, a script or an agent drives
the interface without the machine's mouse or keyboard, and the window does not need focus or to be on top: the events
go straight into its queue (`platform.inject_event`), as the system's would.

## In an application

```odin
import "gui_toolkit/devtools"

srv := devtools.start_from_env(win, "My app")   // TOOLKIT_DEVTOOLS=9222 in the environment, else nil
defer devtools.stop(srv)

// each frame, before poll_events and begin_build:
devtools.service(srv, &ui_state, &renderer)
```

`start(win, port, title)` starts it on a port of your choosing. With nil (the variable unset) `service` and `stop` do
nothing, so the calls stay in a release build.

## Who can reach it

It listens on 127.0.0.1 only, and 127.0.0.1 alone does not keep a browser out: a WebSocket is not bound by the
same-origin policy, so any page open on the machine could connect and drive the window, and a name made to resolve to
127.0.0.1 could read the endpoints. So these are refused:

- a request with an `Origin` header (403): what a browser's page sends and a tool's client does not;
- a `Host` other than `127.0.0.1:<port>`, `localhost:<port>`, `[::1]:<port>` (403);
- a WebSocket on a path without the target's id (404), a random id given by `/json/list`.

What runs on the machine as any user can still connect, as with Chrome's own `--remote-debugging-port`. In an
application that acts on what it is told (an agent), that is running commands: keep it opt-in, and off for what you
ship to people. A client that stops reading is dropped after 5 s (the answers are written on the UI thread), and a
message over 16 MB ends its connection.

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
| `Page.captureScreenshot` | PNG of the window's pixels (`clip` in CSS pixels), from the renderer's capture: the frame as presented. Encoded on a thread of its own: the window goes on meanwhile. |
| `Page.getLayoutMetrics` | the window's size in CSS pixels, its DPI scale as the visual viewport's zoom. |
| `Accessibility.getFullAXTree` | the tree a screen reader gets (`ui.a11y_tree`, built while the server runs): role in Chrome's vocabulary (button, textbox, StaticText, checkbox...), name, value, properties (focused, disabled, expanded, selected, checked...), children; and, beyond the protocol, `bounds` in CSS pixels and `actions`. |
| `Accessibility.queryAXTree` | the nodes with a `role` and an `accessibleName` (contained, case ignored; `exact` for all of it). |
| `Browser.getVersion`, `Target.*`, `Page.getFrameTree` | discovery, and attaching in sessions (`Target.attachToTarget`, `setAutoAttach`, the browser's endpoint): what Puppeteer and Playwright use. |
| `Browser.close` | closes the window, as its close button. |
| `Page.startScreencast` `{minIntervalMs?}`, `Page.screencastFrameAck`, `Page.stopScreencast` | the window's frames as `Page.screencastFrame` events, PNG only (`format`, `quality`, `maxWidth` are ignored). One at a time (the next waits for the ack), no faster than `minIntervalMs` (200), none while nothing changes. Each is read back and compared on the UI thread and encoded on a thread of its own, which takes a core while it runs. |
| `*.enable`, `*.disable`, `*.set*` | accepted, nothing to do (what clients send on attaching). |
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
| `Toolkit.startRecording` `{injected?}`, `Toolkit.stopRecording` | what a person does in the window, as lines of a script for `tools/cdp.mjs play`. Clicks by what they hit (a name, a text), drags and what names nothing by coordinates; typed text as is. `injected`: the protocol's events too. `Toolkit.pollRecording` gives the lines since the last time with when they happened (`t`, as `Toolkit.frames`). |

## tools/cdp.mjs

A client for the command line (Node 22+, no package):

```
TOOLKIT_DEVTOOLS=9222 build\whatsnew.exe
node tools/cdp.mjs tree
node tools/cdp.mjs click "Lazy column" , idle , wheel 700 400 30 , idle , shot out.png
node tools/cdp.mjs key ctrl+f , type odin , key Enter , wait-for "matches"
node tools/cdp.mjs press "Send" --role button
node tools/cdp.mjs audit
node tools/cdp.mjs metrics --reset , click "Lazy column" , idle , metrics
node tools/cdp.mjs record steps.txt      # until Enter; then: node tools/cdp.mjs play steps.txt
node tools/cdp.mjs cast frames/          # the window's frames as PNGs, until Enter
```

`tools/cdp_client.mjs` is the same as a module, for a script of your own; `tests/e2e/run.mjs` is an example of one.

## Timelines

A timeline is a run kept whole: each action with when it happened, a picture of the window after it, the time of every
frame in between.

```
node tools/cdp.mjs record --timeline run1            # what a person does, until Enter
node tools/cdp.mjs play run1/timeline.json --timeline run2                # again; each picture compared with run1's
node tools/cdp.mjs play run1/timeline.json --timeline run2 --realtime     # with the recorded pauses
node tools/cdp.mjs play steps.txt --timeline run3 --against run1          # a script against a run
```

A folder per run:

- `index.html`: one file, the pictures in it. The steps, a strip of the frames' times (slow ones in red), the picture of
  each step (arrow keys, Play), what differs from the reference.
- `timeline.json`: the steps and frames, what `play` reads.
- `trace.json`: Chrome's trace format, for `chrome://tracing` or https://ui.perfetto.dev: a slice per build and layout, a
  mark per step, a counter of the frame time.
- `steps.txt`, `step-NNN.png`, `step-NNN.diff.png`.

`play` exits with code 1 if a step differs: over 0.4 % of its pixels by more than 32 of 255 (`--max-diff` for the share),
which lets numbers shown live pass. Each step waits for the window to rest (1.5 s at most; the page says when it was
still moving), and a picture is taken per action, not per frame. The window's encoder is built for rate, on a thread of its own, so the window
does not freeze for it; pictures stay in memory during the run, and are compressed, compared and written when it ends.
`tools/timeline.mjs` is the same as a module (`recordTimeline`, `playTimeline`).

**What was on screen and what was typed are in the folder as they were**: a run on real data is not to be shared as it
stands, and typed passwords are recorded like any other text.

## Puppeteer and Playwright

Both attach (checked with puppeteer-core and playwright-core: `puppeteer.connect({browserURL})`,
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
