package ui

// The file picker's build (file_picker.odin has its state): a program's, in its own layout, or ui.file_dialog's in its
// view (file_dialog.odin). What a control asks (go to a folder, choose, cancel) is done once its body is built: the rows
// built in this build stay those of the folder they were made of, and a picker that answers is not built further.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "../fsx"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import remote "../remote"

// The places' column, in ems.
FILE_PLACES_EM :: 12
// The list's least width beside the preview, in ems.
@(private = "file") FILE_LIST_MIN_EM :: 18

// What a control of the picker asked in this build, done after it (file_picker_do).
@(private)
File_Action_Kind :: enum u8 { None, Go, Up, Home, Back, Forward, Again, Activate, Act, Cancel, Path, New_Folder, Make, Rename, Trash }

@(private)
File_Action :: struct {
	kind:   File_Action_Kind,
	path:   string,   // Go, Path (the frame's memory)
	double: bool,     // Activate: by a double click
}

// What a build of a picker says (file_picker). Its strings are in the frame's memory.
File_Picker_Events :: struct {
	answered:          bool,                    // the person chose or cancelled: `result` says which
	result:            platform.Dialog_Result,  // Chosen: the paths; the type line chosen; the choices' values
	folder_changed:    bool,                    // another folder is shown (file_picker_folder)
	selection_changed: bool,                    // other entries are selected (file_picker_selected)
}

// Builds the picker `fp` (file_picker_init) at the size `next` gives (else the whole room of its parent). Call it at
// each build while it shows. It reads the keys when the focus is in it; ui.file_dialog's reads all of its window's.
file_picker :: proc(id: string, fp: ^File_Picker) -> (ev: File_Picker_Events) {
	// (a picker that builds nothing: what `next` said was for its box, not for the one after it)
	if !fp.open { next_drop(gs()); return }
	context.allocator = runtime.heap_allocator()
	// the overwrite question's answer (a view over the picker)
	if fp.asking {
		switch confirm_answer(FILE_REPLACE_VIEW, fp.instance) {
		case .Confirmed:
			fp.asking = false
			paths := [1]string{strings.clone(fp.ask_path, context.temp_allocator)}
			file_picker_answer(fp, .Chosen, paths[:])
			next_drop(gs())
			return file_picker_events(fp)
		case .Cancelled: fp.asking, fp.asked = false, false
		case .None:
		}
	}
	act := file_picker_body(id, fp)
	file_picker_do(fp, act)
	if fp.open { file_picker_rename_follow(fp) }
	if fp.open && fp.asking && !fp.asked { file_picker_ask(fp) }
	return file_picker_events(fp)
}

// What changed since the last build, and the answer given since (taken: it is said once).
@(private = "file")
file_picker_events :: proc(fp: ^File_Picker) -> (ev: File_Picker_Events) {
	if fp.answered {
		ev.answered = true
		ev.result = platform.dialog_result_clone(fp.answer, context.temp_allocator)
		platform.dialog_result_destroy(&fp.answer, runtime.heap_allocator())
		fp.answered = false
	}
	ev.folder_changed, fp.moved = fp.moved, false
	// (the active row by its identity, not its place: a filter or a sort moves it and selects nothing else)
	vl := &fp.table.vl
	active: u64
	if vl.sel >= 0 && vl.sel < len(fp.table.ids) { active = fp.table.ids[vl.sel] }
	seen := [2]u64{active, vl.version}
	if seen != fp.seen_selection {
		fp.seen_selection = seen
		ev.selection_changed = true
	}
	return
}

@(private = "file")
file_picker_do :: proc(fp: ^File_Picker, a: File_Action) {
	if !fp.open { return }
	switch a.kind {
	case .None:
	case .Go:         file_picker_go(fp, a.path)
	case .Up:         file_picker_up(fp)
	case .Home:       file_picker_home(fp)
	case .Back:       file_picker_back(fp)
	case .Forward:    file_picker_forward(fp)
	case .Again:      file_picker_go(fp, fp.folder, .Again)
	case .Activate:   file_picker_activate(fp, a.double)
	case .Act:        file_picker_act(fp)
	case .Cancel:     file_picker_answer(fp, .Cancelled)
	case .Path:       file_picker_path_typed(fp, a.path)
	case .New_Folder: file_picker_new_folder(fp)
	case .Make:       file_picker_make(fp)
	case .Rename:     file_picker_rename_start(fp)
	case .Trash:      file_picker_trash(fp)
	}
}

// The id of the overwrite question (a confirmation, instance: the picker's).
FILE_REPLACE_VIEW :: "file_picker_replace"

// Save over a file of the folder: asked first, once (its answer comes to file_picker).
@(private = "file")
file_picker_ask :: proc(fp: ^File_Picker) {
	fp.asked = true
	fp.ask_views = state_views(gs())
	name := file_path_name(fp.ask_path, fp.sep)
	confirm_open(FILE_REPLACE_VIEW, {
		title = fmt.tprintf(i18n.tr("Replace %s?"), name),
		note = i18n.tr("A file of this name is in this folder already. Saving replaces it."),
		act = i18n.tr("Replace"),
	}, fp.instance)
}

// A request's title when its options give none, and the word of its act.
@(private)
file_picker_words :: proc(kind: platform.File_Dialog_Kind) -> (title, act: string) {
	switch kind {
	case .Open:   return i18n.tr("Open"), i18n.tr("Open")
	case .Save:   return i18n.tr("Save as"), i18n.tr("Save")
	case .Folder: return i18n.tr("Choose a folder"), i18n.tr("Choose")
	}
	return "", ""
}

// The body: the keys, the path bar, the places, the list and the preview, the bottom. (Escape: the picker's order; a
// dialog's close cross and a press outside: its view's on_end.)
@(private = "file")
file_picker_body :: proc(id: string, fp: ^File_Picker) -> (act: File_Action) {
	em := font_size()
	_, act_word := file_picker_words(fp.kind)
	if fp.d.act != "" { act_word = fp.d.act }
	// (a program's picker beside its own parts reads no key of theirs: only with the focus in it)
	keys := fp.dialog || fp.focus_inside
	if keys { act = file_picker_keys(fp) }
	// (typing anywhere but in a field filters the list; not under the question of a Save)
	if keys && !fp.asking { _ = type_to_field(fp.filter_key) }
	next_default({width = fill(), height = fill()})
	next_merge({axis = .Y})
	if column(id = id) {
		body := parent_box()
		spacer(px(em * 0.5))
		file_picker_bar(fp, &act)
		spacer(px(em * 0.4))
		file_picker_main(fp, &act)
		file_picker_bottom(fp, &act, act_word)
		file_picker_side_buttons(fp, body, &act)
		s := gs()
		focused := s.boxes[s.focus_key] or_else nil
		switch {
		case s.focus_key == 0:
			fp.focus_inside = false
		case box_current(s, focused):
			fp.focus_inside = is_descendant(focused, body)
			if fp.focus_inside { fp.focus_held = s.focus_key }
		case:
			// (its box went with the rows, an empty folder, a failed reading: the keys stay the picker's)
			fp.focus_inside = s.focus_key == fp.focus_held
		}
	}
	return
}

// The mouse's side buttons go Back and Forward, as Alt+Left and Alt+Right: only with the pointer on the picker, or on
// its path bar's dropdown (a popover of the window, outside the body). A field with the keyboard changes nothing: a
// button of the mouse is no key it types.
@(private = "file")
file_picker_side_buttons :: proc(fp: ^File_Picker, body: ^Box, act: ^File_Action) {
	back, forward := mouse_pressed(.Back), mouse_pressed(.Forward)
	if !back && !forward { return }
	if !pointer_on(body) && !path_bar_pointer_on(&fp.bar) { return }
	act.kind = back ? .Back : .Forward
}

// The keys of the picker, before its widgets take theirs: Escape's order, the shortcuts (docs/file-browser.md).
@(private = "file")
file_picker_keys :: proc(fp: ^File_Picker) -> (act: File_Action) {
	s := gs()   // (the State it is built in: its owner's, or its own window's)
	focused := s.boxes[s.focus_key] if s.focus_key != 0 else nil
	in_field := focused != nil && is_text_field(focused)
	// (the path bar's field has its own: its dropdown closes, then the breadcrumb comes back)
	if !path_bar_editing(&fp.bar) && key_press(.Escape) {
		switch {
		case table_band_cancel(&fp.table):   // (a rectangle being drawn: the selection there was)
		case fp.renaming:
			file_picker_rename_end(fp)   // (the name as it was; the list takes the keyboard)
		case line_edit_string(&fp.filter) != "":
			line_edit_clear(&fp.filter)
			fp.focus_list = true
		case fp.new_folder:
			fp.new_folder = false
			fp.focus_list = true
		case:
			act.kind = .Cancel
		}
		if fp.focus_list { s.focus_key = 0 }
	}
	if key_press(.L, {.Ctrl}) { path_bar_edit(&fp.bar) }
	if key_press(.H, {.Ctrl}) { fp.hidden = !fp.hidden }
	if key_press(.P, {.Alt}) { fp.preview_off = !fp.preview_off }   // (Windows Explorer's key for its preview pane)
	if key_press(.F5) { act.kind = .Again }
	if key_press(.N, {.Ctrl, .Shift}) { act.kind = .New_Folder }
	if key_press(.Up, {.Alt}) { act.kind = .Up }
	if key_press(.Home, {.Alt}) { act.kind = .Home }
	if key_press(.Left, {.Alt}) { act.kind = .Back }
	if key_press(.Right, {.Alt}) { act.kind = .Forward }
	if !in_field && key_press(.Backspace) { act.kind = .Up }
	// (the rows' menu's keys: on the entries chosen, as the menu's items; a field keeps its own F2 and Delete)
	if !in_field && !fp.renaming {
		if key_press(.F2) { act.kind = .Rename }
		if key_press(.Delete) { act.kind = .Trash }
	}
	// (the keyboard in the filter: the arrows and Enter are the list's still)
	if s.focus_key == fp.filter_key && s.focus_key != 0 {
		if ev := table_keys(&fp.table); ev.activated { act.kind = .Activate }
	}
	// (Shift+arrows in the list: the list's own selection, item_selection.odin)
	return
}

// The path bar: Back, Forward, Up; the folder as a breadcrumb or as a field; the filter.
@(private = "file")
file_picker_bar :: proc(fp: ^File_Picker, act: ^File_Action) {
	s := gs()   // (the State it is built in: its owner's, or its own window's)
	em := font_size()
	h := math.round(dense(em * 2.1))
	next({width = fill(), height = px(h), axis = .X, cross = .Center})
	if row(.Center, {}, "###fb_bar") {
		spacer(px(em * DIALOG_MARGIN_EM))
		up := file_path_parent(fp.folder, fp.sep)
		next({width = px(h), height = px(h)})
		if button("fb_back", icon = lucide.ARROW_LEFT, o = {icon_font = lucide_icons(), tip = i18n.tr("Back (Alt+Left)"), disabled = len(fp.back) == 0}).clicked { act.kind = .Back }
		next({width = px(h), height = px(h)})
		if button("fb_forward", icon = lucide.ARROW_RIGHT, o = {icon_font = lucide_icons(), tip = i18n.tr("Forward (Alt+Right)"), disabled = len(fp.forward) == 0}).clicked { act.kind = .Forward }
		next({width = px(h), height = px(h)})
		if button("fb_up", icon = lucide.ARROW_UP, o = {icon_font = lucide_icons(), tip = i18n.tr("Up (Backspace)"), disabled = up == "" || up == fp.folder}).clicked { act.kind = .Up }
		spacer(px(em * 0.5))
		was, field := fp.bar.editing, fp.bar.field_key
		next({width = fill(), height = px(h)})
		ev := path_bar("###fb_path", &fp.bar, fp.folder, {separator = fp.sep, name = i18n.tr("Folder"), placeholder = i18n.tr("A folder's path"), edit_shortcut = "Ctrl+L"})
		if p, ok := ev.go.?; ok {
			// (a folder is entered at once; a path typed or a file is looked for in its folder: a file or a folder)
			act^ = {kind = ev.branch ? .Go : .Path, path = p}
		}
		if w, ok := ev.wants.?; ok { file_picker_bar_wants(fp, w) }
		if !was && fp.bar.editing { file_picker_bar_suggest(fp) }
		// (the field left with the keyboard in it, Escape or Enter: the list takes it)
		if was && !fp.bar.editing && (s.focus_key == field || s.focus_key == 0) {
			s.focus_key = 0
			fp.focus_list = true
		}
		spacer(px(em * 0.5))
		next({width = px(em * 13), height = px(h)})
		if input_frame("###fb_filter_frame") {
			icon(lucide.SEARCH, em * 1.6, color("weak text"), lucide_icons())
			next({width = fill(), height = pct(1)})
			if tags("bare") {
				a11y({name = i18n.tr("Filter")})
				res := line_edit("###fb_filter", &fp.filter, {placeholder = fp.deep && fp.source.find != nil ? i18n.tr("Search") : i18n.tr("Filter"), clearable = true})
				fp.filter_key = res.box.key
				if res.committed { act.kind = .Activate }
			}
		}
		if fp.source.find != nil {
			spacer(px(em * 0.5))
			_ = checkbox("###fb_deep", fmt.tprintf("%s###fb_deep_text", i18n.tr("In subfolders")), &fp.deep)
		}
		spacer(px(em * 0.5))
		file_picker_view_button(fp, h)
		// (only where the preview has room: a button that changes nothing is not shown)
		if file_picker_preview_room(fp, em) {
			spacer(px(em * 0.25))
			next({width = px(h), height = px(h)})
			glyph := fp.preview_off ? lucide.PANEL_RIGHT_OPEN : lucide.PANEL_RIGHT_CLOSE
			tip := fp.preview_off ? i18n.tr("Show the preview (Alt+P)") : i18n.tr("Hide the preview (Alt+P)")
			if button("fb_preview_toggle", icon = glyph, o = {icon_font = lucide_icons(), tip = tip}).clicked { fp.preview_off = !fp.preview_off }
		}
		spacer(px(em * DIALOG_MARGIN_EM))
	}
}

// The menu of the list's views: one per picker (two pickers of a window build their own).
@(private = "file")
file_view_menu :: proc(fp: ^File_Picker) -> string { return fmt.tprintf("###fb_view_menu_%s", fp.instance) }

// The list's view: a button of the step's icon, whose menu lists the seven steps (the one shown checked). Ctrl+wheel
// and the zoom keys step them too (Table.zoom_keys).
@(private = "file")
file_picker_view_button :: proc(fp: ^File_Picker, h: f32) {
	next({width = px(h), height = px(h)})
	b := button("fb_view", icon = table_zoom_icon(fp.table.zoom), o = {icon_font = lucide_icons(), tip = i18n.tr("View (Ctrl+wheel, Ctrl+= and Ctrl+-)")})
	if b.clicked && b.box != nil { menu_open(file_view_menu(fp), b.box.rect, align = .End) }
	if menu(file_view_menu(fp)) {
		menu_heading(i18n.tr("View"))
		for i in 0 ..< TABLE_ZOOMS {
			if menu_item(fmt.tprintf("%s###fb_view_%d", table_zoom_label(i), i), checked = fp.table.zoom == i, icon = table_zoom_icon(i), icon_font = lucide_icons()).clicked {
				_ = table_set_zoom(&fp.table, i)
			}
		}
	}
}

// Whether the preview can show: the source reads files and the picker is wide enough. (Whether it does: preview_off.)
@(private = "file")
file_picker_preview_room :: proc(fp: ^File_Picker, em: f32) -> bool {
	return .Read in fp.source.caps && fp.source.read != nil && fp.main_width >= em * (FILE_PREVIEW_SHOWN_EM + FILE_PLACES_EM)
}

// The places, the list and the preview.
@(private = "file")
file_picker_main :: proc(fp: ^File_Picker, act: ^File_Action) {
	em := font_size()
	next({width = fill(), height = fill(), axis = .X})
	if row(.Start, {}, "###fb_main") {
		fp.main_width = parent_box().size.x   // (the last layout's: whether the preview has room)
		spacer(px(em * DIALOG_MARGIN_EM))
		file_picker_places(fp, act)
		spacer(px(em * 0.6))
		shown := file_picker_preview_room(fp, em) && !fp.preview_off
		next({width = fill(), height = fill(), axis = .Y})
		if column(id = "###fb_list") { file_picker_list(fp, act) }
		file_preview_follow(fp, shown)
		if shown {
			total := fp.main_width / em - FILE_PLACES_EM - 2 * DIALOG_MARGIN_EM
			_ = splitter("###fb_split", .X, &fp.split, FILE_PREVIEW_MIN_EM, total - FILE_LIST_MIN_EM, {default_size = FILE_PREVIEW_DEFAULT_EM, after = true, unit = em, total = total, min_other = FILE_LIST_MIN_EM})
			next({width = px(math.round(clamp(fp.split, FILE_PREVIEW_MIN_EM, max(total - FILE_LIST_MIN_EM, FILE_PREVIEW_MIN_EM)) * em)), height = fill(), axis = .Y})
			if column(id = "###fb_preview") {
				a11y_default(parent_box(), {role = .Region, name = i18n.tr("Preview")})
				file_preview_build(fp)
			}
		}
		spacer(px(em * DIALOG_MARGIN_EM))
	}
}

// The source's places, the program's, the recent folders of this dialog: the one that holds the folder shown is marked.
@(private = "file")
file_picker_places :: proc(fp: ^File_Picker, act: ^File_Action) {
	em := font_size()
	// (the place marked is the deepest one the folder is in)
	marked := ""
	consider :: proc(marked: ^string, path, folder: string, sep: u8) {
		if file_path_within(folder, path, sep) && len(path) > len(marked^) { marked^ = path }
	}
	for p in fp.source_places { consider(&marked, p.path, fp.folder, fp.sep) }
	for p in fp.d.places { consider(&marked, p.path, fp.folder, fp.sep) }
	m := file_memory_of(&fp.state.files.memory, fp.d.remember_id)
	next({width = px(em * FILE_PLACES_EM), height = fill()})
	if scroll_y("###fb_places") {
		a11y_default(parent_box(), {role = .Navigation, name = i18n.tr("Places")})
		n := 0
		file_places_heading(i18n.tr("Places"))
		for p in fp.source_places { file_place_row(fp, p, marked, n, act); n += 1 }
		if len(fp.d.places) > 0 {
			spacer(px(em * 0.5))
			for p in fp.d.places { file_place_row(fp, p, marked, n, act); n += 1 }
		}
		if m != nil && len(m.recent) > 0 {
			spacer(px(em * 0.5))
			file_places_heading(i18n.tr("Recent"))
			for r in m.recent { file_place_row(fp, {path = r, icon = lucide.HISTORY}, "", n, act); n += 1 }
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
file_place_row :: proc(fp: ^File_Picker, p: platform.File_Place, marked: string, n: int, act: ^File_Action) {
	em := font_size()
	on := marked != "" && p.path == marked
	name := p.name != "" ? p.name : file_path_name(p.path, fp.sep)
	push_tags("list_row", "nav")
	defer pop_tags()
	if on { push_tags("selected") }
	defer if on { pop_tags() }
	next({width = fill(), height = px(dense(em * 1.9)), axis = .X, cross = .Center, radius = em * shape_of(.Row)})
	flags := Box_Flags{.Clickable, .Focusable, .Draw_Hot_Effects, .Row}
	if on { flags += {.Draw_Background, .Chosen} }
	b := build_box(flags, fmt.tprintf("###fb_place_%d", n))
	a11y_default(b, {role = .Link, name = name, description = p.path, current = on ? .Location : .False})
	sig := signal(b)
	if parent(b) {
		// (inside the face, inset in the row, past the accent's bar of the place shown)
		spacer(px(em * 0.75))
		icon(p.icon != "" ? p.icon : lucide.FOLDER, em * 1.5, nil, lucide_icons())
		spacer(px(em * 0.3))
		next({width = fill(), height = pct(1), text_pad = 0})
		label_tip(fmt.tprintf("%s###t", text_shown(name)))
	}
	if sig.clicked { act^ = {kind = .Go, path = strings.clone(p.path, context.temp_allocator)} }
}

// The list, or what stands in for it: a folder being read (after FILE_PICKER_SLOW_MS), empty, refused or failed.
@(private = "file")
file_picker_list :: proc(fp: ^File_Picker, act: ^File_Action) {
	s := gs()   // (the State it is built in: its owner's, or its own window's)
	em := font_size()
	file_picker_find_follow(fp)
	if file_picker_finds(fp) {
		file_picker_found_list(fp, act)
		return
	}
	if fp.new_folder { file_picker_new_row(fp, act) }
	switch {
	case remote.failed(&fp.listing):
		refused := fp.listing.state == .Refused
		next({width = fill(), height = fill()})
		title := refused ? i18n.tr("This folder may not be read") : i18n.tr("This folder could not be read")
		if empty_state("fb_failed", {icon = refused ? lucide.LOCK : lucide.ALERT_TRIANGLE, title = title, note = fp.listing.message,
			actions = {{text = i18n.tr("Try again"), icon = lucide.REFRESH_CW, intent = .Primary}}}) == 0 {
			act.kind = .Again
		}
		return
	case (fp.listing.state == .Loading || fp.listing.state == .Idle) && len(fp.entries) == 0:
		// (Idle: the computer's first folder is not known yet)
		waited := clock_ms(s) - fp.listing_ms
		next({width = fill(), height = fill(), axis = .Y, cross = .Center})
		if column(.Center, {}, "###fb_reading") {
			if waited >= FILE_PICKER_SLOW_MS {
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
				wake_within(s, int(FILE_PICKER_SLOW_MS - waited) + WAKE_MARGIN_MS)
			}
		}
		return
	case fp.listing.state == .Ready && len(fp.entries) == 0 && !fp.new_folder:
		next({width = fill(), height = fill()})
		empty_state("fb_empty", {icon = lucide.FOLDER_OPEN, title = i18n.tr("This folder is empty")})
		return
	}
	file_picker_rows(fp, false)
	empty := line_edit_string(&fp.filter) != "" ? i18n.tr("Nothing here matches the filter") : i18n.tr("Nothing here to show")
	file_picker_table(fp, act, empty)
}

// The rows' table, the folder's or the find's: a click on a title sorts them, Enter or a double click acts.
@(private = "file")
file_picker_table :: proc(fp: ^File_Picker, act: ^File_Action, empty: string) {
	s := gs()   // (the State it is built in: its owner's, or its own window's)
	fp.table.lead = file_row_lead
	fp.table.lead_user = fp
	fp.table.picture = file_card_picture
	next({width = fill(), height = fill()})
	a11y({name = i18n.tr("Files"), multiselectable = fp.table.vl.multi})
	ev := table_build("###fb_table", &fp.table, &fp.data, empty)
	// (after the cards: the thumbnails they asked go to the source, the newest first; the old ones go over the budget)
	thumb_cache_frame(&fp.thumbs, file_thumb_ask, fp)
	if ev.sorted { file_picker_rows(fp, true) }
	if ev.activated && act.kind == .None { act^ = {kind = .Activate, double = s.double_key != 0} }
	file_picker_row_menu(fp, ev, act)
	// the keyboard is the list's when the dialog shows (Save: the name's)
	if fp.focus_list && s.focus_key == 0 {
		if fp.kind == .Save && fp.name_key != 0 { s.focus_key = fp.name_key } else { s.focus_key = fp.table.vl.key }
		fp.focus_list = false
	}
}

// The find's rows (the toggle on and a query typed): what it found, best first, its path relative to the folder in the
// Name column; while the first answer is on its way, a line after FILE_PICKER_SLOW_MS; nothing found; its failure.
// The answer of the last query stays while the next one is asked: the list does not flash at each letter.
@(private = "file")
file_picker_found_list :: proc(fp: ^File_Picker, act: ^File_Action) {
	s := gs()   // (the State it is built in: its owner's, or its own window's)
	em := font_size()
	file_picker_rows(fp, false)   // (the find's rows, even empty: what the keys act on is what is shown)
	switch {
	case remote.failed(&fp.finding):
		next({width = fill(), height = fill()})
		empty_state("fb_find_failed", {icon = lucide.ALERT_TRIANGLE, title = i18n.tr("The search failed"), note = fp.finding.message})
		return
	case !remote.shows(&fp.finding):
		// (Idle: the query is not quiet yet; Loading: asked, no answer yet)
		waited := fp.finding.state == .Loading ? clock_ms(s) - fp.find_ms : 0
		next({width = fill(), height = fill(), axis = .Y, cross = .Center})
		if column(.Center, {}, "###fb_finding") {
			if waited >= FILE_PICKER_SLOW_MS {
				spacer(fill())
				spinner("###fb_finding_spinner", em * 1.6)
				spacer(px(em * 0.5))
				if tags("weak") {
					next({width = fill(), text_align = .Center})
					label(fmt.tprintf("%s###fb_finding_text", i18n.tr("Searching…")))
				}
				spacer(fill())
				a11y_default(parent_box(), {role = .Status, name = i18n.tr("Searching…"), busy = true, live = .Polite})
			} else if fp.finding.state == .Loading {
				wake_within(s, int(FILE_PICKER_SLOW_MS - waited) + WAKE_MARGIN_MS)
			}
		}
		return
	case fp.finding.state == .Ready && len(fp.found) == 0:
		next({width = fill(), height = fill()})
		empty_state("fb_found_none", {icon = lucide.SEARCH, title = i18n.tr("Nothing found.")})
		return
	}
	file_picker_table(fp, act, i18n.tr("Nothing found."))
}

// A row's icon, before its name: its kind's (a folder in the accent).
@(private = "file")
file_row_lead :: proc(t: ^Table, row: int, size: f32) {
	fp := (^File_Picker)(t.lead_user)
	e := file_row_entry(fp, row)
	if e == nil { return }
	look := file_entry_look(e^)
	tint: Maybe(Color)
	if look == .Folder { tint = color("accent") }
	icon(file_look_icon(look), size, tint, lucide_icons())
}

// A card's picture (Grid): the file's thumbnail once the source gave it, else the kind's icon (a folder's always; a
// source without thumbnails: always). Each card built asks for its own (thumb_cache_get); the asks go after the cards.
@(private = "file")
file_card_picture :: proc(t: ^Table, row: int, size: f32) {
	fp := (^File_Picker)(t.lead_user)
	e := file_row_entry(fp, row)
	if e == nil { return }
	if e.kind == .File && fp.source.thumbnail != nil {
		path := fsx.path_join(fp.folder, e.name, fp.sep, context.temp_allocator)
		// (the source's identity and generation in the key: a server's "/a.png" is not the computer's, nor another
		// server's behind the same source, nor its own picture changed since; thumbnails.md)
		key := fmt.tprintf("%p|%d|%s", fp.source.user, fp.source.generation, thumb_key(path, e.size, e.modified))
		// (the card's picture's longer side: its width, the height `size` being TABLE_CARD_PICTURE of it)
		th := thumb_cache_get(&fp.thumbs, key, path, size / TABLE_CARD_PICTURE)
		if th.state == .Ready && !th.refused {
			next({width = fill(), height = pct(1)})
			_ = thumb_picture("###thumb", th, font_size() * shape_of(.Row))
			return
		}
	}
	// (the icon at the card's share, as the table's own cards: at the rows' font size it is a dot in a large card)
	sz := table_card_icon_size(size)
	spacer(fill())
	if style({font_size = sz}) { file_row_lead(t, row, sz) }
	spacer(fill())
}

// An ask of the thumbnails' cache, to the source (its answer: file_reply_thumbnail, file_reply_failed).
@(private = "file")
file_thumb_ask :: proc(user: rawptr, path: string, side: int, ticket: u64) {
	fp := (^File_Picker)(user)
	// (an ask that waited from a dialog of another source: none to answer it, the slot is given back)
	if fp.source.thumbnail == nil {
		thumb_cache_failed(&fp.thumbs, ticket)
		return
	}
	fp.source.thumbnail(&fp.source, path, side, {state = fp.state, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .Thumbnail})
}

// The row of a new folder: its name, being typed; Enter makes it, Escape gives it up.
@(private = "file")
file_picker_new_row :: proc(fp: ^File_Picker, act: ^File_Action) {
	s := gs()   // (the State it is built in: its owner's, or its own window's)
	em := font_size()
	h := math.round(dense(em * TABLE_ROW_EM * 1.2))
	next({width = fill(), height = px(h), axis = .X, cross = .Center})
	if row(.Center, {}, "###fb_new_row") {
		spacer(px(em * 0.4))
		icon(lucide.FOLDER_PLUS, em * 1.5, color("accent"), lucide_icons())
		spacer(px(em * 0.4))
		next({width = fill(), height = px(h - em * 0.3)})
		a11y({name = i18n.tr("The new folder's name")})
		res := line_edit("###fb_new_name", &fp.new_name)
		if fp.new_key == 0 { s.focus_key = res.box.key }
		fp.new_key = res.box.key
		if res.committed && fp.making.state != .Loading { act.kind = .Make }
		if fp.making.state == .Loading {
			spacer(px(em * 0.4))
			spinner("###fb_making", em * 1.2)
		}
		spacer(px(em * 0.4))
	}
	if remote.failed(&fp.making) {
		if tags("bad") {
			next({width = fill(), text_pad = em * 0.6})
			paragraph(fmt.tprintf("%s###fb_making_error", text_shown(fp.making.message)))
		}
	}
}

// The request's choices (platform.File_Choice), in one row that wraps: a check box for a choice without options, else
// its label and a drop-down. Their values go with the answer.
@(private = "file")
file_picker_choices :: proc(fp: ^File_Picker, h: f32) {
	em := font_size()
	spacer(px(em * 0.6))
	next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
	if row(.Center, {}, "###fb_choices") {
		spacer(px(em * DIALOG_MARGIN_EM))
		for ch, i in fp.d.choices {
			if i >= len(fp.choice_values) { break }
			if i > 0 { spacer(px(em * 1.2)) }
			if len(ch.options) == 0 {
				on := fp.choice_values[i] == 1
				if checkbox(fmt.tprintf("###fb_choice_%d", i), fmt.tprintf("%s###fb_choice_text_%d", text_shown(ch.label), i), &on) {
					fp.choice_values[i] = on ? 1 : 0
				}
				continue
			}
			labels := make([]string, len(ch.options), context.temp_allocator)
			for o, k in ch.options { labels[k] = o.label != "" ? o.label : o.id }
			next({width = text_size(em * 0.6), height = px(h)})
			label(fmt.tprintf("%s###fb_choice_label_%d", text_shown(ch.label), i))
			next({width = px(em * 12), height = px(h)})
			_ = dropdown(fmt.tprintf("###fb_choice_%d", i), labels, &fp.choice_values[i])
		}
		spacer(px(em * DIALOG_MARGIN_EM))
	}
}

// The bottom: Save's name and the type list; New folder, Hidden files, Cancel and the act.
@(private = "file")
file_picker_bottom :: proc(fp: ^File_Picker, act: ^File_Action, act_word: string) {
	em := font_size()
	h := math.round(dense(em * 2.2))
	types := make([dynamic]string, context.temp_allocator)
	if fp.kind != .Folder {
		for f in fp.d.filters { append(&types, f.name != "" ? f.name : strings.join(f.patterns, ", ", context.temp_allocator)) }
		if fp.d.all_files && len(types) > 0 { append(&types, i18n.tr("All files")) }
	}
	show_types := len(types) > 1 || (fp.kind == .Save && len(types) > 0)
	if fp.kind == .Save || show_types {
		spacer(px(em * 0.6))
		next({width = fill(), height = px(h), axis = .X, cross = .Center})
		if row(.Center, {}, "###fb_naming") {
			spacer(px(em * DIALOG_MARGIN_EM))
			if fp.kind == .Save {
				next({width = text_size(em * 0.6), height = pct(1)})
				label(fmt.tprintf("%s###fb_name_label", i18n.tr("Name")))
				next({width = fill(), height = px(h)})
				a11y({name = i18n.tr("Name")})
				res := line_edit("###fb_name", &fp.name)
				fp.name_key = res.box.key
				if res.committed { act.kind = .Act }
				spacer(px(em * 0.6))
			} else {
				spacer(fill())
			}
			if show_types {
				next({width = text_size(em * 0.6), height = pct(1)})
				label(fmt.tprintf("%s###fb_type_label", i18n.tr("Type")))
				next({width = px(em * 14), height = px(h)})
				if dropdown("###fb_type", types[:], &fp.type_index) { file_picker_type_changed(fp) }
			}
			spacer(px(em * DIALOG_MARGIN_EM))
		}
	}
	if len(fp.d.choices) > 0 { file_picker_choices(fp, h) }
	spacer(px(em * 0.6))
	next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
	if row(.Center, {}, "###fb_buttons") {
		spacer(px(em * DIALOG_MARGIN_EM))
		if .Make_Folder in fp.source.caps && fp.source.make_folder != nil {
			if button("fb_new_folder", i18n.tr("New folder"), lucide.FOLDER_PLUS, {icon_font = lucide_icons(), tip = i18n.tr("Shift+Ctrl+N"), disabled = fp.folder == "" || remote.failed(&fp.listing)}).clicked {
				act.kind = .New_Folder
			}
			spacer(px(em * DIALOG_BUTTON_GAP_EM))
		}
		_ = checkbox("###fb_hidden", fmt.tprintf("%s###fb_hidden_text", i18n.tr("Hidden files")), &fp.hidden)
		spacer(fill())
		if button("fb_cancel", i18n.tr("Cancel"), lucide.X, {icon_font = lucide_icons()}).clicked { act.kind = .Cancel }
		spacer(px(em * DIALOG_BUTTON_GAP_EM))
		if button("fb_act", act_word, fp.kind == .Save ? lucide.SAVE : lucide.CHECK, {icon_font = lucide_icons(), intent = .Primary, disabled = !file_picker_can_act(fp)}).clicked {
			act.kind = .Act
		}
		spacer(px(em * DIALOG_MARGIN_EM))
	}
	spacer(px(em * DIALOG_MARGIN_EM))
}
