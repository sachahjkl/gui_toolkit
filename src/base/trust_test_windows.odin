package gt_base

import "core:os"
import "core:strings"
import "core:testing"
import win "core:sys/windows"

// Only an administrator's folders, by a full path: System32 (not its folders that users write), Program Files.
@(test)
trusted_programs_on_windows :: proc(t: ^testing.T) {
	buf: [260]u16
	n := win.GetSystemDirectoryW(&buf[0], len(buf))
	system, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	testing.expect(t, trusted_program(strings.concatenate({system, `\cmd.exe`}, context.temp_allocator)), "System32's cmd.exe")
	testing.expect(t, trusted_program(strings.to_upper(strings.concatenate({system, `\cmd.exe`}, context.temp_allocator), context.temp_allocator)), "in another case")
	testing.expect(t, !trusted_program(strings.concatenate({system, `\Tasks\x.exe`}, context.temp_allocator)), "a folder of System32 that users write")
	testing.expect(t, !trusted_program(strings.concatenate({system, `\..\Temp\x.exe`}, context.temp_allocator)), "a climb out of it")
	// a folder of System32 by another of its names: its 8.3 name, its index stream; and a stream of a trusted folder
	testing.expect(t, !trusted_program(strings.concatenate({system, `\TASKS_~1\x.exe`}, context.temp_allocator)), "an 8.3 name")
	testing.expect(t, !trusted_program(strings.concatenate({system, `\Tasks::$INDEX_ALLOCATION\x.exe`}, context.temp_allocator)), "an index stream")
	testing.expect(t, !trusted_program(strings.concatenate({system, `:x.exe`}, context.temp_allocator)), "a stream of the folder")
	testing.expect(t, !trusted_program(strings.concatenate({system, `\spool\drivers\color\x.exe`}, context.temp_allocator)), "a folder that users write")
	testing.expect(t, trusted_program(strings.concatenate({system, `\WindowsPowerShell\v1.0\powershell.exe`}, context.temp_allocator)), "PowerShell")
	wow: [260]u16
	if m := win.GetSystemWow64DirectoryW(&wow[0], len(wow)); m > 0 {
		wow64, _ := win.utf16_to_utf8(wow[:m], context.temp_allocator)
		testing.expect(t, trusted_program(strings.concatenate({wow64, `\cmd.exe`}, context.temp_allocator)), "SysWOW64's cmd.exe")
		testing.expect(t, !trusted_program(strings.concatenate({wow64, `\Tasks\x.exe`}, context.temp_allocator)), "SysWOW64's Tasks, which users write too")
	}
	testing.expect(t, !trusted_program("cmd.exe"), "a bare name")
	tmp, _ := os.temp_dir(context.temp_allocator)
	testing.expect(t, !trusted_program(strings.concatenate({tmp, `\x.exe`}, context.temp_allocator)), "the user's TEMP")
	_ = elevated()   // (read once; a CI runner is an administrator: a test build is not restricted by it)
	testing.expect(t, !restricted(), "a test build")
}
