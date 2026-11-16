package ui

// The font picker (docs/font-picker.md; its reasons: src/md/features/font-picker.md): a button that shows the family in
// use, drawn in itself, and opens a list of the system's families under a search field. "Default" heads the list: the
// family the program draws in when none is chosen, named ("Roboto (default)").
//
// Its machines:
//   picker:   closed -> (a click on the button, Down, Enter or Space on it) -> open -> (a choice, Escape, a press
//             outside it, the keyboard leaving it) -> closed
//   families: None -> Reading (the first opening) -> Ready; not read again
//   a face:   not asked -> Asked (its row built) -> Loaded | Missing
// The rows are made again only when the query or the families change.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../ascii"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// The faces loaded at most by one chore: a fast scroll loads the rows it stops on, not every row it passed.
FONT_PICKER_LOAD_BATCH :: 8
// The list at most, the popover at least, a heading's height, in ems.
@(private = "file") FONT_PICKER_LIST_EM :: 20
@(private = "file") FONT_PICKER_WIDTH_EM :: 22
@(private = "file") FONT_PICKER_HEADING_EM :: 1.7
// The rows' identities (Virtual_List ids): a family's is its index after these.
@(private = "file") FONT_ROW_ID_DEFAULT :: 1
@(private = "file") FONT_ROW_ID_HEADING :: 2
@(private = "file") FONT_ROW_ID_FAMILY :: 16

// Where the picker reads its families and their faces. Both calls run on the chores (they may read the system); a
// test's source answers from its own lists.
Font_Source :: struct {
	user:     rawptr,
	// The families, sorted by name, once each, in `allocator`.
	families: proc(user: rawptr, allocator: mem.Allocator) -> []font.Family,
	// A face of `family` to draw its name in (0: none: the name shows in the interface's font).
	face:     proc(user: rawptr, family: string) -> font.Font_Id,
}

// The system's families (font.system_families) and their regular faces (font.load_system), in `fonts`.
font_system_source :: proc(fonts: ^font.State) -> Font_Source {
	return {
		user = fonts,
		families = proc(user: rawptr, allocator: mem.Allocator) -> []font.Family {
			if user == nil { return nil }
			return font.system_families((^font.State)(user), allocator)
		},
		face = proc(user: rawptr, family: string) -> font.Font_Id {
			if user == nil { return 0 }
			id, _ := font.load_system((^font.State)(user), family)
			return id
		},
	}
}

Font_Families_Reading :: enum u8 { None, Reading, Ready }
Font_Face_State :: enum u8 { Asked, Loaded, Missing }

Font_Face :: struct {
	state: Font_Face_State,
	id:    font.Font_Id,
}

// The families and their faces, read once and shared by the pickers of a page: the caller's, set up with its `source`
// (font_system_source) and kept as long as the State it is used in (the answers of its chores come in that State's
// builds). font_families_destroy frees it.
Font_Families :: struct {
	source:  Font_Source,
	reading: Font_Families_Reading,
	list:    []font.Family,          // (heap)
	version: u64,                    // counts the changes of `list` (0: none yet)
	faces:   map[string]Font_Face,   // by family (keys in the heap)
	wanted:  [dynamic]string,        // this build's families with no face asked (borrowed: list, or the values shown)
	loading: bool,                   // a batch of faces is on a chore
	reads:   int,                    // the times the list was read, and the faces asked (a test: lazily, once)
	asked:   int,
}

font_families_destroy :: proc(fam: ^Font_Families) {
	a := runtime.heap_allocator()
	for f in fam.list { delete(f.name, a) }
	delete(fam.list, a)
	for k in fam.faces { delete(k, a) }
	delete(fam.faces)
	delete(fam.wanted)
	fam^ = {}
}

// The face of `family` when it is loaded; else 0, and it is asked for (its row is shown: font_families_ask).
font_families_face :: proc(fam: ^Font_Families, family: string) -> font.Font_Id {
	if family == "" { return 0 }
	if f, ok := fam.faces[family]; ok { return f.state == .Loaded ? f.id : 0 }
	if fam.wanted.allocator.procedure == nil { fam.wanted.allocator = runtime.heap_allocator() }
	if len(fam.wanted) < FONT_PICKER_LOAD_BATCH * 4 && !slice.contains(fam.wanted[:], family) { append(&fam.wanted, family) }
	return 0
}

// The faces wanted in this build (font_families_face of the rows built), a batch on a chore when none is there (the
// next batch at a build after its answer). Once per build, after the rows: a list of families of one's own (the
// palette's run mode) calls it as the picker does.
font_families_ask :: proc(fam: ^Font_Families) {
	defer clear(&fam.wanted)
	if fam.loading || len(fam.wanted) == 0 || fam.source.face == nil { return }
	a := runtime.heap_allocator()
	if fam.faces == nil { fam.faces = make(map[string]Font_Face, allocator = a) }
	n := min(len(fam.wanted), FONT_PICKER_LOAD_BATCH)
	job := new(Font_Face_Job, a)
	job^ = {families = fam, source = fam.source, names = make([]string, n, a), ids = make([]font.Font_Id, n, a)}
	for name, i in fam.wanted[:n] {
		job.names[i] = strings.clone(name, a)
		fam.faces[strings.clone(name, a)] = {state = .Asked}
	}
	fam.loading = true
	fam.asked += n
	task(gs(), font_face_work, font_face_done, job, font_face_lost)
}

@(private = "file")
Font_Face_Job :: struct {
	families: ^Font_Families,
	source:   Font_Source,
	names:    []string,   // (the job's: the families may be freed while it runs)
	ids:      []font.Font_Id,
}

@(private = "file")
font_face_work :: proc(d: rawptr) {
	job := (^Font_Face_Job)(d)
	for name, i in job.names { job.ids[i] = job.source.face(job.source.user, name) }
}

@(private = "file")
font_face_done :: proc(d: rawptr, _: u64) {
	job := (^Font_Face_Job)(d)
	fam := job.families
	for name, i in job.names {
		if f, ok := &fam.faces[name]; ok { f^ = {state = job.ids[i] != 0 ? Font_Face_State.Loaded : Font_Face_State.Missing, id = job.ids[i]} }
	}
	fam.loading = false
	font_face_lost(d)
}

@(private = "file")
font_face_lost :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	job := (^Font_Face_Job)(d)
	for n in job.names { delete(n, a) }
	delete(job.names, a)
	delete(job.ids, a)
	free(job, a)
}

// The list read on a chore, at the first opening of a picker (or of a list of one's own); not read again.
font_families_read :: proc(fam: ^Font_Families) {
	if fam.reading != .None { return }
	if fam.source.families == nil { fam.reading = .Ready; return }
	fam.reading = .Reading
	fam.reads += 1
	job := new(Font_List_Job, runtime.heap_allocator())
	job^ = {families = fam, source = fam.source}
	task(gs(), font_list_work, font_list_done, job, font_list_lost)
}

@(private = "file")
Font_List_Job :: struct {
	families: ^Font_Families,
	source:   Font_Source,
	list:     []font.Family,
}

@(private = "file")
font_list_work :: proc(d: rawptr) {
	job := (^Font_List_Job)(d)
	job.list = job.source.families(job.source.user, runtime.heap_allocator())
}

@(private = "file")
font_list_done :: proc(d: rawptr, _: u64) {
	job := (^Font_List_Job)(d)
	fam := job.families
	fam.list, job.list = job.list, nil
	fam.reading = .Ready
	fam.version += 1
	font_list_lost(d)
}

@(private = "file")
font_list_lost :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	job := (^Font_List_Job)(d)
	for f in job.list { delete(f.name, a) }
	delete(job.list, a)
	free(job, a)
}

////////////////////////////////
// The picker

Font_Picker_Options :: struct {
	// the face drawn when no family is chosen: its family is named, "Roboto (default)" (0: not known: "Default", in the
	// interface's font). The program's own, not the face in use: program_text_face for a text face
	default_face: font.Font_Id,
	// the monospace families first, the others after them under "Other families" (a code font's setting)
	monospace:    bool,
	name:         string,   // what a screen reader calls it ("": "Font")
}

// What a row of the list is. For tests: Font_Picker.rows.
Font_Picker_Row_Kind :: enum u8 { Default, Family, Heading }

Font_Picker_Row :: struct {
	kind:   Font_Picker_Row_Kind,
	index:  int,              // Family: of Font_Families.list
	ranges: []Fuzzy_Range,    // what the query lit in its words (in rows_arena)
}

// A picker's state: the caller's, kept from one build to the next (zero: closed). font_picker_destroy frees it.
Font_Picker :: struct {
	open:         bool,
	field:        Line_Edit,
	field_key:    Key,      // the search field's box (0: it takes the keyboard when it is built)
	button_key:   Key,
	vl:           Virtual_List,
	rows:         [dynamic]Font_Picker_Row,
	ids:          [dynamic]u64,
	selectable:   [dynamic]bool,
	rows_arena:   virtual.Arena,
	rows_query:   string,   // (heap)
	rows_version: u64,      // Font_Families.version the rows were made for
	rows_made:    bool,
	rows_height:  f32,      // the rows' content, in pixels at the em they were made at
	rows_em:      f32,
	rows_count:   int,      // the families the query found (the heading and Default aside)
	ids_version:  u64,
	select_value: bool,     // opening: the current family selected once the rows are made
	ranked:       int,      // the times the rows were made (a test: a quiet build makes none)
	cache:        Fuzzy_Cache,
}

font_picker_destroy :: proc(st: ^Font_Picker) {
	line_edit_destroy(&st.field)
	vlist_destroy(&st.vl)
	delete(st.rows)
	delete(st.ids)
	delete(st.selectable)
	virtual.arena_destroy(&st.rows_arena)
	delete(st.rows_query, runtime.heap_allocator())
	fuzzy_cache_destroy(&st.cache)
	st^ = {}
}

// How the default reads: its family, marked ("Roboto (default)"); "Default" when the family is not known.
font_default_label :: proc(family: string) -> string {
	if family == "" { return i18n.tr("Default") }
	return fmt.tprintf(i18n.tr("%s (default)"), family)
}

// The picker: `value`, the family chosen ("": the default), shown on a button in its own face. `chosen`: a family the
// person picked in this build ("" for Default; temporary memory): the caller sets it. Its size is `next`'s (else
// FONT_PICKER_WIDTH_EM wide and a button's line high).
font_picker :: proc(id: string, st: ^Font_Picker, fam: ^Font_Families, value: string, o := Font_Picker_Options{}) -> (chosen: Maybe(string)) {
	s := gs()
	em := font_size()
	default_face := o.default_face
	default_label := font_default_label(font.family_of(s.fonts, default_face))
	drop_id := fmt.tprintf("###font_picker_drop_%x", u64(key_from_string(parent_box().key, id)))
	drop_key := key_from_string(s.root.key, drop_id)
	if st.open { font_picker_follow_focus(st, drop_key) }

	// the button
	shown := value != "" ? value : default_label
	face := value != "" ? font_families_face(fam, value) : default_face
	next_default({width = px(math.round(em * FONT_PICKER_WIDTH_EM)), height = px(math.round(dense(em * BUTTON_LINE_EM)))})
	btn: ^Box
	sig: Signal
	if tags("button") {
		set_next_axis(.X, .Center)
		btn = build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, id)
		sig = signal(btn)
		a11y_default(btn, {role = .Combo_Box, name = o.name != "" ? o.name : i18n.tr("Font"), value = shown, expanded = st.open, popup = .Listbox, read_only = true})
		if parent(btn) {
			spacer(px(em * 0.8))
			next({width = fill(), height = pct(1)})
			if face != 0 { next_merge({font = face}) }
			build_box({.Draw_Text}, fmt.tprintf("%s###cur", text_shown(shown)))
			if tags("weak") { icon(st.open ? ICON_UP : ICON_DOWN, em * 1.8, nil, widget_icons()) }
		}
	}
	if btn == nil { return }
	st.button_key = btn.key
	kb := sig.focused && !st.open && (key_press(.Down, {.Alt}) || key_press(.Down) || key_press(.F4))
	if sig.clicked || kb {
		if st.open { font_picker_close(st) } else { font_picker_open(st, fam) }
	}
	if st.open {
		chosen = font_picker_drop(st, fam, drop_id, btn, value, default_label, default_face, o)
	}
	font_families_ask(fam)
	return
}

// Opens the picker's list as a click on its button does (a program that opens it from elsewhere: the palette, a
// picture of it); the families are read on a chore if they are not yet.
font_picker_open :: proc(st: ^Font_Picker, fam: ^Font_Families) {
	st.open, st.field_key, st.rows_made, st.select_value = true, 0, false, true
	line_edit_clear(&st.field)
	st.vl.no_typeahead = true   // (letters typed go to the field: type_to_field)
	vlist_scroll_to(&st.vl, 0)
	font_families_read(fam)
}

@(private = "file")
font_picker_close :: proc(st: ^Font_Picker) {
	st.open, st.field_key = false, 0
	if gs().focus_key != st.button_key && st.button_key != 0 { set_focus(st.button_key) }
}

// The keyboard left the picker: closed. A press on its popover is not that (the focus goes back to the field, the row's
// click comes with the release), nor one on its button (whose click closes it).
@(private = "file")
font_picker_follow_focus :: proc(st: ^Font_Picker, drop: Key) {
	s := gs()
	if st.field_key == 0 { return }
	focus := s.focus_key
	if focus == st.field_key || focus == st.vl.key || focus == st.button_key { return }
	if s.pressed_any[.Left] {
		hit := s.pressed_key[.Left]
		if owner, ok := s.sb_owner[hit]; ok { hit = owner }   // (its list's scroll bar)
		hb := s.boxes[hit] if hit != 0 else nil
		db := s.boxes[drop] or_else nil
		if hb != nil && db != nil && is_descendant(hb, db) {
			s.focus_key = st.field_key
			return
		}
	}
	st.open, st.field_key = false, 0
}

// Under the button: a popover with the search field and the list (a Virtual_List: only the rows in view are built).
@(private = "file")
font_picker_drop :: proc(st: ^Font_Picker, fam: ^Font_Families, drop_id: string, btn: ^Box, value, default_label: string, default_face: font.Font_Id, o: Font_Picker_Options) -> (chosen: Maybe(string)) {
	s := gs()
	em := font_size()
	row_h := dense(em * CHOICE_ROW_ONE_EM)
	heading_h := dense(em * FONT_PICKER_HEADING_EM)
	query := line_edit_string(&st.field)
	if !st.rows_made || st.rows_version != fam.version || st.rows_query != query || st.rows_em != em {
		font_picker_rank(st, fam, query, default_label, o.monospace, row_h, heading_h)
		st.rows_em = em
		if st.select_value {
			// (a family's row comes with the list: until it is read only Default can be the current one)
			at := font_picker_row_of(st, fam, value)
			if at >= 0 { list_select(&st.vl.list, at) }
			if at >= 0 || fam.reading == .Ready { st.select_value = false }
		} else if query != "" {
			list_select(&st.vl.list, len(st.rows) > 0 ? 0 : -1)   // (the best one: Enter takes it)
		}
	}
	pick := -1
	cancelled := false
	// the field's keys: Up, Down, Page Up, Page Down move in the list, Enter takes its row, Escape closes
	if st.field_key != 0 && s.focus_key == st.field_key {
		if key_press(.Escape) { font_picker_close(st); return }
		if key_press(.Return) && st.vl.sel >= 0 && st.vl.sel < len(st.rows) { pick = st.vl.sel }
		moves := [?]platform.Key{.Down, .Up, .Page_Down, .Page_Up}
		for k in moves {
			if key_press(k) {
				_ = item_selection_key(&st.vl.selection, list_rows(&st.vl.list), k, {}, max(st.vl.page_rows - 1, 1))
				st.vl.reveal = LIST_REVEAL_FRAMES
			}
		}
	}
	w := max(btn.rect.max.x - btn.rect.min.x, math.round(em * FONT_PICKER_WIDTH_EM))
	status := ""
	switch {
	case fam.reading == .Reading:                    status = i18n.tr("Reading the fonts…")
	case len(st.rows) == 0:                          status = i18n.tr("Nothing matches")
	}
	if popover(drop_id, btn.rect, w, .Below, align_right = false) {
		panel := parent_box()
		inner := max(w - 2 * border_inset(panel), 0)
		pad := math.round(em * 0.35)
		spacer(px(pad))
		next({width = px(inner), height = children_sum(), axis = .X})
		if row(.Center, {}, "###fp_search") {
			spacer(px(pad))
			// (a letter typed while the list has the keyboard goes to the field)
			if st.field_key != 0 && s.focus_key == st.vl.key { type_to_field(st.field_key) }
			next({width = fill(), height = px(math.round(dense(em * BUTTON_LINE_EM)))})
			a11y({role = .Editable_Combo_Box, name = o.name != "" ? o.name : i18n.tr("Font"), expanded = true, popup = .Listbox})
			res := line_edit("###fp_field", &st.field, {placeholder = i18n.tr("Search fonts"), placeholder_focused = true, clearable = true})
			if st.field_key == 0 { s.focus_key = res.box.key }
			st.field_key = res.box.key
			spacer(px(pad))
		}
		spacer(px(pad))
		if status != "" {
			next({width = px(inner), height = px(row_h), axis = .X, cross = .Center})
			if row(.Center, {}, "###fp_status") {
				spacer(px(em * 0.9))
				if fam.reading == .Reading {
					spinner("###fp_reading", em * 1.1)
					spacer(px(em * 0.5))
					a11y_default(parent_box(), {role = .Status, name = status, busy = true, live = .Polite})
				}
				if tags("weak") {
					next({width = fill(), height = pct(1), text_pad = 0})
					label(fmt.tprintf("%s###fp_status_text", status))
				}
			}
		}
		if len(st.rows) > 0 {
			view_h := min(st.rows_height, math.round(em * FONT_PICKER_LIST_EM))
			next({width = px(inner), height = px(view_h)})
			if rows, ok := vlist("###fp_list", &st.vl, st.ids[:], nil, st.selectable[:], st.ids_version); ok {
				for i in rows.first ..< rows.last {
					if font_picker_row(st, fam, i, value, default_label, default_face, row_h, heading_h) { pick = i }
				}
			}
			if st.vl.activated && st.vl.sel >= 0 { pick = st.vl.sel }
			cancelled = st.vl.cancelled
		}
		spacer(px(pad))
	}
	if cancelled { font_picker_close(st); return }
	if pick >= 0 && pick < len(st.rows) {
		r := st.rows[pick]
		#partial switch r.kind {
		case .Default: chosen = ""
		case .Family:  chosen = strings.clone(fam.list[r.index].name, context.temp_allocator)
		}
		if chosen != nil { font_picker_close(st) }
	}
	return
}

// One row, built under its list's row name (the list measures it). True: clicked.
@(private = "file")
font_picker_row :: proc(st: ^Font_Picker, fam: ^Font_Families, i: int, value, default_label: string, default_face: font.Font_Id, row_h, heading_h: f32) -> bool {
	s := gs()
	em := font_size()
	r := st.rows[i]
	if r.kind == .Heading {
		next({width = fill(), height = px(heading_h), axis = .X, cross = .Center})
		if parent(build_box({}, vlist_row_name(i))) {
			if tags("weak") {
				next({width = fill(), height = pct(1), font_size = math.round(em * 0.85), text_pad = em * 0.9})
				label(fmt.tprintf("%s###h", i18n.tr("Other families")))
			}
		}
		return false
	}
	title := default_label
	face := default_face
	mono, current := false, value == ""
	if r.kind == .Family {
		f := fam.list[r.index]
		title, mono = f.name, f.monospace
		face = font_families_face(fam, f.name)
		current = ascii.equal_fold(f.name, value)
	}
	selected := st.vl.sel == i
	push_tags("menu_item", "nav")
	defer pop_tags()
	if selected { push_tags("selected") }
	defer if selected { pop_tags() }
	next({width = fill(), height = px(row_h), axis = .X, cross = .Center, radius = font_size() * CONTROL_RADIUS_EM})
	flags := Box_Flags{.Clickable, .Draw_Hot_Effects, .Row}
	if selected { flags += {.Draw_Background, .Chosen} }
	rb := build_box(flags, vlist_row_name(i))
	a11y_default(rb, {role = .List_Box_Option, name = title, selected = selected, position = i + 1})
	sig := signal(rb)
	if sig.hovering && s.mouse_moved && st.vl.sel != i { st.vl.sel = i }
	if parent(rb) {
		spacer(px(em * 0.9))
		next({width = fill(), text_pad = 0})
		if face != 0 {
			push_style_copy()
			top_style().font = face
		}
		matched_label("###t", title, r.ranges)
		if face != 0 { pop_style() }
		if mono {
			spacer(px(em * 0.6))
			if tags("weak") {
				next({width = text_size(), height = pct(1), text_pad = 0, font_size = math.round(em * 0.85)})
				build_box({.Draw_Text}, fmt.tprintf("%s###m", i18n.tr("monospace")))
			}
		}
		if current {
			spacer(px(em * 0.5))
			next({width = px(em * 1.2), height = pct(1), font = lucide_icons(), font_size = em, text_align = .Center, text_pad = 0})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###c", lucide.CHECK))
		}
		spacer(px(em * 0.9))
	}
	return sig.clicked
}

@(private = "file")
font_picker_entry :: proc(f: ^font.Family, _: rawptr) -> Rank_Entry { return {label = f.name} }

// The rows for `query`: Default while the query finds its words, then the families it finds, best first (none typed:
// all, in their order); `mono`: the monospace ones first, the others under a heading.
@(private = "file")
font_picker_rank :: proc(st: ^Font_Picker, fam: ^Font_Families, query, default_label: string, mono: bool, row_h, heading_h: f32) {
	a := runtime.heap_allocator()
	if st.rows.allocator.procedure == nil { st.rows.allocator = a }
	if st.ids.allocator.procedure == nil { st.ids.allocator = a }
	if st.selectable.allocator.procedure == nil { st.selectable.allocator = a }
	delete(st.rows_query, a)
	st.rows_query = strings.clone(query, a)
	st.rows_version, st.rows_made = fam.version, true
	st.ranked += 1
	st.ids_version += 1
	virtual.arena_free_all(&st.rows_arena)
	ra := virtual.arena_allocator(&st.rows_arena)
	clear(&st.rows)
	clear(&st.ids)
	clear(&st.selectable)
	st.rows_height, st.rows_count = 0, 0
	keep :: proc(st: ^Font_Picker, kind: Font_Picker_Row_Kind, index: int, ranges: []Fuzzy_Range, h: f32, a: mem.Allocator) {
		r := Font_Picker_Row{kind = kind, index = index}
		if len(ranges) > 0 { r.ranges = slice.clone(ranges, a) }
		append(&st.rows, r)
		id: u64
		switch kind {
		case .Default: id = FONT_ROW_ID_DEFAULT
		case .Heading: id = FONT_ROW_ID_HEADING
		case .Family:  id = FONT_ROW_ID_FAMILY + u64(index)
		}
		append(&st.ids, id)
		append(&st.selectable, kind != .Heading)
		st.rows_height += h
	}
	if query == "" {
		keep(st, .Default, 0, nil, row_h, ra)
	} else if _, ranges, ok := fuzzy_score(query, default_label); ok {
		keep(st, .Default, 0, ranges, row_h, ra)
	}
	if len(fam.list) == 0 { return }
	hits := rank(query, fam.list, font_picker_entry, match = rank_fuzzy, cache = &st.cache, version = fam.version)
	st.rows_count = len(hits)
	marked := false
	if mono { for h in hits { if fam.list[h.index].monospace { marked = true; break } } }
	if !marked {
		for h in hits { keep(st, .Family, h.index, h.ranges, row_h, ra) }
		return
	}
	for h in hits { if fam.list[h.index].monospace { keep(st, .Family, h.index, h.ranges, row_h, ra) } }
	heading := false
	for h in hits {
		if fam.list[h.index].monospace { continue }
		if !heading { keep(st, .Heading, 0, nil, heading_h, ra); heading = true }
		keep(st, .Family, h.index, h.ranges, row_h, ra)
	}
}

// The row of the family `value` ("": Default), -1 when no row shows it.
@(private = "file")
font_picker_row_of :: proc(st: ^Font_Picker, fam: ^Font_Families, value: string) -> int {
	for r, i in st.rows {
		#partial switch r.kind {
		case .Default: if value == "" { return i }
		case .Family:  if value != "" && ascii.equal_fold(fam.list[r.index].name, value) { return i }
		}
	}
	return -1
}
