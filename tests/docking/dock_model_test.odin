// Docking, the model (ui/dock_model.odin): splitting, joining, floating and docking back, closing, moving along a strip,
// folds, the layout and the drop targets under a point, the text and its round trip, texts that are not one.
//   odin test tests/docking -vet -define:ODIN_TEST_THREADS=1
package docking_test

import "core:strings"
import "core:testing"
import "../../ui"

// Panels of the tests: their ids and names.
@(private) A :: u32(1)
@(private) B :: u32(2)
@(private) C :: u32(3)
@(private) D :: u32(4)
@(private) E :: u32(5)
@(private) NAMES := [?]string{"", "a", "b", "c", "d", "e"}

@(private)
name_of :: proc(user: rawptr, id: u32) -> string { return int(id) < len(NAMES) ? NAMES[id] : "" }

@(private)
id_of :: proc(user: rawptr, name: string) -> (u32, bool) {
	for n, i in NAMES { if i > 0 && n == name { return u32(i), true } }
	return 0, false
}

// What the layout measures with in these tests (frame px; 1 px a logical px).
@(private) METRICS :: ui.Dock_Metrics{strip = 30, handle = 5, folded = 19, min = 45, marker = 30, gap = 5, em = 15, scale = 1}
@(private) SPACE :: ui.Vec2{800, 600}

@(private)
text_of :: proc(d: ^ui.Dock) -> string { return ui.dock_format(d, name_of, nil) }

// a and b in the main stack
@(private)
two :: proc(d: ^ui.Dock) {
	ui.dock_init(d)
	ui.dock_add(d, A, ui.dock_with(d, A))
	ui.dock_add(d, B, ui.dock_with(d, A))
}

@(test)
panels_join_a_stack_and_split_it :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	testing.expect_value(t, text_of(&d), "dock1 [a,*b]")
	testing.expect(t, ui.dock_shown(&d, B) && !ui.dock_shown(&d, A))
	testing.expect(t, ui.dock_activate(&d, A))
	testing.expect_value(t, text_of(&d), "dock1 [*a,b]")

	// b at the right of the stack: a split, half each
	leaf := ui.dock_leaf_of(&d, A)
	testing.expect(t, ui.dock_move(&d, B, {place = .Right, node = leaf}))
	testing.expect_value(t, text_of(&d), "dock1 x0.500([*a] [*b])")
	testing.expect(t, ui.dock_shown(&d, A) && ui.dock_shown(&d, B))
	// beside itself alone: refused
	testing.expect(t, !ui.dock_move(&d, B, {place = .Left, node = ui.dock_leaf_of(&d, B)}))
	// c below b, then b back into a's stack: b's leaf goes, c takes its split's place
	ui.dock_add(&d, C, ui.dock_beside(&d, B, .Bottom))
	testing.expect_value(t, text_of(&d), "dock1 x0.500([*a] y0.500([*b] [*c]))")
	testing.expect(t, ui.dock_move(&d, B, {place = .Tab, node = ui.dock_leaf_of(&d, A), index = -1}))
	testing.expect_value(t, text_of(&d), "dock1 x0.500([a,*b] [*c])")
	// at the top edge of the space: the whole tree split, a quarter for it
	testing.expect(t, ui.dock_move(&d, A, {place = .Edge_Top}))
	testing.expect_value(t, text_of(&d), "dock1 y0.250([*a] x0.500([*b] [*c]))")
	testing.expect(t, ui.dock_move(&d, C, {place = .Edge_Right}))
	testing.expect_value(t, text_of(&d), "dock1 x0.750(y0.250([*a] [*b]) [*c])")
}

@(test)
moving_along_the_strip :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	ui.dock_add(&d, C, ui.dock_with(&d, A))
	leaf := ui.dock_leaf_of(&d, A)
	testing.expect_value(t, text_of(&d), "dock1 [a,b,*c]")
	testing.expect(t, ui.dock_move(&d, A, {place = .Tab, node = leaf, index = 3}))   // after the last
	testing.expect_value(t, text_of(&d), "dock1 [b,c,*a]")
	testing.expect(t, ui.dock_move(&d, C, {place = .Tab, node = leaf, index = 0}))
	testing.expect_value(t, text_of(&d), "dock1 [*c,b,a]")
	testing.expect(t, !ui.dock_move(&d, C, {place = .Tab, node = leaf, index = 1}), "where it is already")
	testing.expect(t, ui.dock_move(&d, B, {place = .Tab, node = leaf, index = -1}))
	testing.expect_value(t, text_of(&d), "dock1 [c,a,*b]")
}

@(test)
floating_and_docking_back :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	ui.dock_add(&d, C, ui.dock_beside(&d, A, .Right))
	ui.dock_layout(&d, SPACE, METRICS)
	testing.expect(t, ui.dock_float(&d, B, {{40, 30}, {360, 230}}))
	testing.expect_value(t, len(d.floats), 1)
	testing.expect_value(t, text_of(&d), "dock1 x0.500([*a] [*c]) @40,30,320,200 [*b]")
	testing.expect(t, ui.dock_is_floating(&d, ui.dock_leaf_of(&d, B)))
	ui.dock_layout(&d, SPACE, METRICS)
	r := d.nodes[d.floats[0]].rect
	testing.expect_value(t, r, ui.Rect{{40, 30}, {360, 230}})
	// docked into it: a stack of two that floats
	testing.expect(t, ui.dock_move(&d, C, {place = .Tab, node = ui.dock_leaf_of(&d, B), index = -1}))
	testing.expect_value(t, text_of(&d), "dock1 [*a] @40,30,320,200 [b,*c]")
	// back into the main tree (c's home is none: the largest stack): the floating root goes
	root := d.floats[0]
	testing.expect(t, ui.dock_redock(&d, root))
	testing.expect_value(t, len(d.floats), 0)
	testing.expect_value(t, text_of(&d), "dock1 [a,b,*c]")
	// a floating panel docked at a side of a stack: its whole tree goes there
	testing.expect(t, ui.dock_float(&d, A, {{10, 10}, {200, 200}}))
	testing.expect(t, ui.dock_move(&d, B, {place = .Bottom, node = ui.dock_leaf_of(&d, A)}))
	testing.expect_value(t, text_of(&d), "dock1 [*c] @10,10,190,190 y0.500([*a] [*b])")
	testing.expect(t, ui.dock_move_node(&d, d.floats[0], {place = .Left, node = ui.dock_leaf_of(&d, C)}))
	testing.expect_value(t, text_of(&d), "dock1 x0.500(y0.500([*a] [*b]) [*c])")
	testing.expect_value(t, len(d.floats), 0)
}

@(test)
a_floated_panel_goes_home :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	ui.dock_add(&d, C, ui.dock_beside(&d, A, .Right))   // [a,b] | [c]
	ui.dock_add(&d, D, ui.dock_with(&d, C))             // [a,b] | [c,d]
	ui.dock_layout(&d, SPACE, METRICS)
	testing.expect(t, ui.dock_float(&d, B, {{0, 0}, {300, 200}}))   // its home: a
	testing.expect(t, ui.dock_redock(&d, d.floats[0]))
	testing.expect_value(t, text_of(&d), "dock1 x0.500([a,*b] [c,*d])")
	// alone in its stack, it goes home with its sibling's panel
	testing.expect(t, ui.dock_move(&d, B, ui.dock_beside(&d, A, .Bottom)))
	testing.expect(t, ui.dock_float(&d, B, {{0, 0}, {300, 200}}))
	testing.expect(t, ui.dock_redock(&d, d.floats[0]))
	testing.expect_value(t, text_of(&d), "dock1 x0.500([a,*b] [c,*d])")
}

@(test)
closing_empties_stacks :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	ui.dock_add(&d, C, ui.dock_beside(&d, A, .Left))
	testing.expect(t, ui.dock_close(&d, C))
	testing.expect_value(t, text_of(&d), "dock1 [a,*b]")
	testing.expect(t, ui.dock_close(&d, B))
	testing.expect_value(t, text_of(&d), "dock1 [*a]")
	testing.expect(t, ui.dock_close(&d, A))
	testing.expect_value(t, text_of(&d), "dock1 []")
	testing.expect(t, !ui.dock_close(&d, A))
	// into the empty space at any edge: the main stack takes it
	testing.expect(t, ui.dock_add(&d, D, {place = .Edge_Left}))
	testing.expect_value(t, text_of(&d), "dock1 [*d]")
	testing.expect(t, !ui.dock_add(&d, D, {place = .Edge_Left}), "already in")
}

@(test)
folds_hide_and_showing_unfolds :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	ui.dock_move(&d, B, ui.dock_beside(&d, A, .Bottom))
	split := d.nodes[ui.dock_leaf_of(&d, A)].parent
	ui.dock_set_split(&d, split, 0.7, true)
	testing.expect_value(t, text_of(&d), "dock1 y0.700f([*a] [*b])")
	testing.expect(t, !ui.dock_shown(&d, B))
	ui.dock_layout(&d, SPACE, METRICS)
	testing.expect_value(t, d.nodes[ui.dock_leaf_of(&d, A)].rect, ui.Rect{{0, 0}, {800, 600 - 19}})
	testing.expect_value(t, ui.dock_handle_rect(&d, split), ui.Rect{{0, 581}, {800, 600}})
	testing.expect_value(t, ui.dock_panel_size(&d, B), ui.Vec2{})
	ui.dock_activate(&d, B)
	testing.expect(t, ui.dock_shown(&d, B))
	ui.dock_layout(&d, SPACE, METRICS)
	// open: 70 % of the room less the handle, the strip at the top of each stack
	testing.expect_value(t, d.nodes[ui.dock_leaf_of(&d, A)].rect, ui.Rect{{0, 0}, {800, 417}})
	testing.expect_value(t, d.nodes[ui.dock_leaf_of(&d, B)].rect, ui.Rect{{0, 422}, {800, 600}})
	testing.expect_value(t, ui.dock_panel_size(&d, B), ui.Vec2{800, 178 - 30})
	// a ratio past the limits is held in them; the layout keeps the minimum on each side
	ui.dock_set_split(&d, split, 0.999, false)
	ui.dock_layout(&d, SPACE, METRICS)
	testing.expect_value(t, d.nodes[ui.dock_leaf_of(&d, B)].rect.min.y, 600 - 45)
}

@(test)
drop_targets_under_the_pointer :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	ui.dock_add(&d, C, ui.dock_beside(&d, A, .Right))
	ui.dock_layout(&d, SPACE, METRICS)
	right := ui.dock_leaf_of(&d, C)
	mk := ui.dock_markers(d.nodes[right].rect, METRICS)
	mid :: proc(r: ui.Rect) -> ui.Vec2 { return (r.min + r.max) * 0.5 }
	places := [ui.Dock_Marker]ui.Dock_Place{.Center = .Tab, .Left = .Left, .Right = .Right, .Top = .Top, .Bottom = .Bottom}
	for r, k in mk {
		tg, under := ui.dock_target_at(&d, mid(r), B, ui.DOCK_NONE, {})
		testing.expect_value(t, under, right)
		testing.expect_value(t, tg.place, places[k])
		testing.expect_value(t, tg.node, right)
	}
	// the strip of a stack: a tab
	tg, _ := ui.dock_target_at(&d, {600, 10}, B, ui.DOCK_NONE, {})
	testing.expect_value(t, tg.place, ui.Dock_Place.Tab)
	// the edges of the space
	for r, k in ui.dock_edge_markers(SPACE, METRICS) {
		if k == .Center { continue }
		e, _ := ui.dock_target_at(&d, mid(r), B, ui.DOCK_NONE, {})
		testing.expect(t, e.place >= .Edge_Left && e.place <= .Edge_Bottom)
	}
	// anywhere else: floating there, the pointer where it held the tab
	f, _ := ui.dock_target_at(&d, {100, 300}, B, ui.DOCK_NONE, {10, 5})
	testing.expect_value(t, f.place, ui.Dock_Place.Float)
	testing.expect_value(t, f.rect.min, ui.Vec2{90, 295})
	// c alone in its stack: not beside itself, but into another
	own := ui.dock_markers(d.nodes[right].rect, METRICS)
	s, _ := ui.dock_target_at(&d, mid(own[.Left]), C, ui.DOCK_NONE, {})
	testing.expect_value(t, s.place, ui.Dock_Place.Float)
	// the preview of a side: half of the stack
	testing.expect_value(t, ui.dock_preview_rect(&d, {place = .Bottom, node = right}), ui.Rect{{d.nodes[right].rect.min.x, 300}, {800, 600}})
	testing.expect_value(t, ui.dock_preview_rect(&d, {place = .Edge_Left}), ui.Rect{{0, 0}, {200, 600}})
}

@(test)
the_text_round_trips :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	ui.dock_add(&d, C, ui.dock_beside(&d, A, .Right))
	ui.dock_add(&d, D, ui.dock_beside(&d, C, .Bottom))
	ui.dock_float(&d, E, {{12, 34}, {312, 234}})
	ui.dock_set_split(&d, d.nodes[ui.dock_leaf_of(&d, D)].parent, 0.3, true)
	text := strings.clone(text_of(&d))
	defer delete(text)
	testing.expect_value(t, text, "dock1 x0.500([a,*b] y0.300f([*c] [*d])) @12,34,300,200 [*e]")
	back: ui.Dock
	defer ui.dock_destroy(&back)
	testing.expect(t, ui.dock_parse(&back, text, id_of, nil))
	testing.expect_value(t, text_of(&back), text)
	testing.expect(t, ui.dock_shown(&back, B) && !ui.dock_shown(&back, D) && ui.dock_shown(&back, E))
}

@(test)
unknown_names_go_and_new_panels_are_the_app_s :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	// "gone" is a panel removed since; the stack it was alone in goes with it
	testing.expect(t, ui.dock_parse(&d, "dock1 x0.600([a,*gone] y0.500([gone2] [c])) @1,2,30,40 [gone3]", id_of, nil))
	testing.expect_value(t, text_of(&d), "dock1 x0.600([*a] [*c])")
	testing.expect_value(t, len(d.floats), 0)
	// a panel the text does not name: where the app says
	testing.expect(t, ui.dock_add(&d, B, ui.dock_beside(&d, C, .Top)))
	testing.expect_value(t, text_of(&d), "dock1 x0.600([*a] y0.500([*b] [*c]))")
	// a name twice: the first one
	testing.expect(t, ui.dock_parse(&d, "dock1 x0.500([a,b] [*a])", id_of, nil))
	testing.expect_value(t, text_of(&d), "dock1 [*a,b]")
}

@(test)
texts_that_are_no_layout_leave_it_alone :: proc(t: ^testing.T) {
	d: ui.Dock
	defer ui.dock_destroy(&d)
	two(&d)
	before := strings.clone(text_of(&d))
	defer delete(before)
	deep := strings.builder_make()
	defer strings.builder_destroy(&deep)
	strings.write_string(&deep, "dock1 ")
	for _ in 0 ..< ui.DOCK_DEPTH_MAX + 2 { strings.write_string(&deep, "x0.5([a] ") }
	strings.write_string(&deep, "[b]")
	for _ in 0 ..< ui.DOCK_DEPTH_MAX + 2 { strings.write_string(&deep, ")") }
	bad := []string{
		"", "dock1", "dock2 [a]", "dock1 [a", "dock1 [a,]", "dock1 [,a]", "dock1 x0.5([a])", "dock1 x0.5([a] [b]", "dock1 x1.5([a] [b])",
		"dock1 x-1([a] [b])", "dock1 xnan([a] [b])", "dock1 z0.5([a] [b])", "dock1 [a] @1,2,3 [b]", "dock1 [a] @1,2,0,5 [b]", "dock1 [a] [b]",
		"dock1 [a] @1,2,3,4", "dock1 [a]x", "dock1  x0.5([a]  [b])", strings.to_string(deep),
	}
	for s in bad {
		testing.expectf(t, !ui.dock_parse(&d, s, id_of, nil), "refused: %q", s)
		testing.expect_value(t, text_of(&d), before)
	}
}
