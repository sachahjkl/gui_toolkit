#+build linux
package platform

import "base:runtime"
import "core:sys/posix"
import "core:testing"
import "core:time"

// A pipe for a read of the clipboard: ours does not wait, the owner's end is a pipe as it is (blocking). Both ends non-blocking,
// an owner that writes a large picture and stops at EAGAIN gave only what the pipe held.
@(test)
a_clipboard_read_pipe_leaves_the_owner_a_blocking_end :: proc(t: ^testing.T) {
	read, write, ok := wl_read_pipe()
	if !testing.expect(t, ok) { return }
	defer { posix.close(read); posix.close(write) }
	testing.expect(t, posix.fcntl(read, .GETFL) & WL_O_NONBLOCK != 0, "ours does not wait")
	testing.expect(t, posix.fcntl(write, .GETFL) & WL_O_NONBLOCK == 0, "the owner's is blocking")
}

// What the toolkit sends on the clipboard (a large picture) comes whole to a reader that made the pipe non-blocking, both ends,
// and drains it slowly: the write was cut at the first EAGAIN.
@(test)
a_large_flavour_is_sent_whole_through_a_non_blocking_pipe :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fds: [2]posix.FD
	if !testing.expect(t, posix.pipe(&fds) == .OK) { return }
	for fd in fds { posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | WL_O_NONBLOCK) }
	data := make([]u8, 1 << 20)
	defer delete(data)
	for i in 0 ..< len(data) { data[i] = u8(i * 7) }
	wl_fd_send(i32(fds[1]), data)   // (it closes the write end once all is written)
	got := make([dynamic]u8, 0, len(data))
	defer { delete(got); posix.close(fds[0]) }
	chunk: [16384]u8
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 10 {
		n := posix.read(fds[0], &chunk[0], len(chunk))
		if n > 0 { append(&got, ..chunk[:n]); time.sleep(2 * time.Millisecond); continue }   // (a reader slower than the writer)
		if n == 0 { break }   // (the end: the writer closed its end)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(got), len(data))
	testing.expect(t, string(got[:]) == string(data), "as it was")
}
