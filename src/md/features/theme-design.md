# A theme carries its shape, not only its colours

A theme was a name and colours (`Theme_Def`). Everything else that makes a look was spread over the finishes, the widgets
and the program's settings. The experiment "Old Head" (branch `theme-oldhead`, its `src/md/features/theme-oldhead.md`)
made a Windows 95 theme and needed a new `Finish.Bevel` of about 220 lines: each look that a theme cannot say became a
finish with private constants, a branch in about ten procedures and in two exhaustive switches.

The decision: a theme carries its look as data (`Theme_Look`, in `Theme_Def.look`). Old Head then becomes a theme made
of data, with no finish of its own. The work goes in layers, in the order of the finding's gaps. Each layer leaves every
existing theme looking as it did: the pixel baselines do not move.

## The rule that keeps every theme as it was

Every part of `Theme_Look` has a zero value that is the toolkit's look before this design. A theme says only what
differs. The same `Theme_Look` rides in `Palette.look` (a program and a test make palettes, not themes) and in
`Theme.look` (what the drawing reads; `apply_palette` copies it and bumps `Theme.serial` when it changes).

Refused: a full `Theme_Look` with the default values written out in each theme. A palette made by a program (and every
test's) would have zeros, and zero radii are a real look (Old Head's square corners). A `Maybe` where 0 is a value, a
zero meaning "the default" where 0 is no value: that keeps zero-initialised palettes right.

`Theme_Def` is a positional literal in `THEMES` (and in the programs). The new field is last, and every literal gives
it: `{}` for a theme without a look of its own.

## Who wins

The person's explicit choice wins over the theme, and the theme wins over the program's built-in default:

- the rounding setting (`set_rounding`) scales the theme's radii; the edged finish still squares them;
- the person's font family (`use_text_family`) wins over the theme's family;
- the person's motion setting `Animations.On` wins over the theme's stillness; `.System` follows the system and then
  the theme; `.Off` is still anyway. A theme can remove motion, never add it.

## Layer 1: shape per role (built)

`Theme_Look.shape: Maybe(Theme_Shape)`, nil: `SHAPE_DEFAULT`. `Theme_Shape` is `[Shape_Role]f32`, the radius of each
role before the rounding setting: in ems of the font size, the scroll bar's in logical pixels.

| Role | Default | Who takes it |
|---|---|---|
| `Control` | 0.45 em | buttons, fields, a frame of fields, a dropdown, a number's field, the search launcher, the hot-key field, the font picker's button, the find bar |
| `Row` | 0.45 em | a row's face: a list's, a menu's, the palette's, a dialog's choice, the file browser's places, the font picker's, a button drawn as a row |
| `Card` | 0.6 em | `card`, `list_card` (a card's own `Card_Options.radius` still wins) |
| `Dialog` | 0.8 em | a dialog, an internal window |
| `Menu` | 0.5 em | a menu's panel |
| `Tooltip` | 0.4 em | a tooltip |
| `Scroll_Thumb` | 3 px | the scroll bar's thumb |
| `Scroll_Arrow` | 2 px | the scroll bar's arrow buttons |

`shape_of(role)` reads the value of the theme shown. The widgets multiply it by their font size as they multiplied the
constant: the same float product, so the default radii are the same bits. `CONTROL_RADIUS_EM` and `DIALOG_RADIUS_EM`
are gone; a widget that needs a role's radius asks `shape_of`.

The other radii stay the widget's: a tab (0.35 em), a strip's arrow, a swatch, a node of a graph, a scroll mark's head,
a find match, a QR code. They are part of their widget's form, not of a role a theme dresses. What is round by its shape
(a radio, a switch, a slider's knob: `shape_rad`) keeps its radius.

## Layer 2: selection per role, with its text colour (built)

`Theme_Look.selections: [Selection_Role]Theme_Selection`. A role's `fill` (0xRRGGBBAA; 0: the accent at the role's own
alpha) and its `ink`, the text on it (0: the text as it is).

| Role | Fill entry (default alpha) | Ink entry |
|---|---|---|
| `Text` | `selection` (0.35) | `selection text` (default: the text) |
| `List` | `selected background` (0.22) | `selected ink` |
| `Menu` | `menu_item selected background` (0.30) | `menu_item selected ink` |
| `Nav` | `nav selected background` (0.13) | `nav selected ink` |
| `Weak` | `weak_selected background` (0.09) | `weak_selected ink` |

The finding's gap: `list_row` and `menu_row` pop the `selected` tag before the caller builds the row's label, so the
label asks `text` with no `selected` on the tag stack. Keeping the tag over the children was refused: the `selected`
entries (`selected border`, `selected sheen`) would reach every child (a field's border turns accent, a label gets the
machined engraving) and move the baselines.

The ink is passed down instead. A `.Chosen` box (every selected row is one) reads `ink` under its tags when it is built
(`Box.ink`). What is built inside it takes that ink as its text colour, unless it gives its own colour (`next`'s `fg`)
or draws a face of its own (an opaque background: a button in the row keeps its text). The ink goes down the tree
until such a face. A disabled box keeps the disabled text. The ink entries are alpha 0 by default: no ink, nothing
changes. So no widget had to change, and every selected row has it: the list's, the menu's, the palette's, the file
browser's, the font picker's, a dialog's choices.

## Layer 3: focus style (built)

`Theme_Look.focus: Theme_Focus`: `style` (`Ring_Glow`, the default: the solid ring and, in every finish but Flat, its
glow; `Ring`: the ring alone; `Dotted`: a dotted rectangle), `width` (logical px; 0: `FOCUS_RING_PX` for a ring, 1 for
the dots), `inset` (the dotted rectangle this far inside the box, logical px; a row's on its face) and `color`
(0xRRGGBBAA; 0: `focus border`).

The dots are a rect each: the draw list has `path_dash` for paths, not for a rectangle's ring, and one-pixel dots at a
two-pixel pitch are what a dash of a path antialiases badly. On a box with an ink (a selected row) the dots take the
ink: Windows drew them in XOR, the ink is what reads on the selection.

What a relief draws for its own focus (the machined well's accent ring, the edged hairline) stays the relief's: layer 6.

## Layer 4: motion (built)

`Theme_Look.still`: the theme's look has no motion. In `begin_build`, under `Animations.System`, a still theme turns
the animations off as the system's "less motion" does: states, fades, tweens, the scroll's easing (`Smooth_Scroll.Follow`),
the cross-fade of a palette change. `Animations.On` (the person's word) keeps them.

## Layer 5: font (built)

`Theme_Look.font: Theme_Font`: `family` (a family name; "": the program's) and `size` (a factor of the program's font
size; 0: 1).

- The family is loaded as the person's family is (`family_face_set`, on a chore), into `State.text_themed`. The
  interface's face is the person's family when one is asked, else the theme's once loaded, else the program's own. A
  family the system lacks leaves the program's face (logged once).
- The factor multiplies the root style's font size before the zoom, then the size is rounded as before. A factor of 0
  or 1 takes the old path: the same size. The person's text size is the base the factor scales, so the person still
  sets it.
- The theme's family is the interface face's only: the monospace and the reading faces are a program's content.

## Layer 6: relief as data (designed, not built)

Edged, Machined, Gradient, Glass and Old Head's Bevel each draw a raised and a sunken edge with constants private to
their files (`machined.odin`, `draw_ui.odin`'s `GRADIENT_*` and `GLASS_*`, `row_face.odin`'s `ROW_*`).

A relief is data: per surface kind (raised, pressed, sunken, groove, plate, a row's face, an accent fill) a list of
rings, each with its width (device pixels or logical ones), its tone per side (top and left, bottom and right) as light
or dark of the face (a step toward white or black, or a relief shade or shine of an alpha), its blur (0: crisp) and
its offset; plus the face's own gradient (top and bottom steps). One routine draws every finish from that data.
`Finish` stays as the names of presets of relief data, so a program's setting still picks one.

What does not fit rings stays a preset's extra, named in the preset: Glass's gloss (two half-faces of four stops),
Machined's inset shadow of a well and its blurred drop shadow under a key, the lamp's bead. The routine draws the
extras of a preset after its rings.

The first test: every finish drawn through the routine gives the same pixels as today's code, for each surface kind,
on a dark and a light palette. Until that test passes on the five finishes, the old code stays.

Also in this layer: the square corners of the edged finish become the preset's (`rounding()` asks the relief, not
`finish == .Edged`), and the halos' strength (`Theme.glow`, the program's) is capped by the preset (Bevel: 0).

## Layer 7: Old Head as data (designed, not built)

Old Head becomes one `THEMES` entry: its colours (one grey `#c0c0c0`, white fields, navy `#000080`), `shape` all 0,
the bevel relief preset (two one-pixel rings: white and the face's light along the top and left, black and its shadow
along the bottom and right; turned over when pressed or sunken), `focus = {style = .Dotted, inset = 4, color = black}`,
every selection navy with a white ink, `still`, no drop shadow and no scrim (preset data). Its film
(`tools/film/oldhead.odin`) comes with it. No `Finish.Bevel`, no `bevel()` test anywhere.

## Left for later

- The scroll bar's form (a pale track, raised arrows and thumb for Old Head): the bar's form is the toolkit's standard
  (scroll-bar.md); a theme's bar is a separate design.
- The title bar and its caption buttons: a caption band (colour or gradient), active and inactive, a caption-button
  style. A separate design.
- A themes file's keys for the look (a radius, a focus style): the file says colours today.
