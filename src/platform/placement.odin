package platform

import "core:fmt"
import "core:strconv"
import "core:strings"

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

// A rectangle of the work area `from` at the same place on the work area `to`: the share of the room left around it on
// each axis is kept (a window in the middle stays in the middle, one in a corner in that corner), its size too, then it
// is fitted to `to`. Pure.
rect_on_work :: proc(r, from, to: [4]int) -> [4]int {
	at :: proc(pos, from_origin, from_size, to_origin, to_size, size: int) -> int {
		room := from_size - size
		share := room > 0 ? clamp(f64(pos - from_origin) / f64(room), 0, 1) : 0
		return to_origin + int(share * f64(max(to_size - size, 0)) + 0.5)
	}
	moved := [4]int{at(r[0], from[0], from[2], to[0], to[2], r[2]), at(r[1], from[1], from[3], to[1], to[3], r[3]), r[2], r[3]}
	return fit_rect_to_work(moved, to)
}

// A rectangle of WINDOWPLACEMENT (workspace coordinates: relative to the work area, for a window that is no tool window)
// on the screen: the work area of the monitor starts at `work`, the monitor at `monitor`. A taskbar along the left or top
// edge is what makes them differ. Pure.
placement_workspace_to_screen :: proc(r: [4]int, monitor, work: [2]int) -> [4]int {
	return {r[0] + work.x - monitor.x, r[1] + work.y - monitor.y, r[2], r[3]}
}

// A placement as a preference's text, to open the window where it was ("120 80 1400 900", "maximized" after when it was): the
// numbers of `rect`, physical pixels of the virtual screen. Pure.
placement_text :: proc(p: Placement, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%d %d %d %d%s", p.rect[0], p.rect[1], p.rect[2], p.rect[3], p.maximized ? " maximized" : "", allocator = allocator)
}

// The placement placement_text wrote. ok false: not one (empty, another shape, a size of nothing): the window opens where the
// system puts it. Pure.
placement_parse :: proc(s: string) -> (p: Placement, ok: bool) {
	words := strings.fields(s, context.temp_allocator)
	if len(words) != 4 && len(words) != 5 { return }
	for i in 0 ..< 4 {
		n, is_int := strconv.parse_int(words[i], 10)
		if !is_int { return }
		p.rect[i] = n
	}
	if p.rect[2] <= 0 || p.rect[3] <= 0 { return }
	if len(words) == 5 {
		if words[4] != "maximized" { return }
		p.maximized = true
	}
	return p, true
}
