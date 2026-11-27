package fsx

// Linux: inotify, one watch per folder (its entries made, removed, renamed, written, their attributes), and an eventfd
// that ends a wait when the folders to watch change or the program ends.

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:time"

@(private = "file")
WATCH_MASK :: linux.Inotify_Event_Mask{.CREATE, .DELETE, .MOVED_FROM, .MOVED_TO, .CLOSE_WRITE, .ATTRIB, .DELETE_SELF, .MOVE_SELF, .ONLYDIR}
@(private = "file")
EVENT_BUFFER :: 64 * 1024

@(private)
Watch_Native :: struct {
	inotify: linux.Fd,
	wake:    linux.Fd,
	paths:   map[linux.Wd]string,   // the waiting thread's (heap)
}

@(private)
watch_open_native :: proc(w: ^Watch) -> bool {
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE { return false }
	wake, werr := linux.eventfd(0, {.NONBLOCK, .CLOEXEC})
	if werr != .NONE {
		linux.close(fd)
		return false
	}
	w.native.inotify, w.native.wake = fd, wake
	w.native.paths = make(map[linux.Wd]string, runtime.heap_allocator())
	return true
}

@(private)
watch_close_native :: proc(w: ^Watch) {
	a := runtime.heap_allocator()
	for _, p in w.native.paths { delete(p, a) }
	delete(w.native.paths)
	linux.close(w.native.inotify)
	linux.close(w.native.wake)
}

@(private)
watch_wake_native :: proc(w: ^Watch) {
	one: u64 = 1
	linux.write(w.native.wake, ([^]u8)(&one)[:size_of(one)])
}

// The watches of the wanted folders, the others removed.
@(private = "file")
apply :: proc(w: ^Watch, wanted: []string) {
	n := &w.native
	a := runtime.heap_allocator()
	keep := make(map[string]bool, len(wanted), context.temp_allocator)
	for p in wanted { keep[p] = true }
	gone := make([dynamic]linux.Wd, context.temp_allocator)
	for wd, p in n.paths { if p not_in keep { append(&gone, wd) } }
	for wd in gone {
		linux.inotify_rm_watch(n.inotify, wd)
		delete(n.paths[wd], a)
		delete_key(&n.paths, wd)
	}
	have := make(map[string]bool, len(n.paths), context.temp_allocator)
	for _, p in n.paths { have[p] = true }
	for p in wanted {
		if p in have { continue }
		wd, err := linux.inotify_add_watch(n.inotify, strings.clone_to_cstring(p, context.temp_allocator), WATCH_MASK)
		if err != .NONE { continue }
		if old, found := n.paths[wd]; found { delete(old, a) }   // (the same folder by another path: one watch)
		n.paths[wd] = strings.clone(p, a)
	}
}

// A folder told, its path copied: the watch's own copy goes when its watch is removed, before the wait ends.
@(private = "file")
told :: proc(changed: ^map[string]bool, p: string) {
	if p not_in changed^ { changed[strings.clone(p, context.temp_allocator)] = true }
}

// Reads the events waiting; the folders they are in go to `changed`.
@(private = "file")
drain :: proc(w: ^Watch, changed: ^map[string]bool) {
	n := &w.native
	buf := make([]u8, EVENT_BUFFER, context.temp_allocator)
	for {
		got, err := linux.read(n.inotify, buf)
		if err != .NONE || got <= 0 { return }
		for off := 0; off + size_of(linux.Inotify_Event) <= got; {
			e := (^linux.Inotify_Event)(&buf[off])
			if .Q_OVERFLOW in e.mask {
				for _, p in n.paths { told(changed, p) }   // (events were lost: every folder is read again)
			} else if p, ok := n.paths[e.wd]; ok {
				told(changed, p)
				// (the folder went, its watch with it: forgotten, so the next watch_set of its path, a folder made
				// again there, watches it again instead of keeping a watch that is dead)
				if .IGNORED in e.mask {
					delete_key(&n.paths, e.wd)
					delete(p, runtime.heap_allocator())
				}
			}
			off += size_of(linux.Inotify_Event) + int(e.len)
		}
	}
}

@(private = "file")
clear_wake :: proc(w: ^Watch) {
	v: u64
	linux.read(w.native.wake, ([^]u8)(&v)[:size_of(v)])
}

// Waits until a watched folder changes: their paths, as watch_set gave them (`allocator`). closed: watch_stop was
// called, or the system failed; the thread ends its loop.
watch_wait :: proc(w: ^Watch, allocator := context.temp_allocator) -> (changed: []string, closed: bool) {
	found := make(map[string]bool, 8, context.temp_allocator)
	first: time.Tick
	for {
		if wanted, now, closing := watch_take_wanted(w); closing {
			return nil, true
		} else if now {
			apply(w, wanted)
		}
		timeout: i32 = -1
		if len(found) > 0 {
			waited := time.duration_milliseconds(time.tick_since(first))
			if waited >= WATCH_MAX_MS { break }
			timeout = i32(min(WATCH_QUIET_MS, WATCH_MAX_MS - waited))
		}
		fds := [2]linux.Poll_Fd{{fd = w.native.inotify, events = {.IN}}, {fd = w.native.wake, events = {.IN}}}
		ready, err := linux.poll(fds[:], timeout)
		if err == .EINTR { continue }
		if err != .NONE { return nil, true }
		if ready == 0 { break }   // (quiet: what came is one change)
		if .IN in fds[1].revents { clear_wake(w) }
		if .IN in fds[0].revents {
			had := len(found)
			drain(w, &found)
			if had == 0 && len(found) > 0 { first = time.tick_now() }
		}
	}
	return watch_found_list(found, allocator), false
}
