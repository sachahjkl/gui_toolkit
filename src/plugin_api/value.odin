package tk_plugin_api

// An Odin value as JavaScript, by reflection: what `fill` reads, written back (a program's call's result and an
// event's payload, app.odin). A string, a boolean, a number, an enum as its name (as `fill` reads it), a struct as a
// plain object of its fields, a slice as an array.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import js "../js"

// The JavaScript of the value of type `ti` at `at`. Each object made is rooted until the turn ends (js.root), as the
// bridge's values are.
value_to_js :: proc(ctx: ^js.Context, ti: ^runtime.Type_Info, at: rawptr) -> js.Value {
	#partial switch info in reflect.type_info_base(ti).variant {
	case runtime.Type_Info_String:
		return js.new_string(ctx, (^string)(at)^)
	case runtime.Type_Info_Boolean:
		return js.new_bool((^bool)(at)^)
	case runtime.Type_Info_Float:
		return js.new_number(ti.size == 4 ? f64((^f32)(at)^) : (^f64)(at)^)
	case runtime.Type_Info_Integer:
		x: i64
		mem.copy(&x, at, ti.size)
		// (the high bytes of a narrower signed integer: its sign)
		if info.signed && ti.size < 8 && (x >> uint(ti.size * 8 - 1)) & 1 == 1 { x |= ~i64(0) << uint(ti.size * 8) }
		return js.new_number(f64(x))
	case runtime.Type_Info_Enum:
		x: i64
		mem.copy(&x, at, ti.size)
		names := reflect.enum_field_names(ti.id)
		values := reflect.enum_field_values(ti.id)
		for v, k in values { if i64(v) == x { return js.new_string(ctx, names[k]) } }
		return js.UNDEFINED
	case runtime.Type_Info_Struct:
		o := js.new_object(ctx)
		js.root(ctx.rt, o)
		for k in 0 ..< int(info.field_count) {
			v := value_to_js(ctx, info.types[k], rawptr(uintptr(at) + info.offsets[k]))
			js.root(ctx.rt, v)
			js.set_property_str(ctx, o, info.names[k], v)
		}
		return o
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(at)
		a := js.new_array(ctx)
		js.root(ctx.rt, a)
		for k in 0 ..< s.len {
			v := value_to_js(ctx, info.elem, rawptr(uintptr(s.data) + uintptr(k * info.elem_size)))
			js.root(ctx.rt, v)
			js.set_property_str(ctx, a, fmt.tprintf("%d", k), v)
		}
		return a
	}
	return js.UNDEFINED
}
