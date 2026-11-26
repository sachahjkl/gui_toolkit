# A process with more rights than its user's files

A program made with the toolkit can run with an administrator's rights: started elevated by a person, or by Windows
when taskmgr.exe auto-elevates for an administrator and its Debugger is a task manager installed for everyone
([default-task-manager.md](default-task-manager.md)), or as the elevated verb of an install for everyone
([install-scope.md](install-scope.md)). Such a process must never run code that a process of lower
rights can change. Else any medium-integrity program writes a file where the elevated one later runs it, and the
user's account becomes the administrator's without a prompt. The how-to is in [docs/base.md](../../../docs/base.md#restricted-processes).

## One rule, in the toolkit

`base.restricted()` is true in a program that is elevated (an administrator's token on Windows, root on Linux). Every place of
the toolkit that starts, opens, installs, updates or loads something asks it, so no program can forget it:

| Place | In a restricted process |
|---|---|
| `process.start` (and every launch over it: setup.launch, host's restart, prefs_page.install_launch) | only a full path in an administrator's folder (`trusted_program`); else `Permission_Denied` |
| `platform.open_url`, `open_path`, `reveal_in_folder` | refused: a URL's, a file's or a folder's handler is the user's to change (a default file manager in HKCU is one); `ui.open` and "Open with" show a toast that says why |
| `desktop.open_terminal`, `open_with`, `cleanup_later` | refused |
| the shell's context menu (`desktop.context_menu_invoke`) | refused, a toast says why: an item runs a verb of HKCU or a service menu of the user's folders |
| Settings' page of default apps (`ms-settings:`) | refused: HKCU can take over a protocol, and `ms-settings:` from an elevated process is the fodhelper bypass of UAC |
| Linux: `platform.launch_detached`, the file dialogs' helpers | a name is looked for in the system's folders only, never on the PATH (sudo -E keeps the user's) |
| `desktop.install`, `remove` | `Error.Restricted`; `apply` does nothing |
| `setup.install`, `uninstall`, `updated`, `wanted`, the dialog and the page | refused, never offered; the page says why (`restricted_words`) |
| `update`: the Updater, `place` | phase `Refused`, nothing checked or downloaded; `place` returns `Refused` |
| plugins | none read nor run; a toast says why |
| devtools | no server: its port takes commands from any program of the user, and `TOOLKIT_DEVTOOLS` is the user's to set |
| instance (Windows) | the message filter stays the default: a process of lower integrity cannot send it a command |
| the window's title (Windows) | "(Administrator)" after it: the person knows which window acts with those rights |

- File dialogs stay: the person chooses a file, and the program reads or writes it as data.
- What a program does itself (its own system calls) is its own: the rule covers what goes through the toolkit.

## Decisions

- **A program says it at its start.** Elevation restricts a process once it calls `base.restrict_if_elevated`:
  `host.program_start`, `setup.command_run` and `setup.task_manager_start` do it first. A command-line tool made with
  the toolkit (tk, run_tests, a program's tool) does not: it runs what the person typed, as any command of an
  administrator's console or of root does. Restricting every process broke them where they always run elevated: a
  Windows CI runner is an administrator, and the Pages build runs as root in a container (bare `odin`, `cwebp`).

- **Fail closed.** A token that cannot be read counts as elevated: a doubt never hands the process's rights to the
  user's code.
- **The elevated verb of an install for everyone writes in a restricted process.** It starts nothing that a user can
  write (Linux's `update-desktop-database` comes from the system's folders, through `process.start`'s rule): it copies
  its own image and writes the machine's places, which are then the system's own whatever the options and the
  environment say. `desktop.machine_install` and `machine_remove` are the only writes allowed there.
- **The refusals say this system's words.** "As administrator" on Windows, "as root" on Linux, whole sentences in
  `base.restricted_words` (trust_words_<os>.odin), translated as such: a language puts those words where its grammar
  wants them.
- **Trusted folders by path.** A file directly in System32 or SysWOW64, or in System32's WindowsPowerShell\v1.0,
  anything under Program Files and Program Files (x86). System32, SysWOW64 and the Windows
  folder come from the kernel (GetSystemDirectoryW), not from a variable of the environment. Program Files comes from
  the known-folder API: a Windows run must still show that a `ProgramFiles` in `HKCU\Environment` does not move it.
  Refused: System32's subfolders minus a list of the writable ones (spool\drivers\color, Tasks, com\dmp, FxsTmp...).
  SysWOW64 has the same writable folders, and a list is bypassed by an 8.3 name (`TASKS_~1`) or a stream
  (`Tasks::$INDEX_ALLOCATION`). No user creates a file directly in System32. A `:` after the drive is refused: a
  stream is not the file that its name shows. A bare name is never trusted:
  its search goes through the working folder and the user's PATH. Refused: an ACL check of each folder. It is long to
  do right (inheritance, groups, deny entries), and the folders above are the system's by design. Residual risk: a
  folder of Program Files that an installer opened to users.
- **The program, not its arguments.** A trusted program is trusted with any argument: cmd.exe or powershell.exe given
  a script of the user's runs it. No place of the toolkit does that in a restricted process (the terminal is refused).
  Refused: explorer.exe as a trusted program. No place starts it through `process.start`, and given a file it runs
  the file's handler.
- **Libraries.** `base.dll_search_restrict` (SetDefaultDllDirectories: the program's folder and System32) is the first
  call of `host.program_start`, `setup.command_run` and `setup.task_manager_start`. A library loaded by name later
  never comes from the working folder or the PATH. The program's folder stays: a program that ships a library beside
  it needs it, and for an install for everyone that folder is Program Files.
- **Tests.** CI runners run as administrator. A test build (`ODIN_TEST`), or a build with
  `-define:GT_ELEVATED_UNRESTRICTED=true` for such a runner (tk's builds with the devtools endpoint, which a tool drives),
  is not restricted by its elevation alone. The toolbox's `build release` refuses that define: a release never has it. An explicit
  `restrict` counts in every build: tests/restricted restricts its own process and checks each place above.
- **Nothing lifts it.** `restrict` keeps the first reason. A process that became restricted stays so.
- **Later: a de-elevated start** (ROADMAP). On Windows an elevated program can ask Explorer's shell, at medium
  integrity, to open a URL, a file or a terminal with the person's own token (`IShellDispatch2::ShellExecute`), so an
  administrator's elevated classeur keeps Open, Open with and the terminal. Linux has no such way for root: no process
  of the user's session takes requests from root, and `sudo -u` from root would trust the user's environment.
