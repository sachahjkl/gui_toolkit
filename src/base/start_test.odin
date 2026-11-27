package gt_base

import "core:testing"

// The start clock counts from the process's start as the system knows it, not from main: on Linux and Windows the
// process has lived a little before this test, the loading of the program at least. Steps come back in the order they
// were marked, each at its time; a step marked again (a second window's renderer) is not kept again, and marks past the
// list's room are dropped, never written past it. (One test: the list is the process's.)
@(test)
the_start_is_the_process_s :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux || ODIN_OS == .Windows {
		testing.expect(t, process_age_ns() > 0, "the system says when the process started")
	}
	before := start_ms()
	testing.expect(t, before > 0, "time has passed since the start")
	testing.expect(t, start_mark("test: one"), "kept")
	testing.expect(t, start_mark("test: two"), "kept")
	buf: [START_STEPS_MAX]Start_Step
	steps := start_steps(buf[:])
	one, two := -1, -1
	for s, i in steps {
		if s.what == "test: one" { one = i }
		if s.what == "test: two" { two = i }
	}
	if !testing.expect(t, one >= 0 && two == one + 1, "both steps, in their order") { return }
	testing.expect(t, steps[one].ms >= before && steps[two].ms >= steps[one].ms, "each at its time")
	testing.expect_value(t, len(start_steps(buf[:0])), 0)

	// marked again: its first time stays, alone
	at := steps[one].ms
	for _ in 0 ..< 3 * START_STEPS_MAX { testing.expect(t, !start_mark("test: one"), "not kept again") }
	seen := 0
	for s in start_steps(buf[:]) { if s.what == "test: one" { seen += 1; testing.expect_value(t, s.ms, at) } }
	testing.expect_value(t, seen, 1)

	// more steps than room: the first ones are kept, the list never passes its room
	fill := FILL_STEPS
	for n in fill { _ = start_mark(n) }
	testing.expect_value(t, len(start_steps(buf[:])), START_STEPS_MAX)
	testing.expect(t, !start_mark("test: past the room"), "no room")
}

// (constant strings: start_mark keeps the text, it does not copy it)
@(private = "file") FILL_STEPS :: [?]string{"test: fill 0", "test: fill 1", "test: fill 2", "test: fill 3", "test: fill 4", "test: fill 5", "test: fill 6", "test: fill 7", "test: fill 8", "test: fill 9", "test: fill 10", "test: fill 11", "test: fill 12", "test: fill 13", "test: fill 14", "test: fill 15", "test: fill 16", "test: fill 17", "test: fill 18", "test: fill 19", "test: fill 20", "test: fill 21", "test: fill 22", "test: fill 23", "test: fill 24", "test: fill 25", "test: fill 26", "test: fill 27", "test: fill 28", "test: fill 29", "test: fill 30", "test: fill 31", "test: fill 32", "test: fill 33", "test: fill 34", "test: fill 35", "test: fill 36", "test: fill 37", "test: fill 38", "test: fill 39", "test: fill 40", "test: fill 41", "test: fill 42", "test: fill 43", "test: fill 44", "test: fill 45", "test: fill 46", "test: fill 47", "test: fill 48", "test: fill 49", "test: fill 50", "test: fill 51"}
