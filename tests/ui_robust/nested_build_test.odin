package ui_robust_test

// A build begun inside another one (an app's window procedure made a frame from a message pumped during the build: a loop
// of the system such as TrackPopupMenu) used to empty the outer build's parent stack and free its frame arena; the outer
// build failed later at an unrelated place (a bounds check in ui.spacer). ui.building() lets the app see it; begin_build
// refuses it with an assertion that names it.

import "base:runtime"
import "core:testing"
import "core:thread"
import "../../ui"

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
