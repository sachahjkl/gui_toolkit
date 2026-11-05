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
// Input is never what is limited: it is read as it comes, whatever the frames do. What is decided here is how many frames go out.
// That is the application's to choose: `pacer.choices` (a rate to aim for, a ceiling; read at the next frame), or
// `pacer.cadence.uncapped = true`: no slot, no wait for the screen (a diagnostic, a benchmark: it costs power).
//
// `idled`: the loop slept before this frame (nothing was due). A frame of a loop of the system (on_frame from the window
// procedure, a modal move or size) passes `inner = true`.
//
// Input after a rest is not shown at once (no wait for the refresh): measured in opencode native, that one frame left the
// swap chain a frame deeper for the rest of the session (input to screen 45 to 60 ms instead of 30, every run).

Pacer :: struct {
	cadence:        platform.Cadence,
	choices:        platform.Cadence_Choices,   // what the application asks of the frames: a target, a ceiling
	adopted:        platform.Cadence_Choices,   // those the plan was made with
	display_serial: u64,
	size:           [2]int,   // the window's size at the last frame
	presented:      bool,     // a frame reached the swap chain
	slot_held:      bool,     // the swap chain's slot was waited for, no present since
	latency:        int,      // the swap chain's maximum frame latency, as last set
}

// Before a frame reads its input: the cadence's decision executed (the screen's plan adopted when the display changed,
// the frame's slot and the swap chain's waited for, its latency set). Returns whether the frame is presented at once.
pace_frame :: proc(p: ^Pacer, r: ^Renderer, w: ^platform.Window, idled := false, dragging := false, inner := false) -> (at_once: bool) {
	if d := platform.display_info(w); d.serial != p.display_serial || p.choices != p.adopted {
		p.display_serial, p.adopted = d.serial, p.choices
		platform.cadence_adopt(&p.cadence, platform.cadence_plan(d, p.choices))
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
		// No frame before its slot: on a screen that does not hold the app back, a 1 kHz mouse made 430 frames a second. After
		// the swap chain, and only what is left: the decision is made just after the last present, always early, and a screen
		// that paces the app has by now passed the slot. Slept before, the two waits add up (60 Hz: 40 frames a second).
		// Input is taken meanwhile; a key or a button ends the wait, and the frame answers the newest of what came.
		if d.wait_ns > 0 {
			if left := d.wait_until_ns - time.tick_now()._nsec; left > platform.FRAME_SLOT_MIN_WAIT_NS {
				platform.wait_slot(w, time.Duration(left))
			}
		}
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
