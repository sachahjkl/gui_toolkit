# The file browser: intent

What the person sees and the API are in [docs/file-browser.md](../../../docs/file-browser.md). This file keeps the
reasons.

## Purpose

One picker for every program of the toolkit, the same in every theme. It must also read files that are not on this
computer: ocn chooses a folder on its server. The system's dialogs cannot do that, they freeze the window (Windows'
modal loop) or depend on the desktop (portal, zenity, kdialog). They stay one setting away (`general.file_dialog`).

## Decisions

- **One browser per State, a view.** A program calls `ui.file_dialog` once and nothing per frame. One dialog at a time:
  a second call cancels the first, so `done` is called exactly once per call. The browser is the ready-made view
  `"file_dialog"` (views.md), one instance per owner window: the views build it (in the frame it opens), draw its header
  (its title and its icon), remember its size, and let the person float it, dock it or open it in a window of its own,
  as every dialog. Refused: its own pass in `end_build` with the private modal: a second kind of dialog beside the
  views, without their presentations, and `dialog_header`, `confirm` were gone with the views. Its answer is the
  toolkit's: the person's close (the close cross, a press outside) reaches it through the view kind's `on_end`, and is
  its Cancel; its own close is the program's close of the view (no answer). The dialog's size is also kept per
  `remember_id` (its memory), given to the view when it opens.
- **The question of a Save over a file is a confirmation over the view** (`confirm_open`, `confirm_answer`, instance:
  the browser's). It opens once (`asked`); its answer is read at each build of the browser.
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
- **The path bar is the toolkit's `path_bar`, its dropdown's reading the browser's own** (`bar_listing`,
  `File_Reply.bar`). The list must not change while a person types a path elsewhere; the folder shown is answered from
  its entries. A flag on the reply, not a new `File_Reply_Kind`: a source dispatches on the kind (the local one does),
  and a listing is a listing. A go of the bar's that is a folder (`branch`) is entered at once; a text typed or a file
  goes through the path field's lookup above. Refused: a search in subfolders in the dropdown: a second find machine
  beside the filter's, for what the filter's toggle does already.
- **No work in proportion to the entries in a quiet build.** The rows are made again only when the entries, Hidden
  files or the type change; filtered and sorted again only when the query or the sort change. The table passes a
  version of its ids to the list (`Table.ids_version`), and Open's "can act" is kept by (active row, selection's version, ids' version).
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
  menu and the browser open as a dialog are both built after the program's own code (the menu where it is built, the
  browser's view in `end_build`): without this, the program's `key_press` saw Escape first (ocn: Escape interrupted a
  running job while the person closed the picker). The menu reads the queue itself; the browser gets it back as the
  frame's keys when its view is built (`overlay_release_keys`), so its fields and its list read keys as everywhere.
  Only as a dialog of the window (`file_browser_holds_keys`): floated, docked or in a window of its own, it takes keys
  as the views do (the focus in it). The modal's own rule
  (`keys_held_by_dialog`) is not enough: a program may set `keys_behind_dialogs`, and typed text, `key_pressed_peek`
  and a program's own reading of the events went around it.
- **A local entry is hidden as the system says, by one rule for the listing and the search.** `fsx.read_folder` gives
  the system's mark with each entry; `file_entry_hidden` (that mark, or a name that starts with ".") decides in the
  folder and in the walk. On Windows the mark is `FILE_ATTRIBUTE_HIDDEN` alone: Explorer's Hidden items shows those, and
  a file with `SYSTEM` but not `HIDDEN` is shown by Explorer too. `HIDDEN` and `SYSTEM` together are Explorer's
  "protected operating system files", a second toggle; one Hidden files toggle shows them with the others (they carry
  `HIDDEN`). The attribute comes from `FindFirstFileW` / `FindNextFileW`'s records: `core:os`'s `File_Info` drops it
  (and opens each entry to stat it), and a `GetFileAttributesW` per entry would be one more call per entry of a walk of
  200 000. Refused: a `when ODIN_OS` in `file_local.odin` (the system's code is in `fsx_<os>.odin`), and a second read
  of each folder for the attributes alone (two readings that can disagree).
- **`File_Place` is in `platform`.** `platform.File_Dialog` stays the one options struct, with `places`, and with
  `row_actions`: a program's acts in a row's context menu (downloads.md says why data of the options and why the
  dialog stays open).
- **`start_known` is the source's to answer** (`File_Source.known`), after `start_dir` and the dialog's memory: only
  the computer's source has a Downloads folder, and it reads it with its places, on the chores (downloads.md).
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
- On Windows a name that starts with "." is hidden too, though the system does not mark it: a program's dot folders
  (`.git`, `.config`) are the clutter Hidden files is for, and every source keeps the same rule.
- A hidden link is skipped before it is followed: the walk stats no link it does not show.
- A program's source must not answer after `ui.destroy`: the reply holds the State.
- Escape is taken by the browser before its fields and its list: the filter, then the new folder's row, then the
  dialog. While the path bar is typed in, Escape is the bar's (its dropdown, then the breadcrumb).
- The browser takes the keyboard from the build after it opened: the build that opens it gave its keys to the program
  already.
- Its body reads the State it is built in (`gs()`), not `fb.state`: in a window of its own, that is the window's.
  Replies and the clock stay the owner's (`fb.state`).
- `ui.destroy` closes the browser before the views end: its view goes as the program's close, `done` is not called.
- A result of a find is named by its path relative to the folder shown. Its row's identity is the hash of that path:
  `select_name`, the preview and the act join it to the folder as they join a name.
- The find's rows replace the folder's rows while the toggle is on and the query is not empty. The folder's entries stay
  as they are: clearing the query shows them again without a new listing.
