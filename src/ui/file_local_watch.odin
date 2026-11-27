package ui

// The local source's follow of the folders shown (File_Source.watch, src/md/features/folder-watch.md): one fsx.Watch
// per State for the folders its pickers show, and one thread that waits on it, started at the first follow. The thread
// opens the watch itself (what it asks of the system is off the interface's thread) and gathers the folders told; one
// wake at a time is posted to the State, which takes them all and tells each picker that shows one
// (file_reply_changed).
//
// Its memory is shared by the interface's thread and the waiting thread, counted: ui.destroy lets go of its reference
// and stops the wait without joining the thread (a post on its way would wait for a queue the interface's thread no
// longer drains); the last of the two frees it. A post after ui.destroy is refused by the State's Task_Box. A system
// with no watcher (watch_open fails) ends the thread: the pickers' folders are then read again only on F5.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "../fsx"

@(private = "file") LOCAL_WATCH_THREAD :: "gt folder watch"

@(private)
File_Local_Watch :: struct {
	refs:    int,                    // (atomic) the State's and the thread's
	box:     ^Task_Box,              // where the wakes are posted (one reference of its own)
	watch:   fsx.Watch,
	lock:    sync.Mutex,
	told:    map[string]bool,        // the folders told, not taken yet (heap; under lock)
	posted:  bool,                   // a wake is in the State's queue (under lock)
	follows: map[u64]Local_Follow,   // by picker id: the interface's thread only
}

@(private = "file")
Local_Follow :: struct {
	folder: string,   // (heap)
	reply:  File_Reply,
}

// File_Source.watch of the computer's files.
@(private)
local_watch :: proc(src: ^File_Source, path: string, reply: File_Reply) {
	if reply.state == nil { return }
	h := file_pickers_of(reply.state)
	a := runtime.heap_allocator()
	if h.watch == nil {
		if path == "" { return }
		h.watch = local_watch_start(reply.state)
		if h.watch == nil { return }
	}
	lw := h.watch
	if old, ok := lw.follows[reply.picker]; ok {
		delete(old.folder, a)
		delete_key(&lw.follows, reply.picker)
	}
	if path != "" { lw.follows[reply.picker] = {folder = strings.clone(path, a), reply = reply} }
	folders := make([dynamic]string, context.temp_allocator)
	for _, f in lw.follows {
		seen := false
		for x in folders { if x == f.folder { seen = true; break } }
		if !seen { append(&folders, f.folder) }
	}
	fsx.watch_set(&lw.watch, folders[:])
}

@(private = "file")
local_watch_start :: proc(s: ^State) -> ^File_Local_Watch {
	a := runtime.heap_allocator()
	lw := new(File_Local_Watch, a)
	lw.refs = 2
	lw.told = make(map[string]bool, a)
	lw.follows = make(map[u64]Local_Follow, a)
	lw.box = task_box_of(s)
	sync.atomic_add(&lw.box.refs, 1)
	// (the thread frees itself with the allocator it was made with, after the State may be gone: the process's heap, not
	// the caller's, which may be a test's tracker, destroyed by then)
	started: ^thread.Thread
	{
		context.allocator = a
		started = thread.create_and_start_with_data(lw, local_watch_run, priority = .Low, self_cleanup = true, name = LOCAL_WATCH_THREAD)
	}
	if started == nil {
		delete(lw.follows)
		local_watch_release(lw)   // (the thread's reference)
		local_watch_release(lw)
		return nil
	}
	return lw
}

// The waiting thread: what it is told goes to `told`, and one wake is posted while none is queued.
@(private = "file")
local_watch_run :: proc(d: rawptr) {
	lw := (^File_Local_Watch)(d)
	heap := runtime.heap_allocator()
	if fsx.watch_open(&lw.watch) {
		for {
			changed, closed := fsx.watch_wait(&lw.watch)
			if closed { break }
			sync.lock(&lw.lock)
			for p in changed { if p not_in lw.told { lw.told[strings.clone(p, heap)] = true } }
			wake := !lw.posted
			lw.posted = true
			sync.unlock(&lw.lock)
			if wake && !local_watch_post(lw) {
				sync.lock(&lw.lock)
				lw.posted = false
				sync.unlock(&lw.lock)
			}
			free_all(context.temp_allocator)
		}
	}
	free_all(context.temp_allocator)
	local_watch_release(lw)
}

// (the box's lock held: ui.destroy waits for it before it shuts the box)
@(private = "file")
local_watch_post :: proc(lw: ^File_Local_Watch) -> (posted: bool) {
	sync.lock(&lw.box.lock)
	defer sync.unlock(&lw.box.lock)
	if lw.box.s != nil { posted = post_state(lw.box.s, local_watch_told, lw) }
	return
}

// On the interface's thread: every folder told, to the pickers that show it. (`lw` is alive: the State lets go of it
// only in ui.destroy, after which nothing it posted runs.)
@(private = "file")
local_watch_told :: proc(d: rawptr, _: u64) {
	lw := (^File_Local_Watch)(d)
	heap := runtime.heap_allocator()
	told := make([dynamic]string, context.temp_allocator)
	sync.lock(&lw.lock)
	for p in lw.told {
		append(&told, strings.clone(p, context.temp_allocator))
		delete(p, heap)
	}
	clear(&lw.told)
	lw.posted = false
	sync.unlock(&lw.lock)
	// (the replies first: a picker told may read its folder, and its follow is kept as it is)
	replies := make([dynamic]File_Reply, context.temp_allocator)
	for _, f in lw.follows {
		for p in told { if p == f.folder { append(&replies, f.reply); break } }
	}
	for r in replies { file_reply_changed(r) }
}

// ui.destroy: the follows go, the wait ends, the State's reference is let go of.
@(private)
local_watch_end :: proc(h: ^File_Pickers) {
	lw := h.watch
	if lw == nil { return }
	h.watch = nil
	a := runtime.heap_allocator()
	for _, f in lw.follows { delete(f.folder, a) }
	delete(lw.follows)
	lw.follows = nil
	fsx.watch_stop(&lw.watch)
	local_watch_release(lw)
}

@(private = "file")
local_watch_release :: proc(lw: ^File_Local_Watch) {
	if sync.atomic_sub(&lw.refs, 1) != 1 { return }
	a := runtime.heap_allocator()
	for p in lw.told { delete(p, a) }
	delete(lw.told)
	fsx.watch_close(&lw.watch)
	task_box_release(lw.box)
	free(lw, a)
}
