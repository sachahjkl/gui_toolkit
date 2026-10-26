package platform

// The cadence frames are made at while something moves, whatever the screen and the swap chain do.
//
// A swap chain's latency object paces an app only when the system holds the frames back until a refresh. On a display with a
// variable refresh rate (G-Sync, FreeSync, Windows' dynamic refresh rate), or when the compositor takes every frame as it
// comes, the object is released at once and an app that is woken by input a thousand times a second makes and presents a
// thousand frames a second (the screen shows the few it can, and the rest is work and heat). Frame_Slots is the app's own
// cap: a grid of slots one period apart that no frame starts before. Pure (no clock, no window): the caller gives the time.
//
//   s := Frame_Slots{period_ns = 5_555_555, strict = true}   // 180 Hz
//   wait, slot := frame_slot_wait(&s, now, idled, answers_input)
//   ... wait `wait` ns (taking input meanwhile), then make the frame ...
//
// `strict`: the grid is the period itself (a variable refresh display: the app is the only thing that paces). Otherwise it is
// 0.9 of it, a safety net a screen that paces the app (a fixed refresh rate) never reaches: the screen's own slots are further
// apart than the grid's, so the grid never delays a frame and never beats against the refresh. A grid that did delay
// FRAME_SLOT_ESCALATE frames in a row proves that nothing else paces the app: it becomes strict until the next rest.

FRAME_SLOT_MIN_WAIT_NS :: 200_000   // a wait shorter than this is not made (the timer's own granularity)
FRAME_SLOT_ESCALATE    :: 8         // consecutive delayed frames that make a loose grid strict
FRAME_SLOT_LOOSE       :: 0.9       // a loose grid's period, as a part of the period

Frame_Slots :: struct {
	period_ns: i64,    // the cadence aimed for (0: no cap)
	strict:    bool,   // the grid is the whole period (see above)
	next_ns:   i64,    // the slot of the next frame (0: none yet)
	delayed:   int,    // consecutive frames the grid had to delay
	escalated: bool,   // a loose grid found nothing else pacing the app
}

// The distance between two slots.
frame_slot_gap :: proc(s: ^Frame_Slots) -> i64 {
	if s.strict || s.escalated { return s.period_ns }
	return i64(f64(s.period_ns) * FRAME_SLOT_LOOSE)
}

// What the next frame waits for, at `now_ns`: how long before it starts (0: now) and the slot it was timed for.
// `restart`: the loop rested before this frame (a new run of frames starts now, and a strict grid forgotten). `immediate`: the
// frame starts an answer to input or is a step of a resize: it is not delayed, and the next one is a slot after it.
frame_slot_wait :: proc(s: ^Frame_Slots, now_ns: i64, restart, immediate: bool) -> (wait_ns, slot_ns: i64) {
	if s.period_ns <= 0 { s.next_ns = 0; return 0, now_ns }
	gap := frame_slot_gap(s)
	if restart {
		s.escalated, s.delayed = false, 0
		gap = frame_slot_gap(s)
		s.next_ns = now_ns
	}
	// a frame later than a whole gap does not try to catch up
	if s.next_ns == 0 || now_ns - s.next_ns > gap { s.next_ns = now_ns }
	if immediate {
		s.next_ns = now_ns + gap
		s.delayed = 0
		return 0, now_ns
	}
	slot_ns = s.next_ns
	if wait := slot_ns - now_ns; wait > FRAME_SLOT_MIN_WAIT_NS {
		wait_ns = wait
		s.delayed += 1
		if s.delayed >= FRAME_SLOT_ESCALATE { s.escalated = true }
	} else {
		s.delayed = 0
		if wait > 0 { slot_ns = now_ns }
	}
	s.next_ns = slot_ns + gap
	return
}

// The refresh rate of a display can change under the app: the screen is called variable when its modes at the current size
// go higher than the rate it runs at (a monitor with a dynamic refresh rate, or a variable one run below its top), so the
// rate the system reports is not the one frames will be shown at. `hz` and `max_hz` are Display_Info's.
refresh_is_variable :: proc(hz, max_hz: f64) -> bool { return hz > 0 && max_hz > hz * 1.05 }
