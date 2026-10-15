# Changelog

All notable changes to gui_toolkit. The project follows [semantic versioning](https://semver.org); while the version is
`0.x`, a minor bump may change the API. The version is also available in code as `ui.VERSION`.

## [0.3.1] - 2026-10-15

### Changed
- **Self-contained exes**: the icon font is compiled in (`ui.ICON_FONT_DATA`, `font.load_embedded`); nothing has to
  sit next to the exe any more.
- Text fonts: Segoe UI and Consolas are read from the Windows font folder (`platform.system_font_path`); when they
  are missing (Wine, trimmed installs) the exe falls back to Roboto and Inconsolata compiled into it
  (`font.load_system_or_embedded`, `font.FALLBACK_UI_DATA`, `font.FALLBACK_MONO_DATA`). fidget: `--embedded_fonts`
  forces the fallbacks.
## [0.3.0] - 2026-10-15

### Added
- **Arrow-key focus navigation**: once a widget that does not use arrows has the focus, the arrows move it to the
  nearest Tab stop in that direction (trapped inside modals, scrolled into view). Sliders, text fields and open
  menus keep their arrows.
- **Scrollbars**: every `View_Scroll_Y` box gets an overlay scrollbar (drag the thumb, click the track to jump);
  `text_edit` has vertical and horizontal bars.
- **Wrapping rows**: `ui.flow(gap)` and the `Wrap` box flag place children left to right and start a new line when
  the row is too narrow. Chips and the fidget button / tag / swatch rows use it.
- **Corner rounding**: `ui.set_rounding` (0 = square, 1 = default, up to 2) scales box radii and widget chrome;
  `ui.rad` for custom draws. Radio buttons stay round, and so do boxes with the new `Fixed_Radius` flag.
  Rounded rects can use squircle corners (`render.set_corner_smoothing`), which removes the visible kink where an
  arc meets a straight edge. At rounding 0 the Windows 11 window corners go square (`platform.set_square_corners`).
- **Density**: `ui.set_density` / `ui.dense` (Comfortable or `DENSITY_COMPACT`): row heights, vertical gaps and
  paddings shrink, the text keeps its size.
- **Disabled and muted scopes**: `if ui.disabled(cond) { ... }` disables everything built inside (no clicks, hover or
  focus) with a neutral look and a fade; `button_icon(disabled = ...)` uses it. `if ui.muted() { ... }` dims
  secondary content that stays interactive.
- **Finishes**: `Palette.finish` paints raised surfaces `Flat`, `Gradient` (Bootstrap 2: vertical gradient, top
  highlight, embossed text, focus glow) or `Glass` (Windows 7 Aero: glossy top half, bottom glow, white rim).
  `ui.paint_rect` gives custom draws the same finish. Palettes can also set a bar colour.
- **Translucent windows**: `render.init(transparent = true)` presents through DirectComposition with a linear fp16
  (scRGB) swap chain, so translucent pixels compose correctly; `platform.set_backdrop` shows the Windows 11 acrylic
  backdrop behind them.
- **Selection outline**: selected rows, menu items and palette entries get a crisp accent border over a light fill.
- fidget: Aero and Bootstrap themes (8 themes; Graphite is now the default), Settings for rounding, corner shape and
  density, an "Enabled" switch that disables a card, a grouped data table (collapsible department groups with
  totals, two-line headers with column totals, right-aligned numbers, column separators, alternating rows),
  `--bench=N` (CPU time per frame), `--compact`, `--size=WxH`, `--long_text`.
- `tools/keyboard_test.ps1`: 33 checks (arrow navigation, menus closing on a click outside).

### Changed
- A box with `Draw_Border` keeps its border out of the layout (like CSS border-box): its children sit inside it, so a
  border never hides a child's own outline.
- Disabled boxes no longer get a dimming overlay: they switch to neutral colours and fade as a whole.

### Fixed
- Context menus and dropdowns now close on a click anywhere outside, not only on clickable boxes.
- Rects ignored the alpha stack (`draw.push_alpha`): only text faded.
- The page and the menu bar inherited the default radius, leaving dark pixels in the window corners.
- The sort arrow and resize lines of the table header were not aligned with the column separators.
## [0.2.0] - 2026-10-15

### Added
- **Multi-line editor** `ui.text_edit` with `ui.Text_Area`: selection (keyboard and mouse, double-click word),
  Up / Down keep the column, Home goes to the first non-blank character, Ctrl+Home / End, Page Up / Down,
  word moves and deletes, Enter keeps the indentation, clipboard (CRLF and tabs normalized), undo / redo
  (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z; edits grouped per second), wheel scrolling, optional line numbers,
  optional Tab-indents mode, Ctrl+Enter = committed, Escape leaves the field.
- **Keyboard focus navigation**: Tab / Shift+Tab move through the Tab stops in build order (wrapping), the
  focused widget is scrolled into view and gets a focus ring; Enter / Space activate buttons, checkboxes, radios,
  switches, segmented items, chips, tabs and dropdowns; sliders take arrows, Page Up / Down, Home / End.
  Inside a modal, Tab cycles through the dialog only, and the page loses the focus when the dialog opens.
- **Context menus and dropdowns from the keyboard**: Up / Down select, Enter / Space choose.
- `ui.focused_name()` (id of the focused box), new box flags `Text_Input` and `Scroll_Self`.
- fidget: a multi-line editor card, more shortcuts in the cheat sheet, `--state_title` for scripted tests.
- `tools/keyboard_test.ps1`: 28 checks with real keystrokes and modifiers (Ctrl+A/C/V, Tab, Space, Ctrl+Z/Y,
  Ctrl +/-/0, Ctrl+K, Ctrl+, and a dropdown driven from the keyboard), only sent while fidget is in front.
- New logo: a white switch and slider on a cobalt rounded square (`tools/make_logo.ps1`), also the icon of `todo.exe`.

### Fixed
- `icon_button` registered its box under a key it then replaced: the button could not hold the keyboard focus.
- A focused widget no longer steals Enter / Space from an open context menu.

## [0.1.0] - 2026-10-15

First release.

### Toolkit
- **platform** (Win32): per-monitor DPI aware window sized from the monitor DPI, events (keys, text with UTF-16
  surrogates, mouse, wheel with modifiers), clipboard, cursors, dark title bar, OS "show animations" setting,
  `wait_event` / `poll_events` (re-entrancy safe during live resize), app icon from resource id 1.
- **render** (Direct3D 11): one instanced-quad pipeline for SDF rounded rects, borders, soft shadows and glyphs;
  sRGB target (linear blending); waitable swap chain with one frame in flight for low input latency
  (~47 ms input-to-scan-out at 60 Hz, measured); `RENDER_PROBE` latency / frame-gap probe.
- **font**: TrueType via `stb_truetype`, glyph cache, shelf-packed atlas, text measurement and caret mapping.
- **draw**: rects (per-corner colors and radii), text, clip / alpha / scale stacks, sRGB / hex / HSV helpers.
- **ui**: box tree with keyed persistence (`##` / `###` id rules), style / tag / parent scopes using
  `@(deferred_none)`, five-pass layout (pixels, text, percent, children-sum, strictness, floating, cross-axis
  alignment, scrolling), signals (hover, press, click, double / right / middle click, drag, wheel), animations
  that follow the OS setting, tag-based themes with cross-fades and two built-in palettes, built-in zoom
  (Ctrl+wheel, Ctrl +/-/0).
- **Widgets**: label, button (+icon), icon button, checkbox, radio, switch, slider, range slider, stepper,
  segmented control, chips, rating, progress (determinate / indeterminate), dropdown, tabs, key caps, cards, form rows,
  single-line text field (selection, word moves, clipboard, mouse), scroll region, context menu, menu bar, tooltips,
  toasts (8 positions), modal dialogs, color pickers, fuzzy matching with highlighted labels, custom-draw boxes.

### Examples
- **fidget**: widget gallery (Controls, Inputs, Data with a 20,000-row virtualized table, Playground), command
  palette, menu bar, Settings and About dialogs, six themes, persisted settings.
- **todo**: a todo app with persistence, filters, search, context menu, light / dark theme.
- **smoke**: renderer, font and draw layers without the UI.

### Tooling
- `build.bat`, embedded exe icons, scripted interaction tests (`tools/fidget_test.ps1`, `tools/ui_test.ps1`),
  screenshot generator (`tools/screenshots.ps1`), icon generator (`tools/make_icon.ps1`).

[0.2.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.2.0
[0.1.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.1.0
