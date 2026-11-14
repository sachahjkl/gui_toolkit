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

## File Index

- [features/file-browser.md](features/file-browser.md): the file browser of `ui.file_dialog`: why it reads through sources, how stale answers are dropped, what a quiet build does not do
- [features/path-bar.md](features/path-bar.md): the path bar (`ui.path_bar`): why it reads nothing itself, why `wants` is said once, why its dropdown is a popover
- [features/plugins.md](features/plugins.md): plugins in JavaScript over the whole toolkit: the notes taken before the design (the engine Wren already embeds, what to design first)
- [features/toolbar.md](features/toolbar.md): the tool bar: one bar that wraps or folds into an organised menu, why the menu shows rows and not the bar's controls
- [features/views.md](features/views.md): views: every dialog and movable pane as one content in four presentations (dialog, floating window, window of the system, docked panel), the state machine, what is remembered, the chrome rules, the migration of the programs
