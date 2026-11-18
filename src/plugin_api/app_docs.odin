package tk_plugin_api

// What a plugin's author reads of a program's module "app" (plugins.md, "As built: a program's own module"): its
// `app.d.ts` and its reference page, made from the declaration by reflection. The pieces are the ones `tk plugin_api`
// writes the module "gt" with (plugin_api/dts). A field's doc is its tag's `doc:"…"`; a call's and an event's are
// their declaration's. A program's tool writes both files (toolbox.generated_files).

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"
import dts "dts"

// The declarations of the module "app" for TypeScript: `declare module "app"` with its types, a const per group and
// an `on` per event. Temp memory.
app_module_dts :: proc(m: ^App_Module) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "// The module \"app\" of %s, level %d. Made from its declaration by plugin_api.app_module_dts: do not edit.\n", m.name, m.level)
	strings.write_string(&b, "declare module \"app\" {\n")
	for ti in app_types(m) {
		name := type_name(ti)
		#partial switch info in reflect.type_info_base(ti).variant {
		case runtime.Type_Info_Enum:
			fmt.sbprintf(&b, "\texport type %s =", name)
			for n, i in reflect.enum_field_names(ti.id) { fmt.sbprintf(&b, "%s \"%s\"", i == 0 ? "" : " |", n) }
			strings.write_string(&b, ";\n\n")
		case runtime.Type_Info_Struct:
			fmt.sbprintf(&b, "\texport interface %s {{\n", name)
			for k in 0 ..< int(info.field_count) {
				dts.doc(&b, "\t\t", tag_doc(info.tags[k]))
				fmt.sbprintf(&b, "\t\t%s%s: %s;\n", info.names[k], tag_optional(info.tags[k]) ? "?" : "", type_ts(info.types[k]))
			}
			strings.write_string(&b, "\t}\n\n")
		}
	}
	for group in app_groups(m) {
		fmt.sbprintf(&b, "\texport const %s: {{\n", group)
		for c in m.calls {
			if !strings.has_prefix(c.name, group) || c.name[len(group)] != '.' { continue }
			dts.doc(&b, "\t\t", call_doc(c))
			args := type_info_of(c.arguments)
			fmt.sbprintf(&b, "\t\t%s(args%s: %s): Promise<%s>;\n", c.name[len(group) + 1:], all_optional(args) ? "?" : "", type_ts(args), type_ts(type_info_of(c.result)))
		}
		strings.write_string(&b, "\t};\n\n")
	}
	for e in m.events {
		dts.doc(&b, "\t", event_doc(e))
		fmt.sbprintf(&b, "\texport function on(event: \"%s\", handler: (payload: %s) => void | Promise<void>): void;\n", e.name, type_ts(type_info_of(e.payload)))
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// The reference page of the module "app": its calls, its events, its permissions and its types. Temp memory.
app_module_markdown :: proc(m: ^App_Module) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# The module \"app\" of %s\n\n", m.name)
	fmt.sbprintf(&b, "Level %d. A plugin imports it as `import { ... } from \"app\"`, and says `\"app\": %d` in its manifest when it needs this level. Made from %s's declaration by `plugin_api.app_module_markdown`: do not edit.\n\n", m.level, m.level, m.name)
	strings.write_string(&b, "Every call takes one object and returns a promise. A call without its grant rejects with `PermissionError`.\n")
	if len(m.calls) > 0 { strings.write_string(&b, "\n## Calls\n") }
	for c in m.calls {
		args := type_info_of(c.arguments)
		fmt.sbprintf(&b, "\n### `%s(args%s)`\n\n", c.name, all_optional(args) ? "?" : "")
		if c.doc != "" { fmt.sbprintf(&b, "%s\n\n", c.doc) }
		fmt.sbprintf(&b, "Permission: %s. Its argument: `%s`. Its result: `%s`.\n", c.permission == "" ? "none" : fmt.tprintf("`%s`", c.permission), type_ts(args), type_ts(type_info_of(c.result)))
	}
	if len(m.events) > 0 { strings.write_string(&b, "\n## Events\n") }
	for e in m.events {
		fmt.sbprintf(&b, "\n### `%s`\n\n", e.name)
		if e.doc != "" { fmt.sbprintf(&b, "%s\n\n", e.doc) }
		fmt.sbprintf(&b, "`app.on(\"%s\", (payload) => ...)`. Permission: %s. Its payload: `%s`.\n", e.name, e.permission == "" ? "none" : fmt.tprintf("`%s`", e.permission), type_ts(type_info_of(e.payload)))
	}
	if len(m.permissions) > 0 {
		strings.write_string(&b, "\n## Permissions\n\nA word of the manifest's `permissions`, and what the grant dialog says of it.\n\n| Word | |\n|---|---|\n")
		for p in m.permissions { fmt.sbprintf(&b, "| `%s` | %s |\n", p.word, dts.cell(p.words)) }
	}
	types := app_types(m)
	if len(types) > 0 { strings.write_string(&b, "\n## Types\n") }
	for ti in types {
		fmt.sbprintf(&b, "\n### `%s`\n\n", type_name(ti))
		#partial switch info in reflect.type_info_base(ti).variant {
		case runtime.Type_Info_Enum:
			quoted := make([dynamic]string, context.temp_allocator)
			for n in reflect.enum_field_names(ti.id) { append(&quoted, fmt.tprintf("`\"%s\"`", n)) }
			fmt.sbprintf(&b, "One of %s.\n", strings.join(quoted[:], ", ", context.temp_allocator))
		case runtime.Type_Info_Struct:
			if info.field_count == 0 { strings.write_string(&b, "No field.\n"); continue }
			dts.field_head(&b, "Field")
			for k in 0 ..< int(info.field_count) { dts.field_row(&b, info.names[k], type_ts(info.types[k]), tag_optional(info.tags[k]), tag_doc(info.tags[k])) }
		}
	}
	return strings.to_string(b)
}

// The named structs and enums the module's calls and events reach, each once, in the order they are first met (each
// call's argument then its result, then each event's payload; a struct before the types of its fields).
@(private = "file")
app_types :: proc(m: ^App_Module) -> []^runtime.Type_Info {
	out := make([dynamic]^runtime.Type_Info, context.temp_allocator)
	visit :: proc(out: ^[dynamic]^runtime.Type_Info, ti: ^runtime.Type_Info) {
		#partial switch info in reflect.type_info_base(ti).variant {
		case runtime.Type_Info_Slice:
			visit(out, info.elem)
		case runtime.Type_Info_Enum, runtime.Type_Info_Struct:
			if _, named := ti.variant.(runtime.Type_Info_Named); !named { return }
			for t in out { if t.id == ti.id { return } }
			append(out, ti)
			if s, is_struct := info.(runtime.Type_Info_Struct); is_struct {
				for k in 0 ..< int(s.field_count) { visit(out, s.types[k]) }
			}
		}
	}
	for c in m.calls {
		visit(&out, type_info_of(c.arguments))
		visit(&out, type_info_of(c.result))
	}
	for e in m.events { visit(&out, type_info_of(e.payload)) }
	return out[:]
}

// The groups of the calls ("notes"), in the order of their first call.
@(private = "file")
app_groups :: proc(m: ^App_Module) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for c in m.calls {
		g := c.name[:strings.index_byte(c.name, '.')]
		known := false
		for o in out { known ||= o == g }
		if !known { append(&out, g) }
	}
	return out[:]
}

// A type as TypeScript writes it: a named struct or enum by its name, a slice as `T[]`, a primitive as dts says.
@(private = "file")
type_ts :: proc(ti: ^runtime.Type_Info) -> string {
	#partial switch info in reflect.type_info_base(ti).variant {
	case runtime.Type_Info_Slice:
		return fmt.tprintf("%s[]", type_ts(info.elem))
	case runtime.Type_Info_Struct, runtime.Type_Info_Enum:
		if _, named := ti.variant.(runtime.Type_Info_Named); named { return type_name(ti) }
		return "unknown"
	}
	// (a primitive, or a distinct one: its base's name, "string", "int", "f64")
	ts, ok := dts.primitive(fmt.tprint(reflect.type_info_base(ti).id))
	return ok ? ts : "unknown"
}

@(private = "file")
type_name :: proc(ti: ^runtime.Type_Info) -> string {
	if n, named := ti.variant.(runtime.Type_Info_Named); named { return n.name }
	return fmt.tprint(ti.id)
}

// Whether every field of a struct is optional: its call may be made with no argument.
@(private = "file")
all_optional :: proc(ti: ^runtime.Type_Info) -> bool {
	s, ok := reflect.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	if !ok { return false }
	for k in 0 ..< int(s.field_count) { if !tag_optional(s.tags[k]) { return false } }
	return true
}

@(private = "file")
tag_optional :: proc(tag: string) -> bool { return strings.contains(tag, "optional") }

// A field's doc: its tag's `doc:"…"` ("": none).
@(private = "file")
tag_doc :: proc(tag: string) -> string {
	at := strings.index(tag, `doc:"`)
	if at < 0 { return "" }
	rest := tag[at + len(`doc:"`):]
	end := strings.index_byte(rest, '"')
	return end < 0 ? rest : rest[:end]
}

@(private = "file")
call_doc :: proc(c: App_Call) -> string {
	if c.permission == "" { return c.doc }
	return strings.trim_space(fmt.tprintf("%s (needs the permission %s)", c.doc, c.permission))
}

@(private = "file")
event_doc :: proc(e: App_Event) -> string {
	if e.permission == "" { return e.doc }
	return strings.trim_space(fmt.tprintf("%s (heard with the permission %s)", e.doc, e.permission))
}
