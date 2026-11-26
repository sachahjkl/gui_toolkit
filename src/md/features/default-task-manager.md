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
- The key is in HKLM: an administrator must allow the write. The status is read without elevation: every user can
  read HKLM.

### The Debugger runs an install for everyone

The value is machine-wide: it runs for every account, the administrators included, and from Ctrl+Alt+Del. A Debugger
that runs a file the user can write lets any program of that user put its code where another account (an
administrator, elevated) runs it. That is a privilege escalation from the user to the administrator.

- Decided: the part exists only in an install for everyone ([install-scope.md](install-scope.md)). That install is
  in Program Files, where only an administrator writes, and the Debugger runs it. The part is in the machine half of the
  install: the elevated verb writes it with the files, the menu and the record, in one prompt.
- Refused (0.360.0's design, replaced): a machine copy in Program Files beside a user install, which handed over to
  the person's copy when it started unelevated. It was a second install that nobody updated, at the very place where an
  install for everyone goes; it needed its own elevated verb, its own record of the account that set it, and a hand-off.
- Refused: the Debugger on a user install, with a warning. System Informer warns when it is outside Program Files;
  Process Explorer does nothing. With a user install the warning is always shown, so it protects nothing.
- For an administrator, taskmgr.exe auto-elevates: Ctrl+Shift+Esc starts the program elevated, with no prompt. That
  process is the whole program, so it is restricted as every elevated program
  ([elevated-process.md](elevated-process.md)): it starts, installs, updates and loads nothing that a user can write,
  and its title says "(Administrator)".
- The elevated verb reads no folder from the environment: a user writes `HKCU\Environment`, which an elevated process
  reads, and HKLM's Debugger must never name a folder that the user can write. In a restricted process the machine's
  places are the system's own (`machine_root_of`).
- Off gives back the Debugger that was there before, exactly (its text and its kind, `REG_SZ` or `REG_EXPAND_SZ`).
  `<registry_mark>Previous` keeps it in the same key, and `<registry_mark>` (the AppUserModelID) marks the key as
  the program's. Off does not touch a Debugger that another program set after ours: only the marks go.
- An Uninstall gives Task Manager back first, in the machine half. If the person declines, nothing is removed.
- The rules on the values are pure (`image_options_on`, `image_options_off` in task_manager.odin) and tested on
  every system. task_manager_windows.odin reads and writes the key.
- The key is the machine's and so is the install: an uninstall takes the part away for every account.

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
