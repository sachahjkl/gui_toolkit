package host_test

// A window opened ahead (host.ahead_due): with a window there, due at once and once only; with none, the driver is made
// on a thread first, its end wakes the loop, and then it is due.

import "core:sync"
import "core:testing"
import "core:time"
import host "gt:host"
import "gt:render"

@(test)
a_window_ahead_is_due_once :: proc(t: ^testing.T) {
	sh: host.Shared
	h: host.Host
	sh.main = &h   // (a window is there: the driver is made)
	a: host.Ahead
	testing.expect(t, host.ahead_due(&a, &sh), "due at once")
	testing.expect(t, !host.ahead_due(&a, &sh), "once only")
}

@(test)
with_no_window_the_driver_comes_first :: proc(t: ^testing.T) {
	if render.device_preload_state() != .Not_Started { return }   // (another test's device: nothing to see here)
	defer render.release_preloaded_device()
	sh: host.Shared
	a: host.Ahead
	woken: i32
	wake :: proc(user: rawptr) { sync.atomic_store((^i32)(user), 1) }
	testing.expect(t, !host.ahead_due(&a, &sh, wake, &woken), "not before the driver")
	testing.expect(t, render.device_preload_state() != .Not_Started, "the driver is being made on a thread")
	// (made or failed, its end wakes the loop; a failed one is made again by the window, which then opens)
	until := time.tick_add(time.tick_now(), 60 * time.Second)
	for sync.atomic_load(&woken) == 0 && time.tick_diff(time.tick_now(), until) > 0 { time.sleep(time.Millisecond) }
	testing.expect(t, sync.atomic_load(&woken) == 1, "its end woke the loop")
	testing.expect(t, host.ahead_due(&a, &sh, wake, &woken), "then due")
	testing.expect(t, !host.ahead_due(&a, &sh, wake, &woken), "once only")
}
