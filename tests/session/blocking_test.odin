package session_test

// A call that waits on the system in a frame is counted by the session (the test fails at its end for it, unless the
// test allows it); one made by the test between frames is not. Run with TOOLKIT_BLOCKING_CHECK (run_tests'
// session_blocking): without the check nothing is counted.

import "core:os"
import "core:testing"
import base "gt:base"
import "gt:fsx"
import "gt:testkit/session"

@(private = "file") Blocking_Run :: struct { read: bool }

@(test)
a_frame_that_waits_on_the_system_is_counted :: proc(t: ^testing.T) {
	when !base.BLOCKING_CHECK { return }
	r: Blocking_Run
	s := session.start(t, {size = {200, 100}, user = &r, build = proc(s: ^session.Session) {
		r := (^Blocking_Run)(s.user)
		if r.read { _, _ = fsx.read_all(os.args[0], context.temp_allocator) }   // (a disk read in a build)
	}})
	session.frames(s, 2)
	testing.expect_value(t, s.blocking, 0)
	// the test's own read, between frames: not the interface's
	_, _ = fsx.read_all(os.args[0], context.temp_allocator)
	session.frames(s, 1)
	testing.expect_value(t, s.blocking, 0)
	r.read = true
	session.frame(s)
	r.read = false
	testing.expect_value(t, s.blocking, 1)
	session.allow_blocking(s)   // (this one is the point of the test: its end does not fail)
}
