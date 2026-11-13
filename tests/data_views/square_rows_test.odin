package data_views_test

// A row of a list, of a table or of a menu is square, and so is a table's tinted cell, whatever radius the style around it has: a selected row's fill runs
// from edge to edge, row under row.

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
Rows :: struct { list: ui.List_State, menu_open: bool, table: ui.Table }

@(test)
a_row_is_square :: proc(t: ^testing.T) {
	r: Rows
	ui.table_init(&r.table, {{title = "Name", width = 10}})
	defer ui.table_destroy(&r.table)
	s := session.start(t, {size = {400, 300}, user = &r, build = proc(s: ^session.Session) {
		r := (^Rows)(s.user)
		if ui.style({radius = 10}) {
			ui.next({width = ui.px(300), height = ui.px(200)})
			if ui.list("###l", &r.list) {
				for i in 0 ..< 3 { ui.list_row(&r.list, i, "row") }
			}
			key := "m"
			if !r.menu_open { r.menu_open = true; ui.menu_open(key, ui.Vec2{50, 50}) }
			if ui.menu(key) { ui.menu_item("An item") }
			ui.next({width = ui.px(300), height = ui.px(24), axis = .X})
			if ui.row(id = "###trow") { ui.table_cell(&r.table.layout, 0, "busy", bg = ui.Color{0.8, 0.2, 0.2, 1}) }
		}
	}})
	session.frames(s, 3)
	row := session.find(s, "lrow_0")
	if testing.expect(t, row != nil, "a list's row") { testing.expect_value(t, row.radius, 0) }
	item: ^ui.Box
	for k, b in s.state.boxes { if b.a11y != nil && b.a11y.role == .Menu_Item { item = b; _ = k; break } }
	if testing.expect(t, item != nil, "a menu's row") {
		testing.expect_value(t, item.radius, 0)
		// (flush: from one edge of the menu to the other)
		panel := item.parent
		for panel != nil && !(.Plate in panel.flags) { panel = panel.parent }
		if testing.expect(t, panel != nil, "its menu") {
			testing.expectf(t, item.rect.min.x <= panel.rect.min.x + 1 && item.rect.max.x >= panel.rect.max.x - 1, "edge to edge: %v in %v", item.rect, panel.rect)
		}
	}
	cell := session.find(s, "c0")
	if testing.expect(t, cell != nil, "a table's tinted cell") { testing.expect_value(t, cell.radius, 0) }
}
