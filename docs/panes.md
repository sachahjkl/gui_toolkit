# Splitter and accordion (`ui/split.odin`)

## `ui.splitter`

A handle between two panes. The app keeps the size of one pane, passes it by pointer and persists it when the
result says `finished`.

```odin
ui.next({width = ui.px(app.sidebar * ui.scale()), height = ui.fill()})
if ui.column(.Start, {}, "###sidebar") { ... }
r := ui.splitter("###side_split", .X, &app.sidebar, 140, 480, {default_size = 240, total = room_w, min_other = 240})
if r.finished { save_settings(app) }
```

`splitter(id, axis, &size, min, max, opts) -> Splitter_Result`

- `axis`: `.X` is a vertical bar between side-by-side panes, `.Y` a horizontal bar between stacked panes. Its length
  fills the parent unless `next` says otherwise.
- `size` is in logical pixels by default; `opts.unit` gives the frame pixels per unit (a pane's room in pixels makes
  `size` a fraction of it).
- Limits: `min` and `max` for the pane; with `opts.total` (both panes, in units of `size`), the other pane keeps
  `opts.min_other`. When the limits cross, the smaller one wins (`splitter_limits`). A size outside them at rest (the
  window shrank) is left alone: the app draws the pane clamped, and the user's size comes back when there is room.
- `opts.after`: the pane sized is after the handle (right of it, below it); dragging towards it shrinks it.
- Double click, or Enter with the keyboard focus: back to `opts.default_size` (none when 0).
- Keyboard: a Tab stop unless `opts.no_keyboard`; the arrow keys of its axis move it by `opts.step` (default 10 logical
  pixels; Ctrl: a fifth), Home and End go to the limits.
- Resize cursor over it and while it is held, even when the pointer runs ahead of it.
- Drawn as a rule along the middle of the grab area (`opts.thickness` frame pixels, default 5 logical pixels), twice as
  thick and in the accent colour while hot, held or focused from the keyboard. Nothing animates: no frame at rest.
- Result: the signal (`dragging` while held), `changed` (the size changed this frame), `finished` (a drag, a reset or a
  key ended: persist now).

## `ui.accordion`

```odin
if ui.accordion("###net", "Network", &app.net_open) {
	ui.label("...")
}
```

A header (chevron and title) that folds the content built in the block. The block runs while the section is open or
still folding: the content is clipped to the animated height (`ACCORDION_RATE`, about 0.2 s; at once when animations
are off), and nothing is built once it is folded. No frame at rest. The header is a Tab stop: Enter or Space toggle it.
The open state is the app's (`open` is flipped on a click).

Example: `examples/panes` (`build.bat panes`). Tests: `tests/panes` (dragging within the limits, the pane after the
handle, double click, keys, no Tab stop, the animated height, the keyboard, what is drawn).
