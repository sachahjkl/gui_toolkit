package tk_rpc

// The watch's wait and the readers' reads on Windows (rpc.md, "The threads"): the watch waits on the child's process
// handle and an event. No process leaves the tree's job, so the job's end closes every pipe: the readers block in
// ReadFile.

import "core:os"
import win "core:sys/windows"
import "core:time"

@(private)
Waker :: struct {
	event: win.HANDLE,   // auto-reset: set, the watch has something to do
}

@(private)
Wait_Result :: enum u8 { Ended, Woken, Timed_Out }

@(private)
waker_make :: proc(w: ^Waker) -> bool {
	w.event = win.CreateEventW(nil, false, false, nil)
	return w.event != nil
}

@(private)
waker_destroy :: proc(w: ^Waker) {
	if w.event != nil { win.CloseHandle(w.event) }
	w^ = {}
}

@(private)
waker_wake :: proc(w: ^Waker) { win.SetEvent(w.event) }

@(private)
waker_wait :: proc(w: ^Waker, handle: uintptr, timeout: time.Duration) -> Wait_Result {
	handles := [2]win.HANDLE{w.event, win.HANDLE(handle)}
	count := win.DWORD(handle != 0 ? 2 : 1)
	ms := win.INFINITE
	if timeout >= 0 { ms = win.DWORD(min(time.duration_milliseconds(timeout) + 1, f64(win.INFINITE - 1))) }
	switch win.WaitForMultipleObjects(count, raw_data(handles[:]), false, ms) {
	case win.WAIT_OBJECT_0:     return .Woken
	case win.WAIT_OBJECT_0 + 1: return .Ended
	case win.WAIT_TIMEOUT:      return .Timed_Out
	}
	return .Ended
}

@(private)
pipes_stop :: proc(w: ^Waker) {}

// (no process leaves the job: the job's end breaks every write)
@(private)
writer_prepare :: proc(f: ^os.File) {}

@(private)
write_pipe :: proc(w: ^Waker, f: ^os.File, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		n, err := os.write(f, rest)
		if err != nil || n <= 0 { return false }
		rest = rest[n:]
	}
	return true
}

@(private)
read_pipe :: proc(w: ^Waker, f: ^os.File, buf: []u8) -> int {
	n, err := os.read(f, buf)
	if err != nil { return 0 }
	return n
}
