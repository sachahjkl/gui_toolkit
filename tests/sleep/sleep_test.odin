// platform.precise_sleep: a wait of a frame's slot. Only that it lasts at least what was asked: how much longer depends on the
// machine, and on a loaded runner it says nothing.
//   odin test tests/sleep -vet
package sleep_test

import "core:testing"
import "core:time"
import "../../platform"

@(test)
precise_sleep_waits :: proc(t: ^testing.T) {
	WAIT :: 3 * time.Millisecond
	start := time.tick_now()
	platform.precise_sleep(WAIT)
	testing.expect(t, time.tick_since(start) >= WAIT - 200 * time.Microsecond, "it lasted what was asked")
	// twice on one thread: its timer is kept
	start = time.tick_now()
	platform.precise_sleep(WAIT)
	testing.expect(t, time.tick_since(start) >= WAIT - 200 * time.Microsecond, "and again")
	platform.precise_sleep(0)
	platform.precise_sleep(-time.Second)
}
