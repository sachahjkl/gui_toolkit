# The default file manager

A file manager made with the toolkit can take the place of the system's: Win+E and a folder opened from the shell open
it on Windows, and a folder opened by another application opens it on Linux. The how-to is in
[docs/desktop.md](../../../docs/desktop.md#the-default-file-manager); this file keeps the reasons.

## A part of the integration, not a preference

The option is `Part.File_Manager` of gt:desktop, beside the launcher and the PATH. Its state is the presence of
registry keys or of one line of `mimeapps.list`, read each time; the program keeps no flag of its own. So the box of the
install shows what the system does, and a change made elsewhere (the person's settings, another program that takes the
default) shows at the next read. A setup `Choice` is tied to the part (`Choice.parts`) for this reason: when an install
exists, its box starts from `Facts.parts`, not from a default.

## Windows

- The user's `Software\Classes` overrides the machine's: no administrator rights, and removal gives back exactly what
  the system had.
- Win+E runs File Explorer's object `{52205fd8-5dfb-447d-801a-d0b52f2e83e1}` with its verb `opennewwindow`. A
  `command` under it in HKCU, with an empty `DelegateExecute`, makes the shell run the command in place of Explorer's
  own handler.
- Folders and drives get a verb of the program's (`<key>.open`), made the default of `Directory\shell` and
  `Drive\shell`. Refused: `Folder\shell`. `Folder` also covers virtual folders (Control Panel, the Recycle Bin, This PC),
  which a program that reads paths cannot open.
- Refused: replacing the system's `open` verb. Removal could not tell the system's command from the program's, and
  the person's Explorer would stay broken after an uninstall.
- A `(Default)` of `shell` holds no mark. It is the program's when it names `<key>.open`, a name in the program's own
  namespace, and removal clears it only then.

## Linux

- The MIME Applications specification has no "default file manager": a folder is `inode/directory`, and its default
  application is the file manager. Desktops (GNOME, KDE, xdg-open) read that line.
- The program's id goes first in the line, and the ids already there stay after it. Removal takes only the program's
  id out, so the person's former default comes back without a record of it.
- The default counts only for an entry associated with the type, so the entry declares `inode/directory` while the
  option is on, and takes `%F`. A path, not `%U`: a `file://` address would be one more form for the program to read.
- Only `$XDG_CONFIG_HOME/mimeapps.list` is written. A `<desktop>-mimeapps.list` of the person's comes before it; the
  program does not edit one it did not write.
