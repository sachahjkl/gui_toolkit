package draw

// Failures that cannot be had at will (the renderer refusing a target of a size it just gave), forced for a test: each path
// then runs once. On in `odin test`, compiled out of any other build.

DRAW_FAILURE_HOOKS :: #config(DRAW_FAILURE_HOOKS, ODIN_TEST)

Forced_Failure :: enum u8 { Mask_Target }

when DRAW_FAILURE_HOOKS {
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
