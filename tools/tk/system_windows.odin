package tk

import "core:fmt"
import win "core:sys/windows"

// A program of the system (curl, tar), from its own folder: never another of that name earlier on the PATH (Git's tar reads no zip).
system_program :: proc(name: string) -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetSystemDirectoryW(&buf[0], win.MAX_PATH)
	dir, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return fmt.tprintf("%s\\%s.exe", dir, name)
}
