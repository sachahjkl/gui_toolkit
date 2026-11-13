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
import "../platform"
import "../tasks"

// The chores' threads, and how many more they may start while theirs hang.
CHORES_THREADS :: 2
CHORES_GROW :: 6

@(private = "file") chores_pool: tasks.Pool
@(private = "file") chores_once: sync.Once
@(private = "file") chores_stopped: bool

// The program's pool for what the interface must not wait for, started at the first call.
chores :: proc() -> ^tasks.Pool {
	sync.once_do(&chores_once, proc() {
		context = runtime.default_context()
		context.allocator = runtime.heap_allocator()
		tasks.start(&chores_pool, {threads = CHORES_THREADS, grow = CHORES_GROW})
	})
	return &chores_pool
}

// At the program's end (or a test's): the chores waiting run, then the threads are joined. A task asked after it runs
// nothing (its `lost` gets the data).
chores_stop :: proc() {
	if sync.atomic_load(&chores_stopped) { return }
	_ = chores()
	sync.atomic_store(&chores_stopped, true)
	tasks.stop(&chores_pool)
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
// Call it on that thread. When `s` is destroyed by then (or the chores stopped), `done` never runs: `lost(data)` does,
// on the thread that found it out, to free the data (nil: nothing). `done` nil: nothing comes back.
task :: proc(s: ^State, work: tasks.Work, done: Post_Proc, data: rawptr, lost: tasks.Work = nil) {
	b := task_box_of(s)
	sync.atomic_add(&b.refs, 1)
	t := new(Task, runtime.heap_allocator())
	t^ = {b, work, done, lost, data}
	if sync.atomic_load(&chores_stopped) || !tasks.add(chores(), task_run, t) { task_end(t, false) }
}

@(private = "file")
task_run :: proc(d: rawptr) {
	t := (^Task)(d)
	if t.work != nil { t.work(t.data) }
	posted := false
	if t.done != nil {
		sync.lock(&t.box.lock)
		if t.box.s != nil { posted = post_state(t.box.s, t.done, t.data) }
		sync.unlock(&t.box.lock)
	}
	task_end(t, posted || t.done == nil)
}

@(private = "file")
task_end :: proc(t: ^Task, delivered: bool) {
	if !delivered && t.lost != nil { t.lost(t.data) }
	task_box_release(t.box)
	free(t, runtime.heap_allocator())
}

////////////////////////////////
// The system's programs and dialogs, from the interface's thread

// What ui.open asks of the system.
Open_Kind :: enum u8 {
	Url,      // a web address, in the browser
	Path,     // a file or a folder, with its program
	Reveal,   // a file shown selected in its folder
}

// Opens `target` with the system's program, on the chores (a launch can wait on the disk, the shell, a D-Bus call):
// nothing waits here. `target` is copied.
open :: proc(target: string, kind := Open_Kind.Path) {
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
	if sync.atomic_load(&chores_stopped) || !tasks.add(chores(), work, o) {
		delete(o.target, runtime.heap_allocator())
		free(o, runtime.heap_allocator())
	}
}

// Which file dialog ui.file_dialog shows.
File_Dialog_Kind :: enum u8 { Open, Save, Folder }

// What comes back of a file dialog, on the interface's thread: the result (its paths are freed after the call: copy
// what is kept) and the `user` given.
File_Dialog_Done :: #type proc(r: platform.Dialog_Result, user: rawptr)

@(private = "file")
File_Dialog_Job :: struct {
	kind:   File_Dialog_Kind,
	d:      platform.File_Dialog,
	result: platform.Dialog_Result,
	done:   File_Dialog_Done,
	user:   rawptr,
}

// Shows a file dialog of the system with no wait here: the system's dialogs are modal loops (Windows) or another
// process (zenity, kdialog, the portal) that this thread would wait for, the window frozen meanwhile. It runs on the
// chores; `done(result, user)` comes at a next build of `s`. The strings of `d` are copied.
file_dialog :: proc(s: ^State, kind: File_Dialog_Kind, d: platform.File_Dialog, done: File_Dialog_Done, user: rawptr = nil) {
	a := runtime.heap_allocator()
	j := new(File_Dialog_Job, a)
	j^ = {kind = kind, d = d, done = done, user = user}
	j.d.title = strings.clone(d.title, a)
	j.d.start_dir = strings.clone(d.start_dir, a)
	j.d.remember_id = strings.clone(d.remember_id, a)
	j.d.suggested_name = strings.clone(d.suggested_name, a)
	j.d.default_ext = strings.clone(d.default_ext, a)
	filters := make([]platform.File_Filter, len(d.filters), a)
	for f, i in d.filters {
		patterns := make([]string, len(f.patterns), a)
		for x, k in f.patterns { patterns[k] = strings.clone(x, a) }
		filters[i] = platform.File_Filter{name = strings.clone(f.name, a), patterns = patterns}
	}
	j.d.filters = filters
	work :: proc(data: rawptr) {
		j := (^File_Dialog_Job)(data)
		switch j.kind {
		case .Open:   j.result = platform.open_file_dialog(j.d, runtime.heap_allocator())
		case .Save:   j.result = platform.save_file_dialog(j.d, runtime.heap_allocator())
		case .Folder: j.result = platform.pick_folder_dialog(j.d, runtime.heap_allocator())
		}
	}
	back :: proc(data: rawptr, word: u64) {
		j := (^File_Dialog_Job)(data)
		if j.done != nil { j.done(j.result, j.user) }
		file_dialog_free(data)
	}
	task(s, work, back, j, file_dialog_free)
}

@(private = "file")
file_dialog_free :: proc(data: rawptr) {
	a := runtime.heap_allocator()
	j := (^File_Dialog_Job)(data)
	platform.dialog_result_destroy(&j.result, a)
	delete(j.d.title, a); delete(j.d.start_dir, a); delete(j.d.remember_id, a)
	delete(j.d.suggested_name, a); delete(j.d.default_ext, a)
	for f in j.d.filters {
		delete(f.name, a)
		for x in f.patterns { delete(x, a) }
		delete(f.patterns, a)
	}
	delete(j.d.filters, a)
	free(j, a)
}
