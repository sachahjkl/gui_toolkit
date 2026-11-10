package ui

// A reader on its own thread: something slow (a scan of every process's files, a D-Bus call that waits for polkit, a
// network file system that does not answer) runs there while the interface's thread goes on drawing.
//
//   worker_start(&w, job, user, win)       // the thread waits; nothing runs before the first ask
//   worker_ask(&w)                         // a run is wanted (asks during a run make one more run, not one each)
//   job: proc(w: ^Worker)                  // on the thread: reads into a new result of its own, then, under
//                                          // worker_lock, swaps it in; worker_published marks it and wakes the window
//   if worker_take(&w) { worker_lock(&w); use the result; worker_unlock(&w) }   // on the interface's thread
//   worker_busy(&w)                        // a run is asked or going on (the view says that it reads)
//   worker_stop(&w)                        // joins the thread (a run going on ends first)
//
// One job runs at a time. The thread's temporary allocator is freed after each run.

import "core:sync"
import "core:thread"
import "../platform"

Worker :: struct {
	thread: ^thread.Thread,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	stop:   bool,
	asked:  bool,      // a run is wanted
	busy:   bool,      // a run is going on
	fresh:  bool,      // a result was published and not taken yet
	job:    proc(w: ^Worker),
	user:   rawptr,    // what the job reads and writes
	win:    ^platform.Window,   // woken when a result is published (nil: none)
}

// Starts the thread; nothing runs before the first worker_ask.
worker_start :: proc(w: ^Worker, job: proc(w: ^Worker), user: rawptr, win: ^platform.Window) {
	w.job, w.user, w.win = job, user, win
	w.thread = thread.create_and_start_with_data(w, worker_run, context)
}

worker_stop :: proc(w: ^Worker) {
	if w.thread == nil { return }
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
}

// Asks for a run. What the job is to read is set before, under worker_lock.
worker_ask :: proc(w: ^Worker) {
	if w.thread == nil { return }
	sync.mutex_lock(&w.mutex)
	w.asked = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
}

// Whether a run is asked or going on.
worker_busy :: proc(w: ^Worker) -> bool {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	return w.asked || w.busy
}

// True once per published result: the caller then reads it under worker_lock.
worker_take :: proc(w: ^Worker) -> bool {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if !w.fresh { return false }
	w.fresh = false
	return true
}

worker_lock :: proc(w: ^Worker) { sync.mutex_lock(&w.mutex) }
worker_unlock :: proc(w: ^Worker) { sync.mutex_unlock(&w.mutex) }

// Called by the job, under no lock, once its result is swapped in: marks it and wakes the window.
worker_published :: proc(w: ^Worker) {
	sync.mutex_lock(&w.mutex)
	w.fresh = true
	sync.mutex_unlock(&w.mutex)
	if w.win != nil { platform.wake(w.win) }
}

@(private = "file")
worker_run :: proc(data: rawptr) {
	w := (^Worker)(data)
	for {
		sync.mutex_lock(&w.mutex)
		for !w.asked && !w.stop { sync.cond_wait(&w.cond, &w.mutex) }
		if w.stop { sync.mutex_unlock(&w.mutex); return }
		w.asked = false
		w.busy = true
		sync.mutex_unlock(&w.mutex)
		w.job(w)
		sync.mutex_lock(&w.mutex)
		w.busy = false
		sync.mutex_unlock(&w.mutex)
		free_all(context.temp_allocator)
	}
}
