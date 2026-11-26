# An install for me, or for everyone

A program installs itself from its own download (gt:setup over gt:desktop). Until now that install was the person's
alone: their profile, their menu, no administrator. The scope adds a second place: the computer, for every account,
which an administrator allows. The how-to is in [docs/setup.md](../../../docs/setup.md#for-me-or-for-everyone) and
[docs/desktop.md](../../../docs/desktop.md#the-scope-of-an-install).

## The two scopes

`desktop.Scope` is `User` or `System`. Each system has its own places; nothing is a common ground.

| | Windows, `User` | Windows, `System` | Linux, `User` | Linux, `System` |
|---|---|---|---|---|
| The program | `%LOCALAPPDATA%\Programs\<vendor_key>\<name>` | `%ProgramFiles%\<vendor>\<name>` (known folder) | `~/.local/opt/<vendor_key>/<name>` | `/opt/<vendor_key>/<name>` |
| The menu | the user's Start menu | the Start menu of every account (`FOLDERID_CommonPrograms`) | `~/.local/share/applications` | `/usr/local/share/applications` |
| The record | `HKCU\...\Uninstall\<key>` | `HKLM\...\Uninstall\<key>` | the manifest | the manifest |
| The PATH | `HKCU\Environment`, the console launcher beside the program | `HKLM\SYSTEM\...\Session Manager\Environment`, the launcher beside the program | a link in `~/.local/bin` | a link in `/usr/local/bin` |
| Documents, browser, thumbnails | HKCU's classes | HKLM's classes | the entry, `~/.local/share/thumbnailers` | the entry, `/usr/local/share/thumbnailers` |
| Task Manager | not offered | the Debugger runs the installed program | no part | no part |
| Elevation | none | the consent prompt, one verb | none | `pkexec`, one verb |
| Updates | the updater places them | an administrator allows each one | the updater places them | an administrator allows each one |
| NixOS | | | an install that runs by itself | not offered: the Nix package is the install for everyone |

## Two halves

A system install has a machine half and a user half. The machine half is what every account shares: the files, the
record, the menu entry, the PATH, the documents' and the browser's registration, the thumbnailer, Task Manager
(`desktop.machine_parts()`). The user half is each person's: the desktop shortcut, the start with the session, the
default file manager, the default documents (Linux). An account that did not install keeps its own choices for the user
half, against the same program.

- `Integration_Options.scope` says where; `machine_half` says which half a call writes. `desktop.install` and `remove`
  touch only the parts of their half and leave the others as they are. `status` reads both halves and merges them.
- The machine half is written by an elevated process: `<exe> --system install <choices>` or `--system uninstall`
  (`setup.command_run`). Its arguments are a closed set: a word, then one `0` or `1` per box of `Setup_Options.choices`.
  It reads no path, so it is not a door.
- The user half is written after, by the person's own process, against the installed program.

## The elevated verb

- One prompt per action. Install, a change of the boxes of the machine half, and Uninstall each start the verb once.
- Windows: `ShellExecuteExW` with `runas` on this program, as `--task-manager` did. Linux: `pkexec <this program>`
  (polkit's default action asks for an administrator's password). Refused: `sudo` in a graphical program (it needs a
  terminal and keeps the user's environment), and a `.policy` file of our own (it needs a file in `/usr/share/polkit-1`
  before the first install).
- The verb copies the image of its own process, never a file at a path: after the consent, a user can put another file
  at the path that was allowed (Windows: `image_copy_self`; Linux: `/proc/self/exe`, which is the inode that runs).
- In a real elevated process the machine places are the system's own, whatever the options say. A root comes from the
  environment, and the user writes the environment (`HKCU\Environment`, `sudo -E`). Only a process that is not
  restricted (a test) uses `machine_root` and `machine_registry_root`.
- The process is restricted (`base.restrict_if_elevated`, [elevated-process.md](elevated-process.md)). The machine half
  starts nothing that a user can write, so it is allowed there: `desktop.machine_install` and `machine_remove` do not
  ask `restricted`. Nothing else of the toolkit runs in it. Its one program is Linux's `update-desktop-database`,
  which `process.start` takes only from the system's folders (pkexec's PATH is the system's).
- Linux: the verb refuses a folder that it writes in, or one above it, that is not root's or that a group or others can
  write: `/opt`, `/opt/<vendor_key>`, the program's folder, and the folders of `/usr/local` (`share/applications`,
  `share/icons/hicolor`, `share/thumbnailers`, `bin`). Else a user who made `/opt/<vendor_key>` first would own the
  program that every account runs, and a link put in a folder that root writes would lead root's write elsewhere.
- A link of root's is followed, and the folder it leads to is checked the same way, each folder above it too: Fedora
  Atomic's `/opt` is a link to `/var/opt`. A link of a user's is refused, whatever it leads to.
- Refused: a group-writable `/usr/local` (Debian's `staff` before 2017). That group is root's equal there, but the
  check cannot tell such a group from any other; the verb says which folder, and an administrator fixes its rights.
- Uninstall checks the same folders before it deletes: root deletes what the manifest of the program's folder names,
  and a link that a user put in that folder would lead the deletions elsewhere.
- Uninstall starts the verb from the installed program: the prompt names a file of Program Files or `/opt`. Install,
  and the Uninstall of a broken install whose program is gone, start it from the copy that runs, the download: that is
  the trust of any installer. Residual risk: a program of the
  user that changes the downloaded file between the click and the consent. And on Windows, a library put beside the
  download: Windows loads the libraries that the program imports from its own folder first, before
  `dll_search_restrict` runs (ROADMAP: `/DEPENDENTLOADFLAG`).

## Moving from one scope to the other

There is one install at a time. Install in the other scope is a move: the new scope first, then the old one goes.

- User to system: the verb installs the machine half (one prompt), the user half follows, then the person's own copy
  is uninstalled (no prompt).
- System to user: the person's copy is installed, then the verb uninstalls the machine half (one prompt, from the
  installed program). Declined: two copies stay, `Facts.other_scope` says so, and the dialog offers to remove the other.
- Refused: two installs on purpose. The menu would list the program twice, the PATH would hold two folders, and the
  updates would reach one of them.
- The person's half has the same names in both scopes (the desktop shortcut, the start with the session, the default
  file manager and documents: one slug, one key). The removal of the old scope takes them, though the new install has
  just written them. So the move writes the person's half of the new scope again, last.
- Windows: a move from the person's copy that runs leaves its files, which cannot be deleted while it runs; they go
  when this process ends (`cleanup_later`), as an Uninstall's.
- Another account can move too: its "Only me" over an install for everyone removes that install for every account,
  once an administrator allows it. Accepted: the administrator's prompt is the guard, and it names the uninstall.

## Updates

The updater runs as the person, and cannot write Program Files or `/opt`.

- Decided: an elevated step per update. The updater downloads and checks as now, in the person's folders. "Restart to
  update" then starts `<installed program> --system update <file>` elevated: the installed program is the trusted one,
  and it checks the file's signature again with the key it was built with before it places it. The person sees one
  prompt per update.
- Refused: a service or a scheduled task that runs as SYSTEM or root and updates in the background. It downloads and
  parses from the network with every right, every day, for every account; and a request from a user to it is a door
  that a task with the highest rights keeps open. A fleet that needs silent updates uses its own tool (Intune, a Nix
  configuration).
- Not in this first version: the step is designed, not written (ROADMAP). Until it is, the updater of a system install
  is `Administered`: it checks and downloads nothing, writes nothing beside the program, and says that an
  administrator updates it. `setup.updated` refuses such an install.
- The updater knows this by the folder, not by the scope: the program's folder takes no file from this process
  (`access` on Linux; on Windows the folder opened for the right to add a file, which the access list grants or
  refuses). Nothing is written to find it out. Refused: the scope read from setup's facts. gt:update does not depend on
  gt:setup, and a copy in any folder that its account cannot write has the same answer: no update can be placed there.

## Uninstall on Windows

The elevated verb runs from the installed program, so its own file cannot be deleted while it works. `files_remove`
renames it to `.old` and the verb asks Windows to delete it at the next restart (`MOVEFILE_DELAY_UNTIL_REBOOT`).
A restart deletes a name: the `.old` name keeps a new install before the restart safe. The person's helper
(`cleanup_later`) cannot delete a file of Program Files, so no leftover goes to it. The dialog says "deleted at the next
restart" (`Facts.at_restart`), never "when this window closes".

## Task Manager needs the system scope

The Debugger of taskmgr.exe is the machine's, for every account. A Debugger that runs a file the user can write is an
escalation ([default-task-manager.md](default-task-manager.md)). 0.360.0 made a machine copy in Program Files for that.
A system install is in Program Files already, so the Debugger runs it.

- Decided: `Part.Task_Manager` is a part of the system scope only. Under "Only me" its box is off and says why. The
  machine copy, its hand-off to the person's copy, `Facts.machine_copy` and `--task-manager` are gone.
- Refused: keeping the machine copy for a user install. It is a second install that nobody updates, at the very place
  where a system install goes.

## Accounts

- Another account sees the install as installed (the record is HKLM's, the manifest is the machine's). Its own part is
  the user half: its boxes, its shortcut.
- A standard user may uninstall: the verb asks for an administrator (Windows shows the credentials prompt; polkit asks
  for an administrator's password). Without one, nothing goes, and the dialog says so.
- The settings of a person stay per person: an uninstall leaves each account's settings and data, as before.
- What another account wrote for its user half (its autostart value, its desktop shortcut) is not reachable from the
  account that uninstalls. It runs a program that is gone. Accepted: it is the same for every installer of Windows.

## The choice in the dialog and the page

"Install for", then two radios: "Only me" and "Everyone on this computer" (French: "Installer pour", "Moi seul", "Tous les
comptes de cet ordinateur"). Under each, one line says what it means on this system: where the program goes, and who
allows it. The person compares the two before choosing, so both lines are always shown. The section comes before the
install location and the options, and only when there is something to install.

- Refused: a segmented control. It cannot grey one choice alone, and a greyed control made "Only me" unreadable.
- Install in the other scope than the install that is there is a move: the button says "Install for everyone" or
  "Install for me only", and the line under the choice says that the other copy goes.
- The button that asks an administrator has a shield, as Windows marks such buttons.

## When "Everyone" cannot be offered

`desktop.system_refusal(o)` says why. The radio "Everyone on this computer" is then greyed, and the reason is in place of
its line:

- `Nix`: NixOS. The Nix package in the system's configuration is the install for every account.
- `No_Elevation`: Windows, a standard account whose prompts are refused by policy (`ConsentPromptBehaviorUser` 0, or UAC
  off); Linux, no `pkexec` in the system's folders.
- `Unsupported`: a system without a backend.

A Linux session without a polkit agent shows no prompt: `pkexec` ends with 127, and the dialog says that no
administrator could be asked.

An elevated process still offers nothing ([elevated-process.md](elevated-process.md)): no switch, no button.

## The API

- `Setup_Options.scopes`: the scopes a program offers. `{}` is every scope that this system has. A program that must
  stay per user gives `{.User}`. Most programs change nothing.
- `Facts.scope`: the scope of the install that is there (else the one asked); `Facts.other_scope`: an install of the
  other scope is there too; `Facts.system_refusal`.
- `Dialog.scope`: the scope chosen, from the facts when they first come.
- `install(o, shortcut, choices, folder, scope)`; `uninstall(o, choices)` takes the install that is there.
- The folder field exists only for `User`. A system install goes to its system's place: a folder chosen by a person can
  be one that a user writes.
