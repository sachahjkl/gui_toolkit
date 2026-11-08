package ui_robust_test

// A build begun inside another one (an app's window procedure made a frame from a message pumped during the build: a loop
// of the system such as TrackPopupMenu) used to empty the outer build's parent stack and free its frame arena; the outer
// build failed later at an unrelated place (a bounds check in ui.spacer). ui.building() lets the app see it; begin_build
// refuses it with an assertion that names it.

import "base:runtime"
import "core:testing"
import "core:thread"
import "../../src/platform"
import "../../src/ui"

@(test)
building_is_true_between_begin_and_end :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	testing.expect(t, !ui.building(), "no build before the first")
	frame(&f, nil, proc(f: ^Fx, user: rawptr) {
		t := (^testing.T)(user)
		testing.expect(t, ui.building(), "a build is open inside begin_build / end_build")
		if ui.row() { ui.spacer(ui.px(4)) }
	}, t)
	testing.expect(t, !ui.building(), "no build after end_build")
	// a second state, built after the first: still one build at a time, none open afterwards
	g: Fx
	if !testing.expect(t, open(&g), "fonts") { return }
	defer close(&g)
	frame(&g, nil, proc(f: ^Fx, user: rawptr) { ui.spacer(ui.px(4)) })
	testing.expect(t, !ui.building(), "no build after the second state's")
}

// A state destroyed in the middle of its build leaves no build open on the thread: the next state builds.
@(test)
a_state_destroyed_in_its_build_leaves_none_open :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	ui.begin_build(&f.s, {window_size = {800, 600}, dt = 1.0 / 60, dpi_scale = 1, base = ui.Style{font = f.base_font, font_size = 15}})
	close(&f)
	testing.expect(t, !ui.building(), "its build is gone with it")
	g: Fx
	if !testing.expect(t, open(&g), "fonts") { return }
	defer close(&g)
	frame(&g, nil, proc(f: ^Fx, user: rawptr) { ui.spacer(ui.px(4)) })
}

// `use` of another state in the middle of a build: end_build ends the build that is open, not the state selected.
@(test)
end_build_ends_the_build_that_is_open :: proc(t: ^testing.T) {
	f, g: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	if !testing.expect(t, open(&g), "fonts") { return }
	defer close(&g)
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.use(&(^Fx)(user).s) }, &g)
	testing.expect(t, !ui.building(), "no build open after it")
	testing.expect_value(t, ui.boxes_built(&g.s), 0)
}

// The clipboard written from end_build is written from a build: building() says so until the build is over.
@(test)
a_build_is_open_to_its_last_line :: proc(t: ^testing.T) {
	@(static) seen: bool
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	one :: proc(f: ^Fx, events: []platform.Event) {
		ui.begin_build(&f.s, {
			window_size = {800, 600}, events = events, dt = 1.0 / 60, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
			clipboard_set = proc(text: string) { seen = ui.building() },
		})
		ui.next({flags = {.Selectable}})
		ui.label("Words###words")
		ui.end_build()
		free_all(context.temp_allocator)
	}
	one(&f, nil)
	one(&f, nil)
	ui.select_box(&f.s, ui.box_at("###words").key)
	one(&f, {{kind = .Key_Press, key = .C, mods = {.Ctrl}}})
	testing.expect(t, seen, "the copy of end_build ran in the build")
}

// The assertion is caught on a thread of the test's own, whose assertion procedure records the message and ends that
// thread. (Not testing.expect_assert_message: on Windows the runner's exception handler passes the exception on and
// races the system's unhandled-exception path, which ended the whole test process without a word on a CI runner.)
@(private="file") refused_message: string
@(private="file") nested_reached_end: bool

when ODIN_OS == .Windows {
	foreign import kernel32 "system:Kernel32.lib"
	@(default_calling_convention = "system", private = "file")
	foreign kernel32 { ExitThread :: proc(code: u32) -> ! --- }
}

@(test)
nested_build_is_refused :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	refused_message, nested_reached_end = "", false
	th := thread.create_and_start(proc() {
		// (the assertion ends the thread where it stands: nothing it allocated is freed, so not the tracked allocator)
		context.allocator = runtime.heap_allocator()
		context.assertion_failure_proc = proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
			refused_message = message
			ExitThread(0)
		}
		f, inner: Fx
		if !open(&f) || !open(&inner) { return }
		frame(&f, nil, proc(f: ^Fx, user: rawptr) {
			inner := (^Fx)(user)
			if ui.row() {
				// what a frame made from WM_PAINT inside TrackPopupMenu did, in the middle of the outer build
				frame(inner, nil, proc(f: ^Fx, user: rawptr) { ui.spacer(ui.px(4)) })
				ui.spacer(ui.px(6))   // (before: the parent stack was empty here, a bounds check failed in parent_box)
			}
		}, &inner)
		nested_reached_end = true
	})
	thread.destroy(th)   // (joins it)
	testing.expect_value(t, refused_message, "ui: begin_build inside another build")
	testing.expect(t, !nested_reached_end, "the nested build was not refused")
	testing.expect(t, !ui.building(), "the test's own thread has no build open")
}

// A public proc on a thread where nothing selected a state (no init, use or begin_build) stops at once and says why, not on a
// nil state somewhere further.
@(private="file") no_state_message: string
@(private="file") no_state_reached_end: bool

@(test)
no_state_on_this_thread_is_named :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	no_state_message, no_state_reached_end = "", false
	th := thread.create_and_start(proc() {
		context.allocator = runtime.heap_allocator()
		context.assertion_failure_proc = proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
			no_state_message = message
			ExitThread(0)
		}
		_ = ui.focus_key()   // (a new thread: its state is nil)
		no_state_reached_end = true
	})
	thread.destroy(th)
	testing.expect_value(t, no_state_message, ui.NO_STATE_MESSAGE)
	testing.expect_value(t, no_state_message, "ui: no begin_build on this thread")
	testing.expect(t, !no_state_reached_end, "the call went on without a state")
	// the procs that answer without one still do
	testing.expect(t, !ui.building(), "building() needs no state")
	testing.expect(t, ui.now_ms() >= 0, "now_ms() needs no state")
}
