package ui

// What each file dialog remembers, by its remember_id: the folder it was left in, its size, its split, its sort,
// Hidden files, the recent folders (FILE_BROWSER_RECENT). It is kept in memory for the run; a program that gives a file
// (file_dialog_memory) has it read on the chores and written by a store.Writer (its own thread, atomic) each time a
// dialog closes: the interface's thread never touches the file.
//
//	ui.file_dialog_memory(&app.ui, filepath.join({state_dir, "file_dialogs.txt"}))   // at the start, once

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "../fsx"
import store "../store"

// The file's first line: another file is not read.
FILE_MEMORY_HEADER :: "gui_toolkit file dialogs 1"
// Between two recent folders of a line (a path holds no such byte).
@(private = "file") FILE_MEMORY_LIST_SEP :: "\x1f"
@(private = "file") FILE_MEMORY_SAVE_WAIT_MS :: 500
@(private = "file") FILE_MEMORY_SAVE_MOST_MS :: 3000

@(private)
File_Memory :: struct {
	folder:     string,
	size:       Vec2,    // ems
	split:      f32,     // ems
	sort:       int,
	descending: bool,
	sort_set:   bool,
	hidden:     bool,
	recent:     [dynamic]string,
}

@(private)
File_Memories :: struct {
	by_id:   map[string]File_Memory,   // (keys and strings in the heap)
	writer:  store.Writer,
	saving:  bool,
	read:    ^File_Memory_Read,
}

// The reading of the file, shared by its task and the memories: the last of the two to let go frees it.
@(private)
File_Memory_Read :: struct {
	state: ^State,     // nil once the memories closed
	path:  string,
	data:  []byte,
	found: bool,
	refs:  int,        // (atomic)
}

// Keeps what the file dialogs of `s` remember in the file at `path`, from now on: what it holds is read on the chores
// and merged at a next build (what a dialog remembered meanwhile wins). Call it once, on the interface's thread.
file_dialog_memory :: proc(s: ^State, path: string) {
	fb := file_browser_of(s)
	m := &fb.memory
	if m.saving || path == "" { return }
	a := runtime.heap_allocator()
	store.writer_open(&m.writer, path, wait_ms = FILE_MEMORY_SAVE_WAIT_MS, most_ms = FILE_MEMORY_SAVE_MOST_MS, allocator = a)
	m.saving = true
	r := new(File_Memory_Read, a)
	r^ = {state = s, path = strings.clone(path, a), refs = 2}
	m.read = r
	work :: proc(d: rawptr) {
		r := (^File_Memory_Read)(d)
		r.data, r.found = fsx.read_all(r.path, runtime.heap_allocator())
	}
	done :: proc(d: rawptr, _: u64) {
		r := (^File_Memory_Read)(d)
		if r.state != nil && r.state.files != nil {
			m := &r.state.files.memory
			m.read = nil
			if r.found { file_memories_merge(m, string(r.data)) }
			file_memory_read_release(r)   // (the memories' share)
		}
		file_memory_read_release(r)
	}
	lost :: proc(d: rawptr) { file_memory_read_release((^File_Memory_Read)(d)) }
	task(s, work, done, r, lost)
}

@(private = "file")
file_memory_read_release :: proc(r: ^File_Memory_Read) {
	if sync.atomic_sub(&r.refs, 1) != 1 { return }
	a := runtime.heap_allocator()
	delete(r.path, a)
	delete(r.data, a)
	free(r, a)
}

// The program's end (ui.destroy): what changed is written (it waits for the disk), the memories freed.
@(private)
file_memories_close :: proc(m: ^File_Memories) {
	if m.read != nil {
		m.read.state = nil
		file_memory_read_release(m.read)
	}
	if m.saving { store.writer_close(&m.writer) }
	for id, &e in m.by_id {
		file_memory_free(&e)
		delete(id, runtime.heap_allocator())
	}
	delete(m.by_id)
	m^ = {}
}

@(private = "file")
file_memory_free :: proc(e: ^File_Memory) {
	a := runtime.heap_allocator()
	delete(e.folder, a)
	for r in e.recent { delete(r, a) }
	delete(e.recent)
	e^ = {}
}

// What dialog `id` remembers (nil: nothing yet).
@(private)
file_memory_of :: proc(m: ^File_Memories, id: string) -> ^File_Memory {
	if e, ok := &m.by_id[id]; ok { return e }
	return nil
}

// The dialog closes: what it is now is remembered (`chosen`: the folder of what it chose, first of the recent ones; ""
// for none), and written when a file keeps it.
@(private)
file_memory_remember :: proc(fb: ^File_Browser, chosen: string) {
	a := runtime.heap_allocator()
	m := &fb.memory
	if m.by_id == nil { m.by_id = make(map[string]File_Memory, a) }
	id := fb.d.remember_id
	e := file_memory_of(m, id)
	if e == nil {
		m.by_id[strings.clone(id, a)] = {recent = make([dynamic]string, a)}
		e = file_memory_of(m, id)
	}
	if fb.folder != "" { delete(e.folder, a); e.folder = strings.clone(fb.folder, a) }
	e.size, e.split, e.hidden = fb.size, fb.split, fb.hidden
	e.sort, e.descending, e.sort_set = fb.table.sort, fb.table.descending, true
	if chosen != "" && !file_memory_bad(chosen) {
		for r, i in e.recent {
			if r == chosen { delete(r, a); ordered_remove(&e.recent, i); break }
		}
		inject_at(&e.recent, 0, strings.clone(chosen, a))
		for len(e.recent) > FILE_BROWSER_RECENT { delete(pop(&e.recent), a) }
	}
	if m.saving { store.writer_put(&m.writer, transmute([]byte)file_memories_text(m)) }
}

// A text that cannot be a field of a line (a path with a line break, a tab or the list's separator: never kept).
@(private = "file")
file_memory_bad :: proc(s: string) -> bool { return strings.index_any(s, "\t\r\n\x1f") >= 0 }

// The file: its header, then a line per dialog,
// `id <tab> folder <tab> width <tab> height <tab> split <tab> sort <tab> descending <tab> hidden <tab> recent...`.
@(private)
file_memories_text :: proc(m: ^File_Memories, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, FILE_MEMORY_HEADER)
	strings.write_byte(&b, '\n')
	for id, e in m.by_id {
		if file_memory_bad(id) { continue }
		folder := file_memory_bad(e.folder) ? "" : e.folder
		fmt.sbprintf(&b, "%s\t%s\t%.2f\t%.2f\t%.2f\t%d\t%d\t%d\t", id, folder, e.size.x, e.size.y, e.split, e.sort, e.descending ? 1 : 0, e.hidden ? 1 : 0)
		for r, i in e.recent {
			if i > 0 { strings.write_string(&b, FILE_MEMORY_LIST_SEP) }
			strings.write_string(&b, r)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// The dialogs of a file's text that are not remembered already (a dialog closed before the file came is newer). A
// line that does not read is skipped; a text of another header adds nothing.
@(private)
file_memories_merge :: proc(m: ^File_Memories, text: string) {
	a := runtime.heap_allocator()
	if m.by_id == nil { m.by_id = make(map[string]File_Memory, a) }
	rest := text
	first := true
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if first {
			first = false
			if line != FILE_MEMORY_HEADER { return }
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 9 || f[0] in m.by_id { continue }
		w, w_ok := strconv.parse_f32(f[2])
		h, h_ok := strconv.parse_f32(f[3])
		split, split_ok := strconv.parse_f32(f[4])
		sort, sort_ok := strconv.parse_int(f[5], 10)
		if !w_ok || !h_ok || !split_ok || !sort_ok || sort < TABLE_UNSORTED || sort > FILE_COLUMN_KIND { continue }
		e := File_Memory{folder = strings.clone(f[1], a), size = {w, h}, split = split, sort = sort, descending = f[6] == "1", sort_set = true, hidden = f[7] == "1"}
		e.recent = make([dynamic]string, a)
		list := f[8]
		for p in strings.split_iterator(&list, FILE_MEMORY_LIST_SEP) {
			if p != "" && len(e.recent) < FILE_BROWSER_RECENT { append(&e.recent, strings.clone(p, a)) }
		}
		m.by_id[strings.clone(f[0], a)] = e
	}
}
