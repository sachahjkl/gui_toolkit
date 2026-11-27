package host_test

import "core:fmt"
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

// The debug window sent to a window of its own: its key there closes it, as in its owner's window. That window is a
// view's, which gt:host opens with a debug surface of its own: the key must not open a debug window of the debug window.
@(test)
the_debug_key_in_the_debug_window_s_own_window_closes_it :: proc(t: ^testing.T) {
	p: Probe
	defer delete(p.seen)
	sh: host.Shared
	a := new(host.Host)
	defer free(a)
	open_main(t, &sh, a, &p)
	defer host.host_close(a)
	step(a)
	views := ui.state_views(&a.state)
	ui.views_set_windows(views, host.view_windows(&sh))
	press_debug_key(a)
	testing.expect(t, debug.shown(&a.state), "the key opens the debug window")
	// (not temp memory: a frame frees it)
	instance := fmt.aprintf("%x", uintptr(&a.state))
	defer delete(instance)
	ui.view_present(views, debug.DEBUG_VIEW, .External, instance = instance)
	vw: ^ui.State
	for _ in 0 ..< 40 {
		step(a)
		vw = ui.view_window_state(views, debug.DEBUG_VIEW, instance)
		if vw != nil && vw.window != nil { break }
	}
	if !testing.expect(t, vw != nil && vw.window != nil, "the debug window in a window of its own") { return }
	step(a)
	platform.inject_event(vw.window, {kind = .Key_Press, key = .D, mods = {.Ctrl, .Alt, .Shift}})
	for _ in 0 ..< 4 { step(a) }
	testing.expect(t, !debug.shown(vw), "no debug window of the debug window")
	testing.expect(t, !debug.shown(&a.state), "the key in its window closes it")
}
