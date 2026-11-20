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
// Where the renderer knows the screen's vblanks (vblank_grid, Present_State.lead_ns), a frame of a run starts just in
// time: as late as it can and still be presented before its refresh's deadline, its input read as close to the screen as
// possible (platform.jit_start, src/md/infrastructure/vblank.md). Its cost runs from the end of its waits to
// paced_present.
//
// Input after a rest is not shown at once (no wait for the refresh): measured in opencode native, that one frame left the
// swap chain a frame deeper for the rest of the session (input to screen 45 to 60 ms instead of 30, every run). That holds
// for every frame that goes through pace_frame, whatever the application: the decision is never told of input (`input = false`
// below), so no caller can ask for it.

Pacer :: struct {
	cadence:        platform.Cadence,
	choices:        platform.Cadence_Choices,   // what the application asks of the frames: a target, a ceiling
	adopted:        platform.Cadence_Choices,   // those the plan was made with
	display_serial: u64,
	size:           [2]int,   // the window's size at the last frame
	presented:      bool,     // a frame reached the swap chain
	slot_held:      bool,     // the swap chain's slot was waited for, no present since
	just_in_time:   u64,      // frames started just in time (a test, the diagnostics: whether it runs on this screen)
	just_in_time_late: u64,   // frames timed just in time whose start was past (a frame dearer than the refresh): at once
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
		at_once = platform.cadence_inner_frame(&p.cadence, resized, p.presented, time.tick_now()._nsec)
		if at_once { latency = 2 } else if !p.slot_held { p.slot_held = wait_for_frame(r) }
	} else {
		// (the screen's vblanks, for the start just in time: unknown, the frame waits for its slot alone)
		in_ := platform.Cadence_Inputs{
			now_ns = time.tick_now()._nsec, idled = idled, input = false,
			presented = p.presented, resized = resized, slot_held = p.slot_held, dragging = dragging,
		}
		if last, period, ok := vblank_grid(r); ok {
			in_.vblank_ns, in_.period_ns, in_.lead_ns = last._nsec, period, r.present.lead_ns
		}
		d := platform.frame_decision(&p.cadence, in_)
		at_once, latency = d.present_at_once, d.latency
		if d.just_in_time { p.just_in_time += 1 }
		if d.just_in_time_late { p.just_in_time_late += 1 }
		if d.wait_swap_chain && !p.slot_held { p.slot_held = wait_for_frame(r) }
		// No frame before its slot: on a screen that does not hold the app back, a 1 kHz mouse made 430 frames a second. After
		// the swap chain, and only what is left: the decision is made just after the last present, always early, and a screen
		// that paces the app has by now passed the slot. Slept before, the two waits add up (60 Hz: 40 frames a second).
		// Input is taken meanwhile; a key or a button ends the wait, and the frame answers the newest of what came.
		// The start just in time is that wait too, when it is later (d.just_in_time): the frame then reads its input as late as
		// it can and still be presented before the deadline of its refresh.
		if d.wait_ns > 0 {
			if left := d.wait_until_ns - time.tick_now()._nsec; left > platform.FRAME_SLOT_MIN_WAIT_NS {
				platform.wait_slot(w, time.Duration(left))
			}
		}
		// (from here to its present: the frame's cost, which times the next one)
		platform.cadence_started(&p.cadence, time.tick_now()._nsec)
	}
	// (Present_State says what the swap chain has: a new one starts over, and a backend that cannot set it is asked again for nothing)
	if latency != max(r.present.max_latency, 1) { set_max_frame_latency(r, latency) }
	return
}

// After frame_end.
paced_present :: proc(p: ^Pacer) {
	p.presented = true
	p.slot_held = false
	platform.cadence_presented(&p.cadence, time.tick_now()._nsec)
}
