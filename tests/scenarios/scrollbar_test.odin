package scenarios_test

// A scroll box and its bar (src/md/features/scroll-bar.md): the wheel, the thumb, the track, the arrow buttons and their
// repeat by the clock, the end of the content; a bar that always shows while the content overflows, or with auto-hide only
// while its view moves or the pointer is over it; its two sizes; its states, by its pixels.

import "core:fmt"
import "core:math"
import "core:testing"
import "../../src/font"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") VIEW_SIZE :: [2]f32{300, 200}
@(private = "file") ROW_HEIGHT :: 30
@(private = "file") ROWS :: 50
@(private = "file") FEW_ROWS :: 3
@(private = "file") WHEEL_NOTCHES :: 3
// Longer than anything that could hide a bar (a fade, a delay after the pointer left).
@(private = "file") AWAY_MS :: 3000
// An arrow held this long (past the delay before it repeats) scrolls at least this many steps.
@(private = "file") ARROW_HOLD_MS :: 1000
@(private = "file") ARROW_HOLD_STEPS_MIN :: 4
// The standard's repeat of a held arrow (scroll-bar.md).
@(private = "file") REPEAT_DELAY_MS :: 400
@(private = "file") REPEAT_INTERVAL_MS :: 60

@(private = "file")
Scroller :: struct { rows: int }

@(private = "file")
scroller_build :: proc(s: ^session.Session) {
	sc := (^Scroller)(s.user)
	ui.next({width = ui.px(VIEW_SIZE.x), height = ui.px(VIEW_SIZE.y)})
	if ui.scroll_y("###view") {
		for i in 0 ..< sc.rows {
			ui.next({width = ui.fill(), height = ui.px(ROW_HEIGHT)})
			ui.label(fmt.tprintf("Row %d###row%d", i, i))
		}
	}
}

@(private = "file")
max_scroll :: proc(s: ^session.Session) -> f32 {
	return ui.view_limit(session.get(s, "view"))
}

// What an arrow steps: a line of the view's font.
@(private = "file")
line_of :: proc(s: ^session.Session) -> f32 {
	b := session.get(s, "view")
	return math.ceil(font.metrics(s.state.fonts, b.font, b.font_size).line_height)
}

@(test)
everything_fits_no_bar :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = FEW_ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	_, _, ok := ui.scrollbar_rects(session.get(s, "view"))
	testing.expect(t, !ok, "three rows fit")
	session.wheel(s, session.center(session.get(s, "view")), {0, WHEEL_NOTCHES})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, 0)
	sc.rows = ROWS
	session.frames(s, 2)
	_, _, ok = ui.scrollbar_rects(session.get(s, "view"))
	testing.expect(t, ok, "fifty do not")
}) }

// The bar is there whenever the content overflows, wherever the pointer is and however long it has been away: its thumb
// is in the frame at rest, under the pointer, and after the pointer left.
@(test)
a_bar_always_shows_while_the_content_overflows :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, animations = true})
	away := [2]f32{f32(session.DEFAULT_SIZE.x - 1), f32(session.DEFAULT_SIZE.y - 1)}
	session.move(s, away)
	session.advance(s, AWAY_MS)
	session.wait_idle(s)
	_, thumb, ok := ui.scrollbar_rects(session.get(s, "view"))
	if !testing.expect(t, ok, "a bar") { return }
	// (the thumb's face, clear of its border, its inner line and its grip; the page beside the bar, past the rows' words)
	face := [2]int{int(thumb.min.x) + 2, int(thumb.min.y) + 4}
	page := [2]int{int(thumb.min.x) - 20, int(thumb.min.y) + 4}
	img := session.capture(s)
	testing.expect(t, !session.near(session.pixel(img, face.x, face.y), session.pixel(img, page.x, page.y), 8), "at rest, with the pointer away: the thumb is drawn")
	session.hover(s, "view")
	session.wait_idle(s)
	img = session.capture(s)
	testing.expect(t, !session.near(session.pixel(img, face.x, face.y), session.pixel(img, page.x, page.y), 8), "with the pointer over the view")
	session.move(s, away)
	session.advance(s, AWAY_MS)
	session.wait_idle(s)
	img = session.capture(s)
	testing.expect(t, !session.near(session.pixel(img, face.x, face.y), session.pixel(img, page.x, page.y), 8), "long after the pointer left")
	_, _, ok = ui.scrollbar_rects(session.get(s, "view"))
	testing.expect(t, ok, "and its parts are still there to take")
}) }

// Auto-hide, a person's option (off by default): hidden at rest, its pixels the page's; shown while its view moves, while the
// pointer is over the view, and for a moment after scrollbar_reveal; hidden again by the clock.
@(test)
an_autohide_bar_shows_while_its_view_moves :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, animations = true})
	testing.expect(t, !s.state.scrollbar_autohide, "off by default")
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 1)
	ui.set_scrollbar_autohide(s.state, true)
	away := [2]f32{f32(session.DEFAULT_SIZE.x - 1), f32(session.DEFAULT_SIZE.y - 1)}
	session.move(s, away)
	session.advance(s, AWAY_MS)
	session.wait_idle(s)
	view := session.get(s, "view")
	testing.expect_value(t, ui.scrollbar_opacity(s.state, view), 0)
	_, thumb, ok := ui.scrollbar_rects(view)
	if !testing.expect(t, ok, "it has a bar to show") { return }
	face := [2]int{int(thumb.min.x) + 2, int(thumb.min.y) + 4}
	page := [2]int{int(thumb.min.x) - 20, int(thumb.min.y) + 4}
	img := session.capture(s)
	testing.expect(t, session.near(session.pixel(img, face.x, face.y), session.pixel(img, page.x, page.y), 8), "at rest: not drawn")

	// the view glides (moved by the program, the pointer away): the bar shows while it moves, then goes
	view.view_target.y = max_scroll(s)
	session.frames(s, 3)
	view = session.get(s, "view")
	testing.expect(t, view.view_off.y != view.view_target.y, "still gliding")
	testing.expect(t, ui.scrollbar_opacity(s.state, view) > 0, "shown while the view moves")
	session.wait_idle(s)
	session.advance(s, AWAY_MS)
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 0)

	// the pointer over the view
	session.hover(s, "view")
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 1)
	session.move(s, away)
	session.advance(s, AWAY_MS)
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 0)

	// revealed (the keyboard moved it): for a moment, then gone by the clock
	ui.scrollbar_reveal(session.get(s, "view"))
	session.frames(s, 3)
	testing.expect(t, ui.scrollbar_opacity(s.state, session.get(s, "view")) > 0, "revealed")
	session.advance(s, AWAY_MS)
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 0)

	// hidden, it is still there to take
	_, thumb, _ = ui.scrollbar_rects(session.get(s, "view"))
	at := (thumb.min + thumb.max) * 0.5
	session.drag(s, at, at - {0, 60})
	testing.expect(t, session.get(s, "view").view_off.y < max_scroll(s), "the thumb is taken")
	ui.set_scrollbar_autohide(s.state, false)
}) }

@(test)
the_wheel_scrolls_and_stops_at_the_ends :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	mid := session.center(session.get(s, "view"))
	session.wheel(s, mid, {0, WHEEL_NOTCHES})
	session.wait_idle(s)
	off := session.get(s, "view").view_off.y
	testing.expect(t, off > 0, "down")
	session.wheel(s, mid, {0, ROWS})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, max_scroll(s))
	track, thumb, _ := ui.scrollbar_rects(session.get(s, "view"))
	testing.expectf(t, abs(thumb.max.y - track.max.y) < 1, "the thumb at the end of its track: %v and %v", thumb.max.y, track.max.y)
	session.wheel(s, mid, {0, -ROWS})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, 0)
}) }

@(test)
the_thumb_follows_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	track, thumb, ok := ui.scrollbar_rects(session.get(s, "view"))
	if !testing.expect(t, ok) { return }
	x := (thumb.min.x + thumb.max.x) * 0.5
	grab := (thumb.min.y + thumb.max.y) * 0.5
	span := (track.max.y - track.min.y) - (thumb.max.y - thumb.min.y)
	session.drag(s, {x, grab}, {x, grab + span * 0.5})
	want := max_scroll(s) * 0.5
	testing.expectf(t, abs(session.get(s, "view").view_off.y - want) < 3, "half way along its track, half way down: %v, want %v", session.get(s, "view").view_off.y, want)
	// beyond the end: at the end
	_, thumb, _ = ui.scrollbar_rects(session.get(s, "view"))
	grab = (thumb.min.y + thumb.max.y) * 0.5
	session.drag(s, {x, grab}, {x, grab + span * 4})
	testing.expect_value(t, session.get(s, "view").view_off.y, max_scroll(s))
}) }

// A press on the thumb with no move moves nothing: its place is whole pixels, coarser than the content's offsets.
@(test)
a_press_on_the_thumb_moves_nothing :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	session.wheel(s, session.center(session.get(s, "view")), {0, 1})
	session.wait_idle(s)
	before := session.get(s, "view").view_off.y
	_, thumb, _ := ui.scrollbar_rects(session.get(s, "view"))
	at := (thumb.min + thumb.max) * 0.5
	session.press(s, at)
	session.release(s, at)
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, before)
}) }

// A press on the track moves the view a page (its own height) toward the press, and no further.
@(test)
a_press_on_the_track_pages :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	track, thumb, _ := ui.scrollbar_rects(session.get(s, "view"))
	x := (thumb.min.x + thumb.max.x) * 0.5
	session.click_at(s, {x, track.max.y - 1})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, VIEW_SIZE.y)
	session.click_at(s, {x, track.max.y - 1})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, 2 * VIEW_SIZE.y)
	_, thumb, _ = ui.scrollbar_rects(session.get(s, "view"))
	session.click_at(s, {x, thumb.min.y - 1})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, VIEW_SIZE.y)
}) }

// What is under the pointer at a row of the view after a scroll: the row that is drawn there, not the one that was.
@(test)
a_click_lands_on_what_scrolled_there :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	mid := session.center(session.get(s, "view"))
	session.wheel(s, mid, {0, WHEEL_NOTCHES})
	session.wait_idle(s)
	b := session.get(s, "view")
	first_visible := int(b.view_off.y) / ROW_HEIGHT
	r := session.get(s, fmt.tprintf("row%d", first_visible + 1))
	testing.expect(t, r.rect.min.y >= b.rect.min.y && r.rect.max.y <= b.rect.max.y, "that row is in view")
	off_screen := session.find(s, fmt.tprintf("row%d", 0))
	testing.expect(t, off_screen == nil || off_screen.rect.max.y <= b.rect.min.y, "the first is above the view")
}) }

// A window made taller lets the content fit: the bar goes, the offset with it.
@(test)
a_bar_follows_the_box_s_size :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = FEW_ROWS * 4}
	s := session.start(t, {user = &sc, no_renderer = true, build = proc(s: ^session.Session) {
		sc := (^Scroller)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###view") {
			for i in 0 ..< sc.rows {
				ui.next({width = ui.fill(), height = ui.px(ROW_HEIGHT)})
				ui.label(fmt.tprintf("Row %d###row%d", i, i))
			}
		}
	}, size = {300, 200}})
	_, _, ok := ui.scrollbar_rects(session.get(s, "view"))
	testing.expect(t, ok, "it overflows: a bar")
	session.wheel(s, session.center(session.get(s, "view")), {0, FEW_ROWS * 4})
	session.wait_idle(s)
	testing.expect(t, session.get(s, "view").view_off.y > 0)
	session.resize(s, {300, ROW_HEIGHT * FEW_ROWS * 8})
	session.wait_idle(s)
	_, _, ok = ui.scrollbar_rects(session.get(s, "view"))
	testing.expect(t, !ok, "it all fits now")
	testing.expect_value(t, session.get(s, "view").view_off.y, 0)
}) }

// Thin (the default) is 9 px, wide the standard's 17; each arrow button is a square of the bar's thickness, at its ends,
// the track between them.
@(test)
a_bar_is_thin_or_wide :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	for size in ([2]ui.Scrollbar_Size{.Thin, .Wide}) {
		ui.set_scrollbar_size(s.state, size)
		session.frames(s, 2)
		w: f32 = size == .Wide ? 17 : 9
		view := session.get(s, "view")
		track, _, _ := ui.scrollbar_rects(view)
		start, end, has := ui.scrollbar_arrow_rects(view)
		if !testing.expectf(t, has, "%v: arrow buttons", size) { continue }
		testing.expect_value(t, track.max.x - track.min.x, w)
		testing.expect_value(t, track.max.x, view.rect.max.x)
		testing.expect_value(t, start.max - start.min, ui.Vec2{w, w})
		testing.expect_value(t, end.max - end.min, ui.Vec2{w, w})
		// (as far from each end of the box: its drawn corner, none for a square box)
		testing.expect(t, start.min.y >= view.rect.min.y && start.min.y - view.rect.min.y == view.rect.max.y - end.max.y, "the arrows at the ends of the bar")
		testing.expect(t, track.min.y == start.max.y && track.max.y == end.min.y, "the track between them")
	}
	ui.set_scrollbar_size(s.state, .Thin)
}) }

// A click on an arrow scrolls a line; held, it repeats by the clock and stops when let go.
@(test)
an_arrow_steps_a_line_and_repeats_while_held :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	start, end, has := ui.scrollbar_arrow_rects(session.get(s, "view"))
	if !testing.expect(t, has, "a bar with arrows") { return }
	down := (end.min + end.max) * 0.5
	session.click_at(s, down)
	session.wait_idle(s)
	step := session.get(s, "view").view_off.y
	testing.expect_value(t, step, line_of(s))

	session.press(s, down)
	session.advance(s, ARROW_HOLD_MS)
	session.release(s, down)
	session.wait_idle(s)
	held := session.get(s, "view").view_off.y
	testing.expectf(t, held >= step * ARROW_HOLD_STEPS_MIN, "held, it repeats: %v after a step of %v", held, step)
	session.advance(s, ARROW_HOLD_MS)
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, held)

	session.click_at(s, (start.min + start.max) * 0.5)
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, held - step)
}) }

// A held arrow repeats by the standard's times, by the frame's clock (no wait): one step at the press, none more before
// 400 ms, then one every 60 ms. The Feel's repeat (a number's buttons) is not the bar's.
@(test)
a_held_arrow_repeats_by_the_standard_s_times :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	MARGIN_MS :: 100
	REPEATS :: 5   // after the one at the delay, in the REPEATS * REPEAT_INTERVAL_MS that follow
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	f := ui.feel(s.state)
	f.repeat_delay_ms, f.repeat_interval_ms = 2000, 500
	ui.set_feel(s.state, f)
	_, end, has := ui.scrollbar_arrow_rects(session.get(s, "view"))
	if !testing.expect(t, has, "a bar with arrows") { return }
	down := (end.min + end.max) * 0.5

	session.press(s, down)
	step := session.get(s, "view").view_target.y
	testing.expect(t, step > 0, "the press steps")
	session.advance(s, REPEAT_DELAY_MS - MARGIN_MS)
	testing.expect_value(t, session.get(s, "view").view_target.y, step)
	session.advance(s, MARGIN_MS + REPEATS * REPEAT_INTERVAL_MS)
	steps := int(session.get(s, "view").view_target.y / step + 0.5)
	// (the press's, the repeat at the delay, then REPEATS more by the interval, the last perhaps a frame late)
	testing.expectf(t, steps >= 1 + REPEATS && steps <= 1 + 1 + REPEATS, "held, it repeats by 60 ms: %d steps", steps)
	session.release(s, down)
	session.wait_idle(s)
}) }

// The states, by their pixels: at rest an arrow has no button under its triangle; the pointer over the bar lights the
// buttons and the thumb; the arrow under the pointer is hot; a held thumb is pressed.
@(test)
a_bar_shows_its_states :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc})
	view := session.get(s, "view")
	track, thumb, _ := ui.scrollbar_rects(view)
	start, end, has := ui.scrollbar_arrow_rects(view)
	if !testing.expect(t, has, "a bar with arrows") { return }
	button := [2]int{int(end.min.x) + 2, int(end.min.y) + 2}   // (beside its triangle)
	face := [2]int{int(thumb.min.x) + 2, int(thumb.min.y) + 4}   // (clear of the border, the inner line and the grip)
	look :: proc(s: ^session.Session, at: [2]int) -> session.Color {
		session.wait_idle(s)
		return session.pixel(session.capture(s), at.x, at.y)
	}
	session.move(s, {f32(session.DEFAULT_SIZE.x - 1), f32(session.DEFAULT_SIZE.y - 1)})
	rest_button, rest_face := look(s, button), look(s, face)
	trough := look(s, {int(track.min.x) + 2, int(track.max.y) - 2})
	testing.expect(t, session.near(rest_button, trough, 2), "at rest: no button, the trough")

	// lit: the pointer on the track, away from the thumb and the buttons
	session.move(s, {(track.min.x + track.max.x) * 0.5, track.max.y - 2})
	lit_button, lit_face := look(s, button), look(s, face)
	testing.expect(t, !session.near(lit_button, rest_button, 2), "lit: the buttons have their fill")
	testing.expect(t, !session.near(lit_face, rest_face, 2), "lit: the thumb takes the accent")

	// hot: the pointer on the end button
	session.move(s, (end.min + end.max) * 0.5)
	hot_button := look(s, button)
	testing.expect(t, !session.near(hot_button, lit_button, 2), "hot: the button under the pointer")
	start_button := look(s, {int(start.min.x) + 2, int(start.min.y) + 2})
	testing.expect(t, session.near(start_button, lit_button, 2), "the other button stays lit")

	// pressed: the thumb held
	at := (thumb.min + thumb.max) * 0.5
	session.press(s, at)
	held_face := look(s, face)
	testing.expect(t, !session.near(held_face, lit_face, 2), "pressed: a deeper accent")
	session.release(s, at)
}) }
