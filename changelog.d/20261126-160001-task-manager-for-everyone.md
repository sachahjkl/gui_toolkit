type: Changed

**Task Manager needs an install for everyone**: the Debugger of taskmgr.exe now runs the program installed in Program
Files, and the box "in place of Task Manager" is off under "Only me", with the reason. The machine copy beside a user
install, its hand-off, `Facts.machine_copy` and `--task-manager on|off` are gone; the elevated verb is
`--system install|uninstall`. `setup.task_manager_start(args)` now returns the arguments alone.
