package ui

// Work off the interface's thread, its result back on it (docs/tasks.md). The interface's thread makes no system call:
// no file read or written, no process started, no D-Bus call that waits, not even a stat. Such work is a task:
//
//   ui.task(s, work, done, data)   // work(data) on a thread of the chores; then done(data, 0) at the start of s's next
//                                  // build, on its thread (ui.post). The window wakes for it.
//
// The chores are the program's one pool for that (gt:tasks: a few threads, more while some hang), started at its first
// use. A program that has its own (a pool per connection, newest first) makes a tasks.Pool and posts with ui.post.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import base "../base"
import "../platform"
import "../tasks"

// The chores' threads, and how many more they may start while theirs hang.
CHORES_THREADS :: 2
CHORES_GROW :: 6

// (a pool per start: chores_stop retires the running one and the next use starts another, so a second app in the same
// process, or a test after a test, gets answers. A retired pool's struct is never freed: a thread that took it before
// the stop may still call tasks.add on it, which then answers false; a stop that ran out of time leaves its threads on it)
@(private = "file") chores_lock: sync.Mutex
@(private = "file") chores_pool: ^tasks.Pool
// (a stop drains the pool: it stays the one chores gives, refusing, until the stop ends. A chore that asked for another
// during the drain got a new pool, whose work ran after the program had ended)
@(private = "file") chores_stopping: bool

// The program's pool for what the interface must not wait for, started at the first call, and again at the first call
// after chores_stop.
chores :: proc() -> ^tasks.Pool {
	sync.lock(&chores_lock)
	defer sync.unlock(&chores_lock)
	if chores_pool == nil {
		context = runtime.default_context()
		context.allocator = runtime.heap_allocator()
		p := new(tasks.Pool)
		tasks.start(p, {threads = CHORES_THREADS, grow = CHORES_GROW})
		chores_pool = p
	}
	return chores_pool
}

// How long a program's end waits for its chores: a chore that hangs (a disk asleep, a share that does not answer) must
// not keep a closed program alive.
CHORES_STOP_BOUND :: 2 * time.Second

// At the program's end (or a test's): the chores waiting run, then the threads are joined, within `bound` (0: for as
// long as they take). False: a chore still ran, its thread left to the process's end. A task asked after it starts the
// chores again: an app that ends stops only what it asked, never a later app's answers.
chores_stop :: proc(bound := CHORES_STOP_BOUND) -> (all: bool) {
	sync.lock(&chores_lock)
	p := chores_pool
	if p == nil || chores_stopping { sync.unlock(&chores_lock); return true }
	chores_stopping = true
	sync.unlock(&chores_lock)
	all = tasks.stop(p, bound = bound)
	sync.lock(&chores_lock)
	chores_pool, chores_stopping = nil, false
	sync.unlock(&chores_lock)
	return
}

// Where the tasks of a State post their results: shared by the State and its tasks (counted), so that a task ending after
// ui.destroy finds it shut instead of a State freed.
Task_Box :: struct {
	lock: sync.Mutex,
	s:    ^State,   // nil once shut
	refs: int,      // (atomic) the State's and each task's: never under the lock, which a task holds while it posts
}

@(private)
task_box_of :: proc(s: ^State) -> ^Task_Box {
	if s.task_box == nil {
		s.task_box = new(Task_Box, runtime.heap_allocator())
		s.task_box^ = {s = s, refs = 1}
	}
	return s.task_box
}

@(private)
task_box_release :: proc(b: ^Task_Box) {
	if sync.atomic_sub(&b.refs, 1) == 1 { free(b, runtime.heap_allocator()) }
}

// ui.destroy: the queue closed first (a task blocked on a full one, the box's lock held, gives up), then the box shut.
@(private)
task_box_shut :: proc(s: ^State) {
	b := s.task_box
	if b == nil { return }
	post_queue_close(&s.posts)
	sync.lock(&b.lock)
	b.s = nil
	sync.unlock(&b.lock)
	s.task_box = nil
	task_box_release(b)
}

@(private = "file")
Task :: struct {
	box:  ^Task_Box,
	work: tasks.Work,
	done: Post_Proc,
	lost: tasks.Work,
	data: rawptr,
}

// `work(data)` on the chores, then `done(data, 0)` on the interface's thread of `s` at the start of its next build.
// Call it on that thread. When `s` is destroyed by then (or the chores stopped while it waited), `done` never runs:
// `lost(data)` does, on the thread that found it out, to free the data (nil: nothing). That holds for an answer already
// queued and not yet run when `s` goes too. `done` nil: nothing comes back.
task :: proc(s: ^State, work: tasks.Work, done: Post_Proc, data: rawptr, lost: tasks.Work = nil) {
	b := task_box_of(s)
	sync.atomic_add(&b.refs, 1)
	t := new(Task, runtime.heap_allocator())
	t^ = {b, work, done, lost, data}
	// (the chores' queue is the process's: it grows in the heap, not in the caller's allocator, which may be a frame's
	// or a test's tracker)
	context.allocator = runtime.heap_allocator()
	if !tasks.add(chores(), task_run, t) { task_end(t, false) }
}

// `work(data)` on the chores, nothing posted back (the caller waits on its own condition, with a bound). False: the
// chores refused it (a stop began meanwhile); `work` does not run.
@(private)
chore_add :: proc(work: tasks.Work, data: rawptr) -> bool {
	context.allocator = runtime.heap_allocator()
	return tasks.add(chores(), work, data)
}

@(private = "file")
task_run :: proc(d: rawptr) {
	t := (^Task)(d)
	if t.work != nil { t.work(t.data) }
	if t.done == nil { task_end(t, true); return }
	posted := false
	// (the box held here, not read through t: once posted, the answer may run on the interface's thread and free t
	// before this thread unlocks; the box lives on, the State's reference to it waits for this lock in task_box_shut)
	box := t.box
	sync.lock(&box.lock)
	// (the task itself is posted, not its data: an answer still queued when the State goes reaches task_dropped through
	// pq_drop, and `lost` frees the data; posting `done` alone left that data to a queue that knows nothing of it)
	if box.s != nil { posted = post_state(box.s, task_answer, t) }
	sync.unlock(&box.lock)
	// (t is read again only when it was not posted: then nothing else has it)
	if !posted { task_end(t, false) }
}

// The answer, at a build of the State: `done`, then the task goes.
@(private)
task_answer :: proc(d: rawptr, word: u64) {
	t := (^Task)(d)
	t.done(t.data, 0)
	task_end(t, true)
}

// An answer that will never run (the State destroyed with it still queued): `lost` frees the data.
@(private)
task_dropped :: proc(d: rawptr) { task_end((^Task)(d), false) }

@(private = "file")
task_end :: proc(t: ^Task, delivered: bool) {
	if !delivered && t.lost != nil { t.lost(t.data) }
	task_box_release(t.box)
	free(t, runtime.heap_allocator())
}

////////////////////////////////
// The system's programs and dialogs, from the interface's thread

// Why a URL, a file, "Open with" or a shell menu's item opened nothing in a restricted process (base.restricted: an
// administrator's, root's), in this system's words and the language in use.
@(private)
restricted_open_words :: proc() -> string {
	return base.restricted_words(.Opens)
}

// What ui.open asks of the system.
Open_Kind :: enum u8 {
	Url,      // a web address, in the browser
	Path,     // a file or a folder, with its program
	Reveal,   // a file shown selected in its folder
}

// Opens `target` with the system's program, on the chores (a launch can wait on the disk, the shell, a D-Bus call):
// nothing waits here. `target` is copied.
open :: proc(target: string, kind := Open_Kind.Path) {
	// (a restricted process opens nothing with the user's programs: the toast says why, not a click that does nothing)
	if base.restricted() { toast_add(.Bad, nil, nil, restricted_open_words()); return }
	Open :: struct { target: string, kind: Open_Kind }
	o := new(Open, runtime.heap_allocator())
	o^ = {strings.clone(target, runtime.heap_allocator()), kind}
	work :: proc(d: rawptr) {
		o := (^Open)(d)
		switch o.kind {
		case .Url:    _ = platform.open_url(o.target)
		case .Path:   _ = platform.open_path(o.target)
		case .Reveal: _ = platform.reveal_in_folder(o.target)
		}
		delete(o.target, runtime.heap_allocator())
		free(o, runtime.heap_allocator())
	}
	if !tasks.add(chores(), work, o) {
		delete(o.target, runtime.heap_allocator())
		free(o, runtime.heap_allocator())
	}
}

