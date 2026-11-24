package ui

// The file picker (docs/file-browser.md, src/md/features/file-picker.md): open files, choose a folder, save under a
// name, reading the folders through a File_Source (file_source.odin). A program builds one in its own layout
// (file_picker_init, file_picker at each build, file_picker_destroy: the program owns it, several live at once), or asks
// ui.file_dialog for one in a dialog (file_dialog.odin: a picker the State keeps, shown as the view "file_dialog"). This
// file holds its state and what it does; file_picker_view.odin builds it, file_picker_preview.odin reads and shows the
// preview, file_picker_memory.odin keeps what each remember_id remembers, file_picker_row_menu.odin has the rows' menu
// (copy, open, rename, trash and its undo).
//
// Its machines, each a remote.Remote (an answer of a reading given up is dropped by its ticket; every answer of a picker
// stopped or destroyed by its id and its serial):
//   listing:  the folder shown (Idle -> Loading -> Ready | Refused | Failed; a missing folder goes up instead)
//   making:   a new folder (Loading -> Ready: the folder read again, the new one selected | Failed: said under its row)
//   preview:  the file selected (preview.reading)
//   finding:  a search in subfolders (File_Source.find): Idle while the query is quiet for less than FILE_FIND_QUIET_MS,
//             Loading -> Ready | Failed; reset when the query empties, the toggle goes off, the folder changes
//   bar_listing: the folder the path bar's dropdown wants (Loading -> Ready | Failed: told to the bar); the folder
//             shown is answered from its entries, with no reading
// and the picker's own: stopped -> open (file_picker_start) -> (asking: Save over a file, the confirm) -> answered (Chosen
// or Cancelled, given once by its next build) -> open again; file_picker_stop and file_picker_destroy end it with no answer.
// The rows show the folder's entries, or the find's (the toggle on and a query typed): File_Rows_Key.found says which.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:time"
import "../ascii"
import "../fsx"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import remote "../remote"
import timefmt "../timefmt"

// A folder that answers sooner than this shows no "Reading" line: a fast folder does not flash.
FILE_PICKER_SLOW_MS :: 300
// What the preview reads of a text file, and at most of a picture.
FILE_PREVIEW_BYTES :: 64 * 1024
FILE_PREVIEW_IMAGE_BYTES :: 32 * 1024 * 1024
// The recent folders a dialog keeps, per remember_id.
FILE_PICKER_RECENT :: 8
// What a build of the picker may take once its rows are made (tests/file_browser checks it with 100 000 entries).
FILE_PICKER_BUILD_BUDGET_MS :: 16
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
	found:      bool,   // of the find's entries (fp.found), not the folder's
}

// What the pickers of a State share (State.files, made at the first use): the computer's places, the memory of each
// remember_id, the pickers alive by id (a reply finds its own picker there: the answer of a destroyed one finds none),
// and ui.file_dialog's picker.
@(private)
File_Pickers :: struct {
	state:        ^State,
	live:         map[u64]^File_Picker,
	next_id:      u64,
	local:        File_Local,      // the computer's places (file_local.odin)
	memory:       File_Memories,   // file_picker_memory.odin
	trash_serial: u64,             // counts the trashes of every picker: a toast's undo finds its own
	dialog:       File_Dialog_Host,   // file_dialog.odin
}

// A file picker: the program's (file_picker_init), or ui.file_dialog's. Its fields are its own: read it through
// file_picker_folder, file_picker_selected, file_picker_counts. Its address must not change between file_picker_init
// and file_picker_destroy (the State finds it by its id).
File_Picker :: struct {
	state:        ^State,     // the State it answers in: its replies, its clock, its tasks
	id:           u64,        // in State.files.live (0: not set up, or its State destroyed)
	open:         bool,       // started (file_picker_start), not stopped
	instance:     string,     // its views' instance (the overwrite question), its menus' ids (heap)
	serial:       u64,        // counts its starts: a reply of an earlier one is dropped
	kind:         platform.File_Dialog_Kind,
	d:            platform.File_Dialog,   // the request's options (owned copies)
	source:       File_Source,
	sep:          u8,
	source_places: [dynamic]platform.File_Place,   // what the source knows (in places_arena)
	places_arena: virtual.Arena,
	dialog:       bool,       // ui.file_dialog's: it holds the keys of its window (as a dialog), else only with the focus in it
	focus_inside: bool,       // the focus was in it at the end of its last build (its keys are read)
	focus_held:   Key,        // ... the box it was in last (still the picker's when that box is gone)
	// its answer, given by its next build (file_picker_answer)
	answered:     bool,
	answer:       platform.Dialog_Result,   // (heap)
	// what changed since the last build said it (File_Picker_Events)
	moved:        bool,       // another folder
	seen_selection: [2]u64,   // (active row, selection's version) at the last build
	choice_values: [dynamic]int,   // per choice of d.choices: its option, or 0 and 1 for a check box

	// the folder
	folder:       string,     // shown (the path bar's); "" before the first one is known
	back:         [dynamic]string,
	forward:      [dynamic]string,
	listing:      remote.Remote,
	listing_ms:   f64,        // when its reading began (the "Reading" line comes after FILE_PICKER_SLOW_MS)
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
	rows_made:    int,        // the rows made, and filtered or sorted (file_picker_counts)
	rows_applied: int,
	select_name:  string,     // the row selected once the rows are made (a new folder, a path typed)
	open_key:     [3]u64,     // what Open's act was last looked at for (file_picker_can_act), and whether it can
	open_ok:      bool,

	// the controls
	filter:       Line_Edit,
	filter_key:   Key,
	name:         Line_Edit,  // Save: the file's name
	name_key:     Key,
	bar:          Path_Bar,   // the folder as a breadcrumb, or typed (Ctrl+L) with its dropdown
	bar_listing:  remote.Remote,   // the bar's reading of the folder it wants (not the folder shown's)
	bar_folder:   string,     // ... that folder
	hidden:       bool,
	type_index:   int,        // the type line chosen (len(d.filters): "All files")
	new_folder:   bool,       // the inline row of a new folder's name
	new_name:     Line_Edit,
	new_key:      Key,
	making:       remote.Remote,
	making_name:  string,
	asking:       bool,       // Save over a file of the folder: the confirm is open
	asked:        bool,       // ... its view opened (confirm_open once; its answer read at each build)
	ask_views:    ^Views,     // ... where (the State the picker was built in)
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
	find_ms:      f64,        // when the find was asked (the "Searching" line comes after FILE_PICKER_SLOW_MS)
	find_stop:    ^File_Find_Stop,   // stops the local walks (file_local.odin)
	sort_kept:    bool,       // the find's rows show as found: the folder's sort, back when they go
	kept_sort:    int,
	kept_descending: bool,

	// the rows' menu (file_picker_row_menu.odin)
	start:        string,     // the first folder this dialog showed: Copy relative path is relative to it
	renaming:     bool,       // a row's name is edited in place (Table.editing)
	rename_name:  string,     // ... the entry's name, as its row has it
	rename_edit:  Line_Edit,
	rename_key:   Key,        // ... its field (0: it takes the keyboard when it is built)
	rename_commit: bool,      // ... Enter in it: the source is asked after the build
	rename_call:  remote.Remote,
	rename_to:    string,     // the new name asked (selected in the folder read again)
	trash_call:   remote.Remote,
	restore_call: remote.Remote,
	undo:         [dynamic]File_Trashed,   // the last trash's items that can come back
	undo_serial:  u64,        // ... its toast's (0: none, or undone)
	undo_dialog:  u64,        // ... the dialog it was in
	shell:        Shell_Menu, // asynchronous system shell context-menu actions for local files
	shell_was_open: bool,

	preview:      File_Preview,
	// the cards' pictures (thumbnails.odin): kept from one request to the next, freed with the picker
	thumbs:       Thumb_Cache,
}

// The pickers of `s`, made at the first use.
@(private)
file_pickers_of :: proc(s: ^State) -> ^File_Pickers {
	if s.files != nil { return s.files }
	a := runtime.heap_allocator()
	h := new(File_Pickers, a)
	h.state = s
	h.live = make(map[u64]^File_Picker, a)
	s.files = h
	return h
}

// ui.destroy: the dialog is given up (its `done` not called), the memory written. A program's picker still alive stops
// here; file_picker_destroy then frees only its own memory.
@(private)
file_pickers_destroy :: proc(s: ^State) {
	h := s.files
	if h == nil { return }
	a := runtime.heap_allocator()
	context.allocator = a
	file_dialog_destroy(h)
	for _, fp in h.live {
		if fp.open { file_picker_stop(fp) }
		fp.id = 0
	}
	delete(h.live)
	file_memories_close(&h.memory)
	file_local_destroy(&h.local)
	free(h, a)
	s.files = nil
}

// Makes `fp` ready to start, in `s` (its replies, its clock, its tasks): what every start reuses.
@(private)
file_picker_setup :: proc(fp: ^File_Picker, s: ^State) {
	h := file_pickers_of(s)
	a := runtime.heap_allocator()
	fp^ = {}
	fp.state = s
	h.next_id += 1
	fp.id = h.next_id
	h.live[fp.id] = fp
	fp.instance = strings.clone(fmt.tprintf("%x_%x", uintptr(s), fp.id), a)
	fp.back = make([dynamic]string, a)
	fp.forward = make([dynamic]string, a)
	fp.entries = make([dynamic]File_Entry, a)
	fp.found = make([dynamic]File_Entry, a)
	fp.rows = make([dynamic]int, a)
	fp.by_id = make(map[u64]int, a)
	fp.source_places = make([dynamic]platform.File_Place, a)
	fp.undo = make([dynamic]File_Trashed, a)
	fp.choice_values = make([dynamic]int, a)
	// (in the order of FILE_COLUMN_NAME, _SIZE, _MODIFIED, _KIND)
	fp.columns = {
		{title = i18n.later("Name"), width = 0},
		{title = i18n.later("Size"), width = 6.5, number = true},
		{title = i18n.later("Modified"), width = 9, number = true, weak = true},
		// (the icon tells the kind already: the column is there for who asks, and leaves the name its room)
		{title = i18n.later("Kind"), width = 7, weak = true, hidden = true},
	}
	context.allocator = a
	table_init(&fp.table, fp.columns[:])
	fp.table.fuzzy = true
	fp.table.lead_em = 0.4
	fp.table.lead_user = fp
	fp.table.vl.no_typeahead = true   // (what is typed goes to the filter)
	// the views (view-modes.md): Ctrl+wheel and the zoom keys step them, a rectangle selects (several files), a card's
	// weak line is the size, its picture the file's thumbnail
	fp.table.zoom_keys = true
	fp.table.rubber_band = true
	fp.table.card_line = FILE_COLUMN_SIZE
	thumb_cache_init(&fp.thumbs)
}

// A picker of the program, in `s` (the State it is built in, or the owner of the window of its view), started with the
// request `kind` and `d` (copied) on `source` (nil: the computer's files). Build it with file_picker at each build;
// its answers come in its events. file_picker_start asks it something else; file_picker_destroy frees it.
file_picker_init :: proc(fp: ^File_Picker, s: ^State, kind: platform.File_Dialog_Kind, d: platform.File_Dialog, source: ^File_Source = nil) {
	file_picker_setup(fp, s)
	file_picker_start(fp, kind, d, source)
}

// Frees what `fp` holds. Its readings still on their way answer nothing. What it shows is remembered (its remember_id).
file_picker_destroy :: proc(fp: ^File_Picker) {
	if fp.state == nil { return }
	a := runtime.heap_allocator()
	context.allocator = a
	if fp.open {
		if fp.id != 0 { file_memory_remember(fp, "") }
		file_picker_stop(fp)
	}
	if fp.id != 0 && fp.state.files != nil { delete_key(&fp.state.files.live, fp.id) }
	table_destroy(&fp.table)
	table_data_destroy(&fp.data)
	delete(fp.back); delete(fp.forward); delete(fp.entries); delete(fp.found); delete(fp.rows); delete(fp.by_id)
	delete(fp.source_places)
	delete(fp.choice_values)
	file_trashed_clear(&fp.undo)
	delete(fp.undo)
	platform.dialog_result_destroy(&fp.answer, a)
	line_edit_destroy(&fp.rename_edit)
	remote.destroy(&fp.rename_call); remote.destroy(&fp.trash_call); remote.destroy(&fp.restore_call)
	virtual.arena_destroy(&fp.entries_arena)
	virtual.arena_destroy(&fp.found_arena)
	virtual.arena_destroy(&fp.places_arena)
	line_edit_destroy(&fp.filter); line_edit_destroy(&fp.name); line_edit_destroy(&fp.new_name)
	path_bar_destroy(&fp.bar)
	remote.destroy(&fp.listing); remote.destroy(&fp.making); remote.destroy(&fp.finding); remote.destroy(&fp.bar_listing)
	delete(fp.find_query, a); delete(fp.find_seen, a); delete(fp.bar_folder, a)
	// (a walk still on its way holds the stop: it stops, and the last of them frees it)
	file_find_stop(fp)
	file_find_stop_release(fp.find_stop)
	shell_menu_destroy(&fp.shell)
	file_preview_destroy(fp)
	thumb_cache_destroy(&fp.thumbs)
	delete(fp.instance, a)
	fp^ = {}
}

// The picker a reply is for: alive, and not started again since it asked (nil otherwise).
@(private)
file_picker_by_id :: proc(s: ^State, id, serial: u64) -> ^File_Picker {
	if s == nil || s.files == nil { return nil }
	fp := s.files.live[id] or_else nil
	if fp == nil || !fp.open || fp.serial != serial { return nil }
	return fp
}

// What a test reads of a picker: whether it is open, the folder shown, how many times its rows were made and
// filtered or sorted (a build that changed nothing does neither), the rows shown, the search in subfolders.
File_Picker_Counts :: struct {
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
	zoom:         int,   // the list's step (table_zoom_step)
	thumbs_asked: int,   // the thumbnails asked of the source
	thumbs_ready: int,   // ... and kept, Ready
}

// (nil: a picker never set up, all zero)
file_picker_counts :: proc(fp: ^File_Picker) -> File_Picker_Counts {
	if fp == nil || fp.state == nil { return {} }
	ready := 0
	for _, t in fp.thumbs.entries { if t.state == .Ready { ready += 1 } }   // (a test's question: not per frame)
	return {open = fp.open, folder = fp.folder, rows_made = fp.rows_made, rows_applied = fp.rows_applied,
		rows_shown = len(fp.table.rows), entries = len(fp.entries), list_layouts = fp.table.vl.offsets_made,
		deep = fp.deep, found = len(fp.found), found_shown = fp.made && fp.made_for.found,
		zoom = fp.table.zoom, thumbs_asked = fp.thumbs.sent, thumbs_ready = ready}
}

// The folder `fp` shows ("": none yet). Valid until it changes.
file_picker_folder :: proc(fp: ^File_Picker) -> string { return fp.folder }

// The paths of the entries selected in `fp` (the active one when it takes one), in the folder's order, in `allocator`.
file_picker_selected :: proc(fp: ^File_Picker, allocator := context.temp_allocator) -> []string {
	if !fp.open { return nil }
	list := file_rows_entries(fp)
	chosen := file_picker_chosen(fp)
	out := make([]string, len(chosen), allocator)
	for k, i in chosen { out[i] = fsx.path_join(fp.folder, list[k].name, fp.sep, allocator) }
	return out
}

// The keyboard to the list at the next build (Save: to the name), when no other box has it.
file_picker_focus :: proc(fp: ^File_Picker) { fp.focus_list = true }

////////////////////////////////
// Start and stop

// Asks `fp` the request `kind` and `d` (copied) on `source` (nil: the computer's files): what it asked before is
// given up with no answer.
file_picker_start :: proc(fp: ^File_Picker, kind: platform.File_Dialog_Kind, d: platform.File_Dialog, source: ^File_Source = nil) {
	s := fp.state
	a := runtime.heap_allocator()
	context.allocator = a
	if fp.open { file_picker_stop(fp) }
	fp.serial += 1
	fp.open = true
	fp.kind = kind
	fp.d = platform.file_dialog_clone(d, a)
	fp.source = source != nil ? source^ : local_files()
	fp.sep = fp.source.separator != 0 ? fp.source.separator : '/'
	// (cleared as the last dialog's list was: a multi one has its set to empty)
	list_selection_clear(&fp.table.vl)
	fp.table.vl.multi = kind == .Open && d.multiple
	fp.table.vl.sel = -1
	fp.type_index = clamp(d.filter_index, 0, max(len(d.filters) - (d.all_files ? 0 : 1), 0))
	fp.made = false
	fp.focus_list = true
	fp.listing_ms = clock_ms(s)
	line_edit_clear(&fp.filter)
	fp.deep = d.find_deep && fp.source.find != nil
	// (the suggested name selected without its extension: what is typed replaces the name, the type stays)
	line_edit_set(&fp.name, d.suggested_name)
	fp.name.mark = 0
	if dot := strings.last_index_byte(d.suggested_name, '.'); dot > 0 { fp.name.cursor = dot }
	// (its choices at their first values)
	clear(&fp.choice_values)
	for ch in fp.d.choices { append(&fp.choice_values, file_choice_first(ch)) }
	fp.answered = false
	platform.dialog_result_destroy(&fp.answer, a)
	// what this remember_id remembers: its size, its split, its sort, hidden files, the folder it was left in
	m := file_memory_of(&s.files.memory, d.remember_id)
	fp.size = m != nil ? m.size : Vec2{}
	fp.split = m != nil && m.split > 0 ? m.split : FILE_PREVIEW_DEFAULT_EM
	fp.hidden = m != nil && m.hidden
	table_layout_reset(&fp.table.layout)
	fp.table.sort, fp.table.descending = FILE_COLUMN_NAME, false
	if m != nil && m.sort_set { fp.table.sort, fp.table.descending = m.sort, m.descending }
	// (its view: a dialog for pictures opens on its cards again)
	fp.table.zoom = 0
	if m != nil { fp.table.zoom = m.zoom }
	fp.table.shown[FILE_COLUMN_SIZE] = .Size in fp.source.caps
	fp.table.shown[FILE_COLUMN_MODIFIED] = .Modified in fp.source.caps
	file_local_warm(s)   // (the computer's places)
	file_picker_places_refresh(fp)
	// (the order: the folder asked, the one this dialog was left in, the system's folder asked, the source's start)
	start := d.start_dir
	if start == "" && m != nil { start = m.folder }
	if start == "" { start = file_picker_known(fp) }
	if start == "" && fp.source.start != nil { start = fp.source.start(&fp.source, context.temp_allocator) }
	if start == "" && len(fp.source_places) > 0 { start = fp.source_places[0].path }
	// (the computer's folders are read on the chores: the dialog starts once they are known, file_picker_local_ready)
	if start != "" { file_picker_go(fp, start) }
}

// The first value of a choice: its `initial` option's index (0 when it names none), or 1 for a check box whose
// `initial` is "true".
@(private)
file_choice_first :: proc(ch: platform.File_Choice) -> int {
	if len(ch.options) == 0 { return ch.initial == "true" ? 1 : 0 }
	for o, i in ch.options { if o.id == ch.initial { return i } }
	return 0
}

// The computer's places came (file_local_warm): shown, and the dialog that waited for its first folder starts.
@(private)
file_picker_local_ready :: proc(fp: ^File_Picker) {
	if !fp.open { return }
	context.allocator = runtime.heap_allocator()
	file_picker_places_refresh(fp)
	if fp.folder != "" { return }
	start := file_picker_known(fp)
	if start == "" && fp.source.start != nil { start = fp.source.start(&fp.source, context.temp_allocator) }
	if start == "" && len(fp.source_places) > 0 { start = fp.source_places[0].path }
	if start == "" { start = string([]u8{fp.sep}) }
	file_picker_go(fp, start)
}

// The folder of the dialog's start_known, as its source knows it ("": None, a source with no such folders, a folder
// the person never made, or the computer's folders not read yet). Temporary memory.
@(private)
file_picker_known :: proc(fp: ^File_Picker) -> string {
	if fp.d.start_known == .None || fp.source.known == nil { return "" }
	return fp.source.known(&fp.source, fp.d.start_known, context.temp_allocator)
}

// The source's places, again (they may come later than the dialog: the computer's).
@(private)
file_picker_places_refresh :: proc(fp: ^File_Picker) {
	virtual.arena_free_all(&fp.places_arena)
	clear(&fp.source_places)
	if fp.source.places == nil { return }
	for p in fp.source.places(&fp.source, virtual.arena_allocator(&fp.places_arena)) { append(&fp.source_places, p) }
}

// Stops `fp` with no answer: everything of this request goes; what every request keeps (its thumbnails, the memory,
// the computer's places) stays.
file_picker_stop :: proc(fp: ^File_Picker) {
	if !fp.open { return }
	a := runtime.heap_allocator()
	context.allocator = a
	// (the question over it goes: no answer)
	if fp.asked && fp.ask_views != nil { view_close(fp.ask_views, FILE_REPLACE_VIEW, fp.instance) }
	file_picker_rename_end(fp)
	fp.open, fp.asking, fp.asked = false, false, false
	fp.ask_views = nil
	fp.serial += 1   // (a reply still on its way is of no request now)
	fp.answered = false
	platform.dialog_result_destroy(&fp.answer, a)
	clear(&fp.choice_values)
	platform.file_dialog_free(&fp.d, a)
	delete(fp.start, a); fp.start = ""
	// (a trash's undo is its dialog's: the next one may read another source)
	file_trashed_clear(&fp.undo)
	fp.undo_serial = 0
	remote.reset(&fp.trash_call)
	remote.reset(&fp.restore_call)
	file_picker_find_drop(fp)
	delete(fp.find_seen, a); fp.find_seen = ""
	file_strings_clear(&fp.back)
	file_strings_clear(&fp.forward)
	delete(fp.folder, a); fp.folder = ""
	delete(fp.pending, a); fp.pending = ""
	delete(fp.select_name, a); fp.select_name = ""
	delete(fp.applied_query, a); fp.applied_query = ""
	delete(fp.making_name, a); fp.making_name = ""
	delete(fp.ask_path, a); fp.ask_path = ""
	remote.reset(&fp.listing)
	remote.reset(&fp.making)
	remote.reset(&fp.bar_listing)
	delete(fp.bar_folder, a); fp.bar_folder = ""
	path_bar_destroy(&fp.bar)   // (the breadcrumb at the next dialog; zero is a bar at rest)
	file_entries_clear(fp)
	file_picker_sort_back(fp)
	table_data_reset(&fp.data, len(fp.columns))
	clear(&fp.rows)
	clear(&fp.by_id)
	table_apply(&fp.table, &fp.data, "")
	fp.table.highlight = fp.table.query
	fp.made = false
	fp.new_folder = false
	shell_menu_clear(&fp.shell)
	fp.shell_was_open = false
	file_preview_clear(fp)
	virtual.arena_free_all(&fp.places_arena)
	clear(&fp.source_places)
}

// The picker's answer (Chosen with `paths`, or Cancelled), given by its next build (File_Picker_Events), or at once to
// its dialog. A later answer before that build replaces it. What the picker is now is remembered (its remember_id).
@(private)
file_picker_answer :: proc(fp: ^File_Picker, status: platform.Dialog_Status, paths: []string = nil) {
	if !fp.open { return }
	a := runtime.heap_allocator()
	platform.dialog_result_destroy(&fp.answer, a)
	r := platform.Dialog_Result{status = status, filter = fp.type_index}
	if len(paths) > 0 {
		r.paths = make([]string, len(paths), a)
		for p, i in paths { r.paths[i] = strings.clone(p, a) }
	}
	if len(fp.d.choices) > 0 {
		r.choices = make([]platform.File_Choice_Answer, len(fp.d.choices), a)
		for ch, i in fp.d.choices {
			v := i < len(fp.choice_values) ? fp.choice_values[i] : 0
			value := len(ch.options) == 0 ? (v == 1 ? "true" : "false") : (v < len(ch.options) ? ch.options[v].id : "")
			r.choices[i] = {id = strings.clone(ch.id, a), value = strings.clone(value, a)}
		}
	}
	fp.answer, fp.answered = r, true
	file_picker_sort_back(fp)   // (the folder's sort is the one remembered, not the find's order)
	file_memory_remember(fp, status == .Chosen ? (fp.kind == .Folder && len(paths) > 0 ? paths[0] : fp.folder) : "")
	if fp.dialog { file_dialog_answered(fp) }
}

@(private)
file_strings_clear :: proc(list: ^[dynamic]string) {
	for x in list { delete(x, runtime.heap_allocator()) }
	clear(list)
}

@(private)
file_entries_clear :: proc(fp: ^File_Picker) {
	virtual.arena_free_all(&fp.entries_arena)
	clear(&fp.entries)
	fp.entries_version += 1
}

////////////////////////////////
// Readings

// Shows `path` and reads it. A folder other than the one shown starts empty (its entries are not those of the last: a
// press on them would act on the wrong folder); the same one keeps its entries until the new ones come.
@(private)
file_picker_go :: proc(fp: ^File_Picker, path: string, move := File_Move.New) {
	a := runtime.heap_allocator()
	target := strings.clone(path, context.temp_allocator)   // (`path` may be a slice of what changes below)
	if fp.start == "" { fp.start = strings.clone(target, a) }
	if target != fp.folder {
		fp.moved = true   // (said by the next build's events)
		file_picker_rename_end(fp)   // (its row is of the folder left)
		switch move {
		case .New:
			if fp.folder != "" { append(&fp.back, strings.clone(fp.folder, a)) }
			file_strings_clear(&fp.forward)
		case .Back:    if fp.folder != "" { append(&fp.forward, strings.clone(fp.folder, a)) }
		case .Forward: if fp.folder != "" { append(&fp.back, strings.clone(fp.folder, a)) }
		case .Again, .Replace:
		}
		delete(fp.folder, a)
		fp.folder = strings.clone(target, a)
		delete(fp.select_name, a)
		fp.select_name = ""
		file_entries_clear(fp)
		file_picker_find_drop(fp)   // (what was found is under the folder left)
		line_edit_clear(&fp.filter)
		fp.new_folder = false
		list_selection_clear(&fp.table.vl)
		fp.table.vl.sel = -1
		vlist_scroll_to(&fp.table.vl, 0)
	}
	ticket := remote.begin(&fp.listing)
	fp.listing_ms = clock_ms(fp.state)
	reply := File_Reply{state = fp.state, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .List}
	if fp.source.list == nil {
		remote.answer(&fp.listing, ticket, .Failed, i18n.tr("This source lists no folder."))
		return
	}
	fp.source.list(&fp.source, strings.clone(fp.folder, context.temp_allocator), reply)
}

@(private)
file_picker_up :: proc(fp: ^File_Picker) {
	up := file_path_parent(fp.folder, fp.sep)
	if up != "" && up != fp.folder {
		// (the folder left is selected in its parent: the way back down is under the keyboard)
		name := file_path_name(fp.folder, fp.sep)
		select := strings.clone(name, context.temp_allocator)
		file_picker_go(fp, up)
		file_picker_select_later(fp, select)
	}
}

// Alt+Home: the source's start (the computer's: the home folder), as KDE's and GNOME's file managers go home.
@(private)
file_picker_home :: proc(fp: ^File_Picker) {
	home := fp.source.start != nil ? fp.source.start(&fp.source, context.temp_allocator) : ""
	if home == "" && len(fp.source_places) > 0 { home = fp.source_places[0].path }
	if home != "" { file_picker_go(fp, home) }
}

@(private)
file_picker_back :: proc(fp: ^File_Picker) {
	if len(fp.back) == 0 { return }
	p := pop(&fp.back)
	defer delete(p, runtime.heap_allocator())
	file_picker_go(fp, p, .Back)
}

@(private)
file_picker_forward :: proc(fp: ^File_Picker) {
	if len(fp.forward) == 0 { return }
	p := pop(&fp.forward)
	defer delete(p, runtime.heap_allocator())
	file_picker_go(fp, p, .Forward)
}

@(private)
file_picker_select_later :: proc(fp: ^File_Picker, name: string) {
	a := runtime.heap_allocator()
	delete(fp.select_name, a)
	fp.select_name = strings.clone(name, a)
}

// The index of the entry `name`, -1 when the folder has none.
@(private)
file_entry_named :: proc(fp: ^File_Picker, name: string) -> int {
	for e, i in fp.entries { if e.name == name { return i } }
	return -1
}

@(private)
file_picker_listed :: proc(fp: ^File_Picker, ticket: u64, entries: []File_Entry) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fp.listing, ticket, .Ready) { return }
	virtual.arena_free_all(&fp.entries_arena)
	clear(&fp.entries)
	ea := virtual.arena_allocator(&fp.entries_arena)
	reserve(&fp.entries, len(entries))
	for e in entries {
		c := e
		c.name = strings.clone(e.name, ea)
		append(&fp.entries, c)
	}
	fp.entries_version += 1
	if fp.pending == "" { return }
	name := strings.clone(fp.pending, context.temp_allocator)
	act := fp.pending_act
	delete(fp.pending, runtime.heap_allocator())
	fp.pending, fp.pending_act = "", false
	i := file_entry_named(fp, name)
	if i < 0 {
		if act && fp.kind == .Save { line_edit_set(&fp.name, name) }   // (a new file's name, in this folder)
		return
	}
	if act && fp.entries[i].kind == .Folder {
		file_picker_go(fp, fsx.path_join(fp.folder, name, fp.sep))
		return
	}
	if act && fp.kind == .Open {
		paths := [1]string{fsx.path_join(fp.folder, name, fp.sep)}
		file_picker_answer(fp, .Chosen, paths[:])
		return
	}
	if act && fp.kind == .Save { line_edit_set(&fp.name, name) }
	file_picker_select_later(fp, name)
}

@(private)
file_picker_failed :: proc(fp: ^File_Picker, kind: File_Reply_Kind, ticket: u64, message: string, refused, missing: bool) {
	context.allocator = runtime.heap_allocator()
	switch kind {
	case .List:
		if !remote.current(&fp.listing, ticket) { return }
		delete(fp.pending, runtime.heap_allocator())   // (what was to be found in it is not)
		fp.pending, fp.pending_act = "", false
		if missing {
			// (deleted since it was remembered or shown: its nearest parent that is there)
			up := file_path_parent(fp.folder, fp.sep)
			if up != "" && up != fp.folder {
				file_picker_go(fp, up, .Replace)
				return
			}
		}
		_ = remote.answer(&fp.listing, ticket, refused ? .Refused : .Failed, message)
		file_entries_clear(fp)
	case .Make:
		_ = remote.answer(&fp.making, ticket, refused ? .Refused : .Failed, message)
	case .Read:
		file_preview_failed(fp, ticket, message)
	case .Find:
		_ = remote.answer(&fp.finding, ticket, refused ? .Refused : .Failed, message)
	case .Rename, .Trash, .Restore:
		file_picker_row_failed(fp, kind, ticket, message, refused)
	case .Thumbnail:   // (file_reply_failed gives it to the thumbnails)
	}
}

////////////////////////////////
// Search in subfolders

// Whether the rows are the find's: the toggle on, a source that finds, a query typed.
@(private)
file_picker_finds :: proc(fp: ^File_Picker) -> bool {
	return fp.deep && fp.source.find != nil && line_edit_string(&fp.filter) != ""
}

// At each build, before the list: the query wanted (empty with the toggle off) is compared with the last one (a string,
// not the entries); a new one is asked once it stayed the same FILE_FIND_QUIET_MS, by the State's clock. Nothing is
// asked again while it stays the same: no request per frame.
@(private)
file_picker_find_follow :: proc(fp: ^File_Picker) {
	s := fp.state
	a := runtime.heap_allocator()
	want := file_picker_finds(fp) ? line_edit_string(&fp.filter) : ""
	now := clock_ms(s)
	if want != fp.find_seen {
		delete(fp.find_seen, a)
		fp.find_seen = strings.clone(want, a)
		fp.find_typed_ms = now
		if want == "" { file_picker_find_drop(fp) }
	}
	// (the computer's first folder not known yet: asked once it is)
	if want == "" || fp.folder == "" || (want == fp.find_query && fp.hidden == fp.find_hidden) { return }
	if waited := now - fp.find_typed_ms; waited < FILE_FIND_QUIET_MS {
		wake_within(s, int(FILE_FIND_QUIET_MS - waited) + WAKE_MARGIN_MS)
		return
	}
	delete(fp.find_query, a)
	fp.find_query = strings.clone(want, a)
	fp.find_hidden = fp.hidden
	fp.find_ms = now
	context.allocator = a
	ticket := remote.begin(&fp.finding)
	reply := File_Reply{state = s, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .Find, hidden = fp.hidden}
	fp.source.find(&fp.source, strings.clone(fp.folder, context.temp_allocator), strings.clone(want, context.temp_allocator), FILE_FIND_LIMIT, reply)
}

// No find wanted any more (the query emptied, the toggle off, another folder, the dialog closed): the walk on its way
// stops, its answer is dropped, what was found goes.
@(private)
file_picker_find_drop :: proc(fp: ^File_Picker) {
	file_find_stop(fp)
	context.allocator = runtime.heap_allocator()
	remote.reset(&fp.finding)
	delete(fp.find_query, runtime.heap_allocator())
	fp.find_query, fp.find_hidden = "", false
	if len(fp.found) > 0 {
		virtual.arena_free_all(&fp.found_arena)
		clear(&fp.found)
		fp.found_version += 1
	}
}

@(private)
file_picker_found :: proc(fp: ^File_Picker, ticket: u64, entries: []File_Entry) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fp.finding, ticket, .Ready) { return }
	virtual.arena_free_all(&fp.found_arena)
	clear(&fp.found)
	ea := virtual.arena_allocator(&fp.found_arena)
	reserve(&fp.found, len(entries))
	for e in entries {
		c := e
		c.name = strings.clone(e.name, ea)
		append(&fp.found, c)
	}
	fp.found_version += 1
}

// The folder's sort back, when the find's rows had set it aside.
@(private)
file_picker_sort_back :: proc(fp: ^File_Picker) {
	if !fp.sort_kept { return }
	fp.table.sort, fp.table.descending = fp.kept_sort, fp.kept_descending
	fp.sort_kept = false
}

////////////////////////////////
// New folder

@(private)
file_picker_new_folder :: proc(fp: ^File_Picker) {
	if .Make_Folder not_in fp.source.caps || fp.source.make_folder == nil || fp.folder == "" { return }
	fp.new_folder = true
	remote.reset(&fp.making)
	line_edit_set(&fp.new_name, i18n.tr("New folder"))
	line_edit_select_all(&fp.new_name)
	fp.new_key = 0   // (the field takes the keyboard when it is built)
}

@(private)
file_picker_make :: proc(fp: ^File_Picker) {
	name := strings.trim_space(line_edit_string(&fp.new_name))
	if name == "" { return }
	if strings.index_byte(name, fp.sep) >= 0 || strings.index_byte(name, '/') >= 0 {
		remote.settle(&fp.making, .Failed, i18n.tr("A folder's name has no separator in it."))
		return
	}
	a := runtime.heap_allocator()
	delete(fp.making_name, a)
	fp.making_name = strings.clone(name, a)
	ticket := remote.begin(&fp.making)
	fp.source.make_folder(&fp.source, fsx.path_join(fp.folder, name, fp.sep), {state = fp.state, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .Make})
}

@(private)
file_picker_made :: proc(fp: ^File_Picker, ticket: u64) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fp.making, ticket, .Ready) { return }
	fp.new_folder = false
	name := strings.clone(fp.making_name, context.temp_allocator)
	file_picker_go(fp, fp.folder, .Again)
	file_picker_select_later(fp, name)
}

////////////////////////////////
// The rows

// The rows of the list, made again when the entries, Hidden files or the type changed, and filtered and sorted again
// when the filter or the sort changed: a build that changed none of them does no work in proportion to the entries.
@(private)
file_picker_rows :: proc(fp: ^File_Picker, sorted: bool) {
	found := file_picker_finds(fp)
	key := File_Rows_Key{entries = found ? fp.found_version : fp.entries_version, hidden = fp.hidden, type_index = fp.type_index, found = found}
	remade := false
	if !fp.made || key != fp.made_for {
		// (the find's rows in the order found, best first: the folder's sort set aside until they go, unless the person
		// clicks a column)
		if found && !fp.sort_kept {
			fp.kept_sort, fp.kept_descending, fp.sort_kept = fp.table.sort, fp.table.descending, true
			fp.table.sort, fp.table.descending = TABLE_UNSORTED, false
		} else if !found {
			file_picker_sort_back(fp)
		}
		fp.made_for = key   // (before the rows: file_rows_entries reads which entries they are of)
		file_picker_rows_make(fp)
		fp.made, remade = true, true
		fp.rows_made += 1
		if found { vlist_scroll_to(&fp.table.vl, 0) }
		// (the row a rename edits may be gone; one on its way ends with its answer)
		if fp.renaming && fp.rename_call.state != .Loading { file_picker_rename_end(fp) }
	}
	q := line_edit_string(&fp.filter)
	if remade || sorted || q != fp.applied_query {
		a := runtime.heap_allocator()
		delete(fp.applied_query, a)
		fp.applied_query = strings.clone(q, a)
		// (the find filtered and ranked them already: the table filters nothing more, and lights the query's letters)
		table_apply(&fp.table, &fp.data, found ? "" : q)
		fp.table.highlight = found ? fp.applied_query : fp.table.query
		if found && fp.table.vl.sel < 0 && len(fp.table.ids) > 0 { list_select(&fp.table.vl, 0) }
		fp.rows_applied += 1
	}
	// (looked for once the folder's rows are there, not at every build: a pass over them)
	if fp.select_name != "" && remade && fp.listing.state == .Ready {
		_ = table_select_id(&fp.table, file_row_id(fp.select_name))
		delete(fp.select_name, runtime.heap_allocator())
		fp.select_name = ""
	}
}

// A row's identity: its name's (a name is one in its folder), so that the selection stays on it through a filter, a
// sort and a reading again.
@(private)
file_row_id :: proc(name: string) -> u64 { return hash_bytes(transmute([]u8)name) }

@(private)
file_picker_rows_make :: proc(fp: ^File_Picker) {
	table_data_reset(&fp.data, len(fp.columns))
	clear(&fp.rows)
	clear(&fp.by_id)
	now := f64(time.to_unix_nanoseconds(time.now()) / 1_000_000)
	offset := timefmt.local_offset_minutes()
	filters := file_picker_type_filters(fp)
	words := [File_Look]string{
		.Folder = i18n.tr("Folder"), .File = i18n.tr("File"), .Image = i18n.tr("Image"), .Code = i18n.tr("Code"),
		.Archive = i18n.tr("Archive"), .Text = i18n.tr("Text"), .Link = i18n.tr("Link"),
	}
	found := fp.made_for.found
	// (the folder's: folders first, in the data too, so the rows unsorted keep them first; the find's: one pass, in the
	// order found, a folder and a file in one group)
	for pass in 0 ..< (found ? 1 : 2) {
		for e, i in file_rows_entries(fp) {
			folder := e.kind == .Folder
			if !found && (pass == 0) != folder { continue }
			hidden := file_entry_hidden(e)
			if hidden && !fp.hidden { continue }
			tone := hidden ? Table_Tone.Dim : Table_Tone.Normal
			if !folder {
				// (Open: what no type of the dialog takes is not there; Save and Folder: faded, it says what is there)
				if filters != nil && !platform.filter_matches(filters, file_path_name(e.name, fp.sep)) {
					if fp.kind == .Open { continue }
					tone = .Dim
				}
				if fp.kind == .Folder { tone = .Dim }
			}
			id := file_row_id(e.name)
			fp.by_id[id] = len(fp.rows)
			table_data_row(&fp.data, id, e.name, tone, found || folder ? 0 : 1)
			table_data_cell(&fp.data, e.name)
			table_data_cell(&fp.data, !folder && e.size >= 0 ? timefmt.size(e.size) : "", folder ? -1 : f64(e.size))
			table_data_cell(&fp.data, e.modified > 0 ? timefmt.moment(f64(e.modified), now, offset, short = true) : "", f64(e.modified))
			table_data_cell(&fp.data, words[file_entry_look(e)])
			append(&fp.rows, i)
		}
	}
}

// The filters of the type chosen (nil: every file).
@(private)
file_picker_type_filters :: proc(fp: ^File_Picker) -> []platform.File_Filter {
	if fp.kind == .Folder || fp.type_index < 0 || fp.type_index >= len(fp.d.filters) { return nil }
	return fp.d.filters[fp.type_index:fp.type_index + 1]
}

// The entries the rows were made of: the folder's, or the find's (their names: paths relative to the folder). Either
// joins to the folder by fsx.path_join.
@(private)
file_rows_entries :: proc(fp: ^File_Picker) -> []File_Entry { return fp.made_for.found ? fp.found[:] : fp.entries[:] }

// The entry of data row `r`.
@(private)
file_row_entry :: proc(fp: ^File_Picker, r: int) -> ^File_Entry {
	list := file_rows_entries(fp)
	// (the entries may have changed since the rows were made: they are made again at the list's next build)
	if r < 0 || r >= len(fp.rows) || fp.rows[r] >= len(list) { return nil }
	return &list[fp.rows[r]]
}

// The entries chosen (indices of file_rows_entries): the rows selected (Open with `multiple`), else the active one; in
// the entries' order.
@(private)
file_picker_chosen :: proc(fp: ^File_Picker, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	n := len(file_rows_entries(fp))
	vl := &fp.table.vl
	if vl.multi {
		for id in vl.selected {
			if r, ok := fp.by_id[id]; ok && fp.rows[r] < n { append(&out, fp.rows[r]) }
		}
		slice.sort(out[:])
	} else if r := table_selected(&fp.table); r >= 0 && fp.rows[r] < n {
		append(&out, fp.rows[r])
	}
	return out[:]
}

// Whether the act's button does something now: Open, a file chosen; Folder, always (the folder selected, or the one
// shown); Save, a name.
@(private)
file_picker_can_act :: proc(fp: ^File_Picker) -> bool {
	switch fp.kind {
	case .Open:
		// (looked at again when the active row, the selection or the rows change: every file selected is a pass)
		vl := &fp.table.vl
		key := [3]u64{u64(vl.sel + 1), vl.version, fp.table.ids_version}
		if key != fp.open_key {
			fp.open_key, fp.open_ok = key, false
			list := file_rows_entries(fp)
			for i in file_picker_chosen(fp) { if list[i].kind == .File { fp.open_ok = true; break } }
		}
		return fp.open_ok
	case .Folder: return fp.folder != ""
	case .Save:   return strings.trim_space(line_edit_string(&fp.name)) != "" && fp.folder != ""
	}
	return false
}

// The act's button, or Enter in the name field.
@(private)
file_picker_act :: proc(fp: ^File_Picker) {
	list := file_rows_entries(fp)
	switch fp.kind {
	case .Open:
		paths := make([dynamic]string, context.temp_allocator)
		for i in file_picker_chosen(fp) {
			if list[i].kind == .File { append(&paths, fsx.path_join(fp.folder, list[i].name, fp.sep)) }
		}
		if len(paths) > 0 { file_picker_answer(fp, .Chosen, paths[:]) }
	case .Folder:
		path := fp.folder
		if chosen := file_picker_chosen(fp); len(chosen) == 1 && list[chosen[0]].kind == .Folder {
			path = fsx.path_join(fp.folder, list[chosen[0]].name, fp.sep)
		}
		if path != "" {
			paths := [1]string{strings.clone(path, context.temp_allocator)}
			file_picker_answer(fp, .Chosen, paths[:])
		}
	case .Save:
		file_picker_save(fp)
	}
}

// Enter on a row, or a double click: a folder is entered; a file is chosen (Open), or named (Save; a double click
// saves under it too).
@(private)
file_picker_activate :: proc(fp: ^File_Picker, double: bool) {
	e := file_row_entry(fp, table_selected(&fp.table))
	if e == nil { return }
	if e.kind == .Folder {
		file_picker_go(fp, fsx.path_join(fp.folder, e.name, fp.sep))
		return
	}
	switch fp.kind {
	case .Open:   file_picker_act(fp)
	case .Save:
		line_edit_set(&fp.name, e.name)
		if double { file_picker_save(fp) }
	case .Folder:
	}
}

// Save: the name typed, in the folder shown (a name with a separator goes to that path), with the type's extension when
// it has none; over a file of the folder, asked first (`overwrite_prompt`). A name of a folder of this one enters it.
@(private)
file_picker_save :: proc(fp: ^File_Picker) {
	typed := strings.trim_space(line_edit_string(&fp.name))
	if typed == "" || fp.folder == "" { return }
	has_sep := strings.index_byte(typed, fp.sep) >= 0 || (fp.sep == '\\' && strings.index_byte(typed, '/') >= 0)
	if !has_sep {
		if i := file_entry_named(fp, typed); i >= 0 && fp.entries[i].kind == .Folder {
			file_picker_go(fp, fsx.path_join(fp.folder, typed, fp.sep))
			line_edit_set(&fp.name, file_path_name(fp.d.suggested_name, fp.sep))
			return
		}
	}
	path: string
	switch {
	case !has_sep:                           path = fsx.path_join(fp.folder, typed, fp.sep)
	case file_path_root(typed, fp.sep) > 0: path = file_path_clean(typed, fp.sep)
	case:                                    path = file_path_clean(fsx.path_join(fp.folder, typed, fp.sep), fp.sep)
	}
	path = file_picker_with_extension(fp, path)
	name := file_path_name(path, fp.sep)
	here := file_path_trim(file_path_parent(path, fp.sep), fp.sep) == file_path_trim(fp.folder, fp.sep)
	if fp.d.overwrite_prompt && here {
		if i := file_entry_named(fp, name); i >= 0 && fp.entries[i].kind == .File {
			a := runtime.heap_allocator()
			delete(fp.ask_path, a)
			fp.ask_path = strings.clone(path, a)
			fp.asking = true
			return
		}
	}
	paths := [1]string{path}
	file_picker_answer(fp, .Chosen, paths[:])
}

// `path` with the extension of the type chosen ("*.png": "png"), else the dialog's default_ext, when its name has none.
@(private)
file_picker_with_extension :: proc(fp: ^File_Picker, path: string) -> string {
	name := file_path_name(path, fp.sep)
	if strings.last_index_byte(name, '.') > 0 { return path }
	ext := file_picker_type_extension(fp)
	if ext == "" { ext = strings.trim_prefix(fp.d.default_ext, ".") }
	if ext == "" { return path }
	return strings.concatenate({path, ".", ext}, context.temp_allocator)
}

// The extension of the type chosen: its first pattern that names one ("*.png": "png"); "": none (All files, "*").
@(private)
file_picker_type_extension :: proc(fp: ^File_Picker) -> string {
	filters := file_picker_type_filters(fp)
	if filters == nil { return "" }
	for p in filters[0].patterns {
		q := strings.trim_space(p)
		q = strings.trim_prefix(q, "*")
		q = strings.trim_prefix(q, ".")
		if q != "" && q != "*" && strings.index_any(q, "*?") < 0 { return q }
	}
	return ""
}

// Save: another type chosen changes the extension of the name typed to the type's (GTK's and Windows' rule): "report.txt"
// becomes "report.md". A name without an extension, or a type without one, stays.
@(private)
file_picker_type_changed :: proc(fp: ^File_Picker) {
	if fp.kind != .Save { return }
	ext := file_picker_type_extension(fp)
	name := line_edit_string(&fp.name)
	dot := strings.last_index_byte(name, '.')
	if ext == "" || dot <= 0 { return }
	stem := strings.clone(name[:dot], context.temp_allocator)
	line_edit_set(&fp.name, strings.concatenate({stem, ".", ext}, context.temp_allocator))
	// (the stem selected, as at the start: what is typed replaces the name, the type stays)
	fp.name.mark = 0
	fp.name.cursor = len(stem)
}

// A path the path bar goes to (typed, or a row of its dropdown): its folder is read, then its last part is looked for
// there: a folder is entered, a file chosen (Open) or named (Save). A root, or a path that ends with a separator, is
// entered at once.
@(private)
file_picker_path_typed :: proc(fp: ^File_Picker, typed: string) {
	text := strings.trim_space(typed)
	if text == "" { return }
	if file_path_root(text, fp.sep) == 0 { text = fsx.path_join(fp.folder, text, fp.sep) }
	ends := text[len(text) - 1] == fp.sep || text[len(text) - 1] == '/'
	clean := file_path_clean(text, fp.sep)
	parent := file_path_parent(clean, fp.sep)
	name := file_path_name(clean, fp.sep)
	a := runtime.heap_allocator()
	if ends || parent == clean || name == "" {
		file_picker_go(fp, clean)
		return
	}
	// (its folder first; the last part is looked for when the folder's entries come: set before the reading is asked,
	// a source may answer at once)
	delete(fp.pending, a)
	fp.pending, fp.pending_act = strings.clone(name, a), true
	file_picker_go(fp, strings.clone(parent, context.temp_allocator))
}

////////////////////////////////
// The path bar's dropdown

// The bar wants the children of `folder`: the folder shown is answered from its entries; another is read (its own
// reading: the list keeps the folder shown).
@(private)
file_picker_bar_wants :: proc(fp: ^File_Picker, folder: string) {
	a := runtime.heap_allocator()
	if file_path_trim(folder, fp.sep) == file_path_trim(fp.folder, fp.sep) && fp.listing.state == .Ready {
		remote.reset(&fp.bar_listing)
		path_bar_children(&fp.bar, folder, file_picker_bar_children(fp, fp.entries[:]))
		return
	}
	if fp.source.list == nil {
		path_bar_failed(&fp.bar, folder, i18n.tr("This source lists no folder."))
		return
	}
	delete(fp.bar_folder, a)
	fp.bar_folder = strings.clone(folder, a)
	context.allocator = a
	ticket := remote.begin(&fp.bar_listing)
	fp.source.list(&fp.source, strings.clone(folder, context.temp_allocator), {state = fp.state, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .List, bar = true})
}

@(private)
file_picker_bar_listed :: proc(fp: ^File_Picker, ticket: u64, entries: []File_Entry) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fp.bar_listing, ticket, .Ready) { return }
	path_bar_children(&fp.bar, fp.bar_folder, file_picker_bar_children(fp, entries))
}

@(private)
file_picker_bar_failed :: proc(fp: ^File_Picker, ticket: u64, message: string) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fp.bar_listing, ticket, .Failed, message) { return }
	path_bar_failed(&fp.bar, fp.bar_folder, message)
}

// A folder's entries as the bar lists them: its folders, then its files where a file's path can be chosen (Open: of the
// type chosen; Save), each by name; the hidden ones only with Hidden files. (Temporary memory; once per answer.)
@(private = "file")
file_picker_bar_children :: proc(fp: ^File_Picker, entries: []File_Entry) -> []Path_Bar_Entry {
	out := make([dynamic]Path_Bar_Entry, 0, len(entries), context.temp_allocator)
	filters := file_picker_type_filters(fp)
	for e in entries {
		if file_entry_hidden(e) && !fp.hidden { continue }
		folder := e.kind == .Folder
		if !folder {
			if fp.kind == .Folder { continue }
			if fp.kind == .Open && filters != nil && !platform.filter_matches(filters, e.name) { continue }
		}
		append(&out, Path_Bar_Entry{name = e.name, icon = folder ? "" : file_look_icon(file_entry_look(e)), branch = folder})
	}
	slice.sort_by(out[:], proc(a, b: Path_Bar_Entry) -> bool {
		if a.branch != b.branch { return a.branch }
		return ascii.compare_fold(a.name, b.name) < 0
	})
	return out[:]
}

// The bar's suggestions: the places (the source's and the program's) and this dialog's recent folders, each a path.
@(private)
file_picker_bar_suggest :: proc(fp: ^File_Picker) {
	places := make([dynamic]Path_Bar_Entry, context.temp_allocator)
	for list in ([2][]platform.File_Place{fp.source_places[:], fp.d.places}) {
		for p in list {
			append(&places, Path_Bar_Entry{name = p.name != "" ? p.name : file_path_name(p.path, fp.sep), icon = p.icon, detail = p.name, path = p.path, branch = true})
		}
	}
	recent := make([dynamic]Path_Bar_Entry, context.temp_allocator)
	if m := file_memory_of(&fp.state.files.memory, fp.d.remember_id); m != nil {
		for r in m.recent { append(&recent, Path_Bar_Entry{name = file_path_name(r, fp.sep), icon = lucide.HISTORY, path = r, branch = true}) }
	}
	groups := [2]Path_Bar_Group{{title = i18n.tr("Places"), entries = places[:]}, {title = i18n.tr("Recent"), entries = recent[:]}}
	path_bar_suggestions(&fp.bar, groups[:])
}
