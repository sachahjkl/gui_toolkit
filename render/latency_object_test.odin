#+build windows
package render

import "core:testing"
import win "core:sys/windows"

// The frame latency object's surplus (present.odin: latency_lowered, latency_drain), against a semaphore that stands for it.
// No clocks and no window: the semaphore's count is the object's.

@(private = "file")
count_of :: proc(h: win.HANDLE) -> (n: int) {
	for win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0 { n += 1 }
	return
}

@(test)
lowering_the_latency_remembers_what_the_object_keeps :: proc(t: ^testing.T) {
	p := Present_State{max_latency = 1}
	latency_lowered(&p, 2)
	testing.expect_value(t, p.latency_debt, 0)   // raising: the system adds the slot, nothing is owed
	testing.expect_value(t, p.max_latency, 2)
	latency_lowered(&p, 1)
	testing.expect_value(t, p.latency_debt, 1)
	latency_lowered(&p, 3)
	testing.expect_value(t, p.latency_debt, 1)
	latency_lowered(&p, 1)
	testing.expect_value(t, p.latency_debt, 3)   // 3 -> 1 again leaves two more
}

@(test)
latency_not_set_yet_counts_as_one :: proc(t: ^testing.T) {
	p: Present_State
	latency_lowered(&p, 1)
	testing.expect_value(t, p.latency_debt, 0)
}

@(test)
the_surplus_is_taken_without_waiting_and_only_up_to_what_is_owed :: proc(t: ^testing.T) {
	h := win.CreateSemaphoreW(nil, 3, 8, nil)   // after 1 -> 2 -> 1 -> 2 -> 1 the object holds a slot and two surplus counts
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1, latency_debt = 2}
	latency_drain(&p, h)
	testing.expect_value(t, p.latency_debt, 0)
	testing.expect_value(t, count_of(h), 1)   // one slot left, as at max latency 1
}

@(test)
the_surplus_waits_for_counts_the_object_does_not_have_yet :: proc(t: ^testing.T) {
	h := win.CreateSemaphoreW(nil, 0, 8, nil)   // a frame is in flight: nothing to take now
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1, latency_debt = 1}
	latency_drain(&p, h)
	testing.expect_value(t, p.latency_debt, 1)   // still owed
	win.ReleaseSemaphore(h, 1, nil)   // the frame reached the screen
	latency_drain(&p, h)
	testing.expect_value(t, p.latency_debt, 0)
	testing.expect_value(t, count_of(h), 0)
}

@(test)
nothing_owed_takes_nothing :: proc(t: ^testing.T) {
	h := win.CreateSemaphoreW(nil, 1, 8, nil)
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1}
	latency_drain(&p, h)
	testing.expect_value(t, count_of(h), 1)
}
