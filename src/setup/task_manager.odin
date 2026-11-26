package tk_setup

// A program in place of the system's task manager (desktop's Part.Task_Manager, src/md/features/default-task-manager.md)
// starts from the Debugger of taskmgr.exe: Windows gives it taskmgr's path, then taskmgr's options. The Debugger runs the
// program of an install for everyone (Program Files), restricted when it runs elevated (base.restricted:
// src/md/features/elevated-process.md).

import "core:strings"
import ascii "../ascii"
import base "../base"

// The arguments without what Windows gives a task manager's replacement: taskmgr's path first, then its own options
// ("/4", "/7 /startup"), which mean nothing to the program. `from_task_manager`: they were there. Windows gives the
// command line as the starter wrote it: cmd's `taskmgr` comes without its path nor ".exe".
task_manager_arguments :: proc(args: []string) -> (rest: []string, from_task_manager: bool) {
	if len(args) == 0 { return args, false }
	first := args[0]
	slash := max(strings.last_index_byte(first, '\\'), strings.last_index_byte(first, '/'))
	name := first[slash + 1:]
	if !ascii.equal_fold(name, "taskmgr.exe") && !ascii.equal_fold(name, "taskmgr") { return args, false }
	return nil, true
}

// The first call of a task manager, before anything else (its window, its settings, program_start): the arguments
// without taskmgr's (task_manager_arguments). Elevated, the program is restricted first (base.restrict_if_elevated,
// fail closed): an administrator's Ctrl+Shift+Esc starts it elevated with no prompt.
task_manager_start :: proc(args: []string) -> []string {
	base.dll_search_restrict()
	base.restrict_if_elevated()
	rest, _ := task_manager_arguments(args)
	return rest
}
