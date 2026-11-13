package data_views_test

// A strip of cells on one line that scrolls sideways; "Show all" lays them out as a grid wrapped to the width, "Show fewer"
// folds them back. With few cells, no button.

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
Strip :: struct { open: bool, count: int }

@(private = "file")
strip_build :: proc(s: ^session.Session) {
	st := (^Strip)(s.user)
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(400), height = ui.px(400), axis = .Y})
	if ui.column(id = "###page") {
		if ui.strip_grid("###g", &st.open, {8, 8}) {
			for i in 0 ..< st.count {
				ui.next({width = ui.px(120), height = ui.px(40), bg = {0.3, 0.3, 0.3, 1}})
				ui.build_box({.Draw_Background}, fmt.tprintf("###c%d", i))
			}
		}
	}
}

@(test)
a_strip_opens_into_a_grid :: proc(t: ^testing.T) {
	st := Strip{count = 9}
	s := session.start(t, {size = {400, 400}, user = &st, build = strip_build})
	session.frames(s, 3)
	c0, c8 := session.get(s, "c0"), session.get(s, "c8")
	testing.expectf(t, c8.rect.min.y == c0.rect.min.y, "folded: one line (%v, %v)", c0.rect, c8.rect)
	testing.expect(t, c8.rect.min.x > 400, "past the view: it scrolls")
	testing.expect(t, session.find(s, "strip_toggle") != nil, "Show all")
	session.click(s, "strip_toggle")
	session.frames(s, 3)
	testing.expect(t, st.open, "open")
	c0, c8 = session.get(s, "c0"), session.get(s, "c8")
	testing.expectf(t, c8.rect.min.y > c0.rect.max.y && c8.rect.max.x <= 400.5, "a grid, wrapped to the width: %v", c8.rect)
	session.click(s, "strip_toggle")
	session.frames(s, 3)
	testing.expect(t, !st.open, "folded again")
}

@(test)
a_short_strip_has_no_button :: proc(t: ^testing.T) {
	st := Strip{count = 2}
	s := session.start(t, {size = {400, 400}, user = &st, build = strip_build})
	session.frames(s, 3)
	testing.expect(t, session.find(s, "strip_toggle") == nil, "all on the line: nothing to show")
}

// A mouse's wheel turns one way only: over a line that is cut, it scrolls the line sideways; over one that holds all its
// cells, it goes to the page.
@(test)
the_wheel_scrolls_a_strip_sideways :: proc(t: ^testing.T) {
	st := Strip{count = 9}
	s := session.start(t, {size = {400, 400}, user = &st, build = strip_build})
	session.frames(s, 3)
	x := session.get(s, "c0").rect.min.x
	session.wheel(s, session.center(session.get(s, "c0")), {0, 3})
	session.wait_idle(s)
	testing.expectf(t, session.get(s, "c0").rect.min.x < x - 1, "the line went left: %v, then %v", x, session.get(s, "c0").rect.min.x)
	short := Strip{count = 2}
	s2 := session.start(t, {size = {400, 400}, user = &short, build = strip_build})
	session.frames(s2, 3)
	view := session.get(s2, "strip_view")
	testing.expect(t, .Scroll_Self not_in view.flags, "all on the line: the wheel is the page's")
}

// A line that is cut has its bar under its cells, not over them, and a fade at the side that hides cells: at the right while
// it is at its start, at the left once at its end.
@(test)
a_cut_strip_has_its_bar_under_it_and_fades_where_it_goes_on :: proc(t: ^testing.T) {
	st := Strip{count = 9}
	s := session.start(t, {size = {400, 400}, user = &st, build = strip_build})
	session.frames(s, 3)
	view, c0 := session.get(s, "strip_view"), session.get(s, "c0")
	bar, _, ok := ui.scrollbar_rects(view, .X)
	if testing.expect(t, ok, "a bar") {
		testing.expectf(t, bar.min.y >= c0.rect.max.y - 0.5, "the bar %v under the cells %v", bar, c0.rect)
	}
	testing.expectf(t, view.edge_fade[0] == 0 && view.edge_fade[2] > 0, "at its start: a fade at the right only, %v", view.edge_fade)
	view.view_target.x = ui.view_limit(view, .X)
	session.wait_idle(s)
	view = session.get(s, "strip_view")
	testing.expectf(t, view.edge_fade[0] > 0 && view.edge_fade[2] == 0, "at its end: a fade at the left only, %v", view.edge_fade)
}
