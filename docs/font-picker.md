# The font picker (`src/ui/font_picker.odin`)

A button that shows the family in use, drawn in that family, and opens a list of the system's families under a search
field. "Default" heads the list: the family the program draws in when none is chosen, named ("Roboto (default)"). Each
family's name is drawn in itself; the monospace families are marked. The settings page uses it for the three family
settings (`appearance.text.ui_font`, `mono_font`, `prose_font`, [prefs_page.md](prefs_page.md)); a program's own screen
can use it too. The reasons: [src/md/features/font-picker.md](../src/md/features/font-picker.md).

```
 ┌───────────────────────────────┐
 │ Roboto (default)            v │   the button: the family in use, in its face
 └───────────────────────────────┘
 ┌───────────────────────────────┐
 │ ┌ Search fonts ─────────────┐ │
 │ └───────────────────────────┘ │
 │ ▌Roboto (default)           ✓ │   the current one, selected at the opening
 │  DejaVu Sans Mono  monospace  │
 │  Inter                        │
 │  Noto Serif                   │
 └───────────────────────────────┘
```

## Use

```odin
app.families = ui.Font_Families{source = ui.font_system_source(&app.fonts)}   // one for every picker of a screen
app.picker: ui.Font_Picker                                                   // one per setting

ui.next({width = ui.px(em * 15)})
if v, ok := ui.font_picker("###code_font", &app.picker, &app.families, app.code_font, {default_face = app.mono, monospace = true}).?; ok {
	set_code_font(app, v)   // "": the default
}

// at the end
ui.font_picker_destroy(&app.picker)
ui.font_families_destroy(&app.families)
```

- `font_picker(id, &st, &families, value, o) -> Maybe(string)`: `value` is the family chosen ("": the default). The
  result is a family the person picked in this build ("" for Default; temporary memory): the caller sets it at once.
  Its size is `next`'s (else 22 ems wide and a button's line high).
- `Font_Picker_Options`: `default_face` (the face drawn when no family is chosen: its family is named, "Roboto
  (default)"; 0: "Default", unnamed), `monospace` (the monospace families first, the others after them under "Other
  families"), `name` (what a screen reader calls it; "Font" by default).
- `Font_Families`: the families and their faces, shared by the pickers of a screen. Set its `source`; keep it as long as
  the `ui.State` it is used in (the answers of its chores come in that State's builds). The list is read at the first
  opening of a picker, on the chores, and kept for the run. `font_families_face(&families, family)` is the face of a
  family when it is loaded (0 meanwhile: it is asked for).
- `Font_Source`: `families(user, allocator) -> []font.Family` and `face(user, family) -> font.Font_Id`, both called on
  the chores. `font_system_source(&fonts)` reads the system (`font.system_families`, `font.load_system`); a test gives
  its own, with no system read.
- `font_default_label(family)`: how a default reads ("Roboto (default)"; "Default" when the family is "").
- `font_picker_open(&st, &families)`: opens the list as a click on the button does, from elsewhere (the settings page's
  `control_open`, a picture of it); the families are read on a chore if they are not yet.

## The text faces (`src/ui/text_faces.odin`)

A program has three text faces: the interface's, the monospace one and the reading one (`ui.Text_Face`: `Interface`,
`Mono`, `Prose`). Each is the program's own until the person chooses a family for it; the toolkit then loads that
family's face on a chore and swaps it in when it comes, in every window of the program, with no restart. The standard
settings do it by themselves (`prefs_page.standard_watch`, [prefs_page.md](prefs_page.md)): a program gives its own
faces once, in `Standard_Targets.faces`, and nothing else.

```odin
prefs_page.standard_watch(&app.standard, &app.prefs, &h.state, {renderer = &sh.r, fonts = &sh.fonts, faces = {.Mono = app.mono}})

// in a build: the faces in use
ui.next({font = ui.mono_font()})
markdown.view(&doc, "###doc", src, {})   // its text in ui.text_face(.Prose): View_Options.prose is 0

// a cache of the program's own, laid out with them
if n := ui.text_faces_serial(&h.state); n != app.faces_seen { app.faces_seen = n; layout_again(app) }
```

- `set_text_faces(s, own, source)`: the program's own faces (each 0: the interface's is `Build_Params.base.font`, the
  monospace one `State.mono_font`, the reading one the interface's) and where the families come from (zero: the
  system's). `Build_Params.base.font` stays the program's own face: `begin_build` puts the chosen one in its place.
- `use_text_family(s, which, family)`: the family for one face; "" puts the program's back at once. A family the source
  has no face for leaves the program's, and is logged.
- `state_text_face(s, which)`, `text_face(which)`: the face in use (0: the program has none of its own for it).
  `mono_font()` and `prose_font()` fall back to the interface's. `program_text_face(s, which)`: what Default draws in.
- `text_family(s, which) -> (family, loading)`, `text_faces_serial(s)`: what was asked, and a count that moves with
  every change of a face in use.
- `text_font_source(s)`: the families' source (the program's, else the system's); the settings page lists from it.
- `Family_Face`, `family_face_set(s, &ff, family, source)`, `family_face_destroy(&ff)`: the same for a face of the
  program's own (a terminal's): its `face` once loaded (0 meanwhile, or missing), its `serial`. Keep it as long as the
  State: the chore's answer comes in that State's builds.

## What the person does

| Input | Effect |
|---|---|
| a click on the button, Down, Alt+Down, F4, Enter or Space on it | opens the list, the current family selected and in view |
| typing | narrows the list (fuzzy, the toolkit's ranking); the best one is selected |
| Up, Down, Page Up, Page Down | move in the list while the field has the keyboard |
| Enter, a click on a row | chooses it and closes |
| Escape, a press outside, Tab away | closes, nothing chosen |

A click on the list gives it the keyboard: its keys are a list's (Home, End too); a letter typed goes back to the field.

## Costs

Only the rows in view (and a margin) are built (`vlist`), and only they ask for their face: a batch of
`FONT_PICKER_LOAD_BATCH` families at a time, on a chore. Until a face comes, its name shows in the interface's font.
A family whose face cannot be loaded keeps that font. The faces loaded stay for the run. The rows are ranked again only
when the query or the list change.
