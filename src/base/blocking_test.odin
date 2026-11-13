package gt_base

import "core:testing"
import "core:thread"

// A blocking call is counted on a thread that builds an interface, never on another.
@(test)
a_blocking_call_is_counted_on_the_interfaces_thread_only :: proc(t: ^testing.T) {
	when !BLOCKING_CHECK { return }
	before := blocking_count()
	th := thread.create_and_start(proc() {
		// (a worker: not marked)
		blocking("worker read")
	})
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, blocking_count(), before)
	th = thread.create_and_start(proc() {
		interface_thread_mark()
		blocking("interface read")
		blocking("interface read")
	})
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, blocking_count(), before + 2)
}
