package tk_toolbox

import "core:fmt"
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
