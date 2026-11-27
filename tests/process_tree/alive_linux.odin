#+build linux
package process_tree_test

import "core:sys/linux"
import "core:time"

// Whether the process `pid` runs (a zombie has ended).
@(private)
alive :: proc(pid: int) -> bool {
	return !ends_within(pid, 0)
}

// Whether the process `pid` has ended, or ends within `bound`: its pidfd is readable then.
@(private)
ends_within :: proc(pid: int, bound: time.Duration) -> bool {
	fd, err := linux.pidfd_open(linux.Pid(pid), {})
	if err == .ESRCH { return true }
	if err != .NONE { return false }
	defer linux.close(linux.Fd(fd))
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(fd), events = {.IN}}}
	for {
		n, e := linux.poll(fds[:], i32(time.duration_milliseconds(bound)))
		if e == .EINTR { continue }
		return e == .NONE && n == 1
	}
}
