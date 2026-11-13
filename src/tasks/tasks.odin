// Package tasks: work off the interface's thread. A Pool is a few threads that run work in the order it came (or the
// newest first), work that waits for its time with no thread asleep for it, and work that must run before the rest.
// A pool may grow: work that hangs (a read of a network share that does not answer) holds its thread for good, so when
// work waits, no thread is free and none has moved for Pool_Options.stuck, one more thread starts, up to
// Pool_Options.grow; such a thread ends after Pool_Options.extra_idle with nothing to do.
//
// A Job is work asked again and again whose runs merge: asked while it waits, nothing more; asked while it runs, one
// more run after it (a re-read of a folder each time it changes: one read with the newest state, not one per change).
//
// A pool of no thread runs work at once on the thread that adds it, and timed work when pump says: a test drives it so,
// in its own order and by its own clock (Pool_Options.clock).
//
// The result of a work goes back to the interface's thread by ui.post (ui.task does both: docs/tasks.md).
package tasks

import "core:sync"
import "core:thread"
import "core:time"

Work :: #type proc(data: rawptr)

STUCK_DEFAULT :: time.Second
EXTRA_IDLE_DEFAULT :: 5 * time.Second

Pool_Options :: struct {
	threads:      int,            // started now; 0: work runs on the thread that adds it (timed work at pump)
	grow:         int,            // threads it may add while its own are held
	stuck:        time.Duration,  // no thread free nor moving this long while work waits: one more starts (0: STUCK_DEFAULT)
	extra_idle:   time.Duration,  // a thread added ends after this long with nothing to do (0: EXTRA_IDLE_DEFAULT)
	newest_first: bool,           // the work last added runs first (the pictures last asked for are the ones on the screen)
	clock:        ^i64,           // (atomic) a test's clock in ms; nil: the monotonic one. Threads then wait for poke, not for a time
}

// How a work is added.
Add_Options :: struct {
	after_ms: int,    // runs this long from now (0: as soon as a thread is free)
	urgent:   bool,   // runs before every work waiting
}

@(private)
Item :: struct { work: Work, data: rawptr, due_ms: i64 }

Pool :: struct {
	o:        Pool_Options,
	lock:     sync.Mutex,
	changed:  sync.Cond,          // work came, the clock moved, the stop: the threads look again
	rested:   sync.Cond,          // a work ended, or a thread waits: wait_rest looks again
	ready:    [dynamic]Item,      // in the order they run (urgent ones first)
	timed:    [dynamic]Item,      // not due yet, in no order (a few: the soonest is looked for)
	threads:  [dynamic]^thread.Thread,
	running:  int,                // works taken and not ended
	waiting:  int,                // threads waiting for work
	extras:   int,                // threads added that run
	moved:    time.Tick,          // the last time a thread took or ended a work
	stopping: bool,
	alive:    int,                // worker threads not ended (a bounded stop waits for 0)
	looks:    int,                // times a thread looked at what is due (a test sees that it looked)
	origin:   time.Tick,
	watch:    ^thread.Thread,     // starts the threads added (nil: the pool does not grow)
	watch_wake: sync.Cond,        // the stop, for the watcher (its own: a signal for a work must reach a worker)
}

// How much work and how many threads a pool has now (counts).
Counts :: struct { ready, timed, running, waiting, threads, extras, looks: int }

// Starts the pool's threads, with the caller's context (its allocator is theirs; their temporary memory is freed after
// each work).
start :: proc(p: ^Pool, o: Pool_Options) {
	p.o, p.origin, p.moved = o, time.tick_now(), time.tick_now()
	if p.o.stuck <= 0 { p.o.stuck = STUCK_DEFAULT }
	if p.o.extra_idle <= 0 { p.o.extra_idle = EXTRA_IDLE_DEFAULT }
	p.alive = o.threads
	for _ in 0 ..< o.threads { append(&p.threads, thread.create_and_start_with_poly_data(p, worker, context)) }
	if o.threads > 0 && o.grow > 0 { p.watch = thread.create_and_start_with_poly_data(p, watcher, context) }
}

// Work for a thread of the pool. False once stop has begun: the work will not run (the data is the caller's again).
add :: proc(p: ^Pool, work: Work, data: rawptr, o := Add_Options{}) -> bool {
	if p.o.threads == 0 && o.after_ms <= 0 && !p.stopping { work(data); return true }
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	if p.stopping { return false }
	it := Item{work, data, 0}
	if o.after_ms > 0 {
		it.due_ms = now(p) + i64(o.after_ms)
		append(&p.timed, it)
		sync.cond_broadcast(&p.changed)   // (the soonest may be this one: every waiting thread computes its wait again)
	} else {
		queue(p, it, o.urgent)
		sync.cond_signal(&p.changed)
	}
	return true
}

// The test's clock moved: the threads look at what is due.
poke :: proc(p: ^Pool) {
	sync.lock(&p.lock)
	sync.cond_broadcast(&p.changed)
	sync.unlock(&p.lock)
}

// On the calling thread: the work due, and what was ready (a pool of no thread; `all_timed`: the timed work too). How
// many ran.
pump :: proc(p: ^Pool, all_timed := false) -> (ran: int) {
	for {
		sync.lock(&p.lock)
		due(p, all_timed)
		if len(p.ready) == 0 { sync.unlock(&p.lock); return }
		it := p.ready[0]
		ordered_remove(&p.ready, 0)
		sync.unlock(&p.lock)
		it.work(it.data)
		ran += 1
	}
}

// Ends the pool. Without `lost`, every work waiting runs first (timed work too, its time not waited for); with `lost`,
// the work waiting does not run and `lost` gets its data (to free it). `bound` 0: the threads are joined, a work that hangs holds the
// stop. `bound` > 0 (a program that quits): the stop waits that long at most; when a work still runs (a disk asleep), it
// returns false and leaves the pool as it is, its threads and memory to the process's end (a later stop, bound 0,
// joins them).
stop :: proc(p: ^Pool, lost: Work = nil, bound: time.Duration = 0) -> (all: bool) {
	sync.lock(&p.lock)
	p.stopping = true
	if lost != nil {
		for it in p.ready { lost(it.data) }
		for it in p.timed { lost(it.data) }
		clear(&p.ready)
		clear(&p.timed)
	}
	sync.cond_broadcast(&p.changed)
	sync.cond_broadcast(&p.watch_wake)
	sync.unlock(&p.lock)
	if p.watch != nil { thread.join(p.watch); thread.destroy(p.watch); p.watch = nil }
	if bound > 0 {
		// (a work that hangs holds its thread for good: its thread and the pool's memory are left to the process's end)
		began := time.tick_now()
		sync.lock(&p.lock)
		for p.alive > 0 {
			left := bound - time.tick_since(began)
			if left <= 0 { sync.unlock(&p.lock); return false }
			_ = sync.cond_wait_with_timeout(&p.rested, &p.lock, left)
		}
		sync.unlock(&p.lock)
	}
	// (an added thread may still be starting: the list is read under the lock)
	for {
		sync.lock(&p.lock)
		if len(p.threads) == 0 { sync.unlock(&p.lock); break }
		t := pop(&p.threads)
		sync.unlock(&p.lock)
		thread.join(t)
		thread.destroy(t)
	}
	if p.o.threads == 0 { pump(p, all_timed = true) }
	delete(p.threads); delete(p.ready); delete(p.timed)
	p.threads, p.ready, p.timed = nil, nil, nil
	return true
}

counts :: proc(p: ^Pool) -> Counts {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	return {len(p.ready), len(p.timed), p.running, p.waiting, len(p.threads), p.extras, p.looks}
}

// Until nothing is ready or running and every thread waits (timed work waits on), or `bound` passed: whether it rested.
// (Tests.)
wait_rest :: proc(p: ^Pool, bound: time.Duration) -> bool {
	began := time.tick_now()
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	for !(len(p.ready) == 0 && p.running == 0 && p.waiting == len(p.threads)) {
		left := bound - time.tick_since(began)
		if left <= 0 { return false }
		_ = sync.cond_wait_with_timeout(&p.rested, &p.lock, left)
	}
	return true
}

////////////////////////////////
// Jobs

// Work whose runs merge (job_ask). Its fields are the pool's, under its lock.
Job :: struct {
	work:    Work,
	data:    rawptr,
	pool:    ^Pool,  // the pool of its last ask
	queued:  bool,   // a run waits
	running: bool,
	again:   bool,   // asked during the run: one more after it
}

// A run of the job is wanted: queued unless one waits; asked during a run, one more run follows it. False once the
// pool stops.
job_ask :: proc(p: ^Pool, j: ^Job, o := Add_Options{}) -> bool {
	sync.lock(&p.lock)
	if p.stopping { sync.unlock(&p.lock); return false }
	if j.queued { sync.unlock(&p.lock); return true }
	if j.running { j.again = true; sync.unlock(&p.lock); return true }
	j.queued, j.pool = true, p
	sync.unlock(&p.lock)
	if !add(p, job_run, j, o) {
		sync.lock(&p.lock)
		j.queued = false
		sync.unlock(&p.lock)
		return false
	}
	return true
}

// Whether a run of the job waits or goes on.
job_busy :: proc(p: ^Pool, j: ^Job) -> bool {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	return j.queued || j.running || j.again
}

@(private)
job_run :: proc(data: rawptr) {
	j := (^Job)(data)
	p := j.pool
	for {
		sync.lock(&p.lock)
		j.queued, j.running, j.again = false, true, false
		sync.unlock(&p.lock)
		j.work(j.data)
		sync.lock(&p.lock)
		j.running = false
		more := j.again && !p.stopping
		if more { j.queued = true }
		j.again = false
		sync.unlock(&p.lock)
		if !more { return }
	}
}

////////////////////////////////

@(private)
queue :: proc(p: ^Pool, it: Item, urgent: bool) {
	if urgent {
		// (after the urgent ones already there, before the rest: they are at the front, in the order they came)
		at := 0
		for at < len(p.ready) && p.ready[at].due_ms < 0 { at += 1 }
		u := it
		u.due_ms = -1
		inject_at(&p.ready, at, u)
	} else if p.o.newest_first {
		at := 0
		for at < len(p.ready) && p.ready[at].due_ms < 0 { at += 1 }
		inject_at(&p.ready, at, it)
	} else {
		append(&p.ready, it)
	}
}

@(private)
now :: proc(p: ^Pool) -> i64 {
	if p.o.clock != nil { return sync.atomic_load(p.o.clock) }
	return i64(time.duration_milliseconds(time.tick_since(p.origin)))
}

// (Under the lock.) What is due goes to the ready ones, in the order of its time; the soonest that is not (-1: none).
@(private)
due :: proc(p: ^Pool, all: bool) -> (soonest: i64) {
	t := now(p)
	soonest = -1
	for {
		at := -1
		for it, i in p.timed {
			if all || p.stopping || it.due_ms <= t {
				if at < 0 || it.due_ms < p.timed[at].due_ms { at = i }
			}
		}
		if at < 0 { break }
		it := p.timed[at]
		unordered_remove(&p.timed, at)
		it.due_ms = 0
		queue(p, it, false)
	}
	for it in p.timed { if soonest < 0 || it.due_ms < soonest { soonest = it.due_ms } }
	return
}

@(private)
worker :: proc(p: ^Pool) { work_loop(p, false) }

@(private)
extra_worker :: proc(p: ^Pool) { work_loop(p, true) }

@(private)
work_loop :: proc(p: ^Pool, extra: bool) {
	sync.lock(&p.lock)
	for {
		soonest := due(p, false)
		p.looks += 1
		sync.cond_broadcast(&p.rested)
		if len(p.ready) > 0 {
			it := p.ready[0]
			ordered_remove(&p.ready, 0)
			p.running += 1
			p.moved = time.tick_now()
			sync.unlock(&p.lock)
			it.work(it.data)
			free_all(context.temp_allocator)
			sync.lock(&p.lock)
			p.running -= 1
			p.moved = time.tick_now()
			sync.cond_broadcast(&p.rested)
			continue
		}
		if p.stopping { break }
		p.waiting += 1
		sync.cond_broadcast(&p.rested)
		woke := true
		if extra {
			wait := p.o.extra_idle
			if soonest >= 0 && p.o.clock == nil { wait = min(wait, time.Duration(soonest - now(p)) * time.Millisecond) }
			woke = sync.cond_wait_with_timeout(&p.changed, &p.lock, wait)
		} else if soonest < 0 || p.o.clock != nil {
			sync.cond_wait(&p.changed, &p.lock)
		} else {
			_ = sync.cond_wait_with_timeout(&p.changed, &p.lock, time.Duration(soonest - now(p)) * time.Millisecond)
		}
		p.waiting -= 1
		// (an added thread idle for extra_idle with nothing ready ends; its handle is joined at stop)
		if extra && !woke && len(p.ready) == 0 && len(p.timed) == 0 { break }
	}
	if extra { p.extras -= 1 }
	p.alive -= 1
	sync.cond_broadcast(&p.rested)
	sync.unlock(&p.lock)
}

// Starts one more thread while work waits and none of the pool's is free nor has moved for `stuck`.
@(private)
watcher :: proc(p: ^Pool) {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	for !p.stopping {
		_ = sync.cond_wait_with_timeout(&p.watch_wake, &p.lock, p.o.stuck)
		if p.stopping { break }
		held := len(p.ready) > 0 && p.waiting == 0 && time.tick_since(p.moved) >= p.o.stuck
		if held && p.extras < p.o.grow {
			p.extras += 1
			p.alive += 1
			p.moved = time.tick_now()
			append(&p.threads, thread.create_and_start_with_poly_data(p, extra_worker, context))
		}
	}
}
