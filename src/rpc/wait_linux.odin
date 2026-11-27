package tk_rpc

// The watch's wait and the readers' reads on Linux (rpc.md, "The threads"): the watch polls the keeper's pidfd and a
// wake pipe; the readers and the writer poll their pipe and the stop pipe, whose write end the watch closes to release
// them from a process that left the tree.

import "core:os"
import "core:sys/linux"
import "core:time"

@(private)
Waker :: struct {
	wake:  [2]linux.Fd,   // a byte: the watch has something to do
	stops: [2]linux.Fd,   // its write end closed: the readers and the writer stop
}

@(private)
Wait_Result :: enum u8 { Ended, Woken, Timed_Out }

@(private)
waker_make :: proc(w: ^Waker) -> bool {
	if linux.pipe2(&w.wake, {.CLOEXEC, .NONBLOCK}) != .NONE { return false }
	if linux.pipe2(&w.stops, {.CLOEXEC}) != .NONE {
		linux.close(w.wake[0]); linux.close(w.wake[1])
		return false
	}
	return true
}

@(private)
waker_destroy :: proc(w: ^Waker) {
	linux.close(w.wake[0]); linux.close(w.wake[1])
	linux.close(w.stops[0])
	if w.stops[1] >= 0 { linux.close(w.stops[1]) }
	w^ = {}
}

@(private)
waker_wake :: proc(w: ^Waker) {
	b := [1]u8{1}
	_, _ = linux.write(w.wake[1], b[:])   // (a full pipe is already a wake)
}

// Waits for the end of the process whose pidfd is `handle` (0: none), a wake or the timeout (negative: none).
@(private)
waker_wait :: proc(w: ^Waker, handle: uintptr, timeout: time.Duration) -> Wait_Result {
	fds := [2]linux.Poll_Fd{{fd = w.wake[0], events = {.IN}}, {fd = linux.Fd(handle), events = {.IN}}}
	count := handle != 0 ? 2 : 1
	ms := i32(-1)
	if timeout >= 0 { ms = i32(min(time.duration_milliseconds(timeout) + 1, f64(max(i32)))) }
	n, e := linux.poll(fds[:count], ms)
	if e == .EINTR { return .Woken }
	if e != .NONE { return .Ended }
	if n == 0 { return .Timed_Out }
	if count == 2 && fds[1].revents != {} { return .Ended }
	drain: [64]u8
	for {
		r, re := linux.read(w.wake[0], drain[:])
		if re != .NONE || r < len(drain) { break }
	}
	return .Woken
}

// The readers and the writer stop waiting: what holds their pipes is not the tree's.
@(private)
pipes_stop :: proc(w: ^Waker) {
	if w.stops[1] < 0 { return }
	linux.close(w.stops[1])
	w.stops[1] = -1
}

// The child's input without blocking, so that a write waits in write_pipe's poll, where pipes_stop releases it. A
// blocking write to a full pipe whose reader left the tree (a daemon that kept its input) would never return, and
// destroy would wait on the writer for ever. The child's end is a description of its own: it still blocks.
@(private)
writer_prepare :: proc(f: ^os.File) {
	fd := linux.Fd(os.fd(f))
	flags, e := linux.fcntl(fd, linux.F_GETFL)
	if e != .NONE { return }
	_ = linux.fcntl(fd, linux.F_SETFL, flags + {.NONBLOCK})
}

// Writes all of `data`; false when the pipe is closed or the reads are stopped (a process that left the tree holds the
// read end and reads nothing).
@(private)
write_pipe :: proc(w: ^Waker, f: ^os.File, data: []u8) -> bool {
	fd := linux.Fd(os.fd(f))
	rest := data
	for len(rest) > 0 {
		fds := [2]linux.Poll_Fd{{fd = fd, events = {.OUT}}, {fd = w.stops[0], events = {.IN}}}
		_, e := linux.poll(fds[:], -1)
		if e == .EINTR { continue }
		if e != .NONE || fds[1].revents != {} { return false }
		n, we := linux.write(fd, rest)
		if we == .EINTR || we == .EAGAIN { continue }
		if we != .NONE || n <= 0 { return false }
		rest = rest[n:]
	}
	return true
}

// Reads what the pipe has; 0 at its end or once the reads are stopped.
@(private)
read_pipe :: proc(w: ^Waker, f: ^os.File, buf: []u8) -> int {
	fd := linux.Fd(os.fd(f))
	for {
		fds := [2]linux.Poll_Fd{{fd = fd, events = {.IN}}, {fd = w.stops[0], events = {.IN}}}
		_, e := linux.poll(fds[:], -1)
		if e == .EINTR { continue }
		if e != .NONE || fds[1].revents != {} { return 0 }
		n, re := linux.read(fd, buf)
		if re == .EINTR || re == .EAGAIN { continue }
		if re != .NONE { return 0 }
		return n
	}
}
