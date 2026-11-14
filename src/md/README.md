# gui_toolkit: intent

The toolkit is the base of several programs (papier, classeur, inspecteur, cliche, opencode native, Wren). Its first
purpose is that a need common to two programs has one API here, and none in the programs: no duplicate, no alias, no
compatibility layer. The programs are the only users, so an API changes freely when the usage changes; each program
is migrated in the same piece of work.

## Overview

- Immediate mode: a program builds its whole interface at each frame. A box is found again by its id; what must live
  longer than a frame is in the program's state or in the toolkit's `ui.State`, one per window.
- Every window has its own `ui.State`; the renderer and the fonts are shared between the windows of a program.
- Platform code is behind clear interfaces, in files with a system suffix; every package checks for Windows, Linux and
  darwin, so that a system can be added or removed without touching the rest.
- What a program shows the same way in every program is a standard part of the toolkit, not a program's code: the
  settings page and its standard settings, the install page, the licence page, the crash bar, the diagnostics, the
  updates, the palette and its memory, the texts in the user's language.

## Subtleties

- The interface thread never waits: no disk, network, process or system call there, not even once at a frame. Work
  runs on tasks (`ui.chores`, `gt:tasks`) and posts its result back.
- A frame does no work in proportion to the data: lists, filters, sorts and translated tables are made when their data
  changes and kept.
- A program's catalogue never changes the toolkit's own words: each catalogue answers for the texts of its own files.
- A label a user must read is never cut: widgets grow or wrap; only data rows elide.
- Defaults are the best value for every program; a program overrides only its identity (its theme).

## File Index

- [features/views.md](features/views.md): views — every dialog and movable pane as one content in four
  presentations (dialog, internal window, external window, docked panel), the state machine, what is remembered, the
  chrome rules, the plan of the work and the migration of the programs.
