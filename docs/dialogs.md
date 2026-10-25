# File dialogs and shell actions (`platform/dialogs.odin`)

The system's Open, Save and folder dialogs, and handing a URL or a file to the system, behind an API of the toolkit's
own. Windows: the Common Item Dialog (`IFileOpenDialog`, `IFileSaveDialog`) and `ShellExecuteExW`
(`platform/dialogs_win32.odin`). Other systems: every call answers "not supported" (`dialogs_stub.odin`).

```odin
r := platform.open_file_dialog({
	owner = win, title = "Open an image",
	filters = {{name = "Images", patterns = {"*.png", "*.jpg"}}}, all_files = true,
	start_known = .Pictures, remember_id = "images", multiple = true,
})
defer platform.dialog_result_destroy(&r)
if r.status == .Chosen { for p in r.paths { ... } }
```

| procedure | what |
|---|---|
| `open_file_dialog(d)` | files that exist (`multiple`: several) |
| `save_file_dialog(d)` | a path to write (`suggested_name`, `default_ext`, `overwrite_prompt`) |
| `pick_folder_dialog(d)` | a folder |
| `dialog_result_destroy(&r)` | frees `r.paths` (made with the allocator given to the dialog) |
| `known_folder_path(k)` | Desktop, Documents, Downloads, Music, Pictures, Videos, Home |
| `open_url(url)` | the system's handler of the URL (default browser, mail client) |
| `open_path(path)` | the application of the file's type (a folder: the file manager) |
| `reveal_in_folder(path)` | the file manager on the file's folder, with the file selected |

`File_Dialog`: `owner` (disabled while the dialog is up), `title`, `filters` (`File_Filter`: a name and patterns
`"*.ext"`; a bare `"ext"` or `".ext"` is accepted), `all_files` (a last "All files" line), `filter_index`, `start_dir`
(an explicit folder) or `start_known` (a default), `remember_id` (the system keeps the last folder per id),
`suggested_name`, `default_ext`, `multiple`, `overwrite_prompt`. `Dialog_Result`: `status` (`Chosen`, `Cancelled`,
`Unsupported`, `Failed`), `paths`, `filter` (the type line selected).

**Threads.** The dialogs are modal and return when the user closed them: call them from a thread that may block (a
worker of the app's blocking pool), not from the frame loop.

**Filters.** `filter_patterns(f)` joins a filter's patterns as the systems want them (`"*.png;*.jpg"`),
`filter_matches(filters, name)` matches a file name case-insensitively, `filters_from_accept(entries, mime_extensions)`
makes filters from a web page's description of what it accepts (a description, a MIME type, extensions; a MIME type
alone takes the extensions the app's table knows).

**Tests.** `dialog_test_hook` answers instead of the system's dialogs (end-to-end tests of an app: a real dialog needs a
person). `odin test tests/dialogs -vet`.
