package scenarios_test

// The wheel goes to the box that scrolls its way: over a wide table that scrolls only sideways, inside a page that scrolls up
// and down, a vertical wheel scrolls the page and Shift+wheel (or a sideways one) the table.

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") PAGE :: [2]int{400, 300}
@(private = "file") WIDE :: 1200      // the table's content, wider than the page
@(private = "file") TALL :: 30        // rows of the page

@(private = "file")
wheel_build :: proc(s: ^session.Session) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.View_Scroll_Y, .Clip}, "###page")
	_ = ui.signal(page)   // (a box scrolls in its signal)
	ui.push_parent(page)
	ui.next({width = ui.fill(), height = ui.px(80), axis = .X})
	table := ui.build_box({.View_Scroll_X, .Clip}, "###table")
	_ = ui.signal(table)
	ui.push_parent(table)
	ui.next({width = ui.px(WIDE), height = ui.px(80)})
	ui.build_box({}, "###wide")
	ui.pop_parent()
	for i in 0 ..< TALL {
		ui.next({width = ui.fill(), height = ui.px(40)})
		ui.build_box({}, fmt_row(i))
	}
	ui.pop_parent()
}

@(private = "file")
fmt_row :: proc(i: int) -> string {
	buf := make([]u8, 8, context.temp_allocator)
	buf[0], buf[1], buf[2], buf[3], buf[4] = '#', '#', '#', 'r', 'a' + u8(i)
	return string(buf[:5])
}

@(test)
the_wheel_goes_to_the_box_that_scrolls_its_way :: proc(t: ^testing.T) {
	s := session.start(t, {size = PAGE, build = wheel_build})
	session.frames(s, 3)
	at := session.center(session.get(s, "table"))
	session.move(s, at)
	session.event(s, {kind = .Scroll, pos = at, delta = {0, 2}, mods = {.Shift}})
	session.frames(s, 30)
	testing.expect(t, session.get(s, "table").view_off.x > 0, "Shift+wheel scrolls the table sideways")
	testing.expect_value(t, session.get(s, "page").view_off.y, 0)
	session.event(s, {kind = .Scroll, pos = at, delta = {0, 2}})
	session.frames(s, 30)
	testing.expect(t, session.get(s, "page").view_off.y > 0, "a vertical wheel over the table scrolls the page")
}
