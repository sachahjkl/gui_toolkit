// One clock for the process: a second ui.State made later (a second window) does not restart it.
//   odin test tests/clock -vet
package clock_test

import "core:testing"
import "core:thread"
import "../../src/ui"

// The clock has run for this long: it is running.
@(private = "file") RUNS_MS :: 2

@(test)
a_second_state_keeps_the_clock :: proc(t: ^testing.T) {
	a, b: ui.State
	ui.init(&a, nil, nil)
	defer ui.destroy(&a)
	for ui.now_ms() < RUNS_MS { thread.yield() }
	before := ui.now_ms()
	ui.init(&b, nil, nil)
	defer ui.destroy(&b)
	testing.expect(t, before >= RUNS_MS, "the clock runs from the first init")
	testing.expect(t, ui.now_ms() >= before, "and goes on after the second")
}