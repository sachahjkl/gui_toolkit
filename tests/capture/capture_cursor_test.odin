// The pointer in a still picture: which backends draw it, the session's choice, and the cut of the pointer's patch
// against the picture (what the Windows backend draws into). No desktop needed.
package capture_test

import "core:testing"
import "../../src/capture"

@(test)
the_backends_that_draw_the_pointer :: proc(t: ^testing.T) {
	testing.expect(t, capture.backend_draws_cursor(.Wayland_Image_Copy))
	testing.expect(t, capture.backend_draws_cursor(.Wayland_Screencopy))
	testing.expect(t, capture.backend_draws_cursor(.Windows))
	testing.expect(t, !capture.backend_draws_cursor(.Portal))
	testing.expect(t, !capture.backend_draws_cursor(.X11))
	testing.expect(t, !capture.backend_draws_cursor(.None))
	testing.expect(t, !capture.cursor_support(nil))
}

// A session's stills have no pointer until it asks for one, and it can stop asking.
@(test)
a_session_asks_for_the_pointer :: proc(t: ^testing.T) {
	s := capture.Session{backend = .Windows}
	testing.expect(t, !s.cursor)
	capture.set_cursor(&s, true)
	testing.expect(t, s.cursor)
	testing.expect(t, capture.cursor_support(&s))
	capture.set_cursor(&s, false)
	testing.expect(t, !s.cursor)
}

@(test)
a_patch_is_cut_to_the_picture :: proc(t: ^testing.T) {
	size := [2]i32{100, 50}
	// inside: all of it
	dst, src, extent, ok := capture.patch_clip(size, {10, 20}, {32, 16})
	testing.expect(t, ok)
	testing.expect_value(t, dst, [2]i32{10, 20})
	testing.expect_value(t, src, [2]i32{0, 0})
	testing.expect_value(t, extent, [2]i32{32, 16})
	// over the top left corner: its bottom right part, at the picture's corner
	dst, src, extent, ok = capture.patch_clip(size, {-5, -3}, {32, 32})
	testing.expect(t, ok)
	testing.expect_value(t, dst, [2]i32{0, 0})
	testing.expect_value(t, src, [2]i32{5, 3})
	testing.expect_value(t, extent, [2]i32{27, 29})
	// over the bottom right corner: its top left part
	dst, src, extent, ok = capture.patch_clip(size, {90, 40}, {32, 32})
	testing.expect(t, ok)
	testing.expect_value(t, dst, [2]i32{90, 40})
	testing.expect_value(t, src, [2]i32{0, 0})
	testing.expect_value(t, extent, [2]i32{10, 10})
	// outside, or empty: nothing
	_, _, _, ok = capture.patch_clip(size, {100, 0}, {32, 32})
	testing.expect(t, !ok)
	_, _, _, ok = capture.patch_clip(size, {-32, 0}, {32, 32})
	testing.expect(t, !ok)
	_, _, _, ok = capture.patch_clip(size, {0, 0}, {0, 32})
	testing.expect(t, !ok)
}
