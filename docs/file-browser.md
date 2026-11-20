# The file browser (`src/ui/file_browser*.odin`, `src/ui/file_source.odin`, `src/ui/file_local.odin`)

One file picker for every program, drawn by the toolkit with its own widgets: open one or more files, choose a folder,
save under a name. It reads its folders through a *source*: the computer's own files (the toolkit's local source), or
any other file system a program reaches (a server's, an archive's). It looks and behaves the same for all of them, and
in every theme.

`ui.file_dialog` shows it. It is a view, `"file_dialog"` ([views.md](views.md)), one per window: the toolkit builds it
while it is open, a program calls nothing per frame. As every dialog, the person may float it, dock it or open it in a
window of its own (its header's menu); the views remember that, and its size per `remember_id` too. The system's dialog stays available: a person who prefers it sets `general.file_dialog` to `system`
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
│ ← → ↑  [/home / sacha / Projects / gui_toolkit       ]  [⌕ filter  ] │
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

- **The path bar**: Back, Forward, Up; the folder in the toolkit's path bar ([path-bar.md](path-bar.md)): a breadcrumb
  whose parts a click enters (parts that do not fit go into a `…` menu at the left). `Ctrl+L`, or a click on the bar's
  empty end, turns it into a field with the whole path and a dropdown: the folders of the folder typed (and its files in
  Open and Save mode: Open's of the type chosen), by fuzzy matching on what follows the last separator; then the places
  and the recent folders, under "Places" and "Recent". The folder shown is answered from its entries; another one is
  read through the source (`list`, with `File_Reply.bar`: a reading of its own, the list keeps the folder shown). Enter,
  or a row, goes there: a folder is entered; a path typed or a file is looked for in its folder (a folder is entered, a
  file chosen in Open mode and named in Save mode). Tab takes the row highlighted, a folder with its separator. Escape
  closes the dropdown, then gives the breadcrumb back, and so does the keyboard leaving the field. The search in
  subfolders stays the filter's (the toggle below): the bar lists one folder at a time.
- **The view**: the button at the end of the bar shows the list's view and opens its menu: Details, Names, Columns,
  then cards of four sizes (`Table.zoom`, docs/data-views.md "A table's views"). A card shows the file's thumbnail
  when the source gives one (`File_Source.thumbnail`, "Thumbnails" below), else its kind's icon, its name cut in its
  middle with its extension kept, and its size. With several files (Open with `multiple`), a press on the empty part
  and a drag select a rectangle; Escape gives the selection there was back. The view is remembered with the dialog's
  `remember_id`, in its memory file too (the last field of its line: the step's name, `table_zoom_key`).
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
  cleared); a file found is chosen, previewed and named as one of the folder (`fsx.path_join(folder, relative, sep)`).
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
- **A row's menu**: a right click on a row (it is selected), or the Menu key (Shift+F10) on the rows selected, opens
  their context menu. The toolkit's acts come first, each only when the source can do it (`platform.File_Row_Builtin`):

  | Act | Source | Entries |
  |---|---|---|
  | Copy path, Copy name, Copy relative path | every source | all chosen: one line each, in the folder's order; relative to the folder the dialog started in (a path outside it stays whole) |
  | Open with its program, Show in folder | the computer's (`local_files`) | one (`ui.open`, `.Path` / `.Reveal`, on the chores) |
  | Rename (F2) | one with `rename` | one: its name becomes a field in its row or its card, selected without its extension; Enter asks the source, Escape or a press elsewhere gives it up |
  | Move to the trash (Delete) | one with `trash` | all chosen, in one call; a toast says what went, and a click on it puts them back (`restore`) while the dialog is open |

  Then, after a separator, the program's acts (`File_Dialog.row_actions`), each a `File_Row_Action`: `label`, `icon` (a
  Lucide glyph), `folders` (offered on a folder too; by default on files only), `act(user, path)`. An act runs on the
  interface's thread, once per entry chosen that it takes (a multiple selection gives each, in the folder's order), with
  the entry's path in the source's form (valid during the call). The dialog stays open: an act is no answer of the
  dialog. It must not block: ocn's Download starts a task (`http.receive`, docs/http.md). The system's dialogs do not
  show them.

  A program removes the toolkit's acts it does not want with `File_Dialog.row_actions_off`, a
  `bit_set[platform.File_Row_Builtin]` (empty: all of them). The menu opens when one act at least is offered.

  ```odin
  download :: proc(user: rawptr, path: string) { app_download_start((^App)(user), path) }
  acts := []platform.File_Row_Action{{label = "Download", icon = lucide.DOWNLOAD, act = download, user = app}}
  ui.file_dialog(&app.ui, .Open, {row_actions = acts, row_actions_off = {.Copy_Relative_Path}}, done, app, source = &app.server_files)
  ```
- **The first folder**: `start_dir`; else the folder this `remember_id` was left in; else `start_known`, the system's
  folder of that name (`.Downloads`), asked of the source (`File_Source.known`; the computer's source answers it from
  its places, read once per State: a folder the person never made is none); else the source's start, its first place.
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
| Ctrl+L | the path as a field, with its dropdown (↓ ↑, Tab, Enter, Escape: [path-bar.md](path-bar.md)) |
| Ctrl+H | hidden files |
| Ctrl + click, Shift+↑↓, Ctrl+A | several files (Open with `multiple`) |
| a letter | the filter |
| Escape | the path field's while it has the keyboard (its dropdown, then the breadcrumb); else gives a rename up, then clears the filter, then the new folder's row, then cancels |
| Menu, Shift+F10 | the menu of the rows selected |
| F2 (out of a field) | renames the row selected (a source with `rename`) |
| Delete (out of a field) | moves the rows selected to the trash (a source with `trash`) |
| F5 | reads the folder again |
| Shift+Ctrl+N | New folder |
| Ctrl+= / Ctrl+-, Ctrl+wheel over the list | the next or the previous view (the keyboard in the list); Ctrl+0: the details |
| ←→ (cards, columns) | the next or the previous card; in the columns, the next or the previous column |

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
	generation:  u64,                       // the version of what its paths name: another value asks the thumbnails again
	caps:        File_Caps,                 // what it knows and does: .Size, .Modified, .Read, .Make_Folder
	separator:   u8,                        // '/' or '\\': how its paths are joined
	list:        proc(src: ^File_Source, path: string, reply: File_Reply),           // the entries of a folder
	read:        proc(src: ^File_Source, path: string, max: int, reply: File_Reply), // the start of a file (preview)
	make_folder: proc(src: ^File_Source, path: string, reply: File_Reply),
	find:        proc(src: ^File_Source, folder, query: string, limit: int, reply: File_Reply),  // search in subfolders
	places:      proc(src: ^File_Source, allocator: mem.Allocator) -> []platform.File_Place,  // cheap: what it knows already
	start:       proc(src: ^File_Source, allocator: mem.Allocator) -> string,        // where a dialog starts with no folder known ("": the source's first place)
	known:       proc(src: ^File_Source, folder: platform.Known_Folder, allocator: mem.Allocator) -> string,  // a dialog's start_known ("": none; nil: no such folders)
	thumbnail:   proc(src: ^File_Source, path: string, px: int, reply: File_Reply),  // a card's picture (nil: the kind's icon)
	rename:      proc(src: ^File_Source, path, name: string, reply: File_Reply),      // nil: no Rename
	trash:       proc(src: ^File_Source, paths: []string, reply: File_Reply),        // nil: no Move to the trash
	restore:     proc(src: ^File_Source, items: []File_Trashed, reply: File_Reply),  // nil: a trash without undo
}
```

A call starts the work and returns at once: it never blocks the interface's thread. The source answers later (or in
the call), on the interface's thread, through the reply: `file_reply_listed(reply, entries)`,
`file_reply_read(reply, bytes, size)`, `file_reply_made(reply)`, `file_reply_found(reply, entries)`,
`file_reply_renamed(reply)`, `file_reply_trashed(reply, items, message = "")`, `file_reply_restored(reply)`, or
`file_reply_failed(reply, message, refused = false, missing = false)`.

`rename` gives the entry `path` the name `name` in its folder; it must refuse a name taken (`file_reply_failed`, the
source's words in a toast; the field stays to correct it). `trash` moves every path given to the source's trash and
answers `file_reply_trashed` with a `File_Trashed` per entry moved: its `path`, and the `token` that names it in the
trash ("": it cannot come back); `message` says what went wrong with the others ("": none). `restore` gets those items
back, from a click on the trash's toast, and answers `file_reply_restored`. Done, the browser reads the folder again: the
listing is the truth. A remote source that has none of them shows neither Rename nor Move to the trash.

The computer's source renames on the chores (a name taken refused: `os.rename` replaces on POSIX), and trashes with
`platform.move_to_trash(path) -> (in_trash, ok)` and `platform.put_back(in_trash, to) -> bool`: the freedesktop.org
trash on Linux (`.trashinfo` written, the desktop's trash can put it back), the Recycle Bin on Windows
(`IFileOperation`); `put_back` never goes over a name taken again. Both ask the disk: call them from a task.

`find` (nil: no search in subfolders) answers `file_reply_found` with the entries under `folder`, at any depth, that
match `query`, best first, at most `limit`: each entry's `name` is its path relative to `folder`, with the source's
separator (`notes/todo.md`). `reply.hidden` is Hidden files: off, the hidden entries and what is in hidden folders are
not found. The browser shows them in the order given. A reply's `bar` says a listing is the path bar's (its dropdown's
children), not the folder shown's: a source passes the reply back as it is given. A reply carries the ticket of its reading
(`remote`) and its dialog: the answer of a folder left, of a file no longer selected, or of a dialog closed changes
nothing. The entries and bytes are copied by the browser: the source frees its own after the call. A source answers
while the State lives (a program's source stops answering at `ui.destroy`).

`File_Entry`: `name`, `kind` (`.File`, `.Folder`), `link` (a link, to what `kind` says), `size` (-1: unknown),
`modified` (Unix milliseconds, 0: unknown), `hidden` (the source's flag; a name starting with `.` is hidden whatever it
says). `platform.File_Place`: `name` ("": the path's last part), `path`, `icon` (a Lucide glyph, "": a folder).

`ui.local_files()` is the computer's, with all `caps`: `fsx.read_folder` and `core:os` on the chores (`ui.task`), the
system's places (`platform.known_folder_path`, `platform.file_roots`) read once per State on the chores. An entry is
hidden when its name starts with `.` or the system marks it hidden (Windows: the hidden attribute, as in Explorer; a
system file without it is shown), in the folder and in the search alike. Its `find` walks the
folder on the chores, breadth first: it scores each path relative to the folder with `fuzzy_score` and keeps the best
`limit`; it does not enter links, nor hidden folders unless `reply.hidden`; it looks at `FILE_FIND_VISIT_MAX` entries at
most; a newer find, another folder, the toggle off or the dialog closing stops it early. The dates of every source are
told on `timefmt.local_offset_minutes()`, the toolkit's one reading of the local time's offset. A program's own source answers from where its data comes (ocn: its requests to the server, whose answers already
come on the interface's thread).

`examples/showcase/files.odin` is a whole source in memory, one table of folders and files that answers each call at
once: a start for a program's own source.

### Thumbnails

`thumbnail` (nil: the cards show the kind's icon) answers `file_reply_thumbnail(reply, rgba, width, height)` with a
picture of the file at most `px` pixels on its longer side: straight RGBA8, row by row, copied by the browser. With no
picture, it answers `file_reply_failed(reply, "")`: the card keeps its icon. Answer every call: an ask without an answer
holds one of the browser's slots. A thumbnail's answer counts whatever dialog asked (a file's picture is good for the
next one too).

The browser keeps a thumbnail by the source's `user` and `generation` and by the file's path, size and date. A source
whose listing gives no size nor date, or one object that reaches several places (a server's address that changes),
gives another `generation` when what its paths name may have changed: a reconnection, another server, a refresh the
program offers. The cards then ask again; the old thumbnails are no longer shown and go under the budget. The browser
reads it when a dialog opens. A source that leaves it at 0 is keyed as before.

```odin
app.source.generation += 1   // another server behind the same source: its "/a.png" is not the last one's
ui.file_dialog(s, .Open, d, done, app, source = &app.source)
```

A card without a thumbnail (a folder, a file the source has none of) shows its kind's icon at half the picture's
height (`table_card_icon_size`), at every card size.

`local_files()`'s, on the chores: PNG, JPEG, BMP, WebP and a GIF's first frame are decoded (`gt:image`) and reduced; a
picture over `FILE_THUMB_CACHED_BYTES` (2 MiB) is read from the system's cache first (`desktop.thumbnail_cached`) and
kept there once made (`desktop.thumbnail_store`, Linux); another type, a picture over `FILE_THUMB_DECODE_BYTES`
(64 MiB), or a picture `gt:image` fails to decode (a WebP in a program built without `IMAGE_WEBP`), gets the system's
thumbnail (`desktop.thumbnail`: its cache, else its thumbnailer).

That work is `file_thumbnail_make(path, side, system, allocator) -> (File_Thumbnail, ok)`, for a program that makes
thumbnails on its own workers: `rgba`, straight RGBA8, `width` by `height`, at most `side` pixels on its longer side, in
`allocator`; `picture`, the size of the picture it was made from (`{0, 0}` when the system made it: an inspector shows
the size it knows). `file_thumbnail_decodes(name)` says whether the toolkit decodes a file of that name. `system` false
neither reads nor writes the system's cache and never runs its thumbnailer (a test, a program headless). It reads the
disk and may wait for a thumbnailer: call it off the interface's thread.

The browser keeps them in a `Thumb_Cache` (`src/ui/thumbnails.odin`), which any view of items can use:

| Procedure | |
|---|---|
| `thumb_cache_init(c, Thumb_Options{side, most_count, most_bytes, asks})`, `thumb_cache_destroy(c)` | 0: the defaults (256 px, 400 entries, 48 MiB, 2 asks out at a time) |
| `thumb_key(path, size, modified)` | a file's key: a file changed gets another thumbnail |
| `thumb_cache_get(c, key, path)` | in each card built: the entry (`Waiting`, `Asked`, `Ready`, `Failed`), marked used; a new one waits for its ask |
| `thumb_cache_frame(c, ask, user)` | after the cards: the waiting asks sent newest first while fewer than `asks` are out (a card not built for `THUMB_STALE_FRAMES` builds is dropped instead); over the budget, the least used go, never one used in the last `THUMB_KEEP_FRAMES` builds |
| `thumb_cache_answer(c, ticket, rgba, w, h)`, `thumb_cache_failed(c, ticket)` | the answer of an ask (an unknown ticket is ignored) |
| `thumb_cache_clear(c)` | every thumbnail made (`Ready`, `Failed`) forgotten: the cards shown ask again. The asks out stay and their answers land. Safe in a build: the entries go once no draw reads them |
| `thumb_picture(id, t, radius)` | a `Ready` entry in the box `next` gives: fitted, centred, never enlarged; its texture made at its first draw |

The paths of any separator are read by `file_path_root`, `file_path_parent`, `file_path_name`, `file_path_clean`,
`file_path_parts`, `file_path_within`, and joined by `fsx.path_join` (docs/fsx.md); `file_entry_hidden`, `file_entry_look` and `file_look_icon`
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
older query, no request per frame); the program's `key_press` and typed text while the browser is open; the path bar
(Ctrl+L and a path typed, Tab and its own reading beside the list, a part clicked, Escape's order); the program's acts
on a row (a right click on a file and on a folder, the Menu key on several files); the toolkit's acts (the menu with no
program act, Copy path of two entries, a source without rename nor trash, `row_actions_off`, Rename in place, Move to
the trash and its toast's undo, Open and Show in folder on the computer's source only); `start_known`
(a source that knows the folder, `start_dir` first, the computer's Downloads named by a `user-dirs.dirs` of the test's).
