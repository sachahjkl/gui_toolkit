package tk_plugin_api

// A program's own module, `import { ... } from "app"` (plugins.md, "As built: a program's own module"): the program
// declares its calls and events with structs (typeids), as the module "gt" is declared; the same reflection fills an
// argument from JavaScript (fill), carries it across the pipe (value_encode) and makes a result a plain object
// (value_to_js). Its `run` procedures stay in the program: the plugin's process knows the names and the typeids, which
// name the same types there (it is the program's own executable).

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import js "../js"

// The name a plugin imports the program's module by.
APP_MODULE :: "app"

// A call of the program's that is waited for: what `App_Run` gives back to the host. Its value names the call until
// it is answered (plugins.app_answer, plugins.app_fail).
App_Token :: distinct u64

// A call's work, on the program's interface thread, in the request's event: `args` points to the call's argument
// struct, filled (its strings live through the call only: copy what is kept), `result` to its result struct, zeroed,
// which `run` fills. `pending`: the answer comes later, by the token (the program keeps it). `error` not "": the call
// fails with these words (the plugin's promise rejects with an Error of them).
App_Run :: #type proc(user: rawptr, token: App_Token, args: rawptr, result: rawptr) -> (pending: bool, error: string)

// A call of the module: "<group>.<call>" ("notes.list", `import { notes } from "app"`), its argument and result
// structs, the permission it needs ("": none; a word of App_Module.permissions), a line for its docs, its work.
App_Call :: struct {
	name:       string,
	arguments:  typeid,
	result:     typeid,
	permission: string,
	doc:        string,
	run:        App_Run,
}

// An event of the module: its name ("note.added": `app.on("note.added", f)`), its payload struct, the permission a
// plugin needs to hear it ("": none), a line for its docs.
App_Event :: struct {
	name:       string,
	payload:    typeid,
	permission: string,
	doc:        string,
}

// A permission of the module: its word, which starts with "app:" ("app:notes.write"), and what it lets a plugin do in
// the program's words, for the grant dialog ("Add notes").
App_Permission :: struct {
	word:  string,
	words: string,
}

// A program's module. `name` is the program's (its docs say "<name>'s module"); `level` its own, which a manifest's
// "app" asks for; `user` goes to each call's `run`. The program keeps it, unchanged, while its host is open.
App_Module :: struct {
	name:        string,
	level:       int,
	calls:       []App_Call,
	events:      []App_Event,
	permissions: []App_Permission,
	user:        rawptr,
}

// What the plugin's process knows of a call or an event: its name and its types (the start frame carries them).
App_Spec :: struct {
	name:     string,
	types:    [2]typeid,   // a call's argument and result; an event's payload (and nil)
}

// Why a module's declaration is wrong ("": it is right): a name that is not "<group>.<call>", a group "on" (the
// module's own `on`), a type the bridge does not carry, a permission it does not declare. The program's bug: host_open
// asserts on it.
app_module_check :: proc(m: ^App_Module) -> string {
	if m.name == "" { return "the module has no name (the program's)" }
	if m.level < 1 { return fmt.tprintf("the module's level is %d: it starts at 1", m.level) }
	for p in m.permissions {
		if !strings.has_prefix(p.word, "app:") || !word_valid(p.word[len("app:"):], true) { return fmt.tprintf("the permission \"%s\" is not app:<words>", p.word) }
		if p.words == "" { return fmt.tprintf("the permission \"%s\" has no words for the grant dialog", p.word) }
	}
	for c, i in m.calls {
		dot := strings.index_byte(c.name, '.')
		if dot <= 0 || !word_valid(c.name[:dot], false) || !word_valid(c.name[dot + 1:], false) { return fmt.tprintf("the call \"%s\" is not <group>.<call>", c.name) }
		if c.name[:dot] == "on" { return fmt.tprintf("the call \"%s\": the group \"on\" is the module's own app.on", c.name) }
		if c.run == nil { return fmt.tprintf("the call \"%s\" has no run", c.name) }
		for t, k in ([2]typeid{c.arguments, c.result}) {
			if t == nil { return fmt.tprintf("the call \"%s\" has no %s type", c.name, k == 0 ? "argument" : "result") }
			if why := type_carried(type_info_of(t)); why != "" { return fmt.tprintf("the call \"%s\"'s %s: %s", c.name, k == 0 ? "argument" : "result", why) }
			if !reflect.is_struct(reflect.type_info_base(type_info_of(t))) { return fmt.tprintf("the call \"%s\"'s %s is not a struct", c.name, k == 0 ? "argument" : "result") }
		}
		if why := permission_declared(m, c.permission); why != "" { return fmt.tprintf("the call \"%s\": %s", c.name, why) }
		for o in m.calls[:i] { if o.name == c.name { return fmt.tprintf("the call \"%s\" is declared twice", c.name) } }
	}
	for e, i in m.events {
		if !word_valid(e.name, true) { return fmt.tprintf("the event \"%s\" is not a name (letters, digits, '.', '_', '-')", e.name) }
		if e.payload == nil { return fmt.tprintf("the event \"%s\" has no payload type", e.name) }
		if why := type_carried(type_info_of(e.payload)); why != "" { return fmt.tprintf("the event \"%s\"'s payload: %s", e.name, why) }
		if !reflect.is_struct(reflect.type_info_base(type_info_of(e.payload))) { return fmt.tprintf("the event \"%s\"'s payload is not a struct", e.name) }
		if why := permission_declared(m, e.permission); why != "" { return fmt.tprintf("the event \"%s\": %s", e.name, why) }
		for o in m.events[:i] { if o.name == e.name { return fmt.tprintf("the event \"%s\" is declared twice", e.name) } }
	}
	return ""
}

// The call `name` of the module (-1: none).
app_call_index :: proc(m: ^App_Module, name: string) -> int {
	for c, i in m.calls { if c.name == name { return i } }
	return -1
}

// The event `name` of the module (-1: none).
app_event_index :: proc(m: ^App_Module, name: string) -> int {
	for e, i in m.events { if e.name == name { return i } }
	return -1
}

// A permission word's words for the grant dialog ("": the module does not declare it).
app_permission_words :: proc(m: ^App_Module, word: string) -> string {
	if m == nil { return "" }
	for p in m.permissions { if p.word == word { return p.words } }
	return ""
}

@(private = "file")
permission_declared :: proc(m: ^App_Module, word: string) -> string {
	if word == "" || app_permission_words(m, word) != "" { return "" }
	return fmt.tprintf("its permission \"%s\" is not one of the module's", word)
}

// Letters, digits and '_' ('.' and '-' too with `dotted`): a name JavaScript and a manifest both read.
@(private = "file")
word_valid :: proc(s: string, dotted: bool) -> bool {
	if s == "" { return false }
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		case '.', '-': if !dotted { return false }
		case: return false
		}
	}
	return true
}

// Why a type is not one the bridge carries ("": it is): strings, booleans, numbers, enums, structs and slices of them.
@(private = "file")
type_carried :: proc(ti: ^runtime.Type_Info, depth := 0) -> string {
	if ti == nil { return "no type" }
	if depth > 16 { return "a type nested more than 16 deep" }
	#partial switch info in reflect.type_info_base(ti).variant {
	case runtime.Type_Info_String, runtime.Type_Info_Boolean, runtime.Type_Info_Float, runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		return ""
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(info.field_count) {
			if why := type_carried(info.types[k], depth + 1); why != "" { return fmt.tprintf("%s: %s", info.names[k], why) }
		}
		return ""
	case runtime.Type_Info_Slice:
		if info.elem_size == 0 { return "a slice of an empty struct" }
		return type_carried(info.elem, depth + 1)
	}
	return fmt.tprintf("%v is not a string, a boolean, a number, an enum, a struct or a slice", ti.id)
}

// Whether a typeid read from the start frame is one this executable has (the program's own: it always is, unless the
// frame is not the program's).
typeid_known :: proc(id: typeid) -> bool {
	ti := type_info_of(id)
	return ti != nil && ti.id == id
}

////////////////////////////////
// In the plugin's process: the module's object, its calls through one native function, as the module "gt"'s

// The host's side of a call of the module (the plugin's process): `index` is its place in Realm.app_calls, `args` its
// argument struct, filled. It returns the call's promise, or js.EXCEPTION with an exception pending.
App_Impl :: #type proc(c: ^Call, index: int, args: rawptr) -> js.Value

// The object of the module "app": an object per group with its calls, and `on`, the host's (`on_fn`). `realm.app_calls`
// must be set; `ctx.rt.host_data` must be `realm` before a call.
app_install :: proc(ctx: ^js.Context, realm: ^Realm, on_fn: js.Native_Proc) -> js.Value {
	o := js.new_object(ctx)
	for c, i in realm.app_calls {
		dot := strings.index_byte(c.name, '.')
		group, name := c.name[:dot], c.name[dot + 1:]
		g := js.get_property_str(ctx, o, group)
		if js.is_undefined(g) {
			g = js.new_object(ctx)
			js.set_property_str(ctx, o, group, g)
		}
		js.set_property_str(ctx, g, name, js.new_function(ctx, app_bridge, name, 1, i32(i)))
	}
	js.set_property_str(ctx, o, "on", js.new_function(ctx, on_fn, "on", 2))
	return o
}

// The text of the module "app": `on` and each group, exported from import.meta.app (the host's import_meta hook).
app_module_source :: proc(realm: ^Realm, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "const a = import.meta.app;\nexport const on = a.on;\n")
	seen := make([dynamic]string, context.temp_allocator)
	for c in realm.app_calls {
		group := c.name[:strings.index_byte(c.name, '.')]
		known := false
		for s in seen { known ||= s == group }
		if known { continue }
		append(&seen, group)
		fmt.sbprintf(&b, "export const %s = a.%s;\n", group, group)
	}
	return strings.to_string(b)
}

// Every call of the module: its one argument object filled by reflection into its struct, then the host's App_Impl
// (which sends it to the program and gives a promise). No argument: each field as absent (a struct of optional fields).
@(private)
app_bridge :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	realm := (^Realm)(ctx.rt.host_data)
	i := int(magic)
	if realm == nil || realm.app_impl == nil || i < 0 || i >= len(realm.app_calls) { return js.throw_type_error(ctx, "this call has no host") }
	spec := realm.app_calls[i]
	ti := type_info_of(spec.types[0])
	buf, _ := mem.alloc(max(ti.size, 1), max(ti.align, 1), context.temp_allocator)
	what := fmt.tprintf("%s.%s", APP_MODULE, spec.name)
	v := len(args) > 0 ? args[0] : js.UNDEFINED
	if js.is_undefined(v) {
		for k in 0 ..< reflect.struct_field_count(spec.types[0]) {
			f := reflect.struct_field_at(spec.types[0], k)
			if !fill(ctx, js.UNDEFINED, f.type, rawptr(uintptr(buf) + f.offset), what, f.name, is_optional(f.tag)) { return js.EXCEPTION }
		}
	} else if !fill(ctx, v, ti, buf, what, "its argument", false) {
		return js.EXCEPTION
	}
	c := Call{ctx = ctx, realm = realm, declaration = -1}
	return realm.app_impl(&c, i, buf)
}
