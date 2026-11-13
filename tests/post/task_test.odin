package post_test

import "core:sync"
import "core:testing"
import "core:time"
import "../../src/font"
import "../../src/ui"

// What should come is waited for at most this.
@(private = "file") TASK_WAIT :: 5 * time.Second

@(private = "file")
Task_Run :: struct {
	fonts:   font.State,
	theme:   ui.Theme,
	s:       ui.State,
	gate:    sync.Sema,   // the work waits for one post
	worked:  sync.Sema,   // posted when the work ended
	thread:  int,         // the work's thread
	done:    int,         // done ran (on the interface's thread)
	lost:    int,         // (atomic)
}

@(private = "file")
work :: proc(d: rawptr) {
	r := (^Task_Run)(d)
	sync.sema_wait(&r.gate)
	r.thread = sync.current_thread_id()
	sync.sema_post(&r.worked)
}

@(private = "file") done :: proc(d: rawptr, word: u64) { (^Task_Run)(d).done += 1 }
@(private = "file") lost :: proc(d: rawptr) { sync.atomic_add(&(^Task_Run)(d).lost, 1) }

// The work runs off the interface's thread; done runs on it, at the drain of the posts, once.
@(test)
a_task_works_elsewhere_and_comes_back :: proc(t: ^testing.T) {
	r := new(Task_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	defer ui.destroy(&r.s)
	ui.task(&r.s, work, done, r, lost)
	sync.sema_post(&r.gate)
	testing.expect(t, sync.sema_wait_with_timeout(&r.worked, TASK_WAIT), "the work ran")
	testing.expect(t, r.thread != sync.current_thread_id(), "on another thread")
	began := time.tick_now()
	for r.done == 0 && time.tick_since(began) < TASK_WAIT {
		ui.drain_posts(&r.s)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, r.done, 1)
	testing.expect_value(t, sync.atomic_load(&r.lost), 0)
}

// The State is destroyed while the work runs: done never runs (no State freed is touched), lost gets the data.
@(test)
a_task_that_ends_after_its_state_is_lost :: proc(t: ^testing.T) {
	r := new(Task_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	ui.task(&r.s, work, done, r, lost)
	ui.destroy(&r.s)
	sync.sema_post(&r.gate)
	testing.expect(t, sync.sema_wait_with_timeout(&r.worked, TASK_WAIT), "the work ran")
	began := time.tick_now()
	for sync.atomic_load(&r.lost) == 0 && time.tick_since(began) < TASK_WAIT { time.sleep(time.Millisecond) }
	testing.expect_value(t, sync.atomic_load(&r.lost), 1)
	testing.expect_value(t, r.done, 0)
}
