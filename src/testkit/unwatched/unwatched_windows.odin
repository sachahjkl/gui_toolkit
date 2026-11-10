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
	code:   u32,       // the exception that ended the body, 0 when it returned
	module: [260]u16,  // where it was raised
	offset: uintptr,
}

@(private, thread_local)
current: ^Job

// The body on a thread of its own; its exception, when it ends by one, fails the test.
@(private)
run_unwatched :: proc(t: ^testing.T, body: proc(t: ^testing.T), loc: runtime.Source_Code_Location) {
	job := Job{t = t, body = body}
	th := thread.create_and_start_with_data(&job, proc(data: rawptr) {
		current = (^Job)(data)
		t := current.t
		first := len(t.cleanups)
		current.body(t)
		current = nil
		// (the body's own cleanups, here: what it made is this thread's)
		for i := len(t.cleanups) - 1; i >= first; i -= 1 {
			c := t.cleanups[i]
			context = c.ctx
			c.procedure(c.user_data)
		}
		resize(&t.cleanups, first)
	}, init_context = context)
	thread.join(th)
	thread.destroy(th)
	// (testing.fail_now ends the body with a trap too, after saying why)
	if job.code != 0 && !t._fail_now_called {
		module := module_name(job.module[:])
		testing.expectf(t, false, "exception 0x%08X at %s+0x%X in %s", job.code, module, job.offset, loc.procedure, loc = loc)
		fmt.eprintfln("unwatched: exception 0x%08X at %s+0x%X in %s", job.code, module, job.offset, loc.procedure)
		os.flush(os.stderr)
	}
}
