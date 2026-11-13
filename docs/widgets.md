# Buttons, numbers and small widgets

The widgets a program asks for most, in `src/ui/widgets.odin` and `src/ui/widgets_ext.odin`: the buttons, the numbers one
sets, and small marks (a spinner, a dot, a label that shows what it cuts). Every widget takes a stable `id` (key.odin)
and keeps its value in the caller's variables.

## Buttons

![Every intent in the raised, ghost and toggled faces; the hues in their shades and soft pairs (examples/showcase)](screenshots/showcase_intents.webp)

One procedure:

```odin
button :: proc(id: string, text := "", icon := "", o := Button_Options{}) -> Signal
```

`id` is its id (key.odin: `"save"` or `"###save"`); what it shows is `text`, its words, and `icon`, a glyph of
`o.icon_font` (0: `State.icon_font`; `lucide_icons()` for Lucide's). Changing them keeps its state. What the call asks
for decides how it is laid out:

| Call | How it is laid out |
|---|---|
| `button(id, text)`, `button(id, text, icon)` | one row: its glyph and words are boxes in it; its corners rounded |
| `button(id, icon = g)` | a glyph alone (a tool of a bar, a close cross): one box, its size the style's or `next`'s, a ghost unless told |
| `button(id, text, icon, {face = .Link})` | words (and a glyph) with no face, weak like a hint, lit under the pointer, as a link |

`Button_Options`:

- **`intent`** (`Intent`: Neutral, Primary, Info, Success, Warning, Danger, Cancel): what the act means, and so its
  colour, the soft pair of its hue (`soft_pair`: a tinted fill, its words of the same hue), the same in every theme.
- **`face`** (`Maybe(Button_Face)`): how it sits. nil: `.Raised`, a glyph alone `.Ghost`. `.Raised`: a face of its own
  (bevelled by the machined finish). `.Ghost`: no face until the pointer is over it, a tool among many; an intent then
  colours its words. `.Toggled`: held down, the option chosen (the box flag `.Held`; a screen reader reads it pressed).
  `.Link`: no face at all, words that say what can be done and do it; an intent colours them, a little quieter away
  from the pointer.
- **`width`** (`{}`: as wide as what is in it; `fill()` a share of the row; `px(...)` its own) and **`height`** (of one
  line, in pixels; 0: the toolkit's). They win over what `next` says.
- **`left`**: what is in a row wider than it at its left, whatever the style's `text_align`.
- **`quiet`**: a secondary act, smaller; a Neutral one's words weak until the pointer is over it.
- **`wrap`**: words longer than its width go on more lines; the button grows to hold them.
- **`disabled`**: shown faded, takes no press and no focus.
- **`lit`**: drawn as under the pointer while what it opened is open (a menu). The box flag `.Lit`.
- **`tip`**: a tooltip once the pointer rests on it for `Feel.tooltip_delay_ms`; its description for a screen reader,
  and the name of a glyph alone (else its id: a glyph says nothing).
- **`icon_font`**: the glyph's font.

A row takes what the caller says of it, as any box:

- **Its size**: `o.width` and `o.height`, else `next`'s, else as wide as what is in it and a line of the toolkit's
  height. A `text_size(pad)` width is its words' and `pad` on each side. A `fill()` share is never narrower than what is
  in it; in a width of pixels too small for it, the padding gives way first.
- **Its padding**: beside its words, the toolkit's (0.95 of the font size, with the words' own `text_pad`); none when
  `next` gives a `text_pad`, which is then the words' own.
- **Its alignment**: what is in a row wider than it is centred unless a style or `next` sets `text_align`
  (`next({text_align = .Left})`, `style({text_align = .Right})`; `Style.text_aligned`), or `o.left`. The glyph of a
  glyph alone too.
- **Its words**: the style's font and size, and what `next` says of them: `font`, `font_size`, `fg`.

```odin
if ui.button("save", "Save", lucide.SAVE, {intent = .Success, icon_font = ui.lucide_icons()}).clicked { save(app) }
if ui.button("close", icon = lucide.X, o = {tip = "Close", icon_font = ui.lucide_icons()}).clicked { app.open = false }
ui.button("bold", "Bold", o = {face = app.bold ? .Toggled : .Raised})
if ui.button("restore", "Restore the defaults", o = {face = .Link}).clicked { restore(app) }
```

`ui.icon(icon, width, fg, icon_font)` is a glyph and no button: a cell `width` wide, as tall as its parent (0:
`State.icon_font`; `widget_icons()` for the toolkit's own marks, the `ICON_` characters).

The theme's tags of the buttons are named by the intent (`intent_tag`: `accent_button`, `info_button`,
`success_button`, `warn_button`, `danger_button`, `cancel_button`) and by the ghost face (`ghost_button`;
`icon_button` for a glyph alone): a theme gives them their colours (themes.md, "Button variants"); a program says
`intent =` and `face =`, not the tags.

`box_hot(b)` and `box_held(b)` say how much a box is drawn under the pointer and pressed in (its `.Lit` and `.Held`
flags count): a program's own draw of a button reads them.

### Wells and search launchers

`if ui.well("###facts") { ... }` is a sunken box, carved in the surface (code, a preview, a list of facts): the theme's
"well" colour, carved in by the machined finish. Its size and corners come from `next`; `axis` lays out its children.
A well around a field that shows when the field has the keyboard (a composer, a search): `flags = {.Focus_Within,
.Draw_Focus_Ring}`, the ring of the well lit while any box in it has the keyboard.

`ui.search_launcher(id, hint, keys, tip)` is a search field that opens a search elsewhere (a title bar's "Search the
commands" that opens the palette): sunken with an input's border, its magnifying glass, the hint in weak words, the keys
at its end. It holds no text; a click, Enter or Space is its `clicked`. Its size comes from `next` (19 ems wide).

## Numbers

![ui.number with its track, ui.range_slider, ui.slider, a well of facts (examples/showcase)](screenshots/showcase_controls.webp)

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
| `dot(id, size, intent)` | a filled disc of the intent's hue (a recording, a state); with no intent, of the text's colour where it stands (a dot in a button's words). The icon fonts have no filled circle |
| `label_tip(text)` | a label whose whole text shows in a tooltip when its box cuts it and the pointer rests on it (`Feel.tooltip_delay_ms`); it takes no press |

## A secret's memory

`ui.field_wipe(&f)` empties a `Text_Field` and leaves nothing of its text in memory: its buffer (all its capacity) and
every step of its undo and redo history are zeroed before they go. Call it once a password or a PIN is used or given
up. A step the history drops on its own (the oldest, a redo replaced) is zeroed too. What the buffer held before it last
grew is out of reach: reserve the capacity of a secret's field before it is typed in (`reserve(&f.buf, n)`).
