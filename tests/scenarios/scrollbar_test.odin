package scenarios_test

// A scroll box and its bar: the wheel, the thumb, the track, the end of the content; a bar that hides, by the clock and by its pixels.

import "core:fmt"
import "core:testing"
import "../../testkit/session"
import "../../ui"

@(private = "file") VIEW_SIZE :: [2]f32{300, 200}
@(private = "file") ROW_HEIGHT :: 30
@(private = "file") ROWS :: 50
@(private = "file") FEW_ROWS :: 3
// More than the time a bar stays once it was shown (ui SCROLLBAR_REVEAL_MS), and than its fade.
@(private = "file") HIDE_WAIT_MS :: 2000
@(private = "file") WHEEL_NOTCHES :: 3
// An arrow held this long (past the delay before it repeats) scrolls at least this many steps.
@(private = "file") ARROW_HOLD_MS :: 1000
@(private = "file") ARROW_HOLD_STEPS_MIN :: 4

@(private = "file")
Scroller :: struct { rows: int, autohide: bool }

@(private = "file")
scroller_build :: proc(s: ^session.Session) {
	sc := (^Scroller)(s.user)
	ui.set_scrollbar_autohide(s.state, sc.autohide)
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
	b := session.get(s, "view")
	return b.view_bounds.y - b.size.y
}

@(test)
everything_fits_no_bar :: proc(t: ^testing.T) {
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
}

@(test)
the_wheel_scrolls_and_stops_at_the_ends :: proc(t: ^testing.T) {
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
	_, thumb, _ := ui.scrollbar_rects(session.get(s, "view"))
	track, _, _ := ui.scrollbar_rects(session.get(s, "view"))
	testing.expectf(t, abs(thumb.max.y - track.max.y) < 1, "the thumb at the end of its track: %v and %v", thumb.max.y, track.max.y)
	session.wheel(s, mid, {0, -ROWS})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "view").view_off.y, 0)
}

@(test)
the_thumb_follows_the_pointer :: proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	track, thumb, ok := ui.scrollbar_rects(session.get(s, "view"))
	if !testing.expect(t, ok) { return }
	x := (thumb.min.x + thumb.max.x) * 0.5
	grab := (thumb.min.y + thumb.max.y) * 0.5
	span := (track.max.y - track.min.y) - (thumb.max.y - thumb.min.y)
	session.drag(s, {x, grab}, {x, grab + span * 0.5})
	want := max_scroll(s) * 0.5
	testing.expectf(t, abs(session.get(s, "view").view_off.y - want) < 2, "half way along its track, half way down: %v, want %v", session.get(s, "view").view_off.y, want)
	// beyond the end: at the end
	_, thumb, _ = ui.scrollbar_rects(session.get(s, "view"))
	grab = (thumb.min.y + thumb.max.y) * 0.5
	session.drag(s, {x, grab}, {x, grab + span * 4})
	testing.expect_value(t, session.get(s, "view").view_off.y, max_scroll(s))
}

// A press on the track centres the thumb there.
@(test)
a_press_on_the_track_goes_there :: proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	track, thumb, _ := ui.scrollbar_rects(session.get(s, "view"))
	x := (thumb.min.x + thumb.max.x) * 0.5
	y := track.max.y - 1
	session.press(s, {x, y})
	session.release(s, {x, y})
	session.wait_idle(s)
	testing.expect(t, session.get(s, "view").view_off.y > max_scroll(s) * 0.5, "towards the end")
}

// What is under the pointer at a row of the view after a scroll: the row that is drawn there, not the one that was.
@(test)
a_click_lands_on_what_scrolled_there :: proc(t: ^testing.T) {
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
}

// Auto-hide: no bar at rest, the bar while the pointer is over the box, gone by the clock when it leaves; still there to grab.
@(test)
an_autohide_bar_comes_and_goes_with_the_pointer :: proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS, autohide = true}
	s := session.start(t, {build = scroller_build, user = &sc, animations = true})
	session.wait_idle(s)
	view := session.get(s, "view")
	testing.expect_value(t, ui.scrollbar_opacity(s.state, view), 0)
	_, thumb, ok := ui.scrollbar_rects(view)
	if !testing.expect(t, ok, "it has a bar to show") { return }
	inside := [2]int{int((thumb.min.x + thumb.max.x) * 0.5), int((thumb.min.y + thumb.max.y) * 0.5)}
	hidden := session.pixel(session.capture(s), inside.x, inside.y)

	session.hover(s, "view")
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 1)
	testing.expect(t, !session.near(session.pixel(session.capture(s), inside.x, inside.y), hidden), "its thumb is in the frame")

	session.move(s, {f32(session.DEFAULT_SIZE.x - 1), f32(session.DEFAULT_SIZE.y - 1)})
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 0)
	testing.expect(t, session.near(session.pixel(session.capture(s), inside.x, inside.y), hidden), "and out of it")

	// still there to grab, as soon as the pointer comes
	_, thumb, _ = ui.scrollbar_rects(session.get(s, "view"))
	x := (thumb.min.x + thumb.max.x) * 0.5
	y := (thumb.min.y + thumb.max.y) * 0.5
	session.drag(s, {x, y}, {x, y + 60})
	session.wait_idle(s)
	testing.expect(t, session.get(s, "view").view_off.y > 0, "the thumb is grabbed")
}

// Scrolled by something other than the pointer: its bar shows for a moment, wherever the pointer is, and goes by the clock.
@(test)
an_autohide_bar_reveals_itself_for_a_moment :: proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS, autohide = true}
	s := session.start(t, {build = scroller_build, user = &sc, animations = true, no_renderer = true})
	session.wait_idle(s)
	ui.scrollbar_reveal(session.get(s, "view"))
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 1)
	session.advance(s, HIDE_WAIT_MS)
	session.wait_idle(s)
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 0)
}

// Without auto-hide it always shows, and a window made taller lets the content fit: the bar goes, the offset with it.
@(test)
a_bar_follows_the_box_s_size :: proc(t: ^testing.T) {
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
	testing.expect_value(t, ui.scrollbar_opacity(s.state, session.get(s, "view")), 1)
	session.wheel(s, session.center(session.get(s, "view")), {0, FEW_ROWS * 4})
	session.wait_idle(s)
	testing.expect(t, session.get(s, "view").view_off.y > 0)
	session.resize(s, {300, ROW_HEIGHT * FEW_ROWS * 8})
	session.wait_idle(s)
	_, _, ok := ui.scrollbar_rects(session.get(s, "view"))
	testing.expect(t, !ok, "it all fits now")
	testing.expect_value(t, session.get(s, "view").view_off.y, 0)
}

// Arrow buttons (set_scrollbar_arrows): none by default; on, they take the ends of the bar from its track; a click on one
// scrolls a step, held it repeats by the clock and stops when let go.
@(test)
arrow_buttons_step_and_repeat :: proc(t: ^testing.T) {
	sc := Scroller{rows = ROWS}
	s := session.start(t, {build = scroller_build, user = &sc, no_renderer = true})
	_, _, ok := ui.scrollbar_arrow_rects(session.get(s, "view"))
	testing.expect(t, !ok, "no arrows by default")
	plain, _, _ := ui.scrollbar_rects(session.get(s, "view"))
	ui.set_scrollbar_arrows(s.state, true)
	session.frames(s, 2)
	start, end, has := ui.scrollbar_arrow_rects(session.get(s, "view"))
	if !testing.expect(t, has, "a bar with arrows") { return }
	track, _, _ := ui.scrollbar_rects(session.get(s, "view"))
	testing.expect(t, start.min.y == plain.min.y && end.max.y == plain.max.y, "the arrows at the ends of the bar")
	testing.expect(t, track.min.y == start.max.y && track.max.y == end.min.y, "the track between them")

	down := (end.min + end.max) * 0.5
	session.click_at(s, down)
	session.wait_idle(s)
	step := session.get(s, "view").view_off.y
	testing.expect(t, step > 0 && step < max_scroll(s), "a click scrolls a step")

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
}
