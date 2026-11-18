// The pieces of a module's declarations for an author (plugins.md, "As built: a program's own module"): a TypeScript
// doc comment, a Markdown table's cell, the TypeScript of an Odin primitive. Both writers use them: `tk plugin_api`
// for the module "gt" (from the declarations' source) and plugin_api.app_module_dts for a program's "app" (from its
// declaration, by reflection). A package of its own, without the engine: a tool imports it.
package tk_plugin_api_dts

import "core:fmt"
import "core:strings"

// A TypeScript doc comment for `doc` at `indent` (nothing for no doc).
doc :: proc(b: ^strings.Builder, indent, text: string) {
	if text != "" { fmt.sbprintf(b, "%s/** %s */\n", indent, text) }
}

// `s` as a cell of a Markdown table: a union's "|" would end the cell, even in a code span.
cell :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "|", "\\|", context.temp_allocator)
	return out
}

// The TypeScript of an Odin primitive type's name. ok false: not a primitive.
primitive :: proc(odin_type: string) -> (ts: string, ok: bool) {
	switch odin_type {
	case "string":
		return "string", true
	case "f64", "f32", "int", "i64", "i32", "i16", "i8", "u64", "u32", "u16", "u8", "uint":
		return "number", true
	case "bool":
		return "boolean", true
	}
	return "", false
}

// A row of a Markdown table of fields: its name, its TypeScript type, whether it is optional, its doc.
field_row :: proc(b: ^strings.Builder, name, ts_type: string, optional: bool, text: string) {
	fmt.sbprintf(b, "| `%s` | `%s`%s | %s |\n", name, cell(ts_type), optional ? ", optional" : "", text)
}

// The head of a Markdown table of fields; `first` is its first column's title ("Field", "Argument").
field_head :: proc(b: ^strings.Builder, first: string) {
	fmt.sbprintf(b, "| %s | Type | |\n|---|---|---|\n", first)
}
