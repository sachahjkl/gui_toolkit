// A build with the toolkit's optional parts left out (run_tests passes the defines; docs/builds.md):
//   odin test tests/lean_build -collection:gt=src -vet -define:TOOLKIT_DEVTOOLS=false -define:FONT_EMBED_FALLBACK=false
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

// Without the endpoint, the debug panels are compiled out: a panel registers nothing (the State has no surface), its
// calls return false, the tools' list is empty (src/md/features/debug-panel.md, "Cost").
@(test)
no_debug_panels_without_the_define :: proc(t: ^testing.T) {
	testing.expect(t, !debug.ENABLED, "built with -define:TOOLKIT_DEVTOOLS=false")
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
