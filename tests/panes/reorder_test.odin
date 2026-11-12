// A list reordered by dragging (ui/reorder.odin): sizes, scroll following the current item, slots, moves, the edge
// scroll, the threshold, and a drag through a real build (items slide, the dragged one follows the pointer).
package panes_test

import "core:fmt"
import "core:testing"
import "../../src/font"
import "../../src/platform"
import "../../src/ui"

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

	// items of different sizes: a narrow item (40) between two wide ones (100), 2 apart from 10: it takes the next one's
	// place once its right edge is half into it (pos 164: not yet, 165: there), not once its middle passes the other's
	sized := [3]f32{100, 40, 100}
	testing.expect_value(t, ui.reorder_slot_sized(164, 10, 2, sized[:], 1), 1)
	testing.expect_value(t, ui.reorder_slot_sized(165, 10, 2, sized[:], 1), 2)
	testing.expect_value(t, ui.reorder_slot_sized(60, 10, 2, sized[:], 1), 1)
	testing.expect_value(t, ui.reorder_slot_sized(59, 10, 2, sized[:], 1), 0)
	// once moved, it does not come back on the pixel it moved at: the band 162 .. 164 moves nothing either way
	moved := [3]f32{100, 100, 40}
	testing.expect_value(t, ui.reorder_slot_sized(163, 10, 2, moved[:], 2), 2)
	testing.expect_value(t, ui.reorder_slot_sized(161, 10, 2, moved[:], 2), 1)
	// the hysteresis widens the band; a fast pointer moves the item several places at once; out of range stays in it
	testing.expect_value(t, ui.reorder_slot_sized(166, 10, 2, sized[:], 1, hysteresis = 4), 1)
	testing.expect_value(t, ui.reorder_slot_sized(169, 10, 2, sized[:], 1, hysteresis = 4), 2)
	testing.expect_value(t, ui.reorder_slot_sized(-500, 10, 2, moved[:], 2), 0)
	testing.expect_value(t, ui.reorder_slot_sized(900, 10, 2, sized[:], 0), 2)
	testing.expect_value(t, ui.reorder_slot_sized(0, 0, 0, nil, 0), 0)
	testing.expect_value(t, ui.reorder_slot_sized(0, 0, 0, sized[:], 7), 2)

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
	items: [4]u64,
	pos:   [4]f32,
	keys:  [4]ui.Key,   // the items' boxes, by place
	hide:  u64,         // an item not built (0: none)
	other: [4]u64,      // a second list under the first, whose items have the same ids (none: zeros)
	other_pos: [4]f32,
}

@(private = "file") PITCH :: 50

// One list in a box `id` at `y`: its items `pitch` apart, the one dragged following the pointer, the others sliding.
@(private = "file")
build_list :: proc(id: string, y: f32, items: []u64, pos: []f32, keys: []ui.Key, hide: u64) {
	n := len(items)
	ui.next({fixed_x = 0, fixed_y = y, width = ui.px(400), height = ui.px(40)})
	area := ui.build_box({}, id)
	from, to := -1, -1
	if ui.parent(area) {
		for item, i in items {
			if item == hide { continue }
			name := fmt.tprintf("###it%d", item)
			key := ui.key_from_string(area.key, name)   // (the box's key, before it is built)
			slot := f32(i) * PITCH
			x, dragging := ui.reorder_item_pos(key, slot, ui.mouse_pos().x - area.rect.min.x, 0, f32(n - 1) * PITCH)
			pos[i] = x
			ui.next({fixed_x = x, fixed_y = 0, width = ui.px(PITCH), height = ui.pct(1)})
			b := ui.build_box({.Clickable}, name)
			keys[i] = b.key
			sig := ui.signal(b)
			if sig.dragging {
				ui.reorder_begin(b.key, ui.reorder_moved(sig.drag_delta, .X, false), 4, ui.mouse_pos().x - sig.drag_delta.x - area.rect.min.x, slot)
				if dragging || ui.reorder_dragging(b.key) {
					if s := ui.reorder_slot(x, PITCH, n); s != i { from, to = i, s }
				}
			}
		}
	}
	if from >= 0 { _ = ui.list_move(items, from, to, 0) }
}

@(private = "file")
build :: proc(r: ^Rx, events: []platform.Event = nil) {
	ui.begin_build(&r.s, {window_size = {400, 100}, events = events, dt = 1.0 / 60, animations = true, dpi_scale = 1, base = ui.Style{font = r.f, font_size = 15}})
	build_list("###area", 0, r.items[:], r.pos[:], r.keys[:], r.hide)
	if r.other[0] != 0 {
		keys: [4]ui.Key
		build_list("###other", 50, r.other[:], r.other_pos[:], keys[:], 0)
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
start :: proc(r: ^Rx) {
	font.init(&r.fonts)
	r.f, _ = font.load_embedded(&r.fonts, font.FALLBACK_UI_DATA)
	ui.apply_palette(&r.theme, ui.palette_of("Midnight"))
	ui.init(&r.s, &r.fonts, &r.theme)
	r.items = {10, 11, 12, 13}
	build(r)
	build(r)
}

@(private = "file")
stop :: proc(r: ^Rx) {
	ui.destroy(&r.s)
	ui.theme_destroy(&r.theme)
	font.destroy(&r.fonts)
}

// Item 11 (x 50 .. 100) pressed at x 60 and moved past the threshold: dragged, 10 px into it.
@(private = "file")
hold :: proc(r: ^Rx, button := platform.Mouse_Button.Left) {
	build(r, {{kind = .Mouse_Move, pos = {60, 20}}, {kind = .Mouse_Press, pos = {60, 20}, button = button}})
	build(r, {{kind = .Mouse_Move, pos = {70, 20}}})
	build(r, {{kind = .Mouse_Move, pos = {80, 20}}})
}

@(test)
reorder_drag_through_a_build :: proc(t: ^testing.T) {
	r := new(Rx)
	defer free(r)
	start(r)
	defer stop(r)
	testing.expect_value(t, r.pos, [4]f32{0, 50, 100, 150})
	it11 := r.keys[1]
	// press item 11 at x 60 (10 into it), move 2 px: under the threshold
	build(r, {{kind = .Mouse_Move, pos = {60, 20}}, {kind = .Mouse_Press, pos = {60, 20}, button = .Left}})
	build(r, {{kind = .Mouse_Move, pos = {62, 20}}})
	testing.expect(t, !ui.reorder_dragging(it11), "under the threshold")
	// past it, then on to the slot of item 13: the dragged item follows the pointer, the others make room
	build(r, {{kind = .Mouse_Move, pos = {70, 20}}})
	testing.expect(t, ui.reorder_dragging(it11))
	build(r, {{kind = .Mouse_Move, pos = {80, 20}}})
	testing.expect_value(t, r.pos[1], 70)   // (held 10 px into it)
	build(r, {{kind = .Mouse_Move, pos = {175, 20}}})
	testing.expect_value(t, r.items, [4]u64{10, 12, 13, 11})
	build(r, {{kind = .Mouse_Move, pos = {500, 20}}})
	testing.expect_value(t, r.pos[3], 150)   // held past the end: at the last slot
	build(r, {{kind = .Mouse_Release, pos = {500, 20}, button = .Left}})
	build(r)
	testing.expect(t, !ui.reorder_dragging(it11), "the button went up")
	// the moved items slide to their slots and stop
	for _ in 0 ..< 200 { build(r); if !ui.needs_frame(&r.s) { break } }
	testing.expect_value(t, r.pos, [4]f32{0, 50, 100, 150})
	testing.expect(t, !ui.needs_frame(&r.s), "at rest")

	// a release and a new press read in one frame: that drag is over, the new press starts under the threshold
	build(r, {{kind = .Mouse_Move, pos = {60, 20}}, {kind = .Mouse_Press, pos = {60, 20}, button = .Left}})
	build(r, {{kind = .Mouse_Move, pos = {80, 20}}})
	held := ui.active_key()
	testing.expect(t, ui.reorder_dragging(held), "dragging")
	build(r, {{kind = .Mouse_Release, pos = {80, 20}, button = .Left}, {kind = .Mouse_Press, pos = {80, 20}, button = .Left}})
	build(r)
	testing.expect(t, !ui.reorder_dragging(held), "not the same drag")
	build(r, {{kind = .Mouse_Release, pos = {80, 20}, button = .Left}})
}

// The drag ends with its press however it ends: the user leaving the window, the item's box going.
@(test)
reorder_ends_with_its_press :: proc(t: ^testing.T) {
	r := new(Rx)
	defer free(r)
	start(r)
	defer stop(r)
	it11 := r.keys[1]
	hold(r)
	testing.expect(t, ui.reorder_dragging(it11), "dragging")
	build(r, {{kind = .Frame_Press}})   // (a press on the window's frame: the user is elsewhere)
	testing.expect(t, !ui.reorder_dragging(it11), "the user left the window")
	build(r, {{kind = .Mouse_Release, pos = {80, 20}, button = .Left}})
	for _ in 0 ..< 200 { build(r); if !ui.needs_frame(&r.s) { break } }
	testing.expect_value(t, r.pos, [4]f32{0, 50, 100, 150})   // (back to its slot)

	hold(r)
	testing.expect(t, ui.reorder_dragging(it11), "dragging again")
	r.hide = 11   // (taken out of the list)
	build(r)
	r.hide = 0
	build(r)
	testing.expect(t, !ui.reorder_dragging(it11), "its box went: the drag with it")
	build(r, {{kind = .Mouse_Release, pos = {80, 20}, button = .Left}})
}

// Another button drags nothing, and a press of it in the middle of a drag leaves the drag alone.
@(test)
reorder_is_the_left_button_s :: proc(t: ^testing.T) {
	r := new(Rx)
	defer free(r)
	start(r)
	defer stop(r)
	it11 := r.keys[1]
	hold(r, .Right)
	testing.expect(t, !ui.reorder_dragging(it11), "the right button")
	testing.expect_value(t, r.pos[1], 50)
	build(r, {{kind = .Mouse_Release, pos = {80, 20}, button = .Right}})
	hold(r)
	build(r, {{kind = .Mouse_Press, pos = {80, 20}, button = .Right}})
	build(r, {{kind = .Mouse_Release, pos = {80, 20}, button = .Right}})
	testing.expect(t, ui.reorder_dragging(it11), "a right click in the middle of the drag")
	build(r, {{kind = .Mouse_Release, pos = {80, 20}, button = .Left}})
	testing.expect(t, !ui.reorder_dragging(it11), "the left button went up")
}

// Two lists whose items have the same ids: the item dragged is the one held, not its namesake in the other list.
@(test)
reorder_lists_with_the_same_ids :: proc(t: ^testing.T) {
	r := new(Rx)
	defer free(r)
	start(r)
	defer stop(r)
	r.other = r.items
	build(r)
	hold(r)
	testing.expect(t, ui.reorder_dragging(r.keys[1]), "dragging")
	testing.expect_value(t, r.pos[1], 70)
	testing.expect_value(t, r.other_pos, [4]f32{0, 50, 100, 150})   // (its namesake stays)
	build(r, {{kind = .Mouse_Move, pos = {175, 20}}})
	testing.expect_value(t, r.items, [4]u64{10, 12, 13, 11})
	testing.expect_value(t, r.other, [4]u64{10, 11, 12, 13})
	build(r, {{kind = .Mouse_Release, pos = {175, 20}, button = .Left}})
}
