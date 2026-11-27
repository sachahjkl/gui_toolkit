package host_test

import "core:strings"
import "core:testing"
import "gt:debug"
import host "gt:host"
import "gt:platform"
import "gt:ui"

@(private = "file")
press_debug_key :: proc(h: ^host.Host) {
	platform.inject_event(h.win, {kind = .Key_Press, key = .D, mods = {.Ctrl, .Alt, .Shift}})
	step(h)
}

// Every window the host opens has the debug window behind its key, with the toolkit's View tab, though the program
// registered no panel; a second window has its own (src/md/features/debug-panel.md, "Every window has it").
@(test)
every_window_has_the_debug_window :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	a := new(host.Host)
	defer free(a)
	open_main(t, &sh, a, &p)
	defer host.host_close(a)
	b := new(host.Host)
	defer free(b)
	if !host.host_open(b, &sh, {title = "host test 2", size = SIZE, headless = true}, probe_build, &p) {
		testing.fail_now(t, "no second window")
	}
	defer host.host_close(b)
	ui.set_clock(&b.state, &p.clock)
	step(a)
	step(b)
	testing.expect(t, !debug.shown(&a.state) && !debug.shown(&b.state), "closed until its key")

	press_debug_key(a)
	testing.expect(t, debug.shown(&a.state), "the key opens the first window's debug window")
	testing.expect(t, !debug.shown(&b.state), "the second window's stays closed")
	press_debug_key(b)
	testing.expect(t, debug.shown(&b.state), "the second window has its own")

	// (only the toolkit's tab: the program registered nothing)
	for s in ([]^ui.State{&a.state, &b.state}) {
		sb := strings.builder_make(context.temp_allocator)
		debug.list(s, &sb)
		listed := strings.to_string(sb)
		testing.expect(t, strings.has_prefix(listed, `{"panels":[{"name":"View"`), listed)
		testing.expect_value(t, strings.count(listed, `{"name":`), 1)
	}

	press_debug_key(a)
	testing.expect(t, !debug.shown(&a.state), "the key closes it again")
	testing.expect(t, debug.shown(&b.state))
}
