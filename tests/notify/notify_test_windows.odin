package notify_test

// Windows: notify_async hands the notification to the notification thread and returns at once; `done` comes back
// through the window's loop, on the window's thread. platform.notify_test_hook stands for the system, so no toast is
// ever shown, and lets an offscreen window take notifications.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import base "gt:base"
import "gt:platform"

@(private = "file") WAIT :: 3 * time.Second

// What the hook saw, on the notification thread (read by the test once `done` came, which the hook's answer precedes).
@(private = "file")
Probe :: struct {
	release:     sync.Sema,   // the test lets the hook answer once notify_async returned
	returned:    bool,        // (atomic) the test's: notify_async returned
	saw_return:  bool,        // the hook's: notify_async had returned when the hook was let go
	waited:      bool,        // the hook was let go within the bound
	hook_thread: int,
	title:       string,      // (heap) the notification's title, read after the caller reused its buffer
	status:      string,      // (heap) its progress's status
	ids:         [dynamic]platform.Notification_Id,
}

@(private = "file") probe: Probe

@(private = "file")
probe_hook :: proc(n: platform.Notification, id: platform.Notification_Id) -> bool {
	probe.hook_thread = sync.current_thread_id()
	probe.waited = sync.sema_wait_with_timeout(&probe.release, WAIT)
	probe.saw_return = sync.atomic_load(&probe.returned)
	delete(probe.title, runtime.heap_allocator())
	probe.title = strings.clone(n.title, runtime.heap_allocator())
	delete(probe.status, runtime.heap_allocator())
	probe.status = strings.clone(n.progress.status, runtime.heap_allocator())
	append(&probe.ids, id)
	return true
}

@(private = "file")
Answers :: struct {
	count:  int,
	id:     platform.Notification_Id,
	ok:     bool,
	thread: int,
}

@(private = "file")
answer_done :: proc(user: rawptr, id: platform.Notification_Id, ok: bool) {
	a := (^Answers)(user)
	a.count += 1
	a.id, a.ok = id, ok
	a.thread = sync.current_thread_id()
}

// Polls `w` until `a` has `count` answers, or the bound ran out.
@(private = "file")
wait_answers :: proc(w: ^platform.Window, a: ^Answers, count: int, seen: ^[dynamic]platform.Event) -> bool {
	start := time.tick_now()
	for a.count < count && time.tick_since(start) < WAIT {
		for e in platform.poll_events(w, true, 50) { append(seen, e) }
	}
	return a.count >= count
}

@(test)
notify_async_returns_at_once_and_done_comes_by_the_loop :: proc(t: ^testing.T) {
	w := platform.open_window_offscreen("notify", {200, 100})
	if !testing.expect(t, w != nil) { return }
	defer platform.destroy_window(w)
	probe = {ids = make([dynamic]platform.Notification_Id, runtime.heap_allocator())}
	defer {
		delete(probe.title, runtime.heap_allocator())
		delete(probe.status, runtime.heap_allocator())
		delete(probe.ids)
		probe = {}
	}
	platform.notify_test_hook = probe_hook
	defer platform.notify_test_hook = nil

	// (this thread builds an interface from now on: a call that blocks is counted. It stays marked: the package's
	// other tests on Windows are pure)
	base.interface_thread_mark()
	answers: Answers
	seen: [dynamic]platform.Event
	defer delete(seen)

	title := make([]u8, 5)
	defer delete(title)
	copy(title, "first")
	blocked := base.blocking_count_here()
	sent := platform.notify_async(w, {title = string(title)}, answer_done, &answers)
	sync.atomic_store(&probe.returned, true)
	testing.expect(t, sent)
	testing.expect_value(t, base.blocking_count_here(), blocked)
	testing.expect_value(t, answers.count, 0)   // (the answer comes by the loop, never inside the call)
	for &c in title { c = 'x' }   // the caller's buffer, reused: the notification thread holds its own copy
	sync.sema_post(&probe.release)

	if !testing.expect(t, wait_answers(w, &answers, 1, &seen), "done within the bound") { return }
	testing.expect(t, probe.waited, "the hook answered after notify_async returned")
	testing.expect(t, probe.saw_return)
	testing.expect(t, probe.hook_thread != sync.current_thread_id(), "the system is asked on the notification thread")
	testing.expect_value(t, probe.title, "first")
	testing.expect(t, answers.ok)
	testing.expect(t, answers.id != 0)
	testing.expect_value(t, answers.thread, sync.current_thread_id())
	first := answers.id

	// a replace keeps the id, and is decided without waiting for the first answer
	sync.sema_post(&probe.release)
	testing.expect(t, platform.notify_async(w, {title = "second", replace = first}, answer_done, &answers))
	if !testing.expect(t, wait_answers(w, &answers, 2, &seen)) { return }
	testing.expect_value(t, answers.id, first)
	testing.expect_value(t, probe.title, "second")
	testing.expect_value(t, len(probe.ids), 2)

	// a progress sent again with the same id: the notification thread gets its own copy of the bar's words
	sync.sema_post(&probe.release)
	testing.expect(t, platform.notify_async(w, {title = "second", replace = first, progress = {shown = true, value = 0.5, status = "half"}}, answer_done, &answers))
	if !testing.expect(t, wait_answers(w, &answers, 3, &seen)) { return }
	testing.expect_value(t, answers.id, first)
	testing.expect_value(t, probe.status, "half")

	// closed by the program: Notification_Closed (Closed) at once, and only once
	platform.notify_close(w, first)
	platform.notify_close(w, first)
	closed := 0
	for e in platform.poll_events(w, false) {
		if e.kind == .Notification_Closed {
			closed += 1
			testing.expect_value(t, e.notification.id, first)
			testing.expect_value(t, e.notification.reason, platform.Notification_Reason.Closed)
		}
	}
	testing.expect_value(t, closed, 1)
	testing.expect_value(t, base.blocking_count_here(), blocked)
}
