// ui.Deferred: something done once things are quiet, by the toolkit's clock (a test's: ui.set_clock).
//   odin test tests/deferred -vet
package deferred_test

import "core:testing"
import "../../src/ui"

@(private = "file") WAIT_MS :: 100
@(private = "file") MOST_MS :: 1000

// A state on a clock the test moves (the clock starts past 0: a due time of 0 is "nothing asked").
@(private = "file")
with_clock :: proc(s: ^ui.State, clock: ^f64) {
	ui.init(s, nil, nil)
	clock^ = 1000
	ui.set_clock(s, clock)
}

@(test)
asked_again_it_fires_once_after_the_last_ask :: proc(t: ^testing.T) {
	s: ui.State
	clock: f64
	with_clock(&s, &clock)
	defer ui.destroy(&s)
	d: ui.Deferred
	testing.expect_value(t, ui.deferred_in_ms(&d), 0)
	ui.deferred_ask(&d, WAIT_MS, MOST_MS)
	testing.expect_value(t, ui.deferred_in_ms(&d), WAIT_MS + 1)
	clock += WAIT_MS - 1
	ui.deferred_ask(&d, WAIT_MS, MOST_MS)   // (it moves back)
	clock += 2
	testing.expect(t, !ui.deferred_take(&d), "not at the first ask's time")
	clock += WAIT_MS
	testing.expect(t, ui.deferred_take(&d), "a wait after the last ask")
	testing.expect(t, !ui.deferred_take(&d), "once")
	testing.expect_value(t, ui.deferred_in_ms(&d), 0)
}

@(test)
asked_without_end_it_fires_at_its_cap :: proc(t: ^testing.T) {
	s: ui.State
	clock: f64
	with_clock(&s, &clock)
	defer ui.destroy(&s)
	d: ui.Deferred
	start := clock
	fired := 0
	at: f64
	for clock < start + 3 * MOST_MS {
		ui.deferred_ask(&d, WAIT_MS, MOST_MS)
		clock += WAIT_MS / 2
		if ui.deferred_take(&d) {
			fired += 1
			if fired == 1 { at = clock }
		}
	}
	testing.expect(t, fired >= 2, "it keeps firing")
	testing.expect(t, at >= start + MOST_MS && at < start + MOST_MS + WAIT_MS, "the first: at its cap after the first ask")
}

// No cap given: never later than the first wait.
@(test)
without_a_cap_the_first_wait_is_the_cap :: proc(t: ^testing.T) {
	s: ui.State
	clock: f64
	with_clock(&s, &clock)
	defer ui.destroy(&s)
	d: ui.Deferred
	ui.deferred_ask(&d, WAIT_MS)
	clock += WAIT_MS / 2
	ui.deferred_ask(&d, WAIT_MS)
	clock += WAIT_MS / 2
	testing.expect(t, ui.deferred_take(&d))
}
