package tk_desktop

// The Task_Manager part's rules that hold on every system (src/md/features/default-task-manager.md): what the key of
// taskmgr.exe in Image File Execution Options holds after On and after Off. task_manager_windows.odin reads the key,
// applies these rules and writes the difference; the tests check the rules here, on every system.

import "core:strings"
import "../ascii"

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
// already runs the installed program. Another program's Debugger (or the system's) is kept to give back; one of
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

// An NT path ("\Device\HarddiskVolume3\...", GetMappedFileNameW's) as CreateFileW opens it: through the
// \\?\GLOBALROOT link of the object namespace ("" for anything else).
global_root_path :: proc(nt_path: string, allocator := context.temp_allocator) -> string {
	if !strings.has_prefix(nt_path, "\\") || strings.has_prefix(nt_path, "\\\\") { return "" }
	return strings.concatenate({"\\\\?\\GLOBALROOT", nt_path}, allocator)
}

// The Debugger's text for the installed program: its path quoted (Program Files has a space; Windows adds taskmgr's
// path after it).
task_manager_debugger :: proc(program: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"\"", program, "\""}, allocator)
}
