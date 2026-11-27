package ui

// The one link between a State and the debug surface of gt:debug (src/md/features/debug-panel.md): the surface is the
// debug package's, which imports ui; ui reads its key at the end of a build and destroys it with the State.
Debug_Hook :: struct {
	data:    rawptr,
	toggle:  proc(s: ^State, data: rawptr),   // the key: the debug window opens, or closes
	destroy: proc(data: rawptr),              // ui.destroy: the surface ends with its State
}

// Whether the debug window is in this build: its key (Ctrl+Alt+Shift+D), its View tab, the wireframe's and the exploded
// view's keys, the program's panels (gt:debug). In every build, a release too, unless the program builds with
// -define:TOOLKIT_DEBUG_WINDOW=false. The devtools' endpoint is another define, TOOLKIT_DEVTOOLS (debug-panel.md).
DEBUG_WINDOW :: #config(TOOLKIT_DEBUG_WINDOW, true)

// The key, read in a build with the debug window, as the wireframe's and the exploded view's.
@(private)
DEBUG_KEY :: DEBUG_WINDOW

// At the end of the build, after every reader of keys: a press that a program's own shortcut took (plume's, galerie's,
// classeur's and feuille's "Compact rows" is Ctrl+Alt+Shift+D) stays the program's. The window opens in the next build.
@(private)
debug_keys :: proc(s: ^State) {
	when DEBUG_KEY {
		if s.debug_hook.toggle != nil && key_press_any(.D, {.Ctrl, .Alt, .Shift}) {
			s.debug_hook.toggle(s, s.debug_hook.data)
			s.anim_busy = true   // (its view is built in the next build)
		}
	}
}

@(private)
debug_hook_destroy :: proc(s: ^State) {
	if s.debug_hook.destroy != nil { s.debug_hook.destroy(s.debug_hook.data) }
	s.debug_hook = {}
}
