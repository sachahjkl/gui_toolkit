package tk_flowgraph

// A set of graphs as JSON text: what a program keeps in its file. The program reads the file and writes it (on a worker:
// it is disk); this is the text, both ways.
//
//   {"version": 1, "graphs": [{"id": 1, "name": "Screenshot", "labels": ["region"], "next_id": 5,
//     "nodes": [{"id": 1, "kind": "resize", "x": 0, "y": 120, "params": {"percent": 50, "color": "#000000ff"}}],
//     "links": [{"from": 1, "from_port": 0, "to": 2, "to_port": 0}]}]}
//
// A node's kind is its Node_Def.name; a parameter is written under its name: a number (Int, Float, Choice), true / false
// (Bool), "#rrggbbaa" (Color), a string (Text, Folder, List). What the text lacks takes its default; what it has that the
// catalog does not know is dropped (a node of an unknown kind, a link that is not valid).

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// A graph of the set, with the program's words about it.
Graph_Entry :: struct {
	id:     u64,                // unique in the set, never reused (Graph_Set.next_id)
	name:   string,             // owned
	labels: [dynamic]string,    // owned: the program's words for it (the triggers that run it)
	graph:  Graph,
}

Graph_Set :: struct {
	list:    [dynamic]Graph_Entry,
	next_id: u64,
}

// The names in the text: a program keeps those of its file ("workflows", "triggers"). "" takes the default.
Store_Format :: struct {
	version: int,      // written; a text of a newer one is refused (0: 1)
	list:    string,   // the key of the list ("graphs")
	labels:  string,   // the key of each graph's labels ("labels")
}

entry_destroy :: proc(e: ^Graph_Entry) {
	delete(e.name)
	for l in e.labels { delete(l) }
	delete(e.labels)
	graph_destroy(&e.graph)
	e^ = {}
}

entry_clone :: proc(e: Graph_Entry, allocator := context.allocator) -> Graph_Entry {
	out := e
	out.name = strings.clone(e.name, allocator)
	out.labels = make([dynamic]string, len(e.labels), allocator)
	for l, i in e.labels { out.labels[i] = strings.clone(l, allocator) }
	out.graph = graph_clone(e.graph, allocator)
	return out
}

set_destroy :: proc(s: ^Graph_Set) {
	for &e in s.list { entry_destroy(&e) }
	delete(s.list)
	s^ = {}
}

// The entry `id` (nil: none).
set_find :: proc(s: ^Graph_Set, id: u64) -> ^Graph_Entry {
	for &e in s.list { if e.id == id { return &e } }
	return nil
}

// `e` (taken) at the end of the set, with a new id. Returns it.
set_add :: proc(s: ^Graph_Set, e: Graph_Entry) -> u64 {
	e := e
	s.next_id += 1
	e.id = s.next_id
	append(&s.list, e)
	return e.id
}

set_remove :: proc(s: ^Graph_Set, id: u64) -> bool {
	for &e, i in s.list {
		if e.id != id { continue }
		entry_destroy(&e)
		ordered_remove(&s.list, i)
		return true
	}
	return false
}

@(private = "file")
format_defaults :: proc(f: Store_Format) -> Store_Format {
	f := f
	if f.version <= 0 { f.version = 1 }
	if f.list == "" { f.list = "graphs" }
	if f.labels == "" { f.labels = "labels" }
	return f
}

////////////////////////////////
// Writing

// The text of `s` (owned).
set_text :: proc(s: ^Graph_Set, cat: ^Catalog, format: Store_Format = {}) -> string {
	f := format_defaults(format)
	b := strings.builder_make()
	strings.write_string(&b, "{\n  \"version\": ")
	strings.write_int(&b, f.version)
	strings.write_string(&b, ",\n  ")
	json_string(&b, f.list)
	strings.write_string(&b, ": [")
	for &e, ei in s.list {
		strings.write_string(&b, ei == 0 ? "\n    {" : ",\n    {")
		strings.write_string(&b, "\"id\": ")
		strings.write_u64(&b, e.id)
		strings.write_string(&b, ", \"name\": ")
		json_string(&b, e.name)
		strings.write_string(&b, ", ")
		json_string(&b, f.labels)
		strings.write_string(&b, ": [")
		for l, li in e.labels {
			if li > 0 { strings.write_string(&b, ", ") }
			json_string(&b, l)
		}
		strings.write_string(&b, "], \"next_id\": ")
		strings.write_u64(&b, e.graph.next_id)
		strings.write_string(&b, ",\n      \"nodes\": [")
		for &n, ni in e.graph.nodes {
			strings.write_string(&b, ni == 0 ? "\n        " : ",\n        ")
			node_write(&b, cat, &n)
		}
		strings.write_string(&b, len(e.graph.nodes) > 0 ? "\n      ],\n      \"links\": [" : "],\n      \"links\": [")
		for l, li in e.graph.links {
			if li > 0 { strings.write_string(&b, ", ") }
			strings.write_string(&b, "{\"from\": ")
			strings.write_u64(&b, l.from_node)
			strings.write_string(&b, ", \"from_port\": ")
			strings.write_u64(&b, u64(l.from_port))
			strings.write_string(&b, ", \"to\": ")
			strings.write_u64(&b, l.to_node)
			strings.write_string(&b, ", \"to_port\": ")
			strings.write_u64(&b, u64(l.to_port))
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, len(s.list) > 0 ? "\n  ]\n}\n" : "]\n}\n")
	return strings.to_string(b)
}

@(private = "file")
node_write :: proc(b: ^strings.Builder, cat: ^Catalog, n: ^Node) {
	def := node_def(cat, n)
	strings.write_string(b, "{\"id\": ")
	strings.write_u64(b, n.id)
	strings.write_string(b, ", \"kind\": ")
	json_string(b, def != nil ? def.name : "")
	strings.write_string(b, ", \"x\": ")
	json_number(b, f64(n.pos.x))
	strings.write_string(b, ", \"y\": ")
	json_number(b, f64(n.pos.y))
	strings.write_string(b, ", \"params\": {")
	if def != nil {
		for d, i in def.params {
			if i >= PARAMS_MAX { break }
			if i > 0 { strings.write_string(b, ", ") }
			json_string(b, d.name)
			strings.write_string(b, ": ")
			p := n.params[i]
			switch d.type {
			case .Int, .Choice: strings.write_i64(b, i64(p.number))
			case .Float:        json_number(b, p.number)
			case .Bool:         strings.write_string(b, p.number != 0 ? "true" : "false")
			case .Color:        json_string(b, color_text(p.color))
			case .Text, .Folder, .List: json_string(b, p.text)
			}
		}
	}
	strings.write_string(b, "}}")   // (its parameters, then the node)
}

// The shortest text that reads back as `v`.
@(private = "file")
json_number :: proc(b: ^strings.Builder, v: f64) {
	buf: [64]u8
	strings.write_string(b, strconv.write_float(buf[:], v, 'g', -1, 64, {}))
}

// `s` as a JSON string, quoted and escaped.
@(private = "file")
json_string :: proc(b: ^strings.Builder, s: string) {
	hex := "0123456789abcdef"
	strings.write_byte(b, '"')
	for c in s {
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				strings.write_string(b, "\\u00")
				strings.write_byte(b, hex[int(c) >> 4])
				strings.write_byte(b, hex[int(c) & 0xf])
			} else {
				strings.write_rune(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// "#rrggbbaa" (temp allocator).
color_text :: proc(c: [4]u8) -> string {
	hex := "0123456789abcdef"
	out := make([]u8, 9, context.temp_allocator)
	out[0] = '#'
	for v, i in c {
		out[1 + i * 2] = hex[int(v) >> 4]
		out[2 + i * 2] = hex[int(v) & 0xf]
	}
	return string(out)
}

// "#rrggbb" or "#rrggbbaa".
color_parse :: proc(s: string) -> (c: [4]u8, ok: bool) {
	if !strings.has_prefix(s, "#") || (len(s) != 7 && len(s) != 9) { return }
	c.a = 255
	for i in 0 ..< (len(s) - 1) / 2 {
		v, read := strconv.parse_uint(s[1 + i * 2:][:2], 16)
		if !read { return {}, false }
		c[i] = u8(v)
	}
	return c, true
}

////////////////////////////////
// Reading

// The set of `text`. why: "" when it reads; else what is wrong (temp allocator), and `s` holds what was read so far (to
// free). Ids taken twice get new ones; links are made through `link`, so one that is not valid is dropped.
set_parse :: proc(text: string, cat: ^Catalog, format: Store_Format = {}) -> (s: Graph_Set, why: string) {
	f := format_defaults(format)
	root, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	if err != .None { return s, fmt.tprintf("not JSON: %v", err) }
	top, is_object := root.(json.Object)
	if !is_object { return s, "not an object" }
	if v, has := top["version"]; has {
		if version := json_int(v); version > i64(f.version) { return s, fmt.tprintf("version %d is newer than this program's", version) }
	}
	list, is_array := top[f.list].(json.Array)
	if !is_array { return s, fmt.tprintf("no list %q", f.list) }
	for item in list {
		o, ok := item.(json.Object)
		if !ok { return s, "a graph is not an object" }
		e := Graph_Entry{id = u64(json_int(o["id"])), name = strings.clone(json_text(o["name"]))}
		if labels, has := o[f.labels].(json.Array); has {
			for l in labels {
				if t := json_text(l); t != "" { append(&e.labels, strings.clone(t)) }
			}
		}
		if nodes, has := o["nodes"].(json.Array); has {
			for node_item in nodes {
				no, is_node := node_item.(json.Object)
				if !is_node { continue }
				n, known := node_parse(no, cat)
				if !known { continue }
				if n.id == 0 || graph_node(&e.graph, n.id) != nil { node_params_destroy(&n); continue }
				append(&e.graph.nodes, n)
				e.graph.next_id = max(e.graph.next_id, n.id)
			}
		}
		e.graph.next_id = max(e.graph.next_id, u64(json_int(o["next_id"])))
		if links, has := o["links"].(json.Array); has {
			for link_item in links {
				lo, is_link := link_item.(json.Object)
				if !is_link { continue }
				l := Link{
					from_node = u64(json_int(lo["from"])), from_port = u32(json_int(lo["from_port"])),
					to_node = u64(json_int(lo["to"])), to_port = u32(json_int(lo["to_port"])),
				}
				_, _ = link(&e.graph, cat, l)   // (one that is not valid is dropped)
			}
		}
		if e.id == 0 || set_find(&s, e.id) != nil { e.id = s.next_id + 1 }
		s.next_id = max(s.next_id, e.id)
		append(&s.list, e)
	}
	return s, ""
}

// A node of the text. known false: its kind is not the catalog's.
@(private = "file")
node_parse :: proc(o: json.Object, cat: ^Catalog) -> (n: Node, known: bool) {
	n.kind = kind_named(cat, json_text(o["kind"]))
	if n.kind < 0 { return {}, false }
	known = true
	n.id = u64(json_int(o["id"]))
	n.pos = {f32(json_float(o["x"])), f32(json_float(o["y"]))}
	node_params_default(cat, &n)
	params, has := o["params"].(json.Object)
	if !has { return }
	for d, i in cat.nodes[n.kind].params {
		if i >= PARAMS_MAX { break }
		v, given := params[d.name]
		if !given { continue }
		p := &n.params[i]
		switch d.type {
		case .Int, .Choice, .Float:
			if x, is_number := json_number_of(v); is_number { p.number = x }
		case .Bool:
			if x, is_bool := v.(json.Boolean); is_bool { p.number = x ? 1 : 0 }
		case .Color:
			if c, read := color_parse(json_text(v)); read { p.color = c }
		case .Text, .Folder, .List:
			if x, is_string := v.(json.String); is_string {
				delete(p.text)
				p.text = strings.clone(string(x))
			}
		}
	}
	return
}

@(private = "file")
json_number_of :: proc(v: json.Value) -> (f: f64, ok: bool) {
	#partial switch x in v {
	case json.Integer: return f64(x), true
	case json.Float:   return f64(x), true
	}
	return 0, false
}

@(private = "file")
json_float :: proc(v: json.Value) -> f64 {
	f, _ := json_number_of(v)
	return f
}

@(private = "file")
json_int :: proc(v: json.Value) -> i64 {
	#partial switch x in v {
	case json.Integer: return max(i64(x), 0)
	case json.Float:   return x < 0 ? 0 : i64(x)
	}
	return 0
}

@(private = "file")
json_text :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return string(s)
}
