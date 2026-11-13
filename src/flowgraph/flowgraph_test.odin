package tk_flowgraph

import "core:testing"

// Each edit keeps the graph valid: no loop, the kinds of a link agree (a text takes a file's path, not a picture), an
// input that takes one link loses the old one, a delete takes the node's links and leaves a kind's min_count.
@(test)
an_edit_keeps_the_graph_valid :: proc(t: ^testing.T) {
	g: Graph
	defer graph_destroy(&g)
	cat := &SAMPLE
	capture := node_add(&g, cat, int(Sample.Capture), {})
	a := node_add(&g, cat, int(Sample.Blur), {})
	b := node_add(&g, cat, int(Sample.Resize), {})
	save := node_add(&g, cat, int(Sample.Save), {})
	copy_text := node_add(&g, cat, int(Sample.Copy_Text), {})
	_, ok := link(&g, cat, {capture, 0, a, 0})
	testing.expect(t, ok)
	_, ok = link(&g, cat, {a, 0, b, 0})
	testing.expect(t, ok)
	_, ok = link(&g, cat, {b, 0, a, 0})
	testing.expect(t, !ok)                                       // (a loop)
	testing.expect(t, !can_link(&g, cat, {a, 0, a, 0}))          // (a node to itself)
	testing.expect(t, reaches(&g, capture, b))
	testing.expect(t, !reaches(&g, b, capture))
	_, ok = link(&g, cat, {save, 0, copy_text, 0})
	testing.expect(t, ok)                                        // (a file's path is a text)
	_, ok = link(&g, cat, {capture, 0, copy_text, 0})
	testing.expect(t, !ok)                                       // (a picture is not)
	_, ok = link(&g, cat, {capture, 0, save, 9})
	testing.expect(t, !ok)                                       // (no such port)
	replaced, linked := link(&g, cat, {capture, 0, b, 0})
	testing.expect(t, linked)
	testing.expect_value(t, replaced.?, Link{a, 0, b, 0})        // (an input takes one link)
	_, ok = link(&g, cat, {capture, 0, b, 0})
	testing.expect(t, !ok)                                       // (there already)
	testing.expect(t, unlink(&g, {capture, 0, b, 0}))
	testing.expect(t, !unlink(&g, {capture, 0, b, 0}))

	deleted := [2]u64{capture, a}
	testing.expect_value(t, nodes_delete(&g, cat, deleted[:]), 1)   // (the Capture's min_count keeps it)
	testing.expect(t, graph_node(&g, capture) != nil)
	for l in g.links { testing.expect(t, l.from_node != a && l.to_node != a) }
	moved := [1]u64{b}
	nodes_move(&g, moved[:], {10, -5})
	testing.expect_value(t, graph_node(&g, b).pos, [2]f32{10, -5})
}

// "At most one Capture" is the catalog's data, not code: node_add and node_copy refuse a second; a kind with no limit
// takes as many as one adds.
@(test)
max_count_limits_a_kind :: proc(t: ^testing.T) {
	g: Graph
	defer graph_destroy(&g)
	cat := &SAMPLE
	capture := node_add(&g, cat, int(Sample.Capture), {})
	testing.expect(t, capture != 0)
	testing.expect_value(t, node_add(&g, cat, int(Sample.Capture), {}), 0)
	testing.expect_value(t, node_copy(&g, cat, capture, {30, 30}), 0)
	testing.expect_value(t, node_add(&g, cat, len(cat.nodes), {}), 0)   // (not a kind of the catalog)
	blur := node_add(&g, cat, int(Sample.Blur), {5, 5})
	p := param(cat, graph_node(&g, blur), "radius")
	p.number = 12
	twin := node_copy(&g, cat, blur, {30, 30})
	testing.expect(t, twin != 0 && twin != blur)
	testing.expect_value(t, graph_node(&g, twin).pos, [2]f32{35, 35})
	testing.expect_value(t, param_float(cat, graph_node(&g, twin), "radius"), 12)
	testing.expect_value(t, graph_count(&g, int(Sample.Blur)), 2)
}

// An action output links only to an action input, and an action input takes nothing else.
@(test)
actions_link_to_actions :: proc(t: ^testing.T) {
	g: Graph
	defer graph_destroy(&g)
	cat := &SAMPLE
	capture := node_add(&g, cat, int(Sample.Capture), {})
	editor := node_add(&g, cat, int(Sample.Editor), {})
	save := node_add(&g, cat, int(Sample.Save), {})
	notify := node_add(&g, cat, int(Sample.Notify), {})
	testing.expect(t, can_link(&g, cat, {editor, 1, save, 1}))     // (done -> when)
	testing.expect(t, !can_link(&g, cat, {capture, 0, save, 1}))   // (a picture is no action)
	testing.expect(t, !can_link(&g, cat, {editor, 1, save, 0}))    // (an action is no picture)
	testing.expect(t, !can_link(&g, cat, {editor, 2, notify, 0}))  // (not even into "anything")
	testing.expect(t, can_link(&g, cat, {editor, 0, notify, 0}))
}

// The accessors read a parameter clamped to its range or its choices, as a hand-edited file may hold anything.
@(test)
parameters_read_clamped :: proc(t: ^testing.T) {
	g: Graph
	defer graph_destroy(&g)
	cat := &SAMPLE
	n := graph_node(&g, node_add(&g, cat, int(Sample.Save), {}))
	testing.expect_value(t, param_int(cat, n, "quality"), 90)
	quality, format := param(cat, n, "quality"), param(cat, n, "format")
	quality.number = 9000
	testing.expect_value(t, param_int(cat, n, "quality"), 100)
	format.number = 1
	testing.expect_value(t, param_choice_text(cat, n, "format"), "JPEG")
	format.number = -4
	testing.expect_value(t, param_choice_text(cat, n, "format"), "PNG")
	testing.expect_value(t, param_color(cat, n, "tint"), [4]u8{0, 0, 0, 255})
	testing.expect(t, !param_bool(cat, n, "open"))
	testing.expect(t, param(cat, n, "nothing") == nil)
	testing.expect_value(t, param_text(cat, n, "name"), "")
}

// A link let go on nothing, then a kind chosen: the new node joins it by its first port that fits; a kind with none fits
// not (the palette greys it out).
@(test)
a_node_added_from_a_link_joins_it :: proc(t: ^testing.T) {
	g: Graph
	defer graph_destroy(&g)
	cat := &SAMPLE
	capture := node_add(&g, cat, int(Sample.Capture), {})
	save := node_add(&g, cat, int(Sample.Save), {})
	testing.expect_value(t, fit_port(&g, cat, {capture, 0, .Out}, int(Sample.Blur)), 0)
	testing.expect_value(t, fit_port(&g, cat, {capture, 0, .Out}, int(Sample.Copy_Text)), -1)   // (a picture is no text)
	testing.expect_value(t, fit_port(&g, cat, {save, 0, .Out}, int(Sample.Copy_Text)), 0)       // (a file's path is)
	testing.expect_value(t, fit_port(&g, cat, {save, 1, .In}, int(Sample.Editor)), 1)         // (its "when" takes the editor's "done")
	blur := node_add_linked(&g, cat, int(Sample.Blur), {200, 0}, {capture, 0, .Out})
	testing.expect(t, blur != 0)
	testing.expect_value(t, len(g.links), 1)
	testing.expect_value(t, g.links[0], Link{capture, 0, blur, 0})
	editor := node_add_linked(&g, cat, int(Sample.Editor), {0, 200}, {save, 1, .In})
	testing.expect_value(t, g.links[1], Link{editor, 1, save, 1})
	testing.expect(t, !can_add(&g, cat, int(Sample.Capture)))
	testing.expect_value(t, node_add_linked(&g, cat, int(Sample.Capture), {}, {blur, 0, .In}), 0)
}

// param_set copies the text it is given; the node frees its own.
@(test)
param_set_copies_the_text :: proc(t: ^testing.T) {
	g: Graph
	defer graph_destroy(&g)
	cat := &SAMPLE
	n := graph_node(&g, node_add(&g, cat, int(Sample.Save), {}))
	_, i := param_def(cat, n, "name")
	given := clone_text("shot.png")
	param_set(n, i, {text = given})
	delete(given)
	testing.expect_value(t, param_text(cat, n, "name"), "shot.png")
	param_set(n, i, {})
	testing.expect_value(t, param_text(cat, n, "name"), "")
}
