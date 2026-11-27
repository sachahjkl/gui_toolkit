package ui

// The file tree's filter (src/md/features/tree-view.md, "The filter"): a field over the tree (Ctrl+F, or typing when
// the tree asks it: File_Tree.type_filters) whose words find names in the whole folder, read or not. A search walks the
// folder on the chores, bounded (FILE_TREE_FIND_MAX_VISITS entries, FILE_TREE_FIND_MAX_MATCHES matches), stopped by the
// next one (a serial), the hidden entries left out unless the tree shows them, and a repository's ignored ones unless
// File_Tree.gitignored. What it found comes in batches; the rows are then the matches and the folders on their way,
// those folders open, the letters matched lit (fuzzy_words, as the palette's). Escape empties the field and gives back
// the open folders of before.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "../fsx"
import i18n "../i18n"

// A search stops after this many entries looked at, or this many found: a disk's root is not walked whole.
FILE_TREE_FIND_MAX_VISITS :: 200_000
FILE_TREE_FIND_MAX_MATCHES :: 2000
// What a search found is shown at least this often while it walks.
@(private = "file") FILE_TREE_FIND_BATCH_MS :: 150

File_Tree_Match :: struct {
	rel:    string,   // (owned) relative to the root, the system's separator between its parts
	folder: bool,
}

File_Tree_Find_State :: struct {
	filter:        Line_Edit,
	filter_open:   bool,
	filter_focus:  bool,    // the field takes the keyboard at its next build
	filter_key:    Key,
	query:         string,  // (owned) what the rows were found for ("": the filter is open and empty)
	found:         map[string]^File_Tree_Folder,   // the folders on the way to what matched, by path (only those entries)
	matches:       [dynamic]File_Tree_Match,       // what the search found so far
	searching:     bool,
	found_more:    bool,    // the search stopped at a bound: there may be more
	found_serial:  u64,     // this tree's search (File_Tree_Link.find_serial when it started)
	saved_open:    map[u64]struct{},   // the open folders before the filter (given back at its end)
	open_swapped:  bool,
	found_opened:  map[u64]struct{},   // the folders the search opened once (a folder closed by the person stays closed)
}

@(private)
file_tree_find_destroy :: proc(t: ^File_Tree) {
	file_tree_found_clear(t)
	delete(t.found)
	delete(t.matches)
	delete(t.saved_open)
	delete(t.found_opened)
	delete(t.query, runtime.heap_allocator())
	t.query = ""
	line_edit_destroy(&t.filter)
}

// Whether the rows are the filter's.
@(private)
file_tree_filtering :: proc(t: ^File_Tree) -> bool { return t.filter_open && t.query != "" }

// Opens the filter (its field takes the keyboard), with `text` typed in it.
file_tree_filter_open :: proc(t: ^File_Tree, text := "") {
	t.filter_focus = true
	if t.filter_open && text == "" { return }
	t.filter_open = true
	if text != "" {
		line_edit_set(&t.filter, text)
		file_tree_find_start(t)
	}
	if current != nil { keep_animating() }
}

// Empties and closes the filter: the rows are the folders' again, opened as they were before it.
file_tree_filter_close :: proc(t: ^File_Tree) {
	if !t.filter_open { return }
	refocus := current != nil && t.filter_key != 0 && gs().focus_key == t.filter_key
	line_edit_set(&t.filter, "")
	file_tree_find_set(t, "")
	t.filter_open = false
	if refocus { set_focus(t.key) }
}

@(private)
file_tree_found_clear :: proc(t: ^File_Tree) {
	for _, f in t.found { file_tree_folder_free(f) }
	clear(&t.found)
}

@(private = "file")
file_tree_matches_clear :: proc(t: ^File_Tree) {
	a := runtime.heap_allocator()
	for m in t.matches { delete(m.rel, a) }
	clear(&t.matches)
}

// The field's text is the query: a new search, the last one stopped.
@(private = "file")
file_tree_find_start :: proc(t: ^File_Tree) { file_tree_find_set(t, strings.trim_space(line_edit_string(&t.filter))) }

@(private = "file")
file_tree_find_set :: proc(t: ^File_Tree, query: string) {
	a := runtime.heap_allocator()
	if query == t.query && (query == "" || t.searching || len(t.matches) > 0) { return }
	delete(t.query, a)
	t.query = strings.clone(query, a)
	if t.link != nil { t.found_serial = u64(sync.atomic_add(&t.link.find_serial, 1)) + 1 }
	file_tree_matches_clear(t)
	file_tree_found_clear(t)
	clear(&t.found_opened)
	t.searching, t.found_more = false, false
	t.stale = true
	if query == "" {
		t.highlight, t.fuzzy = "", false
		if t.open_swapped {
			t.open, t.saved_open = t.saved_open, t.open
			clear(&t.saved_open)
			t.open_swapped = false
			t.open_version += 1
		}
		return
	}
	if !t.open_swapped {
		t.open, t.saved_open = t.saved_open, t.open
		clear(&t.open)
		t.open_swapped = true
		t.open_version += 1
	}
	t.highlight, t.fuzzy = t.query, true
	if t.root == "" || t.link == nil || current == nil { return }
	t.searching = true
	j := new(File_Tree_Find_Job, a)
	j^ = {link = t.link, serial = t.found_serial, generation = t.generation, root = strings.clone(t.root, a), query = strings.clone(query, a), hidden = t.hidden, gitignored = t.gitignored, final = true}
	sync.atomic_add(&t.link.refs, 1)
	task(gs(), file_tree_find_work, file_tree_found_done, j, file_tree_find_lost)
}

// The filter's row: its field, and what it found ("Searching…" while it walks).
@(private)
file_tree_filter_row :: proc(t: ^File_Tree) {
	s := gs()
	em := font_size()
	set_next_axis(.X, .Center)
	s.next_mod.width = fill()
	s.next_mod.height = children_sum()
	push_parent(build_box({}, "###ft_filter_row"))
	defer pop_parent()
	spacer(px(math_round(em * TREE_EDGE_EM)))
	// (what it found inside the field's end: the field takes the row)
	words := ""
	switch {
	case t.query == "":
	case t.searching:
		words = i18n.tr("Searching…")
	case t.found_more:
		words = fmt.tprintf(i18n.tr("%d+ found"), len(t.matches))
	case:
		words = fmt.tprintf(i18n.tr(len(t.matches), "%d found", "%d found"), len(t.matches))
	}
	next({width = fill()})
	a11y({name = i18n.tr("Filter the files")})
	res := line_edit("###ft_filter", &t.filter, {placeholder = i18n.tr("Filter"), clearable = true, suffix = words})
	t.filter_key = res.box.key
	if t.filter_focus { set_focus(res.box.key); t.filter_focus = false }
	if res.changed { file_tree_find_start(t) }
	if res.cancelled { file_tree_filter_close(t); set_focus(t.key); return }
	// (Enter or Down: to the rows, the first one chosen when none is)
	if res.committed || (s.focus_key == res.box.key && key_press(.Down)) {
		set_focus(t.key)
		if t.sel < 0 && len(t.file_rows) > 0 { list_select(&t.list, 0) }
	}
	spacer(px(math_round(em * TREE_EDGE_EM)))
}

@(private = "file")
math_round :: proc(v: f32) -> f32 { return f32(int(v + 0.5)) }

////////////////////////////////
// The search, on the chores

@(private = "file")
File_Tree_Find_Job :: struct {
	link:       ^File_Tree_Link,
	serial:     u64,
	generation: u64,
	root:       string,   // (heap)
	query:      string,   // (heap)
	hidden:     bool,
	gitignored: bool,
	matches:    [dynamic]File_Tree_Match,   // (heap) what this batch brings
	final:      bool,     // the search's end (the task's answer; a batch on the way is not)
	more:       bool,     // it stopped at a bound
}

@(private = "file")
file_tree_find_free :: proc(j: ^File_Tree_Find_Job) {
	a := runtime.heap_allocator()
	for m in j.matches { delete(m.rel, a) }
	delete(j.matches)
	delete(j.root, a)
	delete(j.query, a)
	file_tree_link_release(j.link)
	free(j, a)
}

@(private = "file")
file_tree_find_lost :: proc(d: rawptr) { file_tree_find_free((^File_Tree_Find_Job)(d)) }

// A .gitignore of the folder `dir` added to the rules, as the folder `base` of the repository.
@(private = "file")
file_tree_ignore_read :: proc(ig: ^fsx.Ignore, dir, base: string) {
	data, err := os.read_entire_file_from_path(fsx.path_join(dir, ".gitignore", LOCAL_SEPARATOR, context.temp_allocator), context.temp_allocator)
	if err == nil { fsx.ignore_add(ig, base, string(data)) }
}

// `rel` with "/" between its parts, as git's rules read paths.
@(private = "file")
file_tree_slashed :: proc(rel: string) -> string {
	if LOCAL_SEPARATOR == '/' { return rel }
	out, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
	return out
}

@(private = "file")
file_tree_find_work :: proc(d: rawptr) {
	j := (^File_Tree_Find_Job)(d)
	a := runtime.heap_allocator()
	context.allocator = a
	sep := u8(LOCAL_SEPARATOR)
	ig: fsx.Ignore
	defer fsx.ignore_destroy(&ig)
	// (in a repository: its rules from its top down to the root, the root's path relative to the top before each path)
	prefix := ""
	git := false
	if !j.gitignored {
		top := j.root
		for {
			if fsx.path_kind(fsx.path_join(top, ".git", sep, context.temp_allocator)) != .Absent { git = true; break }
			up := file_path_parent(top, sep)
			if up == top { break }
			top = up
		}
		if git {
			prefix = strings.clone(file_tree_slashed(strings.trim_left(file_path_trim(j.root, sep)[len(file_path_trim(top, sep)):], string([]u8{sep}))))
			file_tree_ignore_read(&ig, top, "")
			dir, base := strings.clone(top), ""
			for part in strings.split(prefix, "/", context.temp_allocator) {
				if part == "" { continue }
				next_dir := fsx.path_join(dir, part, sep, a)
				delete(dir)
				dir = next_dir
				base = base == "" ? part : strings.concatenate({base, "/", part}, context.temp_allocator)
				file_tree_ignore_read(&ig, dir, base)
			}
			delete(dir)
		}
	}
	defer delete(prefix)
	by_path := strings.index_byte(j.query, '/') >= 0 || strings.index_byte(j.query, sep) >= 0
	stack := make([dynamic]string)
	defer {
		for x in stack { delete(x) }
		delete(stack)
	}
	append(&stack, strings.clone(""))
	visited, found := 0, 0
	last := time.tick_now()
	walk: for len(stack) > 0 {
		if sync.atomic_load(&j.link.find_serial) != j.serial { break }
		rel := pop(&stack)
		defer delete(rel)
		dir := rel == "" ? j.root : fsx.path_join(j.root, rel, sep, context.temp_allocator)
		entries, err := fsx.read_folder(dir, context.temp_allocator)
		if err != nil { continue }
		if git && rel != "" {
			slashed := file_tree_slashed(rel)
			file_tree_ignore_read(&ig, dir, prefix == "" ? slashed : strings.concatenate({prefix, "/", slashed}, context.temp_allocator))
		}
		for e in entries {
			visited += 1
			if e.name == ".git" { continue }
			if (e.hidden || (len(e.name) > 0 && e.name[0] == '.')) && !j.hidden { continue }
			folder := e.kind == .Directory   // (a link is not followed: no cycle)
			child := rel == "" ? e.name : fsx.path_join(rel, e.name, sep, context.temp_allocator)
			if git {
				slashed := file_tree_slashed(child)
				if fsx.ignore_match(&ig, prefix == "" ? slashed : strings.concatenate({prefix, "/", slashed}, context.temp_allocator), folder) { continue }
			}
			if _, _, ok := fuzzy_words(j.query, by_path ? child : e.name); ok {
				append(&j.matches, File_Tree_Match{rel = strings.clone(child), folder = folder})
				found += 1
				if found >= FILE_TREE_FIND_MAX_MATCHES { j.more = true; break walk }
			}
			if folder { append(&stack, strings.clone(child)) }
		}
		free_all(context.temp_allocator)
		if visited >= FILE_TREE_FIND_MAX_VISITS { j.more = len(stack) > 0; break }
		// (a batch on its way: what was found shows while the walk goes on)
		if len(j.matches) > 0 && time.duration_milliseconds(time.tick_since(last)) >= FILE_TREE_FIND_BATCH_MS {
			last = time.tick_now()
			b := new(File_Tree_Find_Job)
			b^ = {link = j.link, serial = j.serial, generation = j.generation, matches = j.matches}
			j.matches = {}
			sync.atomic_add(&j.link.refs, 1)
			task_post(j.link.box, file_tree_found_done, b, file_tree_find_lost)
		}
	}
	free_all(context.temp_allocator)
}

// On the interface's thread: what a batch found, added; the rows made again from all of it.
@(private = "file")
file_tree_found_done :: proc(d: rawptr, _: u64) {
	j := (^File_Tree_Find_Job)(d)
	defer file_tree_find_free(j)
	t := j.link.tree
	if t == nil || j.serial != t.found_serial || j.generation != t.generation { return }
	append(&t.matches, ..j.matches[:])
	clear(&j.matches)   // (the strings are the tree's now)
	if j.final { t.searching, t.found_more = false, j.more }
	file_tree_found_make(t)
	t.stale = true
}

// The found folders made again from the matches: each match in its folder, each folder on its way in its parent, those
// folders opened once.
@(private = "file")
file_tree_found_make :: proc(t: ^File_Tree) {
	a := runtime.heap_allocator()
	sep := u8(LOCAL_SEPARATOR)
	file_tree_found_clear(t)
	lists := make(map[string][dynamic]File_Tree_Entry, 64, context.temp_allocator)
	seen := make(map[string]struct{}, 256, context.temp_allocator)
	add :: proc(lists: ^map[string][dynamic]File_Tree_Entry, seen: ^map[string]struct{}, folder, name: string, is_folder: bool) {
		key := fsx.path_join(folder, name, LOCAL_SEPARATOR, context.temp_allocator)
		if key in seen { return }
		seen[key] = {}
		if folder not_in lists { lists[folder] = make([dynamic]File_Tree_Entry, context.temp_allocator) }
		list := &lists[folder]
		append(list, File_Tree_Entry{name = name, folder = is_folder, hidden = len(name) > 0 && name[0] == '.'})
	}
	for m in t.matches {
		folder := t.root
		id := file_tree_root_id(t.root)
		rest := m.rel
		for len(rest) > 0 {
			k := strings.index_byte(rest, sep)
			name := k < 0 ? rest : rest[:k]
			rest = k < 0 ? "" : rest[k + 1:]
			last := rest == ""
			add(&lists, &seen, folder, name, last ? m.folder : true)
			if last { break }
			id = file_tree_child_id(id, name)
			if id not_in t.found_opened { t.found_opened[id] = {}; t.open[id] = {} }
			folder = fsx.path_join(folder, name, sep, context.temp_allocator)
		}
	}
	for path, list in lists {
		f := new(File_Tree_Folder, a)
		f.path = strings.clone(path, a)
		f.entries = make([]File_Tree_Entry, len(list), a)
		for e, i in list { f.entries[i] = {name = strings.clone(e.name, a), folder = e.folder, hidden = e.hidden} }
		file_tree_sort(f.entries)
		t.found[f.path] = f
	}
	t.open_version += 1
}
