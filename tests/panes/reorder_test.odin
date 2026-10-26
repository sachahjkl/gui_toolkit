// A list reordered by dragging (ui/reorder.odin): sizes, scroll following the current item, slots, moves, the edge
// scroll, the threshold, and a drag through a real build (items slide, the dragged one follows the pointer).
package panes_test

import "core:fmt"
import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

@(test)
reorder_geometry :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.reorder_item_size(1000, 2, 60, 240), 240)
	testing.expect_value(t, ui.reorder_item_size(1000, 10, 60, 240), 100)
	testing.expect_value(t, ui.reorder_item_size(1000, 30, 60, 240), 60)
	testing.expect_value(t, ui.reorder_item_size(1000, 0, 60, 240), 240)
	testing.expect_value(t, ui.reorder_item_size(100, 3, 300, 240), 240)

	testing.expect_value(t, ui.reorder_offset(0, 30, 60, 600, 29, true), 1200)
	testing.expect_value(t, ui.reorder_offset(1200, 30, 60, 600, 0, true), 0)
	testing.expect_value(t, ui.reorder_offset(300, 30, 60, 600, 7, true), 300)
	testing.expect_value(t, ui.reorder_offset(5000, 30, 60, 600, 0, false), 1200)
	testing.expect_value(t, ui.reorder_offset(0, 30, 60, 600, 12, true), 180)

	testing.expect_value(t, ui.reorder_slot(49, 100, 5), 0)
	testing.expect_value(t, ui.reorder_slot(50, 100, 5), 1)
	testing.expect_value(t, ui.reorder_slot(-80, 100, 5), 0)
	testing.expect_value(t, ui.reorder_slot(900, 100, 5), 4)
	testing.expect_value(t, ui.reorder_slot(10, 0, 5), 0)

	l := [5]int{0, 1, 2, 3, 4}
	cur := ui.list_move(l[:], 1, 3, 1)
	testing.expect_value(t, l, [5]int{0, 2, 3, 1, 4})
	testing.expect_value(t, cur, 3)
	cur = ui.list_move(l[:], 4, 0, 1)
	testing.expect_value(t, l, [5]int{4, 0, 2, 3, 1})
	testing.expect_value(t, cur, 2)
	testing.expect_value(t, ui.list_move(l[:], 7, 0, 2), 2)

	// held past the top / bottom of a 400 px view at 100 of a 1000 px range; inside: the target stays
	testing.expect_value(t, ui.reorder_edge_scroll(60, 40, 100, 400, 600, 100), 60)
	testing.expect_value(t, ui.reorder_edge_scroll(480, 40, 100, 400, 600, 100), 120)
	testing.expect_value(t, ui.reorder_edge_scroll(200, 40, 100, 400, 600, 100), 100)
	testing.expect_value(t, ui.reorder_edge_scroll(-30, 40, 0, 400, 600, 0), 0)

	testing.expect_value(t, ui.reorder_moved({3, 9}, .X, false), 3)
	testing.expect_value(t, ui.reorder_moved({3, 9}, .X, true), 9)
	testing.expect_value(t, ui.reorder_moved({3, 9}, .Y, false), 9)
}

@(private = "file")
Rx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	f:     font.Font_Id,
	drag:  ui.Reorder,
	items: [4]u64,
	pos:   [4]f32,
}

@(private = "file")
build :: proc(r: ^Rx, events: []platform.Event = nil) {
	PITCH :: 50
	ui.begin_build(&r.s, {window_size = {400, 100}, events = events, dt = 1.0 / 60, animations = true, dpi_scale = 1, base = ui.Style{font = r.f, font_size = 15}})
	ui.reorder_frame(&r.drag)
	n := len(r.items)
	ui.next({width = ui.fill(), height = ui.px(40)})
	area := ui.build_box({}, "###area")
	from, to := -1, -1
	if ui.parent(area) {
		for id, i in r.items {
			key := ui.key_from_string(area.key, fmt.tprintf("x%d", id))
			slot := f32(i) * PITCH
			x, dragging := ui.reorder_item_pos(&r.drag, key, id, slot, ui.mouse_pos().x - area.rect.min.x, 0, f32(n - 1) * PITCH)
			r.pos[i] = x
			ui.next({fixed_x = x, fixed_y = 0, width = ui.px(PITCH), height = ui.pct(1)})
			b := ui.build_box({.Clickable}, fmt.tprintf("###it%d", id))
			sig := ui.signal(b)
			if sig.dragging {
				ui.reorder_begin(&r.drag, id, ui.reorder_moved(sig.drag_delta, .X, false), 4, ui.mouse_pos().x - sig.drag_delta.x - area.rect.min.x, slot)
				if dragging || ui.reorder_dragging(&r.drag, id) {
					if s := ui.reorder_slot(x, PITCH, n); s != i { from, to = i, s }
				}
			}
		}
	}
	if from >= 0 { _ = ui.list_move(r.items[:], from, to, 0) }
	ui.end_build()
	free_all(context.temp_allocator)
}

@(test)
reorder_drag_through_a_build :: proc(t: ^testing.T) {
	r := new(Rx)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	r.f, _ = font.load_embedded(&r.fonts, font.FALLBACK_UI_DATA)
	ui.apply_palette(&r.theme, ui.PALETTE_MIDNIGHT)
	defer ui.theme_destroy(&r.theme)
	ui.init(&r.s, &r.fonts, &r.theme)
	defer ui.destroy(&r.s)
	r.items = {10, 11, 12, 13}
	build(r)
	build(r)
	testing.expect_value(t, r.pos, [4]f32{0, 50, 100, 150})
	// press item 11 at x 60 (10 into it), move 2 px: under the threshold
	build(r, {{kind = .Mouse_Move, pos = {60, 20}}, {kind = .Mouse_Press, pos = {60, 20}, button = .Left}})
	build(r, {{kind = .Mouse_Move, pos = {62, 20}}})
	testing.expect(t, !r.drag.active, "under the threshold")
	// past it, then on to the slot of item 13: the dragged item follows the pointer, the others make room
	build(r, {{kind = .Mouse_Move, pos = {70, 20}}})
	testing.expect(t, r.drag.active && r.drag.id == 11)
	testing.expect_value(t, r.drag.grab, 10)
	build(r, {{kind = .Mouse_Move, pos = {175, 20}}})
	testing.expect_value(t, r.items, [4]u64{10, 12, 13, 11})
	build(r, {{kind = .Mouse_Move, pos = {500, 20}}})
	testing.expect_value(t, r.pos[3], 150)   // held past the end: at the last slot
	build(r, {{kind = .Mouse_Release, pos = {500, 20}, button = .Left}})
	build(r)
	testing.expect(t, !r.drag.active, "the button went up")
	// the moved items slide to their slots and stop
	for _ in 0 ..< 200 { build(r); if !ui.needs_frame(&r.s) { break } }
	testing.expect_value(t, r.pos, [4]f32{0, 50, 100, 150})
	testing.expect(t, !ui.needs_frame(&r.s), "at rest")
}
