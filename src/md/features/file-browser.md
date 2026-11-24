# The file picker's behaviour: intent

What the person sees and the API are in [docs/file-browser.md](../../../docs/file-browser.md). This file keeps the
reasons of the picker's behaviour; its layers (a program's picker, the dialog, the request as a value, gt-file-picker)
are in [file-picker.md](file-picker.md).

## Purpose

One picker for every program of the toolkit, the same in every theme. It must also read files that are not on this
computer: ocn chooses a folder on its server. The system's dialogs cannot do that, they freeze the window (Windows'
modal loop) or depend on the desktop (portal, zenity, kdialog). They stay one setting away (`general.file_dialog`).

## Decisions

- **A picker the program owns; the dialog is one of them, in a view** ([file-picker.md](file-picker.md) gives the
  layers). A program builds a `ui.File_Picker` in its own layout, or calls `ui.file_dialog` once and nothing per
  frame. One dialog at a time per State: a second call cancels the first, so `done` is called exactly once per call.
  The dialog is the ready-made view `"file_dialog"` (views.md), one instance per owner window: the views build it (in
  the frame it opens), draw its header (its title and its icon), remember its size, and let the person float it, dock
  it or open it in a window of its own, as every dialog. Refused: its own pass in `end_build` with the private modal: a
  second kind of dialog beside the views, without their presentations, and `dialog_header`, `confirm` were gone with
  the views. Its answer is the toolkit's: the person's close (the close cross, a press outside) reaches it through the
  view kind's `on_end`, and is its Cancel; its own close is the program's close of the view (no answer). The dialog's
  size is also kept per `remember_id` (its memory), given to the view when it opens.
- **The question of a Save over a file is a confirmation over the view** (`confirm_open`, `confirm_answer`, instance:
  the picker's). It opens once (`asked`); its answer is read at each build of the picker.
- **A source is calls with replies, never a return value.** The interface's thread must not wait. The local source
  runs on the chores; a program's source answers from its HTTP callbacks. A source may also answer inside the call.
- **A reply is a value: State, picker id, serial, ticket, kind.** The id drops every answer of a destroyed picker (the
  State's `live` map no longer has it); the serial every answer of a request stopped or replaced; the `remote` ticket
  the answer of a folder left or of a file no longer selected. No object per request, no counter
  of references, nothing to free when an answer never comes.
- **The controls ask, the picker acts after the dialog is built** (`File_Action`). An act can close the dialog and
  free its rows; a navigation clears the entries. The rows built in a build stay valid until its end.
- **Another folder starts empty.** Old entries under a new path let a press act on the wrong folder. A reading of the
  same folder again (F5, a new folder made) keeps its entries until the answer.
- **A missing folder goes up** (`file_reply_failed(missing = true)`). A remembered folder that was deleted must not
  end on an error.
- **The path field reads the parent, then looks for the last part in its entries.** One mechanism finds a folder to
  enter or a file to choose, and asks the source nothing more than a listing (no stat call, which a remote source may
  not have).
- **The path bar is the toolkit's `path_bar`, its dropdown's reading the picker's own** (`bar_listing`,
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
- **The local time's offset is the toolkit's, not the picker's** (`timefmt.local_offset_minutes`). It is the
  machine's, one per process: a global of class `process`, read by one thread `ui.init` starts, again each minute (a
  zone or a daylight saving change during a run). The picker, the scroll marks and every program read the same value.
  Refused: an offset per State or per widget (each one read it, and they disagreed after a change), and
  `core:time/timezone` (it loads and parses the zone's file at each reading; libc and Win32 answer the same question).
- **Search in subfolders is a call of the source** (`File_Source.find`), not a walk of the picker over `list`. A
  server walks its own disk in one request; the picker asking a listing per folder would be thousands of requests.
  The answer is ranked by the source, best first, at most `limit`: the picker shows it as it is (no re-sort, no
  folders first) until the person clicks a column.
- **The find is asked on a change of the query, after `FILE_FIND_QUIET_MS` of no change**, measured by the State's
  clock. A request per key typed would start a walk per letter; a request per frame, a walk per frame.
- **The local walk stops early when it is no longer wanted.** One stop counter per picker, shared with the walks
  (counted references: a walk may end after `ui.destroy`). A newer find, another folder, the toggle off and the dialog
  closing bump it; the walk compares it with its own at each entry. The ticket still drops a late answer: the counter
  only saves the work.
- **The walk is bounded** (`FILE_FIND_VISIT_MAX` entries): a search from `/` must end. It does not enter links (a
  loop) nor hidden folders unless Hidden files is on (`File_Reply.hidden`: one API for every source, the call's
  signature the same).
- **A toolkit overlay takes the keyboard before the program sees it** (`overlay_capture_keys`, begin_build). An open
  menu and the picker open as a dialog are both built after the program's own code (the menu where it is built, the
  picker's view in `end_build`): without this, the program's `key_press` saw Escape first (ocn: Escape interrupted a
  running job while the person closed the picker). The menu reads the queue itself; the picker gets it back as the
  frame's keys when its view is built (`overlay_release_keys`), so its fields and its list read keys as everywhere.
  Only as a dialog of the window (`file_dialog_holds_keys`): floated, docked or in a window of its own, it takes keys
  as the views do (the focus in it). The modal's own rule
  (`keys_held_by_dialog`) is not enough: a program may set `keys_behind_dialogs`, and typed text, `key_pressed_peek`
  and a program's own reading of the events went around it.
- **A local link's target and a thumbnail's file are statted through `fsx.stat_follow`, never `core:os`'s `os.stat`.**
  On Windows, `core:os`'s `_file_info_from_get_file_information_by_handle` sets `File_Info.fullpath = name` without
  cloning the caller's string for every reparse point (a junction such as `My Documents` or `Application Data`, a
  symbolic link, a OneDrive cloud file); `os.file_info_delete` then freed the caller's path string, and the caller's own
  `delete` freed it a second time (`0xC0000374` heap corruption in `RtlFreeHeap` when opening a folder). `fsx.stat_follow`
  returns the target's `Path_Kind` and size with no heap allocation.
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
  dialog stays open), and `row_actions_off`.
- **A row's context menu always opens: the toolkit's acts, then the program's.** In this order, each one only when the
  source can do it: Copy path, Copy name, Copy relative path (any source: a server's path is worth copying too); Open and
  Show in folder (the computer's source only: the system's programs read only its files); Rename and Move to the trash
  (a source that has `File_Source.rename` / `.trash`; the computer's has them); a separator, then
  `File_Dialog.row_actions`. A program removes the toolkit's own with `File_Dialog.row_actions_off` (a
  `bit_set[File_Row_Builtin]`, empty by default: every program gets them without a line of code). What the source
  cannot do is absent with no setting: a menu that offers an act and fails it is worse than no item.
- **Each act takes what its meaning allows.** The copies take every entry chosen, one line each, in the entries' order
  (a list pasted in a terminal or a mail); a relative path is relative to the folder the dialog was opened in
  (`start`: its first folder), so that a find's results and a walk into subfolders give `docs/a.md`, and a path outside
  it stays whole. Open, Show in folder and Rename take one entry: three hundred windows from a Ctrl+A, or a rename of
  several in one field, is never what was meant. Move to the trash takes them all, in one call of the source.
- **Rename and trash are calls with replies, as a listing** (`File_Reply_Kind.Rename`, `.Trash`, `.Restore`). The
  interface's thread does no file operation; the computer's source runs them on the chores, a server's answers from its
  callbacks. Done, the folder is read again (its listing is the truth: a rename may have been refused, a trash partly
  done). Refused: the picker changing its entries itself before the answer (an entry shown that the disk does not have).
- **Rename edits the name in its row or its card** (`Table.editing`, `edit_id`, `edit`: a hook of the table, so every
  table can edit a name in place). The name is selected without its extension, as Save's suggested name. Enter asks
  the source; Escape, a press elsewhere or a change of folder gives it up. The same name, or an empty one, asks
  nothing. A name with a separator is refused before the source is asked, as New folder's. Refused: a dialog that asks
  the new name (the name is where the eyes are; classeur and every file manager edit it in place).
- **The trash's undo is a toast, and only for the dialog that trashed.** The answer says what went to the trash and
  how each comes back (`File_Trashed`: the path, and the source's token for it, the computer's: its path in the trash);
  a click on the toast asks `File_Source.restore` with them. A source without `restore` gets a toast without undo. Only
  the last trash can be undone, and only while its dialog is open: another dialog may have another source, whose
  `user` the program may have freed. A toast's `user` is the trash's serial, not a pointer: an old toast finds its
  serial is not the last one and does nothing.
- **The system's trash is `platform.move_to_trash` and `platform.put_back`**, beside `reveal_in_folder`: what every
  program that deletes a file wants. Linux: the freedesktop.org trash (the home trash, or `.Trash-<uid>` at the top of
  another volume, its `.trashinfo` written first with `O_EXCL`, the file renamed, never copied). Windows: the Recycle Bin
  through `IFileOperation`, which says the `$R` path it made, so `put_back` renames it back and removes its `$I`
  record. `put_back` never goes over a name that is taken again. Refused: a deletion for good, even confirmed (a picker
  is no place to lose a file), and `SHFileOperationW` (it does not say where the item went: no undo).
- **`start_known` is the source's to answer** (`File_Source.known`), after `start_dir` and the dialog's memory: only
  the computer's source has a Downloads folder, and it reads it with its places, on the chores (downloads.md).
- **The list has the table's views** ([view-modes.md](view-modes.md)): details, names, columns, cards. One button in the
  bar shows the view's icon and opens a menu of the seven steps; Ctrl+wheel over the list and the zoom keys in it step
  them (`Table.zoom_keys`: the window's zoom stays the window's elsewhere). Refused: four buttons for four views (the
  card sizes are steps too, and the bar has no room for seven), and classeur's slider (a control of its own for one
  setting a menu says). The step is part of the dialog's memory (by its stable name, `table_zoom_key`): a dialog for
  pictures opens on its cards again. A card's picture is the file's thumbnail when the source gives one, else the
  kind's icon at the card's share (`table_card_icon_size`); a folder has its icon. A card's weak line is the size. The rubber band works in a dialog of
  several files. The preview pane is the same in every view. The person can close it (its button, Alt+P, as
  Windows Explorer's preview pane); it stays closed for that `remember_id`, and a closed preview reads no file.
- **A thumbnail is a call of the source, kept in the picker's `Thumb_Cache`** ([thumbnails.md](thumbnails.md)). Its
  answer is the only one not dropped by the request's serial (only by the picker's id): a file's picture is good for the
  next request too.
- **A picture's texture is made at the first draw.** The build has no renderer; the draw callback has it.
- **`dialog_test_hook` still answers for the computer's files.** The end-to-end tests of programs set it.
- **The memory is in memory for the run; a file only when the program gives one** (`file_dialog_memory`). The toolkit
  does not know where a program keeps its state.

## Refused

- The system's dialog by default: it freezes the window, differs per desktop, and reads only local files.
- A ui-level options struct beside `platform.File_Dialog`: two APIs for one need.
- A filter and a sort in the picker, outside `ui.Table`: a copy of the table's.

## Subtle points

- A row's identity is the hash of its name. Two names of one hash share a selection; nothing else breaks.
- On Windows a name that starts with "." is hidden too, though the system does not mark it: a program's dot folders
  (`.git`, `.config`) are the clutter Hidden files is for, and every source keeps the same rule.
- A hidden link is skipped before it is followed: the walk stats no link it does not show.
- A program's source must not answer after `ui.destroy`: the reply holds the State.
- The mouse's side buttons are Back and Forward only with the pointer on the picker or on its path bar's dropdown
  (`path_bar_pointer_on`: a popover of the window, outside the picker's body). A press elsewhere in the window is the
  program's. A field with the keyboard does not stop them: a mouse button types nothing.
- Save: another type chosen changes the extension of the name typed (GTK's and Windows' rule), never a name without
  one: a person who typed "notes" without an extension gets the type's at Save, as before.
- Escape is taken by the picker before its fields and its list: a rectangle being drawn, then the filter, then the new
  folder's row, then the dialog. While the path bar is typed in, Escape is the bar's (its dropdown, then the breadcrumb).
- The picker takes the keyboard from the build after it opened: the build that opens it gave its keys to the program
  already.
- Its body reads the State it is built in (`gs()`), not `fb.state`: in a window of its own, that is the window's.
  Replies and the clock stay the owner's (`fb.state`).
- `ui.destroy` closes the picker before the views end: its view goes as the program's close, `done` is not called.
- A result of a find is named by its path relative to the folder shown. Its row's identity is the hash of that path:
  `select_name`, the preview and the act join it to the folder as they join a name.
- A rename's field takes the keyboard: F2, Delete, Backspace and the typed letters are its own, and Escape gives the
  rename up before it clears the filter. A rename is given up when the rows are made again: the row it edits may be
  gone.
- A rename on its way and a new name: the folder read again selects the new name (`select_name`), as a new folder's.
- The computer's rename refuses a name that is taken (`os.rename` replaces on POSIX); a change of case alone is let
  through (on Windows the "other" name is the same file).
- The find's rows replace the folder's rows while the toggle is on and the query is not empty. The folder's entries stay
  as they are: clearing the query shows them again without a new listing.
