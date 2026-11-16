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

- [features/commands.md](features/commands.md): a command's key that types text: why `command_pressed` leaves it to a focused text field, why each program's test lists its typing keys, why they are not refused everywhere; window commands (`scope = .Window`): why their keys work whatever has the focus and whatever the page, and the widgets that claim the chords (`keys_claim`); the sheet's lines that are no command (a widget's keys): in their group, their keys named in the person's language as a command's (a word that names no key as written), not in the palette; a new table handed to the sheet without reopening it (`shortcuts_sheet_set`)
- [features/crash-sessions.md](features/crash-sessions.md): how a start learns that the last run ended badly: one session file per process (two instances never erase each other's trace), why "seen" is the start of the session that ended cleanly and not its end
- [features/default-file-manager.md](features/default-file-manager.md): a program in place of the system's file manager (`Part.File_Manager`): why it is a part read from the system and not a preference, the keys of Win+E and of folders and drives (why not `Folder` nor the system's `open`), the line of `mimeapps.list` that gives the former default back
- [features/drag-autoscroll.md](features/drag-autoscroll.md): a selecting drag held near or past the edge of a scroll view scrolls it: one mark per build, the innermost view that can still scroll, the speed curve shared with the middle click
- [features/folders.md](features/folders.md): a program's folders, the person's and the session's: how `user-dirs.dirs` is read and when (once, cached, a blocking call), why a disabled folder is none, why a folder's icon key is its path, why the runtime folder is never one another user can take first (the order on Linux, `fsx.private_dir`, the fallbacks refused), Windows' temporary folder
- [features/font-picker.md](features/font-picker.md): the font picker (`ui.font_picker`): why a default is a named family, why the families are read once on a chore, why each name is drawn in its face only when its row is in view, why the mono setting lists the others too; who applies the families (the toolkit, live, on a chore: `ui.use_text_family`)
- [features/file-browser.md](features/file-browser.md): the file browser of `ui.file_dialog`: why it reads through sources, how stale answers are dropped, what a quiet build does not do
- [features/interaction-states.md](features/interaction-states.md): hover, press, toggled and chosen are each drawn by the widget in its own design and on its own geometry, never a translucent layer over it: the face's steps toward the theme's tint, a face that appears (ghost buttons, rows), the custom draws (check box, switch, fields), a press shown at once
- [features/json.md](features/json.md): one JSON helper (`gt:json`): why it reads what `core:encoding/json` parses and adds no parser, path reads with defaults that never panic, one quoter (its escapes, U+FFFD for a byte that is no UTF-8), a streaming writer that places the commas
- [features/image-decode.md](features/image-decode.md): one decoder of picture files for every program (`image.decode`): why GIF is the toolkit's own, why only a GIF's first frame and no frames API, damage refused and a short stream kept, the size limit before any allocation
- [features/picture-cache.md](features/picture-cache.md): one cache of picture textures under a byte budget (`gt:pictures`): size classes and why, the last asked decoded first, what is no longer shown dropped from the queue, the upload on the interface's thread, what the budget never evicts, a serial per ask; refused: a decode in the frame, one texture per place, a cache per program
- [features/everything-palette.md](features/everything-palette.md): each item's control in the palette, from the
  value's nature (value kinds and units) in one table the settings page shares; the run mode, live change and Escape;
  go to by an act name; commands with arguments. Layer 1 as built: the thirteen value kinds and what each checks and
  shows, why `Factor` and `Rate` joined, the units' table and which convert, why a family and a theme are not checked,
  why the control table is `prefs_page`'s and a `Size` never a slider. Layers 2 to 4 as built: the run mode's state
  machine, why the palette's field keeps the keyboard and every write waits for `palette_chosen`, why every closed list
  is a sub-list in the palette, undo and the other path that wins; act names as hashes per frame, `reach`, Shift+Enter
  one meaning; a form's registry of its own
- [features/palette.md](features/palette.md): one command palette for every program: sources with a closed table of prefixes, one ranking on the chores, serials that drop stale answers, choices by source and id, what each program's palette becomes
- [features/paste.md](features/paste.md): a paste gives text, files or an image as one answer: the order of preference (files, text, image), why the kinds are asked one after the other, the image decoded on a chore, one API for every kind, the platforms' formats
- [features/path-bar.md](features/path-bar.md): the path bar (`ui.path_bar`): why it reads nothing itself, why `wants` is said once, why its dropdown is a popover
- [features/plugins.md](features/plugins.md): plugins in JavaScript over the whole toolkit: the notes taken before the design (the engine Wren already embeds, what to design first)
- [features/quit.md](features/quit.md): a running program closed before its install: `--status`'s `quit: yes`, `--quit` through the single instance (`instance.MESSAGE_QUIT`), then the processes of the installed file ended (`process.processes_of`); why the installed copy is asked and not the new file, why by full path and never by name
- [features/secrets.md](features/secrets.md): a secret sealed for the user's account (`gt:secrets`): DPAPI on Windows, the Secret Service on Linux; why a field with a mark and a version, why the Linux field names its item, why a locked keyring is no store, why the program decides what to do without a store; refused: a key of our own, libsecret, a cache of the service's state in the toolkit
- [features/selection.md](features/selection.md): the selection of a list's rows (`ui.Item_Selection`): one model for every list, the file manager's rules for Ctrl, Shift and the keys, why the set is always explicit and the range replaces the range
- [features/setup-screen.md](features/setup-screen.md): the setup's view: the program's hero first, the options as switches, the details folded with Uninstall on their line, the vendor in the footer, a screen of its own for a copy from the Nix store
- [features/exploded-view.md](features/exploded-view.md): the window's boxes as planes in depth, one per depth of the tree, each box drawn without its children, turned with the mouse; its modes and the Layers rule; the way in from the flat page and back; the panel, a view (floating, docked or in a window), drawn flat over the planes, and how the pointer goes to it; why a plane per depth and not per box
- [features/spacing.md](features/spacing.md): one spacing scale in em, its roles (a card's inset, the gap between groups), the card with one inset on its four sides and no gap after it, its own look in every finish (`Card_Options`, `Plate_Look` on the `.Plate` box; why its edge is a `Maybe`), its box from inside its scope (`card_box`), the list card and its hairlines, the well's inset and edge
- [features/keymap.md](features/keymap.md): a person's own keys and aliases for any command, in every program: why `Command.id` and not the label or the enum's name, the keymap one per program and the pending chord one per window, a person's key over a command's own key, why an unknown id is kept and inert, the two standard settings stored in English, Ctrl+Enter and Alt+Enter the toolkit's in every palette
- [features/lazy-anchor.md](features/lazy-anchor.md): a lazy column's view follows its anchor by a move rounded to 1/64 px, the remainder kept for the next one: why a stop at the top stays at 0, why no threshold
- [features/link-words.md](features/link-words.md): a program's own words made links (a session's id): prefixes set once, one test of a link for plain text and Markdown, the word its own target
- [features/term-rows.md](features/term-rows.md): a terminal's rows as retained pictures: why keyed by the row's content and not its place (a scroll records one row), the row's sum and its look, recorded inside a pixel and replayed by whole pixels, what no row showed released, stale once then direct; refused: one picture of the grid, slots, pictures for the scrollback
- [features/text-reveal.md](features/text-reveal.md): a cut text's ellipsis opens the whole text in a bubble that stays, to read, select and copy; why the ellipsis is a target of its own, why a dialog's title wraps and is not cut
- [features/text-selection.md](features/text-selection.md): text a person reads is selectable in every program: which text is content and which is a control's label, the widgets selectable by default, why a click on text in a clickable box acts and a drag selects
- [features/scroll-bar.md](features/scroll-bar.md): the scroll bar of every view: the desktop's standard it takes (numbers, states, gradients), the theme's colours that reproduce it, why it hides only on request, why thin is 9 px, the room every scroll box keeps for it (no content under a bar, no oscillation; only while it overflows unless `.Scrollbar_Reserve`); which boxes have a bar (content that is read, never a strip)
- [features/stepper.md](features/stepper.md): the stepper (`ui.stepper`): why the program owns the states and the stepper the motion, clocks keyed by the node and its state, a node seen first is settled, equal columns, one progress node for a screen reader
- [features/streams.md](features/streams.md): a server's event stream and WebSockets in `gt:http`: the system's client does the connection, on Linux our upgrade and frames over curl's raw connection (distributions build libcurl without WebSockets), one frame codec in the toolkit, a callback for a stream and a handle for a socket, the pure SSE parser and its rules, silence as a stream's time limit, one reader and any senders on a socket, a wait that runs out keeps it (why WinHTTP's asynchronous mode); a connection's own bound and compressed answers, the system client's work; refused: libcurl's WebSocket API, a socket over core:net, a Rust crate, Wren's manager
- [features/strip.md](features/strip.md): the strip (`ui.strip`): a row, a column or a block of choices that scrolls with arrow buttons over its edges, never a bar; when a row wraps, folds into a menu or scrolls; the axes, the wheel on each, why an arrow is an opaque button with the fade beyond it and brings the next choice fully in view; one look for every row of tabs (the chosen tab a raised plate)
- [features/third-party-notices.md](features/third-party-notices.md): a program's THIRD-PARTY-NOTICES: what a program states (its own crates, its works), one file for Linux and Windows together and why, why `cargo metadata` is not offline, why a path crate is walked but not listed
- [features/toolbar.md](features/toolbar.md): the tool bar: one bar that wraps or folds into an organised menu, why the menu shows rows and not the bar's controls
- [features/zoom-zones.md](features/zoom-zones.md): zoom zones (`ui.zoom_zone`): an area with its own zoom that the program applies; one set of zoom keys routed by the keyboard focus, Ctrl+wheel by the pointer, the window's zoom when no zone holds them; the zoom remembered per key in a memory zones share (`Zoom_Memory` over `store.Kept`), a default the keys never zoomed follow, Reset that forgets; the terminal's grid a zone; why not two sets of keys nor keys routed by the pointer, a menu or a dialog over a zone
- [features/widget-table.md](features/widget-table.md): the widgets × their behaviours (wheel, keys, Tab, screen reader, menu, disabled, tooltip, Shift step, typed value, reset); its gaps and its decisions
- [infrastructure/frame-formats.md](infrastructure/frame-formats.md): a frame in 8 bits or in half floats: why a translucent window's is in half floats, why every shader output is clamped to [0, 1], how the tests and the verify see both formats
- [infrastructure/no-graphics.md](infrastructure/no-graphics.md): a machine with no graphics driver: which wgpu-native call aborted the process and why, why a surface is made only on an instance with an adapter, what the renderer and the host report, the WARP fallback of Direct3D 11, why no GL fallback yet
- [infrastructure/picture-owner.md](infrastructure/picture-owner.md): a picture knows the draw context that holds its GPU ranges (`Picture.owner`): replayed in another it uploads there, `draw.destroy` lets go of its pictures; why a heap generation is no identity, why release and destroy take no context
- [infrastructure/window-alpha.md](infrastructure/window-alpha.md): an opaque frame is presented with its alpha ignored (the clear decides), and how a window's swap chain or surface changes mode when its theme turns translucent
- [features/views.md](features/views.md): views: every dialog and movable pane as one content in four presentations (dialog, floating window, window of the system, docked panel), the state machine, what is remembered, the chrome rules, the migration of the programs
