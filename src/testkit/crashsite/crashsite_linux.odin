package crashsite

import "core:sync"
import "core:sys/posix"

foreign import libc_dl "system:c"

@(private = "file")
Dl_Info :: struct {
	fname: cstring,
	fbase: rawptr,
	sname: cstring,
	saddr: rawptr,
}

@(private = "file", default_calling_convention = "c")
foreign libc_dl {
	dladdr :: proc(addr: rawptr, info: ^Dl_Info) -> i32 ---
}

@(private = "file") SIGNALS :: [4]posix.Signal{.SIGILL, .SIGFPE, .SIGSEGV, .SIGBUS}

// The handlers replaced, per signal (written once under `lock`, read in the handler).
@(private = "file") replaced: [4]posix.sigaction_t
@(private = "file") lock: sync.Mutex
// The instruction this thread last faulted at: the same one again means the replaced handler returned.
@(private = "file", thread_local) last_pc: uintptr

// Installs the handler for SIGILL, SIGFPE, SIGSEGV and SIGBUS, after the one in place (the test runner's), once. Call it
// after the runner's main started: session.start, unwatched.run and testkit.temp_folder do.
arm :: proc() {
	sync.guard(&lock)
	for sig, i in SIGNALS {
		cur: posix.sigaction_t
		if posix.sigaction(sig, nil, &cur) != .OK { continue }
		if .SIGINFO in cur.sa_flags && cur.sa_sigaction == handler { continue }
		replaced[i] = cur
		act := posix.sigaction_t{sa_flags = {.SIGINFO, .ONSTACK}}
		act.sa_sigaction = handler
		posix.sigemptyset(&act.sa_mask)
		posix.sigaction(sig, &act, nil)
	}
}

@(private = "file")
signal_name :: proc "contextless" (sig: posix.Signal) -> string {
	#partial switch sig {
	case .SIGILL:  return "SIGILL"
	case .SIGFPE:  return "SIGFPE"
	case .SIGSEGV: return "SIGSEGV"
	case .SIGBUS:  return "SIGBUS"
	}
	return "signal"
}

// The faulting instruction: the context's program counter (si_addr is the touched address for a memory fault).
@(private = "file")
pc_of :: proc "contextless" (info: ^posix.siginfo_t, uctx: rawptr) -> uintptr {
	when ODIN_ARCH == .amd64 {
		// ucontext_t: uc_flags, uc_link, uc_stack (24 bytes), then mcontext's gregs; REG_RIP is the 17th
		if uctx != nil { return (^uintptr)(uintptr(uctx) + 40 + 16 * 8)^ }
	} else when ODIN_ARCH == .arm64 {
		// uc_flags, uc_link, uc_stack, uc_sigmask (128), then mcontext at 176: fault_address, regs[31], sp, pc
		if uctx != nil { return (^uintptr)(uintptr(uctx) + 176 + 8 + 31 * 8 + 8)^ }
	}
	return uintptr(info.si_addr)
}

@(private = "file")
cstr :: proc "contextless" (c: cstring) -> string {
	if c == nil { return "" }
	p := ([^]u8)(c)
	n := 0
	for p[n] != 0 { n += 1 }
	return string(p[:n])
}

@(private = "file")
handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr) {
	i := -1
	for s, k in SIGNALS { if s == sig { i = k } }
	pc := pc_of(info, uctx)
	again := pc != 0 && pc == last_pc
	last_pc = pc

	s := Site{signal = signal_name(sig), pc = pc, again = again}
	if sig == .SIGSEGV || sig == .SIGBUS { s.memory, s.fault = true, uintptr(info.si_addr) }
	when ODIN_ARCH == .amd64 {
		if sig == .SIGILL && pc != 0 { s.trap = (^[2]u8)(pc)^ == {0x0f, 0x0b} }
	}
	dl: Dl_Info
	if pc != 0 && dladdr(rawptr(pc), &dl) != 0 {
		s.module, s.base = cstr(dl.fname), uintptr(dl.fbase)
		s.symbol, s.sym_addr = cstr(dl.sname), uintptr(dl.saddr)
	}
	buf: [512]u8
	n := format(buf[:], s)
	posix.write(posix.STDERR_FILENO, raw_data(buf[:]), uint(n))

	if again || i < 0 {
		// (the replaced handler returned and the thread faulted again: end by the signal, not spin)
		dfl := posix.sigaction_t{}
		dfl.sa_handler = auto_cast posix.SIG_DFL
		posix.sigaction(sig, &dfl, nil)
		return
	}
	prev := replaced[i]
	if .SIGINFO in prev.sa_flags {
		if prev.sa_sigaction != nil { prev.sa_sigaction(sig, info, uctx) }
		return
	}
	h := prev.sa_handler
	if rawptr(h) == rawptr(posix.SIG_DFL) || rawptr(h) == rawptr(posix.SIG_IGN) {
		dfl := posix.sigaction_t{}
		dfl.sa_handler = auto_cast posix.SIG_DFL
		posix.sigaction(sig, &dfl, nil)
		return   // (the instruction runs again under the default: the process ends by the signal)
	}
	h(sig)
}
