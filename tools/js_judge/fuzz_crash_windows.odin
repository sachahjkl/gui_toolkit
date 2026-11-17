package jsrt_judge

// A mutant that crashes the judge says which instruction and native it was in (fuzz_run_one), through a vectored
// exception handler that lets the crash go on.

import "base:runtime"
import "core:fmt"
import win "core:sys/windows"
import js "../../src/js"

// The runtime of the reproducer: what ran last is its own (Runtime.trace), and the handler has no other way to it.
@(private = "file")
crash_rt: ^js.Runtime

fuzz_crash_report_install :: proc(rt: ^js.Runtime) {
	crash_rt = rt
	win.AddVectoredExceptionHandler(1, crash_handler)
}

@(private = "file")
crash_handler :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	context = runtime.default_context() // memcheck: the JavaScript engine's own heap (a guest allocator), not the browser's process memory
	when js.JSRT_TRACE_LAST_OP {
		tr := &crash_rt.trace
		name := "?"
		if tr.bc != nil {name = fmt.tprint(tr.bc.func_name)}
		nname := "?"
		if o := tr.native_obj; o != nil {
			i := js.shape_find(o.shape, js.pa(.A_name))
			if i >= 0 && o.slots[i].value.tag == .string {
				s := js.as_str(o.slots[i].value)
				if !s.is_wide && !s.is_rope {nname = string(js.str_u8(s)[:s.len])}
			}
		}
		fmt.eprintf("crash 0x%x after %v in function atom %s (last native %s)\n", info.ExceptionRecord.ExceptionCode, tr.op, name, nname)
		for a, i in tr.native_args {fmt.eprintf("  arg %d: %v %p\n", i, a.tag, a.u.ptr)}
	} else {
		fmt.eprintf("crash 0x%x (build with -define:JSRT_TRACE_LAST_OP=true for the last instruction)\n", info.ExceptionRecord.ExceptionCode)
	}
	return 0 // EXCEPTION_CONTINUE_SEARCH
}
