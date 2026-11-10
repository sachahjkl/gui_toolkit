package post_test

import "core:sync"
import "core:testing"
import "core:time"
import "../../src/ui"

// What a run that should come is waited for at most; what a run that should not come is given to show up.
@(private = "file") WORKER_WAIT :: 5 * time.Second
@(private = "file") WORKER_NONE :: 100 * time.Millisecond

@(private = "file")
Job_State :: struct {
	started: sync.Sema, // posted at the start of each run
	gate:  sync.Sema,   // each run waits for one post
	done:  sync.Sema,   // posted at the end of each run
	runs:  int,         // the job's own
	value: int,         // the result, under the worker's lock
}

@(private = "file")
job :: proc(w: ^ui.Worker) {
	st := (^Job_State)(w.user)
	sync.sema_post(&st.started)
	sync.sema_wait(&st.gate)
	st.runs += 1
	ui.worker_lock(w)
	st.value = st.runs
	ui.worker_unlock(w)
	ui.worker_published(w)
	sync.sema_post(&st.done)
}

// Asks during a run make one more run, not one each; a result is taken once.
@(test)
a_worker_coalesces_its_asks :: proc(t: ^testing.T) {
	st: Job_State
	w: ui.Worker
	ui.worker_start(&w, job, &st, nil)
	defer ui.worker_stop(&w)
	testing.expect(t, !ui.worker_take(&w), "nothing before an ask")
	ui.worker_ask(&w)
	testing.expect(t, ui.worker_busy(&w))
	// (the run has begun: the asks below come during it)
	testing.expect(t, sync.sema_wait_with_timeout(&st.started, WORKER_WAIT), "the run begins")
	ui.worker_ask(&w)
	ui.worker_ask(&w)
	for _ in 0 ..< 2 {
		sync.sema_post(&st.gate)
		testing.expect(t, sync.sema_wait_with_timeout(&st.done, WORKER_WAIT), "a run")
	}
	sync.sema_post(&st.gate)
	testing.expect(t, !sync.sema_wait_with_timeout(&st.done, WORKER_NONE), "no third run")
	testing.expect(t, ui.worker_take(&w))
	testing.expect(t, !ui.worker_take(&w), "taken once")
	ui.worker_lock(&w)
	testing.expect_value(t, st.value, 2)
	ui.worker_unlock(&w)
	testing.expect(t, !ui.worker_busy(&w))
}
