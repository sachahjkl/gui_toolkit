# fidget (gui_toolkit example)

The widget gallery: the Odin counterpart of `gui_fidget`'s demo app, built entirely on the `ui` package.
`build.bat fidget` at the repo root, then `build\fidget.exe`.

- **Controls**: buttons (accent / secondary / danger / ghost, squish on press), icon buttons with tooltips,
  switches, checkboxes, radios, segmented control (sliding pill), chips, sliders, range slider, stepper
  (hold to repeat), rating, progress bars, toasts, modal dialog, context menu
- **Inputs**: validated text fields, live fuzzy search with highlighted matches, tag input, a small form,
  shortcut cheat sheet
- **Data**: 20,000-row virtualized table (sort, filter, resizable columns, keyboard navigation) and a file tree
- **Playground**: physics balls (collisions, mouse repel, confetti), a fidget spinner, the live accent color
  picker (edits the theme while you drag), draggable sticky notes
- **Command palette** (Ctrl+K): fuzzy search over every command
- **Menu bar** with hover-to-switch, check marks and shortcuts; status bar with a frame-time sparkline
- 6 cross-fading themes; settings (theme, animations, status bar, zoom) persisted to
  `%APPDATA%\gui_toolkit_fidget\settings.txt`
- Animations follow the Windows "show animations" setting by default (View menu: system / on / off)
- Ctrl+wheel / Ctrl +/-/0 zoom the whole UI (toolkit feature)

Shortcuts: Ctrl+K, Ctrl+1..4, Ctrl+T theme, Ctrl+B status bar, Ctrl+J animations.
Test flags: `--page=N --theme=N --palette --modal --anim=on|off --dump`.

Files: `app.odin` (state, palettes, command table), `main.odin` (frame loop, settings), `shell.odin`
(menu bar, tabs, status bar, palette, modal), `pages.odin` (Controls, Inputs), `pages_data.odin`,
`pages_play.odin`.

Note: the Controls page renders continuously (the indeterminate "Loading" bar), so it idles at a few percent
CPU; the other pages idle at ~0 %.
