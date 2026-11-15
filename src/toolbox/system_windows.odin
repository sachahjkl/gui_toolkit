package tk_toolbox

import "core:fmt"
import "core:os"
import win "core:sys/windows"

// A program of the system (curl, tar), from the system's own folder: never another of that name earlier on the PATH (Git's tar
// reads no zip archive).
system_program :: proc(name: string) -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetSystemDirectoryW(&buf[0], win.MAX_PATH)
	dir, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return fmt.tprintf("%s\\%s.exe", dir, name)
}

// Whether a Windows executable carries an icon (its group 1, what Explorer, the Start menu and the window show): the file is
// opened as data and the group looked for.
exe_has_icon :: proc(path: string) -> bool {
	module := win.LoadLibraryExW(win.utf8_to_wstring(path), nil, {.LOAD_LIBRARY_AS_DATAFILE, .LOAD_LIBRARY_AS_IMAGE_RESOURCE})
	if module == nil { return false }
	defer win.FreeLibrary(module)
	return win.FindResourceW(module, transmute(win.LPCWSTR)uintptr(1), transmute(win.LPCWSTR)win.RT_GROUP_ICON) != nil
}

// What a stamp file ends with (the ones PowerShell's Set-Content wrote end so on Windows, and stay valid).
STAMP_NEWLINE :: "\r\n"
// What a program's -extra-linker-flags must hold for its reports to be named: the linker's map.
CRASH_LINKER_FLAGS :: "/MAP"
// The target the crates are linked for: this system's.
NOTICES_TARGET :: "x86_64-pc-windows-msvc"

// The exit code of a finished process; -1 when it did not exit. Windows gives it as an unsigned number: it is read back as the
// program's 32-bit int (`exit(-1)` is -1, a crash's NTSTATUS is negative).
exit_code :: proc(state: os.Process_State) -> int {
	if !state.exited { return -1 }
	return int(i32(u32(state.exit_code)))
}
