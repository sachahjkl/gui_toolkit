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
	lead_ns:   f64,   // how long before a vblank a present must be made to be shown at it, learned (vblank_lead_learn)
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
// guess when the compositor gives neither period nor counter. `present_ns`: when the picture was presented (0: unknown),
// which teaches the lead. Pure.
vblank_presented :: proc(v: ^Vblank_Timing, at_ns: i64, msc: u64, refresh_ns: u32, hint_ns: f64 = 0, present_ns: i64 = 0) {
	defer if present_ns > 0 { vblank_lead_learn(&v.lead_ns, present_ns, at_ns, v.period_ns) }
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

// The lead jumps this far past the bound a late picture proves.
@(private = "file") VBLANK_LEAD_STEP_NS :: 500_000
// The share of a period the lead drops at each picture on time: it probes later.
@(private = "file") VBLANK_LEAD_AGE :: 0.0005
// A lead is never more than this many periods (a compositor that composes two refreshes ahead is a queue, not a deadline).
@(private = "file") VBLANK_LEAD_MAX_PERIODS :: 2

// What a picture presented at `present_ns` and shown at the vblank `shown_ns` says of the lead (how long before a vblank
// a present must be made to be shown at it), with the period `period_ns`. Shown one refresh later than the lead
// predicted: the deadline was earlier, the lead jumps past that bound. Shown earlier than predicted: it was later, the
// lead drops to what this picture took. On time: the lead drops a little, so that input is read later and a change of
// the compositor is followed (src/md/infrastructure/vblank.md, "The start just in time"). Pure.
vblank_lead_learn :: proc(lead: ^f64, present_ns, shown_ns: i64, period_ns: f64) {
	if period_ns <= 0 || present_ns <= 0 || shown_ns <= present_ns { return }
	took := f64(shown_ns - present_ns)
	// (the vblanks after the one the lead predicted: the first whose deadline the present made)
	late := math.floor((took - lead^) / period_ns)
	switch {
	case late < 0:  lead^ = took
	case late == 0: lead^ -= period_ns * VBLANK_LEAD_AGE
	case late == 1: lead^ = max(lead^, took - period_ns + VBLANK_LEAD_STEP_NS)
	case:           return   // (two refreshes late or more: a hiccup or a queue)
	}
	lead^ = clamp(lead^, 0, period_ns * VBLANK_LEAD_MAX_PERIODS)
}
