# The table of widgets and their behaviours: intent

Every widget of one concept must behave alike: a person who learned the wheel on one number knows it on every number.
This table writes each widget's behaviours down, so that an empty cell between two widgets of one concept shows. An
empty cell is a bug to fix or a decision written below. How a program uses the widgets is in
[docs/widgets.md](../../../docs/widgets.md).

## The table

Read from the code of `src/ui` (widgets.odin, widgets_ext.odin, line_edit.odin, text_edit.odin, color_picker.odin,
hotkey_field.odin, split.odin). "gen." is the rule every box has: a tooltip is the program's from the box's signal
(`hover_tip`, `label_tip`), and `push_disabled` fades any widget and takes its presses.

| Widget | Wheel | Keys | Tab stop | Screen reader | Context menu | Disabled | Tooltip | Shift step | Typed value | Reset (double click) |
|---|---|---|---|---|---|---|---|---|---|---|
| `button` | — | Space, Enter | yes | button | program's | `o.disabled`, gen. | gen. | — | — | — |
| `checkbox` | — | Space | yes | check box | program's | gen. | gen. | — | — | — |
| `radio` | — | Space | yes, each (**G1**) | radio | program's | gen. | gen. | — | — | — |
| `toggle` | — | Space | yes | switch | program's | gen. | gen. | — | — | — |
| `segmented` | — | Space, arrows, Home, End | the chosen one | radio group | program's | gen. | `tips` | — | — | — |
| `tabs` | its strip | Space, Left, Right, Home, End | the chosen one | tab list | program's | gen. | gen. | — | — | — |
| `dropdown` | — (D1) | Down, Alt+Down, F4 open | yes | combo box | program's | gen. | gen. | — | — | — |
| `slider` | a step | arrows, Home, End, Page | yes | slider | program's | gen. | gen. | yes | — (D2) | `default`: double click |
| `range_slider` | a step, active thumb | arrows, Home, End, Page | yes, each thumb | two sliders | program's | gen. | gen. | yes | — (D2) | — (G2) |
| `number` | a step | Up, Down, Page; Ctrl, Alt | the field | spin button | Reset (with `default`) | `disabled`, gen. | gen. | yes | yes | `default`: menu, track |
| `color_picker` | — | its fields' | its fields | its parts | program's | gen. | gen. | — | hex, numbers | — |
| `hotkey_field` | — | records the keys | yes | its text | program's | gen. | gen. | — | the keys | — |
| `line_edit` | — | editing | yes | text field | edit menu | `.Read_Only`, gen. | gen. | — | yes | — |
| `text_edit` | scrolls | editing | yes | text area | edit menu | gen. | gen. | — | yes | — |
| `splitter` | — | arrows | yes | splitter | program's | gen. | gen. | — | — | `default_size` |

## Gaps

- **G1, arrows in a group of choices.** A group of choices is one Tab stop, and the arrows move the choice in it (the
  radio group's and the tab list's rule of every desktop). `segmented` and `tabs` do it (`choice_group_step`: the chosen
  one the Tab stop, the arrows, Home and End move the choice and the keyboard, no wrap; a row of tabs takes Left and
  Right alone, Down being the way into its page). `radio` remains: each is built alone and knows neither its siblings
  nor their count, so it needs the group's memory in the state (the radios of one `selected` in the last build).
- **G2, a value's reset.** A `splitter` given its `default_size` comes back to it on a double click. `slider` and
  `number` take an optional `default`: a double click on a slider's track sets it (after the press that moved the knob:
  the default wins), and a number's field has a right-click menu, "Reset to 10" (its only way when it has no track; a
  double click on the field selects a word, as in every field). `range_slider` remains: two thumbs, two defaults, and a
  double click on the track would have to say which.

## Decisions

- **D1, no wheel over a closed drop-down.** A page that scrolls under the pointer would change the choice it passes
  over. The open list scrolls; the closed one waits for a press or the keys.
- **D2, a slider types no value.** A slider is the track alone, the lowest widget; `number` with `slider = true` is
  the track with a typed field. One widget types a number, not two.
- **The context menu of a value is the program's** (from `prev_box`'s signal), but for the text fields, whose edit
  menu (Undo, Cut, Copy, Paste) is the toolkit's: a value widget has no act that every program shares, until G2's
  Reset.
- **Shift multiplies a step by `Feel.step_shift`** wherever a step is taken (keys, wheel, buttons): the number, the
  slider, the range slider. The others have no step.
