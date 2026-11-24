#+build windows
package render

import "core:testing"
import win "core:sys/windows"

// The frame latency object's surplus (present.odin: latency_lowered, latency_presented; present_windows.odin: latency_drain,
// latency_take), against a semaphore that stands for it. No clocks and no window: the semaphore's count is the object's.
// What the system does is modelled as src/md/infrastructure/frame-latency-object.md says: a frame that leaves the queue
// releases one count (retire), a raise of the latency releases the difference (set_latency).

@(private = "file")
count_of :: proc(h: win.HANDLE) -> (n: int) {
	for win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0 { n += 1 }
	return
}

// An object as DXGI makes it: MaximumFrameLatency counts (1), and room for the surplus of a long session.
@(private = "file")
new_object :: proc(counts: i32 = 1) -> win.HANDLE { return win.CreateSemaphoreW(nil, counts, 1 << 20, nil) }

// A frame left the queue (it reached the screen).
@(private = "file")
retire :: proc(h: win.HANDLE) { win.ReleaseSemaphore(h, 1, nil) }

// set_max_frame_latency: the system releases the difference of a raise; the renderer remembers a lowering.
@(private = "file")
set_latency :: proc(p: ^Present_State, h: win.HANDLE, to: int) {
	if cur := max(p.max_latency, 1); to > cur { win.ReleaseSemaphore(h, i32(to - cur), nil) }
	latency_lowered(p, to)
}

// The window's first frame (no wait: nothing shown yet), then one frame of a run, which holds the only slot: the frame after
// it waits until it reaches the screen. Returns with the queue empty.
@(private = "file")
open_window :: proc(t: ^testing.T, p: ^Present_State, h: win.HANDLE) {
	latency_presented(p)
	retire(h)
	testing.expect(t, latency_take(p, h, 0), "a frame of the run takes its slot")
	latency_presented(p)
	testing.expect(t, !latency_take(p, h, 0), "the next frame waits while one is in flight")
	retire(h)
}

// After the queue emptied: the next frame gets its slot, the one after it waits for that frame, and nothing is left over.
@(private = "file")
expect_one_frame_deep :: proc(t: ^testing.T, p: ^Present_State, h: win.HANDLE) {
	testing.expect(t, latency_take(p, h, 0), "the frame after the spam takes its slot")
	latency_presented(p)
	testing.expect(t, !latency_take(p, h, 0), "the frame after it waits, as before the spam")
	retire(h)
	testing.expect(t, latency_take(p, h, 0))
	testing.expect_value(t, count_of(h), 0)
	testing.expect_value(t, p.latency_debt, 0)
}

@(test)
a_resize_spam_in_the_size_loop_leaves_the_swap_chain_one_frame_deep :: proc(t: ^testing.T) {
	h := new_object()
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1}
	open_window(t, &p, h)
	// pace_frame with inner = true, the size changing at each step: shown at once, latency 2, no wait; one frame stays queued
	// behind the screen all through the spam
	set_latency(&p, h, 2)
	STEPS :: 200
	for i in 0 ..< STEPS {
		latency_presented(&p)
		if i > 0 { retire(h) }
	}
	retire(h)
	// the size stops: the next frame waits for its slot, then sets the latency back to 1
	testing.expect(t, latency_take(&p, h, 0))
	set_latency(&p, h, 1)
	latency_presented(&p)
	retire(h)
	expect_one_frame_deep(t, &p, h)
}

@(test)
steps_shown_at_once_between_waiting_frames_leave_nothing :: proc(t: ^testing.T) {
	h := new_object()
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1}
	open_window(t, &p, h)
	for _ in 0 ..< 200 {
		set_latency(&p, h, 2)   // a step: at once, no wait
		latency_presented(&p)
		retire(h)
		testing.expect(t, latency_take(&p, h, 0), "the frame between two steps waits for its slot")
		set_latency(&p, h, 1)
		latency_presented(&p)
		retire(h)
	}
	expect_one_frame_deep(t, &p, h)
}

@(test)
a_wait_that_timed_out_leaves_its_present_owed :: proc(t: ^testing.T) {
	h := new_object(0)   // a frame in flight that does not reach the screen in time
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1}
	testing.expect(t, !latency_take(&p, h, 0))
	latency_presented(&p)   // presented all the same
	testing.expect_value(t, p.latency_debt, 1)
	retire(h)
	retire(h)   // both reach the screen
	expect_one_frame_deep(t, &p, h)
}

@(test)
a_frame_that_presents_nothing_keeps_its_slot :: proc(t: ^testing.T) {
	h := new_object()
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1}
	testing.expect(t, latency_take(&p, h, 0))
	// (a region of nothing: no present) the next frame does not take a second count
	testing.expect(t, latency_take(&p, h, 0))
	latency_presented(&p)
	testing.expect_value(t, p.latency_debt, 0)
	testing.expect_value(t, count_of(h), 0)
}

@(test)
a_new_object_whose_first_frame_waits_owes_nothing :: proc(t: ^testing.T) {
	h := new_object()   // a chain made again (recover, a translucent window's alpha mode): the pacer has presented before
	defer win.CloseHandle(h)
	p := Present_State{max_latency = 1}   // as swapchain_latency leaves it
	testing.expect(t, latency_take(&p, h, 0), "the first wait finds the object's count")
	latency_presented(&p)
	retire(h)
	expect_one_frame_deep(t, &p, h)
}

@(test)
no_object_never_waits_nor_owes :: proc(t: ^testing.T) {
	p := Present_State{max_latency = 1}
	testing.expect(t, latency_take(&p, nil, 0))
	testing.expect(t, p.slot_taken)
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
