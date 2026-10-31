package font

// Failures that cannot be had at will (Direct2D refusing a device, the memory running out), forced for a test: each path
// then runs once. On in `odin test`, compiled out of any other build.

FONT_FAILURE_HOOKS :: #config(FONT_FAILURE_HOOKS, ODIN_TEST)

Forced_Failure :: enum u8 { D2d_Device, D2d_Context, D2d_Brush, Colr_Stops, Colr_Scan, Colr_Clip, Word_Alloc, Bidi }

when FONT_FAILURE_HOOKS {
	// What the next calls on this thread fail, each one once: a test sets it, and finds it empty when the path ran.
	@(thread_local) forced_failures: bit_set[Forced_Failure]

	@(private)
	failing :: proc "contextless" (f: Forced_Failure) -> bool {
		if f not_in forced_failures { return false }
		forced_failures -= {f}
		return true
	}
} else {
	@(private)
	failing :: #force_inline proc "contextless" (f: Forced_Failure) -> bool { return false }
}
