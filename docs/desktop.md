# desktop: the program on the user's desktop

`import desktop "gt:desktop"` (or the relative path of the submodule). The package is named `tk_desktop` (the directory is
`desktop`): a program may have a `desktop` package of its own, and Odin package names are unique within a build.

The package makes a portable program part of the user's desktop, and installs a copy of it in a folder of its own. Everything
is in the user's profile: no administrator rights, nothing system-wide. A program gets:

- **The integration**: a launcher in the application menu (Start menu, freedesktop.org entry), a desktop shortcut (Windows),
  the program on the user's PATH, the icons of the theme (Linux), and for a browser the registration as a candidate browser.
  `status` reads it from the disk, `install` writes it, `remove` takes it away.
- **The installed copy**: `files_install` copies the executable and what ships beside it, and writes a manifest of the files
  it placed. `uninstall` removes the integration, the system's record and exactly those files. On NixOS the copy is made
  to run by itself.
- **A command line**: `install`, `remove`, `status` and `uninstall` without a window, for scripts and tests.
- **The system's thumbnails** of files, read from its cache or made by its thumbnailers (`thumbnail`).
- **A watcher**: the system tells the program when a place of the integration changes (`watch_start`).

Nothing is a preference: the state is read from the disk each time. Removal deletes only what carries the program's mark.

## The identity

`Identity` says what the program is. The backends build every path, key and mark from it, so a second channel of the program
(a development build) has its own files and keys. Its strings and slices are the program's constants: `options_clone` shares
them with a job on another thread.

| Field | Example | What it is |
|---|---|---|
| `name` | `Wren` | the menu entry, the shortcut's file name (`<name>.lnk`), the name in the system's lists |
| `key` | `Wren` | the registry key and ProgID stem (letters and digits) |
| `slug` | `wren` | the `.desktop` file, the icon name, the window class (lower case, digits, hyphens) |
| `aumid` | `FromentSoftware.Wren.Dev` | the Windows AppUserModelID; `set_process_identity` gives it to the process's windows (`""`: `identity_aumid` derives it from `vendor` and `name`, as gt:toolbox's `project_aumid` derives the build's from the Project's publisher and title: `Froment Software` and `Wren` give `FromentSoftware.Wren`; give one only for an id of another rule) |
| `description`, `vendor` | | the menu entry's comment; the publisher in Settings > Apps |
| `exe_name` | `wren.exe` | the executable's name in an install folder (`""`: the slug, with `.exe` on Windows) |
| `entry_marker` | `X-Wren-Integration` | the key that marks the `.desktop` file (begins with `X-`) |
| `registry_mark` | `WrenIntegration` | the value that marks a registry key, set to the `aumid` |
| `vendor_key` | `FromentSoftware` | `Software\<vendor_key>\<key>` keeps the program's own values (the PATH mark) |
| `manifest_name`, `manifest_header` | `wren_install.txt` | the installed copy's list of files, and its first line |
| `launcher_mark` | `(Wren console launcher)` | what the console launcher contains (`""`: the embedded launcher's, which the build gives) |
| `env_prefix` | `WREN_DESKTOP_` | the prefix of the roots `roots_from_env` reads (`""`: none) |
| `url_schemes`, `url_flag` | `wren-https`, `--open-url` | the program's own URL schemes, which run `"<exe>" <url_flag> "%1"` |
| `uninstall_arguments` | `--setup` | Settings > Apps runs `"<exe>" <uninstall_arguments>` |
| `generic_name`, `categories`, `keywords` | `Web Browser`, `Network;WebBrowser;` | the `.desktop` lines (`""`: the line is left out) |
| `actions` | `{{id = "services", name = "Services", arguments = "--section services"}}` | the entry's actions (`Desktop_Action`): `Actions=` and a `[Desktop Action <id>]` group each, which runs the program with its arguments; a launcher's right click offers them |
| `entry_extra` | `{{"X-KDE-Wayland-Interfaces", "org_kde_plasma_window_management"}}` | more keys of the entry, written as they are (escaped): what KWin gives the program besides the common protocols |
| `nix_runtime_name`, `nixos_libraries` | `wren-runtime`, `glibc`... | the Nix profile the installed copy runs with on NixOS (no libraries: the copy is not adapted) |
| `watch_thread_name` | `wren-desktop-watch` | the watcher's thread |
| `cleanup_name` | `wren_cleanup` | the stem of the batch file of a deferred deletion (`""`: the slug) |
| `scratch_roots` | `Software\WrenTest_` | the registry keys `delete_scratch_root` may delete (prefixes) |

`identity_of(vendor, title, slug, allocator = context.allocator) -> Identity` derives the names and the marks by one rule
([vendor-facts.md](../src/md/features/vendor-facts.md)): `name` the title, `key` and `vendor_key` the title and the vendor in
PascalCase (the AppUserModelID's rule: `opencode native` gives `OpencodeNative`), `entry_marker` `X-<key>-Integration`,
`registry_mark` `<key>Integration`, `manifest_name` `<slug>_install.txt`, `env_prefix` `<SLUG>_DESKTOP_` (upper case,
hyphens as underscores). The program sets its own lines after the call, and a mark of another rule that its installed
copies already carry. The strings are allocated in `allocator`: they must live as long as the identity.

```odin
papier_identity :: proc() -> desktop.Identity {
	id := desktop.identity_of("Froment Software", APP_TITLE, APP_NAME)
	id.description = "The clipboard's history: text, rich text, images and files, searched and put back in a keystroke."
	id.generic_name, id.categories, id.keywords = "Clipboard Manager", "Utility;", "clipboard;history;copy;paste;"
	id.uninstall_arguments = "--setup"
	return id
}
```

`install`, `remove` and `status` refuse an identity that could reach another program's files (`Bad_Options`): an empty
`name`, `key`, `slug`, `registry_mark`, `vendor_key` or `manifest_name`, a malformed one, an `entry_marker` without
`X-`, a URL scheme that is not lower case, schemes without `url_flag`, a launcher without `launcher_mark`.

## The options

```odin
o := desktop.options_make(IDENTITY)   // the running executable, the menu entry on, the system told
o.add_to_path = true
o.icons = ICONS                       // Linux: the PNGs of the theme, one per size
if r := desktop.install(&o); r.error != .None { log(desktop.error_text(r.error), r.detail) }
s := desktop.status(&o)               // .Absent, .Installed or .Repair, part by part
defer desktop.status_destroy(&s)
```

`Integration_Options` holds what an installation has (`start_menu`, `desktop_shortcut`, `add_to_path`, `autostart` with its `autostart_arguments` (a program of the notification area starts hidden), `default_file_manager` (the program opens folders in place of the system's file manager, [below](#the-default-file-manager)), `open_documents` and `default_documents` with the `document_types` (the program in "Open with" of its documents and their default, [below](#a-handler-of-document-types)), `thumbnails` (the file managers show those documents as thumbnails the program draws, [below](#thumbnails-in-the-file-managers)), `register_browser` with its
`file_types`, the `launcher` bytes, the `icons`) and where everything goes. `install` writes the parts that are on and takes
away the ones that are off: applying a change of options is the same call. `status` says `Repair` when a wanted part is
missing or incomplete, or when a part runs another executable (`stale_exe`: the program was moved). `describe` says it in one
line, `parts_wanted` and `supported_parts` say which parts exist here, `menu_name`, `default_apps_name` and `targets` give the
words of this system.

### What the settings ask

`apply(&o)` makes the desktop what `o` asks, and writes only what differs. A program calls it at each start and after a
change of its `general.menu` or `general.autostart` preference ([prefs_page.md](prefs_page.md)), on a worker: it reads
and writes files, and on Windows the registry.

```odin
o := desktop.options_make(IDENTITY)
o.icons = ICONS
o.start_menu, o.autostart = menu, autostart
o.autostart_arguments = "--hidden"
if r := desktop.apply(&o); r.error != .None { report(r.detail) }
```

- No part on: the integration is removed when there is one.
- Some part on: `install` runs when the state is `Absent` or `Repair` (a part missing, or one that runs another copy).
  Nothing is written when it is `Installed` and no part that is off is there (a launcher left from before
  `general.menu` went off is taken away).
- A platform with no integration returns no error.

## Windows

| Part | What is written |
|---|---|
| `Launcher` | `<Start menu>\Programs\<name>.lnk` (IShellLink with the AppUserModelID) |
| `Desktop_Shortcut` | `<Desktop>\<name>.lnk` |
| `Path` | the executable's folder in `HKCU\Environment\Path` (REG_EXPAND_SZ), marked by `PathDir` in `Software\<vendor_key>\<key>`; the console launcher `<stem>.com` beside `<stem>.exe` |
| `Autostart` | with `autostart`: the value `<key>` of `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, `"<exe>" <autostart_arguments>` |
| `Registration` | only with `register_browser`: `Software\Clients\StartMenuInternet\<key>`, `Software\RegisteredApplications`, the ProgID `Software\Classes\<key>HTML`, the http and https URL associations, the file types, and `Software\Classes\<scheme>` for each of `url_schemes` |
| `File_Manager` | with `default_file_manager`: in `Software\Classes`, `CLSID\{52205fd8-5dfb-447d-801a-d0b52f2e83e1}\shell\opennewwindow\command` (`"<exe>"`, `DelegateExecute` empty: Win+E), the verb `Directory\shell\<key>.open` (`"<exe>" "%1"`) and `Drive\shell\<key>.open` (`"<exe>" %1`: a quoted `"C:\"` reads as `C:"`), each the default of its `shell` key |
| `Documents` | with `open_documents` (or `default_documents`): in `Software\Classes`, the ProgID `<vendor_key>.<key>.<ext>` of each type (its description, `DefaultIcon`, `shell\open\command` `"<exe>" "%1"`, `AppUserModelID`), an empty value `<ProgID>` in `<ext>\OpenWithProgids`, `Applications\<exe name>` with `SupportedTypes\<ext>`; `Software\<vendor_key>\<key>\Capabilities` with `FileAssociations\<ext>` = the ProgID; the value `<key>.Documents` of `Software\RegisteredApplications` |
| `Thumbnails` | with `thumbnails`: the program's provider `<stem>_thumbnails.dll` beside `<stem>.exe`; in `Software\Classes`, `CLSID\<thumbnail_clsid>` with its `InprocServer32`, and `<ext>\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}` (and under the type's ProgID with the Documents part) = the CLSID ([below](#thumbnails-in-the-file-managers)) |

The installed copy goes to `%LOCALAPPDATA%\Programs\<vendor_key>\<name>` (Linux: `~/.local/opt/<vendor_key>/<name>`) unless `install_dir` says otherwise. `record_install` writes
`Software\Microsoft\Windows\CurrentVersion\Uninstall\<key>`, which Settings > Apps lists and `install_target` reads back
(the default folder when there is no record); `install_recorded` reads the record alone ("" when there is none).
A running program's file cannot be deleted: `files_install` renames it to `.old` first, `clean_old` deletes those at the
next start, and `cleanup_later` deletes the files a running copy holds after the process ends. `open_default_apps` opens
`ms-settings:defaultapps`, where the user picks the default browser: a program that is not a browser does not call it.

The console launcher exists because a program with a window gives the prompt back at once and has no console. The
launcher must contain `launcher_mark`, which is how removal tells it from another file.

The toolkit has the launcher: `tools/console_launcher` (what it does: `src/console_launcher`). For a console command it
waits for the program, hands it its standard input, output and error, and ends with its exit code; for the rest (a window
that stays) it lets go of it. A program writes nothing for it: its tool's build (gt:toolbox, `build_windows`) makes
`<name>.com` with the mark `(<name> console launcher)` and the rules of `Project.launcher`, and `odin_command` embeds it
here (`-define:GT_CONSOLE_LAUNCHER=<file>`, `GT_CONSOLE_LAUNCHER_MARK=<mark>`). That launcher and its mark are the
defaults of `Integration_Options.launcher` and `Identity.launcher_mark` (`launcher_bytes(o)`, `launcher_mark_of(id)`);
options that give their own bytes and mark (a test) take those.

`LAUNCHER_DEFAULT` is what a command line does (`wait` or `detach`); `LAUNCHER_OTHERS`, comma-separated, names those that
do the other: a word is the first argument, a flag (`--x`) is anywhere (also as `--x=value`), `(none)` is no argument at
all. `--cli` anywhere makes the launcher wait, and the program never sees it. A browser: `detach`, its console commands in
`LAUNCHER_OTHERS`. A program of the notification area with commands: `wait`, what shows its window in `LAUNCHER_OTHERS`.

## Linux

| Part | What is written |
|---|---|
| `Launcher` | `$XDG_DATA_HOME/applications/<slug>.desktop` (`desktop_entry_text`), marked by its `entry_marker` line |
| `Desktop_Shortcut` | with `desktop_shortcut`: a copy of the entry in the desktop folder (`platform.known_folder_path(.Desktop)`: `user-dirs.dirs`, else `~/Desktop`; none when the person disabled it), executable; another program's file of that name stays (Install fails with it) |
| `Icons` | `$XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/<slug>.png`, one per icon of the options |
| `Path` | a link `~/.local/bin/<slug>` to the executable |
| `Autostart` | with `autostart`: `$XDG_CONFIG_HOME/autostart/<slug>.desktop` (the XDG Autostart specification), `Exec` the executable and `autostart_arguments`, marked as the desktop entry is |
| `File_Manager` | with `default_file_manager`: `inode/directory=<slug>.desktop;` first in `[Default Applications]` of `$XDG_CONFIG_HOME/mimeapps.list`; the entry then has `inode/directory;` in `MimeType=` and `%F` in `Exec` |
| `Documents` | with `open_documents` (or `default_documents`): the MIME type of each of `document_types` in the entry's `MimeType=`, and `%f` in `Exec`; without `start_menu` the entry stays with `NoDisplay=true` |
| `Default_Documents` | with `default_documents`: `<mime>=<slug>.desktop;` first in the line of each type in `[Default Applications]` of `$XDG_CONFIG_HOME/mimeapps.list` |
| `Thumbnails` | with `thumbnails`: `$XDG_DATA_HOME/thumbnailers/<slug>.thumbnailer`, the program itself with `thumbnail_arguments` for the document types ([below](#thumbnails-in-the-file-managers)) |

The entry has `MimeType=` with `register_browser` (http, https, the URL schemes and the file types), `default_file_manager`
(`inode/directory`) and the Documents part (the document types). `Exec` takes `%U` when the program is a browser or has
URL schemes, else `%F` for a file manager, else `%f` for a handler of documents. `StartupWMClass=` is the slug, the window's class (`platform.set_app_id`
with the slug): a launcher and a dock match the window to the entry by it. After a change `update-desktop-database` runs when it is installed.
The installed copy goes to `$XDG_DATA_HOME/<slug>`; nothing records it but its manifest.

### NixOS

A release is linked for a usual Linux: on NixOS it starts only in an FHS sandbox. `files_install` with `adapt` makes the
copy run by itself: `nix-build` makes a profile of `nixos_libraries` (with patchelf), linked as `<install>/nix-runtime` (a root
of the garbage collector, listed in the manifest), and patchelf sets the copy's loader and library path to it. A copy in the
Nix store (`in_nix_store`) is never adapted: its package already runs it. `is_nixos` reads `/etc/os-release`.

## The default file manager

`default_file_manager` makes the program what opens folders: a file manager offers it as an option of its install, and
`Part.File_Manager` says whether it is in place. Like every part, the state is the system's: the keys or the line are
there or not, and `status` reads them each time. `install` writes the part when the option is on and takes it away when
it is off; `remove` takes it away.

- Windows: Win+E and the taskbar's File Explorer run `"<exe>"` with no argument; a folder or a drive opened from the
  shell (a double click, a shortcut, `start <folder>`) runs `"<exe>" "<folder>"`. The keys are in the user's
  `Software\Classes` (under `registry_root`), over the system's own in HKLM. `<key>.open` and the `opennewwindow` key
  carry `registry_mark`. Removal deletes the keys that are the program's, puts the `(Default)` of `Directory\shell` and
  `Drive\shell` back to none when it names `<key>.open` (the system's `open` is then the default again), and deletes
  the parents left empty. Another program's verb, or a default that names it, stays.
- Linux: the default application of `inode/directory` (the MIME Applications specification). The program's id goes
  first in the line, and the ids that were there stay after it: removal takes the program's id out, and the person's
  former default is the default again. Every other line of the file stays as it was; the file is written in one
  rename, and only when it changes. The default counts only for an entry that takes `inode/directory`: the part needs
  the `Launcher` (`start_menu`), and `status` says it is partial when the entry lacks the type. The file manager
  receives each folder as a path (`%F`), unless the entry already takes addresses (`%U`: a browser).
- Elsewhere: no such part (`supported_parts`).

`mimeapps_default(text, mime)`, `mimeapps_defaults(text, mime)` and `mimeapps_with_default(text, mime, id, on)` read and
edit the text of a `mimeapps.list` (no file read, on every system): the first id of a type's default line, all its
ids, and the text with `id` put first in that line or taken out of it.

## A handler of document types

A program that opens files of its own types (a PDF reader) lists them in `document_types`, a `Document_Type` each:

| Field | Example | What it is |
|---|---|---|
| `extension` | `.pdf` | with its dot, lower case letters and digits: Windows names the type by it (a ProgID holds no other character) |
| `mime` | `application/pdf` | Linux names the type by it |
| `description` | `PDF Document` | what Windows calls a file of the type (`""`: the program's name) |

```odin
PDF := [?]desktop.Document_Type{{".pdf", "application/pdf", "PDF Document"}}

o := desktop.options_make(IDENTITY)
o.document_types = PDF[:]   // always: removal reads them to take the types away
o.open_documents = true     // "Open with" lists the program
o.default_documents = true  // and it is their default (Linux); Windows: Settings opens at the program's page
```

Two parts say what is there. `Part.Documents`: the program is in "Open with" of each type. `Part.Default_Documents`:
it is their default. `default_documents` implies `open_documents`, as a default counts only for a program associated
with the type (`opens_documents(&o)` says whether the options ask for the association). `install` writes the parts
that are on and takes away the ones that are off; `remove` takes both away. The types are the program's constants:
`options_clone` shares them. Give them whatever the boxes say: `remove` and an install with the options off read them
to know what to take away.

- Linux: the entry lists the types in `MimeType=` and takes one file as `%f`. The launcher runs one process per file,
  as Windows does: a program that takes one path needs nothing more (`%U` of a browser and `%F` of a file manager come
  first). Without `start_menu` the entry stays, with `NoDisplay=true`: the menu does not show it, "Open with" does, and
  the `Launcher` part reads as absent. The default is the type's line of `mimeapps.list`, edited as the default file
  manager's: the program's id first, the former default after it and given back on removal.
- Windows: a ProgID per type and three lists that name it (the table above): "Open with" of a file, "Choose another
  app", and Settings > Default apps. The program's ProgIDs also carry its AppUserModelID: the files it opens go to its
  jump list (`platform.add_recent_file`). A type taken out of `document_types` goes at the next install (the
  Capabilities list the types of the last one). Windows lets only the person choose a default (`UserChoice`, which
  removal never edits): there is no `Default_Documents` part, and with `default_documents` `install` opens Settings at
  the program's page (`ms-settings:defaultapps?registeredAppUser=<key>.Documents`; Windows 10 opens the general page)
  when a type's default is another program's. It does so only with `notify_system`: a test's scratch roots open no
  window.
- Elsewhere: no such part (`supported_parts`).

A setup `Choice` ties a box to each part ([setup.md](setup.md#the-programs-options)). Offer the default's box only
where `supported_parts()` has `Default_Documents`. On Windows a box of no part sets `default_documents`: each Install
then opens Settings while a type's default is another program's.

## Thumbnails in the file managers

A program that draws its documents makes the file managers show them as thumbnails: a PDF's first page in Explorer, in
Nautilus, Dolphin or Thunar. Everything comes from the program itself: nothing of another vendor, nothing shipped
beside it. The part is `Part.Thumbnails`, for the types of `document_types`
([src/md/features/shell-thumbnails.md](../src/md/features/shell-thumbnails.md) keeps the reasons).

```odin
o := desktop.options_make(IDENTITY)
o.document_types = PDF[:]
o.thumbnails = true
o.thumbnail_clsid = "{0b6a3f3e-2d1c-4b8e-9a7f-5c4d3e2f1a0b}"   // Windows: the program's own provider, its constant
// o.thumbnail_arguments = "--thumbnail %i %o %s"            // Linux: the default
```

| Field | What it is |
|---|---|
| `thumbnails` | the part is asked (with no document type there is nothing to draw: no part) |
| `thumbnail_clsid` | Windows: the CLSID of the program's provider, `"{8-4-4-4-12}"`, the one its DLL gives to `shell_thumbnail.set`; required on Windows, checked everywhere (`clsid_valid`) |
| `thumbnail_dll` | Windows: the provider's bytes; none: the ones the build embedded (`-define:GT_THUMBNAIL_DLL=<file>`, `thumbnail_dll_bytes`) |
| `thumbnail_arguments` | Linux: what the file managers run the program with; `""`: `THUMBNAIL_ARGUMENTS_DEFAULT`, `--thumbnail %i %o %s` |
| `thumbnailers_dir` | Linux: where the `.thumbnailer` goes (default `$XDG_DATA_HOME/thumbnailers`; `<prefix>THUMBNAILERS_DIR`) |

- Windows: Explorer loads a thumbnail provider only from an in-process COM DLL. The program has its own, a small Odin
  package built as a DLL around `gt:shell_thumbnail` ([shell-thumbnail.md](shell-thumbnail.md)); its `Project` names
  it (`thumbnailer`), and its tool builds it and embeds it ([toolbox.md](toolbox.md)). `install` writes it beside the
  executable as `thumbnail_dll_file(exe)` (`feuille.exe`: `feuille_thumbnails.dll`) and registers it in `HKCU` (the
  table above). The part is partial while the DLL is not the embedded bytes: after an update, the installed copy's
  `apply` writes the new one. A DLL that Explorer's surrogate holds is renamed to `.old` and replaced; removal renames
  it the same way, and the uninstall's deferred deletion gets it (`files_remove` names it). The `ShellEx` slot of a
  type is ours while it names the CLSID: another program's handler stays on removal. A build without a provider (a
  check from Linux) has no part to want (`thumbnails_wanted`).
- Linux: the Thumbnail Managing Standard's `.thumbnailer` (`thumbnailer_text`): `TryExec` the executable, `Exec` the
  executable and `thumbnail_arguments`, `MimeType` the types, and the identity's `entry_marker` line, which removal
  looks for. The program answers its arguments: it writes a PNG of the document (`%i`) at most `%s` pixels on its
  longer side to `%o`, and ends with 0. `thumbnail` and `thumbnail_cached` of this package read the file as any file
  manager does.
- Elsewhere: no such part (`supported_parts`).

A setup `Choice` ties a box to `{.Thumbnails}` ([setup.md](setup.md#the-programs-options)).

## Open with

`handlers_for_file(path)` lists the applications the system knows for the type of the file at `path` (the file need not
exist: its name says its type). The default comes first (`Handler.default`), then the others by name. Each `Handler` has
an `id` and a `name` for a menu; free the list with `handlers_destroy`. `open_with(path, id)` opens the file with one of
them. The system's default application is `platform.open_path`.

`type_name(name)` is what the system calls the type of a file of that name ("Plain text document", "PNG image"): on
Linux the English `<comment>` of `mime/<type>.xml` for the type shared-mime-info's globs give the name, on Windows the
shell's type name (`SHGetFileInfoW`, `SHGFI_TYPENAME`, from the extension alone). "" when the system says nothing. It
reads the system's files the first time a type is asked: call it on a worker and keep the answer by extension.

- Linux reads the XDG specifications: the type from shared-mime-info (`mime/globs2` and `mime/subclasses` under each data
  directory; every `text/*` is also `text/plain`), the applications from the desktop entries under `applications/` (their
  `MimeType`; not `Hidden`, not `Terminal`, an `Exec` line that `exec_expand` accepts). The MIME Applications
  specification orders them, level by level: each configuration directory, then each data directory's `applications/`.
  A level's `mimeapps.list` adds and removes associations for itself and the levels after it; its
  `<desktop>-mimeapps.list` (each name of `$XDG_CURRENT_DESKTOP`, in lower case) gives defaults only. The default of a type
  is the first `[Default Applications]` entry, level by level, that is associated with the type; else the most preferred
  application of the type. The type comes before its parents. The id is the desktop file id
  (`org.gnome.TextEditor.desktop`). `open_with` runs its `Exec` line, the field codes replaced (`exec_expand`), with
  `platform.launch_detached`. What was read stays in a cache of the process until a file or a folder read changes (one
  `statx` each: under 1 ms for 83 entries in 9 data directories, against 10 to 16 ms to read everything again in a debug
  build). A link that loops under `applications/` is read once.
- Windows asks the shell for the recommended handlers of the extension (`SHAssocEnumHandlers`, as Explorer's "Open with"
  shows them). The id is the handler's name; `open_with` calls `IAssocHandler.Invoke` with the file. The default is the
  handler of the program `AssocQueryStringW` names.
- Elsewhere: no handler.

`exec_arguments(value)` splits an `Exec` value as the specification quotes it: each `Exec_Argument` has its `text` and
whether it was `quoted`. `exec_expand(value, path, name, icon, desktop_file)` makes the command that opens `path`, or
returns `ok = false` for a line the specification refuses:

- a field code other than `%%` in a quoted argument (`sh -c "viewer %f"`: the shell would read the file name);
- a field code the specification does not list, or a `%` at the end;
- `%F`, `%U` or `%i` inside an argument (they must be an argument of their own);
- more than one of `%f`, `%F`, `%u` and `%U`;
- no program.

The deprecated codes (`%d`, `%D`, `%n`, `%N`, `%v`, `%m`) are dropped. A line with no file code gets the path at its end.

## Icons of files

`file_icon(path, folder, size, choose)` gives the icon the system shows for a file or a folder, about `size` pixels square, as
straight RGBA8 (`File_Icon`; `file_icon_destroy` frees it). `file_icon_key(path, folder)` says what decides it: two paths
with the same key have the same icon, so a program keeps one picture per key and size. `choose` (above 0): the size the theme's
file is chosen by, the picture still made at `size` (Papirus's small icons are monochrome, its coloured ones start at 24).
`file_icon` reads files: call it from a worker.

| System | Where the icon comes from |
|---|---|
| Linux | The person's icon theme (Icon Theme specification), read once per process: the Settings portal's `org.gnome.desktop.interface` `icon-theme` (dconf's, what GTK shows), else `gtk-icon-theme-name` of gtk-4.0's or gtk-3.0's `settings.ini`, else KDE's `kdeglobals` `[Icons] Theme=`, the themes it inherits, then `hicolor`; the subfolder of the size asked, else the nearest. A file's names: its type's icon (`mime/icons`), the type with `/` made `-` (`image-png`), its family's (`mime/generic-icons`), its parents', `<media>-x-generic`. A folder: the person's folders their own (`user-home`, `user-desktop`, `folder-documents`, `folder-download`, `folder-music`, `folder-pictures`, `folder-videos`), the trash `user-trash`, the root `drive-harddisk`, else `folder`. PNG files decoded, reduced to the size asked when larger; SVG files rendered by librsvg and cairo, opened at run time (`svg_available`): without them, the PNG icons only. |
| Windows | The shell's: the path's index in the system's image list (`SHGetFileInfoW`), the icon from the list nearest above the size asked (16, 32, 48, 256: `SHGetImageList`). A program's, a shortcut's, an icon file's own; a folder's own. COM is started on each thread that asks. |
| Other systems | None (`ok` false). |

The theme read and the files found are kept while the data folders and the theme's name are the same. The theme's name is
asked once (`file_icons_forget` makes the next icon ask it again: the person chose another theme). `file_icon_key` reads no
file: on Linux a file's is the type its name says; a folder's is its path, on every system (whether it is one of the
person's folders comes from a file, read by `file_icon` on its worker).

## Icons of applications

`theme_icon(name, size)` gives the icon named `name` in the person's icon theme, about `size` pixels square, as a
`File_Icon`. `name` is a desktop entry's `Icon=` key (`firefox`). The lookup is the one of `file_icon`: the theme, the
themes it inherits, `hicolor`, the subfolder of the size asked, else the nearest. Then come the `pixmaps` folders of the
data directories, as the specification says. An absolute path is the file itself (a PNG or an SVG). `ok` is false when
there is none, and on systems other than Linux. It reads files: call it once per name and size, or from a worker.

```odin
if ic, ok := desktop.theme_icon(entry.icon, 32); ok {
	defer desktop.file_icon_destroy(&ic)
	tex := render.create_texture_rgba(&r, ic.size.x, ic.size.y)
	render.update_texture_rgba(&r, tex, 0, 0, ic.size.x, ic.size.y, ic.rgba)
}
```

## Thumbnails

`thumbnail(path, size)` gives the system's thumbnail of a file (`path` absolute), at most `size` pixels on its longer side,
as straight RGBA8 (`Thumbnail`; `thumbnail_destroy` frees it): a PDF's first page, a frame of a video, a document, a
picture, whatever the system has a thumbnailer for. On a miss it has the system make one and waits for it (seconds for a
long video): call it from a worker, never from the interface's thread. `ok` is false when the system has none and cannot
make one. `thumbnail_cached(path, size)` reads the system's cache only: a miss is `ok = false` at once.
`thumbnail_store(path, rgba, width, height)` keeps a picture the program made itself in the system's cache (Linux), where
`thumbnail_cached` and the other programs find it.

```odin
// on a worker
if th, ok := desktop.thumbnail(path, 256); ok {
	defer desktop.thumbnail_destroy(&th)
	post(th.rgba, th.size)   // the interface's thread makes the texture
}
```

| System | Where the thumbnail comes from |
|---|---|
| Linux | The freedesktop.org Thumbnail Managing Standard. The cache is `$XDG_CACHE_HOME/thumbnails` (default `~/.cache/thumbnails`): `normal` (128 pixels), `large` (256), `x-large` (512), `xx-large` (1024); a file's thumbnail is the MD5 of its `file://` URI (escaped as GLib does) in hex, `.png`. It is valid while its `Thumb::URI` and `Thumb::MTime` (the file's date in seconds) are the file's. The folder of the size asked is read, then the larger ones (reduced). On a miss, the thumbnailer of the file's type (its name's MIME type, then the types it is a kind of): the `*.thumbnailer` files under `thumbnailers/` of each data directory (`[Thumbnailer Entry]`: `TryExec`, `Exec` with `%i` `%u` `%o` `%s` `%%`, `MimeType`). It runs at most 30 seconds; its PNG goes to the cache with `Thumb::URI`, `Thumb::MTime`, `Thumb::Size` and `Software` (`THUMBNAIL_SOFTWARE`), 0600 in 0700 folders, through a file renamed onto its name. A thumbnailer that fails leaves `fail/gui_toolkit/<name>.png`: it is not run again for that file until the file changes. A type with no thumbnailer has none. |
| Windows | The shell's: `IShellItemImageFactory::GetImage` with `SIIGBF_THUMBNAILONLY` (a thumbnail, never the type's icon: `file_icon` gives that), from the system's thumbnail cache or made by the type's handler; `thumbnail_cached` adds `SIIGBF_INCACHEONLY`. A handler with no thumbnail of that size is asked for a larger one, reduced. The bitmap's premultiplied BGRA is read back as straight RGBA. COM is started on each thread that asks. `thumbnail_store` writes nothing (the shell fills its own cache). |
| Other systems | None (`ok` false). |

The thumbnailers read are kept while no file or folder read has changed (a stat of each per call).

## A terminal in a folder

`open_terminal(dir)` opens a terminal whose shell starts in `dir` ("Open a terminal here"). False when none can start.

| System | The terminal |
|---|---|
| Linux | `$TERMINAL` when it is set, else the first of `xdg-terminal-exec`, foot, kitty, alacritty, wezterm, ghostty, gnome-terminal, kgx, konsole, xfce4-terminal, tilix, terminator, lxterminal, mate-terminal, urxvt, st, xterm found on the `PATH`, started in the folder. |
| Windows | Windows Terminal (`wt -d <dir>`), else the command prompt started in the folder. |

## The installed copy

```odin
plan := desktop.Install_Plan{identity = IDENTITY, src_exe = process.executable_path(), dir = dir, exe_name = desktop.exe_name_of(IDENTITY),
                             payload = {"licenses", "readme.txt"}, version = VERSION, channel = "release", adapt = true}
if why := desktop.check_install_dir(dir, IDENTITY.name, probe = true); why != "" { show(why) }
r := desktop.files_install(plan)                       // then desktop.install and desktop.record_install
info := desktop.installed_info(&o, dir)                // version, channel, files, missing
ur := desktop.uninstall(&o, process.executable_path())   // leftovers: files a running copy holds
```

`check_install_dir` refuses system folders, relative paths and names Windows cannot make. `compare_versions` compares two
version strings part by part. The manifest is `<manifest_name>` in the folder: `version=`, `channel=`, `exe=` and one `file=`
per file placed; a hand-edited one never reaches outside its folder.

## The command line

A program's install command line is gt:setup's (`--install`, `--uninstall`, `--setup`, `--status`, `--quit`:
`setup.command_of`, `setup.command_run`, [setup.md](setup.md)). This package has none of its own.

## The tests' scratch roots

Every place is a field of `Integration_Options`: `menu_dir`, `desktop_dir`, `environment_root` and `registry_root` (keys under
HKEY_CURRENT_USER), `applications_dir`, `icons_dir`, `bin_dir`, `autostart_dir`, `config_dir` (`$XDG_CONFIG_HOME`, where `mimeapps.list` is), `thumbnailers_dir`, `install_dir`. A test points them at a scratch folder and a
scratch key, and turns `notify_system` off. `roots_from_env` reads them from `<env_prefix>MENU_DIR`, `<env_prefix>BIN_DIR`...
(`ROOT_NAMES`), so a program's own end-to-end tests run it on scratch places; any of them set turns the notification off.
`delete_scratch_root` deletes a scratch registry key, and only one under the identity's `scratch_roots`.

The package's tests (`odin run tools/run_tests -- desktop_pkg`) use an identity of their own (`Sample`): the Linux backend on
scratch folders, the Windows backend on `HKCU\Software\TkDesktopTest_<id>`, and on NixOS a copy of bash adapted with a real
runtime. `TK_TEST_DESKTOP_REAL=1` adds one round trip on the real Windows desktop.

## The XDG roots (Linux)

`xdg_roots()` gives the data directories (`$XDG_DATA_HOME`, then `$XDG_DATA_DIRS`), the configuration ones
(`$XDG_CONFIG_HOME`, then `$XDG_CONFIG_DIRS`) and the current desktop's names (`$XDG_CURRENT_DESKTOP`), most important
first, absolute paths only (the specification ignores a relative one), in the temporary allocator: a program reads
what the specifications place there (the applications' entries, the autostart folder) through it, not through the
variables.
