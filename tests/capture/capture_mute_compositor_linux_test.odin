#+build linux
package capture_test

// (the tag: Odin reads a system only at the very end of a file's name, `_linux.odin`; `_linux_test.odin` is compiled
// everywhere, and its sys/linux calls are Linux's)

// A compositor that never answers: a socket that listens and says nothing. Opening a session on it gives up within a
// bound, instead of holding its thread for good (a program's worker, and every capture after it).

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import "gt:capture"

// The bound of the whole open: a round trip waits two seconds at most, an open makes two.
@(private = "file") MUTE_BOUND :: 10 * time.Second

@(private = "file")
Mute_Open :: struct {
	done: bool,   // atomic
	err:  capture.Error,
}

@(test)
a_mute_compositor_is_given_up :: proc(t: ^testing.T) {
	// the socket: accepted by the kernel's backlog, never read
	path := fmt.tprintf("/tmp/gt-mute-wayland-%d", linux.getpid())
	_ = os.remove(path)
	defer os.remove(path)
	fd, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	testing.expect_value(t, serr, linux.Errno.NONE)
	if serr != .NONE { return }
	defer linux.close(fd)
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	testing.expect_value(t, linux.bind(fd, &addr), linux.Errno.NONE)
	testing.expect_value(t, linux.listen(fd, 8), linux.Errno.NONE)

	// only this compositor: no X server, no portal to fall back on
	saved := [3]string{"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS"}
	before: [3]string
	for name, i in saved { before[i] = os.get_env(name, context.temp_allocator) }
	defer for name, i in saved { if before[i] != "" { os.set_env(name, before[i]) } else { os.unset_env(name) } }
	os.set_env("WAYLAND_DISPLAY", path)
	os.unset_env("DISPLAY")
	os.set_env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/gt-mute-bus")

	m: Mute_Open
	th := thread.create_and_start_with_data(&m, proc(data: rawptr) {
		m := (^Mute_Open)(data)
		s, err := capture.open()
		capture.close(s)
		m.err = err
		sync.atomic_store(&m.done, true)
	})
	start := time.tick_now()
	for !sync.atomic_load(&m.done) && time.tick_since(start) < MUTE_BOUND { time.sleep(10 * time.Millisecond) }
	finished := sync.atomic_load(&m.done)
	testing.expect(t, finished, "the open gives up on a compositor that never answers")
	if !finished { return }   // (the thread stays: it holds the connection it waits on)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, m.err, capture.Error.Unsupported)
}
