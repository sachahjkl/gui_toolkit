# A program's updates

`gt:update`'s Updater checks, downloads and places a release. Around it, five programs wrote the same glue:
the same `updater_start` options, the rule of `update.auto`, the serial compare, and a call of `setup.updated` on a worker,
written four ways. `prefs_page.Updates` is that glue; a program keeps its words (`update.notice` in its status line or a
toast) and its restart (when and how it gives way to the new copy differs in each).

## Why in prefs_page and not in update

`update` is imported by the release tools (`toolbox`, `release`), which have no window. The glue needs `setup` (the
installed manifest), `config` (the standard Updates set), `ui` (a chore) and the `Install` of the install page: all of
them are `prefs_page`'s already, and `update` stays a package with no interface.

## Decisions

- **The rule of update.auto is read at each follow, not pushed by the program.** It is the preference and
  `Install.known && Install.running_it`. Each program called its `updates_auto` from three places (the start, the
  preference's change, the end of the install's reading) and one forgot a place. A map lookup and two fields a frame
  cost nothing; `set_auto` is called only when the mode changes.
- **The manifest is written on a chore of the window's State (`ui.task`).** Not on the updater's thread: a hook there
  would run either under the updater's lock (the interface's `status` would wait on a disk write) or after
  `updater_stop` returned (its data freed). The chore's data is a copy: the setup's options are constants, the version
  is cloned.
- **The manifest is written once per version** (`Updates.manifest`): a later change of the serial with the same
  version installed writes nothing again.
- **The folder** is `update.base_url` when set, else `update.latest_release_folder(repository)`: the `UPDATE_FOLDER`
  string every program wrote from its repository's name.
- **The news** wakes one window by default. A program with several windows (cliche) gives its own `news`.
- **Channels** (opencode native's): `Updates_Options.channels` gives each channel's folder; the followed one is
  `update.channel`'s, read at the start and followed at each change (`update.set_channel`), as the mode is. With no
  `update.base_url`, the folder is each channel's own.
- **The running program's path is found on the updater's thread** (`Updater_Options.exe` ""): `updates_start` runs on
  the interface's thread, which makes no system call, not even the `readlink` of `/proc/self/exe`. A copy in the Nix
  store is found there too and says `Managed`.

- **A product that changes its name** keeps its earlier feed, so an install several versions late still arrives:
  [identity-change.md](identity-change.md#the-updates-of-an-install-several-versions-late).

## Refused

- `update.app_start` in `gt:update`: it would pull `setup`, `config` and `ui` into the release tools.
- A settle in `updates_follow`: which window shows the change is the program's (cliche's settings are in a window that
  may be hidden); `changed` says when, and `host.host_settle` does it.
