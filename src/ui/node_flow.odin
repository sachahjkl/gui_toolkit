package ui

// A flowgraph.Graph shown by node_graph: its nodes, ports and links as the widget takes them, made when the program says
// the graph changed (not at each frame: the widget reads them every frame); the add palette of a catalog; the links of
// the widget's events as the model's. Details: docs/flowgraph.md, "In a window".

import "core:strings"
import "../draw"
import flowgraph "../flowgraph"
import i18n "../i18n"
import "../render"

// What a node shows beyond its kind (Flow_Options.look): a summary of its parameters, its accent, what the last run did.
Flow_Node_Look :: struct {
	subtitle:       string,   // copied
	color:          draw.Color,
	state:          Graph_Node_State,
	message:        string,   // copied
	thumbnail:      render.Texture,
	thumbnail_size: [2]int,
}

Flow_Options :: struct {
	user: rawptr,
	look: proc(user: rawptr, n: ^flowgraph.Node, def: ^flowgraph.Node_Def) -> Flow_Node_Look,   // nil: the title alone
}

// The widget's nodes, ports and links of a graph, owned: the program keeps one, makes it again after each change
// (flow_nodes_make) and gives `nodes[:]` and `links[:]` to node_graph.
Flow_Nodes :: struct {
	nodes: [dynamic]Graph_Node,
	ports: [dynamic]Graph_Port,   // the nodes' `inputs` and `outputs` are slices of it
	links: [dynamic]Graph_Link,
	texts: [dynamic]string,       // the subtitles and messages (owned: the nodes outlive a frame)
}

// `out` made again from `g`: a port's id is its place in its kind's list, its kind the flowgraph's (kind_colors[kind]). The
// catalog's titles and port names (the program's English, i18n.later) in the language in use.
flow_nodes_make :: proc(out: ^Flow_Nodes, g: ^flowgraph.Graph, cat: ^flowgraph.Catalog, opts: Flow_Options = {}) {
	clear(&out.nodes)
	clear(&out.ports)
	clear(&out.links)
	for s in out.texts { delete(s) }
	clear(&out.texts)
	// (the ports first, all of them: the nodes' slices point into this array, which must not grow after)
	count := 0
	for &n in g.nodes {
		if def := flowgraph.node_def(cat, &n); def != nil { count += len(def.inputs) + len(def.outputs) }
	}
	reserve(&out.ports, count)
	for &n in g.nodes {
		def := flowgraph.node_def(cat, &n)
		if def == nil { continue }
		first := len(out.ports)
		for p, i in def.inputs { append(&out.ports, Graph_Port{id = u32(i), name = i18n.tr(p.name), kind = p.kind, side = .In, multiple = p.multiple}) }
		middle := len(out.ports)
		for p, i in def.outputs { append(&out.ports, Graph_Port{id = u32(i), name = i18n.tr(p.name), kind = p.kind, side = .Out}) }
		look: Flow_Node_Look
		if opts.look != nil { look = opts.look(opts.user, &n, def) }
		subtitle := flow_text(out, look.subtitle)
		message := flow_text(out, look.message)
		append(&out.nodes, Graph_Node{
			id = n.id, title = i18n.tr(def.title), subtitle = subtitle, icon = def.icon, color = look.color, pos = n.pos,
			inputs = out.ports[first:middle], outputs = out.ports[middle:len(out.ports)],
			state = look.state, message = message, thumbnail = look.thumbnail, thumbnail_size = look.thumbnail_size,
		})
	}
	for l in g.links { append(&out.links, Graph_Link{l.from_node, l.from_port, l.to_node, l.to_port}) }
}

flow_nodes_destroy :: proc(out: ^Flow_Nodes) {
	for s in out.texts { delete(s) }
	delete(out.texts)
	delete(out.nodes)
	delete(out.ports)
	delete(out.links)
	out^ = {}
}

@(private = "file")
flow_text :: proc(out: ^Flow_Nodes, s: string) -> string {
	if s == "" { return "" }
	c := strings.clone(s)
	append(&out.texts, c)
	return c
}

// A link of the widget's events as the model's (the same fields).
flow_link :: proc(l: Graph_Link) -> flowgraph.Link {
	return {l.from_node, l.from_port, l.to_node, l.to_port}
}

// What a node of a run shows: Waiting is Idle, Cancelled is Skipped (its branch stopped, nothing failed).
flow_state :: proc(s: flowgraph.Node_State) -> Graph_Node_State {
	switch s {
	case .Waiting:            return .Idle
	case .Running:            return .Running
	case .Done:               return .Done
	case .Failed:             return .Failed
	case .Skipped, .Cancelled: return .Skipped
	}
	return .Idle
}

// The add palette's commands, one per kind of the catalog in its order (the index chosen is the kind), and which are
// disabled (ui.palette's `disabled`): a kind at its max_count, and with `from` (a link let go on nothing) one with no
// port that fits it (flowgraph.fit_port). Temp allocator.
flow_palette :: proc(g: ^flowgraph.Graph, cat: ^flowgraph.Catalog, from: Maybe(flowgraph.Port_Ref) = nil) -> (commands: []Command, disabled: []bool) {
	commands = make([]Command, len(cat.nodes), context.temp_allocator)
	disabled = make([]bool, len(cat.nodes), context.temp_allocator)
	for def, k in cat.nodes {
		commands[k] = {label = def.title, group = def.group, tags = def.tags, icon = def.icon}
		fits := flowgraph.can_add(g, cat, k)
		if f, has := from.?; has { fits &&= flowgraph.fit_port(g, cat, f, k) >= 0 }
		disabled[k] = !fits
	}
	return
}
