package ui

// The path bar (docs/path-bar.md; its reasons: src/md/features/path-bar.md): a folder's path as a breadcrumb a click
// walks, or as an address typed with a dropdown of what can come next. It reads nothing itself: it says which folder's
// children it needs (Path_Bar_Events.wants), and the program answers later (path_bar_children, path_bar_failed). Its
// state is the caller's (Path_Bar); its paths are texts of one separator, read by file_source.odin's helpers.
//
// Its machines:
//   mode:      breadcrumb -> (a click on its empty part, path_bar_edit) -> address -> (Enter, a row chosen, Escape twice,
//              the keyboard leaving the field) -> breadcrumb
//   children:  None -> Loading (wants said) -> Ready | Failed; another folder typed: Loading again; the breadcrumb: None
//   dropdown:  open in address mode; Escape closes it; a key typed, Down or Up opens it again
// The rows are made again only when the text or the data (Path_Bar.version) change.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"

// Children that come sooner than this show no "Reading…" row: a fast answer does not flash.
PATH_BAR_SLOW_MS :: 300
// The rows a section of the dropdown shows at most (the folder's children, a group of suggestions): a folder of 100 000
// entries builds as many boxes as a small one.
PATH_BAR_SHOWN_MAX :: 50
// The dropdown's list at most, in ems (it scrolls past it).
@(private = "file") PATH_BAR_LIST_EM :: 22
// Beside a part's words, and beside the "/" between two parts, in ems.
@(private = "file") PATH_BAR_PART_PAD_EM :: 0.35
@(private = "file") PATH_BAR_GLYPH_PAD_EM :: 0.1
// The room kept at the bar's end for a click that types (the breadcrumb's parts collapse before it), in ems.
@(private = "file") PATH_BAR_END_EM :: 3
// Between the well's edge and the parts, above and below them too, in ems.
@(private = "file") PATH_BAR_INSET_EM :: 0.2
// A group's title in the dropdown, in ems.
@(private = "file") PATH_BAR_HEADING_EM :: 1.7

// One row the dropdown can show: a child of the folder typed (given by path_bar_children), or a suggestion (given by
// path_bar_suggestions). The bar copies what it keeps.
Path_Bar_Entry :: struct {
	name:   string,
	icon:   string,   // a Lucide glyph ("": a folder's)
	detail: string,   // weak, at the row's right ("": none)
	branch: bool,     // it can be entered: Tab adds the separator after it, and the next level's children are asked
	path:   string,   // a suggestion's whole path (what it shows and goes to); a child's "": the folder joined to its name
}

// Suggestions under a title (the program's places, its recent folders, a search's answer).
Path_Bar_Group :: struct {
	title:   string,
	entries: []Path_Bar_Entry,
}

Path_Bar_Options :: struct {
	separator:     u8,       // '/' or '\\' (0: '/')
	name:          string,   // what a screen reader calls the bar ("": "Path")
	placeholder:   string,   // the field's, while it is empty
	edit_shortcut: string,   // the program's key for path_bar_edit ("Ctrl+L"), told with the bar's empty part
}

// What a build of the bar asks of the program. The strings are in the frame's temporary memory.
Path_Bar_Events :: struct {
	go:             Maybe(string),   // a path to go to: a part clicked, a row chosen, the text typed with Enter
	branch:         bool,            // `go` is a folder: a part, or a row given as a branch (false: typed, or a leaf's row)
	open_elsewhere: Maybe(string),   // a part's path, middle-clicked or clicked with Ctrl
	wants:          Maybe(string),   // the folder whose children the dropdown needs: said once, in the build it changes
}

// What a row of the dropdown is. For tests: Path_Bar.rows.
Path_Bar_Row_Kind :: enum u8 { Child, Suggestion, Heading, More }

Path_Bar_Row :: struct {
	kind:   Path_Bar_Row_Kind,
	index:  int,              // Child: of Path_Bar.children; Suggestion: of Path_Bar.suggested; Heading: of titles; More: how many are not shown
	ranges: []Fuzzy_Range,    // what the text lit in its words (in rows_arena)
}

// A suggestion as the bar keeps it: its group's index, and its entry.
Path_Bar_Suggestion :: struct {
	group:       int,
	using entry: Path_Bar_Entry,
}

// The state of the children of the folder typed.
Path_Bar_Reading :: enum u8 { None, Loading, Ready, Failed }

// The bar's state: the caller's, kept from one build to the next (zero: the breadcrumb). path_bar_destroy frees it.
Path_Bar :: struct {
	editing:    bool,        // the address mode
	edit_asked: bool,        // path_bar_edit: the address mode at the next build
	field:      Line_Edit,
	field_key:  Key,         // the field's box (0: it takes the keyboard when it is built)
	fresh:      bool,        // the path as it came, not edited yet: what is typed replaces it, so nothing filters
	open:       bool,        // the dropdown shows
	sel:        int,         // the row highlighted, an index of rows (-1: none)
	reveal:     bool,        // the keyboard moved the highlight: its row is scrolled into view
	sep:        u8,          // the separator of the last build
	// the children of the folder typed
	wanted:     string,      // that folder, its separators at its end trimmed ("": none)
	reading:    Path_Bar_Reading,
	asked_ms:   f64,         // when `wants` was said (the "Reading…" row comes after PATH_BAR_SLOW_MS)
	children:   [dynamic]Path_Bar_Entry,   // (strings in children_arena)
	message:    string,      // Failed: the program's words (in children_arena)
	children_arena: virtual.Arena,
	// the program's suggestions
	suggested:  [dynamic]Path_Bar_Suggestion,   // (strings in suggest_arena)
	titles:     [dynamic]string,
	suggest_arena: virtual.Arena,
	version:    u64,         // counts the changes of the children and of the suggestions
	// the rows, made for (rows_text, rows_version)
	rows:       [dynamic]Path_Bar_Row,
	rows_arena: virtual.Arena,
	rows_text:  string,
	rows_fresh: bool,
	rows_version: u64,
	rows_made:  bool,
	ranked:     int,         // the times the rows were made (a test: a quiet build makes none)
	child_cache:   Fuzzy_Cache,
	suggest_cache: Fuzzy_Cache,
}

path_bar_destroy :: proc(st: ^Path_Bar) {
	a := runtime.heap_allocator()
	line_edit_destroy(&st.field)
	delete(st.wanted, a)
	delete(st.rows_text, a)
	delete(st.children)
	delete(st.suggested)
	delete(st.titles)
	delete(st.rows)
	virtual.arena_destroy(&st.children_arena)
	virtual.arena_destroy(&st.suggest_arena)
	virtual.arena_destroy(&st.rows_arena)
	fuzzy_cache_destroy(&st.child_cache)
	fuzzy_cache_destroy(&st.suggest_cache)
	st^ = {}
}

// The address mode at the next build: the whole path in the field, selected (a program's key, the browser's Ctrl+L).
path_bar_edit :: proc(st: ^Path_Bar) { st.edit_asked = true }

// Whether the bar is in its address mode (its field has the keyboard, Escape is its own).
path_bar_editing :: proc(st: ^Path_Bar) -> bool { return st.editing || st.edit_asked }

// The children of `folder`, which `wants` asked: the dropdown lists them. An answer for another folder than the one
// wanted now (typed since, or the address mode left) is dropped. Copied: the program frees its own after the call.
path_bar_children :: proc(st: ^Path_Bar, folder: string, entries: []Path_Bar_Entry) {
	if !path_bar_answers(st, folder) { return }
	path_bar_allocators(st)
	virtual.arena_free_all(&st.children_arena)
	clear(&st.children)
	st.message = ""
	a := virtual.arena_allocator(&st.children_arena)
	reserve(&st.children, len(entries))
	for e in entries { append(&st.children, path_bar_entry_clone(e, a)) }
	st.reading = .Ready
	st.version += 1
}

// The children of `folder` could not be read: `message`, the program's words, shows in the dropdown in their place.
path_bar_failed :: proc(st: ^Path_Bar, folder, message: string) {
	if !path_bar_answers(st, folder) { return }
	path_bar_allocators(st)
	virtual.arena_free_all(&st.children_arena)
	clear(&st.children)
	st.message = strings.clone(message, virtual.arena_allocator(&st.children_arena))
	st.reading = .Failed
	st.version += 1
}

// The program's suggestions, under their groups' titles, after the children: set when they change (not each frame).
// Ranked against the whole text typed. Copied.
path_bar_suggestions :: proc(st: ^Path_Bar, groups: []Path_Bar_Group) {
	path_bar_allocators(st)
	virtual.arena_free_all(&st.suggest_arena)
	clear(&st.suggested)
	clear(&st.titles)
	a := virtual.arena_allocator(&st.suggest_arena)
	for g, gi in groups {
		append(&st.titles, strings.clone(g.title, a))
		for e in g.entries { append(&st.suggested, Path_Bar_Suggestion{group = gi, entry = path_bar_entry_clone(e, a)}) }
	}
	st.version += 1
}

// The bar: `path`, the folder it shows (the caller's, read in this build). Its size is `next`'s (else as wide as its
// parent and a button's line high). The breadcrumb's parts go where they are clicked (`go`); a click on its empty part
// turns it into a field with a dropdown (docs/path-bar.md: the keys).
path_bar :: proc(id: string, st: ^Path_Bar, path: string, o := Path_Bar_Options{}) -> (ev: Path_Bar_Events) {
	s := gs()
	em := font_size()
	path_bar_allocators(st)
	sep := o.separator != 0 ? o.separator : '/'
	st.sep = sep
	drop_id := fmt.tprintf("###path_bar_drop_%x", u64(key_from_string(parent_box().key, id)))
	if st.edit_asked {
		st.edit_asked = false
		path_bar_enter(st, path)
	}
	if st.editing { path_bar_follow_focus(st, key_from_string(s.root.key, drop_id)) }
	// (before the field: Up, Down, Tab, Enter and Escape are the bar's, the rest the field's)
	if st.editing { path_bar_keys(st, path, sep, &ev) }
	next_default({width = fill(), height = px(math.round(dense(em * BUTTON_LINE_EM)))})
	// (at rest a press on its empty part types: the well takes it, its parts take their own)
	if !st.editing { next_merge({flags = {.Clickable, .Clip}, cursor = .Text}) }
	frame: ^Box
	field: ^Box
	if input_frame(id) {
		frame = parent_box()
		if st.editing {
			field = path_bar_field(st, o)
		} else {
			a11y_default(frame, {role = .Navigation, name = o.name != "" ? o.name : i18n.tr("Path")})
			if signal(frame).clicked { path_bar_enter(st, path) }
			path_bar_crumbs(st, frame, path, sep, o, &ev)
		}
	}
	if !st.editing { return }
	text := line_edit_string(&st.field)
	folder := path_bar_folder(st, text, path, sep)
	if folder != st.wanted {
		path_bar_forget(st)
		if folder != "" {
			st.wanted = strings.clone(folder, runtime.heap_allocator())
			st.reading, st.asked_ms = .Loading, clock_ms(s)
			ev.wants = strings.clone(folder, context.temp_allocator)
		}
	}
	if !st.rows_made || st.rows_version != st.version || st.rows_text != text || st.rows_fresh != st.fresh { path_bar_rank(st, text, sep) }
	if st.open && frame != nil && frame.rect.max.x > frame.rect.min.x {
		path_bar_dropdown(st, drop_id, frame, field, sep, o, &ev)
	}
	return
}

////////////////////////////////
// The breadcrumb

// The parts, the leading ones that do not fit (by the last layout's width) in a "…" menu, a faint "/" between two.
@(private = "file")
path_bar_crumbs :: proc(st: ^Path_Bar, frame: ^Box, path: string, sep: u8, o: Path_Bar_Options, ev: ^Path_Bar_Events) {
	s := gs()
	em := font_size()
	parts := file_path_parts(path, sep)
	ts := top_style()
	inset := math.round(em * PATH_BAR_INSET_EM)
	inner := frame.size.y > 0 ? frame.size.y - 2 * border_inset(frame) - 2 * inset : math.round(em * 1.6)
	part_pad := math.round(em * PATH_BAR_PART_PAD_EM)
	glyph_pad := math.round(em * PATH_BAR_GLYPH_PAD_EM)
	glyph_w := text_width(ts.font, ts.font_size, "/") + 2 * glyph_pad
	more_w := inner + glyph_w
	room := frame.size.x - 2 * border_inset(frame) - 2 * inset - em * PATH_BAR_END_EM
	first := 0
	if room > 0 && frame.first_build != s.build_index {
		// (from the last part back: as many as fit, the "…" counted while parts are left before them; the last always)
		used: f32
		first = len(parts)
		for first > 0 {
			k := first - 1
			w := text_width(ts.font, ts.font_size, parts[k].name) + 2 * part_pad
			if k < len(parts) - 1 && path_bar_glyph_after(parts[k].name, sep) { w += glyph_w }
			more: f32 = k > 0 ? more_w : 0
			if first < len(parts) && used + w + more > room { break }
			used += w
			first = k
		}
	}
	spacer(px(inset))
	if first > 0 {
		menu_id := fmt.tprintf("###path_bar_more_%x", u64(frame.key))
		next({width = px(inner), height = px(inner)})
		sig := button("pb_more", icon = lucide.ELLIPSIS, o = {icon_font = lucide_icons(), tip = i18n.tr("The folders above")})
		if sig.clicked { menu_open(menu_id, sig.box.rect, sig.box.key, search = false) }
		if menu(menu_id) {
			#reverse for p, i in parts[:first] {
				if menu_item(fmt.tprintf("%s###pb_more_%d", text_shown(p.name), i), icon = lucide.FOLDER, icon_font = lucide_icons()).clicked {
					ev.go, ev.branch = strings.clone(p.path, context.temp_allocator), true
				}
			}
		}
		path_bar_glyph(-1, inner, glyph_pad)
	}
	for p, i in parts[first:] {
		k := first + i
		last := k == len(parts) - 1
		// (the folder shown in the text's colour, those above it weak)
		next({width = text_size(part_pad), height = px(inner), text_pad = 0})
		if !last { next_merge({fg = color("weak text")}) }
		a11y({current = last ? .Location : .False})
		sig := button(fmt.tprintf("pb_part_%d", k), p.name, o = {face = Button_Face.Ghost, tip = p.path != p.name ? p.path : ""})
		if sig.middle_clicked || (sig.clicked && .Ctrl in sig.mods) {
			ev.open_elsewhere = strings.clone(p.path, context.temp_allocator)
		} else if sig.clicked {
			ev.go, ev.branch = strings.clone(p.path, context.temp_allocator), true
		}
		if !last && path_bar_glyph_after(p.name, sep) { path_bar_glyph(k, inner, glyph_pad) }
	}
	// (the empty end: a click types the path; a screen reader's button for it)
	next({width = fill(), height = pct(1), cursor = .Text})
	end := build_box({.Clickable}, "###pb_edit")
	a11y_default(end, {role = .Button, name = i18n.tr("Type a path"), shortcut = o.edit_shortcut})
	if signal(end).clicked { path_bar_enter(st, path) }
}

// The faint "/" after part `k` (-1: after the "…").
@(private = "file")
path_bar_glyph :: proc(k: int, inner, pad: f32) {
	if tags("weak") {
		next({width = text_size(pad), height = px(inner), text_pad = 0, text_align = .Center})
		a11y({ignore = true})
		label(fmt.tprintf("/###pb_sep_%d", k + 1))
	}
}

// A "/" goes after a part, unless its words end with a separator already (the root "/").
@(private = "file")
path_bar_glyph_after :: proc(name: string, sep: u8) -> bool {
	if name == "" { return false }
	c := name[len(name) - 1]
	return c != sep && c != '/'
}

////////////////////////////////
// The address

@(private = "file")
path_bar_enter :: proc(st: ^Path_Bar, path: string) {
	st.editing, st.open, st.sel, st.field_key, st.fresh = true, true, -1, 0, true
	line_edit_set(&st.field, path)
	line_edit_select_all(&st.field)
	st.rows_made = false
}

// The folder whose children the dropdown lists: the folder shown while the text is fresh, else the folder typed.
@(private = "file")
path_bar_folder :: proc(st: ^Path_Bar, text, path: string, sep: u8) -> string {
	if st.fresh { return file_path_trim(path, sep) }
	folder, _ := path_bar_split(text, path, sep)
	return folder
}

// Back to the breadcrumb, going nowhere.
@(private = "file")
path_bar_leave :: proc(st: ^Path_Bar) {
	st.editing, st.open, st.sel, st.field_key, st.fresh = false, false, -1, 0, false
	line_edit_clear(&st.field)
	path_bar_forget(st)
	clear(&st.rows)
	st.rows_made = false
}

// No folder wanted: its children go (an answer for it is dropped from now).
@(private = "file")
path_bar_forget :: proc(st: ^Path_Bar) {
	delete(st.wanted, runtime.heap_allocator())
	st.wanted = ""
	virtual.arena_free_all(&st.children_arena)
	clear(&st.children)
	st.message = ""
	if st.reading != .None { st.version += 1 }
	st.reading = .None
}

// Whether an answer for `folder` is for the folder wanted now.
@(private = "file")
path_bar_answers :: proc(st: ^Path_Bar, folder: string) -> bool {
	return st.editing && st.wanted != "" && file_path_trim(folder, st.sep) == st.wanted
}

// The keyboard left the field: the breadcrumb again. A press on the dropdown is not that: the focus goes back to the
// field (the row's click comes with the release).
@(private = "file")
path_bar_follow_focus :: proc(st: ^Path_Bar, drop: Key) {
	s := gs()
	if st.field_key == 0 || s.focus_key == st.field_key { return }
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
	path_bar_leave(st)
}

// The bar's keys while its field has the keyboard (docs/path-bar.md).
@(private = "file")
path_bar_keys :: proc(st: ^Path_Bar, path: string, sep: u8, ev: ^Path_Bar_Events) {
	s := gs()
	if st.field_key == 0 || s.focus_key != st.field_key { return }
	if key_press(.Escape) {
		if st.open { st.open = false } else { path_bar_leave(st) }
		return
	}
	move :: proc(st: ^Path_Bar, dir: int) {
		if !st.open { st.open = true; return }
		st.sel = path_bar_step(st, st.sel, dir)
		st.reveal = true
	}
	if key_press(.Down) { move(st, 1) }
	if key_press(.Up) { move(st, -1) }
	// Tab: the row highlighted, else the best one; a branch with its separator, so the next level is asked
	if key_pressed_peek(.Tab) {
		r := st.sel >= 0 ? st.sel : path_bar_step(st, -1, 1)
		if r >= 0 && r < len(st.rows) {
			_ = key_press(.Tab)
			line_edit_set(&st.field, path_bar_completed(st, st.rows[r], line_edit_string(&st.field), sep))
			st.open, st.sel, st.fresh = true, -1, false
		}
	}
	if key_press(.Return) {
		text := line_edit_string(&st.field)
		if st.sel >= 0 && st.sel < len(st.rows) && path_bar_selectable(st.rows[st.sel]) {
			p, branch := path_bar_row_go(st, st.rows[st.sel], sep)
			ev.go, ev.branch = p, branch
		} else if typed := strings.trim_space(text); typed != "" {
			ev.go = file_path_root(typed, sep) > 0 ? strings.clone(typed, context.temp_allocator) : file_path_join(path, typed, sep)
		}
		path_bar_leave(st)
	}
}

// The field, in the well, its keyboard taken when it is first built.
@(private = "file")
path_bar_field :: proc(st: ^Path_Bar, o: Path_Bar_Options) -> ^Box {
	s := gs()
	if tags("bare") {
		next({width = fill(), height = pct(1)})
		a11y({role = .Editable_Combo_Box, name = o.name != "" ? o.name : i18n.tr("Path"), expanded = st.open, popup = .Listbox})
		res := line_edit("###pb_field", &st.field, {placeholder = o.placeholder})
		if st.field_key == 0 { s.focus_key = res.box.key }
		st.field_key = res.box.key
		if res.changed { st.open, st.sel, st.fresh = true, -1, false }
		return res.box
	}
	return nil
}

// The folder typed (the text up to its last separator: a relative one joined to `base`, cleaned, its end trimmed) and
// what follows it. No separator: `base`, and the whole text.
@(private)
path_bar_split :: proc(text, base: string, sep: u8) -> (folder, rest: string) {
	cut := strings.last_index_byte(text, sep)
	if sep == '\\' { cut = max(cut, strings.last_index_byte(text, '/')) }   // (what a person types on Windows)
	if cut < 0 { return file_path_trim(base, sep), text }
	dir := text[:cut + 1]
	if file_path_root(dir, sep) == 0 { dir = file_path_join(base, dir, sep) }
	return file_path_trim(file_path_clean(dir, sep), sep), text[cut + 1:]
}

// The next row the keyboard can highlight from `from` in direction `dir` (wrapping; from -1: the first or the last).
@(private = "file")
path_bar_step :: proc(st: ^Path_Bar, from, dir: int) -> int {
	n := len(st.rows)
	i := from < 0 ? (dir > 0 ? -1 : n) : from
	for _ in 0 ..< n {
		i += dir
		if i < 0 { i = n - 1 } else if i >= n { i = 0 }
		if path_bar_selectable(st.rows[i]) { return i }
	}
	return -1
}

@(private = "file")
path_bar_selectable :: proc(r: Path_Bar_Row) -> bool { return r.kind == .Child || r.kind == .Suggestion }

@(private = "file")
path_bar_row_entry :: proc(st: ^Path_Bar, r: Path_Bar_Row) -> ^Path_Bar_Entry {
	#partial switch r.kind {
	case .Child:      if r.index < len(st.children) { return &st.children[r.index] }
	case .Suggestion: if r.index < len(st.suggested) { return &st.suggested[r.index].entry }
	}
	return nil
}

// Where row `r` goes: a child's, the folder its children are of joined to its name; a suggestion's, its path. And
// whether it is a branch. (Temporary memory.)
@(private = "file")
path_bar_row_go :: proc(st: ^Path_Bar, r: Path_Bar_Row, sep: u8) -> (path: string, branch: bool) {
	e := path_bar_row_entry(st, r)
	if e == nil { return "", false }
	if r.kind == .Child { return file_path_join(st.wanted, e.name, sep), e.branch }
	return strings.clone(e.path != "" ? e.path : e.name, context.temp_allocator), e.branch
}

// The text Tab makes of row `r`: a child's name after what was typed up to its last separator (fresh: after the whole
// path and a separator), a suggestion's path; a branch's separator after it.
@(private = "file")
path_bar_completed :: proc(st: ^Path_Bar, r: Path_Bar_Row, text: string, sep: u8) -> string {
	e := path_bar_row_entry(st, r)
	if e == nil { return text }
	sep_text := [1]u8{sep}
	out: string
	if r.kind == .Child {
		if st.fresh {
			prefix := path_bar_glyph_after(text, sep) ? strings.concatenate({text, string(sep_text[:])}, context.temp_allocator) : text
			out = strings.concatenate({prefix, e.name}, context.temp_allocator)
		} else {
			cut := strings.last_index_byte(text, sep)
			if sep == '\\' { cut = max(cut, strings.last_index_byte(text, '/')) }
			out = strings.concatenate({text[:cut + 1], e.name}, context.temp_allocator)
		}
	} else {
		out = e.path != "" ? e.path : e.name
	}
	if e.branch && path_bar_glyph_after(out, sep) { out = strings.concatenate({out, string(sep_text[:])}, context.temp_allocator) }
	return out
}

////////////////////////////////
// The rows

@(private = "file")
path_bar_child_entry :: proc(e: ^Path_Bar_Entry, _: rawptr) -> Rank_Entry { return {label = e.name} }

@(private = "file")
path_bar_suggestion_entry :: proc(e: ^Path_Bar_Suggestion, _: rawptr) -> Rank_Entry { return {label = e.path != "" ? e.path : e.name} }

// The rows for `text`: the children ranked against what follows its last separator (none typed: all, in their order),
// then each group's suggestions ranked against the whole text, under its title (fresh: nothing filters). At most
// PATH_BAR_SHOWN_MAX a section, and a line that says how many more.
@(private = "file")
path_bar_rank :: proc(st: ^Path_Bar, text: string, sep: u8) {
	a := runtime.heap_allocator()
	delete(st.rows_text, a)
	st.rows_text = strings.clone(text, a)
	st.rows_version, st.rows_made, st.rows_fresh = st.version, true, st.fresh
	st.ranked += 1
	st.sel = -1   // (other rows: the highlight was on one of the last)
	virtual.arena_free_all(&st.rows_arena)
	clear(&st.rows)
	ra := virtual.arena_allocator(&st.rows_arena)
	keep :: proc(st: ^Path_Bar, kind: Path_Bar_Row_Kind, index: int, ranges: []Fuzzy_Range, a: mem.Allocator) {
		r := Path_Bar_Row{kind = kind, index = index}
		if len(ranges) > 0 { r.ranges = slice.clone(ranges, a) }
		append(&st.rows, r)
	}
	query := st.fresh ? "" : text
	if st.reading == .Ready {
		_, needle := path_bar_split(query, "", sep)
		hits := rank(needle, st.children[:], path_bar_child_entry, match = rank_fuzzy, cache = &st.child_cache)
		for h, i in hits {
			if i == PATH_BAR_SHOWN_MAX { keep(st, .More, len(hits) - i, nil, ra); break }
			keep(st, .Child, h.index, h.ranges, ra)
		}
	}
	if len(st.suggested) == 0 { return }
	hits := rank(query, st.suggested[:], path_bar_suggestion_entry, match = rank_fuzzy, cache = &st.suggest_cache)
	for _, g in st.titles {
		n := 0
		for h in hits {
			if st.suggested[h.index].group != g { continue }
			if n == 0 { keep(st, .Heading, g, nil, ra) }
			if n < PATH_BAR_SHOWN_MAX { keep(st, .Suggestion, h.index, h.ranges, ra) }
			n += 1
		}
		if n > PATH_BAR_SHOWN_MAX { keep(st, .More, n - PATH_BAR_SHOWN_MAX, nil, ra) }
	}
}

////////////////////////////////
// The dropdown

// Under the bar, as wide as it: a popover (it takes no key: the field keeps typing), its rows the dialogs' list rows.
@(private = "file")
path_bar_dropdown :: proc(st: ^Path_Bar, drop_id: string, frame, field: ^Box, sep: u8, o: Path_Bar_Options, ev: ^Path_Bar_Events) {
	s := gs()
	em := font_size()
	w := frame.rect.max.x - frame.rect.min.x
	row_h := dense(em * CHOICE_ROW_ONE_EM)
	heading_h := dense(em * PATH_BAR_HEADING_EM)
	waited := clock_ms(s) - st.asked_ms
	reading := st.reading == .Loading && waited >= PATH_BAR_SLOW_MS
	if st.reading == .Loading && !reading { wake_within(s, int(PATH_BAR_SLOW_MS - waited) + WAKE_MARGIN_MS) }
	// (its height: the rows', known before they are built)
	content: f32
	options := 0
	for r in st.rows {
		content += r.kind == .Heading ? heading_h : row_h
		if path_bar_selectable(r) { options += 1 }
	}
	status := ""
	switch {
	case reading:                   status = i18n.tr("Reading…")
	case st.reading == .Failed:     status = st.message
	case len(st.rows) == 0 && st.reading != .Loading: status = i18n.tr("Nothing matches")
	}
	if status != "" { content += row_h }
	if content == 0 { return }   // (children on their way, not late yet: nothing to show, nothing that flashes)
	chosen := -1
	if popover(drop_id, frame.rect, w, .Below, align_right = false) {
		panel := parent_box()
		inner := max(w - 2 * border_inset(panel), 0)
		pad := math.round(em * 0.25)
		spacer(px(pad))
		view_h := min(content, math.round(em * PATH_BAR_LIST_EM))
		next({width = px(inner), height = px(view_h)})
		if scroll_y("###pb_list") {
			lb := parent_box()
			a11y_default(lb, {role = .List_Box, name = o.name != "" ? o.name : i18n.tr("Path")})
			if field != nil { a11y_set(field, {controls = lb.key}) }
			if st.reveal && st.sel >= 0 {
				top: f32
				for r in st.rows[:st.sel] { top += r.kind == .Heading ? heading_h : row_h }
				lb.view_target.y = view_reveal_offset(lb.view_target.y, top, top + row_h, view_h)
			}
			st.reveal = false
			if status != "" {
				next({width = fill(), height = px(row_h), axis = .X, cross = .Center})
				if row(.Center, {}, "###pb_status") {
					spacer(px(em * 0.9))
					if reading {
						spinner("###pb_reading", em * 1.1)
						spacer(px(em * 0.5))
						a11y_default(parent_box(), {role = .Status, name = status, busy = true, live = .Polite})
					}
					if tags(st.reading == .Failed ? "bad" : "weak") {
						next({width = fill(), height = pct(1), text_pad = 0})
						label(fmt.tprintf("%s###pb_status_text", text_shown(status)))
					}
				}
			}
			position := 0
			for r, i in st.rows {
				switch r.kind {
				case .Heading:
					if tags("weak") {
						next({width = fill(), height = px(heading_h), font_size = em * 0.85, text_pad = em * 0.9})
						label(fmt.tprintf("%s###pb_heading_%d", text_shown(st.titles[r.index]), i))
					}
				case .More:
					if tags("weak") {
						next({width = fill(), height = px(row_h), font_size = em * 0.9, text_pad = em * 0.9})
						label(fmt.tprintf("%s###pb_rest_%d", text_shown(fmt.tprintf(i18n.tr("%d more: type to narrow them"), r.index)), i))
					}
				case .Child, .Suggestion:
					e := path_bar_row_entry(st, r)
					if e == nil { continue }
					position += 1
					title := r.kind == .Child ? e.name : (e.path != "" ? e.path : e.name)
					a11y({role = .List_Box_Option, name = title, selected = i == st.sel, position = position, set_size = options})
					if choice_row(fmt.tprintf("pb_row_%d", i), i, &st.sel, title, e.detail, e.icon != "" ? e.icon : lucide.FOLDER, lucide_icons(), r.ranges, beside = true) {
						chosen = i
					}
					if i == st.sel && field != nil && lb.last != nil { a11y_set(field, {active_descendant = lb.last.key}) }
				}
			}
		}
		spacer(px(pad))
	}
	if chosen >= 0 {
		p, branch := path_bar_row_go(st, st.rows[chosen], sep)
		ev.go, ev.branch = p, branch
		path_bar_leave(st)
	}
}

////////////////////////////////
// Memory

// (the bar's lists in the heap, whatever the allocator of the build that first fills them)
@(private = "file")
path_bar_allocators :: proc(st: ^Path_Bar) {
	a := runtime.heap_allocator()
	if st.children.allocator.procedure == nil { st.children.allocator = a }
	if st.suggested.allocator.procedure == nil { st.suggested.allocator = a }
	if st.titles.allocator.procedure == nil { st.titles.allocator = a }
	if st.rows.allocator.procedure == nil { st.rows.allocator = a }
}

@(private = "file")
path_bar_entry_clone :: proc(e: Path_Bar_Entry, a: mem.Allocator) -> Path_Bar_Entry {
	return {name = strings.clone(e.name, a), icon = strings.clone(e.icon, a), detail = strings.clone(e.detail, a), branch = e.branch, path = strings.clone(e.path, a)}
}
