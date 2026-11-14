package ui

// The file browser (docs/file-browser.md): the dialog ui.file_dialog shows, drawn by the toolkit, reading its folders
// through a File_Source (file_source.odin). One per State (State.files), built by end_build while it is open: a program
// calls nothing per frame. This file holds its state and what it does; file_browser_view.odin builds it,
// file_browser_preview.odin reads and shows the preview, file_browser_memory.odin keeps what each dialog remembers.
//
// Its machines, each a remote.Remote (an answer of a reading given up is dropped by its ticket; every answer of a closed
// dialog by its serial):
//   listing:  the folder shown (Idle -> Loading -> Ready | Refused | Failed; a missing folder goes up instead)
//   making:   a new folder (Loading -> Ready: the folder read again, the new one selected | Failed: said under its row)
//   preview:  the file selected (preview.reading)
//   finding:  a search in subfolders (File_Source.find): Idle while the query is quiet for less than FILE_FIND_QUIET_MS,
//             Loading -> Ready | Failed; reset when the query empties, the toggle goes off, the folder changes
// and the dialog's own: closed -> open -> (asking: Save over a file, the confirm) -> closed, `done` called once.
// The rows show the folder's entries, or the find's (the toggle on and a query typed): File_Rows_Key.found says which.

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:time"
import i18n "../i18n"
import "../platform"
import remote "../remote"
import timefmt "../timefmt"

// A folder that answers sooner than this shows no "Reading" line: a fast folder does not flash.
FILE_BROWSER_SLOW_MS :: 300
// What the preview reads of a text file, and at most of a picture.
FILE_PREVIEW_BYTES :: 64 * 1024
FILE_PREVIEW_IMAGE_BYTES :: 32 * 1024 * 1024
// The recent folders a dialog keeps, per remember_id.
FILE_BROWSER_RECENT :: 8
// What a build of the browser may take once its rows are made (tests/file_browser checks it with 100 000 entries).
FILE_BROWSER_BUILD_BUDGET_MS :: 16
// A search in subfolders: the entries it gives at most, and the time the query stays unchanged before it is asked (a
// search per letter typed would start a walk per letter).
FILE_FIND_LIMIT :: 200
FILE_FIND_QUIET_MS :: 150

// The columns of the list.
@(private) FILE_COLUMN_NAME :: 0
@(private) FILE_COLUMN_SIZE :: 1
@(private) FILE_COLUMN_MODIFIED :: 2
@(private) FILE_COLUMN_KIND :: 3

// How a navigation moves in the history (Back, Forward).
@(private)
File_Move :: enum u8 {
	New,       // a folder chosen: the one left goes into Back, Forward is emptied
	Back,
	Forward,
	Again,     // the same folder read again (F5, Try again)
	Replace,   // in place of the one shown, nothing remembered (a missing folder: its parent)
}

// What the rows were made from: another of these, they are made again.
@(private)
File_Rows_Key :: struct {
	entries:    u64,    // the version of the entries they were made of (entries_version, or found_version)
	hidden:     bool,
	type_index: int,
	found:      bool,   // of the find's entries (fb.found), not the folder's
}

@(private)
File_Browser :: struct {
	state:        ^State,
	// the dialog
	open:         bool,
	shown:        bool,       // the modal's `open` (Escape, a press outside: false)
	serial:       u64,        // counts the dialogs: a reply of another one is dropped
	kind:         File_Dialog_Kind,
	d:            platform.File_Dialog,   // the options (owned copies)
	done:         File_Dialog_Done,
	user:         rawptr,
	source:       File_Source,
	sep:          u8,
	source_places: [dynamic]platform.File_Place,   // what the source knows (in places_arena)
	places_arena: virtual.Arena,
	local:        File_Local,  // the computer's places (file_local.odin)

	// the folder
	folder:       string,     // shown (the path bar's); "" before the first one is known
	back:         [dynamic]string,
	forward:      [dynamic]string,
	listing:      remote.Remote,
	listing_ms:   f64,        // when its reading began (the "Reading" line comes after FILE_BROWSER_SLOW_MS)
	entries:      [dynamic]File_Entry,   // the folder's (names in entries_arena)
	entries_arena: virtual.Arena,
	entries_version: u64,
	pending:      string,     // an entry to find in the next listing (the path field's last part)
	pending_act:  bool,       // ... entered or chosen; else selected

	// the list
	columns:      [4]Table_Column,
	table:        Table,
	data:         Table_Data,
	rows:         [dynamic]int,        // data row -> entry
	by_id:        map[u64]int,         // row identity -> data row
	made_for:     File_Rows_Key,
	made:         bool,
	applied_query: string,
	rows_made:    int,        // the rows made, and filtered or sorted (file_browser_counts)
	rows_applied: int,
	select_name:  string,     // the row selected once the rows are made (a new folder, a path typed)
	shift_from:   int,        // Shift+arrows: where the range of marks starts (-1: none)
	open_key:     [3]u64,     // what Open's act was last looked at for (file_browser_can_act), and whether it can
	open_ok:      bool,

	// the controls
	filter:       Line_Edit,
	filter_key:   Key,
	name:         Line_Edit,  // Save: the file's name
	name_key:     Key,
	path_edit:    Line_Edit,  // Ctrl+L: the path as a field
	path_editing: bool,
	path_key:     Key,
	hidden:       bool,
	type_index:   int,        // the type line chosen (len(d.filters): "All files")
	new_folder:   bool,       // the inline row of a new folder's name
	new_name:     Line_Edit,
	new_key:      Key,
	making:       remote.Remote,
	making_name:  string,
	asking:       bool,       // Save over a file of the folder: the confirm is open
	ask_path:     string,
	size:         Vec2,       // the dialog's, in ems ({}: its own)
	split:        f32,        // the preview's width, in ems
	main_width:   f32,        // the room of the list and the preview at the last layout (the preview shows when wide)
	focus_list:   bool,       // the list takes the keyboard at the next build

	// the search in subfolders
	deep:         bool,       // the toggle "In subfolders"
	finding:      remote.Remote,
	found:        [dynamic]File_Entry,   // its answer, best first (names: paths relative to `folder`, in found_arena)
	found_arena:  virtual.Arena,
	found_version: u64,
	find_query:   string,     // what the find on its way, or answered, asked ("": none)
	find_hidden:  bool,       // ... with Hidden files on
	find_seen:    string,     // the query wanted at the last build (its change starts the quiet time)
	find_typed_ms: f64,       // when it changed
	find_ms:      f64,        // when the find was asked (the "Searching" line comes after FILE_BROWSER_SLOW_MS)
	find_stop:    ^File_Find_Stop,   // stops the local walks (file_local.odin)
	sort_kept:    bool,       // the find's rows show as found: the folder's sort, back when they go
	kept_sort:    int,
	kept_descending: bool,

	preview:      File_Preview,
	memory:       File_Memories,
}

// The browser of `s`, made at its first use.
@(private)
file_browser_of :: proc(s: ^State) -> ^File_Browser {
	if s.files != nil { return s.files }
	a := runtime.heap_allocator()
	fb := new(File_Browser, a)
	fb.state = s
	fb.back = make([dynamic]string, a)
	fb.forward = make([dynamic]string, a)
	fb.entries = make([dynamic]File_Entry, a)
	fb.found = make([dynamic]File_Entry, a)
	fb.rows = make([dynamic]int, a)
	fb.by_id = make(map[u64]int, a)
	fb.source_places = make([dynamic]platform.File_Place, a)
	fb.shift_from = -1
	// (in the order of FILE_COLUMN_NAME, _SIZE, _MODIFIED, _KIND)
	fb.columns = {
		{title = i18n.later("Name"), width = 0},
		{title = i18n.later("Size"), width = 6.5, number = true},
		{title = i18n.later("Modified"), width = 9, number = true, weak = true},
		// (the icon tells the kind already: the column is there for who asks, and leaves the name its room)
		{title = i18n.later("Kind"), width = 7, weak = true, hidden = true},
	}
	context.allocator = a
	table_init(&fb.table, fb.columns[:])
	fb.table.fuzzy = true
	fb.table.lead_em = 0.4
	fb.table.lead_user = fb
	fb.table.vl.no_typeahead = true   // (what is typed goes to the filter)
	s.files = fb
	return fb
}

// ui.destroy: an open dialog is given up (its `done` not called), its memory written.
@(private)
file_browser_destroy :: proc(s: ^State) {
	fb := s.files
	if fb == nil { return }
	a := runtime.heap_allocator()
	context.allocator = a
	if fb.open { file_browser_close(fb) }
	file_memories_close(&fb.memory)
	file_local_destroy(&fb.local)
	table_destroy(&fb.table)
	table_data_destroy(&fb.data)
	delete(fb.back); delete(fb.forward); delete(fb.entries); delete(fb.found); delete(fb.rows); delete(fb.by_id)
	delete(fb.source_places)
	virtual.arena_destroy(&fb.entries_arena)
	virtual.arena_destroy(&fb.found_arena)
	virtual.arena_destroy(&fb.places_arena)
	line_edit_destroy(&fb.filter); line_edit_destroy(&fb.name); line_edit_destroy(&fb.path_edit); line_edit_destroy(&fb.new_name)
	remote.destroy(&fb.listing); remote.destroy(&fb.making); remote.destroy(&fb.finding)
	delete(fb.find_query, a); delete(fb.find_seen, a)
	// (a walk still on its way holds the stop: it stops, and the last of them frees it)
	file_find_stop(fb)
	file_find_stop_release(fb.find_stop)
	file_preview_destroy(fb)
	free(fb, a)
	s.files = nil
}

// What a test reads of the browser: whether it is open, the folder shown, how many times its rows were made and
// filtered or sorted (a build that changed nothing does neither), the rows shown, the search in subfolders.
File_Browser_Counts :: struct {
	open:         bool,
	folder:       string,
	rows_made:    int,
	rows_applied: int,
	rows_shown:   int,
	entries:      int,
	list_layouts: int,   // the times the list placed its rows again (Virtual_List.offsets_made)
	deep:         bool,  // "In subfolders" is on
	found:        int,   // the entries of the last find's answer
	found_shown:  bool,  // the rows are the find's
}

file_browser_counts :: proc(s: ^State) -> File_Browser_Counts {
	fb := s.files
	if fb == nil { return {} }
	return {open = fb.open, folder = fb.folder, rows_made = fb.rows_made, rows_applied = fb.rows_applied,
		rows_shown = len(fb.table.rows), entries = len(fb.entries), list_layouts = fb.table.vl.offsets_made,
		deep = fb.deep, found = len(fb.found), found_shown = fb.made && fb.made_for.found}
}

// Whether the toolkit's file browser is open (ui.file_dialog shows it until it answers): a program that counts what
// is over its window, or waits for its keys.
file_dialog_shown :: proc(s: ^State) -> bool { return s.files != nil && s.files.open }

////////////////////////////////
// Open and close

@(private)
file_browser_open :: proc(s: ^State, kind: File_Dialog_Kind, d: platform.File_Dialog, done: File_Dialog_Done, user: rawptr, source: ^File_Source) {
	fb := file_browser_of(s)
	a := runtime.heap_allocator()
	context.allocator = a
	if fb.open { file_browser_finish(fb, .Cancelled) }   // (one dialog at a time: the one shown gives way)
	fb.serial += 1
	fb.open, fb.shown = true, true
	fb.kind, fb.done, fb.user = kind, done, user
	fb.d = file_dialog_options_clone(d, a)
	fb.source = source != nil ? source^ : local_files()
	fb.sep = fb.source.separator != 0 ? fb.source.separator : '/'
	fb.table.vl.multi = kind == .Open && d.multiple
	fb.table.vl.sel = -1
	list_marks_clear(&fb.table.vl)
	fb.type_index = clamp(d.filter_index, 0, max(len(d.filters) - (d.all_files ? 0 : 1), 0))
	fb.made = false
	fb.focus_list = true
	fb.shift_from = -1
	fb.listing_ms = clock_ms(s)
	line_edit_clear(&fb.filter)
	fb.deep = d.find_deep && fb.source.find != nil
	// (the suggested name selected without its extension: what is typed replaces the name, the type stays)
	line_edit_set(&fb.name, d.suggested_name)
	fb.name.mark = 0
	if dot := strings.last_index_byte(d.suggested_name, '.'); dot > 0 { fb.name.cursor = dot }
	// what this dialog remembers: its size, its split, its sort, hidden files, the folder it was left in
	m := file_memory_of(&fb.memory, d.remember_id)
	fb.size = m != nil ? m.size : Vec2{}
	fb.split = m != nil && m.split > 0 ? m.split : FILE_PREVIEW_DEFAULT_EM
	fb.hidden = m != nil && m.hidden
	table_layout_reset(&fb.table.layout)
	fb.table.sort, fb.table.descending = FILE_COLUMN_NAME, false
	if m != nil && m.sort_set { fb.table.sort, fb.table.descending = m.sort, m.descending }
	fb.table.shown[FILE_COLUMN_SIZE] = .Size in fb.source.caps
	fb.table.shown[FILE_COLUMN_MODIFIED] = .Modified in fb.source.caps
	file_local_warm(s)   // (the computer's places)
	file_browser_places_refresh(fb)
	start := d.start_dir
	if start == "" && m != nil { start = m.folder }
	if start == "" && fb.source.start != nil { start = fb.source.start(&fb.source, context.temp_allocator) }
	if start == "" && len(fb.source_places) > 0 { start = fb.source_places[0].path }
	// (the computer's first folder is read on the chores: the dialog starts once it is known)
	if start != "" { file_browser_go(fb, start) }
}

// The computer's places came (file_local_warm): shown, and the dialog that waited for its first folder starts.
@(private)
file_browser_local_ready :: proc(fb: ^File_Browser) {
	if !fb.open { return }
	context.allocator = runtime.heap_allocator()
	file_browser_places_refresh(fb)
	if fb.folder != "" { return }
	start := fb.source.start != nil ? fb.source.start(&fb.source, context.temp_allocator) : ""
	if start == "" && len(fb.source_places) > 0 { start = fb.source_places[0].path }
	if start == "" { start = string([]u8{fb.sep}) }
	file_browser_go(fb, start)
}

// The source's places, again (they may come later than the dialog: the computer's).
@(private)
file_browser_places_refresh :: proc(fb: ^File_Browser) {
	virtual.arena_free_all(&fb.places_arena)
	clear(&fb.source_places)
	if fb.source.places == nil { return }
	for p in fb.source.places(&fb.source, virtual.arena_allocator(&fb.places_arena)) { append(&fb.source_places, p) }
}

// Closes the dialog without answering (file_browser_finish answers). Everything of this dialog goes; what every
// dialog keeps (the memory, the computer's places) stays.
@(private)
file_browser_close :: proc(fb: ^File_Browser) {
	a := runtime.heap_allocator()
	fb.open, fb.shown, fb.asking = false, false, false
	fb.serial += 1   // (a reply still on its way is of no dialog now)
	file_dialog_options_free(&fb.d, a)
	file_browser_find_drop(fb)
	delete(fb.find_seen, a); fb.find_seen = ""
	file_strings_clear(&fb.back)
	file_strings_clear(&fb.forward)
	delete(fb.folder, a); fb.folder = ""
	delete(fb.pending, a); fb.pending = ""
	delete(fb.select_name, a); fb.select_name = ""
	delete(fb.applied_query, a); fb.applied_query = ""
	delete(fb.making_name, a); fb.making_name = ""
	delete(fb.ask_path, a); fb.ask_path = ""
	remote.reset(&fb.listing)
	remote.reset(&fb.making)
	file_entries_clear(fb)
	file_browser_sort_back(fb)
	table_data_reset(&fb.data, len(fb.columns))
	clear(&fb.rows)
	clear(&fb.by_id)
	table_apply(&fb.table, &fb.data, "")
	fb.table.highlight = fb.table.query
	fb.made = false
	fb.new_folder, fb.path_editing = false, false
	file_preview_clear(fb)
	virtual.arena_free_all(&fb.places_arena)
	clear(&fb.source_places)
}

// The dialog's answer: `done` gets it, once; the dialog is closed first (`done` may ask for another one).
@(private)
file_browser_finish :: proc(fb: ^File_Browser, status: platform.Dialog_Status, paths: []string = nil) {
	if !fb.open { return }
	a := runtime.heap_allocator()
	r := platform.Dialog_Result{status = status, filter = fb.type_index}
	if len(paths) > 0 {
		r.paths = make([]string, len(paths), a)
		for p, i in paths { r.paths[i] = strings.clone(p, a) }
	}
	done, user := fb.done, fb.user
	file_browser_sort_back(fb)   // (the folder's sort is the one remembered, not the find's order)
	file_memory_remember(fb, status == .Chosen ? (fb.kind == .Folder && len(paths) > 0 ? paths[0] : fb.folder) : "")
	file_browser_close(fb)
	if done != nil { done(r, user) }
	platform.dialog_result_destroy(&r, a)
}

@(private)
file_strings_clear :: proc(list: ^[dynamic]string) {
	for x in list { delete(x, runtime.heap_allocator()) }
	clear(list)
}

@(private)
file_entries_clear :: proc(fb: ^File_Browser) {
	virtual.arena_free_all(&fb.entries_arena)
	clear(&fb.entries)
	fb.entries_version += 1
}

////////////////////////////////
// Readings

// Shows `path` and reads it. A folder other than the one shown starts empty (its entries are not those of the last: a
// press on them would act on the wrong folder); the same one keeps its entries until the new ones come.
@(private)
file_browser_go :: proc(fb: ^File_Browser, path: string, move := File_Move.New) {
	a := runtime.heap_allocator()
	target := strings.clone(path, context.temp_allocator)   // (`path` may be a slice of what changes below)
	if target != fb.folder {
		switch move {
		case .New:
			if fb.folder != "" { append(&fb.back, strings.clone(fb.folder, a)) }
			file_strings_clear(&fb.forward)
		case .Back:    if fb.folder != "" { append(&fb.forward, strings.clone(fb.folder, a)) }
		case .Forward: if fb.folder != "" { append(&fb.back, strings.clone(fb.folder, a)) }
		case .Again, .Replace:
		}
		delete(fb.folder, a)
		fb.folder = strings.clone(target, a)
		delete(fb.select_name, a)
		fb.select_name = ""
		file_entries_clear(fb)
		file_browser_find_drop(fb)   // (what was found is under the folder left)
		line_edit_clear(&fb.filter)
		fb.new_folder = false
		fb.shift_from = -1
		list_marks_clear(&fb.table.vl)
		fb.table.vl.sel = -1
		vlist_scroll_to(&fb.table.vl, 0)
	}
	ticket := remote.begin(&fb.listing)
	fb.listing_ms = clock_ms(fb.state)
	reply := File_Reply{state = fb.state, dialog = fb.serial, ticket = ticket, kind = .List}
	if fb.source.list == nil {
		remote.answer(&fb.listing, ticket, .Failed, i18n.tr("This source lists no folder."))
		return
	}
	fb.source.list(&fb.source, strings.clone(fb.folder, context.temp_allocator), reply)
}

@(private)
file_browser_up :: proc(fb: ^File_Browser) {
	up := file_path_parent(fb.folder, fb.sep)
	if up != "" && up != fb.folder {
		// (the folder left is selected in its parent: the way back down is under the keyboard)
		name := file_path_name(fb.folder, fb.sep)
		select := strings.clone(name, context.temp_allocator)
		file_browser_go(fb, up)
		file_browser_select_later(fb, select)
	}
}

@(private)
file_browser_back :: proc(fb: ^File_Browser) {
	if len(fb.back) == 0 { return }
	p := pop(&fb.back)
	defer delete(p, runtime.heap_allocator())
	file_browser_go(fb, p, .Back)
}

@(private)
file_browser_forward :: proc(fb: ^File_Browser) {
	if len(fb.forward) == 0 { return }
	p := pop(&fb.forward)
	defer delete(p, runtime.heap_allocator())
	file_browser_go(fb, p, .Forward)
}

@(private)
file_browser_select_later :: proc(fb: ^File_Browser, name: string) {
	a := runtime.heap_allocator()
	delete(fb.select_name, a)
	fb.select_name = strings.clone(name, a)
}

// The index of the entry `name`, -1 when the folder has none.
@(private)
file_entry_named :: proc(fb: ^File_Browser, name: string) -> int {
	for e, i in fb.entries { if e.name == name { return i } }
	return -1
}

@(private)
file_browser_listed :: proc(fb: ^File_Browser, ticket: u64, entries: []File_Entry) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fb.listing, ticket, .Ready) { return }
	virtual.arena_free_all(&fb.entries_arena)
	clear(&fb.entries)
	ea := virtual.arena_allocator(&fb.entries_arena)
	reserve(&fb.entries, len(entries))
	for e in entries {
		c := e
		c.name = strings.clone(e.name, ea)
		append(&fb.entries, c)
	}
	fb.entries_version += 1
	if fb.pending == "" { return }
	name := strings.clone(fb.pending, context.temp_allocator)
	act := fb.pending_act
	delete(fb.pending, runtime.heap_allocator())
	fb.pending, fb.pending_act = "", false
	i := file_entry_named(fb, name)
	if i < 0 {
		if act && fb.kind == .Save { line_edit_set(&fb.name, name) }   // (a new file's name, in this folder)
		return
	}
	if act && fb.entries[i].kind == .Folder {
		file_browser_go(fb, file_path_join(fb.folder, name, fb.sep))
		return
	}
	if act && fb.kind == .Open {
		paths := [1]string{file_path_join(fb.folder, name, fb.sep)}
		file_browser_finish(fb, .Chosen, paths[:])
		return
	}
	if act && fb.kind == .Save { line_edit_set(&fb.name, name) }
	file_browser_select_later(fb, name)
}

@(private)
file_browser_failed :: proc(fb: ^File_Browser, kind: File_Reply_Kind, ticket: u64, message: string, refused, missing: bool) {
	context.allocator = runtime.heap_allocator()
	switch kind {
	case .List:
		if !remote.current(&fb.listing, ticket) { return }
		delete(fb.pending, runtime.heap_allocator())   // (what was to be found in it is not)
		fb.pending, fb.pending_act = "", false
		if missing {
			// (deleted since it was remembered or shown: its nearest parent that is there)
			up := file_path_parent(fb.folder, fb.sep)
			if up != "" && up != fb.folder {
				file_browser_go(fb, up, .Replace)
				return
			}
		}
		_ = remote.answer(&fb.listing, ticket, refused ? .Refused : .Failed, message)
		file_entries_clear(fb)
	case .Make:
		_ = remote.answer(&fb.making, ticket, refused ? .Refused : .Failed, message)
	case .Read:
		file_preview_failed(fb, ticket, message)
	case .Find:
		_ = remote.answer(&fb.finding, ticket, refused ? .Refused : .Failed, message)
	}
}

////////////////////////////////
// Search in subfolders

// Whether the rows are the find's: the toggle on, a source that finds, a query typed.
@(private)
file_browser_finds :: proc(fb: ^File_Browser) -> bool {
	return fb.deep && fb.source.find != nil && line_edit_string(&fb.filter) != ""
}

// At each build, before the list: the query wanted (empty with the toggle off) is compared with the last one (a string,
// not the entries); a new one is asked once it stayed the same FILE_FIND_QUIET_MS, by the State's clock. Nothing is
// asked again while it stays the same: no request per frame.
@(private)
file_browser_find_follow :: proc(fb: ^File_Browser) {
	s := fb.state
	a := runtime.heap_allocator()
	want := file_browser_finds(fb) ? line_edit_string(&fb.filter) : ""
	now := clock_ms(s)
	if want != fb.find_seen {
		delete(fb.find_seen, a)
		fb.find_seen = strings.clone(want, a)
		fb.find_typed_ms = now
		if want == "" { file_browser_find_drop(fb) }
	}
	// (the computer's first folder not known yet: asked once it is)
	if want == "" || fb.folder == "" || (want == fb.find_query && fb.hidden == fb.find_hidden) { return }
	if waited := now - fb.find_typed_ms; waited < FILE_FIND_QUIET_MS {
		wake_within(s, int(FILE_FIND_QUIET_MS - waited) + WAKE_MARGIN_MS)
		return
	}
	delete(fb.find_query, a)
	fb.find_query = strings.clone(want, a)
	fb.find_hidden = fb.hidden
	fb.find_ms = now
	context.allocator = a
	ticket := remote.begin(&fb.finding)
	reply := File_Reply{state = s, dialog = fb.serial, ticket = ticket, kind = .Find, hidden = fb.hidden}
	fb.source.find(&fb.source, strings.clone(fb.folder, context.temp_allocator), strings.clone(want, context.temp_allocator), FILE_FIND_LIMIT, reply)
}

// No find wanted any more (the query emptied, the toggle off, another folder, the dialog closed): the walk on its way
// stops, its answer is dropped, what was found goes.
@(private)
file_browser_find_drop :: proc(fb: ^File_Browser) {
	file_find_stop(fb)
	context.allocator = runtime.heap_allocator()
	remote.reset(&fb.finding)
	delete(fb.find_query, runtime.heap_allocator())
	fb.find_query, fb.find_hidden = "", false
	if len(fb.found) > 0 {
		virtual.arena_free_all(&fb.found_arena)
		clear(&fb.found)
		fb.found_version += 1
	}
}

@(private)
file_browser_found :: proc(fb: ^File_Browser, ticket: u64, entries: []File_Entry) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fb.finding, ticket, .Ready) { return }
	virtual.arena_free_all(&fb.found_arena)
	clear(&fb.found)
	ea := virtual.arena_allocator(&fb.found_arena)
	reserve(&fb.found, len(entries))
	for e in entries {
		c := e
		c.name = strings.clone(e.name, ea)
		append(&fb.found, c)
	}
	fb.found_version += 1
}

// The folder's sort back, when the find's rows had set it aside.
@(private)
file_browser_sort_back :: proc(fb: ^File_Browser) {
	if !fb.sort_kept { return }
	fb.table.sort, fb.table.descending = fb.kept_sort, fb.kept_descending
	fb.sort_kept = false
}

////////////////////////////////
// New folder

@(private)
file_browser_new_folder :: proc(fb: ^File_Browser) {
	if .Make_Folder not_in fb.source.caps || fb.source.make_folder == nil || fb.folder == "" { return }
	fb.new_folder = true
	remote.reset(&fb.making)
	line_edit_set(&fb.new_name, i18n.tr("New folder"))
	line_edit_select_all(&fb.new_name)
	fb.new_key = 0   // (the field takes the keyboard when it is built)
}

@(private)
file_browser_make :: proc(fb: ^File_Browser) {
	name := strings.trim_space(line_edit_string(&fb.new_name))
	if name == "" { return }
	if strings.index_byte(name, fb.sep) >= 0 || strings.index_byte(name, '/') >= 0 {
		remote.settle(&fb.making, .Failed, i18n.tr("A folder's name has no separator in it."))
		return
	}
	a := runtime.heap_allocator()
	delete(fb.making_name, a)
	fb.making_name = strings.clone(name, a)
	ticket := remote.begin(&fb.making)
	fb.source.make_folder(&fb.source, file_path_join(fb.folder, name, fb.sep), {state = fb.state, dialog = fb.serial, ticket = ticket, kind = .Make})
}

@(private)
file_browser_made :: proc(fb: ^File_Browser, ticket: u64) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fb.making, ticket, .Ready) { return }
	fb.new_folder = false
	name := strings.clone(fb.making_name, context.temp_allocator)
	file_browser_go(fb, fb.folder, .Again)
	file_browser_select_later(fb, name)
}

////////////////////////////////
// The rows

// The rows of the list, made again when the entries, Hidden files or the type changed, and filtered and sorted again
// when the filter or the sort changed: a build that changed none of them does no work in proportion to the entries.
@(private)
file_browser_rows :: proc(fb: ^File_Browser, sorted: bool) {
	found := file_browser_finds(fb)
	key := File_Rows_Key{entries = found ? fb.found_version : fb.entries_version, hidden = fb.hidden, type_index = fb.type_index, found = found}
	remade := false
	if !fb.made || key != fb.made_for {
		// (the find's rows in the order found, best first: the folder's sort set aside until they go, unless the person
		// clicks a column)
		if found && !fb.sort_kept {
			fb.kept_sort, fb.kept_descending, fb.sort_kept = fb.table.sort, fb.table.descending, true
			fb.table.sort, fb.table.descending = TABLE_UNSORTED, false
		} else if !found {
			file_browser_sort_back(fb)
		}
		fb.made_for = key   // (before the rows: file_rows_entries reads which entries they are of)
		file_browser_rows_make(fb)
		fb.made, remade = true, true
		fb.rows_made += 1
		if found { vlist_scroll_to(&fb.table.vl, 0) }
	}
	q := line_edit_string(&fb.filter)
	if remade || sorted || q != fb.applied_query {
		a := runtime.heap_allocator()
		delete(fb.applied_query, a)
		fb.applied_query = strings.clone(q, a)
		// (the find filtered and ranked them already: the table filters nothing more, and lights the query's letters)
		table_apply(&fb.table, &fb.data, found ? "" : q)
		fb.table.highlight = found ? fb.applied_query : fb.table.query
		if found && fb.table.vl.sel < 0 && len(fb.table.ids) > 0 { list_select(&fb.table.vl, 0) }
		fb.rows_applied += 1
	}
	// (looked for once the folder's rows are there, not at every build: a pass over them)
	if fb.select_name != "" && remade && fb.listing.state == .Ready {
		_ = table_select_id(&fb.table, file_row_id(fb.select_name))
		delete(fb.select_name, runtime.heap_allocator())
		fb.select_name = ""
	}
}

// A row's identity: its name's (a name is one in its folder), so that the selection stays on it through a filter, a
// sort and a reading again.
@(private)
file_row_id :: proc(name: string) -> u64 { return hash_bytes(transmute([]u8)name) }

@(private)
file_browser_rows_make :: proc(fb: ^File_Browser) {
	table_data_reset(&fb.data, len(fb.columns))
	clear(&fb.rows)
	clear(&fb.by_id)
	now := f64(time.to_unix_nanoseconds(time.now()) / 1_000_000)
	offset := timefmt.local_offset_minutes()
	filters := file_browser_type_filters(fb)
	words := [File_Look]string{
		.Folder = i18n.tr("Folder"), .File = i18n.tr("File"), .Image = i18n.tr("Image"), .Code = i18n.tr("Code"),
		.Archive = i18n.tr("Archive"), .Text = i18n.tr("Text"), .Link = i18n.tr("Link"),
	}
	found := fb.made_for.found
	// (the folder's: folders first, in the data too, so the rows unsorted keep them first; the find's: one pass, in the
	// order found, a folder and a file in one group)
	for pass in 0 ..< (found ? 1 : 2) {
		for e, i in file_rows_entries(fb) {
			folder := e.kind == .Folder
			if !found && (pass == 0) != folder { continue }
			hidden := file_entry_hidden(e)
			if hidden && !fb.hidden { continue }
			tone := hidden ? Table_Tone.Dim : Table_Tone.Normal
			if !folder {
				// (Open: what no type of the dialog takes is not there; Save and Folder: faded, it says what is there)
				if filters != nil && !platform.filter_matches(filters, file_path_name(e.name, fb.sep)) {
					if fb.kind == .Open { continue }
					tone = .Dim
				}
				if fb.kind == .Folder { tone = .Dim }
			}
			id := file_row_id(e.name)
			fb.by_id[id] = len(fb.rows)
			table_data_row(&fb.data, id, e.name, tone, found || folder ? 0 : 1)
			table_data_cell(&fb.data, e.name)
			table_data_cell(&fb.data, !folder && e.size >= 0 ? timefmt.size(e.size) : "", folder ? -1 : f64(e.size))
			table_data_cell(&fb.data, e.modified > 0 ? timefmt.moment(f64(e.modified), now, offset, short = true) : "", f64(e.modified))
			table_data_cell(&fb.data, words[file_entry_look(e)])
			append(&fb.rows, i)
		}
	}
}

// The filters of the type chosen (nil: every file).
@(private)
file_browser_type_filters :: proc(fb: ^File_Browser) -> []platform.File_Filter {
	if fb.kind == .Folder || fb.type_index < 0 || fb.type_index >= len(fb.d.filters) { return nil }
	return fb.d.filters[fb.type_index:fb.type_index + 1]
}

// The entries the rows were made of: the folder's, or the find's (their names: paths relative to the folder). Either
// joins to the folder by file_path_join.
@(private)
file_rows_entries :: proc(fb: ^File_Browser) -> []File_Entry { return fb.made_for.found ? fb.found[:] : fb.entries[:] }

// The entry of data row `r`.
@(private)
file_row_entry :: proc(fb: ^File_Browser, r: int) -> ^File_Entry {
	list := file_rows_entries(fb)
	// (the entries may have changed since the rows were made: they are made again at the list's next build)
	if r < 0 || r >= len(fb.rows) || fb.rows[r] >= len(list) { return nil }
	return &list[fb.rows[r]]
}

// The entries chosen (indices of file_rows_entries): the rows marked (Open with `multiple`), else the selected one; in
// the entries' order.
@(private)
file_browser_chosen :: proc(fb: ^File_Browser, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	n := len(file_rows_entries(fb))
	vl := &fb.table.vl
	if vl.multi && list_mark_count(vl) > 0 {
		for id in vl.marks {
			if r, ok := fb.by_id[id]; ok && fb.rows[r] < n { append(&out, fb.rows[r]) }
		}
		slice.sort(out[:])
	} else if r := table_selected(&fb.table); r >= 0 && fb.rows[r] < n {
		append(&out, fb.rows[r])
	}
	return out[:]
}

// Whether the act's button does something now: Open, a file chosen; Folder, always (the folder selected, or the one
// shown); Save, a name.
@(private)
file_browser_can_act :: proc(fb: ^File_Browser) -> bool {
	switch fb.kind {
	case .Open:
		// (looked at again when the selection, the marks or the rows change: every file marked is a pass)
		vl := &fb.table.vl
		key := [3]u64{u64(vl.sel + 1), u64(list_mark_count(vl)), fb.table.ids_version}
		if key != fb.open_key {
			fb.open_key, fb.open_ok = key, false
			list := file_rows_entries(fb)
			for i in file_browser_chosen(fb) { if list[i].kind == .File { fb.open_ok = true; break } }
		}
		return fb.open_ok
	case .Folder: return fb.folder != ""
	case .Save:   return strings.trim_space(line_edit_string(&fb.name)) != "" && fb.folder != ""
	}
	return false
}

// The act's button, or Enter in the name field.
@(private)
file_browser_act :: proc(fb: ^File_Browser) {
	list := file_rows_entries(fb)
	switch fb.kind {
	case .Open:
		paths := make([dynamic]string, context.temp_allocator)
		for i in file_browser_chosen(fb) {
			if list[i].kind == .File { append(&paths, file_path_join(fb.folder, list[i].name, fb.sep)) }
		}
		if len(paths) > 0 { file_browser_finish(fb, .Chosen, paths[:]) }
	case .Folder:
		path := fb.folder
		if chosen := file_browser_chosen(fb); len(chosen) == 1 && list[chosen[0]].kind == .Folder {
			path = file_path_join(fb.folder, list[chosen[0]].name, fb.sep)
		}
		if path != "" {
			paths := [1]string{strings.clone(path, context.temp_allocator)}
			file_browser_finish(fb, .Chosen, paths[:])
		}
	case .Save:
		file_browser_save(fb)
	}
}

// Enter on a row, or a double click: a folder is entered; a file is chosen (Open), or named (Save; a double click
// saves under it too).
@(private)
file_browser_activate :: proc(fb: ^File_Browser, double: bool) {
	e := file_row_entry(fb, table_selected(&fb.table))
	if e == nil { return }
	if e.kind == .Folder {
		file_browser_go(fb, file_path_join(fb.folder, e.name, fb.sep))
		return
	}
	switch fb.kind {
	case .Open:   file_browser_act(fb)
	case .Save:
		line_edit_set(&fb.name, e.name)
		if double { file_browser_save(fb) }
	case .Folder:
	}
}

// Save: the name typed, in the folder shown (a name with a separator goes to that path), with the type's extension when
// it has none; over a file of the folder, asked first (`overwrite_prompt`). A name of a folder of this one enters it.
@(private)
file_browser_save :: proc(fb: ^File_Browser) {
	typed := strings.trim_space(line_edit_string(&fb.name))
	if typed == "" || fb.folder == "" { return }
	has_sep := strings.index_byte(typed, fb.sep) >= 0 || (fb.sep == '\\' && strings.index_byte(typed, '/') >= 0)
	if !has_sep {
		if i := file_entry_named(fb, typed); i >= 0 && fb.entries[i].kind == .Folder {
			file_browser_go(fb, file_path_join(fb.folder, typed, fb.sep))
			line_edit_set(&fb.name, file_path_name(fb.d.suggested_name, fb.sep))
			return
		}
	}
	path: string
	switch {
	case !has_sep:                           path = file_path_join(fb.folder, typed, fb.sep)
	case file_path_root(typed, fb.sep) > 0: path = file_path_clean(typed, fb.sep)
	case:                                    path = file_path_clean(file_path_join(fb.folder, typed, fb.sep), fb.sep)
	}
	path = file_browser_with_extension(fb, path)
	name := file_path_name(path, fb.sep)
	here := file_path_trim(file_path_parent(path, fb.sep), fb.sep) == file_path_trim(fb.folder, fb.sep)
	if fb.d.overwrite_prompt && here {
		if i := file_entry_named(fb, name); i >= 0 && fb.entries[i].kind == .File {
			a := runtime.heap_allocator()
			delete(fb.ask_path, a)
			fb.ask_path = strings.clone(path, a)
			fb.asking = true
			return
		}
	}
	paths := [1]string{path}
	file_browser_finish(fb, .Chosen, paths[:])
}

// `path` with the extension of the type chosen ("*.png": "png"), else the dialog's default_ext, when its name has none.
@(private)
file_browser_with_extension :: proc(fb: ^File_Browser, path: string) -> string {
	name := file_path_name(path, fb.sep)
	if strings.last_index_byte(name, '.') > 0 { return path }
	ext := ""
	if filters := file_browser_type_filters(fb); filters != nil {
		for p in filters[0].patterns {
			q := strings.trim_space(p)
			q = strings.trim_prefix(q, "*")
			q = strings.trim_prefix(q, ".")
			if q != "" && q != "*" && strings.index_any(q, "*?") < 0 { ext = q; break }
		}
	}
	if ext == "" { ext = strings.trim_prefix(fb.d.default_ext, ".") }
	if ext == "" { return path }
	return strings.concatenate({path, ".", ext}, context.temp_allocator)
}

// The path typed in the path field (Ctrl+L): its folder is read, then its last part is looked for there: a folder is
// entered, a file chosen (Open) or named (Save). A root, or a path that ends with a separator, is entered at once.
@(private)
file_browser_path_typed :: proc(fb: ^File_Browser, typed: string) {
	text := strings.trim_space(typed)
	if text == "" { return }
	if file_path_root(text, fb.sep) == 0 { text = file_path_join(fb.folder, text, fb.sep) }
	ends := text[len(text) - 1] == fb.sep || text[len(text) - 1] == '/'
	clean := file_path_clean(text, fb.sep)
	parent := file_path_parent(clean, fb.sep)
	name := file_path_name(clean, fb.sep)
	a := runtime.heap_allocator()
	fb.path_editing = false
	if ends || parent == clean || name == "" {
		file_browser_go(fb, clean)
		return
	}
	// (its folder first; the last part is looked for when the folder's entries come: set before the reading is asked,
	// a source may answer at once)
	delete(fb.pending, a)
	fb.pending, fb.pending_act = strings.clone(name, a), true
	file_browser_go(fb, strings.clone(parent, context.temp_allocator))
}

// Tab in the path field: the folder's names that begin with what is typed after its last separator, as far as they
// agree. A field whose folder is not the one shown reads that folder (the next Tab completes in it).
@(private)
file_browser_complete :: proc(fb: ^File_Browser) {
	text := line_edit_string(&fb.path_edit)
	cut := strings.last_index_byte(text, fb.sep)
	if fb.sep == '\\' { cut = max(cut, strings.last_index_byte(text, '/')) }
	if cut < 0 { return }
	dir := text[:cut + 1]
	part := text[cut + 1:]
	if file_path_trim(file_path_clean(dir, fb.sep), fb.sep) != file_path_trim(fb.folder, fb.sep) {
		file_browser_go(fb, file_path_clean(dir, fb.sep))
		return
	}
	common := ""
	found := false
	for e in fb.entries {
		if e.kind != .Folder || !strings.has_prefix(e.name, part) { continue }
		if !found { common, found = e.name, true; continue }
		n := 0
		for n < len(common) && n < len(e.name) && common[n] == e.name[n] { n += 1 }
		common = common[:n]
	}
	if !found || len(common) <= len(part) { return }
	full := strings.concatenate({dir, common}, context.temp_allocator)
	line_edit_set(&fb.path_edit, full)
}
