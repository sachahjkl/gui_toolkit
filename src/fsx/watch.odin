package fsx

// Watching folders (src/md/features/folder-watch.md): a thread of the program waits in watch_wait until something changes
// in one of the folders it was given (watch_set, from any thread), and gets their paths. Changes that come close
// together come as one: after the first, the wait goes on until none came for WATCH_QUIET_MS (at most WATCH_MAX_MS), so
// that a copy of a thousand files reads the folder a few times, not a thousand. The system's part is in
// watch_<os>.odin.
//
// The order of the calls: watch_open, then one thread loops on watch_wait until it says closed; watch_set and watch_stop
// from any thread at any time (watch_set before watch_open is kept for the first wait); watch_close once the waiting
// thread ended. watch_open may run on the waiting thread itself: what it asks of the system is then off the caller's.

import "base:runtime"
import "core:strings"
import "core:sync"

// A change is told once no other came for this long...
WATCH_QUIET_MS :: 120
// ... or this long after the first, whatever still comes.
WATCH_MAX_MS :: 600

// A set of folders watched. Zero is a watch not opened. Its memory is the heap's: it is shared by several threads.
Watch :: struct {
	mutex:   sync.Mutex,
	wanted:  [dynamic]string,   // the folders to watch, as last set
	changed: bool,              // `wanted` changed since the waiting thread applied it
	closing: bool,
	opened:  bool,              // watch_open succeeded: the native wake exists
	native:  Watch_Native,
}

// Asks the system for a watch. False when it gives none (no watcher on this system, or the system refused): the caller
// starts no waiting thread, and a folder is read again only when the person asks.
watch_open :: proc(w: ^Watch) -> bool {
	if !watch_open_native(w) { return false }
	sync.mutex_lock(&w.mutex)
	w.opened = true
	sync.mutex_unlock(&w.mutex)
	return true
}

// Ends the wait of the waiting thread (it returns closed = true); call watch_close after that thread ended.
watch_stop :: proc(w: ^Watch) {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	w.closing = true
	if w.opened { watch_wake_native(w) }
}

// Frees what the watch holds. The waiting thread must have ended.
watch_close :: proc(w: ^Watch) {
	if w.opened { watch_close_native(w) }
	a := runtime.heap_allocator()
	for p in w.wanted { delete(p, a) }
	delete(w.wanted)
	w^ = {}
}

// The folders to watch from now on (the others are no longer watched). Any thread; it does not wait for the system.
watch_set :: proc(w: ^Watch, paths: []string) {
	a := runtime.heap_allocator()
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if w.wanted == nil { w.wanted = make([dynamic]string, a) }
	for p in w.wanted { delete(p, a) }
	clear(&w.wanted)
	for p in paths { append(&w.wanted, strings.clone(p, a)) }
	w.changed = true
	// (the wake is in the lock: watch_close cannot free it between the test and the write)
	if w.opened { watch_wake_native(w) }
}

// The wanted folders, if they changed since the last call (the waiting thread's copy, in `allocator`).
@(private)
watch_take_wanted :: proc(w: ^Watch, allocator := context.temp_allocator) -> (paths: []string, changed, closing: bool) {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if w.closing { return nil, false, true }
	if !w.changed { return nil, false, false }
	w.changed = false
	out := make([]string, len(w.wanted), allocator)
	for p, i in w.wanted { out[i] = strings.clone(p, allocator) }
	return out, true, false
}

// The keys of `found` as a list, in `allocator`.
@(private)
watch_found_list :: proc(found: map[string]bool, allocator: runtime.Allocator) -> []string {
	out := make([]string, len(found), allocator)
	i := 0
	for p in found {
		out[i] = strings.clone(p, allocator)
		i += 1
	}
	return out
}
