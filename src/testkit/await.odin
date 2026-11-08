package tk_testkit

import "core:thread"
import "core:time"

// What a wait for another thread may take: it only ends a failing run.
AWAIT_LIMIT :: 30 * time.Second

// Waits until `ready` says that the state another thread is reaching is there: a barrier on that state, where the code under test
// has no signal of its own. It gives its time slice away between looks and sleeps for no fixed time. False when the limit passed
// (the caller's check then fails).
await :: proc(data: ^$T, ready: proc(data: ^T) -> bool, limit: time.Duration = AWAIT_LIMIT) -> bool {
	start := time.tick_now()
	for !ready(data) {
		if time.tick_since(start) > limit { return false }
		give_way()
	}
	return true
}

// (not generic: a program that never calls `await` still has its import used)
@(private) give_way :: proc() { thread.yield() }
