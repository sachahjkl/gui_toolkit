#+build windows
package platform

import win "core:sys/windows"

// Puts a window on the monitor the user works on (the one of the window in front, else the one under the pointer) when it
// is on another: at the same place of that monitor's work area (rect_on_work). A program called up from anywhere (a
// shortcut, a notification area icon) calls it before it shows its window. True when the window moved.
move_to_active_monitor :: proc(w: ^Window) -> bool {
	if w == nil || w.offscreen || w.hwnd == nil { return false }
	fg := win.GetForegroundWindow()
	target: win.HMONITOR
	if fg != nil && fg != w.hwnd { target = win.MonitorFromWindow(fg, .MONITOR_DEFAULTTONULL) }
	if target == nil {
		pt: win.POINT
		if win.GetCursorPos(&pt) { target = win.MonitorFromPoint(pt, .MONITOR_DEFAULTTONEAREST) }
	}
	current := win.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST)
	if target == nil || target == current || is_maximized(w) { return false }
	from_mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	to_mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	if !win.GetMonitorInfoW(current, &from_mi) || !win.GetMonitorInfoW(target, &to_mi) { return false }
	work :: proc(r: win.RECT) -> [4]int { return {int(r.left), int(r.top), int(r.right - r.left), int(r.bottom - r.top)} }
	r := rect_on_work(outer_rect(w), work(from_mi.rcWork), work(to_mi.rcWork))
	// (the position alone: a monitor of another DPI resizes the window for itself, WM_DPICHANGED; then fitted again there)
	win.SetWindowPos(w.hwnd, nil, i32(r[0]), i32(r[1]), 0, 0, win.SWP_NOZORDER | win.SWP_NOACTIVATE | win.SWP_NOSIZE)
	if now := outer_rect(w); fit_rect_to_work(now, work(to_mi.rcWork)) != now {
		f := fit_rect_to_work(now, work(to_mi.rcWork))
		win.SetWindowPos(w.hwnd, nil, i32(f[0]), i32(f[1]), i32(f[2]), i32(f[3]), win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	}
	return true
}
