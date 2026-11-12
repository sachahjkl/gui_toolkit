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
| `slug` | `wren` | the `.desktop` file, the icon name, the window class, the default install folder on Linux (lower case, digits, hyphens) |
| `aumid` | `FromentSoftware.Wren` | the Windows AppUserModelID; `set_process_identity` gives it to the process's windows |
| `description`, `vendor` | | the menu entry's comment; the publisher in Settings > Apps |
| `exe_name` | `wren.exe` | the executable's name in an install folder (`""`: the slug, with `.exe` on Windows) |
| `entry_marker` | `X-Wren-Integration` | the key that marks the `.desktop` file (begins with `X-`) |
| `registry_mark` | `WrenIntegration` | the value that marks a registry key, set to the `aumid` |
| `vendor_key` | `FromentSoftware` | `Software\<vendor_key>\<key>` keeps the program's own values (the PATH mark) |
| `manifest_name`, `manifest_header` | `wren_install.txt` | the installed copy's list of files, and its first line |
| `launcher_mark` | `(Wren console launcher)` | what the console launcher contains (`""`: the program has none) |
| `cli_flag` | `--desktop-integration` | the flag `parse_cli` takes out (`""`: none) |
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

`install`, `remove` and `status` refuse an identity that could reach another program's files (`Bad_Options`): an empty
`name`, `key`, `slug`, `aumid`, `registry_mark`, `vendor_key` or `manifest_name`, a malformed one, an `entry_marker` without
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

`Options` holds what an installation has (`start_menu`, `desktop_shortcut`, `add_to_path`, `autostart` with its `autostart_arguments` (a program of the notification area starts hidden), `register_browser` with its
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

The installed copy goes to `%LOCALAPPDATA%\Programs\<name>` unless `install_dir` says otherwise. `record_install` writes
`Software\Microsoft\Windows\CurrentVersion\Uninstall\<key>`, which Settings > Apps lists and `install_target` reads back
(the default folder when there is no record); `install_recorded` reads the record alone ("" when there is none).
A running program's file cannot be deleted: `files_install` renames it to `.old` first, `clean_old` deletes those at the
next start, and `cleanup_later` deletes the files a running copy holds after the process ends. `open_default_apps` opens
`ms-settings:defaultapps`, where the user picks the default browser: a program that is not a browser does not call it.

The console launcher exists because a program with a window gives the prompt back at once and has no console. The program
provides the launcher's bytes; the launcher must contain `launcher_mark`, which is how removal tells it from another file.

The toolkit has the launcher: `tools/console_launcher` (what it does: `src/console_launcher`). For a console command it
waits for the program, hands it its standard input, output and error, and ends with its exit code; for the rest (a window
that stays) it lets go of it. A program builds its own, with its mark and its rules, and embeds the bytes:

```sh
odin build ext/gui_toolkit/tools/console_launcher -subsystem:console -o:size -out:build/<stem>.com \
    "-define:LAUNCHER_MARK=(<stem> console launcher)" -define:LAUNCHER_DEFAULT=wait "-define:LAUNCHER_OTHERS=(none),--hidden"
```

```odin
when ODIN_OS == .Windows { o.launcher = #load("../build/<stem>.com") }
```

`LAUNCHER_DEFAULT` is what a command line does (`wait` or `detach`); `LAUNCHER_OTHERS`, comma-separated, names those that
do the other: a word is the first argument, a flag (`--x`) is anywhere (also as `--x=value`), `(none)` is no argument at
all. `--cli` anywhere makes the launcher wait, and the program never sees it. A browser: `detach`, its console commands in
`LAUNCHER_OTHERS`. A program of the notification area with commands: `wait`, what shows its window in `LAUNCHER_OTHERS`.

## Linux

| Part | What is written |
|---|---|
| `Launcher` | `$XDG_DATA_HOME/applications/<slug>.desktop` (`desktop_entry_text`), marked by its `entry_marker` line |
| `Desktop_Shortcut` | with `desktop_shortcut`: a copy of the entry in the desktop folder (`xdg_desktop_dir`: `$XDG_DESKTOP_DIR`, else `user-dirs.dirs`, else `~/Desktop`), executable; another program's file of that name stays (Install fails with it) |
| `Icons` | `$XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/<slug>.png`, one per icon of the options |
| `Path` | a link `~/.local/bin/<slug>` to the executable |
| `Autostart` | with `autostart`: `$XDG_CONFIG_HOME/autostart/<slug>.desktop` (the XDG Autostart specification), `Exec` the executable and `autostart_arguments`, marked as the desktop entry is |

The entry has `MimeType=` (http, https, the URL schemes and the file types) only with `register_browser`, and `Exec` takes
`%U` when the program is a browser or has URL schemes. `StartupWMClass=` is the slug, the window's class (`platform.set_app_id`
with the slug): a launcher and a dock match the window to the entry by it. After a change `update-desktop-database` runs when it is installed.
The installed copy goes to `$XDG_DATA_HOME/<slug>`; nothing records it but its manifest.

### NixOS

A release is linked for a usual Linux: on NixOS it starts only in an FHS sandbox. `files_install` with `adapt` makes the
copy run by itself: `nix-build` makes a profile of `nixos_libraries` (with patchelf), linked as `<install>/nix-runtime` (a root
of the garbage collector, listed in the manifest), and patchelf sets the copy's loader and library path to it. A copy in the
Nix store (`in_nix_store`) is never adapted: its package already runs it. `is_nixos` reads `/etc/os-release`.

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
file: on Linux it is the type the name says.

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

`parse_cli` takes `<cli_flag>=install|remove|status|uninstall` (or the two-word form, or `--install` / `--uninstall`) out of
the arguments; `cli_run` runs it and writes its report with the procedure it is given (`process.console_write`). Exit codes:
0 done (`status`: installed), 1 failed (`status`: absent), 2 to repair, 3 unreadable, `CLI_UNINSTALL_LATER` (5) uninstalled
with files left for after the process ends.

## The tests' scratch roots

Every place is a field of `Options`: `menu_dir`, `desktop_dir`, `environment_root` and `registry_root` (keys under
HKEY_CURRENT_USER), `applications_dir`, `icons_dir`, `bin_dir`, `autostart_dir`, `install_dir`. A test points them at a scratch folder and a
scratch key, and turns `notify_system` off. `roots_from_env` reads them from `<env_prefix>MENU_DIR`, `<env_prefix>BIN_DIR`...
(`ROOT_NAMES`), so a program's own end-to-end tests run it on scratch places; any of them set turns the notification off.
`delete_scratch_root` deletes a scratch registry key, and only one under the identity's `scratch_roots`.

The package's tests (`odin run tools/run_tests -- desktop_pkg`) use an identity of their own (`Sample`): the Linux backend on
scratch folders, the Windows backend on `HKCU\Software\TkDesktopTest_<id>`, and on NixOS a copy of bash adapted with a real
runtime. `TK_TEST_DESKTOP_REAL=1` adds one round trip on the real Windows desktop.
