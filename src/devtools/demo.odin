package devtools

// Demo states: screens that need an account (a vault unlocked, a PIN asked), entered by a tool for a picture
// (src/md/features/demo-states.md). Toolkit.demoStates lists the names, Toolkit.demoState {name} enters one.

import "base:runtime"
import "core:fmt"
import "core:strings"
import tk_json "../json"

// A state's procedure: it sets the program's state in memory, never the person's files.
Demo_Enter :: proc(user: rawptr)

@(private)
Demo_State :: struct {
	name:  string,   // (the heap's)
	enter: Demo_Enter,
	user:  rawptr,
}

// Registers a state a tool can enter by `name` (stable: a script holds it, "vault.unlocked"). Once, on the interface
// thread, after start_from_env. A name registered again replaces the first. With a nil server (no TOOLKIT_DEVTOOLS),
// and in a build without the endpoint, it does nothing.
demo_state :: proc(srv: ^Server, name: string, enter: Demo_Enter, user: rawptr = nil) {
	when TOOLKIT_DEVTOOLS {
		if srv == nil || name == "" || enter == nil { return }
		for &d in srv.demos {
			if d.name == name { d.enter, d.user = enter, user; return }
		}
		append(&srv.demos, Demo_State{strings.clone(name, runtime.heap_allocator()), enter, user})
	}
}

@(private)
demos_destroy :: proc(srv: ^Server) {
	for d in srv.demos { delete(d.name, runtime.heap_allocator()) }
	delete(srv.demos)
}

// Toolkit.demoStates: the names, in the order of registration.
@(private)
demo_list :: proc(sb: ^strings.Builder, srv: ^Server) {
	strings.write_string(sb, `{"names":[`)
	for d, i in srv.demos {
		if i > 0 { strings.write_byte(sb, ',') }
		strings.write_string(sb, tk_json.quote(d.name))
	}
	strings.write_string(sb, "]}")
}

// Toolkit.demoState: runs the state's procedure here, on the interface thread before this frame's build, so that build
// shows it. "": done; else why not (a typo lists what exists, so a script never takes a picture of the wrong screen).
@(private)
demo_enter :: proc(srv: ^Server, name: string) -> string {
	if name == "" { return "demoState: a name" }
	for d in srv.demos {
		if d.name == name { d.enter(d.user); return "" }
	}
	if len(srv.demos) == 0 { return fmt.tprintf("demoState: no state '%s': this program registers none", name) }
	names := make([]string, len(srv.demos), context.temp_allocator)
	for d, i in srv.demos { names[i] = d.name }
	return fmt.tprintf("demoState: no state '%s' (known: %s)", name, strings.join(names, ", ", context.temp_allocator))
}
