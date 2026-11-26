# The default task manager

A task manager made with the toolkit can take the place of the system's: on Windows, Ctrl+Shift+Esc, the taskbar's
"Task Manager" and the one of Ctrl+Alt+Del open it. The option is `Part.Task_Manager` of gt:desktop. A program says that
it is a task manager by offering the part as a setup `Choice`. The how-to is in
[docs/desktop.md](../../../docs/desktop.md#the-default-task-manager); this file keeps the reasons.

## A part read from the system

As for the [file manager](default-file-manager.md), the state is the system's and is read each time: no flag of the
program's own. The box of the install starts from `Facts.parts`.

## Windows: the Debugger of Image File Execution Options

- Ctrl+Shift+Esc, the taskbar and Ctrl+Alt+Del start `taskmgr.exe`. No association names it: the only hook is
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\taskmgr.exe`, value `Debugger`.
  Windows then starts the Debugger's command with taskmgr's path and taskmgr's own options after it. Process Explorer
  and System Informer use this value.
- The key is in HKLM: an administrator must allow the write. The install never elevates by itself. When the box is
  ticked, Install starts `"<installed exe>" --task-manager on` with the verb `runas`. Windows shows its consent
  prompt, and the dialog says under the box why it comes. Off and Uninstall start `--task-manager off` the same way,
  from the machine copy when it is there: the prompt then names a file of Program Files, and no file that the user can
  write runs elevated.
- The elevated command reads no folder from the environment: `machine_dir` counts only with a test's key
  (`image_options_root`, under HKCU). A user writes `HKCU\Environment`, which an elevated process reads, and HKLM's
  Debugger must never name a folder that the user can write (`machine_copy_path`).
- An automatic path never asks, and the elevated command is not a door: its arguments are `on` or `off` alone, and
  its roots come from the environment only with a test's key under HKCU (`machine_dir` alone never moves the copy:
  the environment is the user's to set).
- An automatic path never asks: `Integration_Options.ask_administrator` is set only by setup's Install and Uninstall
  (a person's click or command). `desktop.apply` at a start leaves the part as it is.
- The status is read without elevation: every user can read HKLM.

### The Debugger runs a copy in Program Files

The value is machine-wide: it runs for every account, the administrators included, and from Ctrl+Alt+Del. The installed
copy is in `%LOCALAPPDATA%\Programs`, which the user and every program of the user can write. A Debugger that runs it
lets any program of that user put its code where another account (an administrator, elevated) runs it. That is a
privilege escalation from the user to the administrator.

- Decided: the elevated verb copies the installed program into `%ProgramFiles%\<vendor>\<name>\` (the machine copy),
  where only an administrator can write, and the Debugger runs that copy.
- The machine copy hands over to the person's own installed copy when it starts unelevated (setup's
  `task_manager_start`): the person gets the copy that their updates keep current, and that code runs with the rights
  it already had. Elevated, or for an account with no install, the machine copy runs itself: only code that an
  administrator placed runs with more rights than its owner.
- For an administrator, taskmgr.exe auto-elevates: Ctrl+Shift+Esc starts the machine copy elevated, with no prompt.
  That process is the whole program, so it is restricted as every elevated program
  ([elevated-process.md](elevated-process.md)): it starts, installs, updates and loads nothing that a user can write,
  and its title says "(Administrator)". Unelevated, the machine copy has the user's own token and is not restricted;
  it only never installs itself into the user's folder. Without this, its Install or "Open the installed copy" would run the
  user-writable copy with the administrator's token: a lasting UAC bypass for any program that replaces that file.
- So an update of the installed copy needs no administrator. Install or Repair refreshes the machine copy only when it
  is missing or when the Debugger runs something else.
- Refused: the Debugger on the installed copy, with a warning. System Informer warns when it is outside Program Files;
  Process Explorer does nothing. With a per-user install the warning is always shown, so it protects nothing.
- Refused: no part on a per-user install. The install is per-user by design, so the box could never be used.
- Off gives back the Debugger that was there before, exactly (its text and its kind, `REG_SZ` or `REG_EXPAND_SZ`).
  `<registry_mark>Previous` keeps it in the same key, and `<registry_mark>` (the AppUserModelID) marks the key as
  the program's. Off does not touch a Debugger that another program set after ours: only the marks go.
- On copies the image of the elevated process itself, not the file at a path: after the consent, a user can rename
  the running file and put another at its path. The image's current name (GetMappedFileNameW, which follows a
  rename) is opened with no write and no delete sharing; the name read again being the same proves that the handle
  is the image's file, which can no longer move. Refused: a hash from the signed update manifest. A development
  build has none, and the handle gives the same proof with no network.
- Off runs the machine copy elevated, never the user's copy: the consent prompt names a file of Program Files.
- This account's record: `TaskManagerSetHere` in HKCU (`Software\<vendor_key>\<key>`), written once On succeeded and
  taken by Off. An Uninstall asks an administrator only when this account put the part. Another account's part stays,
  and nothing is asked. Unticking the box is an explicit request, and asks whoever put the part.
- An Uninstall gives Task Manager back first. If the person declines, or the change fails, nothing else is removed,
  the install stays whole, and the dialog says so. Without this, the files would be gone while the Debugger stays.
- The rules on the values are pure (`image_options_on`, `image_options_off` in task_manager.odin) and tested on
  every system. task_manager_windows.odin reads, writes and copies.
- The key is the machine's: an account that uninstalls takes the part away for every account. Its box shows the part
  when another account's install set it.
- A machine copy that runs when Off or a refresh comes (another account's Task Manager, or the copy that runs Off)
  cannot be deleted: it is renamed to a name of its own beside it, which goes at the next restart
  (`MOVEFILE_DELAY_UNTIL_REBOOT`). A restart deletes a name, not a file: had the copy's own name waited for it, an On
  before the restart would lose its new copy.

### The command line that Windows gives

The Debugger receives `<taskmgr path> [taskmgr's options]` ("/4", "/7 /startup"), as the starter wrote it: cmd's
`taskmgr` gives `taskmgr`, with no path nor ".exe". `setup.task_manager_start` takes them
away, and the program starts as from its menu: those options are taskmgr's, not the program's.

## Linux: no part

Linux has no system task manager and no shortcut that the system owns. KDE binds Ctrl+Esc to its System Monitor in
`kglobalshortcutsrc`, GNOME ships System Monitor with no key, and a compositor such as ShojiWM has its own key bindings.
Each is another file format and another owner. A lowest common denominator (a desktop entry, or a key in one desktop)
would claim a part that the other desktops do not have. So `Task_Manager` is not in the Linux backend's parts, and a
program shows the box only where `supported_parts()` has it.
