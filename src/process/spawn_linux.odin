package tk_process

// Linux's spawn: our own fork and exec (process-trees.md, "Every start"). Odin's os.process_start looks for a bare name
// in the current folder when PATH has none, and places only the three standard ends; the tree's keeper needs three
// more. In the child, between the fork and the exec, only system calls run: the other threads' locks are copies that
// nobody will open.

import "core:os"
import "core:strings"
import "core:sys/linux"

// The descriptors given to a child are moved above this before they are put in their places, so that no source is
// overwritten by another's target.
@(private = "file") SPAWN_SPARE_FD :: 16

// The file that runs `name`: a bare name looked for in the absolute folders of PATH (the child's when `env` is
// given, else this process's). In temp memory.
@(private)
resolve :: proc(name: string, env: []string) -> (path: string, ok: bool) {
	path_env := ""
	if env != nil {
		for e in env { if strings.has_prefix(e, "PATH=") { path_env = e[len("PATH="):] } }
	} else {
		path_env = os.get_env("PATH", context.temp_allocator)
	}
	return resolve_command(name, path_env, "", false, proc(p: string, _: rawptr) -> bool {
		cp := strings.clone_to_cstring(p, context.temp_allocator)
		st: linux.Stat
		if linux.stat(cp, &st) != .NONE || !linux.S_ISREG(st.mode) { return false }
		return linux.access(cp, linux.X_OK) == .NONE
	}, nil, context.temp_allocator)
}

// A plain child (start): its three ends, the file `resolved`, argv[0] as the caller wrote it.
@(private)
spawn :: proc(desc: os.Process_Desc, resolved: string) -> (p: os.Process, err: os.Error) {
	argv := cstrings(desc.command)
	envp := desc.env != nil ? cstrings(desc.env) : environment_cstrings()
	dir: cstring = desc.working_dir != "" ? strings.clone_to_cstring(desc.working_dir, context.temp_allocator) : nil
	null, nerr := linux.open("/dev/null", {.RDWR, .CLOEXEC})
	if nerr != .NONE { return {}, os.Platform_Error(nerr) }
	defer linux.close(null)
	fds := [3]linux.Fd{end_fd(desc.stdin, null), end_fd(desc.stdout, null), end_fd(desc.stderr, null)}
	pid, serr := spawn_raw(strings.clone_to_cstring(resolved, context.temp_allocator), argv, envp, dir, fds[:])
	if serr != .NONE { return {}, os.Platform_Error(serr) }
	return os.process_open(int(pid))
}

@(private)
end_fd :: proc(f: ^os.File, null: linux.Fd) -> linux.Fd { return f != nil ? linux.Fd(os.fd(f)) : null }

// A nil-terminated list of C strings in temp memory.
@(private)
cstrings :: proc(list: []string) -> [^]cstring {
	out := make([]cstring, len(list) + 1, context.temp_allocator)
	for s, i in list { out[i] = strings.clone_to_cstring(s, context.temp_allocator) }
	return raw_data(out)
}

@(private)
environment_cstrings :: proc() -> [^]cstring {
	env, _ := os.environ(context.temp_allocator)
	return cstrings(env)
}

// Forks; the child puts fds[i] at descriptor i, marks every other descriptor close-on-exec, moves to `dir` (nil:
// stays), and execs `path`. An error of the child before or at its exec comes back on a pipe, and the child is reaped.
@(private)
spawn_raw :: proc(path: cstring, argv: [^]cstring, envp: [^]cstring, dir: cstring, fds: []linux.Fd) -> (pid: linux.Pid, err: linux.Errno) {
	assert(len(fds) < SPAWN_SPARE_FD)
	report: [2]linux.Fd
	if e := linux.pipe2(&report, {.CLOEXEC}); e != .NONE { return 0, e }
	pid, err = linux.fork()
	if err != .NONE {
		linux.close(report[0]); linux.close(report[1])
		return 0, err
	}
	if pid == 0 {
		child_exec(path, argv, envp, dir, fds, report[1])
	}
	linux.close(report[1])
	code: i32
	n := 0
	for {
		r, e := linux.read(report[0], ([^]u8)(&code)[n:size_of(code)])
		if e == .EINTR { continue }
		if e != .NONE || r <= 0 { break }
		n += r
		if n == size_of(code) { break }
	}
	linux.close(report[0])
	if n == size_of(code) {
		// (the exec failed: the child is ended, reaped here)
		info: linux.Sig_Info
		for linux.waitid(.PID, linux.Id(pid), &info, {.WEXITED}, nil) == .EINTR {}
		return 0, linux.Errno(code)
	}
	return pid, .NONE
}

// The child's side, between the fork and the exec: system calls only.
@(private = "file")
child_exec :: proc "contextless" (path: cstring, argv: [^]cstring, envp: [^]cstring, dir: cstring, fds: []linux.Fd, report: linux.Fd) -> ! {
	fail :: proc "contextless" (report: linux.Fd, e: linux.Errno) -> ! {
		code := i32(e)
		linux.write(report, ([^]u8)(&code)[:size_of(code)])
		linux.exit_group(127)
	}
	// (each source above the targets first: a source may be another's target)
	out := report
	if out < SPAWN_SPARE_FD {
		moved, e := linux.fcntl(report, linux.F_DUPFD_CLOEXEC, SPAWN_SPARE_FD)
		if e != .NONE { fail(report, e) }
		out = moved
	}
	high: [SPAWN_SPARE_FD]linux.Fd
	for fd, i in fds {
		moved, e := linux.fcntl(fd, linux.F_DUPFD_CLOEXEC, SPAWN_SPARE_FD)
		if e != .NONE { fail(out, e) }
		high[i] = moved
	}
	for i in 0 ..< len(fds) {
		// (dup2 leaves the target open across the exec)
		if _, e := linux.dup2(high[i], linux.Fd(i)); e != .NONE { fail(out, e) }
	}
	// (what this process had open without close-on-exec stays here: a library's descriptor reaches no child.
	// Linux 5.11 and later; before, the child inherits them as with os.process_start)
	_ = linux.close_range(linux.Fd(len(fds)), max(linux.Fd), {.CLOEXEC})
	if dir != nil {
		if e := linux.chdir(dir); e != .NONE { fail(out, e) }
	}
	// (a mask and an ignored disposition survive the exec: the child starts as from a shell, not with the signals that
	// this thread blocks or that the toolkit ignores, SIGPIPE above all; as Rust's Command does. A handler resets
	// itself at the exec. Last before the exec: a signal let through earlier would run a handler of the program here)
	default_pipe: linux.Sig_Action
	default_pipe.special = .SIG_DFL
	_ = linux.rt_sigaction(.SIGPIPE, &default_pipe, nil)
	empty: linux.Sig_Set
	_ = linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)
	e := linux.execve(path, argv, envp)
	fail(out, e)
}
