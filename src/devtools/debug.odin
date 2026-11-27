package devtools

// The program's debug panels (gt:debug, src/md/features/debug-panel.md) for the tools: Toolkit.debugPanels lists them
// and their values, Toolkit.debugSet {path, value} sets one, Toolkit.debugPress {path} presses an act. On the interface
// thread before this frame's build: the program's code under the call runs there, and the build shows it.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import debug "../debug"
import "../ui"

// "": answered in `sb`; else why not.
@(private)
debug_command :: proc(sb: ^strings.Builder, s: ^ui.State, method: string, p: json.Object) -> string {
	switch method {
	case "Toolkit.debugPanels":
		debug.list(s, sb)
		return ""
	case "Toolkit.debugSet":
		path := str(p["path"])
		if path == "" { return "debugSet: a path" }
		text, ok := debug_value_text(p["value"])
		if !ok { return "debugSet: a value (a number, a bool, a string or an array of numbers)" }
		if e := debug.set(s, path, text); e != "" { return fmt.tprintf("debugSet: %s", e) }
	case "Toolkit.debugPress":
		path := str(p["path"])
		if path == "" { return "debugPress: a path" }
		if e := debug.press(s, path); e != "" { return fmt.tprintf("debugPress: %s", e) }
	}
	strings.write_string(sb, "{}")
	return ""
}

// A window served gets the debug surface: its View panel, the window's key (debug.attach).
@(private)
debug_attach :: proc(s: ^ui.State) { _ = debug.attach(s) }

// A JSON value as the text debug.set reads: a number, a bool, a string as it is, an array of numbers as "1,2,3"; what
// else (a curve's keys: objects, lists of lists) as its JSON text (curve-editor.md, "The tools").
@(private)
debug_value_text :: proc(v: json.Value) -> (text: string, ok: bool) {
	#partial switch x in v {
	case json.Integer: return fmt.tprintf("%d", x), true
	case json.Float:   return fmt.tprintf("%v", x), true
	case json.Boolean: return x ? "true" : "false", true
	case json.String:  return x, true
	case json.Array:
		flat := true
		for e in x {
			#partial switch _ in e {
			case json.Array, json.Object: flat = false
			}
		}
		if !flat { return debug_value_json(v) }
		parts := make([]string, len(x), context.temp_allocator)
		for e, i in x { parts[i] = debug_value_text(e) or_return }
		return strings.join(parts, ",", context.temp_allocator), true
	case json.Object:
		return debug_value_json(v)
	}
	return "", false
}

@(private)
debug_value_json :: proc(v: json.Value) -> (text: string, ok: bool) {
	data, err := json.marshal(v, allocator = context.temp_allocator)
	return string(data), err == nil
}
