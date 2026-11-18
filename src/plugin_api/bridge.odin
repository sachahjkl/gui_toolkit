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

Capabilities :: bit_set[Capability; u8]   // (a byte: the program sends it to the plugin's process)

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
	// the program's module "app" (app.odin): its calls as the start frame named them, and the host's side of each
	app_calls: []App_Spec,
	app_impl:  App_Impl,
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
		e := permission_error(ctx, fmt.tprintf("%s needs the permission %v, which the person did not grant", declaration_name(i), d.capability))
		// (a call that answers later rejects, as its answer would: a plugin awaits it in one place)
		if is_promise_result(d.result) { return promise_rejected(ctx, e) }
		return js.throw(ctx, e)
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
	case .Undefined: return js.UNDEFINED
	case .Setting_Value, .Promise_Text, .Promise_Void, .Promise_Path, .Promise_Response: return r
	}
	return r
}

// A result that is a promise: the program's broker answers it later.
is_promise_result :: proc(r: Result) -> bool {
	#partial switch r {
	case .Promise_Text, .Promise_Void, .Promise_Path, .Promise_Response: return true
	}
	return false
}

// An Error whose name is PermissionError: a call without its grant.
permission_error :: proc(ctx: ^js.Context, message: string) -> js.Value {
	return named_error(ctx, "PermissionError", message)
}

// An Error of `name` ("PermissionError", "NetworkError"), with its message.
named_error :: proc(ctx: ^js.Context, name, message: string) -> js.Value {
	js.throw_error(ctx, .plain, message)
	e := js.pending_exception(ctx)
	js.root(ctx.rt, e)
	js.set_property_str(ctx, e, "name", js.new_string(ctx, name))
	return e
}

// A new promise and its resolving functions (ok false: an exception is pending).
promise_new :: proc(ctx: ^js.Context) -> (js.Capability, bool) {
	return js.new_promise_capability(ctx, js.mk_obj(ctx.promise_ctor))
}

// A promise already rejected with `reason`.
promise_rejected :: proc(ctx: ^js.Context, reason: js.Value) -> js.Value {
	c, ok := promise_new(ctx)
	if !ok { return js.EXCEPTION }
	js.root(ctx.rt, c.promise)
	_ = js.call_function(ctx, c.reject, js.UNDEFINED, {reason})
	return c.promise
}

// A function of the plugin: Handler, Text_Handler, Flag_Handler, Render (each a distinct js.Value).
is_function_type :: proc(id: typeid) -> bool {
	return id == typeid_of(Handler) || id == typeid_of(Text_Handler) || id == typeid_of(Flag_Handler) || id == typeid_of(Render) || id == typeid_of(Setting_Handler) || id == typeid_of(Row_Render) || id == typeid_of(Palette_Search) || id == typeid_of(Palette_Choose_Handler)
}

@(private)
is_optional :: proc(tag: reflect.Struct_Tag) -> bool {
	return strings.contains(string(tag), "optional")
}

// A JavaScript value as a value of type `ti` at `out` (zeroed by the caller), by the bridge's own reflection: what a
// plugin returns to the host (a palette source's rows). `what` names it in the TypeError that is pending when false.
value_from_js :: proc(ctx: ^js.Context, v: js.Value, ti: ^runtime.Type_Info, out: rawptr, what: string) -> bool {
	return fill(ctx, v, ti, out, what, "its value", false)
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
	if ti.id == typeid_of(Words) { return fill_words(ctx, v, (^Words)(out), call, what) }
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
	case runtime.Type_Info_Slice:
		// (an array: its elements in the temporary memory, as the struct they fill; a program's call's argument)
		if !js.is_object(v) { return wrong(ctx, call, what, "an array") }
		js.root(ctx.rt, v)
		length_v := js.get_property_str(ctx, v, "length")
		if js.is_exception(length_v) { return false }
		if !js.is_number(length_v) { return wrong(ctx, call, what, "an array") }
		n, _ := js.to_number(ctx, length_v)
		count := int(clamp(n, 0, f64(SLICE_MAX_ITEMS)))
		if count == 0 { return true }
		data, _ := mem.alloc(count * info.elem_size, info.elem.align, context.temp_allocator)
		for k in 0 ..< count {
			item := js.get_property_str(ctx, v, fmt.tprintf("%d", k))
			if js.is_exception(item) { return false }
			js.root(ctx.rt, item)
			if !fill(ctx, item, info.elem, rawptr(uintptr(data) + uintptr(k * info.elem_size)), call, fmt.tprintf("%s[%d]", what, k), false) { return false }
		}
		(^runtime.Raw_Slice)(out)^ = {data = data, len = count}
	case:
		js.throw_type_error(ctx, fmt.tprintf("%s: %s has a type the bridge does not convert", call, what))
		return false
	}
	return true
}

// The most items an array argument fills: past them the rest is not read.
SLICE_MAX_ITEMS :: 100_000

// The words of a string, or of an array of strings (`string | string[]`), as one string: each word after a
// WORDS_SEPARATOR, the empty ones left out. One string, so that the display list and the wire carry it as any field.
WORDS_SEPARATOR :: "\x1f"
WORDS_MAX :: 64

@(private)
fill_words :: proc(ctx: ^js.Context, v: js.Value, out: ^Words, call, what: string) -> bool {
	if js.is_string(v) {
		s, ok := js.to_utf8(ctx, v, context.temp_allocator)
		if !ok { return false }
		out^ = Words(s)
		return true
	}
	if !js.is_object(v) { return wrong(ctx, call, what, "a string or an array of strings") }
	js.root(ctx.rt, v)
	length_v := js.get_property_str(ctx, v, "length")
	if js.is_exception(length_v) { return false }
	n, _ := js.to_number(ctx, length_v)
	b := strings.builder_make(context.temp_allocator)
	for k in 0 ..< min(int(max(n, 0)), WORDS_MAX) {
		item := js.get_property_str(ctx, v, fmt.tprintf("%d", k))
		if js.is_exception(item) { return false }
		if !js.is_string(item) { return wrong(ctx, call, fmt.tprintf("%s[%d]", what, k), "a string") }
		s, ok := js.to_utf8(ctx, item, context.temp_allocator)
		if !ok { return false }
		if s == "" { continue }
		if strings.builder_len(b) > 0 { strings.write_string(&b, WORDS_SEPARATOR) }
		strings.write_string(&b, s)
	}
	out^ = Words(strings.to_string(b))
	return true
}

@(private)
wrong :: proc(ctx: ^js.Context, call, what, wanted: string) -> bool {
	js.throw_type_error(ctx, fmt.tprintf("%s: %s must be %s", call, what, wanted))
	return false
}
