package tk_crash

// Windows: an exception no one handles (an access violation, an illegal instruction, a stack overflow, a heap the system found
// corrupted) writes the report on standard error and into "<dir>\crash-<date>-<pid>.txt" (and "<report>.dmp" with
// Install_Options.minidump), then the process dies as it would have (its exit code, the Application Error event).
//
// The report is written by a thread of its own, made at install and parked on an event, while the faulting thread waits: the
// faulting thread may have no stack left. Each stack is unwound with the modules' unwind tables (RtlVirtualUnwind) in a copy of it:
// a stack written over ends the walk where a walk in place would fault. Every other thread of the process is suspended in turn and
// walked the same way. The modules come from the process's own list (EnumProcessModules, no loader lock); the names DbgHelp
// finds (a PDB beside the program) come last, in [symbols]. The build is named by its PE time stamp and image size, "%08X%X".
//
// An end the program chooses itself while its session is open (ExitProcess or TerminateProcess of itself, from whatever library
// called them) leaves an "exit" report with the stack that asked for it: what remains unexplained at the next start came from outside.

import "base:intrinsics"
import win "core:sys/windows"

@(private) UNCLEAN_REASON :: "the session ended without a report: a fail-fast, or the process was ended from outside, or the machine stopped; Windows' Application Error event (wevtutil qe Application) may say more"

@(private = "file") MAX_FRAMES :: 64
@(private = "file") MAX_THREADS :: 256
@(private = "file") MAX_MODULES :: 512
@(private = "file") OUT_BYTES :: 8 * 1024
@(private = "file") NAMES_BYTES :: 64 * 1024
@(private = "file") SYM_NAME_CHARS :: 256
// How much of a stack is copied; what a frame reads past the end of the copy stays in the buffer.
@(private = "file") STACK_COPY_MOST :: 1 << 20
@(private = "file") STACK_COPY_SLACK :: 1 << 20
@(private = "file") FRAME_REGISTER_BYTE :: 3   // of UNWIND_INFO: the frame register in its low bits
@(private = "file") FRAME_REGISTER_MASK :: 0xF
// Room for the handler on a thread whose stack is gone (a stack overflow leaves one page: not enough to write a report).
@(private = "file") STACK_GUARANTEE :: 128 * 1024
@(private = "file") REPORT_THREAD_STACK :: 4 << 20
// What the system is left to die of, past this: a report stuck on a lock has what it wrote before.
@(private = "file") REPORT_LIMIT_MS :: 60_000
@(private = "file") STILL_ACTIVE :: 259
@(private = "file") CONTEXT_FULL_AMD64 :: 0x0010000B
@(private = "file") MINIDUMP_FLAGS :: 0x1040   // MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo
@(private = "file") ERROR_SEVERITY_MASK :: 0xF000_0000
@(private = "file") ERROR_SEVERITY :: 0xC000_0000
@(private = "file") IMPORT_BY_ORDINAL :: u64(1) << 63
@(private = "file") IMPORT_HINT_BYTES :: 2
@(private = "file") FILETIME_UNIX_EPOCH :: 116_444_736_000_000_000   // 1970-01-01 in FILETIME ticks
@(private = "file") FILETIME_TICKS_PER_SECOND :: 10_000_000
@(private = "file") PE_NT_OFFSET :: 0x3C
@(private = "file") PE_STAMP_OFFSET :: 8
@(private = "file") PE_SIZE_OF_IMAGE_OFFSET :: 24 + 56

@(private = "file")
RUNTIME_FUNCTION :: struct {
	begin, end, unwind: u32,
}

@(private = "file")
Import_Descriptor :: struct { names, stamp, chain, dll, slots: u32 }

foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, HistoryTable: rawptr) -> ^RUNTIME_FUNCTION ---
	RtlVirtualUnwind :: proc(HandlerType: u32, ImageBase: u64, ControlPc: u64, FunctionEntry: ^RUNTIME_FUNCTION, ContextRecord: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
	RtlCaptureContext :: proc(ContextRecord: ^win.CONTEXT) ---
	ExitThread :: proc(dwExitCode: win.DWORD) -> ! ---
	GetCurrentThreadStackLimits :: proc(LowLimit, HighLimit: ^uint) ---
	GetExitCodeThread :: proc(hThread: win.HANDLE, lpExitCode: ^win.DWORD) -> win.BOOL ---
	SetThreadStackGuarantee :: proc(size: ^u32) -> win.BOOL ---
	K32GetModuleFileNameExW :: proc(hProcess: win.HANDLE, hModule: win.HMODULE, lpFilename: ^u16, nSize: win.DWORD) -> win.DWORD ---
	K32EnumProcessModules :: proc(hProcess: win.HANDLE, lphModule: ^win.HMODULE, cb: win.DWORD, lpcbNeeded: ^win.DWORD) -> win.BOOL ---
}

// A thread's stack, copied from its stack pointer up. A stack is walked in a copy, never in place: the walk of a stack that is not
// what it should be (code without unwind tables, a stack written over) reads through whatever it found, and RtlVirtualUnwind has no
// way to say it could not. In place that ended the process; in the copy it ends the walk.
@(private = "file")
Stack_Copy :: struct {
	bytes:     [^]u8,
	low, high: u64,   // what was copied, in the thread's addresses
}

@(private = "file")
Mapped :: struct {
	base, size:        u64,
	name_at, name_len: int,
	path_at, path_len: int,
}

// Everything the handler uses, taken at install: nothing is allocated while the process is crashing.
@(private = "file")
Windows_State :: struct {
	reported:       i32,   // (atomic) the report is written once, by whichever handler comes first
	pending:        ^win.EXCEPTION_POINTERS,
	pending_thread: win.DWORD,
	writer_thread:  win.DWORD,   // who is writing the report
	report_wake:    win.HANDLE,
	report_done:    win.HANDLE,
	report_thread:  win.HANDLE,
	file:           win.HANDLE,
	dir:            [DIR_BYTES]u16,   // NUL-terminated
	path:           [DIR_BYTES + 128]u16,
	path_stem:      int,              // where the extension goes
	session:        [DIR_BYTES + 32]u16,
	out:            [OUT_BYTES]u8,
	stack:          Stack_Copy,
	pcs:            [MAX_FRAMES]u64,
	modules:        [MAX_MODULES]Mapped,
	module_count:   int,
	handles:        [MAX_MODULES]win.HMODULE,
	names:          [NAMES_BYTES]u8,
	names_len:      int,
	date:           [32]u8,
	name:           [96]u8,
	real_exit:      proc "system" (code: u32),
	real_terminate: proc "system" (process: win.HANDLE, code: u32) -> win.BOOL,
}

@(private = "file")
sys: Windows_State

@(private)
install_handler :: proc() -> bool {
	// the folder and the session file, as wide paths
	if dir := kept_dir(); dir != "" {
		w := win.utf8_to_utf16(dir, context.temp_allocator)
		n := copy(sys.dir[:len(sys.dir) - 1], w)
		sys.dir[n] = 0
		s := copy(sys.session[:len(sys.session) - 1], sys.dir[:n])
		file_name := "\\" + SESSION_FILE
		for c in file_name { if s < len(sys.session) - 1 { sys.session[s] = u16(c); s += 1 } }
		sys.session[s] = 0
	}
	stack_copy_init(&sys.stack)
	guarantee: u32 = STACK_GUARANTEE
	SetThreadStackGuarantee(&guarantee)
	sys.report_wake = win.CreateEventW(nil, false, false, nil)
	sys.report_done = win.CreateEventW(nil, true, false, nil)
	if sys.report_wake != nil && sys.report_done != nil { sys.report_thread = win.CreateThread(nil, REPORT_THREAD_STACK, parked_report_thread, nil, 0, nil) }
	win.SetUnhandledExceptionFilter(on_crash)
	// What kills a process without the filter being asked: a heap the system found corrupted (0xC0000374) ends it at once, and a
	// stack overflow often leaves the filter no room. The vectored handler is called first for those (and for a failed security
	// check raised as an exception); it only reports, the process dies as it would have.
	win.AddVectoredExceptionHandler(0, on_fatal)
	exit_watch_install()
	return true
}

// When process `pid` was made (FILETIME); alive false when it has ended.
@(private)
process_started :: proc(pid: u64) -> (start: u64, alive: bool) {
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	if h == nil { return }
	defer win.CloseHandle(h)
	code: win.DWORD
	if !win.GetExitCodeProcess(h, &code) || code != STILL_ACTIVE { return }
	c, e, k, u: win.FILETIME
	if !win.GetProcessTimes(h, &c, &e, &k, &u) { return 0, true }
	return u64(c.dwHighDateTime) << 32 | u64(c.dwLowDateTime), true
}

// The fingerprint of the running executable: the link time stamp and the image size of its PE header, "%08X%X" (what a symbol
// server keys an executable with). Every link writes a new time stamp, so it names one build.
@(private)
read_build :: proc "contextless" (buf: []u8) -> int {
	stamp, size, ok := pe_stamp_and_size(uintptr(win.GetModuleHandleW(nil)))
	if !ok { return 0 }
	o := Out{buf = buf}
	hex := "0123456789ABCDEF"
	for shift := 28; shift >= 0; shift -= 4 { out_byte(&o, hex[(stamp >> uint(shift)) & 15]) }
	h := Out{buf = sys.name[:]}
	out_hex(&h, u64(size))
	out_string(&o, string(sys.name[2:h.n]))   // (without its "0x")
	return o.n
}

// The header of a PE image mapped at `base`: TimeDateStamp of the file header, SizeOfImage of the optional header.
@(private = "file")
pe_stamp_and_size :: proc "contextless" (base: uintptr) -> (stamp, size: u32, ok: bool) {
	if base == 0 || (^u16)(base)^ != 0x5A4D { return }   // "MZ"
	nt := base + uintptr((^i32)(base + PE_NT_OFFSET)^)
	if (^u32)(nt)^ != 0x00004550 { return }   // "PE\0\0"
	return (^u32)(nt + PE_STAMP_OFFSET)^, (^u32)(nt + PE_SIZE_OF_IMAGE_OFFSET)^, true
}

////////////////////////////////
// A stack walked in a copy

@(private = "file")
stack_copy_init :: proc "contextless" (c: ^Stack_Copy) -> bool {
	c.bytes = ([^]u8)(win.VirtualAlloc(nil, STACK_COPY_MOST + STACK_COPY_SLACK, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_READWRITE))
	return c.bytes != nil
}

// Copies the stack `rsp` is on, from there to the end of its committed part, through ReadProcessMemory (which fails where a read
// would fault). False: the stack pointer points at nothing that can be read.
@(private = "file")
stack_copy_take :: proc "contextless" (c: ^Stack_Copy, rsp: u64) -> bool {
	c.low, c.high = 0, 0
	if c.bytes == nil { return false }
	info: win.MEMORY_BASIC_INFORMATION
	if win.VirtualQuery(rawptr(uintptr(rsp)), &info, size_of(info)) == 0 || info.State != win.MEM_COMMIT { return false }
	end := u64(uintptr(info.BaseAddress)) + u64(info.RegionSize)
	size := min(end - rsp, STACK_COPY_MOST)
	got: uint
	if !win.ReadProcessMemory(win.GetCurrentProcess(), rawptr(uintptr(rsp)), c.bytes, uint(size), &got) || got == 0 { return false }
	c.low, c.high = rsp, rsp + u64(got)
	return true
}

// The return addresses of the stack in `c`, innermost first, from the registers `ctx` (which the walk changes): at least the first.
@(private = "file")
stack_walk :: proc "contextless" (c: ^Stack_Copy, ctx: ^win.CONTEXT, pcs: []u64) -> int {
	stack_rebase(c, ctx)
	n := 0
	for n < len(pcs) && ctx.Rip != 0 {
		pcs[n] = ctx.Rip
		n += 1
		if !stack_step(c, ctx) { break }
	}
	return n
}

// What points into the stack points into the copy, whatever register it came back in.
@(private = "file")
stack_rebase :: proc "contextless" (c: ^Stack_Copy, ctx: ^win.CONTEXT) {
	for r in ([?]^u64{&ctx.Rsp, &ctx.Rbp, &ctx.Rbx, &ctx.Rsi, &ctx.Rdi, &ctx.R12, &ctx.R13, &ctx.R14, &ctx.R15}) {
		if r^ >= c.low && r^ < c.high { r^ = r^ - c.low + u64(uintptr(c.bytes)) }
	}
}

@(private = "file")
stack_holds :: proc "contextless" (c: ^Stack_Copy, at: u64) -> bool {
	buffer := u64(uintptr(c.bytes))
	return at >= buffer && at + size_of(u64) <= buffer + (c.high - c.low)
}

// From a frame to its caller. False: the walk went out of the stack, or would read through a register that is not on it.
@(private = "file")
stack_step :: proc "contextless" (c: ^Stack_Copy, ctx: ^win.CONTEXT) -> bool {
	if !stack_holds(c, ctx.Rsp) { return false }
	image: u64
	fn := RtlLookupFunctionEntry(ctx.Rip, &image, nil)
	if fn == nil {
		// a leaf, or code without tables: the return address is on top of the stack
		ctx.Rip = (^u64)(uintptr(ctx.Rsp))^
		ctx.Rsp += size_of(u64)
	} else {
		// (registers in the order of the context, Rax first: the numbers of the unwind codes)
		frame := int(([^]u8)(uintptr(image + u64(fn.unwind)))[FRAME_REGISTER_BYTE] & FRAME_REGISTER_MASK)
		if frame != 0 && !stack_holds(c, ([^]u64)(&ctx.Rax)[frame]) { return false }
		handler_data: rawptr
		establisher: u64
		RtlVirtualUnwind(0, image, ctx.Rip, fn, ctx, &handler_data, &establisher, nil)
	}
	stack_rebase(c, ctx)
	return true
}

// Whether the system's search for a handler, which walks the same stack, gets to the thread's start: the filter is called from
// there. On a stack it cannot follow to the end it gives up and ends the process, and the filter is never called.
@(private = "file")
search_reaches_the_filter :: proc "contextless" (at: ^win.CONTEXT) -> bool {
	low, high: uint
	GetCurrentThreadStackLimits(&low, &high)
	if at.Rsp < u64(low) || at.Rsp >= u64(high) { return false }
	stack: Stack_Copy
	if !stack_copy_init(&stack) { return true }   // (not known: the filter's turn)
	defer win.VirtualFree(stack.bytes, 0, win.MEM_RELEASE)
	if !stack_copy_take(&stack, at.Rsp) { return false }
	cut_short := stack.high - stack.low == STACK_COPY_MOST
	ctx := at^
	stack_rebase(&stack, &ctx)
	for ctx.Rip != 0 {
		was := ctx.Rsp
		if !stack_step(&stack, &ctx) { return cut_short }
		if ctx.Rsp <= was { return false }   // (a frame pointer written over can lead back down the stack: this walk would never end)
	}
	return true
}

////////////////////////////////
// The handlers

@(private = "file")
on_crash :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	// The thread that writes the report fell on what it reads: what it has written stays.
	if sys.writer_thread != 0 && sys.writer_thread == win.GetCurrentThreadId() && sys.writer_thread != sys.pending_thread {
		if sys.file != nil { win.CloseHandle(sys.file); sys.file = nil }
		win.SetEvent(sys.report_done)
		ExitThread(0)
	}
	hand_over(info)
	return 0   // EXCEPTION_CONTINUE_SEARCH: the process dies as it would have (exit code, event log)
}

@(private = "file")
on_fatal :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	code := u32(info.ExceptionRecord.ExceptionCode)
	switch code {
	case 0xC0000374, 0xC00000FD, 0xC0000409: hand_over(info)
	case:
		// Errors of the processor and the system (0xC...): most are someone's to handle, or reach the filter. Those on a stack the
		// system cannot walk reach neither.
		if code & ERROR_SEVERITY_MASK == ERROR_SEVERITY && !search_reaches_the_filter(info.ContextRecord) { hand_over(info) }
	}
	return 0   // EXCEPTION_CONTINUE_SEARCH
}

// Every faulting thread stays here until the report is written: the first fault's goes to the writer; a second one returned at once
// would let the system end the process under the writer.
@(private = "file")
hand_over :: proc "contextless" (info: ^win.EXCEPTION_POINTERS) {
	if intrinsics.atomic_exchange(&sys.reported, 1) != 0 {
		if sys.report_done != nil && sys.writer_thread != win.GetCurrentThreadId() { win.WaitForSingleObject(sys.report_done, REPORT_LIMIT_MS) }
		return
	}
	sys.pending, sys.pending_thread = info, win.GetCurrentThreadId()
	// (the parked thread is gone in what runs after ExitProcess, which ended every other thread)
	code: win.DWORD
	if sys.report_thread != nil && GetExitCodeThread(sys.report_thread, &code) && code == STILL_ACTIVE {
		win.SetEvent(sys.report_wake)
		win.WaitForSingleObject(sys.report_done, REPORT_LIMIT_MS)
		return
	}
	h := win.CreateThread(nil, REPORT_THREAD_STACK, write_report_thread, nil, 0, nil)
	if h == nil { write_report_thread(nil); return }   // (no thread to be had: here)
	win.WaitForSingleObject(h, REPORT_LIMIT_MS)
}

@(private = "file")
write_report_thread :: proc "system" (_: rawptr) -> win.DWORD {
	sys.writer_thread = win.GetCurrentThreadId()
	write_report(sys.pending, sys.pending_thread)
	if sys.report_done != nil { win.SetEvent(sys.report_done) }
	return 0
}

// The parked thread: wakes for the one report of the process.
@(private = "file")
parked_report_thread :: proc "system" (_: rawptr) -> win.DWORD {
	win.WaitForSingleObject(sys.report_wake, win.INFINITE)
	write_report_thread(nil)
	return 0
}

////////////////////////////////
// The report

@(private = "file")
write_report :: proc "contextless" (info: ^win.EXCEPTION_POINTERS, tid: win.DWORD) {
	rec := info.ExceptionRecord
	ctx := info.ContextRecord^   // unwound in a copy
	now := unix_now_contextless()
	open_report(CRASH_PREFIX, now)
	o := Out{buf = sys.out[:], sink = sink}
	code := u32(rec.ExceptionCode)
	address := u64(uintptr(rec.ExceptionAddress))
	if code == 0xC0000005 && rec.NumberParameters >= 2 { address = u64(uintptr(rec.ExceptionInformation[1])) }
	code_buf: [16]u8
	write_head(&o, Head{
		program = kept_program(), version = kept_version(), commit = kept_commit(), build = kept_build(), system = SYSTEM_NAME,
		date = out_date(sys.date[:], now), pid = u64(win.GetCurrentProcessId()), kind = KIND_EXCEPTION,
		code = code_text(code_buf[:], code), reason = code_reason(code, rec), address = address, pc = u64(uintptr(rec.ExceptionAddress)),
		thread = u64(tid),
	})
	remove_session_file()   // (the report says it now: the next start has no unclean session to report for this end)
	read_modules()
	n := walk(&ctx)
	write_frames(&o, u64(tid), true, sys.pcs[:n])
	out_flush(&o)
	write_other_threads(&o, tid)
	write_rest(&o, n)
	if kept.minidump { write_dump(info, tid) }
}

// The modules, the log, the settings, the names DbgHelp finds for the first thread's `named` frames (last: it allocates and takes
// locks the crash may have left held), and the end.
@(private = "file")
write_rest :: proc "contextless" (o: ^Out, named: int) {
	out_section(o, "modules")
	for i in 0 ..< sys.module_count {
		m := &sys.modules[i]
		out_module(o, m.base, m.size, string(sys.names[m.name_at:][:m.name_len]), string(sys.names[m.path_at:][:m.path_len]))
	}
	write_source(o, "log", kept.log_tail)
	write_source(o, "settings", kept.settings)
	out_flush(o)
	// (sys.pcs still holds the first thread's frames: the other threads were walked into their own buffer)
	out_section(o, "symbols")
	process := win.GetCurrentProcess()
	win.SymSetOptions(win.SYMOPT_LOAD_LINES | win.SYMOPT_DEFERRED_LOADS)
	if win.SymInitialize(process, nil, true) {
		raw: [size_of(win.SYMBOL_INFOW) + SYM_NAME_CHARS * 2]u8
		for pc in sys.pcs[:named] {
			sym := (^win.SYMBOL_INFOW)(&raw[0])
			sym.SizeOfStruct = size_of(win.SYMBOL_INFOW)
			sym.MaxNameLen = SYM_NAME_CHARS
			disp: u64
			if !win.SymFromAddrW(process, pc, &disp, sym) { continue }
			name: [SYM_NAME_CHARS * 3 + 24]u8
			no := Out{buf = name[:]}
			w := ([^]u16)(&sym.Name[0])[:min(int(sym.NameLen), SYM_NAME_CHARS)]
			out_utf16(&no, w)
			out_byte(&no, '+')
			out_hex(&no, disp)
			out_symbol(o, pc, string(name[:no.n]))
		}
	}
	out_section(o, "end")
	out_flush(o)
	if sys.file != nil { win.CloseHandle(sys.file); sys.file = nil }
}

@(private = "file")
walk :: proc "contextless" (ctx: ^win.CONTEXT) -> int {
	stack_copy_take(&sys.stack, ctx.Rsp)
	return stack_walk(&sys.stack, ctx, sys.pcs[:])
}

@(private = "file")
write_frames :: proc "contextless" (o: ^Out, tid: u64, crashed: bool, pcs: []u64) {
	out_thread(o, tid, "", crashed)
	for pc, i in pcs {
		name, base := module_of(pc)
		out_frame(o, i, pc, name, base != 0 ? pc - base : 0, "")
	}
}

// Every other thread of the process, suspended while its stack is copied.
@(private = "file")
write_other_threads :: proc "contextless" (o: ^Out, crashed: win.DWORD) {
	own := win.GetCurrentProcessId()
	me := win.GetCurrentThreadId()
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0)
	if snap == win.INVALID_HANDLE_VALUE { return }
	defer win.CloseHandle(snap)
	te := win.THREADENTRY32{dwSize = size_of(win.THREADENTRY32)}
	pcs: [MAX_FRAMES]u64
	count := 0
	for ok := bool(win.Thread32First(snap, &te)); ok && count < MAX_THREADS; ok = bool(win.Thread32Next(snap, &te)) {
		if te.th32OwnerProcessID != own || te.th32ThreadID == me || te.th32ThreadID == crashed { continue }
		count += 1
		h := win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT, false, te.th32ThreadID)
		if h == nil { continue }
		n := 0
		if win.SuspendThread(h) != ~win.DWORD(0) {
			ctx: win.CONTEXT
			ctx.ContextFlags = CONTEXT_FULL_AMD64
			got := win.GetThreadContext(h, &ctx)
			if got { stack_copy_take(&sys.stack, ctx.Rsp) }
			win.ResumeThread(h)
			if got { n = stack_walk(&sys.stack, &ctx, pcs[:]) }
		}
		win.CloseHandle(h)
		write_frames(o, u64(te.th32ThreadID), false, pcs[:n])
		out_flush(o)
	}
}

// The process's modules: base, size (the PE header's), file name and path, in the handler's buffers.
@(private = "file")
read_modules :: proc "contextless" () {
	sys.module_count, sys.names_len = 0, 0
	process := win.GetCurrentProcess()
	needed: win.DWORD
	if !K32EnumProcessModules(process, &sys.handles[0], size_of(sys.handles), &needed) { return }
	n := min(int(needed) / size_of(win.HMODULE), MAX_MODULES)
	wide: [win.MAX_PATH * 2]u16
	for i in 0 ..< n {
		h := sys.handles[i]
		base := u64(uintptr(h))
		_, size, _ := pe_stamp_and_size(uintptr(h))
		m := &sys.modules[sys.module_count]
		m.base, m.size = base, u64(size)
		got := int(K32GetModuleFileNameExW(process, h, &wide[0], len(wide)))
		m.path_at = sys.names_len
		names_utf16(wide[:got])
		m.path_len = sys.names_len - m.path_at
		path := string(sys.names[m.path_at:][:m.path_len])
		m.name_at, m.name_len = m.path_at, m.path_len
		for k in 0 ..< len(path) { if path[k] == '\\' || path[k] == '/' { m.name_at, m.name_len = m.path_at + k + 1, m.path_len - k - 1 } }
		sys.module_count += 1
	}
}

@(private = "file")
names_utf16 :: proc "contextless" (w: []u16) {
	o := Out{buf = sys.names[sys.names_len:]}
	out_utf16(&o, w)
	sys.names_len += o.n
}

// UTF-16 as UTF-8 (a lone surrogate becomes U+FFFD).
@(private = "file")
out_utf16 :: proc "contextless" (o: ^Out, w: []u16) {
	for i := 0; i < len(w); i += 1 {
		c := rune(w[i])
		if c >= 0xD800 && c < 0xDC00 && i + 1 < len(w) && w[i + 1] >= 0xDC00 && w[i + 1] < 0xE000 {
			c = 0x10000 + (c - 0xD800) << 10 + (rune(w[i + 1]) - 0xDC00)
			i += 1
		} else if c >= 0xD800 && c < 0xE000 {
			c = 0xFFFD
		}
		switch {
		case c < 0x80:
			out_byte(o, u8(c))
		case c < 0x800:
			out_byte(o, u8(0xC0 | c >> 6)); out_byte(o, u8(0x80 | c & 0x3F))
		case c < 0x10000:
			out_byte(o, u8(0xE0 | c >> 12)); out_byte(o, u8(0x80 | (c >> 6) & 0x3F)); out_byte(o, u8(0x80 | c & 0x3F))
		case:
			out_byte(o, u8(0xF0 | c >> 18)); out_byte(o, u8(0x80 | (c >> 12) & 0x3F)); out_byte(o, u8(0x80 | (c >> 6) & 0x3F)); out_byte(o, u8(0x80 | c & 0x3F))
		}
	}
}

@(private = "file")
module_of :: proc "contextless" (pc: u64) -> (name: string, base: u64) {
	for i in 0 ..< sys.module_count {
		m := &sys.modules[i]
		if pc >= m.base && pc < m.base + m.size { return string(sys.names[m.name_at:][:m.name_len]), m.base }
	}
	return "", 0
}

@(private = "file")
unix_now_contextless :: proc "contextless" () -> i64 {
	ft: win.FILETIME
	win.GetSystemTimeAsFileTime(&ft)
	ticks := u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime)
	return i64((ticks - FILETIME_UNIX_EPOCH) / FILETIME_TICKS_PER_SECOND)
}

// "<dir>\<prefix>-<date>-<pid>.txt" (the folder made first: nothing is made before a crash); the dump's path keeps its stem.
@(private = "file")
open_report :: proc "contextless" (prefix: string, now: i64) {
	if sys.dir[0] == 0 { return }
	// the folder and its parents
	n := 0
	for sys.dir[n] != 0 { sys.path[n] = sys.dir[n]; n += 1 }
	for i in 3 ..= n {
		if i < n && sys.path[i] != '\\' && sys.path[i] != '/' { continue }
		kept_unit := sys.path[i]
		sys.path[i] = 0
		win.CreateDirectoryW(cstring16(&sys.path[0]), nil)
		sys.path[i] = kept_unit
	}
	name := out_report_name(sys.name[:], prefix, now, u64(win.GetCurrentProcessId()))
	sys.path[n] = '\\'
	n += 1
	for c in name[:len(name) - len(REPORT_EXTENSION)] { sys.path[n] = u16(c); n += 1 }
	sys.path_stem = n
	report_extension(REPORT_EXTENSION)
	sys.file = win.CreateFileW(cstring16(&sys.path[0]), win.GENERIC_WRITE, win.FILE_SHARE_READ, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if sys.file == win.INVALID_HANDLE_VALUE { sys.file = nil }
}

@(private = "file")
report_extension :: proc "contextless" (e: string) {
	for i in 0 ..< len(e) { sys.path[sys.path_stem + i] = u16(e[i]) }
	sys.path[sys.path_stem + len(e)] = 0
}

// The minidump, last of all: the system stops every other thread for it and allocates, and one of them may hold the heap's lock.
@(private = "file")
write_dump :: proc "contextless" (info: ^win.EXCEPTION_POINTERS, tid: win.DWORD) {
	if sys.path_stem == 0 { return }
	report_extension(".dmp")
	dump := win.CreateFileW(cstring16(&sys.path[0]), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if dump == win.INVALID_HANDLE_VALUE { return }
	mei := win.MINIDUMP_EXCEPTION_INFORMATION{ThreadId = tid, ExceptionPointers = info, ClientPointers = false}
	win.MiniDumpWriteDump(win.GetCurrentProcess(), win.GetCurrentProcessId(), dump, win.MINIDUMP_TYPE(MINIDUMP_FLAGS), &mei, nil, nil)
	win.CloseHandle(dump)
}

@(private)
remove_session_file :: proc "contextless" () {
	if sys.session[0] != 0 { win.DeleteFileW(cstring16(&sys.session[0])) }
}

// On standard error and the report file, with nothing buffered past the handler's buffer.
@(private = "file")
sink :: proc "contextless" (o: ^Out, data: []u8) {
	written: win.DWORD
	if err := win.GetStdHandle(win.STD_ERROR_HANDLE); err != nil && err != win.INVALID_HANDLE_VALUE {
		win.WriteFile(err, raw_data(data), win.DWORD(len(data)), &written, nil)
	}
	if sys.file != nil { win.WriteFile(sys.file, raw_data(data), win.DWORD(len(data)), &written, nil) }
}

// "0xC0000005"
@(private = "file")
code_text :: proc "contextless" (buf: []u8, code: u32) -> string {
	o := Out{buf = buf}
	hex := "0123456789ABCDEF"
	out_string(&o, "0x")
	for shift := 28; shift >= 0; shift -= 4 { out_byte(&o, hex[(code >> uint(shift)) & 15]) }
	return string(buf[:o.n])
}

@(private = "file")
code_reason :: proc "contextless" (code: u32, rec: ^win.EXCEPTION_RECORD) -> string {
	switch code {
	case 0xC0000005:
		if rec.NumberParameters >= 1 {
			switch uintptr(rec.ExceptionInformation[0]) {
			case 0: return "access violation (reading)"
			case 1: return "access violation (writing)"
			case 8: return "access violation (executing)"
			}
		}
		return "access violation"
	case 0xC000001D: return "illegal instruction (an Odin assertion or bounds check)"
	case 0xC00000FD: return "stack overflow"
	case 0xC0000094: return "integer division by zero"
	case 0xC0000409: return "stack buffer overrun / fast fail"
	case 0xC0000374: return "heap corruption (the system found the heap damaged)"
	case 0x80000003: return "breakpoint"
	}
	return "exception"
}

////////////////////////////////
// An end the program chose itself

// A session that ends through ExitProcess or a TerminateProcess of itself, without end_session (a library that gives up, an exit
// forgotten on a path), left the same nothing as a kill. The calls are in the import table of the executable, whoever made them
// there (the Odin runtime, the C runtime, a Rust library): each is watched, and leaves an "exit" report with the stack that asked.
@(private = "file")
exit_watch_install :: proc "contextless" () {
	image := uintptr(win.GetModuleHandleW(nil))
	nt := (^win.IMAGE_NT_HEADERS64)(image + uintptr((^win.IMAGE_DOS_HEADER)(image).e_lfanew))
	imports := ([^]Import_Descriptor)(image + uintptr(nt.OptionalHeader.ImportTable.VirtualAddress))
	for d := 0; imports[d].dll != 0; d += 1 {
		names := ([^]u64)(image + uintptr(imports[d].names))
		slots := ([^]uintptr)(image + uintptr(imports[d].slots))
		for i := 0; names[i] != 0; i += 1 {
			if names[i] & IMPORT_BY_ORDINAL != 0 { continue }
			switch cstring(rawptr(image + uintptr(names[i]) + IMPORT_HINT_BYTES)) {
			case "ExitProcess":
				sys.real_exit = auto_cast rawptr(slots[i])
				import_write(&slots[i], uintptr(rawptr(watched_exit)))
			case "TerminateProcess":
				sys.real_terminate = auto_cast rawptr(slots[i])
				import_write(&slots[i], uintptr(rawptr(watched_terminate)))
			}
		}
	}
}

@(private = "file")
import_write :: proc "contextless" (slot: ^uintptr, value: uintptr) {
	old: u32
	win.VirtualProtect(slot, size_of(uintptr), win.PAGE_READWRITE, &old)
	slot^ = value
	win.VirtualProtect(slot, size_of(uintptr), old, &old)
}

@(private = "file")
watched_exit :: proc "system" (code: u32) {
	report_own_end(code)
	sys.real_exit(code)
}

@(private = "file")
watched_terminate :: proc "system" (process: win.HANDLE, code: u32) -> win.BOOL {
	if process == win.GetCurrentProcess() { report_own_end(code) }
	return sys.real_terminate(process, code)
}

@(private = "file")
report_own_end :: proc "contextless" (code: u32) {
	if intrinsics.atomic_exchange(&kept.session_open, 0) == 0 { return }
	if intrinsics.atomic_exchange(&sys.reported, 1) != 0 { return }
	ctx: win.CONTEXT
	RtlCaptureContext(&ctx)
	now := unix_now_contextless()
	open_report(EXIT_PREFIX, now)
	o := Out{buf = sys.out[:], sink = sink}
	code_buf: [16]u8
	tid := win.GetCurrentThreadId()
	write_head(&o, Head{
		program = kept_program(), version = kept_version(), commit = kept_commit(), build = kept_build(), system = SYSTEM_NAME,
		date = out_date(sys.date[:], now), pid = u64(win.GetCurrentProcessId()), kind = KIND_EXIT,
		code = code_text(code_buf[:], code), reason = "the program ended itself (ExitProcess or TerminateProcess) with its session open",
		pc = ctx.Rip, thread = u64(tid),
	})
	remove_session_file()
	read_modules()
	n := walk(&ctx)
	write_frames(&o, u64(tid), true, sys.pcs[:n])
	out_flush(&o)
	write_rest(&o, n)
}
