package tk_host

// A window opened ahead, hidden, so that it shows at once when it is asked for (a screenshot tool's editor at its
// shortcut): its window, its surface and the graphics driver are ready before. The first window of the program would
// wait for the driver, seconds on some machines: the driver is made on a thread first (render.preload_device), whose end
// wakes the program's loop, and the window opens after. The interface's thread never waits for it.
//
//	if host.ahead_due(&app.ahead, &app.shared, app_wake, app) { open_hidden_window(app) }   // each turn, while one is wanted

import "../render"

Ahead :: struct {
	done: bool,   // the window was asked for: never again (a window that cannot open is not asked at every turn)
}

// Each turn of the loop while the program wants a window ahead: true once, when it can open it now (hidden). Before
// that, with no window yet, the driver is made on a thread; `wake(user)` is called on that thread when it is made.
ahead_due :: proc(a: ^Ahead, sh: ^Shared, wake: proc(user: rawptr) = nil, user: rawptr = nil) -> bool {
	if a.done { return false }
	if sh.main == nil {
		#partial switch render.device_preload_state() {
		case .Not_Started: render.preload_device(done = wake, user = user); return false
		// (asked by program_start already: its end wakes the loop too)
		case .Creating:    render.preload_when_done(wake, user); return false
		}
	}
	a.done = true
	return true
}
