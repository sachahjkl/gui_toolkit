package tk_desktop

import win "core:sys/windows"

@(private)
open_terminal_native :: proc(dir: string) -> bool {
	wdir := win.utf8_to_wstring(dir, context.temp_allocator)
	open := win.utf8_to_wstring("open", context.temp_allocator)
	// Windows Terminal, in the folder; else the command prompt started there (ShellExecute: > 32 is a success)
	args := win.utf8_to_wstring(strings_concat3("-d \"", dir, "\""), context.temp_allocator)
	if uintptr(win.ShellExecuteW(nil, open, win.utf8_to_wstring("wt.exe", context.temp_allocator), args, wdir, win.SW_SHOWNORMAL)) > 32 { return true }
	return uintptr(win.ShellExecuteW(nil, open, win.utf8_to_wstring("cmd.exe", context.temp_allocator), nil, wdir, win.SW_SHOWNORMAL)) > 32
}

@(private = "file")
strings_concat3 :: proc(a, b, c: string) -> string {
	buf := make([]u8, len(a) + len(b) + len(c), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	copy(buf[len(a) + len(b):], c)
	return string(buf)
}
