package platform

// Where a window is on the screen, for an app that saves its layout or opens several windows. Everything is in physical pixels of the
// virtual screen (the monitors side by side; a monitor to the left or above the main one has negative coordinates).

// A window's outer rectangle (frame and title bar included) and whether it is maximized. `rect` is where the window is restored
// to, also while it is maximized or minimized.
Placement :: struct {
	rect:      [4]int,   // left, top, width, height
	maximized: bool,
}

// A saved rectangle put back on a screen: no larger than the work area (the monitor without the taskbar) and inside it. Pure.
fit_rect_to_work :: proc(r, work: [4]int) -> [4]int {
	w, h := min(r[2], work[2]), min(r[3], work[3])
	return {clamp(r[0], work[0], work[0] + work[2] - w), clamp(r[1], work[1], work[1] + work[3] - h), w, h}
}

// A rectangle of WINDOWPLACEMENT (workspace coordinates: relative to the work area, for a window that is no tool window)
// on the screen: the work area of the monitor starts at `work`, the monitor at `monitor`. A taskbar along the left or top
// edge is what makes them differ. Pure.
placement_workspace_to_screen :: proc(r: [4]int, monitor, work: [2]int) -> [4]int {
	return {r[0] + work.x - monitor.x, r[1] + work.y - monitor.y, r[2], r[3]}
}
