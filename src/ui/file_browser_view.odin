package ui

// The file browser's dialog, built by end_build while it is open (file_browser.odin has its state). What a control asks
// (go to a folder, choose, cancel) is done once the dialog is built: the rows built in this build stay those of the
// folder they were made of, and a dialog that answers is not built further.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import remote "../remote"

// The dialog's size at first and its least, and the places' column, in ems.
FILE_BROWSER_WIDTH_EM :: 76
FILE_BROWSER_HEIGHT_EM :: 42
FILE_BROWSER_MIN_WIDTH_EM :: 32
FILE_BROWSER_MIN_HEIGHT_EM :: 20
FILE_PLACES_EM :: 12
// The list's least width beside the preview, in ems.
@(private = "file") FILE_LIST_MIN_EM :: 18

// What a control of the dialog asked in this build, done after it (file_browser_do).
@(private)
File_Action_Kind :: enum u8 { None, Go, Up, Back, Forward, Again, Activate, Act, Cancel, Path, Complete, New_Folder, Make }

@(private)
File_Action :: struct {
	kind:   File_Action_Kind,
	path:   string,   // Go, Path (the frame's memory)
	double: bool,     // Activate: by a double click
}

// The end of a build: the browser and its question, when a dialog is open.
@(private)
file_browser_build :: proc(s: ^State) {
	fb := s.files
	if fb == nil || !fb.open { return }
	context.allocator = runtime.heap_allocator()
	act := file_browser_dialog(fb)
	file_browser_do(fb, act)
	if fb.open && fb.asking { file_browser_ask(fb) }
}

@(private = "file")
file_browser_do :: proc(fb: ^File_Browser, a: File_Action) {
	if !fb.open { return }
	switch a.kind {
	case .None:
	case .Go:         file_browser_go(fb, a.path)
	case .Up:         file_browser_up(fb)
	case .Back:       file_browser_back(fb)
	case .Forward:    file_browser_forward(fb)
	case .Again:      file_browser_go(fb, fb.folder, .Again)
	case .Activate:   file_browser_activate(fb, a.double)
	case .Act:        file_browser_act(fb)
	case .Cancel:     file_browser_finish(fb, .Cancelled)
	case .Path:       file_browser_path_typed(fb, a.path)
	case .Complete:   file_browser_complete(fb)
	case .New_Folder: file_browser_new_folder(fb)
	case .Make:       file_browser_make(fb)
	}
}

// Save over a file of the folder: asked first.
@(private = "file")
file_browser_ask :: proc(fb: ^File_Browser) {
	name := file_path_name(fb.ask_path, fb.sep)
	switch confirm("file_browser_replace", &fb.asking, {
		title = fmt.tprintf(i18n.tr("Replace %s?"), name),
		note = i18n.tr("A file of this name is in this folder already. Saving replaces it."),
		act = i18n.tr("Replace"),
	}) {
	case .Confirmed:
		paths := [1]string{strings.clone(fb.ask_path, context.temp_allocator)}
		file_browser_finish(fb, .Chosen, paths[:])
	case .Cancelled, .None:
	}
}

// The dialog's title when its options give none, and the word of its act.
@(private = "file")
file_browser_words :: proc(kind: File_Dialog_Kind) -> (title, act: string) {
	switch kind {
	case .Open:   return i18n.tr("Open"), i18n.tr("Open")
	case .Save:   return i18n.tr("Save as"), i18n.tr("Save")
	case .Folder: return i18n.tr("Choose a folder"), i18n.tr("Choose")
	}
	return "", ""
}

@(private = "file")
file_browser_dialog :: proc(fb: ^File_Browser) -> (act: File_Action) {
	s := fb.state
	em := font_size()
	title, act_word := file_browser_words(fb.kind)
	if fb.d.title != "" { title = fb.d.title }
	was := fb.shown
	if modal("file_browser", &fb.shown, {width_em = FILE_BROWSER_WIDTH_EM, height_em = FILE_BROWSER_HEIGHT_EM, min_width_em = FILE_BROWSER_MIN_WIDTH_EM, min_height_em = FILE_BROWSER_MIN_HEIGHT_EM, size = &fb.size}) {
		act = file_browser_keys(fb)
		// (typing anywhere but in a field filters the list; not under the question of a Save)
		if !fb.asking { _ = type_to_field(fb.filter_key) }
		glyph := fb.kind == .Save ? lucide.SAVE : (fb.kind == .Folder ? lucide.FOLDER_OPEN : lucide.FOLDER)
		if dialog_header("fb_header", title, {icon = glyph, icon_font = lucide_icons(), close = true}) {}
		next({width = fill(), height = fill(), axis = .Y})
		if column(id = "###fb_body") {
			spacer(px(em * 0.5))
			file_browser_bar(fb, &act)
			spacer(px(em * 0.4))
			file_browser_main(fb, &act)
			file_browser_bottom(fb, &act, act_word)
		}
	}
	// (Escape seen by the dialog itself, a press outside it, its close button)
	if was && !fb.shown && act.kind == .None { act.kind = .Cancel }
	// (the keyboard left the path field: the breadcrumb again)
	if fb.path_editing && fb.path_key != 0 && s.focus_key != fb.path_key && act.kind != .Path { fb.path_editing = false }
	return
}

// The keys of the dialog, before its widgets take theirs: Escape's order, the shortcuts (docs/file-browser.md).
@(private = "file")
file_browser_keys :: proc(fb: ^File_Browser) -> (act: File_Action) {
	s := fb.state
	focused := s.boxes[s.focus_key] if s.focus_key != 0 else nil
	in_field := focused != nil && is_text_field(focused)
	if key_press(.Escape) {
		switch {
		case line_edit_string(&fb.filter) != "":
			line_edit_clear(&fb.filter)
			fb.focus_list = true
		case fb.path_editing:
			fb.path_editing = false
			fb.focus_list = true
		case fb.new_folder:
			fb.new_folder = false
			fb.focus_list = true
		case:
			act.kind = .Cancel
		}
		if fb.focus_list { s.focus_key = 0 }
	}
	if key_press(.L, {.Ctrl}) {
		fb.path_editing = true
		line_edit_set(&fb.path_edit, fb.folder)
		line_edit_select_all(&fb.path_edit)
		fb.path_key = 0   // (the field takes the keyboard when it is built)
	}
	if key_press(.H, {.Ctrl}) { fb.hidden = !fb.hidden }
	if key_press(.F5) { act.kind = .Again }
	if key_press(.N, {.Ctrl, .Shift}) { act.kind = .New_Folder }
	if key_press(.Up, {.Alt}) { act.kind = .Up }
	if key_press(.Left, {.Alt}) { act.kind = .Back }
	if key_press(.Right, {.Alt}) { act.kind = .Forward }
	if !in_field && key_press(.Backspace) { act.kind = .Up }
	if fb.path_editing && s.focus_key == fb.path_key && s.focus_key != 0 && key_press(.Tab) { act.kind = .Complete }
	// (the keyboard in the filter: the arrows and Enter are the list's still)
	if s.focus_key == fb.filter_key && s.focus_key != 0 {
		if ev := table_keys(&fb.table); ev.activated { act.kind = .Activate }
	}
	// Shift+Up / Down: the marks from where the range started, to the row the keyboard is on
	vl := &fb.table.vl
	if vl.multi && s.focus_key == vl.key && s.focus_key != 0 && len(fb.table.ids) > 0 {
		dir := 0
		if key_press(.Down, {.Shift}) { dir = 1 }
		if key_press(.Up, {.Shift}) { dir = -1 }
		if dir != 0 {
			if fb.shift_from < 0 || list_mark_count(vl) == 0 { fb.shift_from = max(vl.sel, 0) }
			to := clamp(vl.sel + dir, 0, len(fb.table.ids) - 1)
			list_marks_clear(vl)
			for i in min(fb.shift_from, to) ..= max(fb.shift_from, to) { vl.marks[fb.table.ids[i]] = true }
			vl.marks_changed = true
			list_select(vl, to)
		}
	}
	return
}

// The path bar: Back, Forward, Up; the folder as a breadcrumb or as a field; the filter.
@(private = "file")
file_browser_bar :: proc(fb: ^File_Browser, act: ^File_Action) {
	s := fb.state
	em := font_size()
	h := math.round(dense(em * 2.1))
	next({width = fill(), height = px(h), axis = .X, cross = .Center})
	if row(.Center, {}, "###fb_bar") {
		spacer(px(em * DIALOG_MARGIN_EM))
		up := file_path_parent(fb.folder, fb.sep)
		next({width = px(h), height = px(h)})
		if button("fb_back", icon = lucide.ARROW_LEFT, o = {icon_font = lucide_icons(), tip = i18n.tr("Back (Alt+Left)"), disabled = len(fb.back) == 0}).clicked { act.kind = .Back }
		next({width = px(h), height = px(h)})
		if button("fb_forward", icon = lucide.ARROW_RIGHT, o = {icon_font = lucide_icons(), tip = i18n.tr("Forward (Alt+Right)"), disabled = len(fb.forward) == 0}).clicked { act.kind = .Forward }
		next({width = px(h), height = px(h)})
		if button("fb_up", icon = lucide.ARROW_UP, o = {icon_font = lucide_icons(), tip = i18n.tr("Up (Backspace)"), disabled = up == "" || up == fb.folder}).clicked { act.kind = .Up }
		spacer(px(em * 0.5))
		if fb.path_editing {
			next({width = fill(), height = px(h)})
			a11y({name = i18n.tr("Folder")})
			res := line_edit("###fb_path", &fb.path_edit, {placeholder = i18n.tr("A folder's path")})
			if fb.path_key == 0 { s.focus_key = res.box.key }
			fb.path_key = res.box.key
			if res.committed { act^ = {kind = .Path, path = strings.clone(line_edit_string(&fb.path_edit), context.temp_allocator)} }
		} else {
			file_browser_crumbs(fb, act, h)
		}
		spacer(px(em * 0.5))
		next({width = px(em * 13), height = px(h)})
		if input_frame("###fb_filter_frame") {
			icon(lucide.SEARCH, em * 1.6, color("weak text"), lucide_icons())
			next({width = fill(), height = pct(1)})
			if tags("bare") {
				a11y({name = i18n.tr("Filter")})
				res := line_edit("###fb_filter", &fb.filter, {placeholder = i18n.tr("Filter"), clearable = true})
				fb.filter_key = res.box.key
				if res.committed { act.kind = .Activate }
			}
		}
		spacer(px(em * DIALOG_MARGIN_EM))
	}
}

// The folder as a button per part; the parts that do not fit (by the last layout's width) go into a "…" menu at the
// left. A click on the bar's empty end makes it a field.
@(private = "file")
file_browser_crumbs :: proc(fb: ^File_Browser, act: ^File_Action, h: f32) {
	em := font_size()
	next({width = fill(), height = px(h), axis = .X, cross = .Center})
	bar := build_box({.Clip}, "###fb_crumbs")
	a11y_default(bar, {role = .Navigation, name = i18n.tr("Folder")})
	push_parent(bar)
	defer pop_parent()
	parts := file_path_parts(fb.folder, fb.sep)
	st := top_style()
	gap := em * 1.3   // (a chevron between two parts)
	pad := em * 1.2
	room := bar.size.x - em * 3   // (the empty end, and the "…" when it shows)
	first := 0
	if room > 0 {
		used: f32
		first = len(parts)
		for first > 0 {
			w := text_width(st.font, st.font_size, parts[first - 1].name) + pad + gap
			if used + w > room && first < len(parts) { break }
			used += w
			first -= 1
		}
	}
	if first > 0 {
		menu_id := "###fb_crumbs_menu"
		next({width = px(h), height = px(h)})
		sig := button("fb_crumbs_more", icon = lucide.ELLIPSIS, o = {icon_font = lucide_icons(), tip = i18n.tr("The folders above")})
		if sig.clicked { menu_open(menu_id, sig.box.rect, sig.box.key, search = false) }
		if menu(menu_id) {
			#reverse for p, i in parts[:first] {
				if menu_item(fmt.tprintf("%s###fb_crumb_menu_%d", text_shown(p.name), i), icon = lucide.FOLDER, icon_font = lucide_icons()).clicked {
					act^ = {kind = .Go, path = strings.clone(p.path, context.temp_allocator)}
				}
			}
		}
		icon(lucide.CHEVRON_RIGHT, em * 1.1, color("weak text"), lucide_icons())
	}
	for p, i in parts[first:] {
		k := first + i
		if k > first { icon(lucide.CHEVRON_RIGHT, em * 1.1, color("weak text"), lucide_icons()) }
		last := k == len(parts) - 1
		next({height = px(h)})
		if button(fmt.tprintf("fb_crumb_%d", k), text_shown(p.name), o = {face = last ? Button_Face.Toggled : Button_Face.Ghost}).clicked && !last {
			act^ = {kind = .Go, path = strings.clone(p.path, context.temp_allocator)}
		}
	}
	next({width = fill(), height = pct(1), cursor = .Text})
	end := build_box({.Clickable}, "###fb_crumbs_end")
	a11y_default(end, {role = .Button, name = i18n.tr("Type a path (Ctrl+L)")})
	if signal(end).clicked {
		fb.path_editing = true
		line_edit_set(&fb.path_edit, fb.folder)
		line_edit_select_all(&fb.path_edit)
		fb.path_key = 0
	}
}

// The places, the list and the preview.
@(private = "file")
file_browser_main :: proc(fb: ^File_Browser, act: ^File_Action) {
	em := font_size()
	next({width = fill(), height = fill(), axis = .X})
	if row(.Start, {}, "###fb_main") {
		fb.main_width = parent_box().size.x   // (the last layout's: whether the preview has room)
		spacer(px(em * DIALOG_MARGIN_EM))
		file_browser_places(fb, act)
		spacer(px(em * 0.6))
		shown := .Read in fb.source.caps && fb.source.read != nil && fb.main_width >= em * (FILE_PREVIEW_SHOWN_EM + FILE_PLACES_EM)
		next({width = fill(), height = fill(), axis = .Y})
		if column(id = "###fb_list") { file_browser_list(fb, act) }
		file_preview_follow(fb, shown)
		if shown {
			total := fb.main_width / em - FILE_PLACES_EM - 2 * DIALOG_MARGIN_EM
			_ = splitter("###fb_split", .X, &fb.split, FILE_PREVIEW_MIN_EM, total - FILE_LIST_MIN_EM, {default_size = FILE_PREVIEW_DEFAULT_EM, after = true, unit = em, total = total, min_other = FILE_LIST_MIN_EM})
			next({width = px(math.round(clamp(fb.split, FILE_PREVIEW_MIN_EM, max(total - FILE_LIST_MIN_EM, FILE_PREVIEW_MIN_EM)) * em)), height = fill(), axis = .Y})
			if column(id = "###fb_preview") {
				a11y_default(parent_box(), {role = .Region, name = i18n.tr("Preview")})
				file_preview_build(fb)
			}
		}
		spacer(px(em * DIALOG_MARGIN_EM))
	}
}

// The source's places, the program's, the recent folders of this dialog: the one that holds the folder shown is marked.
@(private = "file")
file_browser_places :: proc(fb: ^File_Browser, act: ^File_Action) {
	em := font_size()
	// (the place marked is the deepest one the folder is in)
	marked := ""
	consider :: proc(marked: ^string, path, folder: string, sep: u8) {
		if file_path_within(folder, path, sep) && len(path) > len(marked^) { marked^ = path }
	}
	for p in fb.source_places { consider(&marked, p.path, fb.folder, fb.sep) }
	for p in fb.d.places { consider(&marked, p.path, fb.folder, fb.sep) }
	m := file_memory_of(&fb.memory, fb.d.remember_id)
	next({width = px(em * FILE_PLACES_EM), height = fill()})
	if scroll_y("###fb_places") {
		a11y_default(parent_box(), {role = .Navigation, name = i18n.tr("Places")})
		n := 0
		file_places_heading(i18n.tr("Places"))
		for p in fb.source_places { file_place_row(fb, p, marked, n, act); n += 1 }
		if len(fb.d.places) > 0 {
			spacer(px(em * 0.5))
			for p in fb.d.places { file_place_row(fb, p, marked, n, act); n += 1 }
		}
		if m != nil && len(m.recent) > 0 {
			spacer(px(em * 0.5))
			file_places_heading(i18n.tr("Recent"))
			for r in m.recent { file_place_row(fb, {path = r, icon = lucide.HISTORY}, "", n, act); n += 1 }
		}
	}
}

@(private = "file")
file_places_heading :: proc(text: string) {
	em := font_size()
	if tags("weak") {
		next({width = fill(), height = px(dense(em * 1.7)), font_size = em * 0.85, text_pad = em * 0.5})
		label(fmt.tprintf("%s###fb_heading_%s", strings.to_upper(text, context.temp_allocator), hash_part(text)))
	}
}

// A place's row: its icon and its name; marked when it holds the folder shown.
@(private = "file")
file_place_row :: proc(fb: ^File_Browser, p: platform.File_Place, marked: string, n: int, act: ^File_Action) {
	em := font_size()
	on := marked != "" && p.path == marked
	name := p.name != "" ? p.name : file_path_name(p.path, fb.sep)
	push_tags("list_row")
	defer pop_tags()
	if on { push_tags("selected") }
	defer if on { pop_tags() }
	next({width = fill(), height = px(dense(em * 1.9)), axis = .X, cross = .Center, radius = em * 0.35})
	flags := Box_Flags{.Clickable, .Focusable, .Draw_Hot_Effects}
	if on { flags += {.Draw_Background} }
	b := build_box(flags, fmt.tprintf("###fb_place_%d", n))
	a11y_default(b, {role = .Link, name = name, description = p.path, current = on ? .Location : .False})
	sig := signal(b)
	if parent(b) {
		spacer(px(em * 0.4))
		icon(p.icon != "" ? p.icon : lucide.FOLDER, em * 1.5, nil, lucide_icons())
		spacer(px(em * 0.3))
		next({width = fill(), height = pct(1), text_pad = 0})
		label_tip(fmt.tprintf("%s###t", text_shown(name)))
	}
	if sig.clicked { act^ = {kind = .Go, path = strings.clone(p.path, context.temp_allocator)} }
}

// The list, or what stands in for it: a folder being read (after FILE_BROWSER_SLOW_MS), empty, refused or failed.
@(private = "file")
file_browser_list :: proc(fb: ^File_Browser, act: ^File_Action) {
	s := fb.state
	em := font_size()
	if fb.new_folder { file_browser_new_row(fb, act) }
	switch {
	case remote.failed(&fb.listing):
		refused := fb.listing.state == .Refused
		next({width = fill(), height = fill()})
		title := refused ? i18n.tr("This folder may not be read") : i18n.tr("This folder could not be read")
		if empty_state("fb_failed", {icon = refused ? lucide.LOCK : lucide.ALERT_TRIANGLE, title = title, note = fb.listing.message,
			actions = {{text = i18n.tr("Try again"), icon = lucide.REFRESH_CW, intent = .Primary}}}) == 0 {
			act.kind = .Again
		}
		return
	case (fb.listing.state == .Loading || fb.listing.state == .Idle) && len(fb.entries) == 0:
		// (Idle: the computer's first folder is not known yet)
		waited := clock_ms(s) - fb.listing_ms
		next({width = fill(), height = fill(), axis = .Y, cross = .Center})
		if column(.Center, {}, "###fb_reading") {
			if waited >= FILE_BROWSER_SLOW_MS {
				spacer(fill())
				spinner("###fb_reading_spinner", em * 1.6)
				spacer(px(em * 0.5))
				if tags("weak") {
					next({width = fill(), text_align = .Center})
					label(fmt.tprintf("%s###fb_reading_text", i18n.tr("Reading this folder…")))
				}
				spacer(fill())
				a11y_default(parent_box(), {role = .Status, name = i18n.tr("Reading this folder…"), busy = true, live = .Polite})
			} else {
				wake_within(s, int(FILE_BROWSER_SLOW_MS - waited) + WAKE_MARGIN_MS)
			}
		}
		return
	case fb.listing.state == .Ready && len(fb.entries) == 0 && !fb.new_folder:
		next({width = fill(), height = fill()})
		empty_state("fb_empty", {icon = lucide.FOLDER_OPEN, title = i18n.tr("This folder is empty")})
		return
	}
	file_browser_rows(fb, false)
	fb.table.lead = file_row_lead
	fb.table.lead_user = fb
	empty := line_edit_string(&fb.filter) != "" ? i18n.tr("Nothing here matches the filter") : i18n.tr("Nothing here to show")
	next({width = fill(), height = fill()})
	a11y({name = i18n.tr("Files"), multiselectable = fb.table.vl.multi})
	ev := table_build("###fb_table", &fb.table, &fb.data, empty)
	if ev.sorted { file_browser_rows(fb, true) }
	if ev.activated && act.kind == .None { act^ = {kind = .Activate, double = s.double_key != 0} }
	// the keyboard is the list's when the dialog shows (Save: the name's)
	if fb.focus_list && s.focus_key == 0 {
		if fb.kind == .Save && fb.name_key != 0 { s.focus_key = fb.name_key } else { s.focus_key = fb.table.vl.key }
		fb.focus_list = false
	}
}

// A row's icon, before its name: its kind's (a folder in the accent).
@(private = "file")
file_row_lead :: proc(t: ^Table, row: int, size: f32) {
	fb := (^File_Browser)(t.lead_user)
	e := file_row_entry(fb, row)
	if e == nil { return }
	look := file_entry_look(e^)
	tint: Maybe(Color)
	if look == .Folder { tint = color("accent") }
	icon(file_look_icon(look), size, tint, lucide_icons())
}

// The row of a new folder: its name, being typed; Enter makes it, Escape gives it up.
@(private = "file")
file_browser_new_row :: proc(fb: ^File_Browser, act: ^File_Action) {
	s := fb.state
	em := font_size()
	h := math.round(dense(em * TABLE_ROW_EM * 1.2))
	next({width = fill(), height = px(h), axis = .X, cross = .Center})
	if row(.Center, {}, "###fb_new_row") {
		spacer(px(em * 0.4))
		icon(lucide.FOLDER_PLUS, em * 1.5, color("accent"), lucide_icons())
		spacer(px(em * 0.4))
		next({width = fill(), height = px(h - em * 0.3)})
		a11y({name = i18n.tr("The new folder's name")})
		res := line_edit("###fb_new_name", &fb.new_name)
		if fb.new_key == 0 { s.focus_key = res.box.key }
		fb.new_key = res.box.key
		if res.committed && fb.making.state != .Loading { act.kind = .Make }
		if fb.making.state == .Loading {
			spacer(px(em * 0.4))
			spinner("###fb_making", em * 1.2)
		}
		spacer(px(em * 0.4))
	}
	if remote.failed(&fb.making) {
		if tags("bad") {
			next({width = fill(), text_pad = em * 0.6})
			paragraph(fmt.tprintf("%s###fb_making_error", text_shown(fb.making.message)))
		}
	}
}

// The bottom: Save's name and the type list; New folder, Hidden files, Cancel and the act.
@(private = "file")
file_browser_bottom :: proc(fb: ^File_Browser, act: ^File_Action, act_word: string) {
	em := font_size()
	h := math.round(dense(em * 2.2))
	types := make([dynamic]string, context.temp_allocator)
	if fb.kind != .Folder {
		for f in fb.d.filters { append(&types, f.name != "" ? f.name : strings.join(f.patterns, ", ", context.temp_allocator)) }
		if fb.d.all_files && len(types) > 0 { append(&types, i18n.tr("All files")) }
	}
	show_types := len(types) > 1 || (fb.kind == .Save && len(types) > 0)
	if fb.kind == .Save || show_types {
		spacer(px(em * 0.6))
		next({width = fill(), height = px(h), axis = .X, cross = .Center})
		if row(.Center, {}, "###fb_naming") {
			spacer(px(em * DIALOG_MARGIN_EM))
			if fb.kind == .Save {
				next({width = text_size(em * 0.6), height = pct(1)})
				label(fmt.tprintf("%s###fb_name_label", i18n.tr("Name")))
				next({width = fill(), height = px(h)})
				a11y({name = i18n.tr("Name")})
				res := line_edit("###fb_name", &fb.name)
				fb.name_key = res.box.key
				if res.committed { act.kind = .Act }
				spacer(px(em * 0.6))
			} else {
				spacer(fill())
			}
			if show_types {
				next({width = text_size(em * 0.6), height = pct(1)})
				label(fmt.tprintf("%s###fb_type_label", i18n.tr("Type")))
				next({width = px(em * 14), height = px(h)})
				_ = dropdown("###fb_type", types[:], &fb.type_index)
			}
			spacer(px(em * DIALOG_MARGIN_EM))
		}
	}
	spacer(px(em * 0.6))
	next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
	if row(.Center, {}, "###fb_buttons") {
		spacer(px(em * DIALOG_MARGIN_EM))
		if .Make_Folder in fb.source.caps && fb.source.make_folder != nil {
			if button("fb_new_folder", i18n.tr("New folder"), lucide.FOLDER_PLUS, {icon_font = lucide_icons(), tip = i18n.tr("Shift+Ctrl+N"), disabled = fb.folder == "" || remote.failed(&fb.listing)}).clicked {
				act.kind = .New_Folder
			}
			spacer(px(em * DIALOG_BUTTON_GAP_EM))
		}
		_ = checkbox("###fb_hidden", fmt.tprintf("%s###fb_hidden_text", i18n.tr("Hidden files")), &fb.hidden)
		spacer(fill())
		if button("fb_cancel", i18n.tr("Cancel"), lucide.X, {icon_font = lucide_icons()}).clicked { act.kind = .Cancel }
		spacer(px(em * DIALOG_BUTTON_GAP_EM))
		if button("fb_act", act_word, fb.kind == .Save ? lucide.SAVE : lucide.CHECK, {icon_font = lucide_icons(), intent = .Primary, disabled = !file_browser_can_act(fb)}).clicked {
			act.kind = .Act
		}
		spacer(px(em * DIALOG_MARGIN_EM))
	}
	spacer(px(em * DIALOG_MARGIN_EM))
}
