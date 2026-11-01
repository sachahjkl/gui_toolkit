#+build linux
package pacing_test

import "core:sys/posix"
import "core:thread"
import "core:time"
import "../../platform"
import "core:testing"

// A nested wait_handle with no limit waits for the handle, as on Windows (0 must not become poll's "do not wait").
@(private = "file") WRITER_COMES_AFTER :: 50 * time.Millisecond

@(test)
a_nested_wait_with_no_limit_waits :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.pipe(&fds) == .OK)
	defer { posix.close(fds[0]); posix.close(fds[1]) }
	w := platform.open_window_offscreen("nested wait", {16, 16})
	defer platform.destroy_window(w)
	th := thread.create_and_start_with_data(rawptr(uintptr(fds[1])), proc(data: rawptr) {
		time.sleep(WRITER_COMES_AFTER)   // (real time: what this proves is a wait that does not end by itself)
		b: u8 = 1
		posix.write(posix.FD(uintptr(data)), &b, 1)
	})
	defer { thread.join(th); thread.destroy(th) }
	w.in_poll = true   // (as inside a frame callback)
	defer w.in_poll = false
	testing.expect(t, platform.wait_handle(w, rawptr(uintptr(fds[0])), 0), "the handle was signaled")
}
