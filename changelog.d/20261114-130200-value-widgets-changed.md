type: Changed

**Every value widget returns whether its value changed**: `checkbox`, `radio`, `toggle`, `slider` and `range_slider` return `changed: bool` in place of a `Signal`, as `number`, `dropdown`, `segmented` and `tabs` do (a click on the radio already chosen is no change). What else the box says is `ui.signal(ui.prev_box(id))` right after the widget. How a program moves:
  - `if ui.toggle(id, text, &v).clicked { ... }` → `if ui.toggle(id, text, &v) { ... }`.
  - `sig := ui.checkbox(id, text, &v)`, then `sig.right_clicked` or `sig.box.key` → `ui.checkbox(id, text, &v)`, then `ui.signal(ui.prev_box(id)).right_clicked` or `ui.prev_box(id).key`.
  - A range slider's keys move a thumb as a slider's do: Shift multiplies a step, another modifier moves nothing.
