// tk_remote: a reading's state, and the ticket that drops the answer of a reading given up.
//   odin test tests/remote -vet
package remote_test

import "core:testing"
import remote "../../src/remote"

@(test)
an_answer_of_an_old_ticket_is_dropped :: proc(t: ^testing.T) {
	x: remote.Remote
	defer remote.destroy(&x)
	old := remote.begin(&x)
	now := remote.begin(&x)   // (asked again before the first answered)
	testing.expect(t, !remote.answer(&x, old, .Failed, "late"), "the first reading's answer")
	testing.expect_value(t, x.state, remote.State.Loading)
	testing.expect_value(t, x.message, "")
	testing.expect(t, remote.answer(&x, now, .Ready))
	testing.expect_value(t, x.state, remote.State.Ready)
	testing.expect(t, !remote.answer(&x, now - 1, .Failed, "late"), "still dropped once ready")
	testing.expect_value(t, x.state, remote.State.Ready)
}

@(test)
a_reset_drops_what_is_on_its_way :: proc(t: ^testing.T) {
	x: remote.Remote
	defer remote.destroy(&x)
	ticket := remote.begin(&x)
	remote.reset(&x)
	testing.expect_value(t, x.state, remote.State.Idle)
	testing.expect(t, !remote.current(&x, ticket))
	testing.expect(t, !remote.answer(&x, ticket, .Ready))
	testing.expect_value(t, x.state, remote.State.Idle)
}

// Read again: what was read stays shown until the new reading ends; failed, it is not shown as if it were true.
@(test)
a_reading_again_leaves_what_is_shown_until_it_ends :: proc(t: ^testing.T) {
	x: remote.Remote
	defer remote.destroy(&x)
	testing.expect(t, !remote.shows(&x), "nothing read")
	ticket := remote.begin(&x)
	testing.expect(t, !remote.shows(&x), "the first time, nothing to show")
	remote.answer(&x, ticket, .Ready)
	testing.expect(t, remote.shows(&x))
	ticket = remote.begin(&x)
	testing.expect(t, remote.shows(&x), "it stays")
	remote.answer(&x, ticket, .Refused, "no")
	testing.expect(t, !remote.shows(&x))
	testing.expect(t, remote.failed(&x))
	testing.expect_value(t, x.message, "no")
	remote.reset(&x)
	remote.begin(&x)
	testing.expect(t, !remote.shows(&x), "something else is being read")
}

// Destroyed, it is a new reading's: an answer still on its way does not match.
@(test)
a_destroyed_reading_does_not_take_a_late_answer :: proc(t: ^testing.T) {
	x: remote.Remote
	ticket := remote.begin(&x)
	remote.destroy(&x)
	testing.expect(t, !remote.current(&x, ticket))
	testing.expect_value(t, x.state, remote.State.Idle)
}
