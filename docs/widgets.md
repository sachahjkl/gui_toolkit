# Buttons, numbers and small widgets

The widgets a program asks for most, in `src/ui/widgets.odin` and `src/ui/widgets_ext.odin`: the buttons, the numbers one
sets, and small marks (a spinner, a dot, a label that shows what it cuts). Every widget takes a stable `id` (key.odin)
and keeps its value in the caller's variables.

## Buttons

Three buttons, one concept each:

| Procedure | What it is |
|---|---|
| `button(id, intent, face, disabled, lit, tip)` | words, its size from the style or `next` |
| `icon_button(id, icon, tip, name, icon_font, intent, face, disabled, lit)` | a glyph and no words: a tool of a bar, a close cross |
| `button_icon(id, glyph, text, intent, face, disabled, width, height, icon_font, icon_color, hue, solid, quiet, lit, wrap, left, tip)` | a labelled push button: a glyph ("" none) beside its words |

`icon_button` and `button_icon` stay two procedures: a square glyph without words has no label to lay out, to wrap or
to align, and a screen reader needs a name for it (`name`, else `tip`, else the id).

What they share:

- **`intent`** (`Intent`: Neutral, Primary, Info, Success, Warning, Danger, Cancel): what the act means, and so its
  colour, the soft pair of its hue (`soft_pair`: a tinted fill, its words of the same hue), the same in every theme.
- **`face`** (`Button_Face`): how it sits. `.Raised`: a face of its own (bevelled by the machined finish). `.Ghost`: no
  face until the pointer is over it, a tool among many; an intent then colours its words. `.Toggled`: held down, the
  option chosen (the box flag `.Held`; a screen reader reads it pressed). `icon_button` is a ghost unless told.
- **`disabled`**: shown faded, takes no press and no focus.
- **`lit`**: drawn as under the pointer while what it opened is open (a menu). The box flag `.Lit`.
- **`tip`**: a tooltip once the pointer rests on it for `TIP_DELAY_S`; its description for a screen reader.

The text of `button` and the glyph of `icon_button` are centred unless a style or `next` sets `text_align`
(`next({text_align = .Left})`, `style({text_align = .Right})`): the style's word is kept (`Style.text_aligned`).

`button_icon` has more: `width` (`{}`: as wide as what is in it; `fill()` a share of the row; `px(...)` its own, what is
in it centred, at its left with `left`), `height` (of one line, in pixels), `icon_color` (the glyph says a state in its
colour, the words stay the button's), `hue` and `solid` (a colour by meaning that is no intent; `solid`: the hue itself,
its words dark or light), `quiet` (a secondary act, smaller; a Neutral one's words weak until the pointer is over it) and
`wrap` (words longer than its width go on more lines, the button grows to hold them).

```odin
if ui.button_icon("save", lucide.SAVE, "Save", intent = .Success, icon_font = ui.lucide_icons()).clicked { save(app) }
if ui.icon_button("close", lucide.X, tip = "Close", icon_font = ui.lucide_icons()).clicked { app.open = false }
ui.button("Bold###bold", face = app.bold ? .Toggled : .Raised)
```

The theme's tags of the buttons are named by the intent (`intent_tag`: `accent_button`, `info_button`,
`success_button`, `warn_button`, `danger_button`, `cancel_button`) and by the ghost face (`ghost_button`,
`icon_button`): a theme gives them their colours (themes.md, "Button variants"); a program says `intent =` and `face =`,
not the tags.

`box_hot(b)` and `box_held(b)` say how much a box is drawn under the pointer and pressed in (its `.Lit` and `.Held`
flags count): a program's own draw of a button reads them.

### Wells and hint actions

`if ui.well("###facts") { ... }` is a sunken box, carved in the surface (code, a preview, a list of facts): the theme's
"well" colour, carved in by the machined finish. Its size and corners come from `next`; `axis` lays out its children.

`ui.hint_action(id, text, icon, icon_font, intent)` is words that say what can be done and do it, as a link does: weak
like a hint, lit under the pointer; an intent colours them. It returns its `Signal`.

## Numbers

`ui.number(id, &value, lo, hi, step, format, unit, track, disabled, tip)` is the one widget for a number one sets, of
any integer or float type: − and + around a field where its exact value is typed, then its unit; with `track = true`
and both bounds, a slider before them.

```odin
ui.number("###count", &app.count, lo = 0)                                   // an int, no upper bound
ui.number("###width", &app.width, lo = 1, hi = 40, step = 0.5, unit = "px", track = true)
```

- **Bounds**: `lo` and `hi` are optional (`nil`: none on that side). Every change is clamped to them and rounded to
  `step` (an integer to a whole number). At a bound, its button is disabled.
- **Step**: one step of the keys, the wheel and the buttons (0: 1; a float with both bounds: a hundredth of the range).
- **Field**: shows the value (`format`, a printf format of the type; "": its digits, a float's as many after the point
  as `step` has). Given the keyboard, the field holds the value, all selected; what is typed applies at Enter or when
  the keyboard goes elsewhere. Escape, or text that is no number, gives the value back. The text being typed lives in
  `ui.State` (`number_edit`): one field has the keyboard at a time, so a number keeps nothing of the caller's.
- **Keys** (the field has the keyboard): Up / Down a step, Page Up / Page Down ten; Shift ten times as much, Ctrl a
  hundred, Alt a tenth (`num_step_delta`).
- **Wheel**: over the field or the slider, a notch is a step (Shift: ten); in a view that scrolls, only once it has the
  keyboard (`wheel_steps`).
- **Buttons**: a step each (Shift: ten), repeated while held (`repeat_pressed`). They are no Tab stops: the field is.
- **Screen readers**: the field is a spin button (value, bounds, step; Set value, Increment, Decrement); the slider a
  slider.

`ui.slider(id, &value, lo, hi, step, format)` is the track alone, the lowest widget: its keys (arrows a step, Home / End,
Page Up / Page Down ten steps), its wheel, its screen reader's requests.

`ui.range_slider(id, &lo_v, &hi_v, lo, hi, step, format)` has two thumbs on one track. Each thumb is a Tab stop and a
slider for a screen reader; the active thumb (the one a press took, or the one Tab reached) moves as `slider` does:
arrows a step, Home / End to its ends (the other thumb is one), Page Up / Page Down ten steps. The wheel over the track
moves the active thumb (none: the one nearest the pointer). `format` is each value's ("%.0f": "20-80"; "": no text).

## Small widgets

| Procedure | What it is |
|---|---|
| `spinner(id, size)` | the busy arc, turning: three quarters of a circle in the accent. While shown it asks for the next frames itself (none with animations off); a busy progress indicator to a screen reader |
| `dot(id, size, intent)` | a filled disc of the intent's hue (a recording, a state): the icon fonts have no filled circle |
| `label_tip(text)` | a label whose whole text shows in a tooltip when its box cuts it and the pointer rests on it (`TIP_DELAY_S`); it takes no press |

## A secret's memory

`ui.field_wipe(&f)` empties a `Text_Field` and leaves nothing of its text in memory: its buffer (all its capacity) and
every step of its undo and redo history are zeroed before they go. Call it once a password or a PIN is used or given
up. A step the history drops on its own (the oldest, a redo replaced) is zeroed too. What the buffer held before it last
grew is out of reach: reserve the capacity of a secret's field before it is typed in (`reserve(&f.buf, n)`).
