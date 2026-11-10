# Calls posted from other threads (`ui.post`)

A thread that reads the network (server-sent events, a WebSocket), decodes an image or waits on a process must not touch
the interface's data: `ui.post` hands a call to the interface's thread instead. The call runs at the start of the next
`ui.begin_build`, before the input is read and the tree is built, so the frame sees the new data. The window is woken
(`platform.wake`) when the first call arrives after a drain: a loop asleep in `platform.wait_event` makes a frame.

```odin
on_line :: proc(data: rawptr, word: u64) {           // on the interface's thread
	line := strings.string_from_ptr((^u8)(data), int(word))
	append(&app.lines, line)
}

// on the network thread
line := strings.clone(text)
if !ui.post(&app.ui_state, on_line, raw_data(line), u64(len(line))) { delete(line) }   // closed: never runs
```

Example: `examples/stream` (`tk build stream`).

## API

| Procedure | |
|---|---|
| `post(s: ^State, fn, data = nil, word = 0) -> bool` | from any thread; false when the queue is closed or full with `.Fail` |
| `post(w: ^platform.Window, fn, data, word) -> bool` | the same through the window the State is built for (`Build_Params.window`); false before the first build |
| `post_configure(s, capacity, overflow, per_build, on_drop)` | before any thread posts: ring size (default 1024), what a full ring does (default `.Block`), calls run per build (default 512), what frees the data of calls that never run |
| `drain_posts(s, budget = -1) -> int` | runs the calls waiting; `begin_build` calls it, an app may call it elsewhere in its loop |
| `posts_pending(s)`, `post_stats(s)` | calls waiting; counters (posted, run, dropped, spilled, blocked, refused, wakes) |
| `set_post_wake(s, wake, user)` | who to wake when the loop does not wait on the window (its own event, a socket) |
| `post_close(s)` | refuses further posts and releases the producers waiting on a full ring |

`fn` is `proc(data: rawptr, word: u64)`: a pointer and a word travel with it, nothing is allocated per message (the
message lives in its slot of the ring). It runs with the interface thread's context.

`needs_frame` is true while calls wait beyond the last build's budget: a burst of ten thousand lines is spread over
frames instead of freezing one.

## Full ring (`Post_Overflow`)

| Mode | A push on a full ring | Lost messages |
|---|---|---|
| `Block` (default) | waits until the interface drained some (a futex; the window is woken again every 50 ms meanwhile) | none |
| `Drop_Oldest` | drops the oldest message waiting (`on_drop` gets it) and goes in | the oldest |
| `Grow` | waits in a list behind the ring (an allocation and a lock per spilled message) | none |
| `Fail` | returns false | the refused one (the producer decides) |

A `Block` push from the interface's own thread (a call that posts, on a full ring) cannot wait for itself: it spills as
`Grow` does.

## Order and guarantees

- The calls of one thread run in the order it posted them, in every mode (spilled calls included: once a call spilled,
  the producers keep spilling until the interface emptied the list).
- The ring is Vyukov's bounded multi-producer queue: a compare-and-swap per push and per pop, no lock.
- A wake is asked once per drain, not once per call.
- Shutting down: `post_close`, join the threads that post, then `ui.destroy` (the calls left go to `on_drop`). Destroy
  the State before the window (the window forgets the State then).

The queue itself is `ui.Post_Queue` (`post_queue_init`, `post_queue_push`, `post_queue_drain`...), usable without a
State by a loop of its own. Tests: `tests/post`.

## A reader on its own thread (`ui.Worker`)

Something slow that the interface asks for again and again (a scan of every process's files, a D-Bus call that waits for
polkit, a network file system that does not answer) runs on a thread of its own, a `Worker`. The interface asks for a
run; the thread runs the job, which reads into a new result of its own and swaps it in under the worker's lock; the
thread then wakes the window, which takes the result at its next frame.

```odin
job :: proc(w: ^ui.Worker) {                      // on the worker's thread
	view := (^View)(w.user)
	fresh := read_everything()                    // no lock while it reads
	ui.worker_lock(w)
	view.next, fresh = fresh, view.next           // swapped in
	ui.worker_unlock(w)
	free_reading(fresh)
	ui.worker_published(w)                        // marks it, wakes the window
}

ui.worker_start(&view.worker, job, &view, win)   // the thread waits: nothing runs before the first ask
ui.worker_ask(&view.worker)                       // in a build: the view is shown, F5 was pressed
if ui.worker_take(&view.worker) {                 // once per published result
	ui.worker_lock(&view.worker)
	use(view.next)
	ui.worker_unlock(&view.worker)
}
reading := ui.worker_busy(&view.worker)           // a run is asked or going on
ui.worker_stop(&view.worker)                      // joins the thread
```

| Procedure | |
|---|---|
| `worker_start(w, job, user, win)` | starts the thread; `job` gets the worker (`w.user` is `user`); `win` is woken when a result is published (nil: none) |
| `worker_ask(w)` | a run is wanted. Asks that come while a run goes on make one more run, not one each |
| `worker_busy(w)` | a run is asked or going on |
| `worker_take(w)` | true once per published result |
| `worker_lock(w)`, `worker_unlock(w)` | the lock of what the job and the interface share |
| `worker_published(w)` | called by the job, under no lock, once its result is swapped in |
| `worker_stop(w)` | stops the thread and joins it (a run going on ends first) |

One job runs at a time. The thread's temporary allocator is freed after each run. What the job reads (a unit to start,
an option) is set under the lock before `worker_ask`. Test: `tests/post/worker_test.odin`.
