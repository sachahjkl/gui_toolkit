// The auto-repeat of a held key (platform/key_repeat.odin), for a system that leaves it to the client: a delay, then a
// rate; only the last key pressed repeats; missed repeats are dropped. The clock is a number.
//   odin test tests/key_repeat -vet
package key_repeat_test

import "core:testing"
import "../../platform"

@(test)
a_held_key_repeats_after_the_delay_at_the_rate :: proc(t: ^testing.T) {
	r := platform.Key_Repeat{rate = 25, delay_ms = 600}
	testing.expect_value(t, platform.key_repeat_wait_ms(&r, 0), -1)
	platform.key_repeat_press(&r, 30, 1000)
	testing.expect_value(t, platform.key_repeat_wait_ms(&r, 1000), 600)
	testing.expect(t, !platform.key_repeat_take(&r, 1599))
	testing.expect(t, platform.key_repeat_take(&r, 1600))
	testing.expect(t, !platform.key_repeat_take(&r, 1600), "once")
	testing.expect_value(t, platform.key_repeat_wait_ms(&r, 1600), 40)   // 1000 / 25
	testing.expect(t, !platform.key_repeat_take(&r, 1639))
	testing.expect(t, platform.key_repeat_take(&r, 1640))
	testing.expect_value(t, platform.key_repeat_wait_ms(&r, 2000), 0)
}

@(test)
only_the_key_that_repeats_stops_it :: proc(t: ^testing.T) {
	r := platform.Key_Repeat{rate = 10, delay_ms = 100}
	platform.key_repeat_press(&r, 1, 0)
	platform.key_repeat_press(&r, 2, 50)   // the last one pressed takes over, its delay from now
	testing.expect_value(t, r.code, u32(2))
	testing.expect(t, !platform.key_repeat_take(&r, 100))
	platform.key_repeat_release(&r, 1)
	testing.expect(t, platform.key_repeat_take(&r, 150), "an older key going up changes nothing")
	platform.key_repeat_release(&r, 2)
	testing.expect(t, !platform.key_repeat_take(&r, 1000))
	testing.expect_value(t, platform.key_repeat_wait_ms(&r, 1000), -1)
}

@(test)
a_rate_of_zero_is_no_repeat :: proc(t: ^testing.T) {
	r := platform.Key_Repeat{rate = 0, delay_ms = 100}
	platform.key_repeat_press(&r, 1, 0)
	testing.expect(t, !platform.key_repeat_take(&r, 1000))
	testing.expect_value(t, platform.key_repeat_wait_ms(&r, 1000), -1)
}

@(test)
a_stall_makes_no_burst :: proc(t: ^testing.T) {
	r := platform.Key_Repeat{rate = 10, delay_ms = 100}
	platform.key_repeat_press(&r, 1, 0)
	n := 0
	for platform.key_repeat_take(&r, 5000) { n += 1 }
	testing.expect_value(t, n, 1)
	testing.expect_value(t, platform.key_repeat_wait_ms(&r, 5000), 100)
}
