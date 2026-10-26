# Splitter, accordion, reorderable lists (`ui/split.odin`, `ui/reorder.odin`)

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

## A list reordered by dragging (`ui/reorder.odin`)

Tabs along a strip, rows in a sidebar, cards in a column: items `pitch` apart along X or Y, which the user drags to
another place while the others slide out of the way. The geometry is pure and independent of the axis:

| Procedure | |
|---|---|
| `reorder_item_size(avail, n, min, max)` | each item's size: an equal share between a minimum and a maximum (past the minimum the list scrolls) |
| `reorder_offset(offset, n, pitch, view, current, follow)` | the scroll in range, moved just enough to show the current item when it changed |
| `reorder_slot(pos, pitch, n)` | the slot a dragged item's middle is over |
| `list_move(list, from, to, current)` | moves an element, returns where the current one went |
| `reorder_edge_scroll(pos, size, view_off, view, limit, target)` | an item held past an edge of the view scrolls the list |
| `reorder_moved(delta, axis, across)` | how far a press moved, along the axis (and across it when leaving the list is a gesture of its own) |

The drag's state is a `Reorder` (the item, whether it moved past the threshold, where the pointer holds it):

```odin
ui.reorder_frame(&app.drag)   // the button went up: no drag
for item, i in app.items {
	slot := f32(i) * pitch - offset
	x, dragging := ui.reorder_item_pos(&app.drag, key_of(item), item.id, slot, ui.mouse_pos().x - area.rect.min.x, -offset, f32(n - 1) * pitch - offset)
	ui.next({fixed_x = x, width = ui.px(pitch), height = ui.pct(1)})
	sig := ui.signal(ui.build_box({.Clickable}, id_of(item)))
	if sig.dragging {
		ui.reorder_begin(&app.drag, item.id, ui.reorder_moved(sig.drag_delta, .X, false), threshold, ui.mouse_pos().x - sig.drag_delta.x - area.rect.min.x, slot)
		if ui.reorder_dragging(&app.drag, item.id) {
			if to := ui.reorder_slot(x + offset, pitch, n); to != i { move_from, move_to = i, to }
		}
	}
}
if move_from >= 0 { app.current = ui.list_move(app.items[:], move_from, move_to, app.current) }
```

Items sit at their slot, animated when they move (`anim`, keyed by the item); the dragged one follows the pointer within
`lo .. hi` and slides back from there when released. Wren's tab strip and tab sidebar use it.

Example: `examples/panes` (`build.bat panes`). Tests: `tests/panes` (dragging within the limits, the pane after the
handle, double click, keys, no Tab stop, the animated height, the keyboard, what is drawn; the reorder geometry and a
drag through a build).
