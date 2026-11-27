// A program's own state and acts on a debug surface (src/md/features/debug-panel.md): values shown and edited live,
// acts pressed, in a dense window beside the page (Ctrl+Alt+Shift+D) and by the tools (the devtools' Toolkit.debug*).
//
//   soldier_debug :: proc(s: ^Soldier) {
//       debug.number("model", &s.model, lo = 0, hi = 7)
//       if debug.section("Transform") {
//           debug.vector("rotation", &s.rotation, step = 0.01)
//           debug.vector("position", &s.position)
//       }
//       debug.value("look", &s.look)                      // any Odin value, by reflection
//       if debug.act("Print") { fmt.println(debug.odin_text(s^)) }
//   }
//   debug.panel(&app.state, "Soldier", soldier_debug, &app.soldier)   // once, at start
//
// A panel's procedure runs when the panel is needed (its tab shown, a tool's list, set or press), on the interface
// thread; it calls debug.* and the program's own code, nothing else of the interface. A release build
// (TOOLKIT_DEVTOOLS false) compiles every call to nothing (ENABLED).
package debug

import "base:runtime"
import "core:fmt"
import "core:strings"
import "../ui"

_ :: strings   // (a release build's calls are empty: the import is used by the others only)

// Whether the surface is in this build: a -debug build and a test have it, a release build only with
// -define:TOOLKIT_DEVTOOLS=true. Without it every call does nothing and returns false.
ENABLED :: #config(TOOLKIT_DEVTOOLS, ODIN_DEBUG || ODIN_TEST)

// The debug window's view id (one instance per window), and a pinned panel's (its instance: the window's and the
// panel's name).
DEBUG_VIEW :: "debug"
DEBUG_PANEL_VIEW :: "debug.panel"

// The name of the toolkit's own tab: the view's tools and the frame's numbers.
VIEW_PANEL :: "View"

// A panel's procedure as kept.
@(private)
Panel_Build :: proc(data: rawptr)

@(private)
Panel :: struct {
	name:    string,   // (the surface's allocator)
	key:     u64,      // the hash of its name: the root of its paths
	build:   Panel_Build,
	data:    rawptr,
	pinned:  bool,     // in a view of its own (DEBUG_PANEL_VIEW), not a tab of the window
	surface: ^Surface,
	labels:  ui.Dense_Labels,   // its labels' column: its longest label's width
}

// What one window's debug surface keeps: its panels, the sections the person opened or closed, the tab shown, the
// filter, the strings it wrote. Made at the first panel (or attach), ended with the State.
Surface :: struct {
	state:     ^ui.State,
	allocator: runtime.Allocator,
	panels:    [dynamic]^Panel,        // in the order of registration; [0] the View panel
	opened:    map[u64]bool,           // a section's state the person chose, by its path's hash
	tab:       int,                    // the panel shown in the window
	filter:    ui.Line_Edit,
	written:   map[u64]string,         // the strings the surface wrote into the program's variables, by path
	fields:    map[u64]^Text_Field,    // the text fields of the strings shown
	frame_ms:  ui.Value_History(FRAMES_KEPT),
	frame_build: u64,                  // the build whose frame time is the last pushed
	curve_edits: map[u64]^Curve_Edit,  // the curve editors' views, selections and undo steps, by path
	easing_key:  u64,                  // the easing whose handle is dragged (its path's hash), 0: none
	easing_handle: int,                // 1 or 2
	easing_seen: map[u64]ui.Cubic_Bezier,   // each easing's curve at its last build: a change runs its preview
	easing_anim_key:   u64,            // the easing whose preview runs (0: none), its time in it, s, and when it stops
	easing_anim_t:     f64,
	easing_anim_end:   f64,
	easing_anim_build: u64,
	shows:     ^Surface,               // in a view's own window: the surface whose debug window it shows (its key acts there)
}

// The frames the View panel's graph shows.
@(private) FRAMES_KEPT :: 120

// Registers the panel `name` on the window of `s`: `build(data)` runs when the panel is needed. Once, on the interface
// thread; a name registered again replaces the first. `data` must stay valid until panel_remove or the State ends.
// The name is the first part of every path of the panel ("Soldier/Transform/position"); it holds no "/". Called from
// a panel's procedure, it does nothing: the passes walk the panels while it runs.
panel :: proc(s: ^ui.State, name: string, build: proc(data: ^$T), data: ^T) {
	when ENABLED {
		if current != nil { return }
		sf := attach(s)
		if sf == nil || name == "" || build == nil || strings.contains_rune(name, '/') { return }
		for p in sf.panels {
			if p.name == name { p.build, p.data = Panel_Build(rawptr(build)), data; return }
		}
		p := new(Panel, sf.allocator)
		p^ = {name = clone(sf, name), key = path_root(name), build = Panel_Build(rawptr(build)), data = data, surface = sf}
		p.labels.widths.allocator = sf.allocator
		append(&sf.panels, p)
	}
}

// Takes the panel away (its data is about to go). Called from a panel's procedure, it does nothing (see panel).
panel_remove :: proc(s: ^ui.State, name: string) {
	when ENABLED {
		if current != nil { return }
		sf := surface_of(s)
		if sf == nil { return }
		for p, i in sf.panels {
			if p.name != name || i == 0 { continue }
			if p.pinned { ui.view_close(ui.state_views(sf.state), DEBUG_PANEL_VIEW, pinned_instance(p)) }
			ordered_remove(&sf.panels, i)
			panel_free(sf, p)
			sf.tab = clamp(sf.tab, 0, len(sf.panels) - 1)
			return
		}
	}
}

// The window's surface, made if it has none: its View panel, its key. A program with no panel of its own gets the
// window and its View tab so (devtools.service does it for a program it serves).
attach :: proc(s: ^ui.State) -> ^Surface {
	when ENABLED {
		if s == nil { return nil }
		if sf := surface_of(s); sf != nil { return sf }
		if s.debug_hook.data != nil { return nil }   // (another surface's: not ours to replace)
		// (the program's allocator where it registers: a program's tracking allocator sees the surface)
		sf := new(Surface)
		sf.state, sf.allocator = s, context.allocator
		sf.panels.allocator, sf.opened.allocator, sf.written.allocator, sf.fields.allocator = sf.allocator, sf.allocator, sf.allocator, sf.allocator
		sf.curve_edits.allocator, sf.easing_seen.allocator = sf.allocator, sf.allocator
		s.debug_hook = {data = sf, toggle = hook_toggle, destroy = hook_destroy}
		p := new(Panel, sf.allocator)
		p^ = {name = clone(sf, VIEW_PANEL), key = path_root(VIEW_PANEL), build = Panel_Build(rawptr(view_panel)), data = sf, surface = sf}
		p.labels.widths.allocator = sf.allocator
		append(&sf.panels, p)
		return sf
	} else {
		return nil
	}
}

// The debug window of `s`: open it, close it, whether it is open. Its key does the same.
open :: proc(s: ^ui.State) {
	when ENABLED {
		sf := attach(s)
		if sf == nil || shown(s) { return }
		window_open(sf)
	}
}
close :: proc(s: ^ui.State) {
	when ENABLED {
		sf := surface_of(s)
		if sf == nil { return }
		ui.view_close(ui.state_views(s), DEBUG_VIEW, window_instance(sf))
	}
}
shown :: proc(s: ^ui.State) -> bool {
	when ENABLED {
		sf := surface_of(s)
		return sf != nil && ui.view_is_open(ui.state_views(s), DEBUG_VIEW, window_instance(sf))
	} else {
		return false
	}
}

// The panel shown in the window, by name (a tool's picture of one); false: no such panel.
show_panel :: proc(s: ^ui.State, name: string) -> bool {
	when ENABLED {
		sf := surface_of(s)
		if sf == nil { return false }
		for p, i in sf.panels { if p.name == name { sf.tab = i; return true } }
	}
	return false
}

// The surface of a State, if it has one of this package.
@(private)
surface_of :: proc(s: ^ui.State) -> ^Surface {
	if s == nil || s.debug_hook.toggle != hook_toggle { return nil }
	return (^Surface)(s.debug_hook.data)
}

@(private)
hook_toggle :: proc(s: ^ui.State, data: rawptr) {
	sf := (^Surface)(data)
	// (a window that shows a debug window, its own window: the key closes that one, or opens it again)
	if sf.shows != nil { sf = sf.shows }
	if shown(sf.state) { close(sf.state) } else { window_open(sf) }
}

@(private)
hook_destroy :: proc(data: rawptr) {
	sf := (^Surface)(data)
	for p in sf.panels { panel_free(sf, p) }
	delete(sf.panels)
	delete(sf.opened)
	for _, w in sf.written { delete(w, sf.allocator) }
	delete(sf.written)
	for _, f in sf.fields { ui.line_edit_destroy(&f.edit); free(f, sf.allocator) }
	delete(sf.fields)
	for _, e in sf.curve_edits { curve_edit_free(sf, e) }
	delete(sf.curve_edits)
	delete(sf.easing_seen)
	ui.line_edit_destroy(&sf.filter)
	free(sf, sf.allocator)
}

@(private)
panel_free :: proc(sf: ^Surface, p: ^Panel) {
	ui.dense_labels_destroy(&p.labels)
	delete(p.name, sf.allocator)
	free(p, sf.allocator)
}

@(private)
clone :: proc(sf: ^Surface, s: string) -> string {
	b := make([]u8, len(s), sf.allocator)
	copy(b, s)
	return string(b)
}

@(private)
window_instance :: proc(sf: ^Surface) -> string { return fmt.tprintf("%x", uintptr(sf.state)) }

@(private)
pinned_instance :: proc(p: ^Panel) -> string { return fmt.tprintf("%x/%s", uintptr(p.surface.state), p.name) }
