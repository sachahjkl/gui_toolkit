package ui

// A tree of a folder on disk (src/md/features/tree-view.md): a ui.Tree whose rows it makes from the folders it read.
// Each folder is listed when it is first shown open, on the chores (never on the interface's thread), folders first
// then in natural order; the open folders are watched and read again when they change. A filter finds names in the
// whole folder, read or not (file_tree_find.odin); the file acts, its menu, its keys and its drags are in
// file_tree_acts.odin.
//
//   ui.file_tree_set_root(&app.files, "/home/a/project")
//   ui.next({width = ui.px(280), height = ui.fill()})
//   if shown, ok := ui.file_tree("###files", &app.files); ok {
//       for i in shown.first ..< shown.last { ui.file_tree_row(&app.files, i) }
//   }
//   if app.files.chosen >= 0 { open(ui.file_tree_path(&app.files, app.files.chosen)) }

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "../ascii"
import "../fsx"

@(private = "file") FILE_TREE_WATCH_THREAD :: "gt file tree watch"
// The open file's mark at the end of its row, in the row's ems.
@(private = "file") FILE_TREE_OPEN_DOT_EM :: 0.38
// "Expand here" opens at most this many folders: a disk's root is not read whole.
FILE_TREE_EXPAND_MAX :: 2000

File_Tree_Entry :: struct {
	name:   string,   // (owned by its folder)
	folder: bool,     // a folder, or a link to one
	link:   bool,
	hidden: bool,     // the system's mark, or a name that starts with "."
}

// A folder read: its entries sorted (folders first, then in natural order).
File_Tree_Folder :: struct {
	path:    string,   // (owned)
	entries: []File_Tree_Entry,
	failed:  bool,     // it could not be read (gone, refused): no entries
	dirty:   bool,     // it changed since it was read: it is read again
}

File_Tree :: struct {
	using tree:   Tree,
	root:         string,     // (owned) the folder shown; "" none (file_tree_set_root)
	hidden:       bool,       // hidden entries shown (file_tree_set_hidden)
	gitignored:   bool,       // the filter finds what .gitignore ignores too (false: a repository's ignored files are left out)
	type_filters: bool,       // typing in the tree opens the filter with what is typed (false: type-ahead; Ctrl+F opens it)
	no_system_drops: bool,    // the program answers the system's drags over the window itself
	open_file:    string,     // (owned) the file marked as open (file_tree_set_open_file)
	actions:      []File_Tree_Action,   // the program's acts in the menu (not owned)
	acts_off:     File_Tree_Acts,       // the toolkit's acts the menu leaves out
	folders:      map[string]^File_Tree_Folder,   // read, by path (the key is the folder's path)
	pending:      map[string]struct{},            // being read (owned keys)
	file_rows:    [dynamic]Tree_Row,              // the rows shown
	row_folder:   [dynamic]^File_Tree_Folder,     // the folder each row is in
	row_entry:    [dynamic]i32,                   // ... and its entry there
	file_version: u64,                            // moves with file_rows
	open_seen:    u64,
	stale:        bool,
	dirty_any:    bool,       // a folder was marked to be read again: file_tree_update looks for it (not every build)
	generation:   u64,        // moves with the root: a reading of an earlier root is dropped
	reveal_path:  string,     // (owned) a path to reveal once its folders are read
	expanding:    string,     // (owned) "Expand here": the folder whose folders open as they are read
	expanded:     int,        // ... how many opened so far
	link:         ^File_Tree_Link,
	using find:   File_Tree_Find_State,   // the filter (file_tree_find.odin)
	using acts:   File_Tree_Acts_State,   // the menu, the acts, the drags (file_tree_acts.odin)
}

// What the tree's work holds of it (counted: the tree's, each reading's, the watching thread's, each wake's): a work
// that ends after the tree is destroyed finds `tree` nil.
@(private)
File_Tree_Link :: struct {
	refs:       int,                // (atomic)
	tree:       ^File_Tree,         // nil once destroyed (the interface's thread only)
	box:        ^Task_Box,          // (one reference of its own)
	watch:      fsx.Watch,
	watched:    bool,               // the watching thread started (the interface's thread only)
	lock:       sync.Mutex,
	told:       map[string]bool,    // the folders told, not taken yet (heap; under lock)
	posted:     bool,               // a wake is on its way (under lock)
	find_serial: u64,               // (atomic) the filter's search running: an older one stops
}

file_tree_destroy :: proc(t: ^File_Tree) {
	a := runtime.heap_allocator()
	if l := t.link; l != nil {
		// (the State's list of trees: only while the State lives, which its box says)
		if s := l.box.s; s != nil {
			for x, i in s.file_trees { if x == t { unordered_remove(&s.file_trees, i); break } }
		}
		sync.atomic_add(&l.find_serial, 1)
		l.tree = nil
		if l.watched { fsx.watch_stop(&l.watch) }
		file_tree_link_release(l)
		t.link = nil
	}
	file_tree_forget(t)
	delete(t.folders)
	delete(t.pending)
	delete(t.root, a)
	delete(t.open_file, a)
	delete(t.reveal_path, a)
	delete(t.expanding, a)
	delete(t.file_rows)
	delete(t.row_folder)
	delete(t.row_entry)
	file_tree_find_destroy(t)
	file_tree_acts_destroy(t)
	tree_destroy(&t.tree)
}

// The folders read and asked are forgotten (a new root).
@(private = "file")
file_tree_forget :: proc(t: ^File_Tree) {
	a := runtime.heap_allocator()
	for _, f in t.folders { file_tree_folder_free(f) }
	clear(&t.folders)
	for k in t.pending { delete(k, a) }
	clear(&t.pending)
	clear(&t.file_rows)
	clear(&t.row_folder)
	clear(&t.row_entry)
}

@(private)
file_tree_entries_free :: proc(entries: []File_Tree_Entry) {
	a := runtime.heap_allocator()
	for e in entries { delete(e.name, a) }
	delete(entries, a)
}

@(private)
file_tree_folder_free :: proc(f: ^File_Tree_Folder) {
	a := runtime.heap_allocator()
	file_tree_entries_free(f.entries)
	delete(f.path, a)
	free(f, a)
}

// The folder shown (its entries are the top level). The open folders, the filter, the reveal and the cursor of another
// root are forgotten.
file_tree_set_root :: proc(t: ^File_Tree, path: string) {
	a := runtime.heap_allocator()
	clean := file_path_clean(path, LOCAL_SEPARATOR)
	if clean == t.root { return }
	file_tree_filter_close(t)
	file_tree_forget(t)
	delete(t.root, a)
	t.root = strings.clone(clean, a)
	clear(&t.open)
	t.open_version += 1
	t.generation += 1
	t.has_cursor, t.sel, t.revealing = false, -1, false
	delete(t.reveal_path, a)
	t.reveal_path = ""
	t.stale = true
}

// Hidden entries shown or not.
file_tree_set_hidden :: proc(t: ^File_Tree, on: bool) {
	if t.hidden == on { return }
	t.hidden, t.stale = on, true
}

// The file marked as open ("": none). Its row is not revealed: file_tree_reveal does that.
file_tree_set_open_file :: proc(t: ^File_Tree, path: string) {
	a := runtime.heap_allocator()
	delete(t.open_file, a)
	t.open_file = strings.clone(path, a)
}

// Opens each folder from the root to `path`, reads those not read yet, then selects its row and brings it into view.
// A path outside the root is not revealed. The filter closes.
file_tree_reveal :: proc(t: ^File_Tree, path: string) {
	a := runtime.heap_allocator()
	file_tree_filter_close(t)
	delete(t.reveal_path, a)
	t.reveal_path = strings.clone(file_path_clean(path, LOCAL_SEPARATOR), a)
}

// Every folder read again (F5).
file_tree_refresh :: proc(t: ^File_Tree) {
	for _, f in t.folders { file_tree_mark_dirty(t, f) }
}

// The folder `f` read again at the next build (a change told, an operation, a refresh).
@(private)
file_tree_mark_dirty :: proc(t: ^File_Tree, f: ^File_Tree_Folder) {
	f.dirty, t.dirty_any = true, true
}

// The path of row `i` (in `allocator`; "" for no row).
file_tree_path :: proc(t: ^File_Tree, i: int, allocator := context.temp_allocator) -> string {
	if i < 0 || i >= len(t.file_rows) { return "" }
	f := t.row_folder[i]
	return fsx.path_join(f.path, f.entries[t.row_entry[i]].name, LOCAL_SEPARATOR, allocator)
}

// The entry of row `i`.
file_tree_entry :: proc(t: ^File_Tree, i: int) -> File_Tree_Entry {
	if i < 0 || i >= len(t.file_rows) { return {} }
	return t.row_folder[i].entries[t.row_entry[i]]
}

// The identity of the row named `name` in the folder whose row is `folder` (the root's: file_tree_root_id).
file_tree_child_id :: proc(folder: u64, name: string) -> u64 {
	return hash.fnv64a(transmute([]u8)name, folder ~ 0x9e3779b97f4a7c15)
}

file_tree_root_id :: proc(root: string) -> u64 { return hash.fnv64a(transmute([]u8)root) }

// The identity of the row of `path` (under the root; 0: outside it).
file_tree_id_of :: proc(t: ^File_Tree, path: string) -> u64 {
	sep := u8(LOCAL_SEPARATOR)
	if t.root == "" || !file_path_within(path, t.root, sep) { return 0 }
	id := file_tree_root_id(t.root)
	rest := file_path_trim(path, sep)[len(file_path_trim(t.root, sep)):]
	for len(rest) > 0 {
		for len(rest) > 0 && rest[0] == sep { rest = rest[1:] }
		k := strings.index_byte(rest, sep)
		name := k < 0 ? rest : rest[:k]
		rest = k < 0 ? "" : rest[k:]
		if name != "" { id = file_tree_child_id(id, name) }
	}
	return id
}

// `if shown, ok := ui.file_tree(id, &t); ok { for i in shown.first ..< shown.last { ui.file_tree_row(&t, i) } }`: a
// column of what `next` gives: the filter's field when it is open, then the tree (ui.tree), its rows made again when a
// folder was read or opened. Its menu, its acts and its drags are done at its end.
@(deferred_out = file_tree_end)
file_tree :: proc(id: string, t: ^File_Tree) -> (shown: Vlist_Rows, ok: bool) {
	s := gs()
	file_tree_update(t)
	set_next_axis(.Y)
	push_parent(build_box({}, fmt.tprintf("%s_column", id)))
	append(&s.file_tree_stack, t)
	file_tree_keys(t)
	if t.filter_open { file_tree_filter_row(t) }
	if t.open_seen != t.open_version { t.stale = true; t.open_seen = t.open_version }
	if t.stale { file_tree_rows_make(t) }
	next({width = fill(), height = fill()})
	return tree_open(id, &t.tree, t.file_rows[:], t.file_version)
}

@(private = "file")
file_tree_end :: proc(shown: Vlist_Rows, ok: bool) {
	s := gs()
	tree_end(shown, ok)
	t := pop(&s.file_tree_stack)
	file_tree_after(t)
	pop_parent()
}

// Row `i` of the file tree being built: its icon by its type (a folder's open or closed, in the accent), what the
// filter matched lit, the open file's label bright with a dot at its end, a hidden entry's weak. More at its end:
// `if ui.parent(row.box) { ... }`.
file_tree_row :: proc(t: ^File_Tree, i: int, o := Tree_Row_Options{}) -> Signal {
	o := o
	e := file_tree_entry(t, i)
	if e.folder && o.icon_tint == nil { o.icon_tint = color("accent") }
	is_open := !e.folder && file_tree_is_open_file(t, i)
	if is_open && o.tag == "" { o.tag = "bright" }
	if e.hidden && o.tag == "" { o.tag = "weak" }
	sig := tree_row(&t.tree, i, o)
	if is_open {
		push_parent(sig.box)
		defer pop_parent()
		em := font_size()
		d := max(4, f32(int(em * FILE_TREE_OPEN_DOT_EM)))
		next({width = px(d), height = px(d), bg = color("accent"), radius = d * 0.5})
		build_box({.Draw_Background, .Fixed_Radius}, "###open_dot")
		spacer(px(d))
	}
	return sig
}

// Whether row `i` is the open file: its folder's path, a separator and its name, compared in place.
@(private = "file")
file_tree_is_open_file :: proc(t: ^File_Tree, i: int) -> bool {
	if t.open_file == "" { return false }
	f := t.row_folder[i]
	name := f.entries[t.row_entry[i]].name
	p := t.open_file
	return len(p) == len(f.path) + 1 + len(name) && strings.has_prefix(p, f.path) && p[len(f.path)] == LOCAL_SEPARATOR && strings.has_suffix(p, name)
}

@(private = "file")
file_tree_update :: proc(t: ^File_Tree) {
	s := gs()
	if t.link == nil {
		a := runtime.heap_allocator()
		l := new(File_Tree_Link, a)
		l.refs, l.tree = 1, t
		l.told = make(map[string]bool, a)
		l.box = task_box_of(s)
		sync.atomic_add(&l.box.refs, 1)
		t.link = l
		t.multi = true
		append(&s.file_trees, t)
	}
	// (a folder told changed is read again; its rows stay until the new listing comes. A folder being read keeps its
	// mark: what changed during that reading is read by the next one. The pass only after a mark, not per build)
	if t.dirty_any {
		t.dirty_any = false
		for path, f in t.folders {
			if !f.dirty { continue }
			if path in t.pending { t.dirty_any = true } else { file_tree_ask(t, path) }
		}
	}
	if t.reveal_path != "" { file_tree_reveal_step(t) }
}

// One step of a reveal: the folders from the root to the path opened, those not read asked; once they are all read,
// the row revealed.
@(private = "file")
file_tree_reveal_step :: proc(t: ^File_Tree) {
	a := runtime.heap_allocator()
	sep := u8(LOCAL_SEPARATOR)
	if t.root == "" || !file_path_within(t.reveal_path, t.root, sep) || t.reveal_path == t.root {
		delete(t.reveal_path, a)
		t.reveal_path = ""
		return
	}
	rest := t.reveal_path[len(t.root):]
	for len(rest) > 0 && rest[0] == sep { rest = rest[1:] }
	id := file_tree_root_id(t.root)
	folder := t.root
	ready := true
	for len(rest) > 0 {
		k := strings.index_byte(rest, sep)
		name := k < 0 ? rest : rest[:k]
		rest = k < 0 ? "" : rest[k + 1:]
		id = file_tree_child_id(id, name)
		if rest == "" { break }
		// (a folder on the way: open, and read)
		folder = fsx.path_join(folder, name, sep, context.temp_allocator)
		tree_set_open(&t.tree, id, true)
		if folder not_in t.folders { ready = false }
	}
	if !ready { return }
	tree_reveal(&t.tree, id)
	delete(t.reveal_path, a)
	t.reveal_path = ""
}

// The rows made again from the folders read (the filter's found folders while it shows) and the open set: a pass over
// the rows shown (on a change, never per build). A folder open and not read is asked; "Expand here" opens the folders
// under its folder as they come.
@(private)
file_tree_rows_make :: proc(t: ^File_Tree) {
	t.stale = false
	clear(&t.file_rows)
	clear(&t.row_folder)
	clear(&t.row_entry)
	t.file_version += 1
	if t.root == "" { return }
	filtering := file_tree_filtering(t)
	source := filtering ? &t.found : &t.folders
	root, read := source[t.root]
	if !read {
		if !filtering { file_tree_ask(t, t.root) }
		return
	}
	add :: proc(t: ^File_Tree, source: ^map[string]^File_Tree_Folder, filtering: bool, f: ^File_Tree_Folder, id: u64, depth: int) {
		for e, k in f.entries {
			if e.hidden && !t.hidden && !filtering { continue }
			rid := file_tree_child_id(id, e.name)
			path := ""
			if e.folder && (rid in t.open || t.expanding != "") { path = fsx.path_join(f.path, e.name, LOCAL_SEPARATOR, context.temp_allocator) }
			// ("Expand here": a folder under it opens, up to a bound)
			if path != "" && t.expanding != "" && rid not_in t.open && t.expanded < FILE_TREE_EXPAND_MAX && file_path_within(path, t.expanding, LOCAL_SEPARATOR) {
				t.open[rid] = {}
				t.expanded += 1
			}
			open := e.folder && rid in t.open
			append(&t.file_rows, Tree_Row{id = rid, depth = depth, label = e.name, icon = file_icon(e.name, e.folder, open, e.link), branch = e.folder})
			append(&t.row_folder, f)
			append(&t.row_entry, i32(k))
			if !open { continue }
			if child, ok := source[path]; ok {
				add(t, source, filtering, child, rid, depth + 1)
			} else if !filtering {
				file_tree_ask(t, path)
			}
		}
	}
	add(t, source, filtering, root, file_tree_root_id(t.root), 0)
	if t.expanding != "" {
		// (done once nothing under it is being read)
		waiting := false
		for p in t.pending { if file_path_within(p, t.expanding, LOCAL_SEPARATOR) { waiting = true; break } }
		if !waiting || t.expanded >= FILE_TREE_EXPAND_MAX {
			delete(t.expanding, runtime.heap_allocator())
			t.expanding = ""
		}
	}
	if !filtering { file_tree_watch(t) }
}

////////////////////////////////
// Readings, on the chores

@(private = "file")
File_Tree_Read :: struct {
	link:       ^File_Tree_Link,
	path:       string,   // (heap)
	generation: u64,
	entries:    []File_Tree_Entry,
	failed:     bool,
}

@(private)
file_tree_ask :: proc(t: ^File_Tree, path: string) {
	if path in t.pending || t.link == nil { return }
	if f, ok := t.folders[path]; ok { f.dirty = false }   // (marked again from now on: read again after this one)
	a := runtime.heap_allocator()
	t.pending[strings.clone(path, a)] = {}
	r := new(File_Tree_Read, a)
	r^ = {link = t.link, path = strings.clone(path, a), generation = t.generation}
	sync.atomic_add(&t.link.refs, 1)
	task(gs(), file_tree_read_work, file_tree_read_done, r, file_tree_read_lost)
}

@(private = "file")
file_tree_read_work :: proc(d: rawptr) {
	r := (^File_Tree_Read)(d)
	r.entries, r.failed = file_tree_list(r.path)
	free_all(context.temp_allocator)
}

// The entries of the folder `path`, sorted: folders first, then in natural order (heap). On a thread of the chores.
@(private)
file_tree_list :: proc(path: string) -> (entries: []File_Tree_Entry, failed: bool) {
	a := runtime.heap_allocator()
	found, err := fsx.read_folder(path, context.temp_allocator)
	if err != nil { return nil, true }
	out := make([]File_Tree_Entry, len(found), a)
	for e, i in found {
		folder := e.kind == .Directory
		if e.kind == .Link {
			kind, _ := fsx.stat_follow(fsx.path_join(path, e.name, LOCAL_SEPARATOR, context.temp_allocator))
			folder = kind == .Directory
		}
		out[i] = {name = strings.clone(e.name, a), folder = folder, link = e.kind == .Link, hidden = e.hidden || (len(e.name) > 0 && e.name[0] == '.')}
	}
	file_tree_sort(out)
	return out, false
}

// Folders first, then in natural order.
@(private)
file_tree_sort :: proc(entries: []File_Tree_Entry) {
	slice.sort_by(entries, proc(x, y: File_Tree_Entry) -> bool {
		if x.folder != y.folder { return x.folder }
		return ascii.compare_natural(x.name, y.name) < 0
	})
}

@(private = "file")
file_tree_read_free :: proc(r: ^File_Tree_Read) {
	a := runtime.heap_allocator()
	file_tree_entries_free(r.entries)
	delete(r.path, a)
	file_tree_link_release(r.link)
	free(r, a)
}

@(private = "file")
file_tree_read_lost :: proc(d: rawptr) { file_tree_read_free((^File_Tree_Read)(d)) }

// On the interface's thread: the listing in its folder (the same folder struct, its entries replaced), the rows made
// again at the next file_tree.
@(private = "file")
file_tree_read_done :: proc(d: rawptr, _: u64) {
	r := (^File_Tree_Read)(d)
	t := r.link.tree
	defer file_tree_read_free(r)
	if t == nil || r.generation != t.generation { return }
	a := runtime.heap_allocator()
	if key, ok := file_tree_key_of(t.pending, r.path); ok {
		delete_key(&t.pending, key)
		delete(key, a)
	}
	f, had := t.folders[r.path]
	if !had {
		f = new(File_Tree_Folder, a)
		f.path = strings.clone(r.path, a)
		t.folders[f.path] = f
	}
	file_tree_entries_free(f.entries)
	f.entries, r.entries = r.entries, nil
	f.failed = r.failed
	if f.dirty { t.dirty_any = true }   // (told changed while it was read: read again)
	// (a folder of it that could not be read, removed then made again: read again with it; its watch went with it)
	if !r.failed {
		for p, g in t.folders { if g.failed && p != r.path && file_path_parent(p, LOCAL_SEPARATOR) == r.path { file_tree_mark_dirty(t, g) } }
	}
	if !file_tree_filtering(t) { t.stale = true }
}

// The key of `m` that is `path` (the map owns it).
@(private)
file_tree_key_of :: proc(m: map[string]$V, path: string) -> (string, bool) {
	for k in m { if k == path { return k, true } }
	return "", false
}

@(private)
file_tree_link_release :: proc(l: ^File_Tree_Link) {
	if sync.atomic_sub(&l.refs, 1) != 1 { return }
	a := runtime.heap_allocator()
	for p in l.told { delete(p, a) }
	delete(l.told)
	fsx.watch_close(&l.watch)
	task_box_release(l.box)
	free(l, a)
}

////////////////////////////////
// The open folders watched

// The folders followed: the root and every open folder read. The watching thread starts with the first.
@(private = "file")
file_tree_watch :: proc(t: ^File_Tree) {
	l := t.link
	shown := make(map[^File_Tree_Folder]struct{}, 16, context.temp_allocator)
	for f in t.row_folder { shown[f] = {} }
	paths := make([dynamic]string, context.temp_allocator)
	for path, f in t.folders {
		if f.failed { continue }
		if path != t.root && f not_in shown { continue }
		append(&paths, path)
	}
	if len(paths) == 0 && !l.watched { return }
	if !l.watched {
		l.watched = true
		sync.atomic_add(&l.refs, 1)
		if thread.create_and_start_with_data(l, file_tree_watch_run, priority = .Low, self_cleanup = true, name = FILE_TREE_WATCH_THREAD) == nil {
			l.watched = false
			file_tree_link_release(l)
			return
		}
	}
	fsx.watch_set(&l.watch, paths[:])
}

// The waiting thread: the folders told go to `told`, one wake at a time is posted.
@(private = "file")
file_tree_watch_run :: proc(d: rawptr) {
	l := (^File_Tree_Link)(d)
	heap := runtime.heap_allocator()
	if fsx.watch_open(&l.watch) {
		for {
			changed, closed := fsx.watch_wait(&l.watch)
			if closed { break }
			sync.lock(&l.lock)
			for p in changed { if p not_in l.told { l.told[strings.clone(p, heap)] = true } }
			wake := !l.posted
			l.posted = true
			sync.unlock(&l.lock)
			if wake {
				sync.atomic_add(&l.refs, 1)
				task_post(l.box, file_tree_told, l, file_tree_told_lost)
			}
			free_all(context.temp_allocator)
		}
	}
	free_all(context.temp_allocator)
	file_tree_link_release(l)
}

@(private = "file")
file_tree_told_lost :: proc(d: rawptr) { file_tree_link_release((^File_Tree_Link)(d)) }

// On the interface's thread: each folder told is marked to be read again.
@(private = "file")
file_tree_told :: proc(d: rawptr, _: u64) {
	l := (^File_Tree_Link)(d)
	defer file_tree_link_release(l)
	heap := runtime.heap_allocator()
	sync.lock(&l.lock)
	t := l.tree
	for p in l.told {
		if t != nil { if f, ok := t.folders[p]; ok { file_tree_mark_dirty(t, f) } }
		delete(p, heap)
	}
	clear(&l.told)
	l.posted = false
	sync.unlock(&l.lock)
}
