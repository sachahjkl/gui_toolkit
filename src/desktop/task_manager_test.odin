package tk_desktop

import "core:strings"
import "core:testing"

// The part is the machine's where it exists (Windows), and Linux has none: no box that claims half of it.
@(test)
task_manager_is_an_administrator_part :: proc(t: ^testing.T) {
	testing.expect(t, .Task_Manager not_in supported_parts() || .Task_Manager in admin_parts(), "the machine's: an administrator allows it")
	when ODIN_OS == .Linux { testing.expect(t, .Task_Manager not_in supported_parts(), "Linux has no system task manager") }
	when ODIN_OS == .Windows { testing.expect(t, .Task_Manager in supported_parts(), "Windows has the part") }
}

// The rules of the key of taskmgr.exe (task_manager.odin): what On keeps to give back, what Off gives back.
// GetMappedFileNameW's NT name, opened through GLOBALROOT; nothing else is made into one.
@(test)
task_manager_global_root_path :: proc(t: ^testing.T) {
	testing.expect_value(t, global_root_path(`\Device\HarddiskVolume3\Users\me\a.exe`), `\\?\GLOBALROOT\Device\HarddiskVolume3\Users\me\a.exe`)
	testing.expect_value(t, global_root_path(`C:\Users\me\a.exe`), "")
	testing.expect_value(t, global_root_path(`\\server\share\a.exe`), "")
	testing.expect_value(t, global_root_path(""), "")
}

@(test)
task_manager_on_keeps_the_debugger_before :: proc(t: ^testing.T) {
	ours := task_manager_debugger(`C:\Program Files\Froment Software\Sample\sample.exe`)
	testing.expect_value(t, ours, `"C:\Program Files\Froment Software\Sample\sample.exe"`)

	// nothing before: nothing kept
	k := image_options_on({}, ours, false)
	testing.expect(t, k.marked && k.debugger.present && !k.debugger.expand, "the Debugger is the program's, marked")
	testing.expect_value(t, k.debugger.value, ours)
	testing.expect(t, !k.previous.present, "nothing to give back")

	// another program's Debugger, of the expanding kind: kept as it is
	other := Registry_String{value = `%ProgramFiles%\Other\procexp.exe`, expand = true, present = true}
	k = image_options_on({debugger = other}, ours, false)
	testing.expect_value(t, k.previous, other)
	testing.expect_value(t, k.debugger.value, ours)

	// On again over the program's own (a copy moved): the one kept before stays
	moved := image_options_on(k, task_manager_debugger(`D:\Programs\Sample\sample.exe`), true)
	testing.expect_value(t, moved.previous, other)

	// a Debugger of the same text, not marked (set by hand): nothing to give back but itself, so nothing kept
	same := image_options_on({debugger = {value = ours, present = true}}, ours, false)
	testing.expect(t, !same.previous.present, "the program's own text is not kept as another's")
}

@(test)
task_manager_off_gives_back_exactly :: proc(t: ^testing.T) {
	ours := task_manager_debugger(`C:\Program Files\Sample\sample.exe`)
	other := Registry_String{value = `%ProgramFiles%\Other\procexp.exe`, expand = true, present = true}
	k := image_options_off(image_options_on({debugger = other}, ours, false), true)
	testing.expect_value(t, k.debugger, other)
	testing.expect(t, !k.marked && !k.previous.present, "no mark, nothing kept")

	// none before: none after
	k = image_options_off(image_options_on({}, ours, false), true)
	testing.expect(t, !k.debugger.present && !k.marked && !k.previous.present, "the key holds nothing of ours")

	// another program took the part after ours: its Debugger stays, only the marks go
	later := Registry_String{value = `"C:\Tools\systeminformer.exe"`, present = true}
	taken := image_options_on({debugger = other}, ours, false)
	taken.debugger = later
	k = image_options_off(taken, false)
	testing.expect_value(t, k.debugger, later)
	testing.expect(t, !k.marked && !k.previous.present, "the marks gone")
}

// The machine copy is always under Program Files for HKLM's Debugger: a folder from the environment (which the user
// writes) counts only with a test's key under HKCU.
@(test)
task_manager_copy_is_in_program_files :: proc(t: ^testing.T) {
	o := Integration_Options{identity = {name = "Sample", vendor = "Froment Software"}}
	exe := exe_name_of(o.identity)
	testing.expect_value(t, machine_copy_path(&o, `C:\Program Files`), strings.concatenate({`C:\Program Files\Froment Software\Sample\`, exe}, context.temp_allocator))
	// a user's variable names a folder of theirs: HKLM's Debugger still runs Program Files'
	o.machine_dir = `C:\Users\someone\AppData\Local\evil`
	testing.expect_value(t, machine_copy_path(&o, `C:\Program Files`), strings.concatenate({`C:\Program Files\Froment Software\Sample\`, exe}, context.temp_allocator))
	testing.expect_value(t, machine_copy_path(&o, ""), "")
	// with a test's key, the test's folder
	o.image_options_root = `Software\TkDesktopTest_1\Image File Execution Options`
	testing.expect_value(t, machine_copy_path(&o, `C:\Program Files`), strings.concatenate({o.machine_dir, `\`, exe}, context.temp_allocator))
	// a vendor that is no folder's name: the program's name alone
	o = {identity = {name = "Sample", vendor = `..\Windows`}}
	testing.expect_value(t, machine_copy_path(&o, `C:\Program Files`), strings.concatenate({`C:\Program Files\Sample\`, exe}, context.temp_allocator))
}
