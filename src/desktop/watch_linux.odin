package tk_desktop

// Linux: inotify watches every directory an integration lives in, so what shows its state reads the disk again the moment
// one changes instead of on a timer. The places: the applications directory (the <slug>.desktop file), the hicolor icon
// theme root, the bin directory (the PATH link), the Desktop (its shortcut), the autostart directory, and the install
// folder (the program and its manifest: a reinstall, a repair, an uninstall by another process).
//
// A place that does not exist (a fresh profile has no ~/.local/share/applications, nothing is installed yet) is followed
// through its nearest existing ancestor: the watch there looks only for the next directory of the path being made (or
// moved in), then goes one level down, until the place itself is watched; that the place came is a change. A place that
// is deleted or moved away goes back to its nearest ancestor the same way. Nothing runs on a timer, and changes elsewhere
// in an ancestor (~/.local/share is busy) wake nobody.
//
// inotify follows a directory, not what is below it, which is enough: the integration's files are direct children of
// these directories (the icons are read at the theme root only for "present or not": a size directory appearing wakes
// the reader, which then scans the sizes). Places that share a directory share its watch descriptor (inotify gives the
// same one): it is removed when no place uses it any more. An overflow of the queue is a change (what was lost is read
// again).

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:thread"

WATCH_LINUX_PLACES :: 6

@(private = "file")
Watch_Place :: struct {
	path:  string,     // the place (owned; "" = nothing to watch here)
	on:    string,     // what is watched for it now: the place, or its nearest existing ancestor (owned; "": nothing)
	wd:    linux.Wd,   // the descriptor of `on` (-1: none)
	exact: bool,       // `on` is the place itself
}

@(private = "file")
Watch_Linux :: struct {
	inotify: linux.Fd,
	stop:    linux.Fd,   // eventfd, signalled to end the thread
	places:  [WATCH_LINUX_PLACES]Watch_Place,
	thread:  ^thread.Thread,
	wake:    Watch_Proc,
	user:    rawptr,
	allocator: runtime.Allocator,   // the places' paths: the starter's (the thread moves them; the stopper frees them)
}

@(private = "file")
WATCH_MASK :: linux.Inotify_Event_Mask{.CREATE, .DELETE, .MOVED_FROM, .MOVED_TO, .CLOSE_WRITE, .ATTRIB, .DELETE_SELF, .MOVE_SELF}

watch_start_linux :: proc(o: ^Options, wake: Watch_Proc, user: rawptr) -> ^Watcher {
	ino, ierr := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if ierr != .NONE { return nil }
	ev, everr := linux.eventfd(0, {.CLOEXEC})
	if everr != .NONE { linux.close(ino); return nil }

	st := new(Watch_Linux)
	st.inotify, st.stop = ino, ev
	st.wake, st.user = wake, user
	st.allocator = context.allocator

	// the places of the layout the integration uses; one the options do not set is the XDG default
	data := xdg_data_home()
	config := xdg_config_home()
	paths := [WATCH_LINUX_PLACES]string{
		o.applications_dir != "" ? o.applications_dir : (data == "" ? "" : strings.concatenate({data, "/applications"}, context.temp_allocator)),
		o.icons_dir != "" ? o.icons_dir : (data == "" ? "" : strings.concatenate({data, "/icons/hicolor"}, context.temp_allocator)),
		o.bin_dir != "" ? o.bin_dir : xdg_bin_dir(),
		o.desktop_dir != "" ? o.desktop_dir : xdg_desktop_dir(),
		o.autostart_dir != "" ? o.autostart_dir : (config == "" ? "" : strings.concatenate({config, "/autostart"}, context.temp_allocator)),
		install_target(o),
	}
	for p, i in paths {
		st.places[i] = {path = clone_or_empty(p, st.allocator), wd = linux.Wd(-1)}
		watch_place_settle(st, &st.places[i])
	}

	st.thread = thread.create_and_start_with_data(st, watch_linux_thread, priority = .Low, name = thread_name(o))
	if st.thread == nil {
		watch_linux_free(st)
		return nil
	}
	w := new(Watcher)
	w.user, w.wake, w.impl = user, wake, st
	return w
}

// Watches the place, else its nearest existing ancestor. True when the place itself is watched now.
//
// A directory made between the failed watch of it and the watch of its parent sends its CREATE before the parent is
// watched: once an ancestor is, the next directory toward the place is looked for, and if it is there now the place
// settles again, one level down (what comes after the watch, the watch sees; what came before it, this finds).
@(private = "file")
watch_place_settle :: proc(st: ^Watch_Linux, p: ^Watch_Place) -> bool {
	if p.path == "" { return false }
	for _ in 0 ..< WATCH_SETTLE_TRIES {
		watch_place_release(st, p)
		for dir := p.path; dir != ""; {
			c := strings.clone_to_cstring(dir, context.temp_allocator)
			if wd, err := linux.inotify_add_watch(st.inotify, c, WATCH_MASK); err == .NONE {
				p.on, p.wd, p.exact = strings.clone(dir, st.allocator), wd, dir == p.path
				break
			}
			up := filepath.dir(dir)
			if up == dir || up == "." { break }
			dir = up
		}
		if p.exact || p.on == "" { return p.exact }
		next := strings.concatenate({strings.trim_right(p.on, "/"), "/", next_component(p.on, p.path)}, context.temp_allocator)
		if !os.is_dir(next) { return false }
	}
	return p.exact
}

// (how many times a place settles again while its path is being made under it)
@(private = "file") WATCH_SETTLE_TRIES :: 16

// Lets go of what the place watches; the descriptor goes when no other place watches the same directory.
@(private = "file")
watch_place_release :: proc(st: ^Watch_Linux, p: ^Watch_Place) {
	if p.wd >= linux.Wd(0) {
		shared := false
		for &q in st.places { if &q != p && q.wd == p.wd { shared = true } }
		if !shared { _ = linux.inotify_rm_watch(st.inotify, p.wd) }
	}
	delete(p.on, st.allocator)
	p.on, p.wd, p.exact = "", linux.Wd(-1), false
}

// The name of the directory below `ancestor` on the way to `path` ("" when `path` is not below it).
@(private)
next_component :: proc(ancestor, path: string) -> string {
	base := strings.trim_right(ancestor, "/")
	if len(path) <= len(base) + 1 || !strings.has_prefix(path, base) || path[len(base)] != '/' { return "" }
	rest := strings.trim_left(path[len(base):], "/")
	if i := strings.index_byte(rest, '/'); i >= 0 { return rest[:i] }
	return rest
}

@(private = "file")
watch_linux_thread :: proc(data: rawptr) {
	st := (^Watch_Linux)(data)
	buf: [8192]u8 = ---
	for {
		free_all(context.temp_allocator)   // (the thread runs as long as the watcher)
		fds := [2]linux.Poll_Fd{
			{fd = st.stop, events = {.IN}},
			{fd = st.inotify, events = {.IN}},
		}
		_, perr := linux.poll(fds[:], -1)
		if perr == .EINTR { continue }
		if perr != .NONE { return }
		if .IN in fds[0].revents { return }   // stop was signalled
		if .IN not_in fds[1].revents { continue }
		changed := false
		for {
			r, rerr := linux.read(st.inotify, buf[:])
			if rerr == .EAGAIN || rerr == .EWOULDBLOCK { break }
			if rerr != .NONE || r <= 0 { break }
			if watch_events(st, buf[:r]) { changed = true }
		}
		if changed { st.wake(st.user) }
	}
}

// Works through a read's records: what changed in a place, a place that came (watched now) or went (back to an
// ancestor). True when the program must read the state again.
@(private = "file")
watch_events :: proc(st: ^Watch_Linux, data: []u8) -> (changed: bool) {
	for off := 0; off + size_of(linux.Inotify_Event) <= len(data); {
		e := (^linux.Inotify_Event)(raw_data(data[off:]))
		name_bytes := data[off + size_of(linux.Inotify_Event):][:e.len]
		off += size_of(linux.Inotify_Event) + int(e.len)
		name := string(cstring(raw_data(name_bytes))) if e.len > 0 else ""
		if .Q_OVERFLOW in e.mask {
			// events were lost: every place is looked for again, and the state is read again
			for &p in st.places { if !p.exact { watch_place_settle(st, &p) } }
			changed = true
			continue
		}
		gone := .DELETE_SELF in e.mask || .MOVE_SELF in e.mask || .IGNORED in e.mask || .UNMOUNT in e.mask
		for &p in st.places {
			if p.wd != e.wd || p.path == "" { continue }
			switch {
			case gone:
				// the watched directory went: the descriptor is dead for every place on it
				p.wd = linux.Wd(-1)
				delete(p.on, st.allocator); p.on, p.exact = "", false
				watch_place_settle(st, &p)
				changed = true
			case p.exact:
				changed = true
			case name != "" && name == next_component(p.on, p.path) && (.CREATE in e.mask || .MOVED_TO in e.mask):
				// the next directory toward the place was made: one level down (or the place itself, which came)
				if watch_place_settle(st, &p) { changed = true }
			}
		}
	}
	return
}

watch_stop_linux :: proc(w: ^Watcher) {
	st := (^Watch_Linux)(w.impl)
	if st == nil { return }
	if st.stop >= linux.Fd(0) {
		one := u64(1)
		bytes := (^[8]u8)(&one)^
		_, _ = linux.write(st.stop, bytes[:])
	}
	if st.thread != nil { thread.join(st.thread); thread.destroy(st.thread) }
	watch_linux_free(st)
	w.impl = nil
}

@(private = "file")
watch_linux_free :: proc(st: ^Watch_Linux) {
	if st.inotify >= linux.Fd(0) { linux.close(st.inotify) }
	if st.stop >= linux.Fd(0) { linux.close(st.stop) }
	for p in st.places { delete(p.path, st.allocator); delete(p.on, st.allocator) }
	free(st)
}
