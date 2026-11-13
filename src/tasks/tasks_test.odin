package tasks

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// What should come is waited for at most this; what should not come is given this long to show up.
@(private = "file") WAIT :: 5 * time.Second
@(private = "file") NONE :: 100 * time.Millisecond

@(private = "file")
Log :: struct {
	lock:  sync.Mutex,
	order: [dynamic]int,
	gate:  sync.Sema,    // a gated work waits for one post
	began: sync.Sema,    // posted when a gated work begins
}

@(private = "file")
Entry :: struct { log: ^Log, n: int }

@(private = "file")
note :: proc(data: rawptr) {
	e := (^Entry)(data)
	sync.lock(&e.log.lock)
	append(&e.log.order, e.n)
	sync.unlock(&e.log.lock)
}

@(private = "file")
gated :: proc(data: rawptr) {
	e := (^Entry)(data)
	sync.sema_post(&e.log.began)
	sync.sema_wait(&e.log.gate)
	note(data)
}

// One thread: the order they came; an urgent work before those waiting, after the urgent ones before it.
@(test)
work_runs_in_its_order_and_urgent_work_first :: proc(t: ^testing.T) {
	log: Log
	defer delete(log.order)
	p: Pool
	start(&p, {threads = 1})
	es := [6]Entry{{&log, 0}, {&log, 1}, {&log, 2}, {&log, 3}, {&log, 4}, {&log, 5}}
	add(&p, gated, &es[0])   // (holds the thread while the rest is queued)
	testing.expect(t, sync.sema_wait_with_timeout(&log.began, WAIT))
	add(&p, note, &es[1])
	add(&p, note, &es[2])
	add(&p, note, &es[3], {urgent = true})
	add(&p, note, &es[4], {urgent = true})
	add(&p, note, &es[5])
	sync.sema_post(&log.gate)
	testing.expect(t, wait_rest(&p, WAIT))
	stop(&p)
	testing.expect_value(t, len(log.order), 6)
	want := []int{0, 3, 4, 1, 2, 5}
	for n, i in want { if i < len(log.order) { testing.expect_value(t, log.order[i], n) } }
}

@(test)
the_newest_work_first :: proc(t: ^testing.T) {
	log: Log
	defer delete(log.order)
	p: Pool
	start(&p, {threads = 1, newest_first = true})
	es := [4]Entry{{&log, 0}, {&log, 1}, {&log, 2}, {&log, 3}}
	add(&p, gated, &es[0])
	testing.expect(t, sync.sema_wait_with_timeout(&log.began, WAIT))
	add(&p, note, &es[1])
	add(&p, note, &es[2])
	add(&p, note, &es[3])
	sync.sema_post(&log.gate)
	testing.expect(t, wait_rest(&p, WAIT))
	stop(&p)
	want := []int{0, 3, 2, 1}
	testing.expect_value(t, len(log.order), 4)
	for n, i in want { if i < len(log.order) { testing.expect_value(t, log.order[i], n) } }
}

// A pool of no thread, driven by the test: work at once, timed work when its clock says, the soonest first.
@(test)
a_pool_of_no_thread_runs_by_the_tests_clock :: proc(t: ^testing.T) {
	log: Log
	defer delete(log.order)
	clock: i64
	p: Pool
	start(&p, {clock = &clock})
	es := [3]Entry{{&log, 0}, {&log, 1}, {&log, 2}}
	add(&p, note, &es[0])
	testing.expect_value(t, len(log.order), 1)   // (at once, on this thread)
	add(&p, note, &es[1], {after_ms = 200})
	add(&p, note, &es[2], {after_ms = 100})
	testing.expect_value(t, pump(&p), 0)
	sync.atomic_store(&clock, 150)
	testing.expect_value(t, pump(&p), 1)
	sync.atomic_store(&clock, 250)
	testing.expect_value(t, pump(&p), 1)
	stop(&p)
	want := []int{0, 2, 1}
	for n, i in want { if i < len(log.order) { testing.expect_value(t, log.order[i], n) } }
}

// Threads waiting on a test's clock wake for poke, not for a time.
@(test)
timed_work_waits_for_the_clock :: proc(t: ^testing.T) {
	log: Log
	defer delete(log.order)
	clock: i64
	p: Pool
	start(&p, {threads = 2, clock = &clock})
	e := Entry{&log, 7}
	add(&p, note, &e, {after_ms = 1000})
	testing.expect(t, wait_rest(&p, WAIT))
	testing.expect_value(t, counts(&p).timed, 1)
	sync.atomic_store(&clock, 1000)
	poke(&p)
	deadline := time.tick_now()
	for counts(&p).timed > 0 && time.tick_since(deadline) < WAIT { time.sleep(time.Millisecond) }
	testing.expect(t, wait_rest(&p, WAIT))
	stop(&p)
	testing.expect_value(t, len(log.order), 1)
}

@(private = "file")
Job_State :: struct {
	started: sync.Sema,
	gate:    sync.Sema,
	done:    sync.Sema,
	runs:    int,
}

@(private = "file")
job_work :: proc(data: rawptr) {
	st := (^Job_State)(data)
	sync.sema_post(&st.started)
	sync.sema_wait(&st.gate)
	st.runs += 1
	sync.sema_post(&st.done)
}

// Asks during a run make one more run, not one each; asks while one waits, none.
@(test)
a_jobs_asks_merge :: proc(t: ^testing.T) {
	st: Job_State
	p: Pool
	start(&p, {threads = 2})
	j := Job{work = job_work, data = &st}
	testing.expect(t, !job_busy(&p, &j), "nothing before an ask")
	job_ask(&p, &j)
	testing.expect(t, job_busy(&p, &j))
	testing.expect(t, sync.sema_wait_with_timeout(&st.started, WAIT), "the run begins")
	job_ask(&p, &j)
	job_ask(&p, &j)
	for _ in 0 ..< 2 {
		sync.sema_post(&st.gate)
		testing.expect(t, sync.sema_wait_with_timeout(&st.done, WAIT), "a run")
	}
	sync.sema_post(&st.gate)
	testing.expect(t, !sync.sema_wait_with_timeout(&st.done, NONE), "no third run")
	testing.expect(t, wait_rest(&p, WAIT))
	testing.expect_value(t, st.runs, 2)
	testing.expect(t, !job_busy(&p, &j))
	stop(&p)
}

// A work that hangs holds its thread: the pool adds one for the work waiting behind it, which ends once idle.
@(test)
a_held_pool_grows_and_shrinks :: proc(t: ^testing.T) {
	log: Log
	defer delete(log.order)
	p: Pool
	start(&p, {threads = 1, grow = 2, stuck = 50 * time.Millisecond, extra_idle = 100 * time.Millisecond})
	es := [2]Entry{{&log, 0}, {&log, 1}}
	add(&p, gated, &es[0])
	testing.expect(t, sync.sema_wait_with_timeout(&log.began, WAIT))
	add(&p, note, &es[1])
	began := time.tick_now()
	for time.tick_since(began) < WAIT {
		sync.lock(&log.lock)
		n := len(log.order)
		sync.unlock(&log.lock)
		if n == 1 { break }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, len(log.order), 1)   // (the one behind the held work ran on a thread added)
	if len(log.order) == 1 { testing.expect_value(t, log.order[0], 1) }
	sync.sema_post(&log.gate)
	began = time.tick_now()
	for counts(&p).extras > 0 && time.tick_since(began) < WAIT { time.sleep(5 * time.Millisecond) }
	testing.expect_value(t, counts(&p).extras, 0)
	stop(&p)
}

@(private = "file")
Stop_Run :: struct { p: ^Pool, done: sync.Sema, lost: int }

// A stop with `lost`: the work waiting does not run, its data is handed back; nothing is added once it stops; the
// work that runs ends first.
@(test)
a_stop_hands_back_what_waits :: proc(t: ^testing.T) {
	log: Log
	defer delete(log.order)
	p: Pool
	start(&p, {threads = 1})
	es := [3]Entry{{&log, 0}, {&log, 1}, {&log, 2}}
	add(&p, gated, &es[0])
	testing.expect(t, sync.sema_wait_with_timeout(&log.began, WAIT))
	add(&p, note, &es[1])
	add(&p, note, &es[2], {after_ms = 60_000})
	run := Stop_Run{p = &p}
	// (the stop waits for the held work: it runs on a thread of its own, the test releases the work once it began)
	th := thread.create_and_start_with_poly_data(&run, proc(r: ^Stop_Run) {
		@(static) counted: ^Stop_Run
		counted = r
		stop(r.p, proc(d: rawptr) { counted.lost += 1 })
		sync.sema_post(&r.done)
	})
	began := time.tick_now()
	for !sync.atomic_load(&p.stopping) && time.tick_since(began) < WAIT { time.sleep(time.Millisecond) }
	testing.expect(t, !add(&p, note, &es[1]), "nothing added after the stop began")
	sync.sema_post(&log.gate)
	testing.expect(t, sync.sema_wait_with_timeout(&run.done, WAIT), "the stop ends")
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, run.lost, 2)
	testing.expect_value(t, len(log.order), 1)   // (only the work that ran)
}

// A work that hangs: a stop with a bound gives up after it and says so; the work let go, a stop joins its thread.
@(test)
a_bounded_stop_leaves_a_hung_work :: proc(t: ^testing.T) {
	Hang :: struct { go: sync.Sema, started: sync.Sema }
	h: Hang
	p := new(Pool)
	defer free(p)
	start(p, {threads = 1})
	add(p, proc(data: rawptr) {
		h := (^Hang)(data)
		sync.sema_post(&h.started)
		sync.sema_wait(&h.go)
	}, &h)
	testing.expect(t, sync.sema_wait_with_timeout(&h.started, 5 * time.Second), "the work started")
	began := time.tick_now()
	testing.expect(t, !stop(p, bound = 50 * time.Millisecond), "gave up")
	testing.expect(t, time.tick_since(began) < 5 * time.Second, "within its bound")
	sync.sema_post(&h.go)
	testing.expect(t, stop(p), "joined once let go")
}
