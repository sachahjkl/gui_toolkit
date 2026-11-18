package tk_plugins

import "core:os"
import win32 "core:sys/windows"

// The program's end of a plugin's pipe, kept out of every process started later. os.pipe makes both ends inheritable
// and os.process_start passes every inheritable handle on: a sibling plugin's process then held this end, and the
// program never saw the end of a child that died at its start (its reader waited for ever, the plugin stayed Starting).
@(private)
pipe_not_inherited :: proc(f: ^os.File) {
	_ = win32.SetHandleInformation(win32.HANDLE(os.fd(f)), win32.HANDLE_FLAG_INHERIT, 0)
}
