#+build !windows
package tk_session

import "base:runtime"
import "core:testing"

// Ends the test here: the runner reports it failed, with its message at the place given, and goes on with the next test
// at once (testing.fail_now: its deferred statements do not run). Windows has its own way (stop_windows.odin).
stop_test :: proc(t: ^testing.T, message: string, loc: runtime.Source_Code_Location) -> ! {
	testing.fail_now(t, message, loc)
}
