package ui_robust_test

// A build begun inside another one (an app's window procedure made a frame from a message pumped during the build: a loop
// of the system such as TrackPopupMenu) used to empty the outer build's parent stack and free its frame arena; the outer
// build failed later at an unrelated place (a bounds check in ui.spacer). ui.building() lets the app see it; begin_build
// refuses it with an assertion that names it.

import "base:runtime"
import "core:testing"
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

@(test)
nested_build_is_refused :: proc(t: ^testing.T) {
	// (the assertion ends the test where it stands: nothing it allocated is freed, so not from the tracked allocator)
	context.allocator = runtime.heap_allocator()
	f, inner: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	if !testing.expect(t, open(&inner), "fonts") { return }
	testing.expect_assert_message(t, "ui: begin_build inside another build")
	frame(&f, nil, proc(f: ^Fx, user: rawptr) {
		inner := (^Fx)(user)
		if ui.row() {
			// what a frame made from WM_PAINT inside TrackPopupMenu did, in the middle of the outer build
			frame(inner, nil, proc(f: ^Fx, user: rawptr) { ui.spacer(ui.px(4)) })
			ui.spacer(ui.px(6))   // (before: the parent stack was empty here, a bounds check failed in parent_box)
		}
	}, &inner)
	testing.fail_now(t, "the nested build was not refused")
}
