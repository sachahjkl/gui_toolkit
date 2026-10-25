// One clock for the process: a second ui.State made later (a second window) does not restart it.
//   odin test tests/clock -vet
package clock_test

import "core:testing"
import "core:time"
import "../../ui"

@(test)
a_second_state_keeps_the_clock :: proc(t: ^testing.T) {
	a, b: ui.State
	ui.init(&a, nil, nil)
	defer ui.destroy(&a)
	time.sleep(40 * time.Millisecond)
	before := ui.now_ms()
	ui.init(&b, nil, nil)
	defer ui.destroy(&b)
	testing.expect(t, before >= 35, "the clock runs from the first init")
	testing.expect(t, ui.now_ms() >= before, "and goes on after the second")
}