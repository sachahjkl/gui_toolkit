type: Added

**A program's start, its updates and its vendor mark in the toolkit**: the lines every program wrote around them are calls now.
  - `host.program_start({name, folder, version}) -> Program` opens the log, installs the crash handler, begins the session and reads the last report, in that order (`Program.logger`, `Program.last_crash`); `host.program_end(&p)` is the clean end.
  - A window owes `host.AFTER_INPUT` (3) frames after an event by default (`Host.after_input`, when the program set no count), and `host.host_settle(h)` owes them after a change that came with no event: a program drops its `FRAMES_AFTER_INPUT`.
  - `prefs_page.updates_start`, `updates_follow` and `updates_stop` run a program's Updater: the folder from `update.base_url` or the repository's latest release (`update.latest_release_folder`), `update.auto` for the installed copy only, followed with no call of the program, and the installed copy's manifest written on a chore. `updates_follow` says when to show the change (`update.notice`); the restart stays the program's.
  - `prefs_page.install_vendor_mark(&install, &renderer, png)` makes the "By" line's mark once; `install_end` frees it.
