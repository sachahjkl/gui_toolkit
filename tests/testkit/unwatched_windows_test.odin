#+build windows
package testkit_test

import "core:sync"
import "core:testing"
import "gt:testkit/unwatched"

// What the body and its cleanup saw (the body has no data of its own: it comes in the context).
@(private = "file")
Seen :: struct {
	body:    int,    // the body's thread
	cleanup: int,    // the thread its cleanup ran on
	after:   bool,   // the body went on after end_body
	held:    ^int,   // freed by the cleanup: the runner reports a leak when it does not run
}

// A body ended by end_body (what a session's failure does on Windows): its cleanup runs on its thread, the thread is
// joined and freed (the runner reports the Thread as a leak if not), and run returns at once on the test's thread.
@(test)
a_body_ended_early_ends_its_thread :: proc(t: ^testing.T) {
	seen: Seen
	context.user_ptr = &seen
	unwatched.run(t, proc(t: ^testing.T) {
		seen := (^Seen)(context.user_ptr)
		seen.body = sync.current_thread_id()
		seen.held = new(int)
		testing.cleanup(t, proc(p: rawptr) {
			seen := (^Seen)(p)
			seen.cleanup = sync.current_thread_id()
			free(seen.held)
		}, seen)
		unwatched.end_body(t)
		seen.after = true
	})
	testing.expect(t, !seen.after, "the body ends at end_body")
	testing.expect(t, seen.body != sync.current_thread_id(), "the body ran on a thread of its own")
	testing.expect_value(t, seen.cleanup, seen.body)
}

// end_body outside a body does nothing: the caller ends the test its own way.
@(test)
end_body_outside_a_body_returns :: proc(t: ^testing.T) {
	unwatched.end_body(t)
}
