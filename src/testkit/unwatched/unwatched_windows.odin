#+build windows
package unwatched

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(private, default_calling_convention = "system")
foreign kernel32 {
	ExitThread         :: proc(code: u32) -> ! ---
	GetModuleHandleExW :: proc(flags: u32, address: rawptr, module: ^win32.HMODULE) -> win32.BOOL ---
}

@(private) MSVC_CXX_EXCEPTION :: 0xE06D7363
@(private) GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: 0x2
@(private) GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS :: 0x4

// Last in the chain: after AddressSanitizer's, which commits its shadow memory on access violations (the runner's,
// added later, only looks at the test threads themselves).
@(private, init)
install :: proc "contextless" () {
	win32.AddVectoredExceptionHandler(0, handler)
}

@(private, no_sanitize_address)
handler :: proc "system" (info: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
	job := current
	code := u32(info.ExceptionRecord.ExceptionCode)
	// (below 0x8000_0000: informational codes, which the runner lets pass too)
	if job == nil || code < 0x8000_0000 || code == MSVC_CXX_EXCEPTION { return win32.EXCEPTION_CONTINUE_SEARCH }
	context = job.ctx
	// (testing.fail_now: a stop the body asked for, its message said, its state whole: as end_body)
	if job.t._fail_now_called { body_exit(job) }
	job.code = code
	address := info.ExceptionRecord.ExceptionAddress
	m: win32.HMODULE
	if GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, address, &m) != win32.FALSE {
		win32.GetModuleFileNameW(m, raw_data(job.module[:]), u32(len(job.module) - 1))
		job.offset = uintptr(address) - uintptr(m)
	} else {
		job.offset = uintptr(address)
	}
	current = nil
	ExitThread(1)
}

@(private)
module_name :: proc(w: []u16) -> string {
	n := 0
	for n < len(w) && w[n] != 0 { n += 1 }
	s, _ := win32.utf16_to_utf8(w[:n], context.temp_allocator)
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == '\\' { return s[i + 1:] }
	}
	return s if s != "" else "?"
}

@(private)
Job :: struct {
	t:      ^testing.T,
	body:   proc(t: ^testing.T),
	ctx:    runtime.Context,   // the body's (the handler has none of its own)
	first:  int,       // the first of t.cleanups that the body made
	code:   u32,       // the exception that ended the body, 0 when it returned
	module: [260]u16,  // where it was raised
	offset: uintptr,
}

@(private, thread_local)
current: ^Job

// Calls body(t) on a thread of its own and waits for it (unwatched.odin says why).
run :: proc(t: ^testing.T, body: proc(t: ^testing.T), loc := #caller_location) { run_unwatched(t, body, loc) }

// Ends the body here when this is its thread (unwatched.odin says why): its cleanups are done, the thread ends, and run
// returns on the test's thread. Elsewhere it does nothing: the caller ends the test its own way.
end_body :: proc(t: ^testing.T) {
	if job := current; job != nil && job.t == t { body_exit(job) }
}

// The body ends as if it returned, but here: its deferred statements do not run (as with testing.fail_now).
@(private)
body_exit :: proc(job: ^Job) -> ! {
	current = nil
	body_cleanups(job)
	// (what the thread's entry does after its procedure returns, which ExitThread skips)
	runtime.run_thread_local_cleaners()
	ExitThread(1)
}

// The body's own cleanups, last first, on its thread: what it made is this thread's.
@(private)
body_cleanups :: proc(job: ^Job) {
	t := job.t
	for i := len(t.cleanups) - 1; i >= job.first; i -= 1 {
		c := t.cleanups[i]
		context = c.ctx
		c.procedure(c.user_data)
	}
	resize(&t.cleanups, job.first)
}

// The body on a thread of its own; its exception, when it ends by one, fails the test.
@(private)
run_unwatched :: proc(t: ^testing.T, body: proc(t: ^testing.T), loc: runtime.Source_Code_Location) {
	job := Job{t = t, body = body, ctx = context, first = len(t.cleanups)}
	th := thread.create_and_start_with_data(&job, proc(data: rawptr) {
		job := (^Job)(data)
		current = job
		job.body(job.t)
		current = nil
		body_cleanups(job)
	}, init_context = context)
	// (the thread ends in every case: the body returns, end_body or fail_now, an exception; so this join returns and
	// the Thread is freed)
	thread.join(th)
	thread.destroy(th)
	if job.code != 0 {
		module := module_name(job.module[:])
		testing.expectf(t, false, "exception 0x%08X at %s+0x%X in %s", job.code, module, job.offset, loc.procedure, loc = loc)
		fmt.eprintfln("unwatched: exception 0x%08X at %s+0x%X in %s", job.code, module, job.offset, loc.procedure)
		os.flush(os.stderr)
	}
}
