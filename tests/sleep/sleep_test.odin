// platform.precise_sleep and wait_slot: the wait of a frame's slot. Only that it lasts at least what was asked: how much longer
// depends on the machine, and on a loaded runner it says nothing.
//   odin test tests/sleep -vet
package sleep_test

import "core:testing"
import "core:time"
import "../../platform"

WAIT :: 3 * time.Millisecond
SLACK :: 200 * time.Microsecond

@(test)
precise_sleep_waits :: proc(t: ^testing.T) {
	start := time.tick_now()
	platform.precise_sleep(WAIT)
	testing.expect(t, time.tick_since(start) >= WAIT - SLACK, "it lasted what was asked")
	// twice on one thread: its timer is kept
	start = time.tick_now()
	platform.precise_sleep(WAIT)
	testing.expect(t, time.tick_since(start) >= WAIT - SLACK, "and again")
	platform.precise_sleep(0)
	platform.precise_sleep(-time.Second)
}

@(test)
wait_slot_without_a_window_sleeps :: proc(t: ^testing.T) {
	start := time.tick_now()
	platform.wait_slot(nil, WAIT)
	testing.expect(t, time.tick_since(start) >= WAIT - SLACK, "it lasted what was asked")
	platform.wait_slot(nil, 0)
}
