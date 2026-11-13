package scenarios_test

// A flowgraph node's parameters in ui.node_inspector, applied to the model as a program would (flowgraph.param_set
// after its undo step); a graph shown by ui.node_graph through ui.flow_nodes_make, its links checked by the catalog; the
// add palette of the catalog.

import "core:testing"
import flowgraph "../../src/flowgraph"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"
import undo "../../src/undo"

@(private = "file") PICTURE :: flowgraph.Port_Kind(1)
@(private = "file") TEXT :: flowgraph.Port_Kind(2)
@(private = "file") CAPTURE :: 0
@(private = "file") SAVE :: 1
@(private = "file") COPY_TEXT :: 2

@(private = "file")
CATALOG := flowgraph.Catalog{
	kinds = {{name = "action"}, {name = "picture", transient = true}, {name = "text"}},
	nodes = {
		{name = "capture", title = "Capture", group = "Source", outputs = {{name = "picture", kind = PICTURE}}, max_count = 1},
		{name = "save", title = "Save", group = "Outputs", inputs = {{name = "picture", kind = PICTURE}}, params = {
			{name = "quality", title = "Quality", type = .Int, lo = 1, hi = 100, step = 1, unit = "%", default_number = 90},
			{name = "open", title = "Open it after", type = .Bool},
			{name = "format", title = "Format", type = .Choice, choices = {"PNG", "JPEG", "WebP"}},
			{name = "name", title = "File name", type = .Text, placeholder = "The default name"},
			{name = "folder", title = "Folder", type = .Folder},
			{name = "host", title = "Host", type = .List, placeholder = "The default host"},
		}},
		{name = "copy_text", title = "Copy text", group = "Outputs", inputs = {{name = "text", kind = TEXT}}},
	},
}

@(private = "file")
Inspected :: struct {
	graph:   flowgraph.Graph,
	node:    u64,
	ins:     ui.Node_Inspector,
	history: undo.Stack(flowgraph.Graph),
	changes: int,
	steps:   int,
	picked:  int,
	typing:  bool,
	asked:   int,   // the List's names asked for
}

@(private = "file") HOSTS := []string{"imgur", "sxcu"}

@(private = "file")
hosts :: proc(user: rawptr, n: ^flowgraph.Node, param: flowgraph.Param_Def) -> []string {
	r := (^Inspected)(user)
	r.asked += 1
	return HOSTS
}

@(private = "file")
inspect_build :: proc(s: ^session.Session) {
	r := (^Inspected)(s.user)
	n := flowgraph.graph_node(&r.graph, r.node)
	ui.next({width = ui.px(360), height = ui.children_sum()})
	res := ui.node_inspector("###params", &r.ins, &CATALOG, n, {user = r, lists = hosts})
	r.typing = res.typing
	if res.pick_folder >= 0 { r.picked = res.pick_folder }
	if res.changed >= 0 {
		r.changes += 1
		if res.new_step {
			r.steps += 1
			undo.push(&r.history, flowgraph.graph_clone(r.graph), 100, flowgraph.graph_destroy)
		}
		flowgraph.param_set(n, res.changed, res.value)
	}
}

@(private = "file")
inspected_make :: proc() -> (r: Inspected) {
	r.node = flowgraph.node_add(&r.graph, &CATALOG, SAVE, {})
	r.picked = -1
	return
}

@(private = "file")
inspected_destroy :: proc(r: ^Inspected) {
	ui.node_inspector_destroy(&r.ins)
	undo.destroy(&r.history, flowgraph.graph_destroy)
	flowgraph.graph_destroy(&r.graph)
}

@(private = "file")
param_of :: proc(r: ^Inspected, name: string) -> flowgraph.Param {
	return flowgraph.param(&CATALOG, flowgraph.graph_node(&r.graph, r.node), name)^
}

// Each type of parameter has its control; a change of one parameter in a row is one undo step, and undo gives the model
// back as it was, which the inspector shows once told (ins.node = 0).
@(test)
the_inspector_edits_a_node_by_its_schema :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := inspected_make()
	defer inspected_destroy(&r)
	s := session.start(t, {size = {520, 720}, user = &r, build = inspect_build})
	testing.expect(t, r.asked > 0, "the List's names are asked for")

	session.click(s, "inc")
	session.click(s, "inc")
	testing.expect_value(t, param_of(&r, "quality").number, 92)
	testing.expect_value(t, r.steps, 1)   // (the same parameter twice: one step)

	session.click(s, "toggle")
	testing.expect_value(t, param_of(&r, "open").number, 1)
	testing.expect_value(t, r.steps, 2)

	session.click_text(s, "JPEG")
	testing.expect_value(t, param_of(&r, "format").number, 1)

	session.click(s, "text")
	session.type_text(s, "shot")
	session.frame(s)
	testing.expect(t, r.typing, "the text field has the keyboard")
	testing.expect_value(t, param_of(&r, "name").text, "shot")
	testing.expect_value(t, r.steps, 4)

	session.click(s, "choose")
	testing.expect_value(t, r.picked, 4)   // (the Folder's place: the program opens the dialog)

	// back two steps: the text, then the choice
	for _ in 0 ..< 2 {
		back, ok := undo.undo(&r.history, r.graph)
		testing.expect(t, ok)
		r.graph = back
	}
	r.ins.node = 0
	session.frame(s)
	testing.expect_value(t, param_of(&r, "name").text, "")
	testing.expect_value(t, param_of(&r, "format").number, 0)
	testing.expect_value(t, param_of(&r, "open").number, 1)
	testing.expect_value(t, ui.line_edit_string(&r.ins.texts[3]), "")   // (the field shows the model again)
	again, _ := undo.redo(&r.history, r.graph)
	r.graph = again
	testing.expect_value(t, param_of(&r, "format").number, 1)
}) }

@(private = "file")
Shown :: struct {
	graph:   flowgraph.Graph,
	flow:    ui.Flow_Nodes,
	view:    ui.Graph_View,
	made:    bool,
	refused: int,
}

@(private = "file")
shown_build :: proc(s: ^session.Session) {
	r := (^Shown)(s.user)
	if !r.made {
		ui.flow_nodes_make(&r.flow, &r.graph, &CATALOG)
		r.made = true
	}
	opts := ui.Graph_Options{
		user = r,
		can_link = proc(user: rawptr, l: ui.Graph_Link) -> bool {
			r := (^Shown)(user)
			return flowgraph.can_link(&r.graph, &CATALOG, ui.flow_link(l))
		},
	}
	events := ui.node_graph("###graph", &r.view, r.flow.nodes[:], r.flow.links[:], nil, opts)
	for e in events {
		#partial switch v in e {
		case ui.Graph_Linked:
			if _, ok := flowgraph.link(&r.graph, &CATALOG, ui.flow_link(v.link)); ok { r.made = false } else { r.refused += 1 }
		}
	}
}

@(private = "file")
port_at :: proc(r: ^Shown, node: int, side: flowgraph.Side, index: int) -> [2]f32 {
	return ui.graph_to_screen(&r.view, ui.graph_port_pos(&r.view, &r.flow.nodes[node], side, index))
}

// The widget's nodes are the graph's, with their kinds' ports; a link the catalog takes is made in the model, one it
// refuses (a picture into a text) is not offered.
@(test)
a_flowgraph_is_shown_and_linked :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Shown
	defer { ui.flow_nodes_destroy(&r.flow); flowgraph.graph_destroy(&r.graph) }
	capture := flowgraph.node_add(&r.graph, &CATALOG, CAPTURE, {60, 80})
	save := flowgraph.node_add(&r.graph, &CATALOG, SAVE, {460, 40})
	copy_text := flowgraph.node_add(&r.graph, &CATALOG, COPY_TEXT, {460, 300})
	s := session.start(t, {size = {900, 520}, user = &r, build = shown_build})
	testing.expect_value(t, len(r.flow.nodes), 3)
	testing.expect_value(t, r.flow.nodes[1].title, "Save")
	testing.expect_value(t, len(r.flow.nodes[1].inputs), 1)
	testing.expect_value(t, r.flow.nodes[0].outputs[0].kind, PICTURE)

	session.drag(s, port_at(&r, 0, .Out, 0), port_at(&r, 2, .In, 0))
	testing.expect_value(t, len(r.graph.links), 0)
	session.drag(s, port_at(&r, 0, .Out, 0), port_at(&r, 1, .In, 0))
	session.frame(s)
	testing.expect_value(t, len(r.graph.links), 1)
	if len(r.graph.links) == 1 { testing.expect_value(t, r.graph.links[0], flowgraph.Link{capture, 0, save, 0}) }
	testing.expect_value(t, len(r.flow.links), 1)
	testing.expect_value(t, r.refused, 0)
	_ = copy_text
}) }

// The add palette has a command per kind: one at its max_count is off, and from a link let go, the kinds with no port
// that fits it are off.
@(test)
the_palette_follows_the_catalog :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	g: flowgraph.Graph
	defer flowgraph.graph_destroy(&g)
	capture := flowgraph.node_add(&g, &CATALOG, CAPTURE, {})
	commands, disabled := ui.flow_palette(&g, &CATALOG)
	testing.expect_value(t, len(commands), 3)
	testing.expect_value(t, commands[SAVE].label, "Save")
	testing.expect_value(t, commands[SAVE].group, "Outputs")
	testing.expect(t, disabled[CAPTURE], "one Capture at most")
	testing.expect(t, !disabled[SAVE] && !disabled[COPY_TEXT])
	_, disabled = ui.flow_palette(&g, &CATALOG, flowgraph.Port_Ref{node = capture, port = 0, side = .Out})
	testing.expect(t, !disabled[SAVE], "Save takes a picture")
	testing.expect(t, disabled[COPY_TEXT], "Copy text does not")
	testing.expect_value(t, ui.flow_state(.Cancelled), ui.Graph_Node_State.Skipped)
	testing.expect_value(t, ui.flow_state(.Waiting), ui.Graph_Node_State.Idle)
}) }
