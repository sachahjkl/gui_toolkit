#+build windows
package platform

import win "core:sys/windows"

// The window's outer rectangle now (left, top, width, height).
outer_rect :: proc(w: ^Window) -> [4]int {
	rc: win.RECT
	win.GetWindowRect(w.hwnd, &rc)
	return {int(rc.left), int(rc.top), int(rc.right - rc.left), int(rc.bottom - rc.top)}
}

// Where the client area starts on the screen. A window that holds the mouse captured gets pointer positions outside itself, in its
// own client pixels: this turns them into screen positions.
client_origin :: proc(w: ^Window) -> [2]int {
	pt := win.POINT{0, 0}
	win.ClientToScreen(w.hwnd, &pt)
	return {int(pt.x), int(pt.y)}
}

// Moves the window (its top left corner) without resizing, raising or activating it.
move_window :: proc(w: ^Window, x, y: int) {
	win.SetWindowPos(w.hwnd, nil, i32(x), i32(y), 0, 0, win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
}

// The window's placement: where it is restored to, and whether it is maximized.
get_placement :: proc(w: ^Window) -> Placement {
	wp := win.WINDOWPLACEMENT{length = size_of(win.WINDOWPLACEMENT)}
	win.GetWindowPlacement(w.hwnd, &wp)
	r := wp.rcNormalPosition
	return {{int(r.left), int(r.top), int(r.right - r.left), int(r.bottom - r.top)}, wp.showCmd == u32(win.SW_SHOWMAXIMIZED) || is_maximized(w)}
}

// Puts the window where `p` says, on the monitor nearest to the rectangle and inside its work area (a layout saved with a monitor
// that is gone comes back on one that is there). Nothing is shown: `show_window` shows it, maximized when `p` says so.
set_placement :: proc(w: ^Window, p: Placement) {
	rc := win.RECT{i32(p.rect[0]), i32(p.rect[1]), i32(p.rect[0] + p.rect[2]), i32(p.rect[1] + p.rect[3])}
	work := [4]int{-(1 << 20), -(1 << 20), 1 << 21, 1 << 21}
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	if win.GetMonitorInfoW(win.MonitorFromRect(&rc, .MONITOR_DEFAULTTONEAREST), &mi) {
		work = {int(mi.rcWork.left), int(mi.rcWork.top), int(mi.rcWork.right - mi.rcWork.left), int(mi.rcWork.bottom - mi.rcWork.top)}
	}
	r := fit_rect_to_work(p.rect, work)
	win.SetWindowPos(w.hwnd, nil, i32(r[0]), i32(r[1]), i32(r[2]), i32(r[3]), win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	// a window that crossed to a monitor of another DPI is resized by the system for it (the size is scaled): asked again, now that it is there,
	// the rectangle is the one wanted (a window opens on the monitor the user is on, which is rarely the one a saved layout names)
	if now := outer_rect(w); now != r { win.SetWindowPos(w.hwnd, nil, i32(r[0]), i32(r[1]), i32(r[2]), i32(r[3]), win.SWP_NOZORDER | win.SWP_NOACTIVATE) }
	w.want_maximized = p.maximized
}
