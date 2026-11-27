package post_test

import "core:sync"
import "core:testing"
import "core:time"
import "gt:font"
import "gt:tasks"
import "gt:ui"

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

// The answer is queued, and the State is destroyed before a build runs it: done never runs, lost gets the data (it
// leaked: the queue dropped the answer with nothing to free it).
@(test)
a_task_whose_answer_waits_when_its_state_goes_is_lost :: proc(t: ^testing.T) {
	r := new(Task_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	ui.task(&r.s, work, done, r, lost)
	sync.sema_post(&r.gate)
	testing.expect(t, sync.sema_wait_with_timeout(&r.worked, TASK_WAIT), "the work ran")
	began := time.tick_now()
	for !ui.posts_pending(&r.s) && time.tick_since(began) < TASK_WAIT { time.sleep(time.Millisecond) }
	testing.expect(t, ui.posts_pending(&r.s), "the answer is queued")
	ui.destroy(&r.s)
	testing.expect_value(t, sync.atomic_load(&r.lost), 1)
	testing.expect_value(t, r.done, 0)
}

// Two apps in turn in one process (a program's tests, a second window after the first closed): the first ends as a
// program ends, its chores stopped; the second's task still answers. The chores once stopped for good, every later
// ui.task, ui.open and file dialog of the process never answered.
@(test)
a_task_after_an_app_that_stopped_the_chores_answers :: proc(t: ^testing.T) {
	for app in 0 ..< 2 {
		r := new(Task_Run)
		font.init(&r.fonts)
		ui.init(&r.s, &r.fonts, &r.theme)
		ui.task(&r.s, work, done, r, lost)
		sync.sema_post(&r.gate)
		testing.expectf(t, sync.sema_wait_with_timeout(&r.worked, TASK_WAIT), "app %d: the work ran", app)
		began := time.tick_now()
		for r.done == 0 && time.tick_since(began) < TASK_WAIT {
			ui.drain_posts(&r.s)
			time.sleep(time.Millisecond)
		}
		testing.expectf(t, r.done == 1, "app %d: its task answered", app)
		testing.expect_value(t, sync.atomic_load(&r.lost), 0)
		// (as a program's end: the chores stopped, then the State destroyed)
		testing.expect(t, ui.chores_stop())
		ui.destroy(&r.s)
		font.destroy(&r.fonts)
		free(r)
	}
}

// A chore still running when the program stops the chores asks for one more (a plugin's channel, a chain of reads): it
// is refused, as a task after the end; the stop does not start a pool whose work then runs after the program ended.
// Once the stop is over, the next use starts a pool again.
@(test)
a_chore_that_asks_for_more_while_the_chores_stop_is_refused :: proc(t: ^testing.T) {
	Drain :: struct {
		pool:    ^tasks.Pool,   // the pool the first chore ran on
		began:   sync.Sema,
		added:   bool,          // what tasks.add answered the chore
		asked:   bool,          // the chore saw the stop begin
		late:    int,           // the second chore ran (atomic)
	}
	d := new(Drain)
	defer free(d)
	d.pool = ui.chores()
	first :: proc(data: rawptr) {
		d := (^Drain)(data)
		sync.sema_post(&d.began)
		// (the stop has begun: the pool says so)
		began := time.tick_now()
		for !sync.atomic_load(&d.pool.stopping) && time.tick_since(began) < TASK_WAIT { time.sleep(time.Millisecond) }
		d.asked = sync.atomic_load(&d.pool.stopping)
		d.added = tasks.add(ui.chores(), proc(data: rawptr) { sync.atomic_add(&(^Drain)(data).late, 1) }, d)
	}
	testing.expect(t, tasks.add(d.pool, first, d))
	testing.expect(t, sync.sema_wait_with_timeout(&d.began, TASK_WAIT), "the first chore runs")
	testing.expect(t, ui.chores_stop(), "the stop ends within its bound")
	testing.expect(t, d.asked, "the chore asked during the stop")
	testing.expect(t, !d.added, "refused during the stop")
	// (a pool started by that ask runs it at once: give it the time to show)
	next := ui.chores()
	testing.expect(t, next != d.pool, "a new pool after the stop")
	testing.expect(t, tasks.wait_rest(next, TASK_WAIT))
	testing.expect_value(t, sync.atomic_load(&d.late), 0)
	testing.expect(t, ui.chores_stop())
}
