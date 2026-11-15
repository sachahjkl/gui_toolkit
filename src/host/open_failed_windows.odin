#+build windows
package tk_host

import win "core:sys/windows"

// A program built with -subsystem:windows has no standard error: what host_open wrote there is lost, so the person gets a
// message box. A program with a console (a terminal, a test runner) has read the line: no box, which would also hold a
// test run until someone closes it.
@(private)
open_failed_box :: proc(title, why: string) {
	err := win.GetStdHandle(win.STD_ERROR_HANDLE)
	if err != nil && err != win.INVALID_HANDLE_VALUE { return }
	win.MessageBoxW(nil, win.utf8_to_wstring(why, context.temp_allocator), win.utf8_to_wstring(title, context.temp_allocator), win.MB_OK | win.MB_ICONERROR)
}
