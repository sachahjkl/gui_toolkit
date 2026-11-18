# Interaction states: hover, press, chosen

Under the pointer, held down, chosen: each state of a widget is drawn by the widget, in its own design and on its own
geometry, in every finish. No state is a translucent layer laid over the widget.

## Why

The toolkit drew every state of a `.Draw_Hot_Effects` box as one translucent fill over the box's rect (`hover_fill`,
`press_fill`, draw_ui.odin). Two faults came out of that:

- **The layer was not the widget.** A check box's row carried the flag, so the fill covered the row: the spacer before
  the mark, the mark, the spacer after it, the label. In a narrow cell of a list (a check box with no label), that was a
  grey square larger than the box and off its centre. The box itself did not change.
- **The layer flattened the design.** Over a gradient button it was a grey veil on the gradient; over a machined key the
  key did not move. A state must be the face moving: lighter, sunk, lit; the finish's own reliefs then follow it.

## The rule

A state changes the **face** of the box that has it, and nothing else. The face is what the box draws as its surface:
its background, painted by the finish (`paint_rect_corners`: flat, gradient, glass), or its relief (machined, edged).
Its rect and its radii are the box's: whatever reacts is exactly the widget's geometry.

| State | What the face does |
|---|---|
| Hover | lifts one step toward the theme's tint (`Slot.Hover`: white on a dark palette, black on a light one), by the tags' `hover_fill` (a fraction in sRGB values). A border lifts by `hover_border`. |
| Press (the button held on it) | sinks: the deeper step `press_fill`; a gradient or a lit face inverts (its top darker, its bottom lighter, no rim); glass loses most of its gloss; a machined or edged key goes in (`machined_bevel`'s pressed form). |
| Toggled (`.Held`: a tool that is on, a pressed toggle button) | the sunk face of a press, at rest. Under the pointer it lifts half a hover step. |
| Chosen (a selected row, the current tab, the chosen segment) | its own face: the theme's `selected` colour (a tint of the accent) as the row's background, or the widget's own plate (a tab, a segment). Under the pointer it lifts one step more. |

The steps are one function (`face_step`), so the combined states agree: a selected row under the pointer lifts, a
toggled tool under the pointer lifts less than a free one, a press goes to the press step whatever was before.

### A face that has no colour at rest

A ghost button, a row of a list, a menu's item, a tab not chosen: there is no face at rest. Under the pointer the face
appears, in the box's shape: the colour of what is under it (`box_under` of its parent) stepped toward the tint, opaque.
It appears with the hover's ease; once settled it is opaque, not a veil. A tag's `hover_sheen` (0..1) says whether the
face that appears is raised: the ghost and glyph buttons and the tabs are (in the gradient and glass finishes the
finish's light at that strength; machined and edged, the key rises out of the plate: `machined_bevel` faded in); rows
are not (a row is flat).

### A face that is translucent at rest

A selected row's accent tint is translucent at rest (it is tuned for the blend space, theme_default.odin). In a state it
is first made opaque over what is under it, in the frame's blend space, then stepped: a hovered selected row is a
lighter selected row, not a selected row with a grey veil on it.

### Widgets that draw their own face

Some widgets draw their face in a custom draw. Each takes the states of its clickable box and draws them in its parts:

- **Check box, radio** (`mark_draw`): the row is the target, the mark is what reacts. Unchecked: the ring goes toward the
  accent and the inside lifts a step; pressed, the inside sinks a step. Checked: the accent face lifts; pressed, it sinks.
  Machined: the well's face lifts and its rim catches more light (`machined_well`'s `hot`); a checked box's accent key
  takes `machined_bevel`'s hover and press. The row draws nothing.
- **Switch** (`toggle_draw`): the track lifts a step; the knob grows a little (it did) and its key takes the hover and the
  press. The row draws nothing.
- **Slider**: the knob grows under the pointer and while held (it did); machined, its key lifts and sinks.
- **Fields** (`line_edit`, `text_edit`, a number's field, `input_frame`): the border lifts (`input hover_border`), the
  face lifts a small step (`input hover_fill`); a press does not sink a field (it is no key: its press puts the caret).
  Machined: the well's face lifts and its lip catches more light. A field inside an `input_frame` (tag `bare`) draws no
  state: the frame is the field's face, and it reacts while the pointer is on what it holds (`.Hot_Within`); a face of
  the bare field's own was a second, smaller one inside the frame.
- **The window's title buttons** (`caption_draw`): they draw the system's own fills (WinUI's subtle fills, a red close),
  opaque over the title bar: already their own face.
- **A folded pane's strip** (`pane_draw`): its face is `state_fill`'s opaque step.

### Rows: an inset, rounded face

A row of a list, of a table, of a menu, of the palette, of a file browser's places, of a sidebar (`.Row`) drew its hover
and its selection as a rectangle from edge to edge, square, flat. The owner's verdict: "too plain and square, sharp
angle". A row now draws its face as a control does, inside its box (row_face.odin):

- **Inset.** The face is `ROW_FACE_INSET_EM` (0.3 em) in from each side and `ROW_FACE_GAP_PX` (1 px) in from the top and
  the bottom: two rows under the pointer one after the other, or a row under the pointer under a selected one, read as
  two faces. The face is behind the row's content: nothing in the row moves, the box's rect and layout are unchanged.
- **Rounded as the controls.** Its radius is the box's own, through `box_drawn_radius`, the path of a button's: the row
  widgets give their box the theme's row radius (`shape_of(.Row)`, a control's 0.45 em by default:
  [theme-design.md](theme-design.md)) unless the program's `next` says otherwise. So the rounding setting scales it,
  rounding 0 and the edged finish make it square, and a program that wants square rows gives the row `radius = 0`. It
  is at most half the face's height (a pill, never a blob).
- **Consecutive selected rows are one block.** A selected row whose neighbour above (or below) is selected and touches
  it is joined to it: no gap there, square corners there. The run is one rounded block, as Finder draws a selection of
  several files; separate pills with a pixel between them read as a striped column. Each row paints the whole run's
  face clipped to its own rect, so a finish's gradient and lit line run over the whole block, once. The run is looked
  for among the row's siblings, and only while they are in the list's view: a cost bound by the rows shown, not by the
  rows selected.
- **In the finish.** Flat: a plain fill. Gradient: a soft vertical gradient and a faint lit line along its top.
  Glass: a calm gloss (its upper part a little whiter), a thin rim of light, and for a selection a fine edge of the
  accent, as a selection of the system's glass did: the full glossy plate of a button was too loud behind text.
  Machined: a low plate, its top lit and its bottom shaded, faint under the pointer, stronger when selected. Edged: the
  same drawn crisp, a lit hairline on top and a shade line under it. Pressed, the light turns over (lit_face's sunk).
- **Selected.** The selection's tint (`selected`, or `weak_selected` when the list does not have the keyboard or the
  window is not the user's) is the face at rest; under the pointer it lifts one step (face_step), as before. A
  navigation's row (a sidebar's page, a file browser's place: tag `nav`) adds a short rounded bar of the accent at the
  face's leading edge (theme: `row_mark`), on a calmer tint (`nav selected background`): the bar says where the user
  is, and a weak text on the face (the palette's keys) stays readable, which the palette's old well was made for. Lists
  and tables have no bar: their content starts close to the face's edge,
  a bar there met the icons, and the strong and weak tints already say whether the list has the keyboard.
- **A row's ground stays square.** A list's zebra stripe and a row's own tint (`list_row`'s `tint`) are not a state:
  they run from edge to edge, row under row, and the face is drawn over them.

Hover and selection animate as every face: hot_t with the theme's ease, the background's colour cross-fade; with the
animations off, they jump.

The palette's rows, a dialog's choice rows (`choice_row`) and the font picker's drew their selection as a well with a bar
of the accent, square and full width: they are rows of the same kind, and draw the same face now (with the bar: they
are what the keyboard moves through, a navigation).

A sidebar's entry is a button of face `.Row` (`selected` says the page shown): it was a ghost button and a toggled one,
a key pressed in, which read as a control that is on, not as the place where the user is.

`state_fill(b, name, under)` is for a program's own custom draw: the opaque face of a state (`"hover_fill"`,
`"press_fill"`) over `under`. A program's own box with `.Draw_Hot_Effects` needs nothing: draw_box draws its face by
the rule above.

## Timing

A hover eases in and out at the theme's transition (`State.anim_rate`, `Theme.transition_ms`). A press is shown at once
(`active_t` jumps to 1 when the button goes down) and eases out on release: a press that fades in reads as lag. With
the animations off, every state jumps.

## Chosen, and the window that is not the user's

A list's selected rows are `selected` while the list has the keyboard and the window is the user's; else
`weak_selected` (a calmer tint of the accent): readable, and quieter than the rows the user acts on now.

## What stayed

- The keyboard's focus ring is not a state of the face: it stays a ring around the box (or the well's accent edge).
- `.Draw_Hot_Effects` keeps its name: the programs' own rows carry it, and it now means "the face reacts".
- The theme's names `hover_fill`, `press_fill` and `hover_border` stay: they are the steps of the face.

## Refused

- **Keep the overlay and align it.** Aligned, it was still a veil over the design: the gradient and the bevel did not
  move.
- **A plate behind the mark.** Larger than the box by definition; the box itself must react.
- **A row's face from edge to edge** (the previous design): square and flat, it read as a block of colour, not as a
  thing under the pointer.
- **Selected rows as separate pills** (a pixel between them, as Windows' Explorer): a selection of ten files was a
  striped column. Joined, it is one block, and a row under the pointer next to it stays a face of its own.
- **A radius of the rows' own:** two roundings in one window, and a program's square look (rounding 0) left rounded rows.
- **One colour per state in the theme (hover face, press face).** The steps are fractions toward the tint, so that every
  surface (a button, a soft intent button, a row on a card) gets its own lighter or deeper face.
