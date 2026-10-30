package render

import "core:time"
import "../platform"

// The frame pacing of a window, ready-made: the cadence model (platform/pacing.odin) fed from the window and the swap
// chain, as every application wrote it by hand. Each frame:
//
//   at_once := render.pace_frame(&pacer, &r, win, idled = slept, dragging = ui.active_key() != 0)
//   events := platform.poll_events(win, false)
//   ... build, draw ...
//   render.frame_end(&r, !at_once)
//   render.paced_present(&pacer)
//
// `idled`: the loop slept before this frame (nothing was due). A frame of a loop of the system (on_frame from the window
// procedure, a modal move or size) passes `inner = true`.
//
// Input after a rest is not shown at once (no wait for the refresh): measured in opencode native, that one frame left the
// swap chain a frame deeper for the rest of the session (input to screen 45 to 60 ms instead of 30, every run).

Pacer :: struct {
	cadence:        platform.Cadence,
	display_serial: u64,
	size:           [2]int,   // the window's size at the last frame
	presented:      bool,     // a frame reached the swap chain
	slot_held:      bool,     // the swap chain's slot was waited for, no present since
	latency:        int,      // the swap chain's maximum frame latency, as last set
}

// Before a frame reads its input: the cadence's decision executed (the screen's plan adopted when the display changed,
// the swap chain's slot waited for, its latency set). Returns whether the frame is presented at once.
pace_frame :: proc(p: ^Pacer, r: ^Renderer, w: ^platform.Window, idled := false, dragging := false, inner := false) -> (at_once: bool) {
	if d := platform.display_info(w); d.serial != p.display_serial {
		p.display_serial = d.serial
		platform.cadence_adopt(&p.cadence, platform.cadence_plan(d, {}))
	}
	resized := w.size != p.size
	p.size = w.size
	latency := 1
	if inner {
		at_once = platform.cadence_inner_frame(&p.cadence, resized, p.presented)
		if at_once { latency = 2 } else if !p.slot_held { p.slot_held = wait_for_frame(r) }
	} else {
		d := platform.frame_decision(&p.cadence, {
			now_ns = time.tick_now()._nsec, idled = idled, input = false,
			presented = p.presented, resized = resized, slot_held = p.slot_held, dragging = dragging,
		})
		at_once, latency = d.present_at_once, d.latency
		if d.wait_swap_chain && !p.slot_held { p.slot_held = wait_for_frame(r) }
	}
	if latency != p.latency {
		set_max_frame_latency(r, latency)
		p.latency = latency
	}
	return
}

// After frame_end.
paced_present :: proc(p: ^Pacer) {
	p.presented = true
	p.slot_held = false
	platform.cadence_presented(&p.cadence, time.tick_now()._nsec)
}
