package ui

// The context menu of the file picker's rows (src/md/features/file-browser.md): the toolkit's own acts, then the
// program's (File_Dialog.row_actions). Copy path, name and relative path for every source; Open and Show in folder for
// the computer's files; Rename (the name edited in its row, Table.editing) and Move to the trash (its undo in a toast)
// for a source that has File_Source.rename / .trash. The file operations are the source's calls; their answers come
// back as File_Reply, as a listing's.
//
// Its machines, each a remote.Remote, dropped with the dialog (the reply's serial):
//   rename_call:  (fp.renaming: the field shown) -> Loading -> Ready (the field goes, the folder read again, the new name
//                 selected) | Failed (a toast; the field stays, to correct the name)
//   trash_call:   Loading -> Ready (a toast, with its undo when the source can restore; the folder read again) | Failed
//   restore_call: Loading -> Ready | Failed (a toast); the folder read again either way

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "../ascii"
import "../fsx"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import remote "../remote"

// The menu of a row's acts: one per picker (two pickers of a window build their own).
@(private = "file")
file_row_menu :: proc(fp: ^File_Picker) -> string { return fmt.tprintf("###fb_row_menu_%s", fp.instance) }

// The toolkit's acts the picker offers on `chosen` entries, as its source can do them and the program wants them.
@(private)
file_row_builtins :: proc(fp: ^File_Picker, chosen: int) -> (out: bit_set[platform.File_Row_Builtin; u8]) {
	if chosen == 0 { return }
	out = {.Copy_Path, .Copy_Name, .Copy_Relative_Path}
	// (one entry: a Ctrl+A is never three hundred windows, nor several names in one field)
	if chosen == 1 && file_source_is_local(&fp.source) { out += {.Open, .Reveal} }
	if chosen == 1 && fp.source.rename != nil { out += {.Rename} }
	if fp.source.trash != nil { out += {.Trash} }
	return out - fp.d.row_actions_off
}

// Whether the row menu offers "Open with": one file of the computer's, and Open offered.
@(private = "file")
file_row_opens_with :: proc(fp: ^File_Picker, offered: bit_set[platform.File_Row_Builtin; u8], chosen: []int) -> bool {
	return .Open in offered && len(chosen) == 1 && file_rows_entries(fp)[chosen[0]].kind == .File
}

// What an act says in the menu: its words, its icon, its key.
@(private = "file")
file_row_builtin_words :: proc(b: platform.File_Row_Builtin) -> (text, glyph, shortcut: string) {
	switch b {
	case .Copy_Path:          return i18n.tr("Copy path"), lucide.COPY, ""
	case .Copy_Name:          return i18n.tr("Copy name"), "", ""
	case .Copy_Relative_Path: return i18n.tr("Copy relative path"), "", ""
	// (not "Open": in an Open dialog that word is the dialog's own act, choosing the file)
	case .Open:               return i18n.tr("Open with its program"), lucide.EXTERNAL_LINK, ""
	case .Reveal:             return i18n.tr("Show in folder"), lucide.FOLDER_SEARCH, ""
	case .Rename:             return i18n.tr("Rename"), lucide.PENCIL, "F2"
	case .Trash:              return i18n.tr("Move to the trash"), lucide.TRASH_2, i18n.tr("key", "Delete")
	}
	return "", "", ""
}

// Whether the program's act `x` takes the entry `e`: a file, or a folder when it says so.
@(private = "file")
file_row_action_takes :: proc(x: platform.File_Row_Action, e: File_Entry) -> bool {
	return x.act != nil && (e.kind == .File || x.folders)
}

// The rows' context menu: a right click on a row (it is then selected), the Menu key or Shift+F10 opens it on the
// entries chosen. The copies, Open and Show in folder are done here (they change nothing of the picker); Rename and
// Move to the trash are asked of `act` (done after the dialog is built: an answer may change the entries); a program's
// act runs once per entry it takes, with the entry's path, and the dialog stays open.
@(private)
file_picker_row_menu :: proc(fp: ^File_Picker, ev: Table_Events, act: ^File_Action) {
	list := file_rows_entries(fp)
	chosen := file_picker_chosen(fp)
	offered := file_row_builtins(fp, len(chosen))
	if ev.menu && len(chosen) > 0 && !fp.renaming {
		programs := false
		for x in fp.d.row_actions {
			for k in chosen { if file_row_action_takes(x, list[k]) { programs = true } }
		}
		// (no `card` here: ui's card, the widget, hides the builtin)
		if offered != {} || programs {
			menu_open(file_row_menu(fp), ev.menu_at, from_keyboard = ev.keyboard)
			if file_source_is_local(&fp.source) && fp.state != nil && fp.state.window != nil {
				paths := make([dynamic]string, 0, len(chosen), context.temp_allocator)
				for k in chosen { append(&paths, fsx.path_join(fp.folder, list[k].name, fp.sep, context.temp_allocator)) }
				excluded := SHELL_MENU_DEFAULT_EXCLUDE
				shell_menu_query(&fp.shell, fp.state, {paths = paths[:], exclude_verbs = excluded[:]})
				fp.shell_was_open = true
			} else {
				shell_menu_clear(&fp.shell)
				fp.shell_was_open = false
			}
			if file_row_opens_with(fp, offered, chosen) {
				open_with_ask(&fp.open_with, fp.state, fsx.path_join(fp.folder, list[chosen[0]].name, fp.sep, context.temp_allocator))
			}
		}
	}
	if fp.shell_was_open && !menu_is_open(file_row_menu(fp)) {
		shell_menu_clear(&fp.shell)
		fp.shell_was_open = false
	}
	picked_builtin: Maybe(platform.File_Row_Builtin)
	picked := -1
	picked_with := false
	if menu(file_row_menu(fp)) {
		// (the groups, in their order: a separator between two that show)
		groups := [3]bit_set[platform.File_Row_Builtin; u8]{
			{.Copy_Path, .Copy_Name, .Copy_Relative_Path},
			{.Open, .Reveal},
			{.Rename, .Trash},
		}
		shown := false
		for group in groups {
			if group & offered == {} { continue }
			if shown { menu_separator() }
			shown = true
			for b in platform.File_Row_Builtin {
				if b not_in group || b not_in offered { continue }
				text, glyph, shortcut := file_row_builtin_words(b)
				if menu_item(fmt.tprintf("%s###fb_row_%v", text, b), shortcut, icon = glyph, icon_font = lucide_icons()).clicked { picked_builtin = b }
				// (beside Open: the applications of the file, read when the menu opened)
				if b == .Open && file_row_opens_with(fp, offered, chosen) {
					if menu_submenu(fmt.tprintf("%s###fb_row_open_with", i18n.tr("Open with")), lucide.APP_WINDOW) {
						if open_with_items(&fp.open_with, "fb_ow") { picked_with = true }
					}
				}
			}
		}
		separated := false
		for x, i in fp.d.row_actions {
			takes := false
			for k in chosen { if file_row_action_takes(x, list[k]) { takes = true; break } }
			if !takes { continue }
			if shown && !separated { menu_separator(); separated = true }
			if menu_item(fmt.tprintf("%s###fb_row_act_%d", x.label, i), icon = x.icon, icon_font = lucide_icons()).clicked { picked = i }
		}
		shell_menu_items(&fp.shell, "fb_shell", separator = shown || separated)
	}
	// (after the menu's block: an act runs once the menu is done)
	if picked_with {
		open_with_run(&fp.open_with)
		return
	}
	if b, ok := picked_builtin.?; ok {
		switch b {
		case .Copy_Path, .Copy_Name, .Copy_Relative_Path: file_picker_copy(fp, b, chosen)
		case .Open:   open(fsx.path_join(fp.folder, list[chosen[0]].name, fp.sep, context.temp_allocator), .Path)
		case .Reveal: open(fsx.path_join(fp.folder, list[chosen[0]].name, fp.sep, context.temp_allocator), .Reveal)
		case .Rename: act.kind = .Rename
		case .Trash:  act.kind = .Trash
		}
		return
	}
	if picked < 0 { return }
	// (the paths and the act copied first: an act may ask for another dialog, which frees these options and rows)
	x := fp.d.row_actions[picked]
	paths := make([dynamic]string, context.temp_allocator)
	for k in chosen {
		if file_row_action_takes(x, list[k]) { append(&paths, fsx.path_join(fp.folder, list[k].name, fp.sep, context.temp_allocator)) }
	}
	for p in paths { x.act(x.user, p) }
}

////////////////////////////////
// Copy

// The entries chosen on the clipboard, one line each, in the entries' order: their paths, their names, or their paths
// relative to the folder the dialog started in. (A copy writes the window's store: no wait.)
@(private = "file")
file_picker_copy :: proc(fp: ^File_Picker, what: platform.File_Row_Builtin, chosen: []int) {
	s := gs()   // (the State it is built in: its window's clipboard)
	if s.clipboard_set == nil { return }
	list := file_rows_entries(fp)
	b := strings.builder_make(context.temp_allocator)
	for k, i in chosen {
		if i > 0 { strings.write_byte(&b, '\n') }
		path := fsx.path_join(fp.folder, list[k].name, fp.sep, context.temp_allocator)
		#partial switch what {
		case .Copy_Path:          strings.write_string(&b, path)
		case .Copy_Name:          strings.write_string(&b, file_path_name(path, fp.sep))
		case .Copy_Relative_Path: strings.write_string(&b, file_path_relative(path, fp.start != "" ? fp.start : fp.folder, fp.sep))
		}
	}
	s.clipboard_set(strings.to_string(b))
}

// `path` relative to `folder` ("docs/a.md"; "." for the folder itself); a path outside it, whole.
@(private)
file_path_relative :: proc(path, folder: string, sep: u8) -> string {
	if !file_path_within(path, folder, sep) { return path }
	p, f := file_path_trim(path, sep), file_path_trim(folder, sep)
	rest := strings.trim_left(p[len(f):], string([]u8{sep}))
	return rest == "" ? "." : rest
}

////////////////////////////////
// Rename

// F2, or Rename in the menu: the entry chosen gets a field in place of its name, its name selected without its
// extension (a folder's: all of it).
@(private)
file_picker_rename_start :: proc(fp: ^File_Picker) {
	chosen := file_picker_chosen(fp)
	if .Rename not_in file_row_builtins(fp, len(chosen)) { return }
	e := file_rows_entries(fp)[chosen[0]]
	a := runtime.heap_allocator()
	context.allocator = a
	delete(fp.rename_name, a)
	fp.rename_name = strings.clone(e.name, a)
	name := file_path_name(e.name, fp.sep)
	line_edit_set(&fp.rename_edit, name)
	line_edit_select_all(&fp.rename_edit)
	if dot := strings.last_index_byte(name, '.'); dot > 0 && e.kind == .File { fp.rename_edit.mark, fp.rename_edit.cursor = 0, dot }
	fp.renaming, fp.rename_commit, fp.rename_key = true, false, 0   // (the field takes the keyboard when it is built)
	remote.reset(&fp.rename_call)
	fp.table.editing, fp.table.edit_id, fp.table.edit = true, file_row_id(e.name), file_row_rename_field
}

// The field of a rename, in the row or the card (Table.edit). Enter asks the source after the build.
@(private = "file")
file_row_rename_field :: proc(t: ^Table, row: int) {
	fp := (^File_Picker)(t.lead_user)
	s := gs()
	em := font_size()
	next({width = fill(), height = px(math.round(em * 1.6))})
	a11y({name = i18n.tr("The new name")})
	res := line_edit("###fb_rename", &fp.rename_edit)
	if fp.rename_key == 0 { s.focus_key = res.box.key }
	fp.rename_key = res.box.key
	if res.committed && fp.rename_call.state != .Loading { fp.rename_commit = true }
	if fp.rename_call.state == .Loading {
		spacer(px(em * 0.3))
		spinner("###fb_renaming", em * 1.1)
	}
}

// After the dialog's build: Enter asks the source; the keyboard gone elsewhere (a press outside) gives the rename up.
@(private)
file_picker_rename_follow :: proc(fp: ^File_Picker) {
	if !fp.renaming { return }
	if fp.rename_commit {
		fp.rename_commit = false
		file_picker_rename_ask(fp)
		return
	}
	s := gs()
	if fp.rename_key != 0 && s.focus_key != fp.rename_key && fp.rename_call.state != .Loading { file_picker_rename_end(fp) }
}

// The name typed asked of the source; the same name, or none, asks nothing; a separator is refused here, as a new
// folder's.
@(private = "file")
file_picker_rename_ask :: proc(fp: ^File_Picker) {
	name := strings.trim_space(line_edit_string(&fp.rename_edit))
	if name == "" || name == file_path_name(fp.rename_name, fp.sep) {
		file_picker_rename_end(fp)
		return
	}
	if strings.index_byte(name, fp.sep) >= 0 || strings.index_byte(name, '/') >= 0 {
		toast_add(.Warn, nil, nil, i18n.tr("A name has no separator in it."))
		return
	}
	if fp.source.rename == nil { return }
	a := runtime.heap_allocator()
	context.allocator = a
	// (a find's row is a path relative to the folder: the new one keeps its folder)
	up := file_path_parent(fp.rename_name, fp.sep)
	delete(fp.rename_to, a)
	fp.rename_to = up == "" ? strings.clone(name, a) : fsx.path_join(up, name, fp.sep, a)
	ticket := remote.begin(&fp.rename_call)
	path := fsx.path_join(fp.folder, fp.rename_name, fp.sep, context.temp_allocator)
	fp.source.rename(&fp.source, path, strings.clone(name, context.temp_allocator), {state = fp.state, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .Rename})
}

@(private)
file_picker_renamed :: proc(fp: ^File_Picker, ticket: u64) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fp.rename_call, ticket, .Ready) { return }
	to := strings.clone(fp.rename_to, context.temp_allocator)
	file_picker_rename_end(fp)
	file_picker_refresh(fp)
	file_picker_select_later(fp, to)
}

// The rename given up or done: the name again in its row, the keyboard back to the list.
@(private)
file_picker_rename_end :: proc(fp: ^File_Picker) {
	if !fp.renaming { return }
	a := runtime.heap_allocator()
	if current != nil && current.focus_key == fp.rename_key && fp.rename_key != 0 { current.focus_key = 0 }
	fp.renaming, fp.rename_commit, fp.rename_key = false, false, 0
	fp.table.editing = false
	delete(fp.rename_name, a); fp.rename_name = ""
	delete(fp.rename_to, a); fp.rename_to = ""
	context.allocator = a
	remote.reset(&fp.rename_call)
	fp.focus_list = true
}

////////////////////////////////
// Trash and its undo

// Delete, or Move to the trash in the menu: every entry chosen, in one call of the source.
@(private)
file_picker_trash :: proc(fp: ^File_Picker) {
	chosen := file_picker_chosen(fp)
	if .Trash not_in file_row_builtins(fp, len(chosen)) { return }
	list := file_rows_entries(fp)
	paths := make([]string, len(chosen), context.temp_allocator)
	for k, i in chosen { paths[i] = fsx.path_join(fp.folder, list[k].name, fp.sep, context.temp_allocator) }
	context.allocator = runtime.heap_allocator()
	ticket := remote.begin(&fp.trash_call)
	fp.source.trash(&fp.source, paths, {state = fp.state, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .Trash})
}

@(private)
file_picker_trashed :: proc(fp: ^File_Picker, ticket: u64, items: []File_Trashed, message: string) {
	a := runtime.heap_allocator()
	context.allocator = a
	if !remote.answer(&fp.trash_call, ticket, .Ready) { return }
	file_picker_refresh(fp)
	if len(items) == 0 {
		toast_add(.Bad, nil, nil, message, i18n.tr("Nothing was moved to the trash"))
		return
	}
	// (this trash's undo: only its items that can come back, only the last trash)
	file_trashed_clear(&fp.undo)
	for it in items {
		if it.token != "" { append(&fp.undo, File_Trashed{path = strings.clone(it.path, a), token = strings.clone(it.token, a)}) }
	}
	fp.state.files.trash_serial += 1   // (counted by the State: a toast finds its picker among all of them)
	fp.undo_serial, fp.undo_dialog = fp.state.files.trash_serial, fp.serial
	undo := len(fp.undo) > 0 && fp.source.restore != nil
	title := len(items) == 1 ? fmt.tprintf(i18n.tr("%s moved to the trash"), file_path_name(items[0].path, fp.sep)) : fmt.tprintf(i18n.tr(len(items), "%d item moved to the trash", "%d items moved to the trash"), len(items))
	body := message
	if undo { body = message != "" ? fmt.tprintf("%s %s", message, i18n.tr("Click to undo.")) : i18n.tr("Click to undo.") }
	action: proc(user: rawptr)
	if undo { action = file_picker_undo_clicked }
	// (the toast's user is the trash's serial, not a pointer: an older toast finds another serial and does nothing)
	toast_add(message != "" ? .Warn : .Info, action, rawptr(uintptr(fp.undo_serial)), body, title)
}

// A click on the trash's toast: its items back, while the request that trashed them is open (another may read another
// source).
@(private = "file")
file_picker_undo_clicked :: proc(user: rawptr) {
	// (the toast is the owner's: the trash's answer came at its build)
	if current == nil || current.files == nil { return }
	serial := u64(uintptr(user))
	fp: ^File_Picker
	for _, x in current.files.live { if x.undo_serial != 0 && x.undo_serial == serial { fp = x; break } }
	if fp == nil || !fp.open || fp.undo_dialog != fp.serial { return }
	if len(fp.undo) == 0 || fp.source.restore == nil { return }
	items := make([]File_Trashed, len(fp.undo), context.temp_allocator)
	for it, i in fp.undo { items[i] = {path = strings.clone(it.path, context.temp_allocator), token = strings.clone(it.token, context.temp_allocator)} }
	file_trashed_clear(&fp.undo)   // (once: a second click does nothing)
	fp.undo_serial = 0
	context.allocator = runtime.heap_allocator()
	ticket := remote.begin(&fp.restore_call)
	fp.source.restore(&fp.source, items, {state = fp.state, picker = fp.id, serial = fp.serial, ticket = ticket, kind = .Restore})
}

@(private)
file_picker_restored :: proc(fp: ^File_Picker, ticket: u64) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fp.restore_call, ticket, .Ready) { return }
	file_picker_refresh(fp)
}

// A rename, a trash or a restore that failed: said in a toast (the rename's field stays, to correct the name). A
// restore that failed for some of them read the folder again too.
@(private)
file_picker_row_failed :: proc(fp: ^File_Picker, kind: File_Reply_Kind, ticket: u64, message: string, refused: bool) {
	context.allocator = runtime.heap_allocator()
	state: remote.State = refused ? .Refused : .Failed
	#partial switch kind {
	case .Rename:
		if !remote.answer(&fp.rename_call, ticket, state, message) { return }
		fp.rename_key = 0   // (the field takes the keyboard again)
		toast_add(.Bad, nil, nil, message, i18n.tr("The name was not changed"))
	case .Trash:
		if !remote.answer(&fp.trash_call, ticket, state, message) { return }
		toast_add(.Bad, nil, nil, message, i18n.tr("Nothing was moved to the trash"))
		file_picker_refresh(fp)
	case .Restore:
		if !remote.answer(&fp.restore_call, ticket, state, message) { return }
		toast_add(.Bad, nil, nil, message, i18n.tr("Not everything was put back"))
		file_picker_refresh(fp)
	}
}

@(private)
file_trashed_clear :: proc(list: ^[dynamic]File_Trashed) {
	a := runtime.heap_allocator()
	for it in list { delete(it.path, a); delete(it.token, a) }
	clear(list)
}

// The folder read again after a change of its entries (its listing is the truth); a find shown is asked again too.
@(private)
file_picker_refresh :: proc(fp: ^File_Picker) {
	if !fp.open || fp.folder == "" { return }
	if file_picker_finds(fp) { file_picker_find_drop(fp) }   // (find_follow asks it again: its query is not the one found)
	file_picker_go(fp, fp.folder, .Again)
}

// Whether a name is the same as another but for its case (a rename that only changes it is let through).
@(private)
file_name_case_only :: proc(a, b: string) -> bool { return a != b && ascii.equal_fold(a, b) }
