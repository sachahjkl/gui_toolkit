package scenarios_test

// A strip (src/md/features/strip.md), on each axis and on both: one that fits is a plain row (column); one that overflows
// shows an arrow only on a side that hides choices; a click brings the next hidden choice fully in view, clear of the
// arrows; at the end the arrow goes; held, it repeats; every wheel scrolls a strip of one axis along it, a block's wheel
// is the page's (Y, Shift X, Ctrl the zoom); a strip that fits lets the wheel through; the focus that reaches a choice off
// view reveals it; never a scroll bar nor a bar's room.

import "core:fmt"
import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") STRIP_LONG :: 300     // the row's length along the strip's axis
@(private = "file") STRIP_THICK :: 30     // ... and across it
@(private = "file") STRIP_ITEM :: 80      // a choice's length along the axis
@(private = "file") STRIP_PLUS :: 30      // the "+" after the strip
@(private = "file") STRIP_FEW :: 3        // 240 px: they fit beside the "+"
@(private = "file") STRIP_MANY :: 8       // 640 px: they do not

@(private = "file")
// beside: the "+"'s length (STRIP_PLUS by default); reveal: the chosen choice + 1 (0: none), given to strip_reveal
Strip_Run :: struct { items: int, axis: ui.Axis, beside: f32, reveal: int }

// `v` along axis `a` and `across` across it, as [width, height].
@(private = "file")
along :: proc(a: ui.Axis, v, across: f32) -> [2]f32 { return a == .X ? [2]f32{v, across} : [2]f32{across, v} }

// A row (a column for .Y) STRIP_LONG long: the strip (as long as its choices, giving way first), then a "+".
@(private = "file")
strip_build :: proc(s: ^session.Session) {
	r := (^Strip_Run)(s.user)
	size := along(r.axis, STRIP_LONG, STRIP_THICK)
	ui.next({width = ui.px(size.x), height = ui.px(size.y), axis = r.axis})
	if ui.parent(ui.build_box({}, "###row")) {
		if ui.strip("###strip", {axes = {r.axis}}) {
			for i in 0 ..< r.items {
				it := along(r.axis, STRIP_ITEM, 0)
				if r.axis == .X { ui.next({width = ui.px(it.x), height = ui.pct(1)}) } else { ui.next({width = ui.pct(1), height = ui.px(it.y)}) }
				b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###it%d", i))
				if i == r.reveal - 1 { ui.strip_reveal(b) }
			}
		}
		plus := r.beside > 0 ? r.beside : STRIP_PLUS
		if r.axis == .X { ui.next({width = ui.px(plus), height = ui.pct(1)}) } else { ui.next({width = ui.pct(1), height = ui.px(plus)}) }
		ui.build_box({.Clickable, .Focusable}, "###plus")
	}
}

@(private = "file")
strip_start :: proc(t: ^testing.T, r: ^Strip_Run) -> ^session.Session {
	s := session.start(t, {build = strip_build, user = r, no_renderer = true})
	session.wait_idle(s)
	return s
}

// The names of the arrows at the start and at the end of axis `a`.
@(private = "file")
start_arrow :: proc(a: ui.Axis) -> string { return a == .X ? "strip_left" : "strip_up" }
@(private = "file")
end_arrow :: proc(a: ui.Axis) -> string { return a == .X ? "strip_right" : "strip_down" }

@(private = "file")
off :: proc(s: ^session.Session, a: ui.Axis) -> f32 { return session.get(s, "strip_view").view_off[int(a)] }

// Never a bar on a strip, nor its room.
@(private = "file")
expect_no_bar :: proc(t: ^testing.T, s: ^session.Session, loc := #caller_location) {
	view := session.get(s, "strip_view")
	for a in ui.Axis {
		_, _, ok := ui.scrollbar_rects(view, a)
		testing.expect(t, !ok, "no scroll bar", loc = loc)
		testing.expect_value(t, ui.scrollbar_room(view, a), 0, loc = loc)
	}
}

// `b` is wholly in the view along `a`, clear of the arrows that show there.
@(private = "file")
expect_clear :: proc(t: ^testing.T, s: ^session.Session, b: ^ui.Box, a: ui.Axis, loc := #caller_location) {
	i := int(a)
	view := session.get(s, "strip_view")
	lo, hi := view.rect.min[i], view.rect.max[i]
	if l := session.find(s, start_arrow(a)); l != nil { lo = l.rect.max[i] }
	if r := session.find(s, end_arrow(a)); r != nil { hi = r.rect.min[i] }
	testing.expectf(t, b.rect.min[i] >= lo - 0.5 && b.rect.max[i] <= hi + 0.5, "%v: %s in view, clear of the arrows: %v in %v .. %v", a, b.name, b.rect, lo, hi, loc = loc)
}

@(test)
a_strip_that_fits_shows_no_arrow :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		r := Strip_Run{items = STRIP_FEW, axis = a}
		s := strip_start(t, &r)
		testing.expectf(t, session.find(s, start_arrow(a)) == nil && session.find(s, end_arrow(a)) == nil, "%v: no arrow", a)
		testing.expect_value(t, ui.view_limit(session.get(s, "strip_view"), a), 0)
		expect_no_bar(t, s)
		// (as long as its choices: the "+" right after the last one)
		testing.expect_value(t, session.get(s, "plus").rect.min[int(a)], session.get(s, "it2").rect.max[int(a)])
	}
}) }

@(test)
an_overflowing_strip_shows_the_end_arrow_at_its_start :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		i := int(a)
		r := Strip_Run{items = STRIP_MANY, axis = a}
		s := strip_start(t, &r)
		testing.expectf(t, session.find(s, end_arrow(a)) != nil, "%v: the end arrow", a)
		testing.expectf(t, session.find(s, start_arrow(a)) == nil, "%v: no start arrow at the start", a)
		expect_no_bar(t, s)
		// (the strip gave way: the "+" at the row's end, the arrow at the strip's, across the whole strip)
		row, plus, arrow, strip := session.get(s, "row"), session.get(s, "plus"), session.get(s, end_arrow(a)), session.get(s, "strip")
		testing.expect_value(t, plus.rect.max[i], row.rect.max[i])
		testing.expect_value(t, arrow.rect.max[i], plus.rect.min[i])
		testing.expect_value(t, arrow.rect.min[1 - i], strip.rect.min[1 - i])
		testing.expect_value(t, arrow.rect.max[1 - i], strip.rect.max[1 - i])
		testing.expect(t, .Focusable not_in arrow.flags, "the arrow takes no focus")
		// (nothing of the content shows under the arrow: its band is held clear, the fade is beyond it)
		view := session.get(s, "strip_view")
		testing.expect_value(t, view.edge_hold[i + 2], arrow.rect.max[i] - arrow.rect.min[i])
		testing.expect(t, view.edge_fade[i + 2] > 0, "a fade beyond the arrow")
		testing.expect_value(t, view.edge_hold[i], 0)

		// it grows past its room and back while it is built: the arrow comes and goes without an input
		r.items = STRIP_FEW
		session.wait_idle(s)
		testing.expectf(t, session.find(s, end_arrow(a)) == nil, "%v: fits again: the arrow went", a)
		r.items = STRIP_MANY
		session.wait_idle(s)
		testing.expectf(t, session.find(s, end_arrow(a)) != nil, "%v: overflows again: it came back", a)
	}
}) }

@(test)
a_click_on_an_arrow_brings_the_next_choice_fully_in_view :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		i := int(a)
		r := Strip_Run{items = STRIP_MANY, axis = a}
		s := strip_start(t, &r)
		// the first choice the end arrow covers or that is past it
		arrow := session.get(s, end_arrow(a))
		next := -1
		for k in 0 ..< r.items {
			if session.get(s, fmt.tprintf("it%d", k)).rect.max[i] > arrow.rect.min[i] + 0.5 { next = k; break }
		}
		if !testing.expectf(t, next > 0, "%v: a choice hidden past the end", a) { continue }
		session.click(s, end_arrow(a))
		session.wait_idle(s)
		expect_clear(t, s, session.get(s, fmt.tprintf("it%d", next)), a)
		testing.expectf(t, session.find(s, start_arrow(a)) != nil, "%v: the start arrow: choices hide at the start now", a)
		expect_no_bar(t, s)

		// back: the start arrow brings the choice it hid
		start := session.get(s, start_arrow(a))
		prev := -1
		for k := r.items - 1; k >= 0; k -= 1 {
			if session.get(s, fmt.tprintf("it%d", k)).rect.min[i] < start.rect.max[i] - 0.5 { prev = k; break }
		}
		if !testing.expectf(t, prev >= 0 && off(s, a) > 0, "%v: a choice hidden at the start", a) { continue }
		session.click(s, start_arrow(a))
		session.wait_idle(s)
		expect_clear(t, s, session.get(s, fmt.tprintf("it%d", prev)), a)
	}
}) }

@(test)
at_the_end_the_end_arrow_goes :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		r := Strip_Run{items = STRIP_MANY, axis = a}
		s := strip_start(t, &r)
		for _ in 0 ..< r.items {
			if session.find(s, end_arrow(a)) == nil { break }
			session.click(s, end_arrow(a))
			session.wait_idle(s)
		}
		testing.expectf(t, session.find(s, end_arrow(a)) == nil, "%v: no end arrow at the end", a)
		testing.expectf(t, session.find(s, start_arrow(a)) != nil, "%v: the start one", a)
		testing.expect_value(t, off(s, a), ui.view_limit(session.get(s, "strip_view"), a))
		expect_clear(t, s, session.get(s, fmt.tprintf("it%d", r.items - 1)), a)
		expect_no_bar(t, s)
	}
}) }

// Held, an arrow repeats by the Feel's times: more than one choice comes, by the session's clock.
@(test)
a_held_arrow_repeats :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		r := Strip_Run{items = STRIP_MANY, axis = a}
		s := strip_start(t, &r)
		at := session.center(session.get(s, end_arrow(a)))
		session.press(s, at)
		once := session.get(s, "strip_view").view_target[int(a)]
		testing.expectf(t, once > 0, "%v: the press steps", a)
		f := ui.feel(s.state)
		session.advance(s, f64(f.repeat_delay_ms + 2 * f.repeat_interval_ms))
		testing.expectf(t, session.get(s, "strip_view").view_target[int(a)] > once, "%v: held, it steps again", a)
		session.release(s, at)
		session.wait_idle(s)
	}
}) }

// On one axis, every wheel scrolls the strip along it, smoothly by the wheel's step as a scroll area (the notch, a
// touchpad's fraction): the up-and-down wheel, Shift+wheel, a sideways delta. Only along its axis.
@(test)
every_wheel_scrolls_a_strip_along_its_axis :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		r := Strip_Run{items = STRIP_MANY, axis = a}
		s := strip_start(t, &r)
		mid := session.center(session.get(s, "strip_view"))
		forms := [?]struct { d: [2]f32, mods: platform.Modifiers, what: string }{
			{{0, 1}, {}, "the wheel"},
			{{0, 1}, {.Shift}, "Shift+wheel"},
			{{1, 0}, {}, "a sideways delta"},
			{{0, 0.25}, {}, "a touchpad's fraction"},
		}
		for f in forms {
			// (from the start each time: a notch is many pixels, the strip only a few hundred)
			session.get(s, "strip_view").view_target = {}
			session.wait_idle(s)
			session.wheel(s, mid, f.d, f.mods)
			session.wait_idle(s)
			testing.expectf(t, off(s, a) > 0, "%v: %s scrolls it along its axis", a, f.what)
			testing.expect_value(t, off(s, a == .X ? ui.Axis.Y : ui.Axis.X), 0)
		}
		// (a fraction of a notch moves less than a notch: no page per event)
		session.get(s, "strip_view").view_target = {}
		session.wait_idle(s)
		x := off(s, a)
		session.wheel(s, mid, {0, 0.25})
		session.wait_idle(s)
		small := off(s, a) - x
		x = off(s, a)
		session.wheel(s, mid, {0, 1})
		session.wait_idle(s)
		testing.expectf(t, small > 0 && small < off(s, a) - x, "%v: a quarter notch %v moves less than a notch %v", a, small, off(s, a) - x)
		x = off(s, a)
		session.wheel(s, mid, {0, -1})
		session.wait_idle(s)
		testing.expectf(t, off(s, a) < x, "%v: the wheel up scrolls it back", a)
		expect_no_bar(t, s)
	}
}) }

@(private = "file")
Page_Run :: struct { items: int, axis: ui.Axis }

// A page that scrolls (both ways), a strip near its top.
@(private = "file")
page_build :: proc(s: ^session.Session) {
	r := (^Page_Run)(s.user)
	ui.next({width = ui.px(400), height = ui.px(300), flags = {.View_Scroll_X, .Allow_Overflow_X}})
	if ui.scroll_y("###page") {
		size := along(r.axis, STRIP_LONG, STRIP_THICK)
		ui.next({width = ui.px(size.x), height = ui.px(size.y), axis = r.axis})
		if ui.parent(ui.build_box({}, "###row")) {
			if ui.strip("###strip", {axes = {r.axis}}) {
				for i in 0 ..< r.items {
					if r.axis == .X { ui.next({width = ui.px(STRIP_ITEM), height = ui.pct(1)}) } else { ui.next({width = ui.pct(1), height = ui.px(STRIP_ITEM)}) }
					ui.build_box({.Clickable}, fmt.tprintf("###it%d", i))
				}
			}
		}
		ui.next({width = ui.px(1200), height = ui.px(1200)})
		ui.build_box({}, "###tall")
	}
}

// A strip that fits lets every wheel through to the page around it; one that overflows takes it.
@(test)
a_strip_that_fits_lets_the_wheel_through :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		r := Page_Run{items = STRIP_FEW, axis = a}
		s := session.start(t, {build = page_build, user = &r, no_renderer = true})
		session.wait_idle(s)
		mid := session.center(session.get(s, "strip_view"))
		session.wheel(s, mid, {0, 1})
		session.wait_idle(s)
		testing.expectf(t, session.get(s, "page").view_off.y > 0, "%v: it fits: the wheel scrolls the page", a)
		session.wheel(s, mid, {0, 1}, {.Shift})
		session.wait_idle(s)
		testing.expectf(t, session.get(s, "page").view_off.x > 0, "%v: Shift+wheel too, sideways", a)

		r.items = STRIP_MANY
		session.get(s, "page").view_target = {}   // (the strip back in the page's view)
		session.wait_idle(s)
		page := session.get(s, "page").view_off
		mid = session.center(session.get(s, "strip_view"))
		session.wheel(s, mid, {0, 1})
		session.wait_idle(s)
		testing.expectf(t, session.get(s, "page").view_off == page, "%v: it overflows: the page stays", a)
		testing.expectf(t, off(s, a) > 0, "%v: the strip scrolls", a)
	}
}) }

// Beside strict boxes that take nearly the whole row, a strip gives way, but keeps its largest choice and an arrow: the
// press meant for its first choice still lands on it (a stack of views in a narrow side zone).
@(test)
a_strip_keeps_its_largest_choice_and_an_arrow :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		i := int(a)
		r := Strip_Run{items = STRIP_MANY, axis = a, beside = STRIP_LONG - 20}   // (strict: it leaves the strip 20 px)
		s := strip_start(t, &r)
		strip, arrow := session.get(s, "strip"), session.get(s, end_arrow(a))
		testing.expect_value(t, strip.rect.max[i] - strip.rect.min[i], STRIP_ITEM + (arrow.rect.max[i] - arrow.rect.min[i]))
		testing.expect_value(t, arrow.rect.max[i], strip.rect.max[i])
		// (a click on the first choice's middle lands on it, not on what is beside the strip: it takes the focus)
		session.click(s, "it0")
		testing.expect_value(t, s.state.focus_key, session.get(s, "it0").key)
	}
}) }

// The very first frame the window draws (session.start makes one, no more): a strip that overflows has its least size
// and its end arrow there, its band under the arrow held clear, no start arrow. Not a frame later: the last layout's
// measures, none at a first build, gave the strip nearly nothing for a frame, and a click in it landed beside.
@(test)
the_first_frame_has_the_least_size_and_the_arrow :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		i := int(a)
		for beside in ([2]f32{STRIP_PLUS, STRIP_LONG - 20}) {
			r := Strip_Run{items = STRIP_MANY, axis = a, beside = beside}
			s := session.start(t, {build = strip_build, user = &r, no_renderer = true})   // (one frame)
			strip, arrow := session.find(s, "strip"), session.find(s, end_arrow(a))
			if !testing.expectf(t, strip != nil && arrow != nil, "%v, %v beside: the strip and its end arrow in the first frame", a, beside) { continue }
			length := strip.rect.max[i] - strip.rect.min[i]
			// (beside a "+": the row less the "+"; beside a box that leaves 20 px: its least, a choice and an arrow)
			want := beside == STRIP_PLUS ? f32(STRIP_LONG - STRIP_PLUS) : STRIP_ITEM + (arrow.rect.max[i] - arrow.rect.min[i])
			testing.expectf(t, length == want, "%v, %v beside: the strip %v long in the first frame, want %v", a, beside, length, want)
			testing.expect_value(t, arrow.rect.max[i], strip.rect.max[i])
			testing.expectf(t, session.find(s, start_arrow(a)) == nil, "%v: no start arrow", a)
			testing.expect_value(t, session.get(s, "strip_view").edge_hold[i + 2], arrow.rect.max[i] - arrow.rect.min[i])
		}
	}
}) }

// The first frame (session.start's single frame) of a strip whose chosen choice is its last: that choice is in view,
// clear of the arrows, the start arrow shows; the offset does not move in the frames after (no jump after the first show).
@(test)
the_first_frame_shows_the_chosen_choice :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		r := Strip_Run{items = STRIP_MANY, axis = a, reveal = STRIP_MANY}
		s := session.start(t, {build = strip_build, user = &r, no_renderer = true})   // (one frame)
		last := session.find(s, fmt.tprintf("it%d", STRIP_MANY - 1))
		if !testing.expectf(t, last != nil, "%v: the last choice laid out in the first frame", a) { continue }
		expect_clear(t, s, last, a)
		testing.expectf(t, session.find(s, start_arrow(a)) != nil, "%v: the start arrow in the first frame", a)
		first := off(s, a)
		testing.expectf(t, first > 0, "%v: the first frame already scrolled to it", a)
		session.wait_idle(s)
		testing.expect_value(t, off(s, a), first)
		expect_clear(t, s, session.get(s, fmt.tprintf("it%d", STRIP_MANY - 1)), a)
	}
}) }

// Tab goes through the choices, not the arrows; the choice it reaches off view comes into view, clear of the arrows.
@(test)
the_focus_on_a_choice_off_view_reveals_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for a in ui.Axis {
		r := Strip_Run{items = STRIP_MANY, axis = a}
		s := strip_start(t, &r)
		last := session.get(s, fmt.tprintf("it%d", r.items - 1)).key
		for _ in 0 ..< r.items + 2 {
			session.key(s, .Tab)
			session.wait_idle(s)
			k := s.state.focus_key
			for name in ([2]string{start_arrow(a), end_arrow(a)}) {
				if b := session.find(s, name); b != nil { testing.expect(t, k != b.key, "an arrow is no Tab stop") }
			}
			view := session.get(s, "strip_view")
			for c := view.first; c != nil; c = c.next { if c.key == k { expect_clear(t, s, c, a) } }
			if k == last { break }
		}
		testing.expect_value(t, s.state.focus_key, last)
		testing.expectf(t, session.find(s, end_arrow(a)) == nil, "%v: at the end: no end arrow", a)
		expect_no_bar(t, s)
	}
}) }

@(private = "file") BLOCK_ROWS :: 6
@(private = "file") BLOCK_COLS :: 6
@(private = "file") BLOCK_CELL :: [2]f32{80, 40}   // 480 × 240 of choices in a block of 300 × 200

// A block of choices that overflows both ways: rows of buttons (the rows are not choices, their buttons are).
@(private = "file")
block_build :: proc(s: ^session.Session) {
	ui.next({width = ui.px(STRIP_LONG), height = ui.px(200)})
	if ui.strip("###strip", {axes = {.X, .Y}}) {
		for row in 0 ..< BLOCK_ROWS {
			ui.next({width = ui.children_sum(), height = ui.px(BLOCK_CELL.y), axis = .X})
			if ui.parent(ui.build_box({}, fmt.tprintf("###r%d", row))) {
				for col in 0 ..< BLOCK_COLS {
					ui.next({width = ui.px(BLOCK_CELL.x), height = ui.pct(1)})
					ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###c%d_%d", row, col))
				}
			}
		}
	}
}

// Both axes: an arrow on each side that hides choices, their corners kept clear; the plain wheel scrolls Y only,
// Shift+wheel X only, Ctrl+wheel is the zoom and moves nothing; each arrow steps its own axis; the focus reveals both ways.
@(test)
a_block_of_choices_scrolls_both_ways :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {build = block_build, no_renderer = true})
	session.wait_idle(s)
	testing.expect(t, session.find(s, "strip_right") != nil && session.find(s, "strip_down") != nil, "the right and the down arrows")
	testing.expect(t, session.find(s, "strip_left") == nil && session.find(s, "strip_up") == nil, "none at the start")
	right, down, strip := session.get(s, "strip_right"), session.get(s, "strip_down"), session.get(s, "strip")
	testing.expect(t, right.rect.max.y <= down.rect.min.y && down.rect.max.x <= right.rect.min.x, "the corner between them is clear")
	testing.expect(t, right.rect.min.y > strip.rect.min.y && down.rect.min.x > strip.rect.min.x, "each short of the other axis's sides")
	expect_no_bar(t, s)
	mid := session.center(session.get(s, "strip_view"))

	session.wheel(s, mid, {0.5, 0.5})
	session.wait_idle(s)
	testing.expect(t, off(s, .X) > 0 && off(s, .Y) > 0, "a touchpad's 2D delta scrolls both")
	session.get(s, "strip_view").view_target = {}
	session.wait_idle(s)

	session.wheel(s, mid, {0, 1})
	session.wait_idle(s)
	testing.expect(t, off(s, .Y) > 0, "the wheel scrolls Y")
	testing.expect_value(t, off(s, .X), 0)
	y := off(s, .Y)
	session.wheel(s, mid, {0, 1}, {.Shift})
	session.wait_idle(s)
	testing.expect(t, off(s, .X) > 0, "Shift+wheel scrolls X")
	testing.expect_value(t, off(s, .Y), y)
	x := off(s, .X)
	zoom := ui.zoom(s.state)
	session.wheel(s, mid, {0, -1}, {.Ctrl})
	session.wait_idle(s)
	testing.expect_value(t, off(s, .X), x)
	testing.expect_value(t, off(s, .Y), y)
	testing.expect(t, ui.zoom(s.state) != zoom, "Ctrl+wheel is the zoom")
	ui.set_zoom(s.state, zoom)
	session.wait_idle(s)

	// each arrow its axis: back to the start, then a step right and a step down
	session.get(s, "strip_view").view_target = {}
	session.wait_idle(s)
	session.click(s, "strip_right")
	session.wait_idle(s)
	testing.expect(t, off(s, .X) > 0 && off(s, .Y) == 0, "the right arrow steps X")
	expect_clear(t, s, session.get(s, "c0_3"), .X)
	session.click(s, "strip_down")
	session.wait_idle(s)
	testing.expect(t, off(s, .Y) > 0, "the down arrow steps Y")
	expect_clear(t, s, session.get(s, "c4_3"), .Y)

	// the focus on the last choice: in view both ways
	last := session.get(s, fmt.tprintf("c%d_%d", BLOCK_ROWS - 1, BLOCK_COLS - 1)).key
	for _ in 0 ..< BLOCK_ROWS * BLOCK_COLS + 1 {
		session.key(s, .Tab)
		if s.state.focus_key == last { break }
	}
	session.wait_idle(s)
	testing.expect_value(t, s.state.focus_key, last)
	c := session.get(s, fmt.tprintf("c%d_%d", BLOCK_ROWS - 1, BLOCK_COLS - 1))
	expect_clear(t, s, c, .X)
	expect_clear(t, s, c, .Y)
	expect_no_bar(t, s)
}) }

@(private = "file")
Tabs_Run :: struct { sel: int }

// ui.tabs is a strip: too many tabs for their row scroll with arrows, never a bar; the chosen one is brought into view.
@(test)
tabs_that_overflow_scroll_with_arrows :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Tabs_Run{}
	s := session.start(t, {user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Tabs_Run)(s.user)
		labels := []string{"Settings", "Filter lists", "My filters", "My rules", "Whitelist", "Journal", "Statistics", "About"}
		ui.next({width = ui.px(STRIP_LONG), height = ui.px(STRIP_THICK)})
		if ui.row(id = "###row") { ui.tabs("###tabs", labels, nil, &r.sel) }
	}})
	session.wait_idle(s)
	testing.expect(t, session.find(s, "strip_right") != nil, "the right arrow")
	view := session.get(s, "strip_view")
	_, _, ok := ui.scrollbar_rects(view, .X)
	testing.expect(t, !ok, "no scroll bar under the tabs")
	testing.expect_value(t, ui.scrollbar_room(view, .Y), 0)
	session.click(s, "strip_right")
	session.wait_idle(s)
	testing.expect(t, off(s, .X) > 0, "the arrow scrolls the tabs")
	// the last tab chosen by the program: it comes into view
	r.sel = 7
	session.wait_idle(s)
	expect_clear(t, s, session.get(s, "tabs_7"), .X)
}) }
