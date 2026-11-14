# The file browser: intent

What the person sees and the API are in [docs/file-browser.md](../../../docs/file-browser.md). This file keeps the
reasons.

## Purpose

One picker for every program of the toolkit, the same in every theme. It must also read files that are not on this
computer: ocn chooses a folder on its server. The system's dialogs cannot do that, they freeze the window (Windows'
modal loop) or depend on the desktop (portal, zenity, kdialog). They stay one setting away (`general.file_dialog`).

## Decisions

- **One browser per State, built by `end_build`.** A program calls `ui.file_dialog` once and nothing per frame. One
  dialog at a time: a second call cancels the first, so `done` is called exactly once per call.
- **A source is calls with replies, never a return value.** The interface's thread must not wait. The local source
  runs on the chores; a program's source answers from its HTTP callbacks. A source may also answer inside the call.
- **A reply is a value: State, dialog serial, ticket, kind.** The serial drops every answer of a closed dialog; the
  `remote` ticket drops the answer of a folder left or of a file no longer selected. No object per request, no counter
  of references, nothing to free when an answer never comes.
- **The controls ask, the browser acts after the dialog is built** (`File_Action`). An act can close the dialog and
  free its rows; a navigation clears the entries. The rows built in a build stay valid until its end.
- **Another folder starts empty.** Old entries under a new path let a press act on the wrong folder. A reading of the
  same folder again (F5, a new folder made) keeps its entries until the answer.
- **A missing folder goes up** (`file_reply_failed(missing = true)`). A remembered folder that was deleted must not
  end on an error.
- **The path field reads the parent, then looks for the last part in its entries.** One mechanism finds a folder to
  enter or a file to choose, and asks the source nothing more than a listing (no stat call, which a remote source may
  not have).
- **No work in proportion to the entries in a quiet build.** The rows are made again only when the entries, Hidden
  files or the type change; filtered and sorted again only when the query or the sort change. The table passes a
  version of its ids to the list (`Table.ids_version`), and Open's "can act" is kept by (selection, marks, version).
- **The table grew, no second list.** Folders first is `Table_Data.groups`; the fuzzy filter is `Table_Layout.fuzzy`.
  Every table gets them.
- **The computer's places are read once per State, on the chores** (`File_Local`). `known_folder_path` and the drives
  are system calls. Refused: a process global (the rule: what is one app's lives in its State). `local_places` reads
  the thread's State for this reason.
- **The local time's offset is the toolkit's, not the browser's** (`timefmt.local_offset_minutes`). It is the
  machine's, one per process: a global of class `process`, read by one thread `ui.init` starts, again each minute (a
  zone or a daylight saving change during a run). The browser, the scroll marks and every program read the same value.
  Refused: an offset per State or per widget (each one read it, and they disagreed after a change), and
  `core:time/timezone` (it loads and parses the zone's file at each reading; libc and Win32 answer the same question).
- **Search in subfolders is a call of the source** (`File_Source.find`), not a walk of the browser over `list`. A
  server walks its own disk in one request; the browser asking a listing per folder would be thousands of requests.
  The answer is ranked by the source, best first, at most `limit`: the browser shows it as it is (no re-sort, no
  folders first) until the person clicks a column.
- **The find is asked on a change of the query, after `FILE_FIND_QUIET_MS` of no change**, measured by the State's
  clock. A request per key typed would start a walk per letter; a request per frame, a walk per frame.
- **The local walk stops early when it is no longer wanted.** One stop counter per browser, shared with the walks
  (counted references: a walk may end after `ui.destroy`). A newer find, another folder, the toggle off and the dialog
  closing bump it; the walk compares it with its own at each entry. The ticket still drops a late answer: the counter
  only saves the work.
- **The walk is bounded** (`FILE_FIND_VISIT_MAX` entries): a search from `/` must end. It does not enter links (a
  loop) nor hidden folders unless Hidden files is on (`File_Reply.hidden`: one API for every source, the call's
  signature the same).
- **A toolkit overlay takes the keyboard before the program sees it** (`overlay_capture_keys`, begin_build). An open
  menu and the open browser are both built after the program's own code (the menu where it is built, the browser in
  `end_build`): without this, the program's `key_press` saw Escape first (ocn: Escape interrupted a running job while
  the person closed the picker). The menu reads the queue itself; the browser gets it back as the frame's keys when it
  is built (`overlay_release_keys`), so its fields and its list read keys as everywhere. The modal's own rule
  (`keys_held_by_dialog`) is not enough: a program may set `keys_behind_dialogs`, and typed text, `key_pressed_peek`
  and a program's own reading of the events went around it.
- **`File_Place` is in `platform`.** `platform.File_Dialog` stays the one options struct, with `places`.
- **A picture's texture is made at the first draw.** The build has no renderer; the draw callback has it.
- **`dialog_test_hook` still answers for the computer's files.** The end-to-end tests of programs set it.
- **The memory is in memory for the run; a file only when the program gives one** (`file_dialog_memory`). The toolkit
  does not know where a program keeps its state.

## Refused

- The system's dialog by default: it freezes the window, differs per desktop, and reads only local files.
- A ui-level options struct beside `platform.File_Dialog`: two APIs for one need.
- A filter and a sort in the browser, outside `ui.Table`: a copy of the table's.

## Subtle points

- A row's identity is the hash of its name. Two names of one hash share a selection; nothing else breaks.
- The Windows hidden attribute is not read (`core:os` does not give it): only names that start with "." are hidden.
- A program's source must not answer after `ui.destroy`: the reply holds the State.
- Escape is taken by the browser before its fields and its list: the filter, then the path field, then the new folder's
  row, then the dialog.
- The browser takes the keyboard from the build after it opened: the build that opens it gave its keys to the program
  already.
- A result of a find is named by its path relative to the folder shown. Its row's identity is the hash of that path:
  `select_name`, the preview and the act join it to the folder as they join a name.
- The find's rows replace the folder's rows while the toggle is on and the query is not empty. The folder's entries stay
  as they are: clearing the query shows them again without a new listing.
