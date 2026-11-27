package debug

// Any Odin value by reflection (debug-panel.md, "Values"), and a value written as Odin source.

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "../ui"

// The items of an array or a slice shown at most; the levels of pointers and structs followed at most.
ITEMS_MAX :: 64
DEPTH_MAX :: 6

// `debug.value("look", &soldier.look)`: any value, by reflection. A struct is a section of its fields; a number, a
// bool, an enum, a string, a vector of 2 to 4 numbers, a ui.Color is edited; an array or a slice shows ITEMS_MAX
// items; a pointer is followed (DEPTH_MAX levels); the rest is watched as text. A field's tag says more: `debug:"-"`
// hides it, `debug:"ro"` shows it read only, `debug:"0..360"` bounds it. Not a pointer: shown read only. True when
// something in it changed.
value :: proc(label: string, v: any) -> (changed: bool) {
	when ENABLED {
		if v.data == nil { watch_text(label, "nil"); return }
		ti := type_info_of(v.id)
		if ptr, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Pointer); ok && ptr.elem != nil {
			target := (^rawptr)(v.data)^
			if target == nil { watch_text(label, "nil"); return }
			return reflect_node(label, target, ptr.elem, {}, 0)
		}
		return reflect_node(label, v.data, ti, {read_only = true}, 0)
	} else {
		return false
	}
}

// What a field's tag says of it.
@(private)
Field_Tag :: struct {
	hidden, read_only: bool,
	lo, hi:            Maybe(f64),
	step:              f64,
}

@(private)
tag_of :: proc(tag: reflect.Struct_Tag, inherited: Field_Tag) -> (t: Field_Tag) {
	t.read_only = inherited.read_only
	text, ok := reflect.struct_tag_lookup(tag, "debug")
	if !ok { return }
	for part in strings.split(text, ",", context.temp_allocator) {
		w := strings.trim_space(part)
		switch {
		case w == "-":  t.hidden = true
		case w == "ro": t.read_only = true
		case strings.has_prefix(w, "step="):
			t.step, _ = strconv.parse_f64(w[len("step="):])
		case strings.contains(w, ".."):
			at := strings.index(w, "..")
			if l, lok := strconv.parse_f64(w[:at]); lok { t.lo = l }
			if h, hok := strconv.parse_f64(w[at + 2:]); hok { t.hi = h }
		}
	}
	return
}

@(private)
reflect_node :: proc(label: string, data: rawptr, ti: ^runtime.Type_Info, tag: Field_Tag, depth: int) -> (changed: bool) {
	if tag.hidden { return }
	if ti.id == typeid_of(ui.Color) { return color_any(label, (^ui.Color)(data), tag.read_only) }
	// (a curve, or a few as a vector's channels: the curve editor)
	if ti.id == typeid_of(Curve) { return curves_any(label, ([^]Curve)(data)[:1], nil, "x") }
	if ti.id == typeid_of(ui.Cubic_Bezier) { return easing_any(label, (^ui.Cubic_Bezier)(data)) }
	b := runtime.type_info_base(ti)
	if a, ok := b.variant.(runtime.Type_Info_Array); ok && a.elem.id == typeid_of(Curve) && a.count >= 1 && a.count <= CURVE_CHANNELS_MAX {
		return curves_any(label, ([^]Curve)(data)[:a.count], nil, "xyzw")
	}
	#partial switch v in b.variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float:
		return number_any(label, data, ti, tag.lo, tag.hi, tag.step, tag.read_only)
	case runtime.Type_Info_Boolean:
		return bool_any(label, data, ti, tag.read_only)
	case runtime.Type_Info_Enum:
		return enum_any(label, data, ti, tag.read_only)
	case runtime.Type_Info_String:
		if v.is_cstring { watch_text(label, string((^cstring)(data)^)); return }
		return string_any(label, (^string)(data), tag.read_only)
	case runtime.Type_Info_Array:
		if v.count >= 2 && v.count <= 4 && scalar_numeric(v.elem) {
			return vector_any(label, data, v.elem, v.count, tag.lo, tag.hi, tag.step, tag.read_only)
		}
		return items_node(label, data, v.elem, v.elem_size, v.count, tag, depth)
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(data)
		return items_node(label, s.data, v.elem, v.elem_size, s.len, tag, depth)
	case runtime.Type_Info_Dynamic_Array:
		s := (^runtime.Raw_Dynamic_Array)(data)
		return items_node(label, s.data, v.elem, v.elem_size, s.len, tag, depth)
	case runtime.Type_Info_Struct:
		if depth >= DEPTH_MAX { watch_text(label, "…"); return }
		if section(label) {
			for i in 0 ..< int(v.field_count) {
				f := reflect.struct_field_at(ti.id, i)
				ft := tag_of(f.tag, tag)
				if reflect_node(f.name, rawptr(uintptr(data) + f.offset), f.type, ft, depth + 1) { changed = true }
			}
		}
		return
	case runtime.Type_Info_Pointer:
		target := (^rawptr)(data)^
		if target == nil || v.elem == nil { watch_text(label, target == nil ? "nil" : fmt.tprintf("%p", target)); return }
		if depth >= DEPTH_MAX { watch_text(label, fmt.tprintf("%p", target)); return }
		return reflect_node(label, target, v.elem, tag, depth + 1)
	}
	watch_text(label, fmt.tprint(any{data, ti.id}))
	return
}

@(private)
scalar_numeric :: proc(ti: ^runtime.Type_Info) -> bool {
	#partial switch _ in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float: return true
	}
	return false
}

// An array's or a slice's items, in a section titled with their count; ITEMS_MAX of them, then how many more.
@(private)
items_node :: proc(label: string, data: rawptr, elem: ^runtime.Type_Info, elem_size, count: int, tag: Field_Tag, depth: int) -> (changed: bool) {
	if depth >= DEPTH_MAX { watch_text(label, fmt.tprintf("%d items", count)); return }
	if section(fmt.tprintf("%s [%d]", label, count), count <= 8) {
		for i in 0 ..< min(count, ITEMS_MAX) {
			if reflect_node(fmt.tprintf("[%d]", i), rawptr(uintptr(data) + uintptr(i * elem_size)), elem, tag, depth + 1) { changed = true }
		}
		if count > ITEMS_MAX { note(fmt.tprintf("%d more", count - ITEMS_MAX)) }
	}
	return
}

////////////////////////////////
// Odin source

// `v` written as Odin source, to paste back into the program (temp allocator): a struct as its type's name and its
// fields (`Soldier{model = 2, position = {0, 1.5, 0}}`), an array as its items, an enum as `.Name`, a string quoted; a
// pointer, a map, a procedure as a comment. Works in a release build too.
odin_text :: proc(v: any) -> string {
	b := strings.builder_make(context.temp_allocator)
	odin_write(&b, v.data, type_info_of(v.id), true, 0)
	return strings.to_string(b)
}

@(private)
odin_write :: proc(b: ^strings.Builder, data: rawptr, ti: ^runtime.Type_Info, named: bool, depth: int) {
	if data == nil { strings.write_string(b, "nil"); return }
	// (a curve's keys past its count are not written: Odin takes them by index)
	if ti.id == typeid_of(Curve) { curve_write(b, (^Curve)(data)^, named ? "Curve" : ""); return }
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean:
		fmt.sbprint(b, any{data, ti.id})
	case runtime.Type_Info_Enum:
		x := i64(scalar_get(data, v.base))
		for e, i in v.values {
			if i64(e) == x { strings.write_byte(b, '.'); strings.write_string(b, v.names[i]); return }
		}
		fmt.sbprintf(b, "%d", x)
	case runtime.Type_Info_String:
		s := v.is_cstring ? string((^cstring)(data)^) : (^string)(data)^
		fmt.sbprintf(b, "%q", s)
	case runtime.Type_Info_Array:
		strings.write_byte(b, '{')
		for i in 0 ..< v.count {
			if i > 0 { strings.write_string(b, ", ") }
			odin_write(b, rawptr(uintptr(data) + uintptr(i * v.elem_size)), v.elem, false, depth + 1)
		}
		strings.write_byte(b, '}')
	case runtime.Type_Info_Struct:
		if depth >= DEPTH_MAX { strings.write_string(b, "{}"); return }
		if named { if n, ok := ti.variant.(runtime.Type_Info_Named); ok { strings.write_string(b, n.name) } }
		strings.write_byte(b, '{')
		for i in 0 ..< int(v.field_count) {
			f := reflect.struct_field_at(ti.id, i)
			if i > 0 { strings.write_string(b, ", ") }
			fmt.sbprintf(b, "%s = ", f.name)
			odin_write(b, rawptr(uintptr(data) + f.offset), f.type, false, depth + 1)
		}
		strings.write_byte(b, '}')
	case:
		fmt.sbprintf(b, "{{}} /* %v */", ti.id)
	}
}
