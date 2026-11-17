package tk

// plugin_api [-check]: what a plugin's author and the site's explorer read, made from the declarations of
// src/plugin_api/api.odin (src/md/features/plugins.md, decision 3): plugin-api/gt.d.ts, the snapshot of the current
// level (plugin-api/level-<n>.d.ts), plugin-api/api.json (the explorer's), and docs/plugin-api.md. -check writes
// nothing and fails when a committed file differs from what the declarations make; each snapshot from
// PLUGIN_API_OLDEST on must still be what the declarations of its level make (a level only adds).

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import tk_json "../../src/json"
import toolbox "../../src/toolbox"

PLUGIN_API_SOURCE :: "src/plugin_api/api.odin"
PLUGIN_API_DIR :: "plugin-api"
PLUGIN_API_PAGE :: "docs/plugin-api.md"

@(private = "file")
Api_Field :: struct { name, type, doc: string, optional: bool }

@(private = "file")
Api_Type :: struct {
	name, doc: string,
	is_enum:   bool,
	fields:    [dynamic]Api_Field,   // a struct's
	values:    [dynamic]string,      // an enum's names
}

@(private = "file")
Api_Call :: struct { module, name, arguments, result, capability: string, level: int }

@(private = "file")
Api :: struct {
	level, oldest: int,
	types: [dynamic]Api_Type,   // in the file's order
	calls: [dynamic]Api_Call,
}

run_plugin_api :: proc(args: []string) -> string {
	check := toolbox.has_flag(args, "check")
	root := toolkit_root()
	files, why := plugin_api_files(root)
	if why != "" { return why }
	differ := make([dynamic]string, context.temp_allocator)
	for f in files {
		path := join({root, f[0]})
		have, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil && string(have) == f[1] { continue }
		if check {
			append(&differ, f[0])
			continue
		}
		if dir := path_dir(path); dir != "" { _ = os.make_directory_all(dir) }
		if os.write_entire_file(path, transmute([]u8)f[1]) != nil { return fmt.tprintf("cannot write %s", path) }
		fmt.printfln("wrote %s", f[0])
	}
	if len(differ) > 0 {
		return fmt.tprintf("not what the declarations make (odin run tools/tk -- plugin_api): %s", strings.join(differ[:], ", ", context.temp_allocator))
	}
	if check { fmt.println("plugin_api ok") }
	return ""
}

// Each file and its text: [path from the root, text]. The snapshots of the levels before the current one are checked,
// not written: they are what was promised.
plugin_api_files :: proc(root: string) -> (files: [][2]string, why: string) {
	api: Api
	api, why = api_read(join({root, PLUGIN_API_SOURCE}))
	if why != "" { return }
	out := make([dynamic][2]string, context.temp_allocator)
	append(&out, [2]string{PLUGIN_API_DIR + "/gt.d.ts", api_dts(api, api.level)})
	for l in api.oldest ..= api.level {
		append(&out, [2]string{fmt.tprintf("%s/level-%d.d.ts", PLUGIN_API_DIR, l), api_dts(api, l)})
	}
	append(&out, [2]string{PLUGIN_API_DIR + "/api.json", api_json(api)})
	append(&out, [2]string{PLUGIN_API_PAGE, api_page(api)})
	return out[:], ""
}

@(private = "file")
path_dir :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return i > 0 ? path[:i] : ""
}

////////////////////////////////
// Reading the declarations

@(private = "file")
api_read :: proc(path: string) -> (api: Api, why: string) {
	// (the package whole, as the parser reads one: only the declarations' file is looked at)
	pkg, parsed := parser.parse_package_from_path(path_dir(path))
	if !parsed || pkg == nil { return {}, fmt.tprintf("%s does not parse", path_dir(path)) }
	file: ^ast.File
	for _, f in pkg.files {
		if strings.has_suffix(f.fullpath, "api.odin") && !strings.has_suffix(f.fullpath, "_api.odin") { file = f }
	}
	if file == nil { return {}, fmt.tprintf("cannot read %s", path) }
	api.level, api.oldest = -1, -1
	for decl in file.decls {
		vd, is := decl.derived.(^ast.Value_Decl)
		if !is || len(vd.names) != 1 || len(vd.values) != 1 { continue }
		name := ident_name(vd.names[0])
		doc := doc_text(vd.docs)
		#partial switch v in vd.values[0].derived {
		case ^ast.Basic_Lit:
			n, ok := strconv.parse_int(v.tok.text)
			if !ok { continue }
			switch name {
			case "PLUGIN_API_LEVEL":  api.level = n
			case "PLUGIN_API_OLDEST": api.oldest = n
			}
		case ^ast.Struct_Type:
			t := Api_Type{name = name, doc = doc}
			if v.fields != nil {
				for f in v.fields.list {
					tag := f.tag.text
					for n in f.names {
						append(&t.fields, Api_Field{name = ident_name(n), type = type_text(f.type), doc = doc_text(f.docs), optional = strings.contains(tag, "optional")})
					}
				}
			}
			append(&api.types, t)
		case ^ast.Enum_Type:
			t := Api_Type{name = name, doc = doc, is_enum = true}
			for f in v.fields { append(&t.values, ident_name(f)) }
			append(&api.types, t)
		case ^ast.Distinct_Type:
			// (Handler: a function of the plugin, written as its type in TypeScript)
		case ^ast.Comp_Lit:
			if name != "DECLARATIONS" { continue }
			for e in v.elems {
				entry, is_lit := e.derived.(^ast.Comp_Lit)
				if !is_lit { continue }
				c: Api_Call
				for fe in entry.elems {
					fv, is_fv := fe.derived.(^ast.Field_Value)
					if !is_fv { continue }
					value := expr_text(fv.value)
					switch ident_name(fv.field) {
					case "module":     c.module = value
					case "name":       c.name = value
					case "arguments":  c.arguments = value
					case "result":     c.result = value
					case "capability": c.capability = value
					case "level":      c.level, _ = strconv.parse_int(value)
					}
				}
				append(&api.calls, c)
			}
		}
	}
	if api.level < 1 || api.oldest < 1 || api.oldest > api.level { return {}, fmt.tprintf("%s: PLUGIN_API_LEVEL and PLUGIN_API_OLDEST are not two levels", path) }
	if len(api.calls) == 0 { return {}, fmt.tprintf("%s: no DECLARATIONS", path) }
	for c in api.calls {
		if _, known := type_of_name(api, c.arguments); !known { return {}, fmt.tprintf("%s: %s.%s's arguments %s is not a struct of the file", path, c.module, c.name, c.arguments) }
		if c.level < 1 || c.level > api.level { return {}, fmt.tprintf("%s: %s.%s has level %d", path, c.module, c.name, c.level) }
	}
	api_keep_reachable(&api)
	return api, ""
}

// Only what a plugin can meet goes out: the calls' arguments, `activate`'s context, and every type their fields name.
// The file also holds the bridge's own vocabulary (Declaration, its Capability and Result), which no plugin sees.
@(private = "file")
api_keep_reachable :: proc(api: ^Api) {
	seen := make(map[string]bool, context.temp_allocator)
	todo := make([dynamic]string, context.temp_allocator)
	append(&todo, "Activate_Context")
	for c in api.calls { append(&todo, c.arguments) }
	for len(todo) > 0 {
		name := pop(&todo)
		if name in seen { continue }
		t, known := type_of_name(api^, name)
		if !known { continue }
		seen[name] = true
		for f in t.fields {
			for other in api.types {
				if other.name not_in seen && type_names(f.type, other.name) { append(&todo, other.name) }
			}
		}
	}
	kept := make([dynamic]Api_Type)
	for t in api.types { if t.name in seen { append(&kept, t) } }
	delete(api.types)
	api.types = kept
}

// Whether the field's type text names `name` as a whole word ("Maybe(Toast_Kind)", "[]Toast_Kind").
@(private = "file")
type_names :: proc(text, name: string) -> bool {
	word :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }
	for i := strings.index(text, name); i >= 0; {
		end := i + len(name)
		if (i == 0 || !word(text[i - 1])) && (end == len(text) || !word(text[end])) { return true }
		next := strings.index(text[i + 1:], name)
		if next < 0 { break }
		i += 1 + next
	}
	return false
}

@(private = "file")
ident_name :: proc(e: ^ast.Expr) -> string {
	if id, is := e.derived.(^ast.Ident); is { return id.name }
	return ""
}

// An expression as the file writes it, quotes and the leading dot of an enum's value left out.
@(private = "file")
expr_text :: proc(e: ^ast.Expr) -> string {
	#partial switch v in e.derived {
	case ^ast.Basic_Lit:
		t := v.tok.text
		if len(t) >= 2 && (t[0] == '"' || t[0] == '`') { return t[1:len(t) - 1] }
		return t
	case ^ast.Ident:
		return v.name
	case ^ast.Implicit_Selector_Expr:
		return v.field.name
	}
	return ""
}

@(private = "file")
type_text :: proc(e: ^ast.Expr) -> string {
	#partial switch v in e.derived {
	case ^ast.Ident:          return v.name
	case ^ast.Selector_Expr:  return v.field.name
	}
	return "?"
}

// A comment group as text: the lines without their "//", joined with spaces.
@(private = "file")
doc_text :: proc(g: ^ast.Comment_Group) -> string {
	if g == nil { return "" }
	b := strings.builder_make(context.temp_allocator)
	for tok in g.list {
		line := strings.trim_space(strings.trim_prefix(tok.text, "//"))
		if line == "" { continue }
		if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}

@(private = "file")
type_of_name :: proc(api: Api, name: string) -> (Api_Type, bool) {
	for t in api.types { if t.name == name { return t, true } }
	return {}, false
}

// The argument structs are the calls' parameters, not types of their own.
@(private = "file")
is_arguments :: proc(api: Api, name: string) -> bool {
	for c in api.calls { if c.arguments == name { return true } }
	return false
}

////////////////////////////////
// TypeScript

@(private = "file")
ts_type :: proc(odin_type: string) -> string {
	switch odin_type {
	case "string":                          return "string"
	case "f64", "f32", "int", "i64", "i32": return "number"
	case "bool":                            return "boolean"
	case "Handler":                         return "() => void | Promise<void>"
	}
	return odin_type
}

@(private = "file")
ts_doc :: proc(b: ^strings.Builder, indent, doc: string) {
	if doc != "" { fmt.sbprintf(b, "%s/** %s */\n", indent, doc) }
}

// The module "gt" at level `level`: the calls of that level and before, and every type they name.
@(private = "file")
api_dts :: proc(api: Api, level: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "// The module \"gt\" of a plugin, level %d. Made by `odin run tools/tk -- plugin_api` from %s: do not edit.\n", level, PLUGIN_API_SOURCE)
	strings.write_string(&b, "declare module \"gt\" {\n")
	for t in api.types {
		if is_arguments(api, t.name) { continue }
		ts_doc(&b, "\t", t.doc)
		if t.is_enum {
			fmt.sbprintf(&b, "\texport type %s =", t.name)
			for v, i in t.values { fmt.sbprintf(&b, "%s \"%s\"", i == 0 ? "" : " |", v) }
			strings.write_string(&b, ";\n\n")
			continue
		}
		fmt.sbprintf(&b, "\texport interface %s {{\n", t.name)
		for f in t.fields {
			ts_doc(&b, "\t\t", f.doc)
			fmt.sbprintf(&b, "\t\t%s%s: %s;\n", f.name, f.optional ? "?" : "", ts_type(f.type))
		}
		strings.write_string(&b, "\t}\n\n")
	}
	for m in api_modules(api) {
		fmt.sbprintf(&b, "\texport const %s: {{\n", m)
		for c in api.calls {
			if c.module != m || c.level > level { continue }
			t, _ := type_of_name(api, c.arguments)
			ts_doc(&b, "\t\t", fmt.tprintf("%s (level %d%s)", t.doc, c.level, c.capability != "None" ? fmt.tprintf(", needs %s", c.capability) : ""))
			fmt.sbprintf(&b, "\t\t%s(", c.name)
			for f, i in t.fields {
				fmt.sbprintf(&b, "%s%s%s: %s", i == 0 ? "" : ", ", f.name, f.optional ? "?" : "", ts_type(f.type))
			}
			fmt.sbprintf(&b, "): %s;\n", c.result == "Undefined" ? "void" : "unknown")
		}
		strings.write_string(&b, "\t};\n\n")
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// The modules, in the order of their first call.
@(private = "file")
api_modules :: proc(api: Api) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for c in api.calls {
		if !slice.contains(out[:], c.module) { append(&out, c.module) }
	}
	return out[:]
}

////////////////////////////////
// The explorer's JSON

@(private = "file")
api_json :: proc(api: Api) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n\t\"level\": %d,\n\t\"oldest\": %d,\n\t\"modules\": [\n", api.level, api.oldest)
	mods := api_modules(api)
	for m, mi in mods {
		fmt.sbprintf(&b, "\t\t{{\"name\": %s, \"calls\": [\n", tk_json.quote(m))
		first := true
		for c in api.calls {
			if c.module != m { continue }
			t, _ := type_of_name(api, c.arguments)
			fmt.sbprintf(&b, "%s\t\t\t{{\"name\": %s, \"doc\": %s, \"level\": %d, \"capability\": %s, \"result\": %s, \"arguments\": [",
				first ? "" : ",\n", tk_json.quote(c.name), tk_json.quote(t.doc), c.level, tk_json.quote(c.capability), tk_json.quote(c.result == "Undefined" ? "undefined" : "unknown"))
			first = false
			for f, i in t.fields { json_field(&b, f, i == 0) }
			strings.write_string(&b, "]}")
		}
		fmt.sbprintf(&b, "\n\t\t]}}%s\n", mi + 1 < len(mods) ? "," : "")
	}
	strings.write_string(&b, "\t],\n\t\"types\": [\n")
	shown := make([dynamic]Api_Type, context.temp_allocator)
	for t in api.types { if !is_arguments(api, t.name) { append(&shown, t) } }
	for t, ti in shown {
		fmt.sbprintf(&b, "\t\t{{\"name\": %s, \"doc\": %s, \"kind\": %s", tk_json.quote(t.name), tk_json.quote(t.doc), tk_json.quote(t.is_enum ? "enum" : "object"))
		if t.is_enum {
			strings.write_string(&b, ", \"values\": [")
			for v, i in t.values { fmt.sbprintf(&b, "%s%s", i == 0 ? "" : ", ", tk_json.quote(v)) }
			strings.write_string(&b, "]")
		} else {
			strings.write_string(&b, ", \"fields\": [")
			for f, i in t.fields { json_field(&b, f, i == 0) }
			strings.write_string(&b, "]")
		}
		fmt.sbprintf(&b, "}}%s\n", ti + 1 < len(shown) ? "," : "")
	}
	// (the nodes of a view come with slice 4: the explorer already reads the list)
	strings.write_string(&b, "\t],\n\t\"nodes\": []\n}\n")
	return strings.to_string(b)
}

@(private = "file")
json_field :: proc(b: ^strings.Builder, f: Api_Field, first: bool) {
	fmt.sbprintf(b, "%s{{\"name\": %s, \"type\": %s, \"optional\": %v, \"doc\": %s}}", first ? "" : ", ",
		tk_json.quote(f.name), tk_json.quote(ts_type(f.type)), f.optional, tk_json.quote(f.doc))
}

////////////////////////////////
// The reference page

@(private = "file")
api_page :: proc(api: Api) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# The plugin API\n\n")
	fmt.sbprintf(&b, "Made by `odin run tools/tk -- plugin_api` from `%s`: do not edit. This toolkit gives level %d of the API and accepts plugins written for levels %d to %d. How a program turns plugins on: [plugins.md](plugins.md).\n\n", PLUGIN_API_SOURCE, api.level, api.oldest, api.level)
	strings.write_string(&b, "A plugin imports the API as an ES module, and its entry file exports `activate(context)`:\n\n")
	strings.write_string(&b, "```js\nimport { commands, toast } from \"gt\";\n\nexport function activate(context) {\n\tcommands.on(\"hello\", () => toast.show(\"Hello from \" + context.name));\n}\n```\n\n")
	strings.write_string(&b, "The types are in `plugin-api/gt.d.ts`; each level's are in `plugin-api/level-<n>.d.ts`.\n")
	for m in api_modules(api) {
		fmt.sbprintf(&b, "\n## %s\n", m)
		for c in api.calls {
			if c.module != m { continue }
			t, _ := type_of_name(api, c.arguments)
			names := make([dynamic]string, context.temp_allocator)
			for f in t.fields { append(&names, f.optional ? fmt.tprintf("%s?", f.name) : f.name) }
			fmt.sbprintf(&b, "\n### `%s.%s(%s)`\n\n%s\n\n", m, c.name, strings.join(names[:], ", ", context.temp_allocator), t.doc)
			fmt.sbprintf(&b, "Level %d. Permission: %s.\n\n", c.level, c.capability == "None" ? "none" : c.capability)
			if len(t.fields) > 0 {
				strings.write_string(&b, "| Argument | Type | |\n|---|---|---|\n")
				for f in t.fields { fmt.sbprintf(&b, "| `%s` | `%s`%s | %s |\n", f.name, ts_type(f.type), f.optional ? ", optional" : "", f.doc) }
			}
		}
	}
	strings.write_string(&b, "\n## Types\n")
	for t in api.types {
		if is_arguments(api, t.name) { continue }
		fmt.sbprintf(&b, "\n### `%s`\n\n%s\n\n", t.name, t.doc)
		if t.is_enum {
			quoted := make([dynamic]string, context.temp_allocator)
			for v in t.values { append(&quoted, fmt.tprintf("`\"%s\"`", v)) }
			fmt.sbprintf(&b, "One of %s.\n", strings.join(quoted[:], ", ", context.temp_allocator))
		} else {
			strings.write_string(&b, "| Field | Type | |\n|---|---|---|\n")
			for f in t.fields { fmt.sbprintf(&b, "| `%s` | `%s`%s | %s |\n", f.name, ts_type(f.type), f.optional ? ", optional" : "", f.doc) }
		}
	}
	return strings.to_string(b)
}
