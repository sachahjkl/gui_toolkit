package tk_setup

// A program in place of the system's task manager (desktop's Part.Task_Manager, src/md/features/default-task-manager.md)
// starts from the Debugger of taskmgr.exe: Windows gives it taskmgr's path, then taskmgr's options. The Debugger runs
// the machine copy (Program Files), which hands over to the person's own install when it may, and else runs restricted
// (base.restricted: src/md/features/elevated-process.md).

import "core:os"
import "core:strings"
import ascii "../ascii"
import base "../base"
import desktop "../desktop"
import process "../process"

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

// The first call of the program, before anything else (its window, its settings, program_start): the arguments
// without taskmgr's (task_manager_arguments), and whether this start was handed over to the person's own installed
// copy (the program then ends at once).
//   - A start from taskmgr's Debugger that is not elevated hands over when the person has an install that is not this
//     copy: their updates keep that copy current, and it runs with the rights it already had.
//   - Elevated, the program is restricted (base.restrict_if_elevated, fail closed): an administrator's Ctrl+Shift+Esc
//     starts the machine copy elevated with no prompt. Unelevated, the machine copy has the user's own token and runs
//     as any program of theirs; it never installs itself into their folder (Facts.machine_copy).
// Reads the registry: before the window, never from a frame.
task_manager_start :: proc(o: Setup_Options, args: []string) -> (rest: []string, handed_off: bool) {
	base.dll_search_restrict()
	base.restrict_if_elevated()
	from: bool
	rest, from = task_manager_arguments(args)
	integration, recorded := options(o)
	running := process.executable_path()
	if from && !base.elevated() && recorded {
		exe := join({integration.install_dir, desktop.exe_name_of(integration.identity)})
		// (this process has the user's own token: their copy runs with nothing more than it had)
		if os.is_file(exe) && !desktop.same_path(exe, running) && launch(exe) { return rest, true }
	}
	return rest, false
}
