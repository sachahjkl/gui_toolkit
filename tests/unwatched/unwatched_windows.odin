#+build windows
package unwatched

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
