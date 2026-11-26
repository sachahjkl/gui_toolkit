type: Added

**`desktop.Part.Task_Manager`**: on Windows, a program can take the place of Task Manager (Ctrl+Shift+Esc, the taskbar, Ctrl+Alt+Del) with `Integration_Options.task_manager`, offered as a setup box tied to the part.
  - The Debugger of `taskmgr.exe` runs a copy of the program in Program Files, which only an administrator can write: the image of the elevated process itself, held open while it is copied. That copy hands over to the person's own install when it is not elevated (`setup.task_manager_start`), so updates need no administrator.
  - Install and Uninstall ask Windows for an administrator (`--task-manager on|off` with `runas`), and only when a person asked (`ask_administrator`); the box says why. Off gives back the Debugger that was there before, exactly.
  - An Uninstall gives Task Manager back only when this account put it, and first: declined or failed, nothing is uninstalled.
  - Linux has no such part.
