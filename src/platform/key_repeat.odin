package platform

// The auto-repeat of a held key, for a system that leaves it to the client (Wayland: wl_keyboard.repeat_info gives the
// rate and the delay, the client makes the repeats). Pure: the caller gives the time (ms on any clock).
//
//   key_repeat_press(&r, code, now)         // a key that repeats went down
//   key_repeat_release(&r, code)            // a key went up (only the last one pressed repeats)
//   for key_repeat_take(&r, now) { ... }    // each repeat that is due
//   key_repeat_wait_ms(&r, now)             // how long the loop may sleep (-1: nothing is held)

Key_Repeat :: struct {
	rate:     int,    // repeats per second (0: no repeat)
	delay_ms: int,
	held:     bool,
	code:     u32,    // the key that repeats
	next_ms:  f64,    // when the next repeat is due
}

key_repeat_press :: proc(r: ^Key_Repeat, code: u32, now_ms: f64) {
	r.held = r.rate > 0
	r.code = code
	r.next_ms = now_ms + f64(r.delay_ms)
}

// Only the key that repeats stops the repeat.
key_repeat_release :: proc(r: ^Key_Repeat, code: u32) {
	if r.held && r.code == code { r.held = false }
}

// Whether a repeat is due now; it is then counted. After a stall the repeats missed are dropped, not made in a burst.
key_repeat_take :: proc(r: ^Key_Repeat, now_ms: f64) -> bool {
	if !r.held || now_ms < r.next_ms { return false }
	period := 1000 / f64(r.rate)
	r.next_ms += period
	if r.next_ms <= now_ms { r.next_ms = now_ms + period }
	return true
}

// How long before the next repeat is due, rounded up (0: now; -1: nothing is held).
key_repeat_wait_ms :: proc(r: ^Key_Repeat, now_ms: f64) -> int {
	if !r.held { return -1 }
	return r.next_ms <= now_ms ? 0 : int(r.next_ms - now_ms + WAIT_CEIL_MS)
}
