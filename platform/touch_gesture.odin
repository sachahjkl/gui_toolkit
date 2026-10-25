package platform

// Touch gestures from the fingers' Pointer_* events: tap, pan (the content follows one finger), pinch (two fingers:
// zoom about their middle, and pan with it), long press, and a fling (the speed at release, for inertia). Pure: the
// app feeds the positions and the times (ms on any clock) and gets what the gesture does; nothing here reads a clock.
//
//   g: platform.Touch_Gesture
//   platform.touch_gesture_init(&g, settings)
//   case .Pointer_Down: ge := platform.touch_gesture_down(&g, e.pointer.id, e.pos, now_ms)
//   case .Pointer_Move: ge := platform.touch_gesture_move(&g, e.pointer.id, e.pos, now_ms)
//   case .Pointer_Up:   ge := platform.touch_gesture_up(&g, e.pointer.id, e.pos, now_ms)
//   every frame while a finger is down: ge := platform.touch_gesture_tick(&g, now_ms)   // the long press

import "core:math"

Touch_Gesture_Settings :: struct {
	slop:            f32,   // pixels a finger moves before the press is a pan (a tap or a long press until then)
	long_press_ms:   f64,   // a finger held still this long is a long press (0: never)
	fling_min_speed: f32,   // pixels per second at release, below which the content just stops
	velocity_ms:     f64,   // the last part of the motion the release speed is measured over
}

TOUCH_GESTURE_DEFAULTS :: Touch_Gesture_Settings{slop = 12, long_press_ms = 500, fling_min_speed = 150, velocity_ms = 100}

Touch_Gesture_Kind :: enum u8 {
	None,
	Tap,          // a finger went down and up without moving (pos)
	Pan,          // the content follows the fingers by `pan` (pos: the finger, or the fingers' middle)
	Pinch,        // two fingers: `scale` (relative to the last event) about `pos`, and `pan`
	Long_Press,   // a finger held still (pos); nothing more comes from this gesture but End
	Fling,        // released while panning, fast enough: `velocity` (pixels per second, the direction the content moves)
	End,          // the gesture is over without a tap or a fling
}

Touch_Gesture_Event :: struct {
	kind:     Touch_Gesture_Kind,
	pos:      [2]f32,
	pan:      [2]f32,
	scale:    f32,
	velocity: [2]f32,
	first:    bool,   // the first Pan / Pinch of the gesture (the moment it stops being a tap)
}

@(private) TOUCH_MAX_FINGERS :: 10
@(private) TOUCH_SAMPLES :: 16

@(private)
Touch_Finger :: struct {
	id:    u32,
	start: [2]f32,
	pos:   [2]f32,
}

@(private)
Touch_State :: enum u8 { Idle, Pressed, Panning, Pinching, Held, Done }

Touch_Gesture :: struct {
	settings:  Touch_Gesture_Settings,
	fingers:   [TOUCH_MAX_FINGERS]Touch_Finger,
	count:     int,
	state:     Touch_State,
	down_ms:   f64,
	last_mid:  [2]f32,
	last_dist: f32,
	samples:   [TOUCH_SAMPLES]struct { pos: [2]f32, ms: f64 },
	n_samples: int,
	panned:    bool,   // a Pan / Pinch went out (the next one is not `first`)
}

touch_gesture_init :: proc(g: ^Touch_Gesture, settings := TOUCH_GESTURE_DEFAULTS) {
	g^ = {}
	g.settings = settings
}

// A finger is down (or more of them): the gesture goes on until the last is up.
touch_gesture_active :: proc(g: ^Touch_Gesture) -> bool { return g.count > 0 }

@(private)
finger_index :: proc(g: ^Touch_Gesture, id: u32) -> int {
	for i in 0 ..< g.count { if g.fingers[i].id == id { return i } }
	return -1
}

@(private)
middle :: proc(g: ^Touch_Gesture) -> (mid: [2]f32, dist: f32) {
	if g.count == 0 { return }
	if g.count == 1 { return g.fingers[0].pos, 0 }
	a, b := g.fingers[0].pos, g.fingers[1].pos
	d := b - a
	return (a + b) / 2, max(f32(1), math.sqrt(d.x * d.x + d.y * d.y))
}

@(private)
sample :: proc(g: ^Touch_Gesture, pos: [2]f32, ms: f64) {
	if g.n_samples == TOUCH_SAMPLES {
		for i in 1 ..< TOUCH_SAMPLES { g.samples[i - 1] = g.samples[i] }
		g.n_samples -= 1
	}
	g.samples[g.n_samples] = {pos, ms}
	g.n_samples += 1
}

// The speed over the last velocity_ms of the motion (pixels per second).
@(private)
release_velocity :: proc(g: ^Touch_Gesture, ms: f64) -> [2]f32 {
	if g.n_samples < 2 { return {} }
	last := g.samples[g.n_samples - 1]
	first := last
	for i := g.n_samples - 2; i >= 0; i -= 1 {
		if ms - g.samples[i].ms > g.settings.velocity_ms { break }
		first = g.samples[i]
	}
	dt := last.ms - first.ms
	// a finger that stopped before lifting has no speed
	if dt <= 0 || ms - last.ms > g.settings.velocity_ms { return {} }
	return (last.pos - first.pos) * f32(1000 / dt)
}

touch_gesture_down :: proc(g: ^Touch_Gesture, id: u32, pos: [2]f32, ms: f64) -> Touch_Gesture_Event {
	if finger_index(g, id) >= 0 || g.count >= TOUCH_MAX_FINGERS { return {} }
	g.fingers[g.count] = {id = id, start = pos, pos = pos}
	g.count += 1
	switch g.state {
	case .Idle, .Done:
		g.state = .Pressed
		g.down_ms = ms
		g.n_samples = 0
		g.panned = false
		sample(g, pos, ms)
		g.last_mid, g.last_dist = pos, 0
	case .Pressed, .Panning:
		if g.count >= 2 {
			// a second finger: a pinch from now on (the first finger's tap or pan is over)
			g.state = .Pinching
			g.last_mid, g.last_dist = middle(g)
		}
	case .Pinching, .Held:
	}
	return {}
}

touch_gesture_move :: proc(g: ^Touch_Gesture, id: u32, pos: [2]f32, ms: f64) -> Touch_Gesture_Event {
	i := finger_index(g, id)
	if i < 0 { return {} }
	g.fingers[i].pos = pos
	switch g.state {
	case .Idle, .Done, .Held:
		return {}
	case .Pressed:
		d := pos - g.fingers[i].start
		if abs(d.x) < g.settings.slop && abs(d.y) < g.settings.slop { return {} }
		g.state = .Panning
		fallthrough
	case .Panning:
		if i != 0 { return {} }
		sample(g, pos, ms)
		ev := Touch_Gesture_Event{kind = .Pan, pos = pos, pan = pos - g.last_mid, scale = 1, first = !g.panned}
		g.last_mid = pos
		g.panned = true
		return ev
	case .Pinching:
		if i > 1 { return {} }
		mid, dist := middle(g)
		ev := Touch_Gesture_Event{kind = .Pinch, pos = mid, pan = mid - g.last_mid, scale = g.last_dist > 0 ? dist / g.last_dist : 1, first = !g.panned}
		g.last_mid, g.last_dist = mid, dist
		g.panned = true
		sample(g, mid, ms)
		return ev
	}
	return {}
}

touch_gesture_up :: proc(g: ^Touch_Gesture, id: u32, pos: [2]f32, ms: f64) -> Touch_Gesture_Event {
	i := finger_index(g, id)
	if i < 0 { return {} }
	g.fingers[i].pos = pos
	for k in i + 1 ..< g.count { g.fingers[k - 1] = g.fingers[k] }
	g.count -= 1
	if g.count > 0 {
		if g.state == .Pinching && g.count == 1 {
			// back to one finger: it pans on from where it is (no jump)
			g.state = .Panning
			g.last_mid = g.fingers[0].pos
			g.n_samples = 0
		} else if g.state == .Pinching {
			g.last_mid, g.last_dist = middle(g)
		}
		return {}
	}
	defer g.state = .Idle
	switch g.state {
	case .Pressed:
		return {kind = .Tap, pos = pos}
	case .Panning:
		if i == 0 { sample(g, pos, ms) }
		v := release_velocity(g, ms)
		if v.x * v.x + v.y * v.y >= g.settings.fling_min_speed * g.settings.fling_min_speed { return {kind = .Fling, pos = pos, velocity = v} }
	case .Idle, .Pinching, .Held, .Done:
	}
	return {kind = .End, pos = pos}
}

// The system took the fingers away (Pointer_Cancel): the gesture ends with nothing more.
touch_gesture_cancel :: proc(g: ^Touch_Gesture) -> Touch_Gesture_Event {
	was := g.count > 0
	settings := g.settings
	touch_gesture_init(g, settings)
	return was ? {kind = .End} : {}
}

// Every frame while a finger is down: Long_Press once, when the only finger stayed still long enough.
touch_gesture_tick :: proc(g: ^Touch_Gesture, ms: f64) -> Touch_Gesture_Event {
	if g.state != .Pressed || g.count != 1 || g.settings.long_press_ms <= 0 { return {} }
	if ms - g.down_ms < g.settings.long_press_ms { return {} }
	g.state = .Held
	return {kind = .Long_Press, pos = g.fingers[0].pos}
}

// Where a fling glides to and for how long, under a friction that slows it exponentially (`friction` per second: the
// speed falls by e every 1/friction s): the distance is velocity / friction; the time is until the speed falls under
// `stop_speed` (pixels per second). For a scroll animation that eases out over that time.
touch_fling :: proc(velocity: [2]f32, friction: f32, stop_speed: f32 = 20) -> (distance: [2]f32, ms: f64) {
	k := max(friction, 0.01)
	distance = velocity / k
	speed := math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	if speed <= stop_speed { return distance, 0 }
	return distance, f64(math.ln(speed / max(stop_speed, 0.01)) / k) * 1000
}

// When the next long press is due (the app asks for a frame then), and whether one is.
touch_gesture_long_press_due :: proc(g: ^Touch_Gesture) -> (ms: f64, pending: bool) {
	if g.state != .Pressed || g.count != 1 || g.settings.long_press_ms <= 0 { return 0, false }
	return g.down_ms + g.settings.long_press_ms, true
}
