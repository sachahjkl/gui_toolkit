package base

import "core:os"
import "core:testing"

// Sets CI and GUI_PERF to the given values (nil: not defined).
set_perf_env :: proc(ci, gui: Maybe(string)) {
	if v, ok := ci.?; ok { os.set_env("CI", v) } else { os.unset_env("CI") }
	if v, ok := gui.?; ok { os.set_env("GUI_PERF", v) } else { os.unset_env("GUI_PERF") }
}

@(test)
perf_switch :: proc(t: ^testing.T) {
	ci, ci_set := os.lookup_env("CI", context.temp_allocator)
	gui, gui_set := os.lookup_env("GUI_PERF", context.temp_allocator)
	defer {
		if ci_set { os.set_env("CI", ci) } else { os.unset_env("CI") }
		if gui_set { os.set_env("GUI_PERF", gui) } else { os.unset_env("GUI_PERF") }
	}

	set_perf_env("true", "1")
	testing.expect(t, !perf_enabled(), "CI defined: off even with GUI_PERF=1")
	testing.expect(t, perf_skip("ci"), "CI defined: skipped")

	set_perf_env(nil, nil)
	testing.expect(t, !perf_enabled(), "GUI_PERF absent: off")
	testing.expect(t, perf_skip("absent"), "GUI_PERF absent: skipped")

	set_perf_env(nil, "1")
	testing.expect(t, perf_enabled(), "GUI_PERF=1: on")
	testing.expect(t, !perf_skip("on"), "GUI_PERF=1: not skipped")

	set_perf_env(nil, "true")
	testing.expect(t, perf_enabled(), "GUI_PERF=true: on")

	set_perf_env(nil, "0")
	testing.expect(t, !perf_enabled(), "GUI_PERF=0: off")
}
