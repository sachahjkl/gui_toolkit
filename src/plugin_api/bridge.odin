package tk_plugin_api

// The one bridge between a plugin's JavaScript and the host's procedures. Every call of the API is the same native
// function (`bridge`), told apart by its declaration's index: it checks the capability, fills the declaration's struct
// from the JavaScript arguments by reflection, then calls the host's implementation. An author of a host procedure
// writes neither a conversion nor a check, so neither can be forgotten (plugins.md, decision 4).

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import js "../js"

Capabilities :: bit_set[Capability]

// What a call sees: its realm, and which declaration it is.
Call :: struct {
	ctx:         ^js.Context,
	realm:       ^Realm,
	declaration: int,
}

// The host's side of a declaration: `args` points to the declaration's struct, filled. It returns the call's result,
// or js.EXCEPTION with an exception pending.
Impl :: #type proc(c: ^Call, args: rawptr) -> js.Value

// A typed implementation as an Impl: the compiler checks that `p` takes the struct `A`.
implement :: proc($A: typeid, p: proc(c: ^Call, a: ^A) -> js.Value) -> Impl {
	return transmute(Impl)p
}

// One realm's API: the implementations, what the person granted, and the host's own pointer. The host keeps it as long
// as the runtime, in the runtime's host_data (the bridge finds it there: a native function has no user data).
Realm :: struct {
	impls:   [len(DECLARATIONS)]Impl,
	granted: Capabilities,
	user:    rawptr,
}

// Gives declaration `module`.`name` its implementation. False: no such declaration (the host and the declarations
// disagree: a test of the host checks that each one is set).
realm_set :: proc(realm: ^Realm, module, name: string, impl: Impl) -> bool {
	decls := DECLARATIONS
	for d, i in decls {
		if d.module == module && d.name == name { realm.impls[i] = impl; return true }
	}
	return false
}

// The API object of a realm: one object per module, each with its calls. `rt.host_data` must be `realm` before a call.
// The host retains the result (js.retain) and gives it to the module "gt" (module_source) through import.meta.gt.
install :: proc(ctx: ^js.Context, realm: ^Realm) -> js.Value {
	ctx.rt.host_data = realm
	api := js.new_object(ctx)
	decls := DECLARATIONS
	for d, i in decls {
		mod := js.get_property_str(ctx, api, d.module)
		if js.is_undefined(mod) {
			mod = js.new_object(ctx)
			js.set_property_str(ctx, api, d.module, mod)
		}
		f := js.new_function(ctx, bridge, d.name, reflect.struct_field_count(d.arguments), i32(i))
		js.set_property_str(ctx, mod, d.name, f)
	}
	return api
}

// The text of the module "gt": each module of the declarations, exported from import.meta.gt, which only that module
// is given (the host's import_meta hook). No global of the realm holds the API.
module_source :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "const g = import.meta.gt;\n")
	seen := make([dynamic]string, context.temp_allocator)
	decls := DECLARATIONS
	for d in decls {
		known := false
		for s in seen { known ||= s == d.module }
		if known { continue }
		append(&seen, d.module)
		fmt.sbprintf(&b, "export const %s = g.%s;\n", d.module, d.module)
	}
	return strings.to_string(b)
}

// The JavaScript name of a declaration ("toast.show").
declaration_name :: proc(i: int, allocator := context.temp_allocator) -> string {
	decls := DECLARATIONS
	return fmt.aprintf("%s.%s", decls[i].module, decls[i].name, allocator = allocator)
}

@(private)
bridge :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	realm := (^Realm)(ctx.rt.host_data)
	decls := DECLARATIONS
	i := int(magic)
	if realm == nil || i < 0 || i >= len(decls) { return js.throw_type_error(ctx, "this call has no host") }
	d := decls[i]
	if d.capability != .None && d.capability not_in realm.granted {
		return js.throw_error(ctx, .plain, fmt.tprintf("PermissionError: %s needs the permission %v, which the person did not grant", declaration_name(i), d.capability))
	}
	impl := realm.impls[i]
	if impl == nil { return js.throw_type_error(ctx, fmt.tprintf("%s is not available in this program", declaration_name(i))) }
	ti := type_info_of(d.arguments)
	buf, _ := mem.alloc(ti.size, ti.align, context.temp_allocator)
	name := declaration_name(i)
	n := reflect.struct_field_count(d.arguments)
	for k in 0 ..< n {
		f := reflect.struct_field_at(d.arguments, k)
		v := k < len(args) ? args[k] : js.UNDEFINED
		if !fill(ctx, v, f.type, rawptr(uintptr(buf) + f.offset), name, f.name, is_optional(f.tag)) { return js.EXCEPTION }
	}
	c := Call{ctx = ctx, realm = realm, declaration = i}
	r := impl(&c, buf)
	if js.is_exception(r) { return r }
	switch d.result {
	case .Undefined:     return js.UNDEFINED
	case .Setting_Value: return r
	}
	return r
}

// A function of the plugin: Handler, Text_Handler, Flag_Handler, Render (each a distinct js.Value).
is_function_type :: proc(id: typeid) -> bool {
	return id == typeid_of(Handler) || id == typeid_of(Text_Handler) || id == typeid_of(Flag_Handler) || id == typeid_of(Render) || id == typeid_of(Setting_Handler)
}

@(private)
is_optional :: proc(tag: reflect.Struct_Tag) -> bool {
	return strings.contains(string(tag), "optional")
}

// Writes `v` as a value of type `ti` at `out`. False: a TypeError is pending, which names the call and the argument.
@(private)
fill :: proc(ctx: ^js.Context, v: js.Value, ti: ^runtime.Type_Info, out: rawptr, call, what: string, optional: bool) -> bool {
	if js.is_undefined(v) {
		if optional { return true }   // (the zero value: the buffer is zeroed)
		js.throw_type_error(ctx, fmt.tprintf("%s: %s is missing", call, what))
		return false
	}
	if ti.id == typeid_of(Children) { return true }   // (a node's children: the list's writer reads them, display.odin)
	if is_function_type(ti.id) {
		if !js.is_callable(v) { return wrong(ctx, call, what, "a function") }
		(^js.Value)(out)^ = v
		return true
	}
	base := reflect.type_info_base(ti)
	#partial switch info in base.variant {
	case runtime.Type_Info_String:
		if !js.is_string(v) { return wrong(ctx, call, what, "a string") }
		s, ok := js.to_utf8(ctx, v, context.temp_allocator)
		if !ok { return false }
		(^string)(out)^ = s
	case runtime.Type_Info_Boolean:
		if !js.is_bool(v) { return wrong(ctx, call, what, "a boolean") }
		(^bool)(out)^ = js.to_boolean(v)
	case runtime.Type_Info_Float:
		if !js.is_number(v) { return wrong(ctx, call, what, "a number") }
		n, _ := js.to_number(ctx, v)
		switch ti.size {
		case 4: (^f32)(out)^ = f32(n)
		case:   (^f64)(out)^ = n
		}
	case runtime.Type_Info_Integer:
		if !js.is_number(v) { return wrong(ctx, call, what, "a number") }
		n, _ := js.to_number(ctx, v)
		x := i64(n)
		mem.copy(out, &x, ti.size)   // (little-endian: the low bytes first)
	case runtime.Type_Info_Enum:
		if !js.is_string(v) { return wrong(ctx, call, what, "a string") }
		s, ok := js.to_utf8(ctx, v, context.temp_allocator)
		if !ok { return false }
		names := reflect.enum_field_names(ti.id)
		values := reflect.enum_field_values(ti.id)
		for n, k in names {
			if n != s { continue }
			x := i64(values[k])
			mem.copy(out, &x, ti.size)
			return true
		}
		js.throw_type_error(ctx, fmt.tprintf("%s: %s is \"%s\", not one of %v", call, what, s, names))
		return false
	case runtime.Type_Info_Struct:
		if !js.is_object(v) { return wrong(ctx, call, what, "an object") }
		js.root(ctx.rt, v)
		n := reflect.struct_field_count(ti.id)
		for k in 0 ..< n {
			f := reflect.struct_field_at(ti.id, k)
			fv := js.get_property_str(ctx, v, f.name)
			if js.is_exception(fv) { return false }
			js.root(ctx.rt, fv)   // (a getter may run a collection before the next property)
			if !fill(ctx, fv, f.type, rawptr(uintptr(out) + f.offset), call, fmt.tprintf("%s.%s", what, f.name), is_optional(f.tag)) { return false }
		}
	case:
		js.throw_type_error(ctx, fmt.tprintf("%s: %s has a type the bridge does not convert", call, what))
		return false
	}
	return true
}

@(private)
wrong :: proc(ctx: ^js.Context, call, what, wanted: string) -> bool {
	js.throw_type_error(ctx, fmt.tprintf("%s: %s must be %s", call, what, wanted))
	return false
}
