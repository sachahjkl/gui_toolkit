<p align="center"><img src=".project/image.png" width="128" alt="gui_toolkit logo"></p>

<h1 align="center">gui_toolkit</h1>

<p align="center"><a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.1.0-7c8cff" alt="version 0.1.0"></a></p>

A native GUI toolkit in [Odin](https://odin-lang.org): a retained-state immediate-mode UI with a Direct3D 11 renderer.
The design (box tree, keyed persistence, size-kind layout, signals, tag-based themes) follows the UI layers of the
[RAD Debugger](https://github.com/EpicGamesExt/raddebugger); this project is the toolkit and the apps built on it, not a port of the debugger.

![fidget, the widget gallery](docs/screenshots/controls.png)

~4,100 lines of toolkit (+2,700 of examples), no dependencies beyond Odin's `core:` and `vendor:` (`directx/d3d11`,
`stb/truetype`). The widget gallery is a 930 KB exe, the todo example 720 KB; windows show in ~0.25 s and idle at 0 % CPU.

    build.bat fidget     # the widget gallery           ->  build\fidget.exe
    build.bat todo       # a todo app                   ->  build\todo.exe
    build.bat smoke      # renderer / font / draw smoke test (no UI layer)
    build.bat todo debug

Needs the Odin compiler (tested with `dev-2026-10`) and Windows 10+ (Win32 + D3D11 only for now).
Prebuilt binaries are attached to the [GitHub releases](https://github.com/sachahjkl/gui_toolkit/releases).

## Screenshots

| | |
|---|---|
| ![Inputs: validation, fuzzy search, tags, form](docs/screenshots/inputs.png) | ![Data: 20,000-row virtualized table and file tree](docs/screenshots/data.png) |
| **Inputs**: validated fields, live fuzzy search, tag input, form | **Data**: 20,000-row virtualized table (sort, filter, resize), file tree |
| ![Playground: physics, spinner, live accent picker](docs/screenshots/playground.png) | ![Command palette with fuzzy matching](docs/screenshots/palette.png) |
| **Playground**: physics balls, fidget spinner, live accent color picker | **Command palette** (Ctrl+K), fuzzy matches highlighted, Nord theme |
| ![Settings dialog](docs/screenshots/settings.png) | ![Toasts](docs/screenshots/toasts.png) |
| **Settings**: theme, zoom, animations, toast position (click a cell) | **Toasts**: 8 anchor positions, border tinted by kind |
| ![About dialog](docs/screenshots/about.png) | ![Light theme](docs/screenshots/light.png) |
| **About** (F1), Dracula theme | **Daylight** theme (6 themes, cross-fading) |

<p align="center"><img src="docs/screenshots/todo.png" width="420" alt="todo example"><br><b>examples/todo</b></p>

Screenshots are regenerated with `powershell -File tools/screenshots.ps1` (default settings, 175 % DPI).
## What it looks like

```odin
if ui.style({width = ui.fill(), radius = em * 0.45}) {
	if ui.row(.Center) {
		res := ui.line_edit("###new_task", &app.input, "What needs doing?")
		if ui.tags("accent_button") {
			if ui.button("Add###add").clicked || res.committed { add_task(app, ui.field_string(&app.input)) }
		}
	}
	if ui.scroll_y("###list") {
		for &t in app.tasks {
			ui.checkbox(fmt.tprintf("###chk_%d", t.id), t.title, &t.done)
		}
	}
}
```

Scopes use Odin's `@(deferred_none)`, so `if ui.row() { ... }`, `if ui.style({...}) { ... }`, `if ui.tags("card") { ... }`
open and close themselves. Overrides for a single box go through `ui.next({...})`.

## Versioning

The toolkit follows semantic versioning (`ui.VERSION`, currently `0.1.0`; while `0.x`, a minor bump may change the API).
Changes are listed in [CHANGELOG.md](CHANGELOG.md); releases are git tags `vX.Y.Z`.

## Layers (same layering as raddebugger, one Odin package each)

| Package | Role |
|---|---|
| `platform` | Win32 window, DPI, events, clipboard, cursors, OS animation preference. Live-resize safe (`poll_events` is re-entrancy guarded). |
| `render` | D3D11. One instanced-quad pipeline draws rounded rects / borders / shadows (SDF) and glyphs. sRGB target: colors are linear, blending is in linear space. |
| `font` | TrueType (`stb_truetype`), glyph cache, shelf-packed atlas, text measurement. |
| `draw` | Rect / text / clip / alpha / scale stacks over the renderer. |
| `ui` | The toolkit: boxes, keys, layout, signals, theme, animation, widgets, popups, zoom. |

## Features

- **Layout**: pixels / text / percent / children-sum sizes with strictness, floating boxes, cross-axis alignment, scrolling.
- **State survives rebuilds**: hover/press/focus animation, scroll offsets and text-field state are keyed by id strings
  (`"Label##hidden"`, `"Label###stable_id"`, `"###id"` as in raddebugger).
- **Theme**: `(tags -> color)` patterns, `apply_palette` expands an 11-color palette (dark and light included);
  colors cross-fade when the palette changes.
- **Zoom, built in**: Ctrl+wheel, Ctrl +, Ctrl -, Ctrl 0 scale every size and the font (`ui.zoom`, `ui.set_zoom`;
  the effective scale is dpi scale x zoom). Apps write sizes in logical pixels.
- **DPI**: per-monitor aware, window sized from the monitor DPI and clamped to the work area.
- **Animations** follow the OS "show animations" setting (`Build_Params.animations`); when off, every transition jumps.
- **Widgets**: label, button (+icon variant), icon button, checkbox, radio, switch, slider, range slider, stepper,
  segmented control, chips, rating, progress bar, dropdown, tabs, key caps, cards, form rows, single-line text field
  (selection, word moves, clipboard, mouse), scroll region, context menu + items, menu bar, tooltip with hover delay,
  toasts (8 anchor positions, bordered, stacked with a glide), modal dialogs, color pickers (sat/val + hue), fuzzy-match helper + highlighted labels, custom-draw boxes.
- **Idle = 0 % CPU**: the loop blocks on the message queue; timed wakes only for the caret blink and tooltip delay.
- **Low input latency**: one frame in flight (waitable swap chain, `SetMaximumFrameLatency(1)`), and the loop waits for
  the GPU *before* reading input (`platform.wait_event` -> `render.wait_for_frame` -> `platform.poll_events`).
  Measured input-to-scan-out at 60 Hz: ~80 ms with DXGI's default queue, ~47 ms now (`-define:RENDER_PROBE=true` prints
  it; `-define:LOW_LATENCY=false` restores the old behaviour for comparison). Live resize presents once per step (WM_PAINT).

Not there yet: multi-line text, Tab focus navigation, drag-and-drop files, background blur, Linux/macOS backends.

## Testing

`tools\ui_test.ps1` drives `examples/todo` and `tools\fidget_test.ps1` drives `examples/fidget` with real clicks
(typing, Enter, toggles, segmented, chips, dropdown, slider, tooltip, context menu, wheel scroll, command palette,
theme switch) and check the title / saved files. They abort if another window covers the target point.
Screenshot coordinates: image viewers often downscale captures (e.g. to 2000 px wide); scale click targets by
window width / image width, or clicks land a few percent off. Debug aids: `-define:UI_PROBE=true` logs every press with the hit box's rect; `--dump` (fidget) prints oversized boxes.

## License

MIT (see LICENSE). The design and several algorithms follow the RAD Debugger (MIT, Epic Games Tools): see NOTICE.md.
