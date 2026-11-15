package data_views_test

// A row of a list, of a table or of a menu runs from edge to edge, and its face (hover, selection) is inset in it with a
// button's corners, whatever radius the style around it has (src/md/features/interaction-states.md, "Rows"). A table's
// tinted cell stays square: a row's corner is not drawn, a cell at it takes no curve from it.

import "core:math"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
Rows :: struct { list: ui.List_State, menu_open: bool, table: ui.Table }

// A button's corners, of the font size (widgets.odin's CONTROL_RADIUS_EM): a row's face takes the same.
@(private = "file") CONTROL_RADIUS_EM :: 0.45

@(test)
a_row_has_a_buttons_corners :: proc(t: ^testing.T) {
	r: Rows
	ui.table_init(&r.table, {{title = "Name", width = 10}})
	defer ui.table_destroy(&r.table)
	s := session.start(t, {size = {400, 300}, user = &r, build = proc(s: ^session.Session) {
		r := (^Rows)(s.user)
		if ui.style({radius = 10}) {
			ui.next({width = ui.px(300), height = ui.px(200)})
			if ui.list("###l", &r.list) {
				for i in 0 ..< 3 {
					ui.next({height = ui.px(28)})
					if ui.parent(ui.list_row(&r.list, i, "row").box) {
						ui.next({width = ui.px(60), height = ui.pct(1), axis = .X, radius = 0})
						if ui.row(id = "###trow") { ui.table_cell(&r.table.layout, 0, "busy", bg = ui.Color{0.8, 0.2, 0.2, 1}) }
					}
				}
			}
			key := "m"
			if !r.menu_open { r.menu_open = true; ui.menu_open(key, ui.Vec2{50, 50}) }
			if ui.menu(key) { ui.menu_item("An item") }
		}
	}})
	session.frames(s, 3)
	ui.use(s.state)
	row := session.find(s, "lrow_0")
	if testing.expect(t, row != nil, "a list's row") {
		testing.expect(t, .Row in row.flags, "a row draws a row's face")
		testing.expect(t, math.abs(row.radius - row.font_size * CONTROL_RADIUS_EM) < 1e-3, "a button's corners, not the style's")
		// the box runs across the list: its content stays where it was, its face is inset in it
		list := row.parent
		testing.expect(t, row.rect.min.x <= list.rect.min.x + 0.5, "the row starts at the list's edge")
		face, _, _, _, _ := ui.row_face_of(s.state, row)
		testing.expect(t, face.min.x > row.rect.min.x && face.max.x < row.rect.max.x, "its face is inset")
	}
	item: ^ui.Box
	for k, b in s.state.boxes { if b.a11y != nil && b.a11y.role == .Menu_Item { item = b; _ = k; break } }
	if testing.expect(t, item != nil, "a menu's row") {
		testing.expect(t, .Row in item.flags, "a menu's item is a row")
		testing.expect(t, math.abs(item.radius - item.font_size * CONTROL_RADIUS_EM) < 1e-3, "a button's corners")
		// (its box flush: from one edge of the menu to the other; its face inset)
		panel := item.parent
		for panel != nil && !(.Plate in panel.flags) { panel = panel.parent }
		if testing.expect(t, panel != nil, "its menu") {
			testing.expectf(t, item.rect.min.x <= panel.rect.min.x + 1 && item.rect.max.x >= panel.rect.max.x - 1, "edge to edge: %v in %v", item.rect, panel.rect)
		}
	}
	// (the second row's: the first one's is also at the list's corner, which a box laid there takes, by design)
	cell: ^ui.Box
	if second := session.find(s, "lrow_1"); second != nil {
		for _, b in s.state.boxes {
			if b.name == "c0" && b.last_build == s.state.build_index && b.rect.min.y >= second.rect.min.y - 0.5 && b.rect.max.y <= second.rect.max.y + 0.5 { cell = b }
		}
	}
	if testing.expect(t, cell != nil, "a table's tinted cell") {
		testing.expect_value(t, cell.radius, 0)
		// (at the row's corner: the row's radius is its face's, not a curve the cell takes)
		testing.expect_value(t, ui.box_drawn_radii(s.state, cell), [4]f32{})
	}
}
