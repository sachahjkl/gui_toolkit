package tk_plugin_api

// The display list (plugins.md, decision 2): a render's tree of plain objects written as one flat array of nodes, in
// the order of a walk of the tree, each with its kind, its key, its number of children and its kind's struct. The
// plugin's thread writes it; the interface's thread replays it at each build (gt:plugins, view.odin) and frees it.
// Everything of a list is in its own arena: its nodes, their structs, their strings. No JavaScript value is in it:
// the handlers go to the writer's sink, by the node's key and the field's name.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import "core:strings"
import js "../js"

// The most nodes a list holds, and how deep a tree goes: past them, the rest is dropped and said.
LIST_MAX_NODES :: 20_000
LIST_MAX_DEPTH :: 64

List_Node :: struct {
	kind:     Node_Kind,
	key:      string,   // unique in the list: the node's own, or its parent's key and its place ("/0/2")
	children: int,      // its direct children, the nodes that follow it in the walk
	// a field's, a check box's or a switch's: the person's last change to this key that the plugin had heard of when
	// it rendered (the replay keeps the person's newer change: plugins.md, "A text field in a plugin's view")
	seen:     u64,
	// the node gives its state (a field of its struct tagged `state`: a field's value, a box's checked): the replay
	// shows it; without it the host's own state stays, whatever the plugin renders (a field read only on submit)
	controlled: bool,
	props:    rawptr,   // its kind's struct (NODES[kind].props), in the list's arena; nil for a struct of no field
}

List :: struct {
	arena:    virtual.Arena,
	nodes:    [dynamic]List_Node,   // (in the arena)
	problems: [dynamic]string,      // what was dropped, and why: the plugin's log says it (in the arena)
}

// What the writer tells its caller: the person's last change it heard of for a key, and each handler of a node.
List_Sink :: struct {
	user:    rawptr,
	seen:    proc(user: rawptr, key: string) -> u64,
	handler: proc(user: rawptr, key: string, event: string, f: js.Value),
}

// A node's struct, typed: nil when the list's node is of another kind.
node_props :: proc(n: List_Node, $T: typeid) -> ^T {
	nodes := NODES
	if nodes[int(n.kind)].props != T || n.props == nil { return nil }   // (NODES is in Node_Kind's order)
	return (^T)(n.props)
}

list_free :: proc(l: ^List) {
	if l == nil { return }
	virtual.arena_destroy(&l.arena)
	free(l, runtime.heap_allocator())
}

@(private = "file")
Writer :: struct {
	ctx:   ^js.Context,
	list:  ^List,
	al:    runtime.Allocator,
	sink:  List_Sink,
	keys:  map[string]bool,
	full:  bool,
	// a lazy list's row being written ("": a view's render): its own keys go under it, so that two rows never share
	// one and the program knows each row's nodes (list_write_rows)
	row:   string,
}

// The most rows one ask of a lazy list gets (the program asks for no more).
ROWS_MAX_PER_ASK :: 200

// The rows `from ..< to` of a lazy list whose key is `list_key`, each the result of `row(i)`. Each row is one column
// node keyed `<list_key>~<i>` (the program builds its own row box in its place, and takes its children), with the
// row's node as its one child, or none when `row(i)` gave null. A row's keys are under its column's: its place
// (`<list_key>~<i>/0/2`) or its own key (`<list_key>~<i>~<own>`). False: a row threw, or is not a node; the
// exception is pending and no list is made.
list_write_rows :: proc(ctx: ^js.Context, row: js.Value, list_key: string, from, to: int, sink: List_Sink) -> (l: ^List, ok: bool) {
	l = new(List, runtime.heap_allocator())
	w := Writer{ctx = ctx, list = l, sink = sink}
	if virtual.arena_init_growing(&l.arena) != nil {
		free(l, runtime.heap_allocator())
		js.throw_error(ctx, .internal, "no memory for the list's rows")
		return nil, false
	}
	w.al = virtual.arena_allocator(&l.arena)
	l.nodes = make([dynamic]List_Node, w.al)
	l.problems = make([dynamic]string, w.al)
	w.keys = make(map[string]bool, context.temp_allocator)
	column := type_info_of(Column_Node)
	for i in from ..< to {
		w.row = fmt.tprintf("%s~%d", list_key, i)
		tree := js.call_function(ctx, row, js.UNDEFINED, {js.new_number(f64(i))})
		if js.is_exception(tree) { list_free(l); return nil, false }
		js.root(ctx.rt, tree)
		// (the row's column is written whatever the bound of nodes: the program counts on one per row)
		props, _ := mem.alloc(column.size, column.align, w.al)
		at := len(l.nodes)
		append(&l.nodes, List_Node{kind = .Column, key = strings.clone(w.row, w.al), props = props})
		if js.is_null(tree) || js.is_undefined(tree) { continue }
		wrote, good := write_node(&w, tree, w.row, 0, 1)
		if !good { list_free(l); return nil, false }
		if wrote { l.nodes[at].children = 1 }
	}
	return l, true
}

// The list of `tree`, a render's result. False: a node is not what a node must be; a TypeError is pending and no list
// is made. A key given twice, a tree too deep or too large: the node is dropped and the list says why (problems).
list_write :: proc(ctx: ^js.Context, tree: js.Value, sink: List_Sink) -> (l: ^List, ok: bool) {
	l = new(List, runtime.heap_allocator())
	w := Writer{ctx = ctx, list = l, sink = sink}
	if virtual.arena_init_growing(&l.arena) != nil {
		free(l, runtime.heap_allocator())
		js.throw_error(ctx, .internal, "no memory for the view's list")
		return nil, false
	}
	w.al = virtual.arena_allocator(&l.arena)
	l.nodes = make([dynamic]List_Node, w.al)
	l.problems = make([dynamic]string, w.al)
	w.keys = make(map[string]bool, context.temp_allocator)
	if _, good := write_node(&w, tree, "", 0, 0); !good {
		list_free(l)
		return nil, false
	}
	return l, true
}

// Writes `v` and its children. `written` false: dropped (said in problems). `ok` false: an exception is pending.
@(private = "file")
write_node :: proc(w: ^Writer, v: js.Value, parent_key: string, index, depth: int) -> (written: bool, ok: bool) {
	ctx := w.ctx
	if !js.is_object(v) {
		js.throw_type_error(ctx, fmt.tprintf("render: the node at %s/%d is not an object with a kind", parent_key, index))
		return false, false
	}
	js.root(ctx.rt, v)
	kind_v := js.get_property_str(ctx, v, "kind")
	if js.is_exception(kind_v) { return false, false }
	name := ""
	if js.is_string(kind_v) { name, _ = js.to_utf8(ctx, kind_v, context.temp_allocator) }
	nodes := NODES
	decl := -1
	for d, i in nodes { if d.name == name { decl = i } }
	if decl < 0 {
		names := make([dynamic]string, context.temp_allocator)
		for d in nodes { append(&names, d.name) }
		js.throw_type_error(ctx, fmt.tprintf("render: a node's kind is \"%s\", not one of %s", name, strings.join(names[:], ", ", context.temp_allocator)))
		return false, false
	}
	d := nodes[decl]

	key := fmt.tprintf("%s/%d", parent_key, index)
	key_v := js.get_property_str(ctx, v, "key")
	if js.is_exception(key_v) { return false, false }
	if js.is_string(key_v) || js.is_number(key_v) {
		own, _ := js.to_utf8(ctx, key_v, context.temp_allocator)
		// ('~' is a lazy list's: its rows' keys are `<list>~<row>`, which a key of the plugin's must never be)
		if own == "" || strings.contains_any(own, "#~") || strings.has_prefix(own, "/") {
			problem(w, fmt.tprintf("the key \"%s\" is not a key (empty, '#', '~', or a leading '/'): the node is keyed by its place", own))
		} else {
			key = w.row != "" ? fmt.tprintf("%s~%s", w.row, own) : own
		}
	}
	// (a list in a list's row: the rows of the inner one would be asked for each row of the outer, unbounded)
	if d.kind == .List && w.row != "" {
		problem(w, fmt.tprintf("the list \"%s\" is in a row of a list: it is dropped", key))
		return false, true
	}
	if key in w.keys {
		problem(w, fmt.tprintf("the key \"%s\" is twice in the view: the second %s is dropped", key, d.name))
		return false, true
	}
	if len(w.list.nodes) >= LIST_MAX_NODES {
		if !w.full { problem(w, fmt.tprintf("the view has more than %d nodes: the rest is dropped", LIST_MAX_NODES)) }
		w.full = true
		return false, true
	}
	w.keys[key] = true

	// its struct, filled as a call's arguments are (bridge.odin), then moved to the list: its strings copied, its
	// functions given to the sink
	ti := type_info_of(d.props)
	buf: rawptr
	controlled := false
	if ti.size > 0 {
		buf, _ = mem.alloc(ti.size, ti.align, context.temp_allocator)
		what := fmt.tprintf("render: the %s \"%s\"", d.name, key)
		for k in 0 ..< reflect.struct_field_count(d.props) {
			f := reflect.struct_field_at(d.props, k)
			fv := js.get_property_str(ctx, v, f.name)
			if js.is_exception(fv) { return false, false }
			js.root(ctx.rt, fv)
			if strings.contains(string(f.tag), "state") && !js.is_undefined(fv) { controlled = true }
			if !fill(ctx, fv, f.type, rawptr(uintptr(buf) + f.offset), what, f.name, is_optional(f.tag)) { return false, false }
		}
	}
	owned_key := strings.clone(key, w.al)
	props: rawptr
	if ti.size > 0 {
		props, _ = mem.alloc(ti.size, ti.align, w.al)
		mem.copy(props, buf, ti.size)
		for k in 0 ..< reflect.struct_field_count(d.props) {
			f := reflect.struct_field_at(d.props, k)
			at := rawptr(uintptr(props) + f.offset)
			if is_function_type(f.type.id) {
				fn := (^js.Value)(at)^
				if js.is_callable(fn) && w.sink.handler != nil { w.sink.handler(w.sink.user, owned_key, f.name, fn) }
				(^js.Value)(at)^ = {}   // (no value of the engine crosses to the interface's thread)
			} else if f.type.id == typeid_of(Children) {
				(^js.Value)(at)^ = {}
			} else if f.type.id == typeid_of(string) {
				s := (^string)(at)
				s^ = strings.clone(s^, w.al)
			}
		}
	}
	at := len(w.list.nodes)
	seen := w.sink.seen != nil ? w.sink.seen(w.sink.user, owned_key) : 0
	append(&w.list.nodes, List_Node{kind = d.kind, key = owned_key, seen = seen, controlled = controlled, props = props})
	if !d.container { return true, true }

	kids := js.get_property_str(ctx, v, "children")
	if js.is_exception(kids) { return false, false }
	if js.is_undefined(kids) { return true, true }
	if !js.is_object(kids) {
		js.throw_type_error(ctx, fmt.tprintf("render: the children of the %s \"%s\" are not an array", d.name, key))
		return false, false
	}
	js.root(ctx.rt, kids)
	if depth + 1 > LIST_MAX_DEPTH {
		problem(w, fmt.tprintf("the view is deeper than %d nodes: the children of \"%s\" are dropped", LIST_MAX_DEPTH, key))
		return true, true
	}
	length_v := js.get_property_str(ctx, kids, "length")
	if js.is_exception(length_v) { return false, false }
	n, _ := js.to_number(ctx, length_v)
	count := 0
	for c in 0 ..< int(max(n, 0)) {
		child := js.get_property_str(ctx, kids, fmt.tprintf("%d", c))
		if js.is_exception(child) { return false, false }
		// (a hole, or a `cond && node` that was false: nothing, as a JSX child)
		if js.is_undefined(child) || js.is_null(child) || js.is_bool(child) { continue }
		wrote, good := write_node(w, child, key, c, depth + 1)
		if !good { return false, false }
		if wrote { count += 1 }
	}
	w.list.nodes[at].children = count
	return true, true
}

@(private = "file")
problem :: proc(w: ^Writer, text: string) {
	append(&w.list.problems, strings.clone(text, w.al))
}
