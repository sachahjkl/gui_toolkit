package scenarios_test

// A group of choices is one Tab stop, the chosen one, and the arrows move the choice with the keyboard
// (src/md/features/widget-table.md, G1): a segmented control (pills and words) and a row of tabs.

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Group_Run :: struct { seg, words, tab: int, look: ui.Segmented_Look }

@(private = "file")
group_build :: proc(s: ^session.Session) {
	r := (^Group_Run)(s.user)
	ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(80), height = ui.px(30)})
	_ = ui.button("###before", "Before")
	ui.next({fixed_x = 10, fixed_y = 50, width = ui.px(300), height = ui.px(30)})
	ui.segmented("###group", {"One", "Two", "Three"}, &r.seg, look = r.look)
	ui.next({fixed_x = 10, fixed_y = 90, width = ui.px(80), height = ui.px(30)})
	_ = ui.button("###after", "After")
}

@(private = "file")
focused :: proc(s: ^session.Session, name: string) -> bool {
	b := session.find(s, name)
	return b != nil && s.state.focus_key == b.key
}

@(test)
a_segmented_control_is_one_tab_stop_and_the_arrows_choose :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for look in ([2]ui.Segmented_Look{.Pills, .Text}) {
		r := Group_Run{seg = 1, look = look}
		s := session.start(t, {size = {400, 140}, user = &r, build = group_build})
		session.frames(s, 2)
		session.click(s, "before")
		session.key(s, .Tab)
		session.frames(s, 2)
		testing.expectf(t, focused(s, "seg1"), "%v: Tab lands on the chosen one", look)
		session.key(s, .Right)
		session.frames(s, 2)
		testing.expectf(t, r.seg == 2 && focused(s, "seg2"), "%v: Right chooses the next, the keyboard with it (%d)", look, r.seg)
		session.key(s, .Right)
		session.frames(s, 2)
		testing.expectf(t, r.seg == 2, "%v: no wrap at the end", look)
		session.key(s, .Home)
		session.frames(s, 2)
		testing.expectf(t, r.seg == 0 && focused(s, "seg0"), "%v: Home, the first", look)
		session.key(s, .Tab)
		session.frames(s, 2)
		testing.expectf(t, focused(s, "after"), "%v: Tab leaves the group: one stop", look)
	}
}) }

// The key is the chosen segment's face: under the pointer it does not change, nothing is drawn over it. Another
// segment's hover face keeps clear of its cell's edges: full width, it touched the key and read as a wider choice.
@(test)
a_hovered_segment_never_covers_or_touches_the_key :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Group_Run{seg = 1}
	s := session.start(t, {size = {400, 140}, user = &r, build = group_build})
	session.frames(s, 2)
	chosen, other := session.get(s, "seg1"), session.get(s, "seg2")
	testing.expect(t, .Draw_Hot_Effects not_in chosen.flags, "the chosen segment has no hover face over the key")
	testing.expect(t, .Draw_Hot_Effects in other.flags, "another segment has one")
	cell := other.parent
	testing.expectf(t, other.rect.min.x - cell.rect.min.x >= 1 && cell.rect.max.x - other.rect.max.x >= 1,
		"its face stops short of its cell's edges (%v in %v)", other.rect, cell.rect)
	before := session.capture(s)
	at := session.center(chosen)
	session.move(s, at)
	session.frames(s, 20)
	after := session.capture(s)
	testing.expect(t, session.near(session.pixel(before, int(at.x) - 20, int(at.y)), session.pixel(after, int(at.x) - 20, int(at.y))),
		"the key under the pointer looks as it did")
}) }

@(private = "file")
radios_build :: proc(s: ^session.Session) {
	r := (^Group_Run)(s.user)
	ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(80), height = ui.px(30)})
	_ = ui.button("###before", "Before")
	ui.next({fixed_x = 10, fixed_y = 50, width = ui.px(200), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###radios") {
		for name, i in ([3]string{"Small", "Medium", "Large"}) {
			ui.next({width = ui.fill(), height = ui.px(28)})
			ui.radio(fmt.tprintf("%s###r%d", name, i), name, &r.seg, i)
		}
	}
	ui.next({fixed_x = 10, fixed_y = 160, width = ui.px(80), height = ui.px(30)})
	_ = ui.button("###after", "After")
}

@(test)
radio_buttons_are_one_tab_stop_and_the_arrows_choose :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Group_Run{seg = 1}
	s := session.start(t, {size = {300, 220}, user = &r, build = radios_build})
	session.frames(s, 3)
	session.click(s, "before")
	session.key(s, .Tab)
	session.frames(s, 2)
	testing.expect(t, focused(s, "r1"), "Tab lands on the chosen radio")
	session.key(s, .Down)
	session.frames(s, 2)
	testing.expectf(t, r.seg == 2 && focused(s, "r2"), "Down chooses the next, the keyboard with it (%d)", r.seg)
	session.key(s, .Up)
	session.frames(s, 2)
	session.key(s, .Up)
	session.frames(s, 2)
	testing.expectf(t, r.seg == 0 && focused(s, "r0"), "Up twice: the first, the keyboard with it (%d)", r.seg)
	session.key(s, .Tab)
	session.frames(s, 2)
	testing.expect(t, focused(s, "after"), "Tab leaves the group: one stop")
}) }

@(private = "file")
tabs_build :: proc(s: ^session.Session) {
	r := (^Group_Run)(s.user)
	ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(360), height = ui.px(34)})
	_ = ui.tabs("###tabs", {"Alpha", "Beta", "Gamma"}, nil, &r.tab)
	ui.next({fixed_x = 10, fixed_y = 50, width = ui.px(80), height = ui.px(30)})
	_ = ui.button("###after", "After")
}

@(test)
a_row_of_tabs_moves_with_left_and_right :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Group_Run
	s := session.start(t, {size = {400, 80}, user = &r, build = tabs_build})
	session.frames(s, 2)
	session.key(s, .Tab)
	session.frames(s, 2)
	first := session.find(s, "tabs_0")
	if !testing.expect(t, first != nil && s.state.focus_key == first.key, "Tab lands on the chosen tab") { return }
	session.key(s, .Right)
	session.frames(s, 2)
	second := session.find(s, "tabs_1")
	testing.expectf(t, r.tab == 1 && second != nil && s.state.focus_key == second.key, "Right shows the next tab, the keyboard with it (%d)", r.tab)
	session.key(s, .End)
	session.frames(s, 2)
	testing.expect_value(t, r.tab, 2)
	session.key(s, .Tab)
	session.frames(s, 2)
	testing.expect(t, focused(s, "after"), "Tab leaves the row: one stop")
	// (Down is not the row's: it leaves it for what is under it, the tab chosen as it was)
	session.key(s, .Tab, mods = {.Shift})
	session.frames(s, 2)
	testing.expect(t, focused(s, "tabs_2"), "Shift+Tab: back on the chosen tab")
	session.key(s, .Down)
	session.frames(s, 2)
	testing.expect(t, r.tab == 2 && focused(s, "after"), "Down leaves the row for what is under it")
}) }
