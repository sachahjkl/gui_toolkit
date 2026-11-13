# Feel: delays, repeats and steps

How the interface answers the hand is one struct, `ui.Feel`, held by `ui.State`. `ui.init` sets `ui.FEEL_DEFAULT`. A
program reads the values with `ui.feel`, changes some, and gives them back with `ui.set_feel`. A settings page shows
each field as a preference.

```odin
f := ui.feel(&app.state)
f.tooltip_delay_ms = 800
f.step_shift = 5
ui.set_feel(&app.state, f)
```

`ui.set_feel(s, f)` takes `f` for every build from then on. It brings each value within what works (below), and gives
the platform its part through `platform.set_input_defaults`. The other settings of the State keep their own setters:
`set_zoom`, `set_density`, `set_rounding`, `set_scrollbar_autohide`, `set_scrollbar_arrows`, `set_toast_position`,
`set_scroll_settings`, `set_autoscroll_settings`.

## Fields

| Field | Unit | Default | What it sets |
|---|---|---|---|
| `tooltip_delay_ms` | ms | 500 | The pointer rests this long on a box before its tooltip shows: `hovered_for`, a folded pane's title, a table's cut cell, a segment's tip. |
| `menu_hover_ms` | ms | 280 | The pointer rests this long on a submenu's item before it opens (or before another one closes). |
| `menu_item_em` | em | 1.9 | The height of a menu item, times the density (`dense`). At least 1.2. |
| `palette_fade_ms` | ms | 160 | A change of palette cross-fades every colour for this long. |
| `typeahead_ms` | ms | 900 | Keys typed in a `list` within this much of each other add up to one prefix. |
| `undo_steps` | steps | 200 | The edit history a `line_edit` and a `text_edit` keep. A lower value set later trims the history at the next edit. At least 1. |
| `undo_merge_ms` | ms | 1000 | Typing (or deleting) within this much of the previous edit of the same kind is the same undo step. 0: each edit is a step. |
| `repeat_delay_ms` | ms | 420 | A held button repeats after this long: `repeat_pressed` (a stepper's and a slider field's buttons) and a scroll bar's arrows. |
| `repeat_interval_ms` | ms | 55 | Then once every this much. At least 1. |
| `step_shift` | factor | 10 | Shift multiplies a step: a `slider`'s arrow and Page keys and wheel notch, a `slider_field`'s buttons and wheel, a `stepper`'s buttons (rounded to a whole number), a number in text (`num_step_delta`). |
| `step_ctrl` | factor | 100 | Ctrl multiplies the step of a number in text. |
| `step_alt` | factor | 0.1 | Alt multiplies the step of a number in text. |
| `step_page` | steps | 10 | Page Up and Page Down move this many steps: a `slider`, a number in text. |
| `zoom_step` | factor | 1.1 | The interface's zoom (`zoom`, `set_zoom`) is multiplied or divided by it: Ctrl+wheel (per notch), Ctrl+= and Ctrl+-. At least 1.01. It stays between `ZOOM_MIN` and `ZOOM_MAX`. |
| `wheel_lines` | lines | 3 | The lines a notch of the wheel moves where the system does not say: Linux always, Windows when the setting cannot be read (`platform.wheel_lines`). |
| `key_repeat_delay_ms` | ms | 600 | A held key repeats after this long, where the program makes the repeats and the system has not said its own (Wayland, until the compositor sends its rate). |
| `key_repeat_rate` | per second | 25 | Then this many times a second, likewise. 0: no repeat. |
| `fling_stop_speed` | px/s | 20 | A fling of the finger is over under this speed (`platform.touch_fling`). |

A duration or a count below 0 becomes 0.

The zoom steps of a `preview` (`PREVIEW_ZOOM_STEP`, 1.25), a `node_graph` (`GRAPH_ZOOM_STEP`, 1.2) and a `term` view
(`term.ZOOM_STEP`) are not `zoom_step`: they zoom a picture, a graph or a grid inside the window, in coarser steps than
the interface's own zoom.

## The platform's part

`platform.Input_Defaults` holds what the platform takes where the system says nothing: `wheel_lines`,
`key_repeat_delay_ms`, `key_repeat_rate`, `fling_stop_speed` (defaults: `platform.INPUT_DEFAULTS`).
`platform.set_input_defaults(d)` sets them for the calling thread and `platform.input_defaults()` reads them. They belong
to the thread: its interface sets them and its windows read them. `ui.set_feel` (and `ui.init`) call it with the fields
of `Feel`; a program that uses `ui` does not call it itself.

## Held buttons

`repeat_pressed(sig)` is true at the press of a button, then every `repeat_interval_ms` after `repeat_delay_ms` while the
pointer stays on it. Off the button it waits; back on it, it goes on. It wakes the loop at the next repeat only. The arrow
buttons of a scroll bar (`set_scrollbar_arrows`) repeat by the same rule.
