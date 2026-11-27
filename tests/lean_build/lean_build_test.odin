// A build with the toolkit's optional parts left out (run_tests passes the defines; docs/builds.md). Two steps:
//   lean_build       a release's defaults: no devtools' endpoint, the debug window kept
//     odin test tests/lean_build -collection:gt=src -vet -define:TOOLKIT_DEVTOOLS=false -define:FONT_EMBED_FALLBACK=false
//   lean_build_bare  the debug window left out too (-define:TOOLKIT_DEBUG_WINDOW=false): nothing of either
package lean_build_test

import "core:os"
import "core:strings"
import "core:testing"
import "gt:debug"
import "gt:devtools"
import "gt:ui"
import "gt:font"

// Without the endpoint, the environment variable starts nothing, and service and stop take the nil.
@(test)
no_devtools_without_the_define :: proc(t: ^testing.T) {
	testing.expect(t, !devtools.TOOLKIT_DEVTOOLS, "built with -define:TOOLKIT_DEVTOOLS=false")
	_ = os.set_env("TOOLKIT_DEVTOOLS", "9399")
	defer os.unset_env("TOOLKIT_DEVTOOLS")
	srv := devtools.start_from_env(nil, "lean")
	testing.expect(t, srv == nil)
	devtools.service(srv, nil, nil)
	devtools.stop(srv)
}

// A release keeps the debug window without the endpoint: a panel registers, the tools' list has it, the key opens the
// window and closes it (src/md/features/debug-panel.md, "In every build").
@(test)
the_debug_window_without_the_devtools :: proc(t: ^testing.T) {
	when ui.DEBUG_WINDOW {
		testing.expect(t, debug.ENABLED, "the debug window is in a build without TOOLKIT_DEBUG_WINDOW=false")
		Probe :: struct { speed: f32, runs: int }
		probe: Probe
		state: ui.State
		ui.init(&state, nil, nil)
		defer ui.destroy(&state)
		debug.panel(&state, "Probe", proc(p: ^Probe) { p.runs += 1; debug.number("speed", &p.speed) }, &probe)
		testing.expect(t, state.debug_hook.data != nil, "a panel attaches the surface")
		sb := strings.builder_make(context.temp_allocator)
		debug.list(&state, &sb)
		testing.expect(t, strings.contains(strings.to_string(sb), `"path":"Probe/speed"`), strings.to_string(sb))
		testing.expect_value(t, debug.set(&state, "Probe/speed", "2"), "")
		testing.expect_value(t, probe.speed, 2)
	}
}

// Built with -define:TOOLKIT_DEBUG_WINDOW=false, the debug panels are compiled out: a panel registers nothing (the
// State has no surface), its calls return false, the tools' list is empty (src/md/features/debug-panel.md, "Cost").
@(test)
no_debug_panels_without_the_define :: proc(t: ^testing.T) {
	when ui.DEBUG_WINDOW { return }
	testing.expect(t, !debug.ENABLED, "built with -define:TOOLKIT_DEBUG_WINDOW=false")
	Probe :: struct { speed: f32, runs: int }
	probe: Probe
	state: ui.State
	debug.panel(&state, "Probe", proc(p: ^Probe) { p.runs += 1; debug.number("speed", &p.speed) }, &probe)
	testing.expect(t, state.debug_hook.data == nil)
	testing.expect(t, debug.attach(&state) == nil)
	testing.expect(t, !debug.number("speed", &probe.speed))
	testing.expect(t, !debug.act("Print"))
	testing.expect(t, !debug.shown(&state))
	sb := strings.builder_make(context.temp_allocator)
	debug.list(&state, &sb)
	testing.expect_value(t, strings.to_string(sb), `{"panels":[]}`)
	testing.expect(t, debug.set(&state, "Probe/speed", "1") != "")
	testing.expect_value(t, probe.runs, 0)
}

// Outside a panel (and compiled out without the debug window), the curve editor draws nothing, and a curve still
// plays: a release animates with it (src/md/features/curve-editor.md).
@(test)
a_curve_plays_without_the_editor :: proc(t: ^testing.T) {
	c: debug.Curve
	debug.curve_insert(&c, {time = 0, value = 0, interp = .Linear})
	debug.curve_insert(&c, {time = 2, value = 4})
	testing.expect(t, !debug.curve("hover", &c))
	easing := ui.ease_bezier(.Out)
	testing.expect(t, !debug.easing("land", &easing))
	play := debug.Playback{}
	testing.expect_value(t, debug.playback_step(&play, 0.5, debug.curve_span(c)), 0.5)
	testing.expect_value(t, debug.curve_eval(c, play.time), 1)
	testing.expect(t, strings.has_prefix(debug.curve_text(c), "debug.Curve{count = 2, keys = {0 = {time = 0, value = 0, interp = .Linear}"))
}

// Without the fallback fonts, their data is empty and a missing system font is not replaced.
@(test)
no_fallback_fonts_without_the_define :: proc(t: ^testing.T) {
	testing.expect(t, !font.FONT_EMBED_FALLBACK, "built with -define:FONT_EMBED_FALLBACK=false")
	testing.expect_value(t, len(font.FALLBACK_UI_DATA), 0)
	testing.expect_value(t, len(font.FALLBACK_MONO_DATA), 0)
	s := new(font.State)
	defer free(s)
	font.init(s)
	defer font.destroy(s)
	_, ok, _ := font.load_system_or_embedded(s, "", font.FALLBACK_UI_DATA)
	testing.expect(t, !ok)
}
