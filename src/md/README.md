# gui_toolkit: intent

This folder follows <https://srcmd.org>: the reasons behind the toolkit's modules, their decisions and their subtle
points. The documentation for the programs that use the toolkit is in [docs/](../../docs/). Only Markdown is here: the
tools that list the packages of `src/` skip a folder that holds no Odin file.

The toolkit is the base of several programs (papier, classeur, inspecteur, cliche, opencode native, Wren). A need
common to two programs has one API here, and none in the programs: no duplicate, no alias, no compatibility layer. The
programs are the only users, so an API changes freely when the usage changes; each program is migrated in the same
piece of work.

## Overview

The toolkit is an immediate-mode interface (`ui`) over its own platform layer (`platform`), renderer (`render`, `draw`)
and text (`font`). Two rules shape every module:

- The interface's thread makes no system call and no work in proportion to the data in a frame. Readings go to the
  chores (`ui.task`, `gt:tasks`); a result comes back at a next build. Lists, filters, sorts and translated tables are
  made when their data changes, and kept.
- What is one app's state lives in its State (or its Window, its Renderer), never in a global.

Every window has its own `ui.State`; the renderer and the fonts are shared between the windows of a program. What a
program shows the same way in every program is a standard part of the toolkit, not a program's code: the settings page
and its standard settings, the install page, the licence page, the crash bar, the diagnostics, the updates, the palette
and its memory, the views, the texts in the user's language.

## Subtleties

- A program's catalogue never changes the toolkit's own words: each catalogue answers for the texts of its own files.
- A label a user must read is never cut: widgets grow or wrap; only data rows elide.
- In a row that is too narrow, an empty `fill()` spacer gives its width before anything a user sees shrinks: it only
  pushes what follows it, and it often asks for the whole row. A grid of equal columns makes each cell an exact
  fraction of the row with the gaps inside it, so a last row that is not full has the full rows' column width.
- Defaults are the best value for every program; a program overrides only its identity (its theme).
- A behaviour goes in the lowest widget that carries its concept: the wheel belongs to `ui.slider`, not to the slider
  with a field that wraps it. A wrapper composes; it adds no capacity its part lacks. Before giving a widget a
  behaviour, find its siblings of the same concept and give it to them too, or write why not.
- The corner of a window's resize grip stays square (0.213.0): a choice of look, not a defect. The patch that rounded it
  was refused.

## File Index

- [features/commands.md](features/commands.md): a command's key that types text: why `command_pressed` leaves it to a focused text field, why each program's test lists its typing keys, why they are not refused everywhere; window commands (`scope = .Window`): why their keys work whatever has the focus and whatever the page, and the widgets that claim the chords (`keys_claim`)
- [features/crash-sessions.md](features/crash-sessions.md): how a start learns that the last run ended badly: one session file per process (two instances never erase each other's trace), why "seen" is the start of the session that ended cleanly and not its end
- [features/drag-autoscroll.md](features/drag-autoscroll.md): a selecting drag held near or past the edge of a scroll view scrolls it: one mark per build, the innermost view that can still scroll, the speed curve shared with the middle click
- [features/folders.md](features/folders.md): a program's folders, the person's and the session's: how `user-dirs.dirs` is read and when (once, cached, a blocking call), why a disabled folder is none, why a folder's icon key is its path, why the runtime folder is never one another user can take first (the order on Linux, `fsx.private_dir`, the fallbacks refused), Windows' temporary folder
- [features/font-picker.md](features/font-picker.md): the font picker (`ui.font_picker`): why a default is a named family, why the families are read once on a chore, why each name is drawn in its face only when its row is in view, why the mono setting lists the others too; who applies the families (the toolkit, live, on a chore: `ui.use_text_family`)
- [features/file-browser.md](features/file-browser.md): the file browser of `ui.file_dialog`: why it reads through sources, how stale answers are dropped, what a quiet build does not do
- [features/json.md](features/json.md): one JSON helper (`gt:json`): why it reads what `core:encoding/json` parses and adds no parser, path reads with defaults that never panic, one quoter (its escapes, U+FFFD for a byte that is no UTF-8), a streaming writer that places the commas
- [features/image-decode.md](features/image-decode.md): one decoder of picture files for every program (`image.decode`): why GIF is the toolkit's own, why only a GIF's first frame and no frames API, damage refused and a short stream kept, the size limit before any allocation
- [features/palette.md](features/palette.md): one command palette for every program: sources with a closed table of prefixes, one ranking on the chores, serials that drop stale answers, choices by source and id, what each program's palette becomes
- [features/paste.md](features/paste.md): a paste gives text, files or an image as one answer: the order of preference (files, text, image), why the kinds are asked one after the other, the image decoded on a chore, one API for every kind, the platforms' formats
- [features/path-bar.md](features/path-bar.md): the path bar (`ui.path_bar`): why it reads nothing itself, why `wants` is said once, why its dropdown is a popover
- [features/plugins.md](features/plugins.md): plugins in JavaScript over the whole toolkit: the notes taken before the design (the engine Wren already embeds, what to design first)
- [features/selection.md](features/selection.md): the selection of a list's rows (`ui.Item_Selection`): one model for every list, the file manager's rules for Ctrl, Shift and the keys, why the set is always explicit and the range replaces the range
- [features/text-reveal.md](features/text-reveal.md): a cut text's ellipsis opens the whole text in a bubble that stays, to read, select and copy; why the ellipsis is a target of its own, why a dialog's title wraps and is not cut
- [features/text-selection.md](features/text-selection.md): text a person reads is selectable in every program: which text is content and which is a control's label, the widgets selectable by default, why a click on text in a clickable box acts and a drag selects
- [features/scroll-bar.md](features/scroll-bar.md): the scroll bar of every view: the desktop's standard it takes (numbers, states, gradients), the theme's colours that reproduce it, why it hides only on request, why thin is 9 px, the room every scroll box keeps for it (no content under a bar, no oscillation; only while it overflows unless `.Scrollbar_Reserve`); which boxes have a bar (content that is read, never a strip)
- [features/strip.md](features/strip.md): the strip (`ui.strip`): a row, a column or a block of choices that scrolls with arrow buttons over its edges, never a bar; when a row wraps, folds into a menu or scrolls; the axes, the wheel on each, why an arrow is an opaque button with the fade beyond it and brings the next choice fully in view; one look for every row of tabs (the chosen tab a raised plate)
- [features/toolbar.md](features/toolbar.md): the tool bar: one bar that wraps or folds into an organised menu, why the menu shows rows and not the bar's controls
- [infrastructure/frame-formats.md](infrastructure/frame-formats.md): a frame in 8 bits or in half floats: why a translucent window's is in half floats, why every shader output is clamped to [0, 1], how the tests and the verify see both formats
- [features/views.md](features/views.md): views: every dialog and movable pane as one content in four presentations (dialog, floating window, window of the system, docked panel), the state machine, what is remembered, the chrome rules, the migration of the programs
