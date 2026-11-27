package fsx_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "gt:fsx"

// How long a change may take to be told before the test fails (it waits for the report, never for a fixed time).
@(private = "file") WATCH_BOUND :: 10 * time.Second
// How long one wait for a report lasts before the file is touched again: a change made before the watcher applied the
// folder is not seen, the next one is.
@(private = "file") WATCH_RETRY :: 250 * time.Millisecond

// What the waiting thread got: each report's folders, joined.
@(private = "file")
Seen :: struct {
	w:       fsx.Watch,
	lock:    sync.Mutex,
	reports: [dynamic]string,   // (heap)
	sema:    sync.Sema,
	opened:  bool,
}

@(private = "file")
seen_wait :: proc(data: rawptr) {
	s := (^Seen)(data)
	// (opened on the waiting thread: the folders set before are applied at the first wait)
	if !fsx.watch_open(&s.w) { sync.sema_post(&s.sema); return }
	sync.atomic_store(&s.opened, true)
	sync.sema_post(&s.sema)
	for {
		changed, closed := fsx.watch_wait(&s.w)
		if closed { return }
		sync.lock(&s.lock)
		append(&s.reports, strings.join(changed, "|", runtime.heap_allocator()))
		sync.unlock(&s.lock)
		sync.sema_post(&s.sema)
		free_all(context.temp_allocator)
	}
}

// Whether a report since `from` names `folder`.
@(private = "file")
seen_folder :: proc(s: ^Seen, from: int, folder: string) -> bool {
	sync.lock(&s.lock)
	defer sync.unlock(&s.lock)
	for r in s.reports[min(from, len(s.reports)):] {
		for p in strings.split(r, "|", context.temp_allocator) { if p == folder { return true } }
	}
	return false
}

@(private = "file")
seen_count :: proc(s: ^Seen) -> int {
	sync.lock(&s.lock)
	defer sync.unlock(&s.lock)
	return len(s.reports)
}

// Writes a new file in `folder` until a report names it, within WATCH_BOUND. True when one did.
@(private = "file")
touch_until_told :: proc(s: ^Seen, folder: string) -> bool {
	from := seen_count(s)
	start := time.tick_now()
	for i := 0; time.tick_since(start) < WATCH_BOUND; i += 1 {
		_ = os.write_entire_file(fmt.tprintf("%s/new_%d.txt", folder, i), transmute([]byte)string("x"))
		_ = sync.sema_wait_with_timeout(&s.sema, WATCH_RETRY)
		if seen_folder(s, from, folder) { return true }
	}
	return false
}

// A file made in a watched folder is told, with the folder's path as it was set; a burst of files is told as a few
// changes, not one per file; another folder set is watched in its place.
@(test)
a_watched_folder_tells_its_changes :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux && ODIN_OS != .Windows { return }
	one := fresh_dir(fmt.tprintf("gui_toolkit_fsx_watch_one_%d", os.get_pid()))
	two := fresh_dir(fmt.tprintf("gui_toolkit_fsx_watch_two_%d", os.get_pid()))
	defer { fsx.remove_tree(one); fsx.remove_tree(two) }
	s := new(Seen, runtime.heap_allocator())
	defer free(s, runtime.heap_allocator())
	s.reports = make([dynamic]string, runtime.heap_allocator())
	defer {
		for r in s.reports { delete(r, runtime.heap_allocator()) }
		delete(s.reports)
	}
	folders := []string{one}
	fsx.watch_set(&s.w, folders)   // (before watch_open: kept for the first wait)
	th := thread.create_and_start_with_data(s, seen_wait)
	_ = sync.sema_wait_with_timeout(&s.sema, WATCH_BOUND)
	if !testing.expect(t, sync.atomic_load(&s.opened), "the system gives a watch") {
		thread.join(th); thread.destroy(th)
		fsx.watch_close(&s.w)
		return
	}
	defer {
		fsx.watch_stop(&s.w)
		thread.join(th)
		thread.destroy(th)
		fsx.watch_close(&s.w)
	}

	testing.expect(t, touch_until_told(s, one), "a file made in the folder is told")

	// a burst: told as one change or a few (WATCH_QUIET_MS groups them)
	before := seen_count(s)
	for i in 0 ..< 50 { _ = os.write_entire_file(fmt.tprintf("%s/burst_%d.txt", one, i), transmute([]byte)string("x")) }
	start := time.tick_now()
	for seen_count(s) == before && time.tick_since(start) < WATCH_BOUND { _ = sync.sema_wait_with_timeout(&s.sema, WATCH_RETRY) }
	testing.expect(t, seen_count(s) > before, "the burst is told")
	testing.expect(t, seen_count(s) - before < 10, "the burst is told as a few changes")

	// another folder in its place
	other := []string{two}
	fsx.watch_set(&s.w, other)
	testing.expect(t, touch_until_told(s, two), "the folder set since is told")

	// the folder removed (told), then made again at its path and set again: watched again, not kept as a dead watch
	before = seen_count(s)
	fsx.remove_tree(two)
	start = time.tick_now()
	for !seen_folder(s, before, two) && time.tick_since(start) < WATCH_BOUND { _ = sync.sema_wait_with_timeout(&s.sema, WATCH_RETRY) }
	testing.expect(t, seen_folder(s, before, two), "the folder's removal is told")
	fsx.make_dirs(two)
	fsx.watch_set(&s.w, other)
	testing.expect(t, touch_until_told(s, two), "the folder made again is watched again")
}

// A watch stopped before it was opened ends its first wait at once.
@(test)
a_watch_stopped_before_its_wait_ends :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux && ODIN_OS != .Windows { return }
	w: fsx.Watch
	fsx.watch_stop(&w)
	if !testing.expect(t, fsx.watch_open(&w)) { return }
	defer fsx.watch_close(&w)
	_, closed := fsx.watch_wait(&w)
	testing.expect(t, closed)
}
