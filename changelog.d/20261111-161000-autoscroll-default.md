type: Changed

**Middle-click autoscroll is on by default**: every scroll region of every program (`scroll_y`, lists, tables, a vlist) takes a click of the wheel and scrolls by the pointer, as in the browsers. A program whose middle button does something else calls `ui.set_autoscroll_enabled(&state, false)`.
