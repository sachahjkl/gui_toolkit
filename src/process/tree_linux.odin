package tk_process

// The tree on Linux (process-trees.md, "Linux: a keeper per tree"). The program starts its own executable again as the
// keeper; the keeper forks the child into a group of its own, then waits on the life pipe and on the child. Between a
// fork and an exec only system calls run.

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"
import base "../base"

// The hidden argument of a keeper's process.
@(private = "file") KEEPER_ARG :: "--gt-process-keeper"
// The keeper's descriptors past the standard three.
@(private = "file") KEEP_LIFE :: linux.Fd(3)     // the life pipe: a byte is a signal for the group; its end, the tree's
@(private = "file") KEEP_SPEC :: linux.Fd(4)     // what to run, written once by the program
@(private = "file") KEEP_REPORT :: linux.Fd(5)   // the child's pid, or an error, for the program
@(private = "file") REPORT_PID :: u8('P')
@(private = "file") REPORT_ERROR :: u8('E')
@(private = "file") REPORT_BYTES :: 5            // a tag and an i32
// The spec's count of environment strings when the child takes the keeper's own (the program's).
@(private = "file") ENV_INHERIT :: max(u32)
@(private = "file") PR_SET_PDEATHSIG :: 1
@(private = "file") FD_CLOEXEC :: 1
// Tree.process.handle once the keeper's pidfd is closed (the keeper reaped).
@(private = "file") NO_PIDFD :: ~uintptr(0)
// The signals the keeper ignores (a terminal's Ctrl+C and hangup reach the program's group; the life pipe ends the
// tree then), and that the child gets back as default.
@(private = "file") KEEPER_IGNORES :: [?]linux.Signal{.SIGINT, .SIGTERM, .SIGHUP, .SIGQUIT, .SIGPIPE}

tree_start :: proc(desc: os.Process_Desc, loc := #caller_location) -> (t: Tree, err: os.Error) {
	base.blocking("process.tree_start", loc)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()   // (as start)
	if len(desc.command) == 0 { return {}, os.General_Error.Invalid_Command }
	if !base.may_start(desc.command[0]) {
		fmt.eprintfln("process.tree_start: %s refused: %s", desc.command[0], base.restricted_reason())
		return {}, io.Error.Permission_Denied
	}
	resolved, found := resolve(desc.command[0], desc.env)
	if !found { return {}, os.General_Error.Not_Exist }
	spec := spec_encode(resolved, desc.working_dir, desc.command, desc.env)

	life, spec_pipe, report: [2]linux.Fd
	if e := linux.pipe2(&life, {.CLOEXEC}); e != .NONE { return {}, os.Platform_Error(e) }
	if e := linux.pipe2(&spec_pipe, {.CLOEXEC}); e != .NONE {
		close_all(life[:])
		return {}, os.Platform_Error(e)
	}
	if e := linux.pipe2(&report, {.CLOEXEC}); e != .NONE {
		close_all(life[:]); close_all(spec_pipe[:])
		return {}, os.Platform_Error(e)
	}
	null, nerr := linux.open("/dev/null", {.RDWR, .CLOEXEC})
	if nerr != .NONE {
		close_all(life[:]); close_all(spec_pipe[:]); close_all(report[:])
		return {}, os.Platform_Error(nerr)
	}
	fds := [6]linux.Fd{end_fd(desc.stdin, null), end_fd(desc.stdout, null), end_fd(desc.stderr, null), life[0], spec_pipe[0], report[1]}
	argv := cstrings({executable_path(), KEEPER_ARG})
	envp := environment_cstrings()
	sync.lock(&start_lock)
	keeper, serr := spawn_raw("/proc/self/exe", argv, envp, nil, fds[:])
	sync.unlock(&start_lock)
	close_all({null, life[0], spec_pipe[0], report[1]})
	if serr != .NONE {
		close_all({life[1], spec_pipe[1], report[0]})
		return {}, os.Platform_Error(serr)
	}

	// (a keeper that ends before it read its spec makes this write fail, not this process end)
	broken_pipe_ignore()
	write_all(spec_pipe[1], spec)
	linux.close(spec_pipe[1])
	child: linux.Pid
	child_err: linux.Errno
	msg: [REPORT_BYTES]u8
	n := 0
	for {
		r, e := linux.read(report[0], msg[n:])
		if e == .EINTR { continue }
		if e != .NONE || r <= 0 { break }
		n += r
		if n < REPORT_BYTES { continue }
		value := (^i32)(&msg[1])^
		if msg[0] == REPORT_PID { child = linux.Pid(value) } else { child_err = linux.Errno(value) }
		n = 0
	}
	linux.close(report[0])
	if child == 0 || child_err != .NONE {
		linux.close(life[1])
		info: linux.Sig_Info
		for linux.waitid(.PID, linux.Id(keeper), &info, {.WEXITED}, nil) == .EINTR {}
		return {}, os.Platform_Error(child_err != .NONE ? child_err : linux.Errno.ECHILD)
	}
	pidfd, perr := linux.pidfd_open(keeper, {})
	if perr != .NONE {
		// (the keeper ends with the life pipe; it is this process's child, reaped here)
		linux.close(life[1])
		info: linux.Sig_Info
		for linux.waitid(.PID, linux.Id(keeper), &info, {.WEXITED}, nil) == .EINTR {}
		return {}, os.Platform_Error(perr)
	}
	return Tree{process = {pid = int(keeper), handle = uintptr(pidfd)}, pid = int(child), keep = uintptr(life[1])}, nil
}

tree_signal :: proc(t: ^Tree, sig: Signal) -> bool {
	if t.keep == TREE_GONE || t.ended { return false }
	b := [1]u8{u8(linux_signal(sig))}
	n, e := linux.write(linux.Fd(t.keep), b[:])
	return e == .NONE && n == 1
}

tree_kill :: proc(t: ^Tree) {
	if t.keep == TREE_GONE { return }
	linux.close(linux.Fd(t.keep))
	t.keep = TREE_GONE
}

tree_wait :: proc(t: ^Tree, timeout: time.Duration) -> (end: Tree_End, ended: bool) {
	if t.ended { return t.end, true }
	if t.process.handle == NO_PIDFD || t.process.pid <= 0 { return }
	limit := i32(-1)
	if timeout >= 0 { limit = i32(min(time.duration_milliseconds(timeout), f64(max(i32)))) }
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(t.process.handle), events = {.IN}}}
	start := time.tick_now()
	ms := limit
	for {
		n, e := linux.poll(fds[:], ms)
		if e == .EINTR {
			// (what is left of the whole limit, not of the last wait)
			if limit > 0 { ms = max(0, limit - i32(time.duration_milliseconds(time.tick_since(start)))) }
			continue
		}
		if e != .NONE || n == 0 { return }
		break
	}
	info: linux.Sig_Info
	for linux.waitid(.PID, linux.Id(t.process.pid), &info, {.WEXITED}, nil) == .EINTR {}
	#partial switch linux.Sig_Child_Code(info.code) {
	case .KILLED, .DUMPED: t.end = {signaled = true, code = int(info.status)}
	case:                  t.end = {code = int(info.status)}
	}
	t.ended = true
	linux.close(linux.Fd(t.process.handle))
	t.process.handle = NO_PIDFD
	return t.end, true
}

tree_close :: proc(t: ^Tree) {
	tree_kill(t)
	if !t.ended { _, _ = tree_wait(t, TREE_CLOSE_BOUND) }
	if t.process.handle != NO_PIDFD {
		linux.close(linux.Fd(t.process.handle))
		t.process.handle = NO_PIDFD
	}
}

@(private = "file")
close_all :: proc(fds: []linux.Fd) { for fd in fds { linux.close(fd) } }

@(private = "file")
write_all :: proc(fd: linux.Fd, data: []u8) {
	rest := data
	for len(rest) > 0 {
		n, e := linux.write(fd, rest)
		if e == .EINTR { continue }
		if e != .NONE || n <= 0 { return }
		rest = rest[n:]
	}
}

// What the keeper runs: the counts of the arguments and of the environment (ENV_INHERIT: the keeper's own), then the
// path, the folder, the arguments and the environment, each a length and its bytes. In temp memory.
@(private = "file")
spec_encode :: proc(path, dir: string, argv: []string, env: []string) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	put_u32 :: proc(b: ^[dynamic]u8, v: u32) { v := v; append(b, ..([^]u8)(&v)[:4]) }
	put :: proc(b: ^[dynamic]u8, s: string) { put_u32(b, u32(len(s))); append(b, s) }
	put_u32(&b, u32(len(argv)))
	if env == nil {
		put_u32(&b, ENV_INHERIT)
	} else {
		count: u32
		for e in env { if e != "" && strings.index_byte(e, 0) < 0 { count += 1 } }
		put_u32(&b, count)
	}
	put(&b, path)
	put(&b, dir)
	for a in argv { put(&b, a) }
	for e in env {
		if e == "" || strings.index_byte(e, 0) >= 0 { continue }
		put(&b, e)
	}
	return b[:]
}

@(private = "file")
Spec :: struct {
	path, dir: cstring,
	argv, envp: [^]cstring,
}

@(private = "file")
spec_decode :: proc(data: []u8) -> (s: Spec, ok: bool) {
	rest := data
	get_u32 :: proc(rest: ^[]u8) -> (v: u32, ok: bool) {
		if len(rest) < 4 { return }
		v = (^u32)(raw_data(rest^))^
		rest^ = rest[4:]
		return v, true
	}
	get :: proc(rest: ^[]u8) -> (s: cstring, ok: bool) {
		n := get_u32(rest) or_return
		if int(n) > len(rest) { return }
		s = strings.clone_to_cstring(string(rest[:n]))
		rest^ = rest[n:]
		return s, true
	}
	argc := get_u32(&rest) or_return
	envc := get_u32(&rest) or_return
	if argc == 0 || int(argc) > len(data) || (envc != ENV_INHERIT && int(envc) > len(data)) { return }
	s.path = get(&rest) or_return
	dir := get(&rest) or_return
	s.dir = dir != "" ? dir : nil
	argv := make([]cstring, argc + 1)
	for i in 0 ..< argc { argv[i] = get(&rest) or_return }
	s.argv = raw_data(argv)
	if envc == ENV_INHERIT {
		s.envp = environment_cstrings()
	} else {
		envp := make([]cstring, envc + 1)
		for i in 0 ..< envc { envp[i] = get(&rest) or_return }
		s.envp = raw_data(envp)
	}
	return s, true
}

// The keeper: the program's executable started again by tree_start, before the program's main runs.
@(init, private = "file")
keeper_init :: proc "contextless" () {
	context = runtime.default_context()
	if len(os.args) < 2 || os.args[1] != KEEPER_ARG { return }
	context.allocator = runtime.heap_allocator()
	linux.exit_group(keeper_main())
}

@(private = "file")
keeper_main :: proc() -> i32 {
	// (a signal blocked or ignored by the program's thread survives the exec: the keeper starts from a clean state)
	empty: linux.Sig_Set
	_ = linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)
	for sig in KEEPER_IGNORES { disposition(sig, .SIG_IGN) }
	data := make([dynamic]u8)
	buf: [4096]u8
	for {
		n, e := linux.read(KEEP_SPEC, buf[:])
		if e == .EINTR { continue }
		if e != .NONE || n <= 0 { break }
		append(&data, ..buf[:n])
	}
	linux.close(KEEP_SPEC)
	spec, ok := spec_decode(data[:])
	if !ok {
		report(KEEP_REPORT, REPORT_ERROR, i32(linux.Errno.EINVAL))
		return 127
	}
	_ = linux.fcntl(KEEP_REPORT, linux.F_SETFD, linux.Fd(FD_CLOEXEC))
	// (the child's exec: an errno, or the end of the pipe at the exec. The pid is reported after it, so its session
	// and its group exist by then, and a tree_signal right after tree_start reaches them)
	exec_pipe: [2]linux.Fd
	if e := linux.pipe2(&exec_pipe, {.CLOEXEC}); e != .NONE {
		report(KEEP_REPORT, REPORT_ERROR, i32(e))
		return 127
	}
	me := linux.getpid()
	child, err := linux.fork()
	if err != .NONE {
		report(KEEP_REPORT, REPORT_ERROR, i32(err))
		return 127
	}
	if child == 0 { tree_child(spec, me, exec_pipe[1]) }
	linux.close(exec_pipe[1])
	code: i32
	got := 0
	for got < size_of(code) {
		n, e := linux.read(exec_pipe[0], ([^]u8)(&code)[got:size_of(code)])
		if e == .EINTR { continue }
		if e != .NONE || n <= 0 { break }
		got += n
	}
	linux.close(exec_pipe[0])
	if got == size_of(code) {
		report(KEEP_REPORT, REPORT_ERROR, code)
		info: linux.Sig_Info
		for linux.waitid(.PID, linux.Id(child), &info, {.WEXITED}, nil) == .EINTR {}
		return 127
	}
	report(KEEP_REPORT, REPORT_PID, i32(child))
	linux.close(KEEP_REPORT)

	pidfd, perr := linux.pidfd_open(child, {})
	if perr != .NONE {
		_ = linux.kill(-child, .SIGKILL)
	} else {
		fds := [2]linux.Poll_Fd{{fd = KEEP_LIFE, events = {.IN}}, {fd = linux.Fd(pidfd), events = {.IN}}}
		watch: for {
			_, e := linux.poll(fds[:], -1)
			if e == .EINTR { continue }
			if e != .NONE || fds[1].revents != {} { break }
			if fds[0].revents == {} { continue }
			signals: [64]u8
			n, re := linux.read(KEEP_LIFE, signals[:])
			if re == .EINTR || re == .EAGAIN { continue }
			// (the life pipe's end: the program is gone, or it killed the tree)
			if re != .NONE || n <= 0 { break }
			// (the child is not reaped yet: its pid is still the group's id)
			for s in signals[:n] { _ = linux.kill(-child, linux.Signal(s)) }
		}
	}
	// (what the child left running, or the whole tree: the group's id is still the unreaped child's)
	_ = linux.kill(-child, .SIGKILL)
	info: linux.Sig_Info
	for linux.waitid(.PID, linux.Id(child), &info, {.WEXITED}, nil) == .EINTR {}
	#partial switch linux.Sig_Child_Code(info.code) {
	case .EXITED:
		return info.status
	case .KILLED, .DUMPED:
		// (the same end as the child's, for the program that waits on the keeper; no core file of the keeper)
		sig := linux.Signal(info.status)
		no_core := linux.RLimit{}
		_ = linux.setrlimit(.CORE, &no_core)
		disposition(sig, .SIG_DFL)
		_ = linux.kill(linux.getpid(), sig)
		return 128 + info.status
	}
	return 127
}

// The child, between the keeper's fork and its exec. An error goes to the keeper on `exec_report`.
@(private = "file")
tree_child :: proc "contextless" (spec: Spec, keeper: linux.Pid, exec_report: linux.Fd) -> ! {
	fail :: proc "contextless" (fd: linux.Fd, e: linux.Errno) -> ! {
		code := i32(e)
		_, _ = linux.write(fd, ([^]u8)(&code)[:size_of(code)])
		linux.exit_group(127)
	}
	for sig in KEEPER_IGNORES { disposition(sig, .SIG_DFL) }
	// (a session of its own, not only a group: a child in a background group of the program's terminal would stop
	// at its first read of /dev/tty (a git prompt); without a terminal, that open fails at once. The session's id is
	// the group's: kill(-pid) reaches the group)
	if _, e := linux.setsid(); e != .NONE { fail(exec_report, e) }
	_ = linux.prctl(PR_SET_PDEATHSIG, uint(linux.Signal.SIGKILL), 0, 0, 0)
	// (the keeper ended before the setting: nothing would kill this child at its end)
	if linux.getppid() != keeper { linux.exit_group(127) }
	linux.close(KEEP_LIFE)
	linux.close(KEEP_REPORT)
	// (what the keeper's own start opened stays here)
	_ = linux.close_range(3, max(linux.Fd), {.CLOEXEC})
	if spec.dir != nil {
		if e := linux.chdir(spec.dir); e != .NONE { fail(exec_report, e) }
	}
	e := linux.execve(spec.path, spec.argv, spec.envp)
	fail(exec_report, e)
}

@(private = "file")
report :: proc "contextless" (fd: linux.Fd, tag: u8, value: i32) {
	msg: [REPORT_BYTES]u8
	msg[0] = tag
	(^i32)(&msg[1])^ = value
	_, _ = linux.write(fd, msg[:])
}

@(private = "file")
disposition :: proc "contextless" (sig: linux.Signal, how: linux.Sig_Action_Special) {
	act: linux.Sig_Action
	act.special = how
	_ = linux.rt_sigaction(sig, &act, nil)
}
