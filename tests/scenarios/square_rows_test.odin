package scenarios_test

// A row of a list, of a table or of a menu is square, whatever radius the style around it has: a selected row's fill runs
// from edge to edge, row under row.

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
Rows :: struct { list: ui.List_State, menu_open: bool }

@(test)
a_row_is_square :: proc(t: ^testing.T) {
	r: Rows
	s := session.start(t, {size = {400, 300}, user = &r, build = proc(s: ^session.Session) {
		r := (^Rows)(s.user)
		if ui.style({radius = 10}) {
			ui.next({width = ui.px(300), height = ui.px(200)})
			if ui.list("###l", &r.list) {
				for i in 0 ..< 3 { ui.list_row(&r.list, i, "row") }
			}
			key := ui.key_from_string(0, "m")
			if !r.menu_open { r.menu_open = true; ui.ctx_menu_open(key, {50, 50}) }
			if ui.ctx_menu(key) { ui.menu_item("An item") }
		}
	}})
	session.frames(s, 3)
	row := session.find(s, "lrow_0")
	if testing.expect(t, row != nil, "a list's row") { testing.expect_value(t, row.radius, 0) }
	item: ^ui.Box
	for k, b in s.state.boxes { if b.a11y != nil && b.a11y.role == .Menu_Item { item = b; _ = k; break } }
	if testing.expect(t, item != nil, "a menu's row") { testing.expect_value(t, item.radius, 0) }
}
