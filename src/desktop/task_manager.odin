package tk_desktop

// The Task_Manager part's rules that hold on every system (src/md/features/default-task-manager.md): what the key of
// taskmgr.exe in Image File Execution Options holds after On and after Off. task_manager_windows.odin reads the key,
// applies these rules and writes the difference; the tests check the rules here, on every system.

import "core:strings"
import "../ascii"

// The command that makes the machine's change in a process that an administrator allowed: `<exe> --task-manager on`
// or `off` (setup.command_of reads it; desktop starts it with the verb runas).
TASK_MANAGER_FLAG :: "--task-manager"

// The parts that only an administrator can change, where the platform has them (admin_parts).
@(private)
ADMIN_PARTS :: Parts{.Task_Manager}

// A string value of the registry as it is stored: its text and whether it is REG_EXPAND_SZ.
Registry_String :: struct {
	value:   string,
	expand:  bool,
	present: bool,
}

// What the key Image File Execution Options\taskmgr.exe holds that the part reads and writes.
Image_Options :: struct {
	debugger: Registry_String,   // Debugger: what Windows starts in place of taskmgr.exe
	previous: Registry_String,   // <registry_mark>Previous: the Debugger there before the program's, given back by Off
	marked:   bool,              // <registry_mark> holds the AppUserModelID: the program wrote this key
}

// The key after On. `debugger` is the program's value (task_manager_debugger); `debugger_ours`: the Debugger there
// already runs the program's machine copy. Another program's Debugger (or the system's) is kept to give back; one of
// the program's (a copy moved since) keeps the one kept before it.
image_options_on :: proc(k: Image_Options, debugger: string, debugger_ours: bool) -> Image_Options {
	out := k
	if !debugger_ours && k.debugger.present && !ascii.equal_fold(k.debugger.value, debugger) { out.previous = k.debugger }
	out.debugger = {value = debugger, present = true}
	out.marked = true
	return out
}

// The key after Off: the Debugger kept is back (or none, when there was none), the marks gone. A Debugger that is not
// the program's (another program took the part after it) stays as it is.
image_options_off :: proc(k: Image_Options, debugger_ours: bool) -> Image_Options {
	out := Image_Options{debugger = k.debugger}
	if debugger_ours { out.debugger = k.previous }
	return out
}

// Where the machine copy is, under `program_files` (%ProgramFiles%; "" when Windows does not say): <vendor>\<name>\<exe>.
// machine_dir counts only with a test's key (image_options_root): a root comes from the environment, which the user
// writes (HKCU\Environment), and the elevated command must never point HKLM's Debugger at a folder the user can write.
@(private)
machine_copy_path :: proc(o: ^Integration_Options, program_files: string, allocator := context.temp_allocator) -> string {
	dir := o.machine_dir
	if o.image_options_root == "" {
		if program_files == "" { return "" }
		vendor := o.identity.vendor
		if vendor == "" || strings.contains_any(vendor, "\\/:*?\"<>|\x00") || strings.contains(vendor, "..") {
			dir = strings.concatenate({program_files, "\\", o.identity.name}, context.temp_allocator)
		} else {
			dir = strings.concatenate({program_files, "\\", vendor, "\\", o.identity.name}, context.temp_allocator)
		}
	}
	if dir == "" { return "" }
	return strings.concatenate({strings.trim_right(dir, "\\/"), "\\", exe_name_of(o.identity)}, allocator)
}

// An NT path ("\Device\HarddiskVolume3\...", GetMappedFileNameW's) as CreateFileW opens it: through the
// \\?\GLOBALROOT link of the object namespace ("" for anything else).
global_root_path :: proc(nt_path: string, allocator := context.temp_allocator) -> string {
	if !strings.has_prefix(nt_path, "\\") || strings.has_prefix(nt_path, "\\\\") { return "" }
	return strings.concatenate({"\\\\?\\GLOBALROOT", nt_path}, allocator)
}

// The Debugger's text for the machine copy: its path quoted (Program Files has a space; Windows adds taskmgr's path
// after it).
task_manager_debugger :: proc(machine_copy: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"\"", machine_copy, "\""}, allocator)
}
