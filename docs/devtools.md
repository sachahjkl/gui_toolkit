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
nothing, so the calls stay in a release build. It listens on 127.0.0.1 only; whatever can reach that port drives the
window, so keep it opt-in.

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
| `Page.captureScreenshot` | PNG of the window's pixels (`clip` in CSS pixels), from the renderer's capture: the frame as presented. |
| `Page.getLayoutMetrics` | the window's size in CSS pixels, its DPI scale as the visual viewport's zoom. |
| `Accessibility.getFullAXTree` | the boxes a reader meets: their role (the widget's, or button, textbox, StaticText, scrollable), name, children. |
| `Browser.getVersion`, `Target.getTargets`, `Target.getTargetInfo`, `Page.getFrameTree` | discovery. |
| `*.enable`, `*.disable`, `*.set*` | accepted, nothing to do (what clients send on attaching). |
| `Runtime.evaluate` | refused: there is no JavaScript. |

The `Toolkit` domain reads the box tree (rects in CSS pixels):

| Method | What |
|---|---|
| `Toolkit.getTree` `{all?}` | the tree: `key`, `name` (the id's hash part), `text` (rich paragraphs too), `x y w h`, `flags` (Clickable, Focusable, Text_Input, View_Scroll_Y...), `role`, `label`, `focused`, `hot`, `scroll` / `scrollMax`. Without `all`, only boxes named, with text, interactive, or holding such boxes. |
| `Toolkit.find` `{name? text?}` | boxes named `name` exactly, or whose text contains `text` (ignoring case), in tree order. |
| `Toolkit.click` `{name? text? index? count? button?}` | a click on the middle of the match (the nearest clickable box around it): a move and a press now, the release at the next frame; `count` 2 for a double click. |
| `Toolkit.state` | the build counter, the focused and hovered keys, the size and DPI scale. |

## tools/cdp.mjs

A client for the command line (Node 22+, no package):

```
TOOLKIT_DEVTOOLS=9222 build\whatsnew.exe
node tools/cdp.mjs tree
node tools/cdp.mjs click "Lazy column" , wait 200 , wheel 700 400 30 , wait 300 , shot out.png
node tools/cdp.mjs key ctrl+f , type odin , key Enter
node tools/cdp.mjs raw Accessibility.getFullAXTree
```

Puppeteer and Playwright's CDP mode (`connectOverCDP`) attach to the target too; their page APIs that need a DOM or
JavaScript do not apply, `page.mouse`, `page.keyboard` and `page.screenshot` go through the commands above.

## Limits

- One window per server (a program with several windows starts one server each, on different ports).
- Input arrives as events, not as system input: what reads the system's cursor or key state directly does not see it
  (`Event.injected` says which events these are).
- A screenshot is the next presented frame: a window that is not drawing is woken for it.
