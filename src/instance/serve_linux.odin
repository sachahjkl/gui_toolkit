package tk_instance

import "core:sys/linux"

// An eventfd: serve_stop writes it, the thread's poll wakes.
@(private)
Wake :: struct { fd: linux.Fd }

@(private)
wake_make :: proc(w: ^Wake) -> bool {
	fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE { return false }
	w.fd = fd
	return true
}

@(private)
wake_ring :: proc(w: ^Wake) {
	one: u64 = 1
	linux.write(w.fd, ([^]u8)(&one)[:size_of(one)])
}

@(private)
wake_free :: proc(w: ^Wake) { linux.close(w.fd) }

// Until a start connects or serve_stop rings.
@(private)
serve_wait :: proc(s: ^Server) {
	fds := [2]linux.Poll_Fd{{fd = s.owner.listen, events = {.IN}}, {fd = s.wake.fd, events = {.IN}}}
	linux.poll(fds[:], -1)
}
