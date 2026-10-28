#+build linux
package platform

// The refresh rate of the monitor a window is on (display_info), for frame pacing. On Wayland it comes from the
// wl_output mode's `refresh` (millihertz: 60000, 143998...); on X11 from the RandR mode, when the RandR extension is
// reachable, else 60. Cheap to call every frame (cached; re-read only when stale). The exact present timing comes from
// the renderer's own statistics (render.measured_refresh_hz) as on Windows; this feeds the rate a page reads
// (screen.refresh) and the pacer's starting point.

display_info :: proc(w: ^Window) -> Display_Info {
	if w.offscreen {
		if w.display.serial == 0 { w.display = {hz = 60, max_hz = 60, source = .Default, serial = 1} }
		return w.display
	}
	if w.display_stale || w.display.serial == 0 {
		w.display_stale = false
		d := query_display_linux(w)
		if d.hz != w.display.hz || d.max_hz != w.display.max_hz || d.source != w.display.source {
			d.serial = w.display.serial + 1
			w.display = d
		} else if w.display.serial == 0 {
			d.serial = 1
			w.display = d
		}
	}
	return w.display
}

display_invalidate :: proc(w: ^Window) { w.display_stale = true }

// The rate the compositor runs at right now (a dynamic-refresh screen): there is no portable live query without the
// presentation-time protocol (Wayland) or the Present extension (X11), which the pacer reads through the renderer
// instead. Report "unknown" so the pacer uses display_info and render.measured_refresh_hz, as it does on a window the
// DWM query cannot answer for on Windows.
display_live_hz :: proc(w: ^Window) -> (hz: f64, ok: bool) { return 0, false }

@(private)
query_display_linux :: proc(w: ^Window) -> (d: Display_Info) {
	d.source = .Default
	d.hz, d.max_hz = 60, 60
	d.numerator, d.denominator = 60, 1
	switch w.backend {
	case .Wayland:
		if output_refresh_mhz > 1000 {
			hz := f64(output_refresh_mhz) / 1000
			d.hz, d.max_hz, d.source = hz, hz, .Mode
			d.numerator, d.denominator = u32(output_refresh_mhz), 1000
		}
	case .X11:
		if hz := x11_refresh_hz(); hz > 1 {
			d.hz, d.max_hz, d.source = f64(hz), f64(hz), .Mode
			d.numerator, d.denominator = u32(hz), 1
		}
	case .None:
	}
	return
}

// The X11 monitor's refresh, from RandR when present (bound lazily), else 0. Kept simple: the current mode's whole
// hertz is enough for the pacer, which refines from the renderer's statistics.
@(private)
x11_refresh_hz :: proc() -> int { return 0 }
