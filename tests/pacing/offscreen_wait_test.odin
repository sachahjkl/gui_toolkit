package pacing_test

import "core:testing"
import "core:time"
import "../../platform"

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
