# Old Head: a Windows 95 theme, and what it shows of the theming

An experiment, on a throwaway branch. The goal: a theme, "Old Head", that looks like Windows 95, done as much as
possible as data. The finding matters as much as the theme. A look is more than colours, and the toolkit's `Theme_Def`
holds colours only. Everything else is spread across the finishes, the widgets and the program's settings.

## What was pure data

One `Theme_Def` in `THEMES` (`src/ui/themes.odin`):

- the six steps: well `#ffffff` (white fields), bg0 = bg1 = bg2 = bg3 `#c0c0c0` (one grey for every surface), line
  `#808080`;
- the four texts: faint `#808080`, weak `#404040`, text and bright `#000000`;
- the eight hues: the accent navy `#000080`, then the deep colours of the 16-colour palette (the bright red, yellow
  and cyan do not read as text on the grey);
- `accent_text = #ffffff`, `versions = .Light_Only`, `finish = .Bevel` (pinned as Aero pins `Glass`).

These came out right with no code: the grey surfaces, the white fields, black text, the navy accent of the accent
buttons, the hues.

## What needed code

A new value `Finish.Bevel` (`src/ui/types.odin`, its name in `FINISH_NAMES`). Each change below is behind
`bevel()` or `finish == .Bevel`. The other finishes take the same paths as before.

| File | What |
|---|---|
| `src/ui/machined.odin` | `machined()` is true for Bevel: the widgets carve their wells and raise their keys as in the machined finish. `bevel()`. The tones of a bevel, made from the face: light = half way to white (`#dfdfdf`), shadow = a third of the way to black (`#808080`). `bevel_frame` (two one-pixel rings, two tones each), `bevel_round` (radios, knobs), `bevel_key`, `bevel_focus` (a dotted rectangle, dots drawn as rects). Bevel branches in `machined_bevel`, `machined_well`, `machined_groove`, `machined_plate_corners`, `machined_plate_frame_corners`, `machined_box` (a focused key draws its own dotted rectangle; a rimmed bar gets one ring). `glow_of` is 0. The hover lift of a well is off. |
| `src/ui/scrollbar.odin` | `rounding()` is 0 for Bevel, as for Edged. `scrollbar_paint_bevel`: a pale track, raised arrows and thumb, a held arrow sunken with its triangle moved one pixel. |
| `src/ui/draw_ui.odin` | `paint_rect` fills plainly for Bevel. No focus halo. The focus of a non-key box (a row) is the dotted rectangle, not the accent's ring. |
| `src/ui/row_face.odin` | a row's face is a plain fill, as Flat. |
| `src/ui/theme_default.odin` | `BEVEL_ENTRIES`: four entries the finish overrides in `apply_palette`: `selection` (the accent, opaque), `selection text` (white), `drop_shadow` and `scrim background` (none). |

About 220 lines, of which 150 are in `machined.odin`. Two exhaustive `switch` statements on `Finish` had to learn the new
value (`paint_rect_corners`, `row_face_paint`). Every new finish touches them.

## What a theme could not express

Each item names the file and the hard-coded value that decides it today.

1. **The corner radius.** A theme has no radius. The radius is the widget's (`CONTROL_RADIUS_EM :: 0.45`,
   `src/ui/widgets.odin:283`; cards, menus, dialogs each have their own em), times the program's
   `State.rounding` (`set_rounding`, `src/ui/scrollbar.odin`). Square corners exist only as a special case of a finish:
   `rounding()` returns 0 when `finish == .Edged`, and now `.Bevel`. The scroll bar has its own radii
   (`SCROLLBAR_THUMB_RADIUS_PX :: 3`, `SCROLLBAR_ARROW_RADIUS_PX :: 2`).
2. **The bevel geometry.** How a raised or a sunken surface is drawn is the code of each finish, with constants private
   to its file: `BEVEL_TOP_LIGHTEN :: 0.14`, `BEVEL_RIM_ALPHA :: 0.22`, `EDGED_EDGE_ALPHA :: 0.85`, `PLATE_SHADOW_PX :: 5`
   (`src/ui/machined.odin`), `GRADIENT_*` and `GLASS_*` (`src/ui/draw_ui.odin`), `ROW_*` (`src/ui/row_face.odin`). The
   ring count, its width and its four tones are not data. Bevel makes its tones from the face colour
   (`BEVEL_LIGHT_STEP :: 0.5`, `BEVEL_SHADOW_STEP :: 1/3`), because no palette slot holds a highlight or a dark shadow.
3. **The focus style.** A solid ring of `"focus border"` at `FOCUS_RING_PX :: 1.5` plus a halo `FOCUS_GLOW_PX :: 5`
   for every finish except Flat (`src/ui/draw_ui.odin`). Machined wells draw a ring of the accent, Edged a hairline of
   it. Only the colour is the theme's. The dotted rectangle needed code. The draw list has `path_dash` for paths
   (`src/draw/path.odin`), but a box's ring is a rect: Bevel draws the dots one rect each.
4. **The selection colours per control.** The palette has one accent. Each selection's alpha is fixed in `entries`
   (`src/ui/theme_default.odin`): `"selection"` 0.35, `"selected background"` 0.22, `"menu_item selected background"`
   0.30, `"nav selected background"` 0.13, `"weak_selected background"` 0.09. A theme cannot ask for an opaque navy.
   Bevel overrides the text selection only. A selected row or menu item cannot have white text: `list_row` pops its
   `"selected"` tag before the caller builds the row's label (`src/ui/list.odin:265`, `:293`), and `menu_row` does the
   same (`src/ui/popups.odin:739`, `:749`). The label asks `"text"` with no `"selected"` on the stack. White on navy for
   rows needs each widget to keep the tag over its children, or a "selected text" colour passed down. So Old Head's
   selected rows are a navy tint under black text, not Windows 95's block.
5. **The motion.** It is the program's and the user's, never the theme's: `Theme.transition_ms` (default 0, so states
   change at once), `Feel.palette_fade_ms = 160` (`src/ui/feel.odin:37`), the scroll's easing toward `view_target`,
   `set_animations` and the system's "reduce motion" (`src/ui/state.odin:917`). Old Head is instant by default because
   the defaults are instant, not because the theme asks. A theme switch still cross-fades for 160 ms.
6. **The font family and size.** A theme has no type. The font is the program's (`ui.use_text_family`, the font
   picker), with Roboto as the bundled fallback (`src/font/font.odin:579`). The size is the program's em. MS Sans Serif
   is not bundled and no bitmap font exists. The closest is Roboto at about 11 px, which a theme cannot set. Old Head
   keeps the program's font.
7. **The scroll bar.** Its form is the toolkit's one standard (`src/md/features/scroll-bar.md`). Its colours are
   computed from five palette entries by fixed mixes in `scrollbar_colors` (`src/ui/scrollbar.odin`). Its thickness
   is the program's `Scrollbar_Size` (Thin 9 px, Wide 17 px; Windows 95 was 16 px). Bevel needed its own paint
   procedure, and the dithered track is a plain colour because the draw list has no pattern fill.
8. **The title bar.** An integrated title bar is the program's `title_bar` box with the program's background.
   `"bar background"` is bg1, a grey here, so no navy band and no navy-to-`#1084d0` gradient is possible. The caption
   buttons are Windows 10's: `CAPTION_BUTTON_WIDTH :: 46`, Segoe Fluent glyphs, `CAPTION_CLOSE_HOT :: 0xc42b1cff`
   (`src/ui/window_chrome.odin:25`–`45`). Edged already special-cases the close button (a red block), with an `edged()`
   test in that file. A system title bar is the system's.
9. **The check mark and the state lights.** The machined path of a check box puts a raised key of the accent in the
   well. Its check is white whatever the theme (`{1, 1, 1, d.t}`, `src/ui/widgets_ext.odin:196`). Windows 95 drew a
   black check on white. A row still lifts under the pointer (`state_entries`: `"list_row hover_fill"` 0.05,
   `src/ui/theme_default.odin`). Windows 95 lit nothing there, and the state steps are not theme data.
10. **Small faults left as they are.** A pressed key's label does not move one pixel down and right: the label is the
    box's text, drawn after the finish, and the finish cannot offset it. The dotted focus is `BEVEL_FOCUS_INSET :: 4`
    inside every box, a row included. Windows drew a row's focus on its edge. Lamps and pips keep the machined bead.
11. **The halo strength.** `Theme.glow` comes from the program's `Theme_Choice`, not from the theme. Bevel forces it to
    0 in `glow_of`.

## What a theme would need to carry

The pattern: whatever a theme cannot say becomes a `Finish` with private constants. Each new look then adds an enum
value, a branch in about ten procedures and two exhaustive switches. `Kernel`, `Aero` and `Bootstrap` already pin
finishes for that reason.

A theme would be four parts, each with defaults that reproduce today's look:

```odin
Theme_Def :: struct {
	name:   string,
	colors: [Version]Theme_Colors,   // as now, plus the relief's tones: highlight, light, shadow, dark
	shape:  Theme_Shape,             // corner radius (em) per role: control, card, dialog, menu; the shape radii kept
	relief: Theme_Relief,            // raised / sunken / groove / plate: ring count, ring width, which tone on which
	                                 // side, blur, shadow size; focus: ring | dotted | none, its width and inset
	motion: Theme_Motion,            // transition_ms, palette_fade_ms, scroll easing on/off, hover light on/off
	type:   Theme_Type,              // a family name and a size in px (nil: the program's), the selection's text colour
}
```

- **Shape** (radius per role): low cost. `rounding()` and `radius_drawn` already funnel every corner. The roles
  replace a dozen `*_RADIUS_EM` constants. About 1 to 2 days, mostly the tests that pin radii.
- **Motion and type**: low cost. They are fields that `theme_show` copies into `Theme` and `Feel`. The type needs a
  rule for who wins, the user's font choice or the theme's. About 1 day.
- **Selection colours** (opaque fill and its text, per role): medium cost. The palette must grow a "selection" pair per
  role. Also `list_row`, `menu_row`, the palette's rows and the file browser's rows must keep a tag over their
  children, or pass the text colour down. About 2 to 3 days, with an audit of every widget that pushes `"selected"`.
- **Relief as data**: high cost. The four finishes become four values of one description, and a single
  interpreter draws them. `machined.odin`, `paint_rect`, `row_face_paint` and `scrollbar_paint` merge. Glass's
  gloss and Machined's blurred inset shadows need their own primitives in that description. About 1 to 2 weeks. It
  removes the `Finish` enum and every `edged()` and `bevel()` test, `window_chrome.odin` and `docking.odin`
  included.
- **Title bar and caption buttons**: medium cost, a separate design. They need a theme entry for the caption band (a
  colour or a gradient), the active and inactive colours, and a caption-button style. Today the program owns them.

The order that pays first: shape, then motion and type, then selection. Relief as data waits until a fourth
pinned finish is wanted. Until then a finish per look costs about 200 lines, as this one did.
