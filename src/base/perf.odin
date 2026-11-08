// Opt-in performance checks: the assertions on durations, CPU time, rates or frame counts in a time window run only when
// GUI_PERF is 1 or true, and never in CI (where the machines' speeds are unknown).
package base

import "core:fmt"
import "core:os"

// True when GUI_PERF is 1 or true, and CI is not defined.
perf_enabled :: proc() -> bool {
	if _, ci := os.lookup_env("CI", context.temp_allocator); ci { return false }
	v, _ := os.lookup_env("GUI_PERF", context.temp_allocator)
	return v == "1" || v == "true"
}

// True (and says so on the standard output) when the measurement `what` is not run.
perf_skip :: proc(what: string) -> bool {
	if perf_enabled() { return false }
	fmt.printfln("perf: skipped (%s), set GUI_PERF=1 to run", what)
	return true
}
