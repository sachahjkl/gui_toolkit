package ui

// The one link between a State and the debug surface of gt:debug (src/md/features/debug-panel.md): the surface is the
// debug package's, which imports ui; ui reads its key at the start of a build and destroys it with the State.
Debug_Hook :: struct {
	data:    rawptr,
	toggle:  proc(s: ^State, data: rawptr),   // the key: the debug window opens, or closes
	destroy: proc(data: rawptr),              // ui.destroy: the surface ends with its State
}

// The key, read in a build with the devtools, as the wireframe's and the exploded view's.
@(private)
DEBUG_KEY :: #config(TOOLKIT_DEVTOOLS, ODIN_DEBUG || ODIN_TEST)

@(private)
debug_keys :: proc(s: ^State) {
	when DEBUG_KEY {
		if s.debug_hook.toggle != nil && key_press_any(.D, {.Ctrl, .Alt, .Shift}) { s.debug_hook.toggle(s, s.debug_hook.data) }
	}
}

@(private)
debug_hook_destroy :: proc(s: ^State) {
	if s.debug_hook.destroy != nil { s.debug_hook.destroy(s.debug_hook.data) }
	s.debug_hook = {}
}
