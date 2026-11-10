package tk_process

// Another process, named by its pid and its start time (a pid is given again once its process ends: the pair names one
// process). Before it acts, each procedure pins the pid with a pidfd (pidfd_open: while the descriptor is open, the pid
// cannot name another process), reads the start time again from /proc/<pid>/stat, and acts only when it is the same.

import "core:strconv"
import "core:strings"
import "core:sys/linux"

// The pidfd's own signal call (core:sys/linux has no wrapper for it).
@(private = "file") SYS_PIDFD_SEND_SIGNAL :: uintptr(424)
// /proc/<pid>/stat and the names of /proc/<pid>/task: one read is enough.
@(private = "file") STAT_BYTES :: 1024
@(private = "file") TASK_LIST_BYTES :: 16 * 1024

@(private = "file")
linux_signal :: proc(sig: Signal) -> linux.Signal {
	switch sig {
	case .Terminate: return .SIGTERM
	case .Kill:      return .SIGKILL
	case .Stop:      return .SIGSTOP
	case .Continue:  return .SIGCONT
	case .Hangup:    return .SIGHUP
	case .Interrupt: return .SIGINT
	}
	return .SIGTERM
}

process_start_time :: proc(pid: i32) -> (start: u64, ok: bool) {
	buf: [64]u8
	path := proc_path(buf[:], pid, "stat")
	text: [STAT_BYTES]u8
	n := read_file(path, text[:])
	if n <= 0 { return }
	return parse_start_time(string(text[:n]))
}

signal_process :: proc(pid: i32, start_time: u64, sig: Signal) -> (r: Act_Result, errno: int) {
	fd, r1, e1 := pin(pid, start_time)
	if r1 != .Done { return r1, e1 }
	defer linux.close(linux.Fd(fd))
	ret := linux.syscall(SYS_PIDFD_SEND_SIGNAL, fd, i32(linux_signal(sig)), uintptr(0), uintptr(0))
	if ret < 0 { return result_of(linux.Errno(-ret)), int(-ret) }
	return .Done, 0
}

set_priority :: proc(pid: i32, start_time: u64, nice: int) -> (r: Act_Result, errno: int) {
	fd, r1, e1 := pin(pid, start_time)
	if r1 != .Done { return r1, e1 }
	defer linux.close(linux.Fd(fd))
	// (the nice value is each thread's: setpriority on the pid sets the main thread's alone)
	buf: [64]u8
	dir := proc_path(buf[:], pid, "task")
	dfd, oerr := linux.open(strings.clone_to_cstring(dir, context.temp_allocator), {.DIRECTORY})
	if oerr != .NONE { return result_of(oerr), int(oerr) }
	defer linux.close(dfd)
	set := 0
	names: [TASK_LIST_BYTES]u8
	for {
		n, derr := linux.getdents(dfd, names[:])
		if derr != .NONE { return result_of(derr), int(derr) }
		if n <= 0 { break }
		off := 0
		for d in linux.dirent_iterate_buf(names[:n], &off) {
			tid, is_num := strconv.parse_int(linux.dirent_name(d), 10)
			if !is_num { continue }
			// (a thread that ended since the list was read: nothing left to set)
			if e := linux.setpriority(.PROCESS, i32(tid), i32(nice)); e != .NONE && e != .ESRCH { return result_of(e), int(e) }
			set += 1
		}
	}
	return set > 0 ? .Done : .Gone, 0
}

// The pidfd of `pid`, once its start time is `start_time`.
@(private = "file")
pin :: proc(pid: i32, start_time: u64) -> (fd: i32, r: Act_Result, errno: int) {
	if pid <= 0 { return -1, .Gone, 0 }
	pfd, err := linux.pidfd_open(linux.Pid(pid), {})
	if err != .NONE { return -1, result_of(err), int(err) }
	start, ok := process_start_time(pid)
	if !ok || start != start_time {
		linux.close(linux.Fd(pfd))
		return -1, .Gone, 0
	}
	return i32(pfd), .Done, 0
}

@(private = "file")
result_of :: proc(e: linux.Errno) -> Act_Result {
	#partial switch e {
	case .ESRCH, .ENOENT: return .Gone
	case .EPERM, .EACCES: return .Denied
	}
	return .Failed
}

@(private = "file")
proc_path :: proc(buf: []u8, pid: i32, name: string) -> string {
	b := strings.builder_from_bytes(buf)
	strings.write_string(&b, "/proc/")
	strings.write_int(&b, int(pid))
	strings.write_byte(&b, '/')
	strings.write_string(&b, name)
	return strings.to_string(b)
}

// The bytes of a small file of /proc, -1 when it cannot be read.
@(private = "file")
read_file :: proc(path: string, buf: []u8) -> int {
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {})
	if err != .NONE { return -1 }
	defer linux.close(fd)
	total := 0
	for total < len(buf) {
		n, rerr := linux.read(fd, buf[total:])
		if rerr != .NONE { return -1 }
		if n == 0 { break }
		total += n
	}
	return total
}
