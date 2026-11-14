# The file browser (`src/ui/file_browser*.odin`, `src/ui/file_source.odin`, `src/ui/file_local.odin`)

One file picker for every program, drawn by the toolkit with its own widgets: open one or more files, choose a folder,
save under a name. It reads its folders through a *source*: the computer's own files (the toolkit's local source), or
any other file system a program reaches (a server's, an archive's). It looks and behaves the same for all of them, and
in every theme.

`ui.file_dialog` shows it. The toolkit builds it at the end of each build while it is open (`end_build`): a program calls
nothing per frame. The system's dialog stays available: a person who prefers it sets `general.file_dialog` to `system`
(a preference of the toolkit, on the settings' General page of every program; `prefs_page.standard_apply` calls
`ui.set_file_dialogs(s, .System)`). A program's own source always gets the browser: the system's dialog cannot read it.

```odin
// The computer's files, as before: the same call, the toolkit's browser.
ui.file_dialog(&app.ui, .Open, {owner = win, title = "Open an image", filters = {{"Images", {"*.png", "*.jpg"}}}, multiple = true, remember_id = "images"}, done, app)

// A server's files: the program's source, and places of its own.
places := []platform.File_Place{{name = "Last session", path = "/home/me/work"}}
ui.file_dialog(&app.ui, .Folder, {title = "Start a session in", remember_id = "new_session", places = places}, done, app, source = &app.server_files)
```

`done(result, user)` comes on the interface's thread, once: `Chosen` with the paths, or `Cancelled` (the Cancel button,
Escape, the close button, a press outside the dialog). The paths are the source's (absolute, with its separators as it
gave them). A dialog asked while another one shows cancels that one. With `platform.dialog_test_hook` set (a program's
end-to-end test) the hook answers for the computer's files, as it did for the system's dialogs.

## What it shows

```
┌ Title ───────────────────────────────────────────────────────────── × ┐
│ ← → ↑   home › sacha › Projects › gui_toolkit            [⌕ filter  ] │
│ ┌────────────┐ ┌───────────────────────────────────────┐ ┌─────────┐ │
│ │ PLACES     │ │ Name ▲           Size      Modified    │ │ preview │ │
│ │ ⌂ Home     │ │ 📁 docs                    14:02       │ │         │ │
│ │ 🖥 Desktop  │ │ 📁 src                     yesterday   │ │         │ │
│ │ 📄 Documents│ │ 📄 README.md     4.2 KB    Nov 10      │ │         │ │
│ │ (program's)│ │ ...                                    │ │         │ │
│ │ RECENT     │ └───────────────────────────────────────┘ └─────────┘ │
│ └────────────┘  [Name: report.txt     ] [Type: Images ▾]              │
│  [+ New folder]  [◌ Hidden files]                 [Cancel] [Open]     │
└───────────────────────────────────────────────────────────────────────┘
```

- **The path bar**: Back, Forward, Up; the folder as a breadcrumb, a button per part (a click goes there; parts that do
  not fit, by the last layout's width, go into a `…` menu at the left). `Ctrl+L`, or a click on the bar's empty end,
  turns it into a field with the whole path: Enter goes there (its folder is read, then its last part is looked for in
  it: a folder is entered, a file chosen in Open mode and named in Save mode), Escape gives the breadcrumb back, and so
  does the keyboard leaving the field. Tab completes the folder's names (as far as the names that begin with what is
  typed agree); a field whose folder is not the one shown reads that folder first.
- **Places**, at the left: what the source gives (local: Home, Desktop, Documents, Downloads, Pictures, Music, Videos
  that exist, then the drives on Windows, `/` elsewhere: read once per State on the chores, `file_local.odin`), then the
  program's own places (`File_Dialog.places`: for ocn, the folders of the latest sessions), then the recent folders of
  this `remember_id`. The deepest place that holds the folder shown is marked.
- **The list**: a sortable table (`ui.Table`): Name, Size, Modified, Kind; folders first in every order
  (`table_data_row`'s `group`). Columns the source does not know (`caps`) are not shown. Thousands of entries scroll
  without cost (`vlist`). A row: the icon of its kind (folder, file, image, code, archive, text, link), its name, its
  size in units (`timefmt.size`: `4.2 KB`), its date as `timefmt.moment` tells it (its time today, "yesterday", its
  date). Hidden entries (a name that starts with `.`, or the source's flag) are shown faded when `Hidden files` is on,
  else left out. Files that the type chosen does not take are left out (Open), or shown faded (Save, Folder: they tell
  what is there).
- **The filter**: typing anywhere but in a field filters the list (`type_to_field`), fuzzy (`Table_Layout.fuzzy`: the
  letters in order), the matched letters marked; the arrows and Enter stay the list's while the keyboard is in it.
- **In subfolders**: a toggle beside the filter, shown when the source can search (`File_Source.find`), on at first
  with `File_Dialog.find_deep`. With it on and a query typed, the rows are what the source found under the folder, at
  any depth: their path relative to the folder in the Name column, the matched letters lit, folders and files as found,
  best first (a click on a column sorts them). The search is asked when the query changed and then stayed the same
  `FILE_FIND_QUIET_MS`; at most `FILE_FIND_LIMIT` entries; the answer of an older query is dropped. "Searching…" shows
  after `FILE_BROWSER_SLOW_MS`, "Nothing found." when the answer is empty. A folder found is entered (the query
  cleared); a file found is chosen, previewed and named as one of the folder (`file_path_join(folder, relative)`).
  With the toggle off, the filter is the folder's only.
- **The preview**, at the right (a split the person resizes, `splitter`; hidden when the dialog is narrower than
  `FILE_PREVIEW_SHOWN_EM` beside the places, and when the source cannot read): the selected file's text, coloured by its
  kind (`syntax`), its first `FILE_PREVIEW_BYTES` and `FILE_PREVIEW_LINES` lines; a picture (PNG, JPEG, BMP, WebP:
  `gt:image`, at most `FILE_PREVIEW_IMAGE_BYTES`) fitted and zoomable (`ui.preview`); otherwise its icon, its name, its
  size and its date. Read through the source and made ready on the chores, the latest selection only (a ticket: an older
  reading answers nothing). A picture's texture is made at the first draw that shows it, and freed when another file is
  selected or the dialog closes.
- **The bottom**: in Save mode the name field (the suggested name selected without its extension) and the type list;
  in Open mode the type list when there is more than one line; New folder (when the source can make one: an inline row
  at the top of the list, its name typed in it, Enter makes it, the folder is read again with the new one selected; the
  source's words under it when it fails); Hidden files; Cancel and the act (`Open`, `Choose`, `Save`; the program's own
  word with `File_Dialog.act`: "Start here"). The act is
  disabled while nothing can be chosen (Open with no file selected; Folder mode chooses the selected folder, or the
  folder shown when none is).
- **States**: reading (a line that says so, after `FILE_BROWSER_SLOW_MS` only: a fast folder does not flash), empty
  folder, refused or failed (the source's words, and Try again), a folder that no longer exists (the source says
  `missing`: it goes up to the nearest one that does).

## The keyboard

| Key | |
|---|---|
| ↑ ↓, Page Up/Down, Home, End | the selection (in the list, and while the keyboard is in the filter) |
| Enter | a folder: enter it; a file: choose it (Open), name it (Save) |
| Backspace (out of a field), Alt+↑ | up, the folder left selected |
| Alt+← / Alt+→ | back / forward |
| Ctrl+L | the path as a field |
| Ctrl+H | hidden files |
| Ctrl + click, Shift+↑↓, Ctrl+A | several files (Open with `multiple`) |
| a letter | the filter |
| Escape | clears the filter, then the path field, then the new folder's row, then cancels |
| F5 | reads the folder again |
| Shift+Ctrl+N | New folder |

While the browser is open it holds the keyboard, as an open menu does: from the build after it opened until it
closes, the program's `key_press`, `key_take`, `key_pressed_peek` and typed text get nothing (whatever
`set_keys_behind_dialogs` says), and the browser gets every key. `ui.file_dialog_shown(s)` says whether it is open.

A double click enters a folder or chooses a file (in Save mode: names it and saves). Every control has its role and its
name for a screen reader (the places are links, the one marked the current location; the list is a list box with its
rows' count).

## Save mode

The name typed is joined to the folder shown. With no extension typed, the type's is added (its first `*.ext` pattern),
else `default_ext`. With `overwrite_prompt` and a file of that name in the folder, a `ui.confirm` asks before it answers.
A name with a separator in it goes to that path (`../x.txt`, `/tmp/x.txt`: its `.` and `..` walked). The name of a folder
of the one shown enters it.

## Sources

```odin
File_Source :: struct {
	user:        rawptr,
	caps:        File_Caps,                 // what it knows and does: .Size, .Modified, .Read, .Make_Folder
	separator:   u8,                        // '/' or '\\': how its paths are joined
	list:        proc(src: ^File_Source, path: string, reply: File_Reply),           // the entries of a folder
	read:        proc(src: ^File_Source, path: string, max: int, reply: File_Reply), // the start of a file (preview)
	make_folder: proc(src: ^File_Source, path: string, reply: File_Reply),
	find:        proc(src: ^File_Source, folder, query: string, limit: int, reply: File_Reply),  // search in subfolders
	places:      proc(src: ^File_Source, allocator: mem.Allocator) -> []platform.File_Place,  // cheap: what it knows already
	start:       proc(src: ^File_Source, allocator: mem.Allocator) -> string,        // where a dialog starts with no folder known ("": the source's first place)
}
```

A call starts the work and returns at once: it never blocks the interface's thread. The source answers later (or in
the call), on the interface's thread, through the reply: `file_reply_listed(reply, entries)`,
`file_reply_read(reply, bytes, size)`, `file_reply_made(reply)`, `file_reply_found(reply, entries)`, or
`file_reply_failed(reply, message, refused = false, missing = false)`.

`find` (nil: no search in subfolders) answers `file_reply_found` with the entries under `folder`, at any depth, that
match `query`, best first, at most `limit`: each entry's `name` is its path relative to `folder`, with the source's
separator (`docs/notes.md`). `reply.hidden` is Hidden files: off, the hidden entries and what is in hidden folders are
not found. The browser shows them in the order given. A reply carries the ticket of its reading
(`remote`) and its dialog: the answer of a folder left, of a file no longer selected, or of a dialog closed changes
nothing. The entries and bytes are copied by the browser: the source frees its own after the call. A source answers
while the State lives (a program's source stops answering at `ui.destroy`).

`File_Entry`: `name`, `kind` (`.File`, `.Folder`), `link` (a link, to what `kind` says), `size` (-1: unknown),
`modified` (Unix milliseconds, 0: unknown), `hidden` (the source's flag; a name starting with `.` is hidden whatever it
says). `platform.File_Place`: `name` ("": the path's last part), `path`, `icon` (a Lucide glyph, "": a folder).

`ui.local_files()` is the computer's: `core:os` on the chores (`ui.task`), the system's places
(`platform.known_folder_path`, `platform.file_roots`) read once per State on the chores, all `caps`. Its `find` walks the
folder on the chores, breadth first: it scores each path relative to the folder with `fuzzy_score` and keeps the best
`limit`; it does not enter links, nor hidden folders unless `reply.hidden`; it looks at `FILE_FIND_VISIT_MAX` entries at
most; a newer find, another folder, the toggle off or the dialog closing stops it early. The dates of every source are
told on `timefmt.local_offset_minutes()`, the toolkit's one reading of the local time's offset. A program's own source answers from where its data comes (ocn: its requests to the server, whose answers already
come on the interface's thread).

The paths of any separator are read by `file_path_root`, `file_path_parent`, `file_path_name`, `file_path_join`,
`file_path_clean`, `file_path_parts`, `file_path_within`; `file_entry_hidden`, `file_entry_look` and `file_look_icon`
say what an entry is.

## State kept

Per `remember_id`, for the run: the last folder, the dialog's size, the split's width, the sort, Hidden files, the recent
folders (`FILE_BROWSER_RECENT`). A program that keeps them between runs gives their file once, at its start:

```odin
ui.file_dialog_memory(&app.ui, path)   // read on the chores; written by a store.Writer each time a dialog closes
```

The interface's thread never touches the file. What a dialog remembered before the file came wins over the file's.

## For tests

`ui.file_browser_counts(s)`: whether a dialog is open, its folder, its entries and rows shown, and how many times its rows
were made (new entries, Hidden files, the type), filtered or sorted, and placed by the list: a build that changed none of
them does no work in proportion to the entries. Also whether In subfolders is on (`deep`), the entries of the last find
(`found`) and whether the rows are the find's (`found_shown`).

## Tests

`tests/file_browser`: a fake source that answers when the test says (in order, late, never, refused, missing, at once);
a real local folder made in the test's temp directory for the local source, waited for with a bounded condition. What
breaks first: a slow folder answering after the next one was asked; a folder with 100 000 entries (nothing proportional
to the entries runs in a frame that did not change them; `-define:FILE_BROWSER_TIMING=true` times a build against
`FILE_BROWSER_BUILD_BUDGET_MS`); a name with every kind of character; Save over an existing file; the dialog closed with
a reading under way; the keyboard (Enter, Backspace, typing, Escape's order, Shift+↓, Ctrl+A); Folder mode; the
program's places; New folder; the search in subfolders (a file three folders deep, a hidden folder, a late answer of an
older query, no request per frame); the program's `key_press` and typed text while the browser is open.
