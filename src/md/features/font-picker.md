# The font picker: intent

What the person sees and the API are in [docs/font-picker.md](../../../docs/font-picker.md). This file keeps the
reasons.

## Purpose

The standard settings name three families (`appearance.text.ui_font`, `mono_font`, `prose_font`). They were free
fields, empty at their default: a person saw nothing where a font is obviously in use, and had to know the exact name
the system gives a family. The picker shows the family in use, lists the system's families, each drawn in itself, and
finds one as it is typed. Every program has it, through the settings page; a program's own screen can use it too.

## Decisions

- **A default is a family, named.** "" in the settings file means "the program's", but the field shows the family the
  program draws in, marked: "Roboto (default)". The name comes from gt:font (`font.family_of`), from the program's own
  face (`ui.program_text_face`), which the State keeps beside the chosen one: a family chosen does not rename the
  default.
- **The family of a face is read from its `name` table when nothing else says it.** A face loaded by family
  (`load_system`) has that family. A face loaded from a file or from memory (the hosts' Segoe UI file, the embedded
  Roboto) has none: its typographic family (name 16), else its family (name 1), in the Windows records first. Read
  once, when the face is published, into its own field: `Font.family` stays empty for such a face, because it is the
  base of the system fallback and an embedded family the system lacks would change what the fallback picks.
- **The families come with a monospace flag** (`font.Family`). fontconfig's `spacing` (mono, dual, charcell), the
  regular face's `IDWriteFont1::IsMonospacedFont` on Windows. CoreText marks none (macOS is not a target): the picker
  then shows one list. `font.system_families` returns them; there is one list of families in gt:font, not a second one
  without the flag.
- **The list is read on a chore, once, and kept** (`ui.Font_Families`, the caller's, shared by the pickers of a page).
  A fontconfig or DirectWrite listing reads the disk. It is read at the first opening, not at the page's: a person who
  never opens a picker costs nothing. A family installed during the run shows at the next start; refused: a watcher of
  the font folders for that.
- **A source, not the system, in the picker** (`ui.Font_Source`: the families, a face for one family). The tests give a
  fake one, with no system read; `ui.font_system_source(fonts)` is the system's. Both run on the chores.
- **Each name is drawn in its family, loaded lazily.** Only the rows the list builds (what is in view) ask for their
  face, a batch at a time on one chore, the latest asked first; until it comes the name shows in the interface's font.
  A family whose face cannot be loaded stays in that font and is not asked again. Scrolling fast past a hundred rows
  loads the last batch in view, not the hundred.
- **Faces loaded for the previews stay for the run.** `font.unload` must not overlap a shaping on another thread, and the
  chores shape. A family is loaded once (by its key) whatever the number of pickers and openings.
- **The mono setting lists the monospace families first**, then the others under "Other families". Refused: only the
  monospace ones. The flag is the font's own claim (`post.isFixedPitch`, the advances fontconfig compares): a coding
  font that does not make it must stay reachable.
- **The search is `rank` with `rank_fuzzy`**, the toolkit's one ranking, with a cache and a version: the rows are made
  again when the query or the families change, never in a quiet build. "Default" stays first while the query matches
  its words.
- **A popover with a field, not a `menu`.** A menu takes every key of the frame; the field must type. As the path bar,
  the field keeps the keyboard, and Up, Down, Page Up, Page Down, Enter and Escape are the picker's while it does.
  Home and End stay the field's. A click on the list gives the list the keyboard (its own keys, as every list); a
  letter typed then goes back to the field (`type_to_field`): the list has no type-ahead.
- **Choosing applies at once.** The picker returns the value chosen ("" for the default); the settings page sets the
  preference in the same build, as for every other control, and the toolkit applies it (below). No `restart`.

## Who applies the families

The toolkit, for every program: `prefs_page.standard_watch` calls `ui.use_text_family` at each change of a family
setting. One need, one API. Before, each program read the settings at its start and loaded the faces itself (papier,
classeur), one never applied them (cliche), one listed the system's families on the interface's thread (opencode
native's fork); each had its own bugs and none followed a change without a restart.

- **The State holds the program's three text faces** (`ui.Text_Face`): the program's own (`set_text_faces`, given once
  in `Standard_Targets.faces`) and the chosen family's face (`Family_Face`), with a serial. The style root holds them:
  a view's window reads its owner's, so every window follows with nothing to copy.
- **The face is loaded on a chore**, by the program's `Font_Source` (the system's: `font.load_system`), with its bold
  and italic faces: `font.styled_face` reads the disk for a system face, and a bold word drawn on the interface's
  thread must find them in gt:font's cache. Until the answer the program's face stays; the swap is one build.
- **`begin_build` puts the interface face in use in the base style's place** (the chosen one, else the program's given
  in the targets), after `Build_Params.base` (the owner's for a view's window). The program keeps giving its own face as the base: Default is then the program's again with
  nothing to restore, and the page names it. Refused: the program reading the chosen face into its base each build;
  every program would have to, and one that forgot would draw half in each.
- **`mono_font()`, `prose_font()` and a markdown view's text read the State**, so a program that draws through them
  follows with no code. A program that holds a face of its own derived from them (a bold weight, a cache of measured
  text) watches `text_faces_serial`.
- **A newer ask drops an older answer** (`Family_Face.asked`): two families chosen in a row end on the second whatever
  order the chores answer in. Default is set at once: nothing to load.
- **A missing family leaves the program's face**, logged. Refused: falling back to another family; the person sees
  their choice did not take, the picker shows the name in the interface's font.
- **The program's other faces stay its own.** A terminal face (opencode native's) is not a standard setting; the
  program uses the same `Family_Face` for it rather than a loader of its own.

## The machines

- The picker: closed -> (a click on its button, Down, Enter or Space on it) -> open -> (a choice, Escape, a press
  outside it, the keyboard leaving it) -> closed. Opening selects the current family and puts it in view.
- The families: none -> reading (the first opening) -> ready. Not read again.
- A family's face: not asked -> asked (its row built) -> loaded | missing.
- A text face (`Family_Face`): the program's -> (a family asked) -> loading -> (the chore's answer, if still the last
  ask) -> the family's | missing (the program's). Any -> (Default) -> the program's, at once.

## Subtle points

- At the start, a family in the settings file is loaded like a change: the first frames can draw in the program's
  face, then the chosen one. Refused: loading it before the window, on the interface's thread.
- A program that gives as its base font the face in use rather than its own, and no interface face in
  `Standard_Targets.faces`, makes Default stick on the chosen face: `text_own_face` then reads the base style for the
  program's face. A face given in the targets wins over the base style.
- A family chosen that the system no longer has shows as its name, in the interface's font: the picker does not
  pretend it is in use.
- The comparison of a value with a family folds by ASCII: fontconfig and DirectWrite match family names without case.
- The rows' identities are their kind and family index: the list keeps its measured heights across a search.
