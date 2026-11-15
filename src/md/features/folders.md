# Folders: a program's, the person's, the session's

Three questions, one procedure each, on every system:

- `platform.user_dir(kind, program)`: where a program keeps what it keeps (configuration, data, state, cache, runtime).
- `platform.known_folder_path(k)`: where the person keeps theirs (Desktop, Documents, Downloads, Music, Pictures,
  Videos, Home), as their desktop names them.
- `platform.session_runtime_dir()`: whether the session has a real runtime folder, the one other services of the session
  (gvfs, the portals, D-Bus) use.

`fsx.private_dir(path)` makes a folder that only its user can enter, and refuses one that another user made first.

## Where a program is installed

A program installed for one person goes to `%LOCALAPPDATA%\Programs\<vendor_key>\<name>` on Windows (Microsoft's
place for a person's own programs, as VS Code's user setup uses it) and `~/.local/opt/<vendor_key>/<name>` on Linux.
It is never its data's folder: an uninstall deletes the install folder, and the data (`%LOCALAPPDATA%\<vendor>\<Title>`,
`~/.local/share/<vendor>/<Title>`) stays. XDG names no place for programs; `~/.local/opt` mirrors `/opt`, where FHS puts
an application that comes as a folder of its own. Refused: `~/.local/share/<slug>` (the data's tree: an install beside
the data, one rm from losing it), `~/.local/lib` (systemd's file-hierarchy keeps it for data and libraries, not an
application's folder). An install already somewhere stays there: the setup reads the folder it recorded.

On macOS a program is a bundle: `~/Applications/<name>.app`, the folder macOS keeps for one person's applications,
with no vendor folder around it (the Finder, Launchpad and the Dock expect the bundle there). Its folders follow
Apple's guide: settings, data and state in `~/Library/Application Support/<vendor>/<Title>` (the settings are the
program's own files, not `~/Library/Preferences`' plists), its cache in `~/Library/Caches/<vendor>/<Title>`, its logs
in `~/Library/Logs/<vendor>/<Title>` (where Console.app looks), its runtime files in the user's `$TMPDIR`. These are
said already, for the setup's field and `user_dir`; the bundle itself waits for a Mac to test it
(`src/desktop/integration_darwin.odin`).

## A program's folder: its vendor's, then its own

A program's folder is `<vendor>/<Title>` on every system (`"FromentSoftware" + USER_DIR_SEPARATOR + "Papier"`):
`%APPDATA%\FromentSoftware\Papier`, `~/.config/FromentSoftware/Papier`. The person finds a vendor's programs together,
under the names they read in the menu, and the same layout on Windows and Linux.

- **The same on Linux, against the habit of lower-case folders.** XDG names no case; most Linux programs write
  `~/.config/<binary>`. The user chose one layout for every system: a person moving between them finds the same place.
  The binary, the package and the instance's socket keep the lowercase technical name.
- **The program gives the folder as a constant**, passed wherever it names its folders (`user_dir(kind, APP_FOLDER)`).
  `user_dir` does not learn a vendor: one string, one place to read it, no global of the process.
- **The old folders move once** (`user_dirs_move(from, to)`, at start, before anything reads them): a person keeps their
  settings, history and licence. A rename, not a copy: the move is the same volume's, and a second run finds the new
  folder and does nothing. A folder whose new name is there already is left: what is new is never written over. This is
  the one move a rename of the layout is worth; a later rename of a program moves the same way, by its own call.

## The person's folders on Linux

The names come from xdg-user-dirs: `$XDG_CONFIG_HOME/user-dirs.dirs` (else `~/.config/user-dirs.dirs`), written at
login by `xdg-user-dirs-update` in the person's language (`XDG_DESKTOP_DIR="$HOME/Bureau"`). The toolkit used to
give `$HOME/<English name>` whatever the file said, so a French desktop's `~/Bureau` and `~/Téléchargements` were not
in the file browser's places.

The format is a shell file, but it is not run: the reader takes what GLib's `g_get_user_special_dir` takes.

- A line is `XDG_<NAME>_DIR="<value>"`, spaces allowed around `=`. `#` starts a comment. A name it does not know
  (TEMPLATES, PUBLICSHARE) is left out.
- The value starts with `$HOME` (then `/` or the end) or `/`. Any other form is left out: the format allows only these.
- A `\` takes the next character as it is. A last `/` goes.
- The last line for a name wins, as when a shell reads it.
- A value equal to the home means that the folder is disabled: `xdg-user-dirs-update` says "to disable a directory,
  point it to the homedir". `known_folder_path` gives "" for it, Desktop included. GLib gives the home there, but the
  programs that show places (GTK's sidebar) skip a folder equal to the home. Refused: the home for a disabled Desktop.
  The desktop shortcut of `desktop.install` would then go into the home, and the sidebar would show the home twice.
- A folder the file does not name (no file, no line, a form left out) is `$HOME/<English name>`. That is the default
  of `user-dirs.defaults`, and a system without xdg-user-dirs has these folders. A caller that shows places still checks
  that the folder exists.
- `$XDG_<NAME>_DIR` in the environment is not read. These names are keys of the file, not session variables. GLib does
  not read them. A test points `XDG_CONFIG_HOME` at a file of its own.

### When the file is read

The file is read once per process, at the first `known_folder_path` call, and kept. The cache key is the file's path
and the home. If a test changes `XDG_CONFIG_HOME` or `HOME`, the next call reads the new file. GLib keeps it the same
way, until `g_reload_user_special_dirs_cache`. `xdg-user-dirs-update` writes it at login, before the programs start.

`known_folder_path` is a blocking procedure on every system: on Windows each call asks `SHGetKnownFolderPath`. It calls
`base.blocking`, so a call on the interface's thread is reported, even when the answer comes from the cache. The rule
is the same for both systems, and a cold cache on the interface's thread is never hidden. Its callers are on workers:
the file browser's places (`file_local_warm`), the dialogs, `desktop.file_icon`, `desktop.install`.

`desktop.file_icon_key(path, folder = true)` is called in a frame (Wren). It does not read the person's folders: a
folder's key is its path, as on Windows. `file_icon` resolves the special icon (`folder-pictures`) on its worker.
Refused: a key that names the icon (`folder:folder-pictures`). That key needs the person's folders, so it needs the
file read in a frame.

## The runtime folder

`user_dir(.Runtime, program)` holds sockets, pipes, and files that last a session. It is never a folder that another
user can enter or make first.

On Linux, in this order:

1. `$XDG_RUNTIME_DIR` when it is an absolute path. The basedir specification makes it the user's, mode 0700, made by
   the login manager. It is trusted as given.
2. `/run/user/<uid>` when it is a folder (not a link) owned by this user, closed to the others. That is what
   systemd-logind makes. The variable is missing under `su`, `sudo`, `cron`, or an `ssh` session without pam_systemd,
   while the folder still exists.
3. `<TMPDIR or /tmp>/runtime-<uid>`, made by `fsx.private_dir`. Qt's fallback has the same name and the same checks.
   If another user made that name first, or it is a link, the answer is "": no file of this user goes there.

Steps 1 and 2 are `session_runtime_dir`. Step 3 is only `user_dir`'s.

Refused alternatives:

- `/tmp` as it is, the old fallback. Every user can list it and make a name in it first. papier and classeur each had
  to close their folders themselves (a `chmod`, a `make_directory_all` with 0700 and a `stat`): one check per program,
  and each was a different check.
- GLib's fallback, the cache folder (`~/.cache`). Nobody else can take it, but it is on the disk and it is not emptied
  at logout. papier's history that is "not kept" would then be kept on the disk. `~/.cache` can also be on NFS, where
  a socket does not work.
- A path only, with the check left to each program. `user_dir` gives a path that a program trusts. A program that
  forgets the check is open to another user.

The base is closed to the others, so a program's folder in it (`user_dir(.Runtime, "papier")`) needs nothing more:
`fsx.make_dirs` is enough. Only step 3 touches the disk (a `stat`, a `mkdir`). `user_dir(.Runtime, ...)` is therefore
a blocking call, as `user_dir` already is on Windows (`SHGetKnownFolderPath`).

On Windows, the runtime folder is the system's temporary folder, as Windows gives it to every program:
`GetTempPath2W` where the system has it (Windows 11, and Windows 10 after its 2022 updates), else `GetTempPathW`.
These read `%TMP%`, `%TEMP%`, `%USERPROFILE%`, then the Windows folder. `GetTempPath2W` gives a process of SYSTEM
`C:\Windows\SystemTemp`, which is closed to the other accounts. Refused: our own reading of `TEMP` and `TMP`, then
`%LOCALAPPDATA%` when they are missing or relative. That order was not Windows' order (TMP first), and its last step
was not a temporary folder. `session_runtime_dir` is ("", false) there: Windows has no such folder.

## fsx.private_dir

`private_dir(path)` makes the missing parents (as `make_dirs` does) and the folder itself with mode 0700. It returns
true when the path is a folder of this user that only this user can enter.

- A folder of this user that is open to others is closed (0700). Qt does the same.
- A link at the name is refused, and so is a folder of another user.
- The checks are made on the opened folder (`open` with `O_NOFOLLOW | O_DIRECTORY`, then `fstat` and `fchmod`), not on
  its name. If the name changes between the check and the change, the change still applies to the checked folder. In
  a sticky folder (`/tmp`), no other user can rename or remove a folder that is ours.
- On Windows, a new folder takes its parent's access list. The parents used here (`%TEMP%`, `%LOCALAPPDATA%`) are in the
  user's profile, closed to the other users. A junction or a link at the name is refused, as on POSIX.

The test cannot make a folder of another user without root. It checks the mode, the closing of an open folder, and
the refusal of a link.
