package scenarios_test

// A node graph in a session: the events its gestures and keys return, applied to a model as a program would.

import "core:math"
import "core:testing"
import flowgraph "gt:flowgraph"
import "gt:platform"
import "gt:render"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{900, 520}
@(private = "file") PICTURE :: 0
@(private = "file") FILE :: 1

@(private = "file")
Run :: struct {
	view:     ui.Graph_View,
	nodes:    [dynamic]ui.Graph_Node,
	links:    [dynamic]ui.Graph_Link,
	selected: [dynamic]u64,
	moved:    int,   // Graph_Moved events
	linked:   int,
	dropped:  int,   // Graph_Dropped_Link
	deleted:  int,
	o:        ui.Graph_Options,
	last_delta: [2]f32,
	// the theme's colours a link is drawn in, read in the build
	accent, danger, success: ui.Color,
}

@(private = "file") picture_out := []ui.Graph_Port{{id = 1, name = "picture", kind = PICTURE, side = .Out}}
@(private = "file") inputs := []ui.Graph_Port{
	{id = 2, name = "picture", kind = PICTURE, side = .In},
	{id = 3, name = "file", kind = FILE, side = .In},
}

@(private = "file")
run_make :: proc() -> (r: Run) {
	append(&r.nodes, ui.Graph_Node{id = 1, title = "Capture", pos = {60, 80}, outputs = picture_out})
	append(&r.nodes, ui.Graph_Node{id = 2, title = "Save", pos = {460, 80}, inputs = inputs})
	return
}

@(private = "file")
run_destroy :: proc(r: ^Run) {
	delete(r.nodes)
	delete(r.links)
	delete(r.selected)
}

@(private = "file")
index_of :: proc(r: ^Run, id: u64) -> int {
	for n, i in r.nodes { if n.id == id { return i } }
	return -1
}

@(private = "file")
build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	r.accent, r.danger, r.success = ui.color("accent"), ui.hue_color(ui.intent_hue(.Danger)), ui.hue_color(ui.intent_hue(.Success))
	events := ui.node_graph("###graph", &r.view, r.nodes[:], r.links[:], r.selected[:], r.o)
	for e in events {
		switch v in e {
		case ui.Graph_Moved:
			r.moved += 1
			r.last_delta = v.delta
			for id in v.nodes { if i := index_of(r, id); i >= 0 { r.nodes[i].pos += v.delta } }
		case ui.Graph_Linked:
			r.linked += 1
			append(&r.links, v.link)
		case ui.Graph_Unlinked:
		case ui.Graph_Selected:
			clear(&r.selected)
			append(&r.selected, ..v.nodes)
		case ui.Graph_Deleted:
			r.deleted += 1
			for l in v.links { for x, i in r.links { if x == l { ordered_remove(&r.links, i); break } } }
			for id in v.nodes { if i := index_of(r, id); i >= 0 { ordered_remove(&r.nodes, i) } }
			clear(&r.selected)
		case ui.Graph_Context, ui.Graph_Opened:
		case ui.Graph_Dropped_Link:
			r.dropped += 1
		}
	}
}

// A node's header, on the screen.
@(private = "file")
header_of :: proc(r: ^Run, i: int) -> [2]f32 {
	rect := ui.graph_node_rect(&r.view, &r.nodes[i])
	return ui.graph_to_screen(&r.view, {(rect.min.x + rect.max.x) * 0.5, rect.min.y + 8})
}

@(private = "file")
port_of :: proc(r: ^Run, i: int, side: flowgraph.Side, index: int) -> [2]f32 {
	return ui.graph_to_screen(&r.view, ui.graph_port_pos(&r.view, &r.nodes[i], side, index))
}

@(private = "file")
near :: proc(a, b: [2]f32, eps: f32 = 0.5) -> bool { return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps }

@(test)
a_node_dragged_moves_by_the_drag :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	from := header_of(&r, 0)
	session.drag(s, from, from + {100, 50})
	testing.expect_value(t, r.moved, 1)
	testing.expect(t, near(r.last_delta, {100, 50}), "the delta is the drag's")
	testing.expect(t, near(r.nodes[0].pos, {160, 130}), "the node is where it was dropped")
	testing.expect_value(t, len(r.selected), 1)
	testing.expect_value(t, r.nodes[1].pos, [2]f32{460, 80})
}) }

// The frame of the release draws the node where it was let go: the program applies the move after that build, and a
// node drawn back at its old place for one frame jumps there and back.
@(test)
a_node_let_go_stays_where_it_was_let_go :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	from := header_of(&r, 0)
	to := from + {100, 50}
	session.press(s, from)
	for i in 1 ..= 4 {
		at := from + (to - from) * (f32(i) / 4)
		s.pointer = at
		session.event(s, {kind = .Mouse_Move, pos = at})
		session.frame(s)
	}
	box := session.get(s, "graph_node_1")
	during := box.rect.min
	// (one frame: the release's alone)
	s.buttons -= {.Left}
	session.event(s, {kind = .Mouse_Release, button = .Left, pos = to})
	session.frame(s)
	testing.expect_value(t, r.moved, 1)
	box = session.get(s, "graph_node_1")
	testing.expect(t, near(box.rect.min, during), "the frame of the release draws the node where it was let go")
}) }

@(test)
two_ports_of_a_kind_link :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.drag(s, port_of(&r, 0, .Out, 0), port_of(&r, 1, .In, 0))
	testing.expect_value(t, r.linked, 1)
	testing.expect_value(t, len(r.links), 1)
	if len(r.links) == 1 { testing.expect_value(t, r.links[0], ui.Graph_Link{1, 1, 2, 2}) }
}) }

@(test)
a_link_between_kinds_is_refused :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.drag(s, port_of(&r, 0, .Out, 0), port_of(&r, 1, .In, 1))
	testing.expect_value(t, r.linked, 0)
	testing.expect_value(t, len(r.links), 0)
	// (let go where no port takes it: the program may offer a node there)
	testing.expect_value(t, r.dropped, 1)
}) }

@(test)
a_band_selects_the_nodes_it_touches :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.drag(s, ui.graph_to_screen(&r.view, {10, 10}), ui.graph_to_screen(&r.view, {500, 120}))
	testing.expect_value(t, len(r.selected), 2)
	// a click on nothing clears it
	session.click_at(s, ui.graph_to_screen(&r.view, {20, 400}))
	testing.expect_value(t, len(r.selected), 0)
}) }

@(test)
delete_removes_the_selection_and_its_links :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	append(&r.links, ui.Graph_Link{1, 1, 2, 2})
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.click_at(s, header_of(&r, 0))
	testing.expect_value(t, len(r.selected), 1)
	session.key(s, .Delete)
	testing.expect_value(t, r.deleted, 1)
	testing.expect_value(t, len(r.nodes), 1)
	testing.expect_value(t, len(r.links), 0)
}) }

@(test)
the_zoom_keeps_the_point_under_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	at := [2]f32{300, 260}
	before := ui.graph_from_screen(&r.view, at)
	session.wheel(s, at, {0, -1}, {.Ctrl})
	testing.expect(t, abs(r.view.zoom - ui.GRAPH_ZOOM_STEP) < 1e-4, "a notch zooms by a step")
	after := ui.graph_from_screen(&r.view, at)
	testing.expect(t, near(before, after, 0.01), "the point under the pointer stays")
	testing.expect_value(t, ui.zoom(s.state), 1)   // (the interface's own zoom did not take it)
	// the wheel without Ctrl moves the view
	session.wheel(s, at, {0, 1})
	testing.expect(t, r.view.offset.y < 0, "the wheel moves the view")
}) }

@(test)
fit_shows_every_node :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	r.view.offset = {-3000, 2000}
	r.view.zoom = 3
	ui.graph_fit(&r.view, r.nodes[:])
	session.frames(s, 2)
	for &n in r.nodes {
		rect := ui.graph_node_rect(&r.view, &n)
		lo := ui.graph_to_screen(&r.view, rect.min)
		hi := ui.graph_to_screen(&r.view, rect.max)
		testing.expect(t, lo.x >= 0 && lo.y >= 0 && hi.x <= f32(WINDOW.x) && hi.y <= f32(WINDOW.y), "a node in view")
	}
	testing.expect(t, r.view.zoom <= 1 && !math.is_nan(r.view.zoom), "no closer than 1")
}) }

// Dragging the minimap near or past its edge freezes the minimap transform so the offset never runs away exponentially;
// drawing the grid at an extreme offset finishes immediately without hanging; panning all nodes off-screen shows a
// "Back to content" button that fits the graph back into view.
@(test)
minimap_drag_stays_bounded_and_back_to_content_fits :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	r.o.minimap = {show = true}
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.frames(s, 2)
	// press inside the minimap (bottom-right corner of the 800x600 area) and drag far past its right/bottom edge for 30 frames
	mm_pt := [2]f32{f32(WINDOW.x) - 40, f32(WINDOW.y) - 40}
	session.press(s, mm_pt)
	for _ in 0 ..< 30 { session.move(s, mm_pt + {400, 400}) }
	session.release(s, mm_pt + {400, 400})
	testing.expectf(t, abs(r.view.offset.x) < 1e5 && abs(r.view.offset.y) < 1e5, "minimap drag stayed bounded: %v", r.view.offset)
	// extreme offset must never hang the background grid draw
	r.view.offset = {-1e12, 1e12}
	session.frames(s, 2)
	// with all nodes off-screen, the "Back to content" button appears and brings every node back into view
	back := session.find(s, "graph_back")
	testing.expect(t, back != nil, "Back to content button shown when all nodes are off-screen")
	if back != nil {
		session.click(s, "graph_back")
		session.frames(s, 2)
		testing.expect(t, session.find(s, "graph_back") == nil, "button hides once nodes are back in view")
		testing.expectf(t, abs(r.view.offset.x) < 1e4 && abs(r.view.offset.y) < 1e4, "view returned to nodes: %v", r.view.offset)
	}
}) }

// What a program learns of the pointer: the node under it, its ports counted, none over the background.
@(test)
hover_node_is_the_node_under_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.move(s, header_of(&r, 0))
	testing.expect_value(t, r.view.hover_node, 1)
	session.move(s, port_of(&r, 1, .In, 1))
	testing.expect_value(t, r.view.hover_node, 2)
	session.move(s, ui.graph_to_screen(&r.view, {300, 400}))
	testing.expect_value(t, r.view.hover_node, 0)
}) }

// A tree from top to bottom: a parent's out port is the middle of its bottom edge, a child's in port the middle of its
// top edge; a drag between them links them, and the link leaves downward.
@(test)
a_vertical_link_runs_from_the_bottom_port_to_the_top_port :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer run_destroy(&r)
	child_in := []ui.Graph_Port{{id = 2, kind = PICTURE, side = .In}}
	append(&r.nodes, ui.Graph_Node{id = 1, title = "Parent", pos = {100, 40}, outputs = picture_out})
	append(&r.nodes, ui.Graph_Node{id = 2, title = "Child", pos = {400, 280}, inputs = child_in})
	r.o.direction = .Down
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	parent := ui.graph_node_rect(&r.view, &r.nodes[0])
	child := ui.graph_node_rect(&r.view, &r.nodes[1])
	out_at := ui.graph_port_pos(&r.view, &r.nodes[0], .Out, 0)
	in_at := ui.graph_port_pos(&r.view, &r.nodes[1], .In, 0)
	// (each dot outside its edge, touching it: across it, it covers the title or the message)
	dot := r.view.em * 0.62 * 0.5
	testing.expectf(t, near(out_at, {(parent.min.x + parent.max.x) * 0.5, parent.max.y + dot}, 0.01), "the out port is under the middle of the bottom edge: %v", out_at)
	testing.expectf(t, near(in_at, {(child.min.x + child.max.x) * 0.5, child.min.y - dot}, 0.01), "the in port is over the middle of the top edge: %v", in_at)
	session.drag(s, port_of(&r, 0, .Out, 0), port_of(&r, 1, .In, 0))
	testing.expect_value(t, r.linked, 1)
	session.move(s, ui.graph_to_screen(&r.view, {700, 500}))
	session.frame(s)
	// (just under the out port the link goes straight down: its colour there, the well's beside it)
	img := session.capture(s)
	a := ui.graph_to_screen(&r.view, out_at)
	below := best_near(img, {a.x, a.y + 14}, rgba8(r.accent))
	aside := best_near(img, {a.x + 14, a.y + 14}, rgba8(r.accent))
	testing.expectf(t, session.near(below, rgba8(r.accent), 40), "the link leaves downward: %v, want %v", below, rgba8(r.accent))
	testing.expectf(t, !session.near(aside, rgba8(r.accent), 40), "not to the right: %v", aside)
}) }

// Each link in its own look: a plain one in its port's colour, a dashed one in the danger hue, a dotted one in the
// success hue, read along their straight middles.
@(test)
each_link_is_drawn_in_its_own_look :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer run_destroy(&r)
	one_in := []ui.Graph_Port{{id = 2, kind = PICTURE, side = .In}}
	for row in 0 ..< 3 {
		y := 20 + 120 * f32(row)
		id := u64(row * 2 + 1)
		append(&r.nodes, ui.Graph_Node{id = id, title = "From", pos = {20, y}, outputs = picture_out})
		append(&r.nodes, ui.Graph_Node{id = id + 1, title = "To", pos = {380, y}, inputs = one_in})
		append(&r.links, ui.Graph_Link{id, 1, id + 1, 2})
	}
	looks := []ui.Graph_Link_Look{{}, {intent = .Danger, dash = .Dashed}, {intent = .Success, dash = .Dotted}}
	r.o.link_looks = looks
	r.view.zoom = 1.5
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.frame(s)
	img := session.capture(s)
	want := [3]ui.Color{r.accent, r.danger, r.success}
	share: [3]f32
	changes: [3]int
	for row in 0 ..< 3 {
		a := port_of(&r, row * 2, .Out, 0)
		b := port_of(&r, row * 2 + 1, .In, 0)
		c := rgba8(want[row])
		on_count, n := 0, 0
		was := false
		for x := a.x + 20; x < b.x - 20; x += 1 {
			on := session.near(best_near(img, {x, a.y}, c, 0), c, 40)
			if on { on_count += 1 }
			if n > 0 && on != was { changes[row] += 1 }
			was = on
			n += 1
		}
		share[row] = f32(on_count) / f32(max(n, 1))
	}
	testing.expectf(t, share[0] > 0.95, "the plain link is whole in its port's colour: %v", share[0])
	testing.expectf(t, share[1] > 0.3 && share[1] < 0.85 && changes[1] >= 8, "the dashed one in the danger hue: %v on, %d changes", share[1], changes[1])
	testing.expectf(t, share[2] > 0.05 && share[2] < 0.5 && changes[2] >= 12, "the dotted one in the success hue: %v on, %d changes", share[2], changes[2])
}) }

// A title wraps to two lines, never more: the header grows by one line; a longer title is cut, and the whole of it shows
// in a tooltip once the pointer rests on the header.
@(test)
a_long_title_wraps_to_two_lines_then_is_cut :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer run_destroy(&r)
	LONG :: "Read the image formats the loaders accept, and write down each one they refuse with its reason"
	append(&r.nodes, ui.Graph_Node{id = 1, title = "Build", pos = {20, 40}})
	append(&r.nodes, ui.Graph_Node{id = 2, title = "Find the tests of the PNG decoder", pos = {280, 40}})
	append(&r.nodes, ui.Graph_Node{id = 3, title = LONG, pos = {540, 40}})
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	height :: proc(r: ^Run, i: int) -> f32 { rect := ui.graph_node_rect(&r.view, &r.nodes[i]); return rect.max.y - rect.min.y }
	line := r.view.em * 1.25
	testing.expectf(t, abs(height(&r, 1) - height(&r, 0) - line) < 0.01, "two lines: one line taller (%v, %v)", height(&r, 0), height(&r, 1))
	testing.expectf(t, abs(height(&r, 2) - height(&r, 1)) < 0.01, "never more than two lines (%v)", height(&r, 2))
	// (a title that fits in two lines has no tooltip)
	session.move(s, header_of(&r, 1))
	session.advance(s, f64(ui.feel(s.state).tooltip_delay_ms) * 2)
	session.frames(s, 2)
	testing.expect(t, session.find(s, "tooltip") == nil, "no tooltip for a whole title")
	session.move(s, header_of(&r, 2))
	session.frames(s, 2)
	testing.expect(t, session.find(s, "tooltip") == nil, "the tooltip waits for the pointer to rest")
	session.advance(s, f64(ui.feel(s.state).tooltip_delay_ms) * 2)
	session.frames(s, 2)
	tip := session.find(s, "tooltip")
	testing.expect(t, tip != nil, "a cut title shows whole in a tooltip")
	testing.expect(t, session.find_text(s, LONG) != nil, "its whole text")
	if tip != nil {
		node := ui.graph_node_rect(&r.view, &r.nodes[2])
		lo, hi := ui.graph_to_screen(&r.view, node.min), ui.graph_to_screen(&r.view, node.max)
		testing.expectf(t, tip.rect.max.y <= lo.y || tip.rect.min.y >= hi.y || tip.rect.max.x <= lo.x || tip.rect.min.x >= hi.x,
			"it covers none of the node: %v, the node %v %v", tip.rect, lo, hi)
	}
}) }

// The minimap in the corner and at the size asked; by default a share of a narrow area, not 200 px wide; a fit puts no
// node under it.
@(test)
the_minimap_takes_its_corner_and_size_and_a_fit_avoids_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := run_make()
	defer run_destroy(&r)
	r.o.minimap = {show = true, corner = .Top_Left, size = {160, 100}}
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.move(s, {10 + 80, 10 + 50})
	testing.expect_value(t, session.cursor(s), platform.Cursor.Hand)
	session.move(s, {10 + 175, 10 + 50})
	testing.expect(t, session.cursor(s) != .Hand, "it is 160 wide")
	session.move(s, {f32(WINDOW.x) - 40, f32(WINDOW.y) - 40})
	testing.expect(t, session.cursor(s) != .Hand, "nothing in the bottom-right corner")

	// a narrow area: the default is a share of it (100 x 65 at 400 px)
	NARROW :: [2]int{400, 520}
	r.o.minimap = {show = true}
	session.resize(s, NARROW)
	session.frames(s, 2)
	session.move(s, {f32(NARROW.x) - 10 - 50, f32(NARROW.y) - 10 - 30})
	testing.expect_value(t, session.cursor(s), platform.Cursor.Hand)
	session.move(s, {f32(NARROW.x) - 10 - 120, f32(NARROW.y) - 10 - 30})
	testing.expect(t, session.cursor(s) != .Hand, "not the old 200 px")

	// three nodes spread wide: the fit leaves the minimap's corner free
	append(&r.nodes, ui.Graph_Node{id = 3, title = "Encode", pos = {900, 600}, inputs = inputs})
	ui.graph_fit(&r.view, r.nodes[:])
	session.frames(s, 2)
	mm := ui.Rect{{f32(NARROW.x) - 10 - 100, f32(NARROW.y) - 10 - 65}, {f32(NARROW.x) - 10, f32(NARROW.y) - 10}}
	for &n in r.nodes {
		rect := ui.graph_node_rect(&r.view, &n)
		lo := ui.graph_to_screen(&r.view, rect.min)
		hi := ui.graph_to_screen(&r.view, rect.max)
		testing.expect(t, lo.x >= 0 && lo.y >= 0 && hi.x <= f32(NARROW.x) && hi.y <= f32(NARROW.y), "a node in view")
		testing.expectf(t, hi.x <= mm.min.x || hi.y <= mm.min.y || lo.x >= mm.max.x || lo.y >= mm.max.y, "node %d is not under the minimap: %v %v", n.id, lo, hi)
	}
}) }

// A fit beside a minimap with one node, and with none; a map so wide that the room beside it is narrower than the fit's
// margins: the nodes go above it, never into that sliver.
@(test)
a_fit_beside_the_minimap_with_one_node_none_and_no_room_beside :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer run_destroy(&r)
	r.o.minimap = {show = true, corner = .Bottom_Right, size = {150, 100}}
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.frames(s, 2)
	ui.graph_fit(&r.view, r.nodes[:])
	testing.expect_value(t, r.view.zoom, 1)
	testing.expect_value(t, r.view.offset, [2]f32{})

	append(&r.nodes, ui.Graph_Node{id = 1, title = "Alone", pos = {300, 300}, outputs = picture_out})
	mm := ui.Rect{{f32(WINDOW.x) - 10 - 150, f32(WINDOW.y) - 10 - 100}, {f32(WINDOW.x) - 10, f32(WINDOW.y) - 10}}
	clear_of :: proc(t: ^testing.T, r: ^Run, mm: ui.Rect, window: [2]int) {
		for &n in r.nodes {
			rect := ui.graph_node_rect(&r.view, &n)
			lo, hi := ui.graph_to_screen(&r.view, rect.min), ui.graph_to_screen(&r.view, rect.max)
			testing.expectf(t, lo.x >= 0 && lo.y >= 0 && hi.x <= f32(window.x) && hi.y <= f32(window.y), "node %d in view: %v %v", n.id, lo, hi)
			testing.expectf(t, hi.x <= mm.min.x || hi.y <= mm.min.y || lo.x >= mm.max.x || lo.y >= mm.max.y, "node %d not under the map: %v %v", n.id, lo, hi)
		}
	}
	ui.graph_fit(&r.view, r.nodes[:])
	session.frames(s, 2)
	testing.expect_value(t, r.view.zoom, 1)
	clear_of(t, &r, mm, WINDOW)

	// (the column left of the map is 900 - 10 - 880 - 10 = 0 wide: no inside within the margins)
	r.o.minimap.size = {880, 100}
	append(&r.nodes, ui.Graph_Node{id = 2, title = "Far", pos = {2000, 900}, outputs = picture_out})
	session.frames(s, 2)
	ui.graph_fit(&r.view, r.nodes[:])
	session.frames(s, 2)
	testing.expectf(t, r.view.zoom < 1, "the band above zooms out: %v", r.view.zoom)
	clear_of(t, &r, {{10, f32(WINDOW.y) - 10 - 100}, {f32(WINDOW.x) - 10, f32(WINDOW.y) - 10}}, WINDOW)
}) }

// The tooltip of a cut title, left to right, leaves the node's message under it readable.
@(test)
a_cut_titles_tooltip_leaves_the_message_under_the_node :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer run_destroy(&r)
	LONG :: "Read the image formats the loaders accept, and write down each one they refuse with its reason"
	append(&r.nodes, ui.Graph_Node{id = 1, title = LONG, pos = {200, 40}, message = "Exit code 101", state = .Failed})
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.move(s, header_of(&r, 0))
	session.advance(s, f64(ui.feel(s.state).tooltip_delay_ms) * 2)
	session.frames(s, 2)
	tip := session.find(s, "tooltip")
	testing.expect(t, tip != nil, "a cut title shows whole in a tooltip")
	if tip != nil {
		node := ui.graph_node_rect(&r.view, &r.nodes[0])
		bottom := ui.graph_to_screen(&r.view, node.max).y
		em := r.view.em * r.view.scale * ui.graph_zoom(&r.view)
		// (the message is drawn, not a box: its line is the 1.3 em under the node)
		testing.expectf(t, tip.rect.min.y >= bottom + 1.3 * em, "below the message: the tooltip at %v, the node's bottom %v", tip.rect.min.y, bottom)
	}
}) }

@(private = "file") four_in := []ui.Graph_Port{
	{id = 1, name = "red", kind = PICTURE, side = .In}, {id = 2, name = "green", kind = PICTURE, side = .In},
	{id = 3, name = "blue", kind = PICTURE, side = .In}, {id = 4, name = "alpha", kind = PICTURE, side = .In},
}
@(private = "file") one_out := []ui.Graph_Port{{id = 5, name = "mixed", kind = PICTURE, side = .Out}}

// Widgets in each node: a label 8 em tall (four ports need 6.2 em: the edge is the body's).
@(private = "file")
tall_body :: proc(user: rawptr, node: u64, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 8)})
	ui.label(node == 1 ? "a###body_one" : "b###body_two")
}

// Left to right, the ports sit on the node's edges beside its widgets, spread over its height: the widgets start under the
// header as in a node without ports, and a port's name, with no room beside the widgets, is in a tooltip.
@(test)
ports_sit_on_the_edges_beside_the_body :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer run_destroy(&r)
	append(&r.nodes, ui.Graph_Node{id = 1, title = "Mix", pos = {40, 40}, inputs = four_in, outputs = one_out})
	append(&r.nodes, ui.Graph_Node{id = 2, title = "Mix", pos = {400, 40}})
	r.o.body = tall_body
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.frames(s, 2)
	with_ports, without := session.get(s, "body_one"), session.get(s, "body_two")
	testing.expectf(t, abs(with_ports.rect.min.y - without.rect.min.y) < 0.5, "the body right under the header: %v, without ports %v", with_ports.rect.min.y, without.rect.min.y)
	rect := ui.graph_node_rect(&r.view, &r.nodes[0])
	other := ui.graph_node_rect(&r.view, &r.nodes[1])
	testing.expectf(t, abs((rect.max.y - rect.min.y) - (other.max.y - other.min.y)) < 0.01, "the ports add no height: %v", rect)
	ys: [4]f32
	for i in 0 ..< 4 {
		at := ui.graph_port_pos(&r.view, &r.nodes[0], .In, i)
		testing.expectf(t, abs(at.x - rect.min.x) < 0.01 && at.y > rect.min.y && at.y < rect.max.y, "in port %d on the left edge: %v", i, at)
		ys[i] = at.y
	}
	testing.expectf(t, abs((ys[1] - ys[0]) - (ys[3] - ys[2])) < 0.01 && ys[1] > ys[0], "evenly spread: %v", ys)
	out := ui.graph_port_pos(&r.view, &r.nodes[0], .Out, 0)
	testing.expectf(t, abs(out.x - rect.max.x) < 0.01 && abs(out.y - (ys[1] + ys[2]) * 0.5) < 0.01, "the out port alone: the middle of the right edge: %v", out)
	// (the body is in the way of a name: its tooltip)
	session.move(s, port_of(&r, 0, .In, 2))
	session.advance(s, f64(ui.feel(s.state).tooltip_delay_ms) * 2)
	session.frames(s, 2)
	testing.expect(t, session.find(s, "tooltip") != nil && session.find_text(s, "blue") != nil, "a hidden name in a tooltip")
}) }

// With no widgets, the edges are a row per port and the names are drawn, as before; port_rows keeps each port on a row of
// its own before the widgets.
@(test)
port_rows_keep_a_row_per_port_before_the_body :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Run
	defer run_destroy(&r)
	append(&r.nodes, ui.Graph_Node{id = 1, title = "Mix", pos = {40, 40}, inputs = four_in, outputs = one_out})
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.frames(s, 2)
	edge_rect := ui.graph_node_rect(&r.view, &r.nodes[0])
	edge_in := ui.graph_port_pos(&r.view, &r.nodes[0], .In, 3)
	// (a name drawn on the node has no tooltip)
	session.move(s, port_of(&r, 0, .In, 3))
	session.advance(s, f64(ui.feel(s.state).tooltip_delay_ms) * 2)
	session.frames(s, 2)
	testing.expect(t, session.find(s, "tooltip") == nil, "the name is on the node")
	session.move(s, ui.graph_to_screen(&r.view, {700, 450}))
	r.o.port_rows = true
	session.frames(s, 2)
	testing.expect_value(t, ui.graph_node_rect(&r.view, &r.nodes[0]), edge_rect)
	testing.expect(t, near(ui.graph_port_pos(&r.view, &r.nodes[0], .In, 3), edge_in, 0.01), "four rows: the same places")
	out := ui.graph_port_pos(&r.view, &r.nodes[0], .Out, 0)
	testing.expectf(t, abs(out.y - ui.graph_port_pos(&r.view, &r.nodes[0], .In, 0).y) < 0.01, "the out port on the first row: %v", out)
	r.o.body = tall_body
	session.frames(s, 2)
	body := session.get(s, "body_one")
	last := ui.graph_to_screen(&r.view, ui.graph_port_pos(&r.view, &r.nodes[0], .In, 3))
	testing.expectf(t, body.rect.min.y > last.y, "the body under the rows: %v, the last row %v", body.rect.min.y, last.y)
}) }

// A colour of the theme (linear) as a frame holds it (sRGB bytes).
@(private = "file")
rgba8 :: proc(c: ui.Color) -> session.Color {
	b :: proc(v: f32) -> u8 { return u8(clamp(render.linear_to_srgb(v), 0, 1) * 255 + 0.5) }
	return {b(c.r), b(c.g), b(c.b), 255}
}

// The pixel nearest to `want` around `at`: `reach` pixels across, the rows above and below too (a thin stroke covers a
// pixel whole only somewhere near its middle).
@(private = "file")
best_near :: proc(img: session.Image, at: [2]f32, want: session.Color, reach := 2) -> session.Color {
	best: session.Color
	least := max(int)
	for dy in -2 ..= 2 {
		for dx in -reach ..= reach {
			p := session.pixel(img, int(at.x) + dx, int(at.y) + dy)
			d := 0
			for i in 0 ..< 3 { d = max(d, abs(int(p[i]) - int(want[i]))) }
			if d < least { least, best = d, p }
		}
	}
	return best
}
