package scenarios_test

// The wheel picker (ui.wheel_number, ui.wheels, ui.duration_field; src/md/features/wheel-picker.md): a notch, a throw, a
// click on a row, the keys and what is typed turn the drum; the value changes once, when the drum rests; a wrapped drum
// loops and a bounded one stops at its ends; a value the program sets turns the drum without a change. A duration field
// takes keys and digits part by part, keeps its least, and opens its drums on a click.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{500, 400}

@(private = "file")
Run :: struct {
	minutes: int,
	hours:   int,
	wrap:    bool,
	changes: int,
	seconds: int,
}

@(private = "file")
drum_build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	if ui.wheel_number("###minutes", &r.minutes, 0, 59, format = "%02d", o = {wrap = r.wrap, unit = "min"}) { r.changes += 1 }
}

@(private = "file")
duration_build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	if ui.duration_field("###lock", &r.seconds, least = 60) { r.changes += 1 }
}

@(private = "file")
start :: proc(t: ^testing.T, r: ^Run, build: proc(s: ^session.Session)) -> ^session.Session {
	return session.start(t, {size = WINDOW, user = r, build = build, animations = true})
}

// The height of a row: the drum's height over its rows.
@(private = "file")
row_height :: proc(b: ^ui.Box) -> f32 { return (b.rect.max.y - b.rect.min.y) / ui.WHEEL_ROWS }

// A notch turns it one row; the value changes when it rests, once. A bounded drum does not pass its first row.
@(test)
a_notch_turns_one_row_once_at_rest :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{minutes = 5}
	s := start(t, &r, drum_build)
	at := session.center(session.get(s, "minutes"))
	session.wheel(s, at, {0, 1})
	testing.expect_value(t, r.minutes, 5)   // (still turning)
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 6)
	testing.expect_value(t, r.changes, 1)
	session.wheel(s, at, {0, -3})
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 3)
	testing.expect_value(t, r.changes, 2)
	r.minutes = 0
	session.wait_idle(s)
	session.wheel(s, at, {0, -2})
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 0)
	testing.expect_value(t, r.changes, 2)
}) }

// A wrapped drum goes from its last row to its first.
@(test)
a_wrapped_drum_loops :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{minutes = 58, wrap = true}
	s := start(t, &r, drum_build)
	session.wheel(s, session.center(session.get(s, "minutes")), {0, 3})
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 1)
	testing.expect_value(t, r.changes, 1)
}) }

// A value the program sets turns the drum to it, with no change given back.
@(test)
the_program_s_value_turns_the_drum :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{minutes = 5}
	s := start(t, &r, drum_build)
	r.minutes = 30
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 30)
	testing.expect_value(t, r.changes, 0)
	session.wheel(s, session.center(session.get(s, "minutes")), {0, 1})
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 31)
}) }

// A click on the row under the band's turns the drum to it; a drag of two rows up, held still before it is let go, moves
// it two rows; a fast one throws it further.
@(test)
a_click_a_drag_and_a_throw :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{minutes = 20}
	s := start(t, &r, drum_build)
	b := session.get(s, "minutes")
	c := session.center(b)
	h := row_height(b)
	session.click_at(s, c + {0, h})
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 21)
	session.press(s, c)
	for i in 1 ..= 20 {
		session.move(s, c - {0, 2 * h * f32(i) / 20})
		session.frame(s)
	}
	session.advance(s, 150)   // (held still: nothing is thrown)
	session.release(s, c - {0, 2 * h})
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 23)
	// (a throw: two rows in two frames, let go while moving)
	session.press(s, c)
	session.move(s, c - {0, h})
	session.frame(s)
	session.move(s, c - {0, 2 * h})
	session.frame(s)
	session.release(s, c - {0, 2 * h})
	session.wait_idle(s)
	testing.expect(t, r.minutes > 26, "a throw goes past where the hand let go")
	testing.expect_value(t, r.changes, 3)
}) }

// Down and Up move it a row, End to the last; digits typed go to the row they begin.
@(test)
keys_and_typing_move_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{minutes = 10}
	s := start(t, &r, drum_build)
	session.click(s, "minutes")   // (a click at the band: the keyboard, and the same row)
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 10)
	session.key(s, .Down)
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 11)
	session.key(s, .End)
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 59)
	session.type_text(s, "45")
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 45)
	session.type_text(s, "7")   // (soon after: "457", no row)
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 45)
	session.advance(s, 1000)
	session.type_text(s, "7")   // (a while later: a new search, 07 without its zero)
	session.wait_idle(s)
	testing.expect_value(t, r.minutes, 7)
}) }

// The field with the keyboard: Right goes to the minutes, Up steps them; digits replace a part and go on once no more
// fits; 0 h 00 min keeps the least, one minute.
@(test)
a_duration_field_takes_keys_and_digits :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{seconds = 90 * 60}
	s := start(t, &r, duration_build)
	session.click(s, "lock")
	session.key(s, .Escape)   // (the click opened the drums: the keys alone here)
	testing.expect_value(t, session.focused_name(s), "lock")
	session.key(s, .Left)   // (the hours, wherever the click was)
	session.key(s, .Up)
	testing.expect_value(t, r.seconds, 150 * 60)
	session.key(s, .Right)
	session.key(s, .Up)
	testing.expect_value(t, r.seconds, 151 * 60)
	session.type_text(s, "45")
	testing.expect_value(t, r.seconds, 165 * 60)
	session.key(s, .Left)
	session.type_text(s, "0")
	testing.expect_value(t, r.seconds, 45 * 60)
	session.advance(s, 2000)
	session.key(s, .Right)
	session.type_text(s, "00")
	testing.expect_value(t, r.seconds, 60)
	testing.expect_value(t, r.changes, 5)
}) }

// While the minutes' drum turns, the field shows its rows, frame by frame, never going back: the frame it rests in
// shows the new value, not the one before.
@(test)
a_turning_drum_s_part_never_goes_back :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{seconds = 5 * 60}
	s := start(t, &r, duration_build)
	session.click(s, "lock")
	session.wait_idle(s)
	at := session.center(session.get(s, "drum1"))
	session.move(s, at)
	session.event(s, {kind = .Scroll, pos = at, delta = {0, 3}})
	last := 5
	for _ in 0 ..< 60 {
		session.frame(s)
		text := ui.box_text(session.get(s, "part1"))
		v := 0
		for c in text { v = v * 10 + int(c - '0') }
		testing.expectf(t, v >= last, "the field went back from %d to %d", last, v)
		last = v
	}
	testing.expect_value(t, last, 8)
	testing.expect_value(t, r.seconds, 8 * 60)
}) }

// A click opens the drums below the field; the wheel on the minutes' drum turns it, and the field follows at rest;
// Escape closes them, and so does a press outside.
@(test)
a_duration_field_opens_its_drums :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{seconds = 5 * 60}
	s := start(t, &r, duration_build)
	testing.expect(t, session.find(s, "drum1") == nil, "no drums before a click")
	session.click(s, "lock")
	session.wait_idle(s)
	drum := session.get(s, "drum1")
	session.wheel(s, session.center(drum), {0, 3})
	session.wait_idle(s)
	testing.expect_value(t, r.seconds, 8 * 60)
	testing.expect_value(t, r.changes, 1)
	session.key(s, .Escape)
	session.wait_idle(s)
	testing.expect(t, session.find(s, "drum1") == nil, "Escape closes the drums")
	session.click(s, "lock")
	session.wait_idle(s)
	testing.expect(t, session.find(s, "drum1") != nil, "a click opens them again")
	session.click_at(s, {f32(WINDOW.x) - 10, f32(WINDOW.y) - 10})
	session.wait_idle(s)
	testing.expect(t, session.find(s, "drum1") == nil, "a press outside closes them")
}) }
