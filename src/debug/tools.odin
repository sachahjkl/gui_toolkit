package debug

// The panels for the tools (the devtools' Toolkit.debugPanels, debugSet, debugPress): the same procedures in the List
// and Apply passes, on the interface thread before the frame's build. The paths are the window's.

import "core:fmt"
import "core:strings"
import "../ui"

// Writes the panels of `s`'s window and what they hold, as JSON: `{"panels":[{"name":"Soldier","items":[{"path":
// "Soldier/Transform/position","kind":"vector","value":[0,1.5,0], ...}, ...]}]}`. Kinds: number, vector, bool, choice,
// text, color, watch, plot, act. A window without the surface has the View panel (attach).
list :: proc(s: ^ui.State, sb: ^strings.Builder) {
	when ENABLED {
		sf := attach(s)
		strings.write_string(sb, `{"panels":[`)
		if sf != nil {
			for p, i in sf.panels {
				if i > 0 { strings.write_byte(sb, ',') }
				fmt.sbprintf(sb, `{{"name":%s,"items":[`, quoted(p.name))
				pass := Pass{kind = .List, surface = sf, sb = sb}
				pass_run(&pass, p)
				strings.write_string(sb, "]}")
			}
		}
		strings.write_string(sb, "]}")
	} else {
		strings.write_string(sb, `{"panels":[]}`)
	}
}

// Sets the value at `path` from `text` (a number, "1, 2, 3" for a vector, true or false, an enum's name, a string,
// "#rrggbbaa" or four numbers for a colour), held to its bounds and its step. "": done (the program's code under the
// call ran); else why not.
set :: proc(s: ^ui.State, path, text: string) -> (err: string) {
	when ENABLED { return apply(s, path, text, false) } else { return "no debug panels in this build" }
}

// Presses the act at `path`: its code runs now. "": done; else why not.
press :: proc(s: ^ui.State, path: string) -> (err: string) {
	when ENABLED { return apply(s, path, "", true) } else { return "no debug panels in this build" }
}

@(private)
apply :: proc(s: ^ui.State, path, text: string, press: bool) -> string {
	sf := attach(s)
	if sf == nil { return "no debug surface on this window" }
	at := strings.index_byte(path, '/')
	if at <= 0 || at == len(path) - 1 { return fmt.tprintf("a path is a panel and a label: %q", path) }
	name := path[:at]
	for p in sf.panels {
		if p.name != name { continue }
		pass := Pass{kind = .Apply, surface = sf, target = path_root(path), text = text, press = press}
		pass_run(&pass, p)
		if !pass.found { return fmt.tprintf("no %q in the panel %q", path[at + 1:], name) }
		return pass.err
	}
	names := make([]string, len(sf.panels), context.temp_allocator)
	for p, i in sf.panels { names[i] = p.name }
	return fmt.tprintf("no panel %q (known: %s)", name, strings.join(names, ", ", context.temp_allocator))
}
