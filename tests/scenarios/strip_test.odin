package scenarios_test

// A strip (src/md/features/strip.md): a row of choices that fits is a plain row; one that overflows shows an arrow only on
// the side that hides items; a click brings the next hidden item fully into view; at the end the arrow goes; the wheel
// scrolls it sideways; the focus that reaches an item off view reveals it; never a scroll bar nor a bar's room.

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") STRIP_ROW :: [2]f32{300, 30}
@(private = "file") STRIP_ITEM_W :: 80
@(private = "file") STRIP_PLUS_W :: 30
@(private = "file") STRIP_FEW :: 3    // 240 px: they fit beside the "+"
@(private = "file") STRIP_MANY :: 8   // 640 px: they do not

@(private = "file")
Strip_Run :: struct { items: int }

// A row of 300 px: the strip (as wide as its items, giving way first), then a "+" of 30 px.
@(private = "file")
strip_build :: proc(s: ^session.Session) {
	r := (^Strip_Run)(s.user)
	ui.next({width = ui.px(STRIP_ROW.x), height = ui.px(STRIP_ROW.y)})
	if ui.row(id = "###row") {
		if ui.strip("###strip") {
			for i in 0 ..< r.items {
				ui.next({width = ui.px(STRIP_ITEM_W), height = ui.pct(1)})
				ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###it%d", i))
			}
		}
		ui.next({width = ui.px(STRIP_PLUS_W), height = ui.pct(1)})
		ui.build_box({.Clickable, .Focusable}, "###plus")
	}
}

@(private = "file")
strip_start :: proc(t: ^testing.T, r: ^Strip_Run) -> ^session.Session {
	s := session.start(t, {build = strip_build, user = r, no_renderer = true})
	session.wait_idle(s)
	return s
}

// Never a bar on a strip, nor its room.
@(private = "file")
expect_no_bar :: proc(t: ^testing.T, s: ^session.Session, loc := #caller_location) {
	view := session.get(s, "strip_view")
	_, _, ok := ui.scrollbar_rects(view, .X)
	testing.expect(t, !ok, "no scroll bar", loc = loc)
	testing.expect_value(t, ui.scrollbar_room(view, .Y), 0, loc = loc)
	testing.expect_value(t, ui.scrollbar_room(view, .X), 0, loc = loc)
}

// `b` is wholly in the view, clear of the arrows that show.
@(private = "file")
expect_clear :: proc(t: ^testing.T, s: ^session.Session, b: ^ui.Box, loc := #caller_location) {
	view := session.get(s, "strip_view")
	lo, hi := view.rect.min.x, view.rect.max.x
	if l := session.find(s, "strip_left"); l != nil { lo = l.rect.max.x }
	if r := session.find(s, "strip_right"); r != nil { hi = r.rect.min.x }
	testing.expectf(t, b.rect.min.x >= lo - 0.5 && b.rect.max.x <= hi + 0.5, "%s in view, clear of the arrows: %v in %v .. %v", b.name, b.rect, lo, hi, loc = loc)
}

@(test)
a_strip_that_fits_shows_no_arrow :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Strip_Run{items = STRIP_FEW}
	s := strip_start(t, &r)
	testing.expect(t, session.find(s, "strip_left") == nil && session.find(s, "strip_right") == nil, "no arrow")
	testing.expect_value(t, ui.view_limit(session.get(s, "strip_view"), .X), 0)
	expect_no_bar(t, s)
	// (as wide as its items: the "+" right after the last one)
	testing.expect_value(t, session.get(s, "plus").rect.min.x, session.get(s, "it2").rect.max.x)
	// a wheel over it goes to the page: nothing to scroll
	session.wheel(s, session.center(session.get(s, "strip_view")), {0, 1})
	session.wait_idle(s)
	testing.expect_value(t, session.get(s, "strip_view").view_off.x, 0)
}) }

@(test)
an_overflowing_strip_shows_the_right_arrow_at_its_start :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Strip_Run{items = STRIP_MANY}
	s := strip_start(t, &r)
	testing.expect(t, session.find(s, "strip_right") != nil, "the right arrow")
	testing.expect(t, session.find(s, "strip_left") == nil, "no left arrow at the start")
	expect_no_bar(t, s)
	// (the strip gave way: the "+" at the row's end, the right arrow at the strip's)
	row, plus, right := session.get(s, "row"), session.get(s, "plus"), session.get(s, "strip_right")
	testing.expect_value(t, plus.rect.max.x, row.rect.max.x)
	testing.expect_value(t, right.rect.max.x, plus.rect.min.x)
	// (not a Tab stop: the items are)
	testing.expect(t, .Focusable not_in right.flags, "the arrow takes no focus")

	// it grows past its room while it is built: the arrow comes without an input
	r.items = STRIP_FEW
	session.wait_idle(s)
	testing.expect(t, session.find(s, "strip_right") == nil, "fits again: the arrow went")
	r.items = STRIP_MANY
	session.wait_idle(s)
	testing.expect(t, session.find(s, "strip_right") != nil, "overflows again: it came back")
}) }

@(test)
a_click_on_an_arrow_brings_the_next_item_fully_in_view :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Strip_Run{items = STRIP_MANY}
	s := strip_start(t, &r)
	// the first item the right arrow covers or that is past it
	right := session.get(s, "strip_right")
	next := -1
	for i in 0 ..< r.items {
		if session.get(s, fmt.tprintf("it%d", i)).rect.max.x > right.rect.min.x + 0.5 { next = i; break }
	}
	if !testing.expect(t, next > 0, "an item hidden past the right edge") { return }
	session.click(s, "strip_right")
	session.wait_idle(s)
	expect_clear(t, s, session.get(s, fmt.tprintf("it%d", next)))
	testing.expect(t, session.find(s, "strip_left") != nil, "the left arrow: items hide at the start now")
	expect_no_bar(t, s)

	// back: the left arrow brings the item it hid
	view := session.get(s, "strip_view")
	left := session.get(s, "strip_left")
	prev := -1
	for i := r.items - 1; i >= 0; i -= 1 {
		if session.get(s, fmt.tprintf("it%d", i)).rect.min.x < left.rect.max.x - 0.5 { prev = i; break }
	}
	if !testing.expect(t, prev >= 0 && view.view_off.x > 0, "an item hidden at the start") { return }
	session.click(s, "strip_left")
	session.wait_idle(s)
	expect_clear(t, s, session.get(s, fmt.tprintf("it%d", prev)))
}) }

@(test)
at_the_end_the_right_arrow_goes :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Strip_Run{items = STRIP_MANY}
	s := strip_start(t, &r)
	for _ in 0 ..< r.items {
		if session.find(s, "strip_right") == nil { break }
		session.click(s, "strip_right")
		session.wait_idle(s)
	}
	view := session.get(s, "strip_view")
	testing.expect(t, session.find(s, "strip_right") == nil, "no right arrow at the end")
	testing.expect(t, session.find(s, "strip_left") != nil, "the left one")
	testing.expect_value(t, view.view_off.x, ui.view_limit(view, .X))
	expect_clear(t, s, session.get(s, fmt.tprintf("it%d", r.items - 1)))
	expect_no_bar(t, s)
}) }

// Held, an arrow repeats by the Feel's times: more than one item comes, by the session's clock.
@(test)
a_held_arrow_repeats :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Strip_Run{items = STRIP_MANY}
	s := strip_start(t, &r)
	at := session.center(session.get(s, "strip_right"))
	session.press(s, at)
	once := session.get(s, "strip_view").view_target.x
	testing.expect(t, once > 0, "the press steps")
	f := ui.feel(s.state)
	session.advance(s, f64(f.repeat_delay_ms + 2 * f.repeat_interval_ms))
	testing.expect(t, session.get(s, "strip_view").view_target.x > once, "held, it steps again")
	session.release(s, at)
	session.wait_idle(s)
}) }

@(test)
the_wheel_scrolls_a_strip_sideways :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Strip_Run{items = STRIP_MANY}
	s := strip_start(t, &r)
	mid := session.center(session.get(s, "strip_view"))
	// up and down: sideways (down toward the end)
	session.wheel(s, mid, {0, 1})
	session.wait_idle(s)
	off := session.get(s, "strip_view").view_off.x
	testing.expect(t, off > 0, "a wheel down scrolls it toward its end")
	session.wheel(s, mid, {0, -1})
	session.wait_idle(s)
	testing.expect(t, session.get(s, "strip_view").view_off.x < off, "a wheel up scrolls it back")
	// sideways (a touchpad), and Shift+wheel
	session.wheel(s, mid, {1, 0})
	session.wait_idle(s)
	off = session.get(s, "strip_view").view_off.x
	testing.expect(t, off > 0, "a sideways wheel scrolls it")
	session.wheel(s, mid, {0, 1}, {.Shift})
	session.wait_idle(s)
	testing.expect(t, session.get(s, "strip_view").view_off.x > off, "Shift+wheel scrolls it")
	expect_no_bar(t, s)
}) }

// Tab goes through the items, not the arrows; the item it reaches off view comes into view, clear of the arrows.
@(test)
the_focus_on_an_item_off_view_reveals_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Strip_Run{items = STRIP_MANY}
	s := strip_start(t, &r)
	last := session.get(s, fmt.tprintf("it%d", r.items - 1)).key
	for _ in 0 ..< r.items + 2 {
		session.key(s, .Tab)
		session.wait_idle(s)
		k := s.state.focus_key
		for name in ([2]string{"strip_left", "strip_right"}) {
			if a := session.find(s, name); a != nil { testing.expect(t, k != a.key, "an arrow is no Tab stop") }
		}
		view := session.get(s, "strip_view")
		for c := view.first; c != nil; c = c.next {
			if c.key == k { expect_clear(t, s, c) }
		}
		if k == last { break }
	}
	testing.expect_value(t, s.state.focus_key, last)
	testing.expect(t, session.find(s, "strip_right") == nil, "at the end: no right arrow")
	expect_no_bar(t, s)
}) }

@(private = "file")
Tabs_Run :: struct { sel: int }

// ui.tabs is a strip: too many tabs for their row scroll with arrows, never a bar.
@(test)
tabs_that_overflow_scroll_with_arrows :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Tabs_Run{}
	s := session.start(t, {user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Tabs_Run)(s.user)
		labels := []string{"Settings", "Filter lists", "My filters", "My rules", "Whitelist", "Journal", "Statistics", "About"}
		ui.next({width = ui.px(STRIP_ROW.x), height = ui.px(STRIP_ROW.y)})
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
	testing.expect(t, session.get(s, "strip_view").view_off.x > 0, "the arrow scrolls the tabs")
}) }
