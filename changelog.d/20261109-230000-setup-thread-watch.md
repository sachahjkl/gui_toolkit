type: Changed

**`setup`**: the dialog does its work on a thread of its own and follows the disk while it is open.
  - Reading the state, Install, Uninstall and the folder picker run on the dialog's thread, one at a time; the dialog says "Working…" and its buttons wait; the end of the work and a change seen by the watcher wake the program (`ui.post` to the State of the dialog's last frame). `setup.dialog` is called every frame, open or not.
  - While open, the places of the install are watched (`desktop.watch_start`): a change made elsewhere is read again at once; `setup.stale` lets the program ask for it too.
  - `Config.choices`: the program's own options of an install, shown as boxes; `Config.prepare` receives their values (`prepare(o, choices, user)`) and is called before anything is read or written, so a test can point every place at a folder of its own.
  - `Config.folder`: the user may choose the install folder before the first install (`install(c, shortcut, choices, folder)`; checked with `desktop.check_install_dir`).
  - Uninstall asks for a second click. A newer installed copy is named as such (`is_downgrade`: "Go back to <version>").
