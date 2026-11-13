package tk_crash

// Linux: a fatal signal (SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP) writes the report on standard error and into
// "<dir>/crash-<date>-<pid>.txt", then the process dies as it would have (the default action: the system's core dump, if enabled,
// keeps the memory; coredumpctl).
//
// The handler runs on an alternate signal stack (a stack overflow leaves none of its own), allocates nothing and writes with system
// calls. The faulting thread's stack comes from libc's backtrace(), which unwinds through the signal frame with the unwind tables
// (.eh_frame) of every module. Every other thread is asked for its own with a signal of its own (THREAD_SIGNAL_FROM_MAX below the
// last real-time signal), within THREAD_WAIT_MS: a thread that blocks signals, or hangs, is listed without its frames. A frame is
// its module and its offset there, from /proc/self/maps (no loader call, which takes the loader's lock); the names libc can give
// (exported symbols only) come last, in [symbols], once everything else is written. The build is named by its GNU build id.

import "base:intrinsics"
import "core:sys/linux"
import "core:sys/posix"
import process "../process"

foreign import libc "system:c"
foreign import libdl "system:dl"

@(private = "file")
Dl_Info :: struct {
	fname: cstring,
	fbase: rawptr,
	sname: cstring,
	saddr: rawptr,
}

@(private = "file", default_calling_convention = "c")
foreign libc {
	backtrace :: proc(buffer: [^]rawptr, size: i32) -> i32 ---
	getauxval :: proc(type: u64) -> u64 ---
	__libc_current_sigrtmax :: proc() -> i32 ---
}

@(private = "file", default_calling_convention = "c")
foreign libdl {
	dladdr :: proc(addr: rawptr, info: ^Dl_Info) -> i32 ---
}

@(private) UNCLEAN_REASON :: "the session ended without a report: the process was killed (SIGKILL: the out-of-memory killer, a watchdog, kill -9) or the machine stopped; journalctl -k and coredumpctl may say more"

@(private = "file") MAX_FRAMES :: 64
@(private = "file") MAX_THREADS :: 64
@(private = "file") MAX_MODULES :: 512
@(private = "file") ALT_STACK_BYTES :: 256 * 1024
@(private = "file") OUT_BYTES :: 8 * 1024
@(private = "file") MAPS_BYTES :: 8 * 1024
@(private = "file") LINE_BYTES :: 4 * 1024
@(private = "file") PATHS_BYTES :: 64 * 1024
@(private = "file") THREAD_NAME_BYTES :: 32
// How long the other threads are given to say their stacks, all together.
@(private = "file") THREAD_WAIT_MS :: 1000
// How long a second faulting thread waits for the first one's report before it dies.
@(private = "file") SECOND_FAULT_WAIT_MS :: 10_000
@(private = "file") POLL_NS :: 1_000_000
// The other threads' signal: this many below SIGRTMAX (glibc keeps the first real-time signals for itself; programs take the low ones).
@(private = "file") THREAD_SIGNAL_FROM_MAX :: 2
// x86-64 ucontext_t: uc_flags (8), uc_link (8), uc_stack (24), then the registers; RIP is gregs[16].
@(private = "file") UCONTEXT_RIP_AT :: 40 + 16 * 8
// siginfo_t: si_signo, si_errno, si_code (int each). A code <= 0 is a signal sent by a process (kill, raise, tgkill).
@(private = "file") SIGINFO_CODE_AT :: 8
@(private = "file") AT_PHDR :: 3
@(private = "file") AT_PHNUM :: 5
@(private = "file") ELF64_PHDR_BYTES :: 56

@(private = "file")
FATAL_SIGNALS :: [?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP}

// What a thread asked for its stack says (state: 0 free, 1 asked, 2 answered).
@(private = "file")
Slot :: struct {
	tid:    i32,
	state:  i32,
	pc:     u64,
	count:  int,
	frames: [MAX_FRAMES]rawptr,
}

@(private = "file")
Mapped :: struct {
	base, end:         u64,
	path_at, path_len: int,
	name_at:           int,   // the file name's start in the path
}

// Everything the handler uses, taken at install: nothing is allocated while the process is crashing.
@(private = "file")
Linux_State :: struct {
	thread_signal: posix.Signal,
	reporting:     i32,   // (atomic) a report is being written
	reporter:      i32,   // the thread that writes it
	done:          i32,   // (atomic) it is written
	alt_stack:     [ALT_STACK_BYTES]u8,
	out:           [OUT_BYTES]u8,
	fd:            linux.Fd,
	maps:          [MAPS_BYTES]u8,
	line:          [LINE_BYTES]u8,
	paths:         [PATHS_BYTES]u8,
	paths_len:     int,
	modules:       [MAX_MODULES]Mapped,
	module_count:  int,
	slots:         [MAX_THREADS]Slot,
	own:           Slot,
	path:          [DIR_BYTES + 128]u8,
	session:       [DIR_BYTES + 32]u8,   // <dir>/session.txt, NUL-terminated
	name:          [THREAD_NAME_BYTES]u8,
	date:          [32]u8,
	file:          [96]u8,
}

@(private = "file")
sys: Linux_State

@(private)
install_handler :: proc() -> bool {
	sys.fd = -1
	n := copy(sys.session[:len(sys.session) - 1], kept_dir())
	n += copy(sys.session[n:len(sys.session) - 1], "/" + SESSION_FILE)
	sys.session[n] = 0
	// backtrace() loads libgcc's unwinder on its first call, which allocates: done here, not in the handler
	warm: [4]rawptr
	backtrace(&warm[0], len(warm))
	ss := posix.stack_t{ss_sp = &sys.alt_stack[0], ss_size = ALT_STACK_BYTES}
	posix.sigaltstack(&ss, nil)
	fatal := FATAL_SIGNALS
	for s in fatal {
		act: posix.sigaction_t
		act.sa_sigaction = on_signal
		act.sa_flags = {.SIGINFO, .ONSTACK}
		posix.sigaction(s, &act, nil)
	}
	sys.thread_signal = posix.Signal(__libc_current_sigrtmax() - THREAD_SIGNAL_FROM_MAX)
	act: posix.sigaction_t
	act.sa_sigaction = on_thread_signal
	act.sa_flags = {.SIGINFO, .RESTART}
	posix.sigaction(sys.thread_signal, &act, nil)
	return true
}

// The start of process `pid` after boot, in clock ticks (/proc/<pid>/stat); alive false when it is gone.
@(private)
process_started :: proc(pid: u64) -> (start: u64, alive: bool) { return process.process_start_time(i32(pid)) }

// The GNU build id of the executable mapped in this process, as hex, read from its program headers (AT_PHDR): the note the linker
// writes with --build-id (toolbox.crash_link_flags asks for it).
@(private)
read_build :: proc "contextless" (buf: []u8) -> int {
	phdr := uintptr(getauxval(AT_PHDR))
	phnum := int(getauxval(AT_PHNUM))
	if phdr == 0 || phnum == 0 { return 0 }
	PT_PHDR :: 6
	PT_NOTE :: 4
	NT_GNU_BUILD_ID :: 3
	GNU_NAME :: 0x00554e47   // "GNU\0"
	bias: uintptr
	for i in 0 ..< phnum {
		p := phdr + uintptr(i * ELF64_PHDR_BYTES)
		if (^u32)(p)^ == PT_PHDR { bias = phdr - uintptr((^u64)(p + 16)^) }
	}
	for i in 0 ..< phnum {
		p := phdr + uintptr(i * ELF64_PHDR_BYTES)
		if (^u32)(p)^ != PT_NOTE { continue }
		at := bias + uintptr((^u64)(p + 16)^)
		end := at + uintptr((^u64)(p + 32)^)
		for at + 12 <= end {
			namesz, descsz, kind := (^u32)(at)^, (^u32)(at + 4)^, (^u32)(at + 8)^
			name := at + 12
			desc := name + uintptr((namesz + 3) &~ 3)
			if kind == NT_GNU_BUILD_ID && namesz == 4 && (^u32)(name)^ == GNU_NAME {
				hex := "0123456789abcdef"
				n := 0
				for k in 0 ..< int(descsz) {
					if n + 2 > len(buf) { break }
					b := ([^]u8)(desc)[k]
					buf[n], buf[n + 1] = hex[b >> 4], hex[b & 15]
					n += 2
				}
				return n
			}
			at = desc + uintptr((descsz + 3) &~ 3)
		}
	}
	return 0
}

////////////////////////////////
// The handlers

@(private = "file")
on_signal :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr) {
	tid := i32(linux.gettid())
	if intrinsics.atomic_exchange(&sys.reporting, 1) == 0 {
		intrinsics.atomic_store(&sys.reporter, tid)
		write_report(sig, info, uctx, tid)
		intrinsics.atomic_store(&sys.done, 1)
	} else if intrinsics.atomic_load(&sys.reporter) != tid {
		// another thread faulted meanwhile: its default action now would end the process under the report
		waited := 0
		for intrinsics.atomic_load(&sys.done) == 0 && waited < SECOND_FAULT_WAIT_MS {
			sleep_ns(POLL_NS)
			waited += 1
		}
	}
	// the default action back: a fault returns to the instruction, which faults again and ends the process as it would have; a
	// signal sent on purpose (abort, kill) is sent again
	dfl: posix.sigaction_t
	posix.sigaction(sig, &dfl, nil)
	code := (^i32)(uintptr(info) + SIGINFO_CODE_AT)^
	if code <= 0 || sig == .SIGABRT || sig == .SIGTRAP { posix.raise(sig) }
}

// Another thread, asked for its stack by the report.
@(private = "file")
on_thread_signal :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr) {
	if intrinsics.atomic_load(&sys.reporting) == 0 { return }
	tid := i32(linux.gettid())
	for &s in sys.slots {
		if s.tid != tid || intrinsics.atomic_load(&s.state) != 1 { continue }
		s.pc = context_pc(uctx)
		s.count = int(backtrace(&s.frames[0], MAX_FRAMES))
		intrinsics.atomic_store(&s.state, 2)
		return
	}
}

@(private = "file")
context_pc :: proc "contextless" (uctx: rawptr) -> u64 {
	when ODIN_ARCH == .amd64 { if uctx != nil { return (^u64)(uintptr(uctx) + UCONTEXT_RIP_AT)^ } }
	return 0
}

@(private = "file")
sleep_ns :: proc "contextless" (ns: uint) {
	req := linux.Time_Spec{time_nsec = ns}
	linux.nanosleep(&req, nil)
}

////////////////////////////////
// The report

@(private = "file")
write_report :: proc "contextless" (sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr, tid: i32) {
	ts, _ := linux.clock_gettime(.REALTIME)
	now := i64(ts.time_sec)
	pid := u64(linux.getpid())
	open_report(now, pid)
	o := Out{buf = sys.out[:], sink = sink}
	pc := context_pc(uctx)
	write_head(&o, Head{
		program = kept_program(), version = kept_version(), commit = kept_commit(), build = kept_build(), system = SYSTEM_NAME,
		date = out_date(sys.date[:], now), pid = pid, kind = KIND_SIGNAL, code = signal_code(sig), reason = signal_reason(sig),
		address = u64(uintptr(info.si_addr)), pc = pc, thread = u64(tid),
	})
	read_modules()

	// the faulting thread: the first frames are this handler and the signal trampoline; the stack proper starts at the faulting instruction
	sys.own.count = int(backtrace(&sys.own.frames[0], MAX_FRAMES))
	sys.own.pc = pc
	write_thread(&o, tid, &sys.own, true)

	// every other thread, asked at once and waited for together
	asked := ask_threads(tid)
	waited := 0
	for waited < THREAD_WAIT_MS && !all_answered(asked) {
		sleep_ns(POLL_NS)
		waited += 1
	}
	for i in 0 ..< asked {
		s := &sys.slots[i]
		if intrinsics.atomic_load(&s.state) == 2 {
			write_thread(&o, s.tid, s, false)
		} else {
			out_thread(&o, u64(s.tid), thread_name(s.tid), false)
			out_string(&o, INDENT)
			out_field(&o, "answered", "no")
		}
	}

	out_section(&o, "modules")
	for i in 0 ..< sys.module_count {
		m := &sys.modules[i]
		path := string(sys.paths[m.path_at:][:m.path_len])
		out_module(&o, m.base, m.end - m.base, path[m.name_at:], path)
	}
	write_source(&o, "log", kept.log_tail)
	write_source(&o, "settings", kept.settings)
	out_flush(&o)

	// the names libc finds, last: dladdr takes the loader's lock, which the crash may have left held
	out_section(&o, "symbols")
	for i in 0 ..< sys.own.count {
		at := sys.own.frames[i]
		d: Dl_Info
		if dladdr(at, &d) == 0 || d.sname == nil { continue }
		name_buf: [256]u8
		no := Out{buf = name_buf[:]}
		out_string(&no, c_text(d.sname))
		out_byte(&no, '+')
		out_hex(&no, u64(uintptr(at)) - u64(uintptr(d.saddr)))
		out_symbol(&o, u64(uintptr(at)), string(name_buf[:no.n]))
	}
	out_section(&o, "end")
	out_flush(&o)
	if sys.fd >= 0 { linux.close(sys.fd); sys.fd = -1 }
	// the report says all: the next start has no unclean session to report for this end
	if kept.dir_len > 0 { linux.unlink(cstring(&sys.session[0])) }
}

// The frames of a thread from its faulting (or interrupted) instruction on.
@(private = "file")
write_thread :: proc "contextless" (o: ^Out, tid: i32, s: ^Slot, crashed: bool) {
	out_thread(o, u64(tid), thread_name(tid), crashed)
	first := 0
	if s.pc != 0 { for i in 0 ..< s.count { if u64(uintptr(s.frames[i])) == s.pc { first = i; break } } }
	k := 0
	for i in first ..< s.count {
		pc := u64(uintptr(s.frames[i]))
		name, base := module_of(pc)
		out_frame(o, k, pc, name, base != 0 ? pc - base : 0, "")
		k += 1
	}
}

// Every other thread of the process (/proc/self/task) is asked for its stack. The count of slots taken.
@(private = "file")
ask_threads :: proc "contextless" (own: i32) -> int {
	dir, err := linux.open("/proc/self/task", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return 0 }
	defer linux.close(dir)
	pid := linux.getpid()
	n := 0
	for n < MAX_THREADS {
		got, gerr := linux.getdents(dir, sys.maps[:])
		if gerr != .NONE || got <= 0 { break }
		offset := 0
		for d in linux.dirent_iterate_buf(sys.maps[:got], &offset) {
			tid, ok := parse_dec(linux.dirent_name(d))
			if !ok || i32(tid) == own || n >= MAX_THREADS { continue }
			s := &sys.slots[n]
			s.tid, s.count, s.pc = i32(tid), 0, 0
			intrinsics.atomic_store(&s.state, 1)
			n += 1
			linux.tgkill(pid, linux.Pid(tid), linux.Signal(i32(sys.thread_signal)))
		}
	}
	return n
}

@(private = "file")
all_answered :: proc "contextless" (asked: int) -> bool {
	for i in 0 ..< asked { if intrinsics.atomic_load(&sys.slots[i].state) != 2 { return false } }
	return true
}

// /proc/self/task/<tid>/comm, the thread's name ("" when it cannot be read).
@(private = "file")
thread_name :: proc "contextless" (tid: i32) -> string {
	path: [64]u8
	o := Out{buf = path[:len(path) - 1]}
	out_string(&o, "/proc/self/task/")
	out_dec(&o, u64(tid))
	out_string(&o, "/comm")
	path[o.n] = 0
	fd, err := linux.open(cstring(&path[0]), {.CLOEXEC})
	if err != .NONE { return "" }
	defer linux.close(fd)
	n, rerr := linux.read(fd, sys.name[:])
	if rerr != .NONE || n <= 0 { return "" }
	for n > 0 && (sys.name[n - 1] == '\n' || sys.name[n - 1] == 0) { n -= 1 }
	return string(sys.name[:n])
}

// The files mapped in the process, from /proc/self/maps: a module's base is its first mapping's start less that mapping's offset.
@(private = "file")
read_modules :: proc "contextless" () {
	sys.module_count, sys.paths_len = 0, 0
	fd, err := linux.open("/proc/self/maps", {.CLOEXEC})
	if err != .NONE { return }
	defer linux.close(fd)
	line_len := 0
	for {
		got, rerr := linux.read(fd, sys.maps[:])
		if rerr != .NONE || got <= 0 { break }
		for i in 0 ..< got {
			c := sys.maps[i]
			if c != '\n' {
				if line_len < LINE_BYTES { sys.line[line_len] = c; line_len += 1 }
				continue
			}
			map_line(string(sys.line[:line_len]))
			line_len = 0
		}
	}
	if line_len > 0 { map_line(string(sys.line[:line_len])) }
}

// "start-end perms offset dev inode   path"
@(private = "file")
map_line :: proc "contextless" (line: string) {
	rest := line
	span := next_word(&rest)
	_ = next_word(&rest)   // perms
	offset_text := next_word(&rest)
	_ = next_word(&rest)   // dev
	_ = next_word(&rest)   // inode
	for len(rest) > 0 && rest[0] == ' ' { rest = rest[1:] }
	if len(rest) == 0 || rest[0] != '/' { return }
	dash := -1
	for i in 0 ..< len(span) { if span[i] == '-' { dash = i; break } }
	if dash < 0 { return }
	start, g1 := parse_hex_bare(span[:dash])
	end, g2 := parse_hex_bare(span[dash + 1:])
	offset, g3 := parse_hex_bare(offset_text)
	if !g1 || !g2 || !g3 { return }
	if sys.module_count > 0 {
		last := &sys.modules[sys.module_count - 1]
		if string(sys.paths[last.path_at:][:last.path_len]) == rest {
			if end > last.end { last.end = end }
			return
		}
	}
	if sys.module_count == MAX_MODULES || sys.paths_len + len(rest) > PATHS_BYTES { return }
	m := &sys.modules[sys.module_count]
	m.base, m.end = start - offset, end
	m.path_at, m.path_len = sys.paths_len, len(rest)
	copy(sys.paths[sys.paths_len:], rest)
	sys.paths_len += len(rest)
	m.name_at = 0
	for i in 0 ..< len(rest) { if rest[i] == '/' { m.name_at = i + 1 } }
	sys.module_count += 1
}

@(private = "file")
next_word :: proc "contextless" (rest: ^string) -> string {
	s := rest^
	for len(s) > 0 && s[0] == ' ' { s = s[1:] }
	i := 0
	for i < len(s) && s[i] != ' ' { i += 1 }
	rest^ = s[i:]
	return s[:i]
}

@(private = "file")
module_of :: proc "contextless" (pc: u64) -> (name: string, base: u64) {
	for i in 0 ..< sys.module_count {
		m := &sys.modules[i]
		if pc >= m.base && pc < m.end {
			path := string(sys.paths[m.path_at:][:m.path_len])
			return path[m.name_at:], m.base
		}
	}
	return "", 0
}

@(private = "file")
parse_hex_bare :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 { return }
	for i in 0 ..< len(s) {
		c := s[i]
		d: u64
		switch c {
		case '0' ..= '9': d = u64(c - '0')
		case 'a' ..= 'f': d = u64(c - 'a' + 10)
		case 'A' ..= 'F': d = u64(c - 'A' + 10)
		case: return 0, false
		}
		v = v << 4 | d
	}
	return v, true
}

@(private = "file")
parse_dec :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 { return }
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '9' { return 0, false }
		v = v * 10 + u64(c - '0')
	}
	return v, true
}

@(private = "file")
c_text :: proc "contextless" (c: cstring) -> string {
	p := ([^]u8)(c)
	n := 0
	for p[n] != 0 && n < 4096 { n += 1 }
	return string(p[:n])
}

// "<dir>/crash-<date>-<pid>.txt", the folder and its parents made first (nothing is made before a crash).
@(private = "file")
open_report :: proc "contextless" (now: i64, pid: u64) {
	if kept.dir_len == 0 { return }
	dir := kept_dir()
	n := copy(sys.path[:len(sys.path) - 1], dir)
	for i in 1 ..= n {
		if i < n && sys.path[i] != '/' { continue }
		keep_byte := sys.path[i]
		sys.path[i] = 0
		linux.mkdir(cstring(&sys.path[0]), {.IRUSR, .IWUSR, .IXUSR})
		sys.path[i] = keep_byte
	}
	name := out_report_name(sys.file[:], CRASH_PREFIX, now, pid)
	sys.path[n] = '/'
	n += 1
	n += copy(sys.path[n:len(sys.path) - 1], name)
	sys.path[n] = 0
	fd, err := linux.open(cstring(&sys.path[0]), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err == .NONE { sys.fd = fd }
}

// On standard error and the report file, with nothing buffered past the handler's buffer.
@(private = "file")
sink :: proc "contextless" (o: ^Out, data: []u8) {
	linux.write(2, data)
	if sys.fd >= 0 { linux.write(sys.fd, data) }
}

@(private = "file")
signal_code :: proc "contextless" (s: posix.Signal) -> string {
	#partial switch s {
	case .SIGSEGV: return "SIGSEGV"
	case .SIGBUS:  return "SIGBUS"
	case .SIGILL:  return "SIGILL"
	case .SIGFPE:  return "SIGFPE"
	case .SIGABRT: return "SIGABRT"
	case .SIGTRAP: return "SIGTRAP"
	}
	return "signal"
}

@(private = "file")
signal_reason :: proc "contextless" (s: posix.Signal) -> string {
	#partial switch s {
	case .SIGSEGV: return "segmentation fault (an invalid memory access)"
	case .SIGBUS:  return "bus error"
	case .SIGILL:  return "illegal instruction (an Odin assertion or bounds check)"
	case .SIGFPE:  return "arithmetic error (an integer division by zero)"
	case .SIGABRT: return "abort (a runtime gave up: a Rust panic that could not unwind, a failed C assertion, a corrupted heap)"
	case .SIGTRAP: return "breakpoint"
	}
	return "signal"
}
