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
- **The computer's places and the time zone offset are read once per State, on the chores** (`File_Local`).
  `known_folder_path` and the drives are system calls; the offset reads the zone file on Linux. Refused: a process
  global (the rule: what is one app's lives in its State). `local_places` reads the thread's State for this reason.
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
