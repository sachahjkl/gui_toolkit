package pacing_test

import "core:testing"
import "core:time"
import "../../src/platform"

// What the last poll handed out has been read: it is no reason not to wait for more.
@(test)
a_wait_does_not_end_on_events_already_handed_out :: proc(t: ^testing.T) {
	w := platform.open_window_offscreen("wait", {16, 16})
	testing.expect(t, w != nil)
	if w == nil { return }
	defer platform.destroy_window(w)
	platform.inject_event(w, platform.Event{kind = .Key_Press, key = .A})
	testing.expect_value(t, len(platform.poll_events(w, false)), 1)
	start := time.tick_now()
	platform.wait_event(w, 200)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) >= 150, "the wait takes its time")
	platform.inject_event(w, platform.Event{kind = .Key_Press, key = .B})
	start = time.tick_now()
	platform.wait_event(w, 5000)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 2000, "new input ends it")
}

// A loop that draws several windows sleeps once for all of them: input for any of them ends the sleep, not only the
// first's (host.hosts_wait).
@(test)
a_wait_for_several_windows_ends_on_any_of_them :: proc(t: ^testing.T) {
	a := platform.open_window_offscreen("first", {16, 16})
	b := platform.open_window_offscreen("second", {16, 16})
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil { return }
	defer platform.destroy_window(a)
	defer platform.destroy_window(b)
	ws := []^platform.Window{a, b}
	start := time.tick_now()
	platform.wait_event_any(ws, 200)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) >= 150, "with nothing for either, the wait takes its time")
	platform.inject_event(b, platform.Event{kind = .Key_Press, key = .B})
	start = time.tick_now()
	platform.wait_event_any(ws, 5000)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 2000, "input for the second ends it")
	platform.wait_event_any(nil, 5000)   // (no window: no wait)
}
