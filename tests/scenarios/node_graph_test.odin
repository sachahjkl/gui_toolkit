package scenarios_test

// A node graph in a session: the events its gestures and keys return, applied to a model as a program would.

import "core:math"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

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
	last_delta: [2]f32,
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
	events := ui.node_graph("###graph", &r.view, r.nodes[:], r.links[:], r.selected[:], {})
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
port_of :: proc(r: ^Run, i: int, side: ui.Graph_Port_Side, index: int) -> [2]f32 {
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
