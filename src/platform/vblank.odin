package platform

// What the compositor said of a window's pictures: when the last one shown reached the screen, the period of the
// screen, how many were shown and how many were never shown. Wayland fills it from wp_presentation's answers, one per
// picture (window_wl_linux.odin); the renderer reads it at its next present (render's wgpu_compositor_timing) as Windows
// reads the compositor's timing. src/md/infrastructure/vblank.md says why.
//
//   v, ok := vblank_timing(native_surface_handles(w))

import "core:math"

Vblank_Timing :: struct {
	last_ns:   i64,   // the vblank the last picture shown reached the screen at, on core:time's tick clock (0: none yet)
	msc:       u64,   // the output's refresh counter at that vblank (0: the compositor keeps none)
	period_ns: f64,   // the refresh period: the compositor's, else measured (0: not known yet)
	shown:     u64,   // pictures the compositor showed
	discarded: u64,   // pictures it never showed: a later one replaced it before a repaint, or the window was not shown
}

// Two answers further apart than this many refreshes do not measure the period (a rest, a hidden window).
@(private = "file") VBLANK_SAMPLE_REFRESHES_MAX :: 1000
// A measured period out of this range is noise (10 .. 1000 Hz).
@(private = "file") VBLANK_PERIOD_MIN_NS :: 1e6
@(private = "file") VBLANK_PERIOD_MAX_NS :: 1e8
// Weight of a new measure in the running period.
@(private = "file") VBLANK_PERIOD_SMOOTHING :: 0.1

// A picture was shown at `at_ns` (core:time's tick clock), at the refresh `msc` (0: none counted). `refresh_ns`: the
// period the compositor gave (0: unknown or variable). `hint_ns`: the period of the output's mode (0: none), the first
// guess when the compositor gives neither period nor counter. Pure.
vblank_presented :: proc(v: ^Vblank_Timing, at_ns: i64, msc: u64, refresh_ns: u32, hint_ns: f64 = 0) {
	if refresh_ns > 0 {
		v.period_ns = f64(refresh_ns)
	} else if v.last_ns != 0 && msc > v.msc && msc - v.msc < VBLANK_SAMPLE_REFRESHES_MAX && at_ns > v.last_ns {
		// (no period given, a variable refresh: measured from two (counter, time) pairs, as DXGI's are on Windows)
		vblank_period_sample(v, f64(at_ns - v.last_ns) / f64(msc - v.msc))
	} else if msc == 0 && v.last_ns != 0 && at_ns > v.last_ns {
		// (neither period nor counter, sway's headless output: the gap between two pictures shown is a whole number of
		// refreshes, counted against the period known, else the mode's; a gap of more than a few refreshes, a rest, says
		// nothing)
		gap := f64(at_ns - v.last_ns)
		guess := v.period_ns != 0 ? v.period_ns : hint_ns
		if guess > 0 {
			k := math.round(gap / guess)
			if k >= 1 && k <= VBLANK_GAP_REFRESHES_MAX && abs(gap / k - guess) < guess * VBLANK_GAP_TOLERANCE {
				vblank_period_sample(v, gap / k)
			}
		}
	}
	v.last_ns, v.msc = at_ns, msc
	v.shown += 1
}

// Two pictures with no counter further apart than this many refreshes do not measure the period (a rest).
@(private = "file") VBLANK_GAP_REFRESHES_MAX :: 4
// A gap whose refreshes are this share off the guess is no refresh of it (a picture shown late, a mode change).
@(private = "file") VBLANK_GAP_TOLERANCE :: 0.2

@(private = "file")
vblank_period_sample :: proc(v: ^Vblank_Timing, per: f64) {
	if per <= VBLANK_PERIOD_MIN_NS || per >= VBLANK_PERIOD_MAX_NS { return }
	v.period_ns = v.period_ns == 0 ? per : v.period_ns + (per - v.period_ns) * VBLANK_PERIOD_SMOOTHING
}

// A picture was never shown. Pure.
vblank_discarded :: proc(v: ^Vblank_Timing) { v.discarded += 1 }
