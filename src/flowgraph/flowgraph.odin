// Package flowgraph: a graph of nodes a person edits (a workflow, a pipeline), its catalog of node kinds, its file, and a
// run of it. Pure: no window, no thread, no disk but the store's text; ui.node_graph draws a graph, ui.node_inspector
// edits a node's parameters (docs/flowgraph.md).
//
// A program describes its node kinds as data (a Catalog: each kind's ports, parameters, limits); the edits keep a graph
// valid against it (no cycle, the kinds of a link agree, at most `max_count` nodes of a kind), so a run never meets a
// graph it cannot read. What flows on a link has a kind (Port_Kind, the program's ids); the kind ACTION is the engine's:
// an action output fires when its node ends in a given way (done, failed, cancelled), and a node with an action input
// waits for it and runs only when it fires (run.odin).
package tk_flowgraph

import "core:strings"

// What flows on a link: the program's ids, from 1. The same id as ui.Graph_Port.kind (its colour).
Port_Kind :: u8

// The kind of an action port: no value, a signal that its node ended in a given way (Port_Def.on).
ACTION :: Port_Kind(0)

// How a node's work ended. An action output fires on one of them.
Outcome :: enum u8 { Done, Failed, Cancelled }

// A kind of what flows. Catalog.kinds[k] describes the kind k; kinds[ACTION] gives only its name.
Kind_Def :: struct {
	name:      string,        // the reader's word ("picture")
	accepts:   []Port_Kind,   // the other kinds an input of this kind takes (a text takes an address); itself always
	any:       bool,          // an input of this kind takes every kind but ACTION
	transient: bool,          // its values are let go as soon as no node waits for them (pictures); else at run_destroy
}

Port_Def :: struct {
	name:     string,
	kind:     Port_Kind,
	multiple: bool,      // an input that takes several links (it runs with at least one value)
	on:       Outcome,   // an ACTION output: the outcome that fires it
}

Param_Type :: enum u8 {
	Int,
	Float,
	Bool,     // number 0 or 1
	Color,    // color, straight RGBA
	Choice,   // number: the index in `choices`
	Text,
	Folder,   // a path; the inspector offers the system's dialog (the program opens it)
	List,     // a text chosen from a list the program gives at run time (ui.Node_Inspector_Options.lists); "": the default
	Hotkey,   // keys, as platform.hotkey_text words them ("Ctrl+Alt+E"); "": none. The inspector records them
}

Param_Def :: struct {
	name:           string,     // the file's key
	title:          string,
	type:           Param_Type,
	lo, hi, step:   f64,        // Int, Float: the range and the step
	unit:           string,     // "px", "%", "°"
	choices:        []string,   // Choice: the words of each value
	default_number: f64,
	default_text:   string,
	default_color:  [4]u8,
	placeholder:    string,     // Text, Folder, List: what an empty value means
}

Node_Def :: struct {
	name:      string,       // the file's word, unique in the catalog ("save_file")
	title:     string,
	group:     string,       // its group in the add palette ("Outputs")
	icon:      string,       // a glyph of the program's icon font
	tags:      []string,     // other words the add palette finds it by
	inputs:    []Port_Def,
	outputs:   []Port_Def,
	params:    []Param_Def,
	place:     u8,           // where the program does its work (its own ids: a worker, the interface, a person)
	effect:    bool,         // it acts outside the graph (a file, the network): Skipped in a dry run
	max_count: int,          // a graph holds at most this many (0: no limit)
	min_count: int,          // a delete leaves at least this many (a workflow's start)
}

// The node kinds of a program and the kinds of what flows. Node.kind is an index in `nodes`.
Catalog :: struct {
	kinds: []Kind_Def,
	nodes: []Node_Def,
}

// The parameters a node holds, by place in its kind's list (Node_Def.params).
PARAMS_MAX :: 8
// The ports of a side of a node, at most.
PORTS_MAX :: 8

Param :: struct {
	number: f64,      // Int, Float, Bool (0/1), Choice (the index)
	text:   string,   // Text, Folder, List (owned)
	color:  [4]u8,    // Color
}

Node :: struct {
	id:     u64,      // unique in its graph, never reused (Graph.next_id)
	kind:   int,      // an index in Catalog.nodes
	pos:    [2]f32,   // its top-left, graph units
	params: [PARAMS_MAX]Param,
}

// From an output port to an input port, each its place in its kind's list. The layout of ui.Graph_Link.
Link :: struct {
	from_node: u64,
	from_port: u32,
	to_node:   u64,
	to_port:   u32,
}

Graph :: struct {
	nodes:   [dynamic]Node,
	links:   [dynamic]Link,
	next_id: u64,
}

////////////////////////////////
// The catalog

// The kind of `n` (nil: not one of the catalog's).
node_def :: proc(cat: ^Catalog, n: ^Node) -> ^Node_Def {
	return n.kind >= 0 && n.kind < len(cat.nodes) ? &cat.nodes[n.kind] : nil
}

// The node kind called `name` (-1: none).
kind_named :: proc(cat: ^Catalog, name: string) -> int {
	for d, k in cat.nodes { if d.name == name { return k } }
	return -1
}

// Whether an input of kind `to` takes a value of kind `from`: its own kind, one it accepts, any kind for `any`. An action
// takes an action only.
port_accepts :: proc(cat: ^Catalog, from, to: Port_Kind) -> bool {
	if from == to { return true }
	if from == ACTION || to == ACTION || int(to) >= len(cat.kinds) { return false }
	k := cat.kinds[to]
	if k.any { return true }
	for a in k.accepts { if a == from { return true } }
	return false
}

////////////////////////////////
// Whole graphs

graph_destroy :: proc(g: ^Graph) {
	for &n in g.nodes { node_params_destroy(&n) }
	delete(g.nodes)
	delete(g.links)
	g^ = {}
}

graph_clone :: proc(g: Graph, allocator := context.allocator) -> Graph {
	out := g
	out.nodes = make([dynamic]Node, len(g.nodes), allocator)
	for n, i in g.nodes { out.nodes[i] = node_clone(n, allocator) }
	out.links = make([dynamic]Link, len(g.links), allocator)
	copy(out.links[:], g.links[:])
	return out
}

node_clone :: proc(n: Node, allocator := context.allocator) -> Node {
	out := n
	for &p in out.params { if p.text != "" { p.text = strings.clone(p.text, allocator) } }
	return out
}

node_params_destroy :: proc(n: ^Node) {
	for &p in n.params {
		delete(p.text)
		p.text = ""
	}
}

graph_node :: proc(g: ^Graph, id: u64) -> ^Node {
	for &n in g.nodes { if n.id == id { return &n } }
	return nil
}

graph_node_index :: proc(g: ^Graph, id: u64) -> int {
	for n, i in g.nodes { if n.id == id { return i } }
	return -1
}

// The nodes of kind `kind` in `g`.
graph_count :: proc(g: ^Graph, kind: int) -> (count: int) {
	for n in g.nodes { if n.kind == kind { count += 1 } }
	return
}

////////////////////////////////
// Edits

// A node of `kind` at `pos`, with its kind's default parameters. Returns its id; 0 when refused (not a kind of the
// catalog, or the graph holds its kind's max_count).
node_add :: proc(g: ^Graph, cat: ^Catalog, kind: int, pos: [2]f32) -> u64 {
	if !can_add(g, cat, kind) { return 0 }
	g.next_id += 1
	n := Node{id = g.next_id, kind = kind, pos = pos}
	node_params_default(cat, &n)
	append(&g.nodes, n)
	return n.id
}

// Whether a node of `kind` may be added: a kind of the catalog, under its max_count.
can_add :: proc(g: ^Graph, cat: ^Catalog, kind: int) -> bool {
	if kind < 0 || kind >= len(cat.nodes) { return false }
	m := cat.nodes[kind].max_count
	return m <= 0 || graph_count(g, kind) < m
}

// The side of a node a port is on: its inputs or its outputs.
Side :: enum u8 { In, Out }

// A port of a node: the index `port` among the node's inputs (In) or outputs (Out).
Port_Ref :: struct {
	node: u64,
	port: u32,
	side: Side,
}

// The first port of a new node of `kind` that a link can join to `at`: an input of the new node when `at` is an output,
// else one of its outputs. -1: none (the add palette greys the kind out).
fit_port :: proc(g: ^Graph, cat: ^Catalog, at: Port_Ref, kind: int) -> int {
	n := graph_node(g, at.node)
	if n == nil || kind < 0 || kind >= len(cat.nodes) { return -1 }
	have := node_def(cat, n)
	if have == nil { return -1 }
	other := &cat.nodes[kind]
	switch at.side {
	case .Out:
		if int(at.port) >= len(have.outputs) { return -1 }
		for p, i in other.inputs { if port_accepts(cat, have.outputs[at.port].kind, p.kind) { return i } }
	case .In:
		if int(at.port) >= len(have.inputs) { return -1 }
		for p, i in other.outputs { if port_accepts(cat, p.kind, have.inputs[at.port].kind) { return i } }
	}
	return -1
}

// A node of `kind` at `pos`, linked to `at` by its first port that fits (fit_port): what a link let go on nothing and a
// kind chosen in the add palette make. Returns its id; 0 when refused (as node_add). A kind with no port that fits is
// added unlinked.
node_add_linked :: proc(g: ^Graph, cat: ^Catalog, kind: int, pos: [2]f32, at: Port_Ref) -> u64 {
	fit := fit_port(g, cat, at, kind)
	id := node_add(g, cat, kind, pos)
	if id == 0 || fit < 0 { return id }
	switch at.side {
	case .Out: _, _ = link(g, cat, {at.node, at.port, id, u32(fit)})
	case .In:  _, _ = link(g, cat, {id, u32(fit), at.node, at.port})
	}
	return id
}

// A copy of node `id` (its parameters, no link) at its place plus `offset`. Returns its id; 0 when refused (as node_add).
node_copy :: proc(g: ^Graph, cat: ^Catalog, id: u64, offset: [2]f32) -> u64 {
	n := graph_node(g, id)
	if n == nil || !can_add(g, cat, n.kind) { return 0 }
	out := node_clone(n^)
	g.next_id += 1
	out.id, out.pos = g.next_id, n.pos + offset
	append(&g.nodes, out)   // (after: `n` points into the array, which may move)
	return out.id
}

// The parameters of `n` set to its kind's defaults.
node_params_default :: proc(cat: ^Catalog, n: ^Node) {
	node_params_destroy(n)
	n.params = {}
	def := node_def(cat, n)
	if def == nil { return }
	for d, i in def.params {
		if i >= PARAMS_MAX { break }
		n.params[i] = {number = d.default_number, color = d.default_color}
		if d.default_text != "" { n.params[i].text = strings.clone(d.default_text) }
	}
}

// Whether `l` may be made: both ends exist and differ, the ports exist, the input takes the output's kind, and no cycle
// comes of it.
can_link :: proc(g: ^Graph, cat: ^Catalog, l: Link) -> bool {
	from, to := graph_node(g, l.from_node), graph_node(g, l.to_node)
	if from == nil || to == nil || from == to { return false }
	fd, td := node_def(cat, from), node_def(cat, to)
	if fd == nil || td == nil { return false }
	if int(l.from_port) >= len(fd.outputs) || int(l.to_port) >= len(td.inputs) { return false }
	if !port_accepts(cat, fd.outputs[l.from_port].kind, td.inputs[l.to_port].kind) { return false }
	// (a link from a node that `to` reaches already would close a loop)
	return !reaches(g, l.to_node, l.from_node)
}

// Makes `l`. An input that takes one link loses the one it had (`replaced`). ok false: refused (can_link), or the link is
// there already.
link :: proc(g: ^Graph, cat: ^Catalog, l: Link) -> (replaced: Maybe(Link), ok: bool) {
	if !can_link(g, cat, l) { return nil, false }
	for have in g.links { if have == l { return nil, false } }
	to := graph_node(g, l.to_node)
	if !node_def(cat, to).inputs[l.to_port].multiple {
		for have, i in g.links {
			if have.to_node == l.to_node && have.to_port == l.to_port {
				replaced = have
				ordered_remove(&g.links, i)
				break
			}
		}
	}
	append(&g.links, l)
	return replaced, true
}

unlink :: proc(g: ^Graph, l: Link) -> bool {
	for have, i in g.links {
		if have == l {
			ordered_remove(&g.links, i)
			return true
		}
	}
	return false
}

// Deletes the nodes `ids` and every link that touches them; a node whose kind's min_count it would break stays.
nodes_delete :: proc(g: ^Graph, cat: ^Catalog, ids: []u64) -> (deleted: int) {
	for id in ids {
		i := graph_node_index(g, id)
		if i < 0 { continue }
		kind := g.nodes[i].kind
		if kind >= 0 && kind < len(cat.nodes) && graph_count(g, kind) <= cat.nodes[kind].min_count { continue }
		node_params_destroy(&g.nodes[i])
		ordered_remove(&g.nodes, i)
		deleted += 1
		for j := len(g.links) - 1; j >= 0; j -= 1 {
			if g.links[j].from_node == id || g.links[j].to_node == id { ordered_remove(&g.links, j) }
		}
	}
	return
}

nodes_move :: proc(g: ^Graph, ids: []u64, delta: [2]f32) {
	for id in ids {
		if n := graph_node(g, id); n != nil { n.pos += delta }
	}
}

// Whether `to` is `from` or comes after it along the links.
reaches :: proc(g: ^Graph, from, to: u64) -> bool {
	if from == to { return true }
	seen := make(map[u64]bool, 16, context.temp_allocator)
	stack := make([dynamic]u64, 0, 16, context.temp_allocator)
	append(&stack, from)
	for len(stack) > 0 {
		id := pop(&stack)
		if id == to { return true }
		if seen[id] { continue }
		seen[id] = true
		for l in g.links { if l.from_node == id { append(&stack, l.to_node) } }
	}
	return false
}

////////////////////////////////
// Parameters

// The parameter called `name` of `n` (nil: its kind has none of that name).
param :: proc(cat: ^Catalog, n: ^Node, name: string) -> ^Param {
	_, i := param_def(cat, n, name)
	return i >= 0 ? &n.params[i] : nil
}

// Parameter `index` of `n` becomes `value` (its text copied): what ui.node_inspector's result gives.
param_set :: proc(n: ^Node, index: int, value: Param) {
	if index < 0 || index >= PARAMS_MAX { return }
	p := &n.params[index]
	if p.text != value.text {
		delete(p.text)
		p.text = strings.clone(value.text) if value.text != "" else ""
	}
	p.number, p.color = value.number, value.color
}

// The definition of `n`'s parameter `name` and its place (-1: none).
param_def :: proc(cat: ^Catalog, n: ^Node, name: string) -> (def: Param_Def, index: int) {
	nd := node_def(cat, n)
	if nd == nil { return {}, -1 }
	for d, i in nd.params {
		if i >= PARAMS_MAX { break }
		if d.name == name { return d, i }
	}
	return {}, -1
}

// A parameter's number as an int, clamped to its range or its choices (a hand-edited file may hold anything).
param_int :: proc(cat: ^Catalog, n: ^Node, name: string) -> int {
	return int(param_float(cat, n, name))
}

// A parameter's number, clamped as param_int.
param_float :: proc(cat: ^Catalog, n: ^Node, name: string) -> f64 {
	d, i := param_def(cat, n, name)
	if i < 0 { return 0 }
	v := n.params[i].number
	#partial switch d.type {
	case .Int, .Float: if d.hi > d.lo { v = clamp(v, d.lo, d.hi) }
	case .Choice:      v = clamp(v, 0, f64(max(len(d.choices) - 1, 0)))
	case .Bool:        v = v != 0 ? 1 : 0
	}
	return v
}

param_bool :: proc(cat: ^Catalog, n: ^Node, name: string) -> bool {
	p := param(cat, n, name)
	return p != nil && p.number != 0
}

param_text :: proc(cat: ^Catalog, n: ^Node, name: string) -> string {
	p := param(cat, n, name)
	return p != nil ? p.text : ""
}

param_color :: proc(cat: ^Catalog, n: ^Node, name: string) -> [4]u8 {
	p := param(cat, n, name)
	return p != nil ? p.color : {}
}

// The words of a Choice parameter's value ("": none).
param_choice_text :: proc(cat: ^Catalog, n: ^Node, name: string) -> string {
	d, i := param_def(cat, n, name)
	if i < 0 || d.type != .Choice || len(d.choices) == 0 { return "" }
	return d.choices[param_int(cat, n, name)]
}
