package ui

// A flowgraph.Graph shown by node_graph: its nodes, ports and links as the widget takes them, made when the program says
// the graph changed (not at each frame: the widget reads them every frame); the add palette of a catalog; the links of
// the widget's events as the model's. Details: docs/flowgraph.md, "In a window".

import "base:runtime"
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
flow_nodes_make :: proc(out: ^Flow_Nodes, g: ^flowgraph.Graph, cat: ^flowgraph.Catalog, o: Flow_Options = {}) {
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
		if o.look != nil { look = o.look(o.user, &n, def) }
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

// The add palette's source (src/md/features/palette.md): a chooser's, no prefix. One item per kind of the catalog, in
// its order (a choice's `index` is the kind, its `id` the kind's name), the catalog's words in the language in use. A kind
// at its max_count is disabled, and with `from` (a link let go on nothing) one with no port that fits it
// (flowgraph.fit_port). The program keeps it beside its palette.
Flow_Palette :: struct {
	source:  Palette_Source,
	graph:   ^flowgraph.Graph,             // nil: no graph shown, no item
	catalog: ^flowgraph.Catalog,
	from:    Maybe(flowgraph.Port_Ref),
	version: u64,                          // the program's count of the graph's changes
	made:    bool,
}

// Gives the add palette's source what it lists: the graph a step is added to, its catalog, the port a link was let go
// from (nil: none), the graph's version (the program bumps it when nodes come or go). The first call adds the source to
// `p`. Call it at each build: it compares these only, and the source reads the kinds again when one changed.
flow_palette :: proc(p: ^Command_Palette, fp: ^Flow_Palette, g: ^flowgraph.Graph, cat: ^flowgraph.Catalog, from: Maybe(flowgraph.Port_Ref) = nil, version: u64 = 0) {
	if !palette_has(p, &fp.source) {
		fp.source = {name = "step", title = i18n.later("Steps"), enter = i18n.later("Add"), remember = true, read = flow_palette_read, user = fp}
		palette_add(p, &fp.source)
	}
	f, has_f := from.?
	k, has_k := fp.from.?
	if fp.made && fp.graph == g && fp.catalog == cat && fp.version == version && has_f == has_k && (!has_f || f == k) { return }
	fp.graph, fp.catalog, fp.from, fp.version, fp.made = g, cat, from, version, true
	fp.source.version += 1
}

// The add palette's items, one per kind of `cat` in its order, in `allocator` (an answer's): what flow_palette's source
// answers, and what a test reads.
flow_palette_items :: proc(g: ^flowgraph.Graph, cat: ^flowgraph.Catalog, from: Maybe(flowgraph.Port_Ref), allocator: runtime.Allocator) -> []Palette_Item {
	items := make([]Palette_Item, len(cat.nodes), allocator)
	for def, k in cat.nodes {
		fits := flowgraph.can_add(g, cat, k)
		if f, has := from.?; has { fits &&= flowgraph.fit_port(g, cat, f, k) >= 0 }
		// (the catalog's words are English: shown in the language in use)
		items[k] = palette_item_clone({id = def.name, title = i18n.tr(def.title), group = i18n.tr(def.group), tags = def.tags, icon = def.icon, disabled = !fits}, allocator)
	}
	return items
}

@(private = "file")
flow_palette_read :: proc(p: ^Command_Palette, src: ^Palette_Source, q: Palette_Question) {
	fp := (^Flow_Palette)(src.user)
	a: Palette_Answer
	if fp.graph != nil && fp.catalog != nil { a.items = flow_palette_items(fp.graph, fp.catalog, fp.from, palette_answer_allocator(&a)) }
	palette_answer(q, &a)
}
