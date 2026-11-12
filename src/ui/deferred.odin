package ui

// Something to do once things are quiet: asked again it moves back, so that it comes after what asked for it (an event after a
// request reads what that request changed), but never later than `most_ms` after the first asking: events without end still
// get it done. It goes by the toolkit's clock (now_ms: a test's clock moves it).
//
//	deferred_ask(&app.refresh, 150, 1000)            // each event
//	if deferred_take(&app.refresh) { refresh(app) }  // each frame; once, when it is due
//	wake := deferred_in_ms(&app.refresh)             // how long a window at rest may sleep (0: nothing asked)
Deferred :: struct { due_ms, latest_ms: f64 }   // (0: nothing asked)

// Due `wait_ms` from now, and no later than `most_ms` after the first ask since it was last taken (`most_ms` 0: no later than
// the first wait). To start a wait over, clear it first (`d^ = {}`).
deferred_ask :: proc(d: ^Deferred, wait_ms: f64, most_ms: f64 = 0) {
	now := now_ms()
	if d.due_ms == 0 { d.latest_ms = now + max(most_ms, wait_ms) }
	d.due_ms = min(now + wait_ms, d.latest_ms)
}

// Whether it is time, once: it is then no longer asked.
deferred_take :: proc(d: ^Deferred) -> bool {
	if d.due_ms == 0 || now_ms() < d.due_ms { return false }
	d^ = {}
	return true
}

// In how long, in whole ms (at least 1); 0: nothing asked.
deferred_in_ms :: proc(d: ^Deferred) -> int {
	if d.due_ms == 0 { return 0 }
	return max(int(d.due_ms - now_ms()) + 1, 1)
}
