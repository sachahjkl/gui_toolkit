package tk_session

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"

// Ends the test here: its message is logged at the place given, and the runner ends this thread (its "Test timed out"
// follows the message). A limit of 0 is the one way of being ended that core:testing gives a test twice in a run on
// Windows: testing.fail_now raises a signal, and there the runner lets go of a lock it does not hold when it handles
// one, so that the next signal waits for ever.
stop_test :: proc(t: ^testing.T, message: string, loc: runtime.Source_Code_Location) -> ! {
	log.error(message, location = loc)
	testing.set_fail_timeout(t, 0, loc)
	for { time.sleep(time.Hour) }
}
