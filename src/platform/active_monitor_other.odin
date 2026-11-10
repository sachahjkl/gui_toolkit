#+build !windows
package platform

// Puts a window on the monitor the user works on (see the Windows version). Elsewhere the system places a window it shows:
// Wayland's compositor, an X11 window manager. Nothing is done.
move_to_active_monitor :: proc(w: ^Window, follow := Active_Monitor.Pointer) -> bool { return false }
