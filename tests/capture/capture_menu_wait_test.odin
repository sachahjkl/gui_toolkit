// The Windows backend's bounded wait for a popup menu to leave the screen (win32_wait_until_gone), driven by a fake
// clock and a fake menu: no real sleep, no desktop, every system.
package capture_test

import "core:testing"
import "gt:capture"

@(private = "file")
Fake :: struct {
	now:     i64,   // ms
	gone_at: i64,   // the menu is present while now < gone_at
	looks:   int,
	slept:   i64,
}

@(private = "file")
fake_steps :: proc(fake: ^Fake) -> capture.Win32_Wait_Steps {
	return capture.Win32_Wait_Steps{
		present = proc(data: rawptr) -> bool {
			f := (^Fake)(data)
			f.looks += 1
			return f.now < f.gone_at
		},
		now_ms = proc(data: rawptr) -> i64 { return (^Fake)(data).now },
		sleep  = proc(data: rawptr, ms: i64) {
			f := (^Fake)(data)
			f.now += ms
			f.slept += ms
		},
		data = fake,
	}
}

// No menu: one look, no sleep, nothing seen (so no DwmFlush either).
@(test)
no_menu_returns_at_once :: proc(t: ^testing.T) {
	f := Fake{}
	seen, gone := capture.win32_wait_until_gone(fake_steps(&f), 400, 10)
	testing.expect(t, !seen)
	testing.expect(t, gone)
	testing.expect_value(t, f.looks, 1)
	testing.expect_value(t, f.slept, i64(0))
}

// A menu that fades out for 200 ms: the wait ends at the first look after it went, well before the bound.
@(test)
a_fading_menu_is_waited_for :: proc(t: ^testing.T) {
	f := Fake{gone_at = 200}
	seen, gone := capture.win32_wait_until_gone(fake_steps(&f), 400, 10)
	testing.expect(t, seen)
	testing.expect(t, gone)
	testing.expect_value(t, f.now, i64(200))
}

// A menu that never leaves: the wait ends at the bound, not one sleep past it, and says the menu is still there.
@(test)
a_menu_that_stays_ends_at_the_bound :: proc(t: ^testing.T) {
	f := Fake{gone_at = max(i64)}
	seen, gone := capture.win32_wait_until_gone(fake_steps(&f), 400, 30)
	testing.expect(t, seen)
	testing.expect(t, !gone)
	testing.expect_value(t, f.now, i64(400))
}
