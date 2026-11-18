package tk_plugin_api

// The bytes that cross between a program and its plugin's process (gt:plugins, channel.odin): little-endian numbers,
// strings with their length, and the display list (display.odin) node by node, each node's struct field by field in
// its declaration's order (reflection: the same text as the bridge and `tk plugin_api` read). A reader never trusts
// what it reads: a length past the end, a node of no kind, a frame left short make it `bad`, and nothing it gives is
// used.

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import "core:strings"

Wire_Writer :: struct {
	buf: [dynamic]u8,
}

Wire_Reader :: struct {
	data: []u8,
	at:   int,
	bad:  bool,   // read past the end, or something that cannot be
}

put_u8 :: proc(w: ^Wire_Writer, v: u8) { append(&w.buf, v) }
put_bool :: proc(w: ^Wire_Writer, v: bool) { append(&w.buf, u8(v ? 1 : 0)) }

put_u64 :: proc(w: ^Wire_Writer, v: u64) {
	x := v
	for _ in 0 ..< 8 {
		append(&w.buf, u8(x & 0xff))
		x >>= 8
	}
}

put_i64 :: proc(w: ^Wire_Writer, v: i64) { put_u64(w, cast(u64)v) }
put_f64 :: proc(w: ^Wire_Writer, v: f64) { put_u64(w, transmute(u64)v) }

put_string :: proc(w: ^Wire_Writer, s: string) {
	put_u64(w, u64(len(s)))
	append(&w.buf, ..transmute([]u8)s)
}

get_u8 :: proc(r: ^Wire_Reader) -> u8 {
	if r.at + 1 > len(r.data) { r.bad = true; return 0 }
	r.at += 1
	return r.data[r.at - 1]
}

get_bool :: proc(r: ^Wire_Reader) -> bool { return get_u8(r) != 0 }

get_u64 :: proc(r: ^Wire_Reader) -> u64 {
	if r.at + 8 > len(r.data) { r.bad = true; return 0 }
	v: u64
	for i in 0 ..< 8 { v |= u64(r.data[r.at + i]) << (8 * u64(i)) }
	r.at += 8
	return v
}

get_i64 :: proc(r: ^Wire_Reader) -> i64 { return cast(i64)get_u64(r) }
get_f64 :: proc(r: ^Wire_Reader) -> f64 { return transmute(f64)get_u64(r) }

// A string, copied in `allocator`.
get_string :: proc(r: ^Wire_Reader, allocator := context.allocator) -> string {
	n := get_u64(r)
	if r.bad || n > u64(len(r.data) - r.at) { r.bad = true; return "" }
	s := strings.clone(string(r.data[r.at:][:int(n)]), allocator)
	r.at += int(n)
	return s
}

// A count of things that follow, each at least `least` bytes long: one larger than what is left is a lie.
get_count :: proc(r: ^Wire_Reader, least := 1) -> int {
	n := get_u64(r)
	if r.bad || n > u64((len(r.data) - r.at) / max(least, 1)) { r.bad = true; return 0 }
	return int(n)
}

// The list: its nodes, each with its struct's fields (a function's or the children's are not sent: they stay with
// the plugin). Its problems stay with the plugin too (its log says them).
list_encode :: proc(w: ^Wire_Writer, l: ^List) {
	nodes := NODES
	put_u64(w, u64(len(l.nodes)))
	for n in l.nodes {
		put_u8(w, u8(n.kind))
		put_string(w, n.key)
		put_u64(w, u64(n.children))
		put_u64(w, n.seen)
		put_bool(w, n.controlled)
		props := nodes[int(n.kind)].props
		for k in 0 ..< reflect.struct_field_count(props) {
			f := reflect.struct_field_at(props, k)
			if n.props == nil { break }
			field_encode(w, f.type, rawptr(uintptr(n.props) + f.offset))
		}
	}
}

// The list `list_encode` wrote, in an arena of its own. nil: what was read is not a list.
list_decode :: proc(r: ^Wire_Reader) -> ^List {
	l := new(List, runtime.heap_allocator())
	if virtual.arena_init_growing(&l.arena) != nil {
		free(l, runtime.heap_allocator())
		return nil
	}
	al := virtual.arena_allocator(&l.arena)
	l.nodes = make([dynamic]List_Node, al)
	l.problems = make([dynamic]string, al)
	nodes := NODES
	count := get_count(r, 26)   // (a node's least bytes: its kind, key, children, seen and controlled)
	for _ in 0 ..< count {
		n: List_Node
		kind := get_u8(r)
		if int(kind) >= len(nodes) { r.bad = true; break }
		n.kind = Node_Kind(kind)
		n.key = get_string(r, al)
		n.children = int(get_u64(r))
		n.seen = get_u64(r)
		n.controlled = get_bool(r)
		props := nodes[int(kind)].props
		ti := type_info_of(props)
		if ti.size > 0 {
			n.props, _ = mem.alloc(ti.size, ti.align, al)
			for k in 0 ..< reflect.struct_field_count(props) {
				f := reflect.struct_field_at(props, k)
				field_decode(r, f.type, rawptr(uintptr(n.props) + f.offset), al)
			}
		}
		if r.bad { break }
		append(&l.nodes, n)
	}
	// (each node's children are nodes that follow it: a count past the end is a list the replay would walk out of)
	if !r.bad && !children_fit(l.nodes[:]) { r.bad = true }
	if r.bad {
		list_free(l)
		return nil
	}
	return l
}

@(private = "file")
children_fit :: proc(nodes: []List_Node) -> bool {
	walk :: proc(nodes: []List_Node, i: ^int) -> bool {
		if i^ >= len(nodes) { return false }
		n := nodes[i^]
		i^ += 1
		if n.children < 0 { return false }
		for _ in 0 ..< n.children { if !walk(nodes, i) { return false } }
		return true
	}
	i := 0
	for i < len(nodes) { if !walk(nodes, &i) { return false } }
	return true
}

@(private = "file")
field_encode :: proc(w: ^Wire_Writer, ti: ^runtime.Type_Info, at: rawptr) { value_encode(w, ti, at) }

@(private = "file")
field_decode :: proc(r: ^Wire_Reader, ti: ^runtime.Type_Info, at: rawptr, al: runtime.Allocator) { value_decode(r, ti, at, al) }

// A value of type `ti` at `at`, by reflection: a node's field, a program's call's argument or result (app.odin). A
// struct is its fields in order, a slice its count then its elements; a function and a node's children are not sent
// (they stay with the plugin).
value_encode :: proc(w: ^Wire_Writer, ti: ^runtime.Type_Info, at: rawptr) {
	if is_function_type(ti.id) || ti.id == typeid_of(Children) { return }
	#partial switch info in reflect.type_info_base(ti).variant {
	case runtime.Type_Info_String:  put_string(w, (^string)(at)^)
	case runtime.Type_Info_Boolean: put_bool(w, (^bool)(at)^)
	case runtime.Type_Info_Float:   put_f64(w, ti.size == 4 ? f64((^f32)(at)^) : (^f64)(at)^)
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		x: i64
		mem.copy(&x, at, ti.size)   // (little-endian: the low bytes)
		put_i64(w, x)
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(info.field_count) { value_encode(w, info.types[k], rawptr(uintptr(at) + info.offsets[k])) }
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(at)
		put_u64(w, u64(s.len))
		for k in 0 ..< s.len { value_encode(w, info.elem, rawptr(uintptr(s.data) + uintptr(k * info.elem_size))) }
	}
}

// What value_encode wrote, at `at` (zeroed by the caller), its strings and slices in `al`. A count past what is left
// or an enum's value the type does not have makes `r` bad.
value_decode :: proc(r: ^Wire_Reader, ti: ^runtime.Type_Info, at: rawptr, al: runtime.Allocator) {
	if is_function_type(ti.id) || ti.id == typeid_of(Children) { return }
	#partial switch info in reflect.type_info_base(ti).variant {
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(info.field_count) {
			value_decode(r, info.types[k], rawptr(uintptr(at) + info.offsets[k]), al)
			if r.bad { return }
		}
		return
	case runtime.Type_Info_Slice:
		// (an element is at least a byte on the wire: a count larger than what is left is a lie)
		n := get_count(r, 1)
		if r.bad || n == 0 { return }
		data, err := mem.alloc(n * info.elem_size, info.elem.align, al)
		if err != nil { r.bad = true; return }
		for k in 0 ..< n {
			value_decode(r, info.elem, rawptr(uintptr(data) + uintptr(k * info.elem_size)), al)
			if r.bad { return }
		}
		(^runtime.Raw_Slice)(at)^ = {data = data, len = n}
		return
	}
	#partial switch _ in reflect.type_info_base(ti).variant {
	case runtime.Type_Info_String:  (^string)(at)^ = get_string(r, al)
	case runtime.Type_Info_Boolean: (^bool)(at)^ = get_bool(r)
	case runtime.Type_Info_Float:
		v := get_f64(r)
		if ti.size == 4 { (^f32)(at)^ = f32(v) } else { (^f64)(at)^ = v }
	case runtime.Type_Info_Enum:
		x := get_i64(r)
		// (an enum's value the declarations do not have would index a table of the replay out of its bounds)
		known := false
		for v in reflect.enum_field_values(ti.id) { known ||= i64(v) == x }
		if !known { r.bad = true; return }
		mem.copy(at, &x, ti.size)
	case runtime.Type_Info_Integer:
		x := get_i64(r)
		mem.copy(at, &x, ti.size)
	}
}
