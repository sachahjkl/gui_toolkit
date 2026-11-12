package tk_process

// Another process, named by its pid and its start time (a pid is given again once its process ends: the pair names one
// process). Before it acts, each procedure pins the process twice: a pidfd (pidfd_open: what the signal goes through)
// and a descriptor of its folder /proc/<pid> (while it is open, it is that process's folder: once the process ends,
// every read through it fails with ESRCH, even when the pid names a new process). The start time is read through that
// folder and must be the same. A priority and an affinity are each thread's: the threads are listed through the same
// folder, and the pidfd says afterwards whether the process still runs.

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
	case .Quit:      return .SIGQUIT
	case .User1:     return .SIGUSR1
	case .User2:     return .SIGUSR2
	}
	return .SIGTERM
}

process_start_time :: proc(pid: i32) -> (start: u64, ok: bool) {
	buf: [64]u8
	dir, err := linux.open(proc_dir_path(buf[:], pid), {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return }
	defer linux.close(dir)
	return start_time_at(dir)
}

signal_process :: proc(pid: i32, start_time: u64, sig: Signal) -> (r: Act_Result, errno: int) {
	p, r1, e1 := pin(pid, start_time)
	if r1 != .Done { return r1, e1 }
	defer unpin(p)
	ret := linux.syscall(SYS_PIDFD_SEND_SIGNAL, p.fd, i32(linux_signal(sig)), uintptr(0), uintptr(0))
	if ret < 0 { return result_of(linux.Errno(-ret)), int(-ret) }
	return .Done, 0
}

set_priority :: proc(pid: i32, start_time: u64, nice: int) -> (r: Act_Result, errno: int) {
	// (the nice value is each thread's: setpriority on the pid sets the main thread's alone)
	Nice :: struct { value: i32 }
	n := Nice{i32(nice)}
	return each_thread(pid, start_time, &n, proc(tid: i32, user: rawptr) -> linux.Errno {
		return linux.setpriority(.PROCESS, tid, (^Nice)(user).value)
	})
}

affinity :: proc(pid: i32, start_time: u64) -> (cpus: Cpu_Set, r: Act_Result, errno: int) {
	p, r1, e1 := pin(pid, start_time)
	if r1 != .Done { return {}, r1, e1 }
	defer unpin(p)
	if _, err := linux.sched_getaffinity(linux.Pid(pid), size_of(cpus.words), &cpus.words); err != .NONE { return {}, result_of(err), int(err) }
	// (read after the pin: the pid may have been given again in between, which the pidfd tells)
	if !still_running(p) { return {}, .Gone, 0 }
	return cpus, .Done, 0
}

set_affinity :: proc(pid: i32, start_time: u64, cpus: Cpu_Set) -> (r: Act_Result, errno: int) {
	if cpu_set_count(cpus) == 0 { return .Failed, int(linux.Errno.EINVAL) }
	c := cpus
	return each_thread(pid, start_time, &c, proc(tid: i32, user: rawptr) -> linux.Errno {
		set := (^Cpu_Set)(user)
		_, e := linux.sched_setaffinity(linux.Pid(tid), size_of(set.words), &set.words)
		return e
	})
}

// The process, pinned: its pidfd and its folder in /proc.
@(private = "file")
Pinned :: struct { fd: i32, dir: linux.Fd }

// The process `pid`, pinned, once its start time read through its own folder is `start_time`.
@(private = "file")
pin :: proc(pid: i32, start_time: u64) -> (p: Pinned, r: Act_Result, errno: int) {
	if pid <= 0 { return {}, .Gone, 0 }
	pfd, err := linux.pidfd_open(linux.Pid(pid), {})
	if err != .NONE { return {}, result_of(err), int(err) }
	buf: [64]u8
	dir, derr := linux.open(proc_dir_path(buf[:], pid), {.DIRECTORY, .CLOEXEC})
	if derr != .NONE {
		linux.close(linux.Fd(pfd))
		return {}, result_of(derr), int(derr)
	}
	p = {i32(pfd), dir}
	start, ok := start_time_at(dir)
	if !ok || start != start_time {
		unpin(p)
		return {}, .Gone, 0
	}
	return p, .Done, 0
}

@(private = "file")
unpin :: proc(p: Pinned) {
	linux.close(linux.Fd(p.fd))
	linux.close(p.dir)
}

// Whether the pinned process has not ended: its pidfd is readable once it has.
@(private = "file")
still_running :: proc(p: Pinned) -> bool {
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(p.fd), events = {.IN}}}
	n, err := linux.poll(fds[:], 0)
	return err == .NONE && n == 0
}

// `act` on each thread of the process (pid, start_time), listed through its own folder. Then the pidfd says whether it
// still runs: when it ended in between, its thread ids may name another process's threads now, and the answer is Gone.
@(private = "file")
each_thread :: proc(pid: i32, start_time: u64, user: rawptr, act: proc(tid: i32, user: rawptr) -> linux.Errno) -> (r: Act_Result, errno: int) {
	p, r1, e1 := pin(pid, start_time)
	if r1 != .Done { return r1, e1 }
	defer unpin(p)
	tasks, oerr := linux.openat(p.dir, "task", {.DIRECTORY, .CLOEXEC})
	if oerr != .NONE { return result_of(oerr), int(oerr) }
	defer linux.close(tasks)
	set := 0
	names: [TASK_LIST_BYTES]u8
	for {
		n, derr := linux.getdents(tasks, names[:])
		if derr != .NONE { return result_of(derr), int(derr) }
		if n <= 0 { break }
		off := 0
		for d in linux.dirent_iterate_buf(names[:n], &off) {
			tid, is_num := strconv.parse_int(linux.dirent_name(d), 10)
			if !is_num { continue }
			// (a thread that ended since the list was read: nothing left to set)
			if e := act(i32(tid), user); e != .NONE && e != .ESRCH { return result_of(e), int(e) }
			set += 1
		}
	}
	if set == 0 || !still_running(p) { return .Gone, 0 }
	return .Done, 0
}

// The start time of the process whose /proc folder is `dir`.
@(private = "file")
start_time_at :: proc(dir: linux.Fd) -> (start: u64, ok: bool) {
	fd, err := linux.openat(dir, "stat", {.CLOEXEC})
	if err != .NONE { return }
	defer linux.close(fd)
	text: [STAT_BYTES]u8
	total := 0
	for total < len(text) {
		n, rerr := linux.read(fd, text[total:])
		if rerr != .NONE { return }
		if n == 0 { break }
		total += n
	}
	if total <= 0 { return }
	return parse_start_time(string(text[:total]))
}

@(private = "file")
result_of :: proc(e: linux.Errno) -> Act_Result {
	#partial switch e {
	case .ESRCH, .ENOENT: return .Gone
	case .EPERM, .EACCES: return .Denied
	}
	return .Failed
}

// "/proc/<pid>" as a C string in `buf`.
@(private = "file")
proc_dir_path :: proc(buf: []u8, pid: i32) -> cstring {
	b := strings.builder_from_bytes(buf[:len(buf) - 1])
	strings.write_string(&b, "/proc/")
	strings.write_int(&b, int(pid))
	n := strings.builder_len(b)
	buf[n] = 0
	return cstring(&buf[0])
}
