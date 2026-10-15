# gui_toolkit

A native GUI toolkit in [Odin](https://odin-lang.org): a retained-state immediate-mode UI with a Direct3D 11 renderer.
The design (box tree, keyed persistence, size-kind layout, signals, tag-based themes) follows the UI layers of the
[RAD Debugger](https://github.com/EpicGamesExt/raddebugger); this project is the toolkit and the apps built on it, not a port of the debugger.

~6,300 lines (toolkit + examples), no dependencies beyond Odin's `core:` and `vendor:` (`directx/d3d11`, `stb/truetype`).
The todo example is a 680 KB exe, shows its window in ~0.26 s and uses 0 % CPU when idle.

    build.bat fidget     # the widget gallery           ->  build\fidget.exe
    build.bat todo       # a todo app                   ->  build\todo.exe
    build.bat smoke      # renderer / font / draw smoke test (no UI layer)
    build.bat todo debug

Needs the Odin compiler (tested with `dev-2026-10`) and Windows 10+ (Win32 + D3D11 only for now).

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
  toasts, modal dialogs, color pickers (sat/val + hue), fuzzy-match helper + highlighted labels, custom-draw boxes.
- **Idle = 0 % CPU**: the loop blocks on the message queue; timed wakes only for the caret blink and tooltip delay.

Not there yet: multi-line text, Tab focus navigation, drag-and-drop files, background blur, Linux/macOS backends.

## Testing

`tools\ui_test.ps1` drives `examples/todo` and `tools\fidget_test.ps1` drives `examples/fidget` with real clicks
(typing, Enter, toggles, segmented, chips, dropdown, slider, tooltip, context menu, wheel scroll, command palette,
theme switch) and check the title / saved files. They abort if another window covers the target point.
Debug aids: `-define:UI_PROBE=true` logs every press with the hit box's rect; `--dump` (fidget) prints oversized boxes.

## License

MIT (see LICENSE). The design and several algorithms follow the RAD Debugger (MIT, Epic Games Tools): see NOTICE.md.
