# A theme carries its shape, not only its colours

A theme was a name and colours (`Theme_Def`). Everything else that makes a look was spread over the finishes, the widgets
and the program's settings. The experiment "Old Head" (branch `theme-oldhead`, its `src/md/features/theme-oldhead.md`)
made a Windows 95 theme and needed a new `Finish.Bevel` of about 220 lines: each look that a theme cannot say became a
finish with private constants, a branch in about ten procedures and in two exhaustive switches.

The decision: a theme carries its look as data (`Theme_Look`, in `Theme_Def.look`). Old Head then becomes a theme made
of data, with no finish of its own. The work goes in layers, in the order of the finding's gaps. Each layer leaves every
existing theme looking as it did: the pixel baselines do not move.

## The finding, and where each gap went

The experiment's file stays on its branch; what it found is here. Its gaps, each with the value that decided it then:

| # | Gap | Then | Now |
|---|---|---|---|
| 1 | the corner radius | each widget's em constant (`CONTROL_RADIUS_EM` 0.45, cards, menus, dialogs), times the rounding; square only in a finish | layer 1 |
| 2 | the bevel geometry | each finish's private constants (`BEVEL_*`, `EDGED_*`, `PLATE_*`, `GRADIENT_*`, `GLASS_*`, `ROW_*`) | layer 6: rings for a bevel, the finishes' extras |
| 3 | the focus style | a ring of `FOCUS_RING_PX` 1.5 and a glow of 5 px, the colour alone the theme's | layer 3 |
| 4 | the selection per control | one accent, each selection's alpha fixed; `list_row` and `menu_row` pop `selected` before the label | layer 2 |
| 5 | the motion | the program's and the person's only | layer 4 |
| 6 | the font | the program's family and size | layer 5 |
| 7 | the scroll bar | the toolkit's one form, its colours fixed mixes of five entries | left for later |
| 8 | the title bar | the program's box, Windows 10's caption buttons | left for later |
| 9 | the check mark and the state lights | a white check on the accent's key; a row lifts under the pointer | left: the widgets' |
| 10 | small faults | a pressed key's label does not move; the focus inset is the same in a row | the row's focus is on its face (layer 3) |
| 11 | the halo strength | `Theme.glow`, the program's | layer 6: `Relief.no_glow` |

The experiment's way, a `Finish` per look, cost a value in the enum, a branch in about ten procedures and two
exhaustive switches each time. Refused for that.

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

## Layer 6: relief as data (built)

`Relief` (`src/ui/relief.odin`) says how raised and sunken surfaces are drawn. `Theme.relief` is the one drawn:
`apply_palette` sets it from `Theme_Look.relief` when the theme gives one, else from the program's finish
(`relief_of(finish)`). Every test of the finish in the drawing now asks the relief; no code compares a `Finish` any more.

A relief is two parts.

- **Flags**, one per decision a finish used to take by its name: `carved` (wells, keys, grooves and plates drawn by the
  relief: `machined()`), `square` (`rounding()` is 0), `sheen` (raised faces lit, a focus ring that glows), `engrave`,
  `face` (how `paint_rect` lights a fill: `Face_Paint`), `row` (a row's face: `Row_Paint`), `no_glow` (the halos'
  strength capped at 0 whatever `Theme.glow`), `no_hover`, `no_shadow` (the `drop_shadow` and `scrim background`
  entries at 0), `surface_tones`.
- **Rings**, per surface kind: `raised`, `pressed`, `sunken`, `groove`, `frame` (a panel), `bar` (a rimmed bar or key
  cap). A ring has its width (in pixels of `px1`), the tone of its top and left sides and of its bottom and right sides
  (a step of the face toward white, above 0, or black, below 0), and its blur. `relief_rings` draws them, outermost
  first; `relief_round` draws a round shape's first ring as two discs a ring apart (straight rings cannot go round);
  `relief_lines` draws a groove, each ring a line.

`extra` names the code a preset draws by, beside or in place of rings. A relief of rings has none (`extra = .None`,
`carved`): every primitive of `machined.odin` (`machined_bevel`, `machined_well`, `machined_groove`, the plate and its
frame, `machined_box`'s rimmed bar) then draws its rings.

`Finish` stays: its values are the names of the presets `RELIEF_FLAT` (the zero value), `RELIEF_GRADIENT`,
`RELIEF_GLASS`, `RELIEF_MACHINED` and `RELIEF_EDGED`, so a program's setting still picks one. `RELIEF_BEVEL` is a preset
of rings alone, with no finish name: a theme gives it.

### Why the five finishes are their extras, not rings

The first test of the design was: every finish drawn from rings gives today's pixels. No finish passes it, so each
preset keeps its code as its extra and its rings are empty. A preset that moves a pixel is worse than an extra. What
does not reduce to rings of the face:

- **The tones are not steps of the face.** Machined's and Edged's edges, rims, lips and shades are alphas of black and
  white over what is under (`relief_shade`, `relief_shine`), and on a light palette they go through `RELIEF_ON_LIGHT`'s
  scales and floor. A ring's tone is a step of the face.
- **The edges are filled rounded shapes, drawn from the outside in**, each over the antialiased edge of the one under it
  (the dark edge, then the face inset by a pixel). Straight rings at a radius leave gaps in the curves; that is why the
  machined code stopped drawing strokes side by side.
- **The lines stay off the corners.** Edged's hairlines and machined's under-shade are inset by a share of the radius
  (`radius * 0.6`, `* 0.8`), not by a ring's width.
- **Blurred and offset shadows** (`box_shadow` under a key, `inset_shadow` in a well and a pressed key) are a shape's
  blur moved down, not a ring's.
- **Hover and focus mix into the edge** (a rim brighter by `BEVEL_RIM_HOT * hot`, a well's edge toward the accent by its
  focus), and the gradients of the faces run from their top to their bottom.
- **Glass's gloss** is two half-faces of four stops, and **Gradient's** lit face is a gradient with a rim fading down
  its sides (`lit_face`): no ring at all.

Written as data, each of these would add a field per case, and the "rings" would become the old code as a table. So
the presets carry the flags (what used to be `finish ==` tests) and their extra; a theme that wants another look gives
rings. The flat finish is `Relief{}`: its plain face and thin edge are the primitives' flat path.

A relief of rings has a known limit: the widgets' own machined touches (a radio's lit bead, a section's caption face,
the lamps) still draw their machined forms when `carved` is set.

## Layer 7: Old Head as data (built)

Old Head is one `THEMES` entry and nothing else: its colours (one grey `#c0c0c0` for every surface, white fields, navy
`#000080`, the deep hues of the 16-colour palette), and its look:

- `shape = Theme_Shape{}`: every role square;
- `relief = RELIEF_BEVEL`: two one-pixel rings, white and the face's light (`#dfdfdf`) along the top and left, black and
  its shadow (`#808080`) along the bottom and right; pressed and sunken, turned over; wells, grooves and frames in the
  grey's tones (`surface_tones`); plain faces and rows; no halo, no light under the pointer, no drop shadow, no dim
  behind a dialog;
- `focus = {style = .Dotted, inset = 4, color = black}`: Windows' focus rectangle;
- every selection navy with a white ink;
- `still`.

Its finish is nil: its relief wins over whatever finish the program asks. `Finish.Bevel` and its `bevel()` tests, the
experiment's, do not exist. Its film (`tools/film/oldhead.odin`, `tk film oldhead`) shows the showcase in it.

## Left for later

- The scroll bar's form (a pale track, raised arrows and thumb for Old Head): the bar's form is the toolkit's standard
  (scroll-bar.md); a theme's bar is a separate design.
- The title bar and its caption buttons: a caption band (colour or gradient), active and inactive, a caption-button
  style. A separate design.
- A themes file's keys for the look (a radius, a focus style): the file says colours today.
