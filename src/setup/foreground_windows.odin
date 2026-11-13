#+build windows
package tk_setup

import win "core:sys/windows"

foreign import user32_setup "system:User32.lib"

@(default_calling_convention = "system", private = "file")
foreign user32_setup {
	AllowSetForegroundWindow :: proc(pid: win.DWORD) -> win.BOOL ---
}

// Lets the process `pid` take the foreground. Windows gives the foreground only to the process that had the user's last
// input (or one it allows): a copy started by a process whose window just closed would open behind the others.
@(private)
foreground_allow :: proc(pid: int) {
	if pid > 0 { AllowSetForegroundWindow(win.DWORD(pid)) }
}
