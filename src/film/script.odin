package film

import "core:math"
import "../platform"
import "../ui"

// A film's script acts as a person would, over time: each action makes the frames it lasts, the pointer glides between
// places, each event goes through the program's own input (platform.inject_event). Positions are the window's client
// pixels.

// `seconds` of frames, nothing done.
hold :: proc(r: ^Recorder, seconds: f64) {
	for _ in 0 ..< frames_of(r, seconds) { frame(r) }
}

// The pointer shows (at its place) or hides.
pointer_show :: proc(r: ^Recorder, shown: bool, at: Maybe([2]f32) = nil) {
	if p, ok := at.?; ok { r.pointer.at = p }
	r.pointer.shown = shown
}

// The pointer glides to `to` along an ease in `seconds`, a move each frame (the hovers on the way light up).
move_to :: proc(r: ^Recorder, to: [2]f32, seconds := 0.6) {
	from := r.pointer.at
	r.pointer.shown = true
	n := max(frames_of(r, seconds), 1)
	for i in 1 ..= n {
		t := ease_in_out(f32(i) / f32(n))
		at := from + (to - from) * t
		r.pointer.at = at
		event(r, {kind = .Mouse_Move, pos = at})
		frame(r)
	}
}

// A click where the pointer is: down for a tenth of a second, then up; a ring spreads from it. `count` 2: a double click.
click :: proc(r: ^Recorder, button := platform.Mouse_Button.Left, count := 1) {
	for i in 0 ..< count {
		press(r, button)
		hold(r, 0.08)
		release(r, button)
		if i + 1 < count { hold(r, 0.06) }
	}
}

press :: proc(r: ^Recorder, button := platform.Mouse_Button.Left) {
	r.pointer.down = true
	append(&r.pointer.rings, Ring{at = r.pointer.at, start = r.clock})
	event(r, {kind = .Mouse_Press, button = button, pos = r.pointer.at, buttons = {button}})
	frame(r)
}

release :: proc(r: ^Recorder, button := platform.Mouse_Button.Left) {
	r.pointer.down = false
	event(r, {kind = .Mouse_Release, button = button, pos = r.pointer.at})
	frame(r)
}

// A press where the pointer is, a glide to `to` with the button held, a release.
drag_to :: proc(r: ^Recorder, to: [2]f32, seconds := 0.8, button := platform.Mouse_Button.Left) {
	press(r, button)
	from := r.pointer.at
	n := max(frames_of(r, seconds), 1)
	for i in 1 ..= n {
		at := from + (to - from) * ease_in_out(f32(i) / f32(n))
		r.pointer.at = at
		event(r, {kind = .Mouse_Move, pos = at, buttons = {button}})
		frame(r)
	}
	release(r, button)
}

// The wheel where the pointer is: `notches` (as platform.Event.delta: +y scrolls the content down) spread over `seconds`.
wheel :: proc(r: ^Recorder, notches: [2]f32, seconds := 0.5, mods: platform.Modifiers = {}) {
	n := max(frames_of(r, seconds), 1)
	for _ in 0 ..< n {
		event(r, {kind = .Scroll, pos = r.pointer.at, delta = notches / f32(n), mods = mods})
		frame(r)
	}
}

// A key pressed and released, then `after` seconds.
key :: proc(r: ^Recorder, k: platform.Key, mods: platform.Modifiers = {}, after := 0.15) {
	event(r, {kind = .Key_Press, key = k, mods = mods})
	event(r, {kind = .Key_Release, key = k, mods = mods})
	frame(r)
	hold(r, after)
}

// Words typed at `per_second` characters a second, as a person types; Enter and Tab as keys.
type_text :: proc(r: ^Recorder, text: string, per_second := 14.0) {
	gap := 1 / per_second
	for c in text {
		switch c {
		case '\n': key(r, .Return, after = gap)
		case '\t': key(r, .Tab, after = gap)
		case:
			event(r, {kind = .Text, text = c})
			frame(r)
			hold(r, gap - 1 / f64(r.o.fps))
		}
	}
}

// The window takes `size` pixels from the next frame (its host remakes its picture at it); the stage centres it on the
// film. Never larger than the film.
resize :: proc(r: ^Recorder, size: [2]int) {
	platform.set_size(r.app.win, {min(size.x, r.o.size.x), min(size.y, r.o.size.y)})
}

// An event as the system gives it, handled by the next frame.
event :: proc(r: ^Recorder, e: platform.Event) {
	ev := e
	ev.injected = true
	platform.inject_event(r.app.win, ev)
}

// The box named `name` (or showing `text`) in the last build, nil when none (ui.box_find).
box :: proc(r: ^Recorder, name: string, text := "", index := 0, within: ^ui.Box = nil) -> ^ui.Box {
	return ui.box_find(r.app.state, name, text, index, within)
}

// A box's middle, on whole pixels; `at` (0..1 of its width and height) another point of it.
center :: proc(b: ^ui.Box, at := [2]f32{0.5, 0.5}) -> [2]f32 {
	if b == nil { return {} }
	return {math.round(b.rect.min.x + (b.rect.max.x - b.rect.min.x) * at.x), math.round(b.rect.min.y + (b.rect.max.y - b.rect.min.y) * at.y)}
}

////////////////////////////////
// Eases, 0..1 to 0..1

ease_in_out :: proc(t: f32) -> f32 {
	u := clamp(t, 0, 1)
	return u < 0.5 ? 4 * u * u * u : 1 - math.pow(-2 * u + 2, 3) / 2
}

smooth :: proc(t: f32) -> f32 {
	u := clamp(t, 0, 1)
	return u * u * (3 - 2 * u)
}

// Past its end and back, as a spring let go (`over`: how far past).
ease_out_back :: proc(t: f32, over: f32 = 1.7) -> f32 {
	u := clamp(t, 0, 1)
	c3 := over + 1
	return 1 + c3 * math.pow(u - 1, 3) + over * math.pow(u - 1, 2)
}

// The value of `a` to `b` at `t` seconds of a move from `t0` lasting `seconds`, along `ease` (before: a, after: b).
tween :: proc(a, b: f32, t, t0, seconds: f64, ease := ease_in_out) -> f32 {
	k := seconds > 0 ? f32((t - t0) / seconds) : 1
	return a + (b - a) * ease(k)
}

// The film's time so far, seconds.
now :: proc(r: ^Recorder) -> f64 { return f64(r.frames) / f64(r.o.fps) }
