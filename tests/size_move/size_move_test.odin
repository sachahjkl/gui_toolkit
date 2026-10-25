// Which WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE open the window's modal mode: the decision alone (no window, no clock).
//   odin test tests/size_move -use-separate-modules -vet
package size_move_test

import "core:testing"
import "../../platform"

// The system's loop runs inside DefWindowProc: its messages count, and nest.
@(test)
messages_from_the_systems_loop_count :: proc(t: ^testing.T) {
	open, counted := platform.size_move_step(0, .Enter, true)
	testing.expect_value(t, open, 1)
	testing.expect(t, counted)
	open, counted = platform.size_move_step(open, .Enter, true)   // a move started from inside a size
	testing.expect_value(t, open, 2)
	open, counted = platform.size_move_step(open, .Exit, true)
	testing.expect_value(t, open, 1)
	testing.expect(t, counted)
	open, counted = platform.size_move_step(open, .Exit, true)
	testing.expect_value(t, open, 0)
	testing.expect(t, counted)
}

// A message that does not come from inside DefWindowProc (AltSnap posts them from its own process, from the queue the
// app's poll pumps; so does any test or accessibility tool) opens and closes nothing.
@(test)
messages_from_outside_are_ignored :: proc(t: ^testing.T) {
	open, counted := platform.size_move_step(0, .Enter, false)
	testing.expect_value(t, open, 0)
	testing.expect(t, !counted)
	open, counted = platform.size_move_step(0, .Exit, false)
	testing.expect_value(t, open, 0)
	testing.expect(t, !counted)
}

// A foreign message while a real loop is open changes nothing either way; the real exit then closes the real loop.
@(test)
foreign_messages_do_not_touch_an_open_loop :: proc(t: ^testing.T) {
	open, _ := platform.size_move_step(0, .Enter, true)
	open, _ = platform.size_move_step(open, .Exit, false)
	testing.expect_value(t, open, 1)
	open, _ = platform.size_move_step(open, .Enter, false)
	testing.expect_value(t, open, 1)
	open, _ = platform.size_move_step(open, .Exit, true)
	testing.expect_value(t, open, 0)
}

// An exit from the system with no loop open (the window opened inside one) is not counted, and never goes below zero.
@(test)
an_exit_without_a_loop_is_not_counted :: proc(t: ^testing.T) {
	open, counted := platform.size_move_step(0, .Exit, true)
	testing.expect_value(t, open, 0)
	testing.expect(t, !counted)
}
