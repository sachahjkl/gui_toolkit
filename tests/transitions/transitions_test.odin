package transitions_test

// ui.tween and ui.swap (src/md/features/transitions.md): a value that reaches its target on a curve in a set time, and a
// place whose size glides from one face's to the next's while what is in it keeps its own size. A process of its own:
// its runs draw many frames, and with them the scenarios' came to 400 s of their 420 on WebGPU's CPU driver.

import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") TWEEN_TEST_MS :: 200
@(private = "file") SWAP_TEST_MS :: 200

// The emphasized curve, cubic-bezier(0.2, 0, 0, 1): from 0 to 1, never back, and quick at its start.
@(test)
the_emphasized_curve_starts_quick_and_lands_slow :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.ease_at(.Emphasized, 0), 0)
	testing.expect_value(t, ui.ease_at(.Emphasized, 1), 1)
	prev: f32
	for i in 1 ..= 200 {
		v := ui.ease_at(.Emphasized, f32(i) / 200)
		testing.expectf(t, v >= prev, "never back: %v after %v at %v", v, prev, f32(i) / 200)
		prev = v
	}
	// (the bezier itself gives 0.688 at 0.3: past two thirds of the way in under a third of the time)
	q := ui.ease_at(.Emphasized, 0.3)
	testing.expectf(t, q > 0.65, "quick at its start: %v at 0.3", q)
	// (the bezier's own point: x(0.5) = 0.2 and y(0.5) = 0.5 for these control points)
	testing.expectf(t, abs(ui.ease_at(.Emphasized, 0.2) - 0.5) < 1e-3, "its point (0.2, 0.5): %v", ui.ease_at(.Emphasized, 0.2))
}

// morph_text: the characters both texts share show at once, the text is always as long as the new one, and it is the
// new one at its duration.
@(test)
morph_text_keeps_what_both_texts_share :: proc(t: ^testing.T) {
	from, to := "Install 0.42.0", "Downloading 0.42.0…"
	n := utf8.rune_count(to)
	first := ui.morph_text(from, to, 0, 600, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(first, "0.42.0…"), "the version from the first instant: %q", first)
	for ms in ([?]f64{0, 50, 150, 300, 450, 599}) {
		got := ui.morph_text(from, to, ms, 600, context.temp_allocator)
		testing.expectf(t, utf8.rune_count(got) == n, "as long as the new text at %v ms: %q", ms, got)
	}
	testing.expect(t, ui.morph_text(from, to, 300, 600, context.temp_allocator) != to, "not there before its time")
	testing.expect_value(t, ui.morph_text(from, to, 600, 600, context.temp_allocator), to)
	// (above 128 runes either side: by index, the same contract)
	long_from, long_to := strings.repeat("a", 200, context.temp_allocator), strings.repeat("b", 200, context.temp_allocator)
	testing.expect_value(t, utf8.rune_count(ui.morph_text(long_from, long_to, 10, 600, context.temp_allocator)), 200)
	testing.expect_value(t, ui.morph_text(long_from, long_to, 600, 600, context.temp_allocator), long_to)
}

@(private = "file")
Tween_Run :: struct { target: f32, ease: ui.Ease, value: f32 }

@(private = "file")
tween_build :: proc(s: ^session.Session) {
	r := (^Tween_Run)(s.user)
	r.value = ui.tween(ui.key_from_string(0, "###tween_test"), r.target, TWEEN_TEST_MS, r.ease)
}

// The frames from a run's start until `ms` has passed: the first that reaches it.
@(private = "file")
frames_for :: proc(ms: f64) -> int {
	n := 0
	for f64(n) * session.FRAME_MS < ms { n += 1 }
	return n
}

@(test)
a_tween_reaches_its_target_at_its_time_along_its_curve :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for e in ui.Ease {
		r := Tween_Run{target = 0, ease = e}
		s := session.start(t, {size = {200, 60}, user = &r, build = tween_build, animations = true})
		session.frames(s, 2)
		r.target = 1
		session.frame(s)
		testing.expect_value(t, r.value, 0)   // (the frame of the change starts the run)
		half := frames_for(TWEEN_TEST_MS / 2)
		session.frames(s, half)
		p := f32(f64(half) * session.FRAME_MS / TWEEN_TEST_MS)
		testing.expectf(t, abs(r.value - ui.ease_at(e, p)) < 0.01, "%v at %v: %v, its curve says %v", e, p, r.value, ui.ease_at(e, p))
		session.frames(s, frames_for(TWEEN_TEST_MS) - half - 1)
		testing.expectf(t, r.value < 1, "%v: not there before its time: %v", e, r.value)
		session.frame(s)
		testing.expect_value(t, r.value, 1)
		session.frame(s)
		testing.expect(t, !ui.needs_frame(s.state), "there: no more frames")
	}
}) }

@(test)
a_tween_turned_back_goes_on_from_the_value_shown :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Tween_Run{target = 0, ease = .Out}
	s := session.start(t, {size = {200, 60}, user = &r, build = tween_build, animations = true})
	session.frames(s, 2)
	r.target = 1
	session.frames(s, 4)
	shown := r.value
	r.target = 0
	session.frame(s)
	testing.expectf(t, r.value <= shown && r.value > shown - 0.2, "no jump: %v after %v", r.value, shown)
	session.advance(s, TWEEN_TEST_MS + 20)
	testing.expect_value(t, r.value, 0)
}) }

@(test)
a_tween_without_animations_is_at_its_target :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Tween_Run{target = 0, ease = .Out}
	s := session.start(t, {size = {200, 60}, user = &r, build = tween_build, animations = false})
	session.frames(s, 2)
	r.target = 1
	session.frame(s)
	testing.expect_value(t, r.value, 1)
}) }

@(private = "file")
Swap_Run :: struct { face: string, width: f32 }

@(private = "file")
swap_build :: proc(s: ^session.Session) {
	r := (^Swap_Run)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row(.Center) {
		ui.space(ui.SPACE_3)
		if ui.swap("###swap_test", r.face, {ms = SWAP_TEST_MS}) {
			ui.next({width = ui.px(r.width), height = ui.px(24)})
			_ = ui.button("swap_face", r.face)
		}
		ui.next({width = ui.px(40), height = ui.px(24)})
		ui.label("after###after")
	}
}

@(private = "file")
width_of :: proc(b: ^ui.Box) -> f32 { return b.rect.max.x - b.rect.min.x }

@(test)
a_swap_glides_from_one_face_to_the_next :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Swap_Run{face = "short", width = 100}
	s := session.start(t, {size = {500, 60}, user = &r, build = swap_build, animations = true})
	session.frames(s, 3)
	testing.expect_value(t, width_of(session.get(s, "swap_test")), 100)
	r.face, r.width = "long", 200
	session.frame(s)
	testing.expect_value(t, session.get(s, "swap_test").size.x, 100)   // (the frame of the change: where it was)
	session.frame(s)
	w := session.get(s, "swap_test").size.x
	testing.expectf(t, w > 100 && w < 200, "a frame after: between the two, %v", w)
	session.frames(s, frames_for(SWAP_TEST_MS / 2) - 1)
	sw := session.get(s, "swap_test")
	face := session.get(s, "swap_face")
	// (on the swap's curve: the emphasized one is far past half at half the time)
	half := f32(f64(frames_for(SWAP_TEST_MS / 2)) * session.FRAME_MS / SWAP_TEST_MS)
	want := 100 + 100 * ui.ease_at(.Emphasized, half)
	testing.expectf(t, abs(width_of(sw) - want) <= 1.5 && width_of(sw) < 200, "halfway: %v, the curve says %v", width_of(sw), want)
	// the face is drawn at the swap's size (its round ends right at every frame), held at its start; its words keep
	// their own width and their one line (laid out at its natural size: they never wrap to fit)
	testing.expect_value(t, face.rect, sw.rect)
	words := session.get(s, "t", within = face)
	w_mid, h_mid := width_of(words), words.rect.max.y - words.rect.min.y
	// its neighbour moves with it
	testing.expectf(t, abs(session.get(s, "after").rect.min.x - sw.rect.max.x) <= 1, "the neighbour follows: %v after %v", session.get(s, "after").rect, sw.rect)
	session.advance(s, SWAP_TEST_MS)
	words = session.get(s, "t", within = session.get(s, "swap_face"))
	testing.expect_value(t, w_mid, width_of(words))
	testing.expect_value(t, h_mid, words.rect.max.y - words.rect.min.y)
	testing.expect_value(t, width_of(session.get(s, "swap_test")), 200)
	testing.expect_value(t, width_of(session.get(s, "swap_face")), 200)
	session.frame(s)
	testing.expect(t, !ui.needs_frame(s.state), "settled: no more frames")
	// a face whose own size changes takes it at once
	r.width = 220
	session.frame(s)
	testing.expect_value(t, width_of(session.get(s, "swap_test")), 220)
}) }

@(private = "file") SHAPE_RED :: ui.Color{0.9, 0, 0, 1}
@(private = "file") SHAPE_BLUE :: ui.Color{0, 0, 0.9, 1}

@(private = "file")
Shape_Run :: struct { blue: bool }

// Two faces that are shapes alone: a narrow red box and a wide blue one.
@(private = "file")
shape_build :: proc(s: ^session.Session) {
	r := (^Shape_Run)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row(.Center) {
		ui.space(ui.SPACE_3)
		if ui.swap("###shape_swap", r.blue ? "blue" : "red", {ms = SWAP_TEST_MS}) {
			ui.next({width = ui.px(r.blue ? 200 : 80), height = ui.px(30), bg = r.blue ? SHAPE_BLUE : SHAPE_RED, axis = .Y})
			face := ui.build_box({.Draw_Background}, r.blue ? "###face_blue" : "###face_red")
			if r.blue {
				// (content as wide as the face, a white strip along its top: words that would stand past the shape)
				if ui.parent(face) {
					ui.next({width = ui.px(200), height = ui.px(6), bg = {1, 1, 1, 1}})
					_ = ui.build_box({.Draw_Background}, "###strip")
				}
			}
		}
	}
}

// During a change, the swap draws one shape, between the two faces' widths, in a colour between theirs: the
// shape morphs, the two faces do not cross whole.
@(test)
a_swap_morphs_one_shape_from_the_old_face_to_the_new :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Shape_Run{}
	p := ui.palette_of("Midnight")
	p.finish = .Flat   // (plain colours: the shape's pixels are its colour)
	s := session.start(t, {size = {400, 80}, user = &r, build = shape_build, animations = true, palette = p})
	session.frames(s, 10)
	sw := session.get(s, "shape_swap")
	x0, y := int(sw.rect.min.x), int((sw.rect.min.y + sw.rect.max.y) / 2)
	img := session.capture(s)
	ground := session.pixel(img, 395, 3)
	red := session.pixel(img, x0 + 40, y)
	testing.expectf(t, red[0] > 180 && red[2] < 80, "the red face: %v", red)
	r.blue = true
	session.frame(s)
	// (a quarter of the time: the emphasized curve near its middle, 0.6)
	session.frames(s, frames_for(SWAP_TEST_MS / 4))
	img = session.capture(s)
	// (the shape's width along its middle row: the pixels that are not the ground, from the swap's start)
	n := 0
	for x in x0 ..< img.width { if !session.near(session.pixel(img, x, y), ground, 8) { n += 1 } }
	testing.expectf(t, n > 100 && n < 180, "one shape between 80 and 200 px wide: %v", n)
	// the new content stays inside the shape: the strip, 200 px wide, shows only as wide as the shape is
	strip_y := int(sw.rect.min.y) + 3
	m := 0
	for x in x0 ..< img.width { if !session.near(session.pixel(img, x, strip_y), ground, 8) { m += 1 } }
	testing.expectf(t, m <= n + 2, "the content clipped to the shape: %v px, the shape %v px", m, n)
	mid := session.pixel(img, x0 + n / 2, y)
	// (bluer than half: the new face, whole, comes over the morphed shape on the same curve)
	testing.expectf(t, mid[0] > 60 && mid[0] < 200 && mid[2] > 60 && mid[2] < 240, "a mix of red and blue, not one of them: %v", mid)
	session.advance(s, SWAP_TEST_MS)
	img = session.capture(s)
	blue := session.pixel(img, x0 + 150, y)
	testing.expectf(t, blue[2] > 180 && blue[0] < 80, "the blue face at the end: %v", blue)
}) }

@(test)
a_swap_without_animations_takes_the_new_size_at_once :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Swap_Run{face = "short", width = 100}
	s := session.start(t, {size = {500, 60}, user = &r, build = swap_build, animations = false})
	session.frames(s, 3)
	r.face, r.width = "long", 200
	session.frame(s)
	testing.expect_value(t, width_of(session.get(s, "swap_test")), 200)
	testing.expect(t, !ui.needs_frame(s.state), "no run")
}) }
