package ui

// A horizontal swipe on a touchpad read as one step: the next or the previous picture of a viewer. Intent:
// src/md/features/swipe.md.
//
//	if step := ui.swipe_step(&app.swipe, view.rect); step != 0 { viewer_go(app, step) }

import "../draw"

// The sum of a gesture's x deltas, in notches (platform.Event.delta), that gives its step.
SWIPE_STEP_NOTCHES :: 4
// A gesture ends after this long with no finger scroll in the area, ms.
SWIPE_PAUSE_MS :: 150
// The x of a gesture must be this many times its y: a scroll up and down that drifts gives no step.
SWIPE_ACROSS_RATIO :: 2

// What a swipe reader keeps between builds: the gesture going on.
Swipe :: struct {
	sum:     Vec2,   // the gesture's deltas so far, notches
	stepped: bool,   // the gesture gave its step: it gives no other
	last_ms: f64,    // when its last delta came (0: no gesture)
}

// The step of a swipe in `area` this build: +1 when the fingers scroll the content to the right (the next), -1 to the
// left, else 0. One step per gesture, when its x passes SWIPE_STEP_NOTCHES. A wheel's notches never count. Call it
// once per build for each Swipe.
swipe_step :: proc(sw: ^Swipe, area: Rect) -> (step: int) {
	s := gs()
	// (the pause is read when the next delta comes: an idle program makes no build, and needs none to end a gesture)
	if sw.last_ms != 0 && s.time_ms - sw.last_ms >= SWIPE_PAUSE_MS { sw^ = {} }
	if s.swipe_delta != {} && s.mouse_valid && draw.rect_contains(area, s.mouse) {
		sw.sum += s.swipe_delta
		sw.last_ms = s.time_ms
		if !sw.stepped && abs(sw.sum.x) >= SWIPE_STEP_NOTCHES && abs(sw.sum.x) > SWIPE_ACROSS_RATIO * abs(sw.sum.y) {
			sw.stepped = true
			step = sw.sum.x > 0 ? 1 : -1
		}
	}
	// (after the deltas: the frame that lifts the fingers can bring the last ones)
	if s.swipe_end { sw^ = {} }
	return
}
