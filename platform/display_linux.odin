#+build linux
package platform

// The refresh rate of the monitor a window is on (display_info), for frame pacing. On Wayland it comes from the
// wl_output mode's `refresh` (millihertz: 60000, 143998...); on X11 from RandR, the mode of the monitor under the
// window (x11_ext_linux.odin), else 60. Cheap to call every frame (cached; re-read only when stale). The exact present timing comes from
// the renderer's own statistics (render.measured_refresh_hz) as on Windows; this feeds the rate a page reads
// (screen.refresh) and the pacer's starting point.

@(private = "file") WL_MILLIHERTZ_PER_HZ :: 1000   // wl_output.mode

display_info :: proc(w: ^Window) -> Display_Info {
	if w.offscreen { return offscreen_display(w) }   // (virtual.odin)
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

// The pixel size of the monitor the window is on. Wayland reports the wl_output mode's size; X11 the root screen's
// (a single-head heuristic); the virtual screen's for an offscreen window. {0, 0} when nothing is known. Used for a fixed surface the
// size of the screen (render.set_fixed_surface).
monitor_size :: proc(w: ^Window) -> [2]int {
	if w == nil { return {} }
	if w.offscreen { return virtual_screen().size }
	switch w.backend {
	case .Wayland:
		if wlc.output_px.x > 0 && wlc.output_px.y > 0 {
			// wl_output reports physical pixels; the surface works in logical pixels (divided by the integer scale)
			s := max(wlc.output_scale, 1)
			return {int(wlc.output_px.x / s), int(wlc.output_px.y / s)}
		}
	case .X11:
		if x11c.screen != nil { return {int(x11c.screen.width_in_pixels), int(x11c.screen.height_in_pixels)} }
	case .None:
	}
	return {}
}

// The rate the compositor runs at right now (a dynamic-refresh screen): there is no portable live query without the
// presentation-time protocol (Wayland) or the Present extension (X11), which the pacer reads through the renderer
// instead. Report "unknown" so the pacer uses display_info and render.measured_refresh_hz, as it does on a window the
// DWM query cannot answer for on Windows.
display_live_hz :: proc(w: ^Window) -> (hz: f64, ok: bool) { return 0, false }

@(private)
query_display_linux :: proc(w: ^Window) -> (d: Display_Info) {
	d.source = .Default
	d.hz, d.max_hz = DISPLAY_FALLBACK_HZ, DISPLAY_FALLBACK_HZ
	d.numerator, d.denominator = DISPLAY_FALLBACK_HZ, 1
	switch w.backend {
	case .Wayland:
		if output_refresh_mhz > WL_MILLIHERTZ_PER_HZ {
			hz := f64(output_refresh_mhz) / WL_MILLIHERTZ_PER_HZ
			d.hz, d.max_hz, d.source = hz, hz, .Mode
			d.numerator, d.denominator = u32(output_refresh_mhz), WL_MILLIHERTZ_PER_HZ
		}
	case .X11:
		if num, den, top, ok := x11_randr_rate(w); ok {
			d.hz, d.max_hz, d.source = f64(num) / f64(den), top, .Display_Config
			d.numerator, d.denominator = num, den
		}
	case .None:
	}
	return
}
