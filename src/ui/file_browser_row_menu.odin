package ui

// The context menu of the file browser's rows (src/md/features/file-browser.md): the toolkit's own acts, then the
// program's (File_Dialog.row_actions). Copy path, name and relative path for every source; Open and Show in folder for
// the computer's files; Rename (the name edited in its row, Table.editing) and Move to the trash (its undo in a toast)
// for a source that has File_Source.rename / .trash. The file operations are the source's calls; their answers come
// back as File_Reply, as a listing's.
//
// Its machines, each a remote.Remote, dropped with the dialog (the reply's serial):
//   rename_call:  (fb.renaming: the field shown) -> Loading -> Ready (the field goes, the folder read again, the new name
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

// The menu of a row's acts.
FILE_ROW_MENU :: "###fb_row_menu"

// The toolkit's acts the browser offers on `chosen` entries, as its source can do them and the program wants them.
@(private)
file_row_builtins :: proc(fb: ^File_Browser, chosen: int) -> (out: bit_set[platform.File_Row_Builtin; u8]) {
	if chosen == 0 { return }
	out = {.Copy_Path, .Copy_Name, .Copy_Relative_Path}
	// (one entry: a Ctrl+A is never three hundred windows, nor several names in one field)
	if chosen == 1 && file_source_is_local(&fb.source) { out += {.Open, .Reveal} }
	if chosen == 1 && fb.source.rename != nil { out += {.Rename} }
	if fb.source.trash != nil { out += {.Trash} }
	return out - fb.d.row_actions_off
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
// entries chosen. The copies, Open and Show in folder are done here (they change nothing of the browser); Rename and
// Move to the trash are asked of `act` (done after the dialog is built: an answer may change the entries); a program's
// act runs once per entry it takes, with the entry's path, and the dialog stays open.
@(private)
file_browser_row_menu :: proc(fb: ^File_Browser, ev: Table_Events, act: ^File_Action) {
	list := file_rows_entries(fb)
	chosen := file_browser_chosen(fb)
	offered := file_row_builtins(fb, len(chosen))
	if ev.menu && len(chosen) > 0 && !fb.renaming {
		programs := false
		for x in fb.d.row_actions {
			for k in chosen { if file_row_action_takes(x, list[k]) { programs = true } }
		}
		// (no `card` here: ui's card, the widget, hides the builtin)
		if offered != {} || programs { menu_open(FILE_ROW_MENU, ev.menu_at, from_keyboard = ev.keyboard, search = false) }
	}
	picked_builtin: Maybe(platform.File_Row_Builtin)
	picked := -1
	if menu(FILE_ROW_MENU) {
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
			}
		}
		separated := false
		for x, i in fb.d.row_actions {
			takes := false
			for k in chosen { if file_row_action_takes(x, list[k]) { takes = true; break } }
			if !takes { continue }
			if shown && !separated { menu_separator(); separated = true }
			if menu_item(fmt.tprintf("%s###fb_row_act_%d", x.label, i), icon = x.icon, icon_font = lucide_icons()).clicked { picked = i }
		}
	}
	// (after the menu's block: an act runs once the menu is done)
	if b, ok := picked_builtin.?; ok {
		switch b {
		case .Copy_Path, .Copy_Name, .Copy_Relative_Path: file_browser_copy(fb, b, chosen)
		case .Open:   open(fsx.path_join(fb.folder, list[chosen[0]].name, fb.sep, context.temp_allocator), .Path)
		case .Reveal: open(fsx.path_join(fb.folder, list[chosen[0]].name, fb.sep, context.temp_allocator), .Reveal)
		case .Rename: act.kind = .Rename
		case .Trash:  act.kind = .Trash
		}
		return
	}
	if picked < 0 { return }
	// (the paths and the act copied first: an act may ask for another dialog, which frees these options and rows)
	x := fb.d.row_actions[picked]
	paths := make([dynamic]string, context.temp_allocator)
	for k in chosen {
		if file_row_action_takes(x, list[k]) { append(&paths, fsx.path_join(fb.folder, list[k].name, fb.sep, context.temp_allocator)) }
	}
	for p in paths { x.act(x.user, p) }
}

////////////////////////////////
// Copy

// The entries chosen on the clipboard, one line each, in the entries' order: their paths, their names, or their paths
// relative to the folder the dialog started in. (A copy writes the window's store: no wait.)
@(private = "file")
file_browser_copy :: proc(fb: ^File_Browser, what: platform.File_Row_Builtin, chosen: []int) {
	s := gs()   // (the State it is built in: its window's clipboard)
	if s.clipboard_set == nil { return }
	list := file_rows_entries(fb)
	b := strings.builder_make(context.temp_allocator)
	for k, i in chosen {
		if i > 0 { strings.write_byte(&b, '\n') }
		path := fsx.path_join(fb.folder, list[k].name, fb.sep, context.temp_allocator)
		#partial switch what {
		case .Copy_Path:          strings.write_string(&b, path)
		case .Copy_Name:          strings.write_string(&b, file_path_name(path, fb.sep))
		case .Copy_Relative_Path: strings.write_string(&b, file_path_relative(path, fb.start != "" ? fb.start : fb.folder, fb.sep))
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
file_browser_rename_start :: proc(fb: ^File_Browser) {
	chosen := file_browser_chosen(fb)
	if .Rename not_in file_row_builtins(fb, len(chosen)) { return }
	e := file_rows_entries(fb)[chosen[0]]
	a := runtime.heap_allocator()
	context.allocator = a
	delete(fb.rename_name, a)
	fb.rename_name = strings.clone(e.name, a)
	name := file_path_name(e.name, fb.sep)
	line_edit_set(&fb.rename_edit, name)
	line_edit_select_all(&fb.rename_edit)
	if dot := strings.last_index_byte(name, '.'); dot > 0 && e.kind == .File { fb.rename_edit.mark, fb.rename_edit.cursor = 0, dot }
	fb.renaming, fb.rename_commit, fb.rename_key = true, false, 0   // (the field takes the keyboard when it is built)
	remote.reset(&fb.rename_call)
	fb.table.editing, fb.table.edit_id, fb.table.edit = true, file_row_id(e.name), file_row_rename_field
}

// The field of a rename, in the row or the card (Table.edit). Enter asks the source after the build.
@(private = "file")
file_row_rename_field :: proc(t: ^Table, row: int) {
	fb := (^File_Browser)(t.lead_user)
	s := gs()
	em := font_size()
	next({width = fill(), height = px(math.round(em * 1.6))})
	a11y({name = i18n.tr("The new name")})
	res := line_edit("###fb_rename", &fb.rename_edit)
	if fb.rename_key == 0 { s.focus_key = res.box.key }
	fb.rename_key = res.box.key
	if res.committed && fb.rename_call.state != .Loading { fb.rename_commit = true }
	if fb.rename_call.state == .Loading {
		spacer(px(em * 0.3))
		spinner("###fb_renaming", em * 1.1)
	}
}

// After the dialog's build: Enter asks the source; the keyboard gone elsewhere (a press outside) gives the rename up.
@(private)
file_browser_rename_follow :: proc(fb: ^File_Browser) {
	if !fb.renaming { return }
	if fb.rename_commit {
		fb.rename_commit = false
		file_browser_rename_ask(fb)
		return
	}
	s := gs()
	if fb.rename_key != 0 && s.focus_key != fb.rename_key && fb.rename_call.state != .Loading { file_browser_rename_end(fb) }
}

// The name typed asked of the source; the same name, or none, asks nothing; a separator is refused here, as a new
// folder's.
@(private = "file")
file_browser_rename_ask :: proc(fb: ^File_Browser) {
	name := strings.trim_space(line_edit_string(&fb.rename_edit))
	if name == "" || name == file_path_name(fb.rename_name, fb.sep) {
		file_browser_rename_end(fb)
		return
	}
	if strings.index_byte(name, fb.sep) >= 0 || strings.index_byte(name, '/') >= 0 {
		toast_add(.Warn, nil, nil, i18n.tr("A name has no separator in it."))
		return
	}
	if fb.source.rename == nil { return }
	a := runtime.heap_allocator()
	context.allocator = a
	// (a find's row is a path relative to the folder: the new one keeps its folder)
	up := file_path_parent(fb.rename_name, fb.sep)
	delete(fb.rename_to, a)
	fb.rename_to = up == "" ? strings.clone(name, a) : fsx.path_join(up, name, fb.sep, a)
	ticket := remote.begin(&fb.rename_call)
	path := fsx.path_join(fb.folder, fb.rename_name, fb.sep, context.temp_allocator)
	fb.source.rename(&fb.source, path, strings.clone(name, context.temp_allocator), {state = fb.state, dialog = fb.serial, ticket = ticket, kind = .Rename})
}

@(private)
file_browser_renamed :: proc(fb: ^File_Browser, ticket: u64) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fb.rename_call, ticket, .Ready) { return }
	to := strings.clone(fb.rename_to, context.temp_allocator)
	file_browser_rename_end(fb)
	file_browser_refresh(fb)
	file_browser_select_later(fb, to)
}

// The rename given up or done: the name again in its row, the keyboard back to the list.
@(private)
file_browser_rename_end :: proc(fb: ^File_Browser) {
	if !fb.renaming { return }
	a := runtime.heap_allocator()
	if current != nil && current.focus_key == fb.rename_key && fb.rename_key != 0 { current.focus_key = 0 }
	fb.renaming, fb.rename_commit, fb.rename_key = false, false, 0
	fb.table.editing = false
	delete(fb.rename_name, a); fb.rename_name = ""
	delete(fb.rename_to, a); fb.rename_to = ""
	context.allocator = a
	remote.reset(&fb.rename_call)
	fb.focus_list = true
}

////////////////////////////////
// Trash and its undo

// Delete, or Move to the trash in the menu: every entry chosen, in one call of the source.
@(private)
file_browser_trash :: proc(fb: ^File_Browser) {
	chosen := file_browser_chosen(fb)
	if .Trash not_in file_row_builtins(fb, len(chosen)) { return }
	list := file_rows_entries(fb)
	paths := make([]string, len(chosen), context.temp_allocator)
	for k, i in chosen { paths[i] = fsx.path_join(fb.folder, list[k].name, fb.sep, context.temp_allocator) }
	context.allocator = runtime.heap_allocator()
	ticket := remote.begin(&fb.trash_call)
	fb.source.trash(&fb.source, paths, {state = fb.state, dialog = fb.serial, ticket = ticket, kind = .Trash})
}

@(private)
file_browser_trashed :: proc(fb: ^File_Browser, ticket: u64, items: []File_Trashed, message: string) {
	a := runtime.heap_allocator()
	context.allocator = a
	if !remote.answer(&fb.trash_call, ticket, .Ready) { return }
	file_browser_refresh(fb)
	if len(items) == 0 {
		toast_add(.Bad, nil, nil, message, i18n.tr("Nothing was moved to the trash"))
		return
	}
	// (this trash's undo: only its items that can come back, only the last trash)
	file_trashed_clear(&fb.undo)
	for it in items {
		if it.token != "" { append(&fb.undo, File_Trashed{path = strings.clone(it.path, a), token = strings.clone(it.token, a)}) }
	}
	fb.trash_serial += 1
	fb.undo_serial, fb.undo_dialog = fb.trash_serial, fb.serial
	undo := len(fb.undo) > 0 && fb.source.restore != nil
	title := len(items) == 1 ? fmt.tprintf(i18n.tr("%s moved to the trash"), file_path_name(items[0].path, fb.sep)) : fmt.tprintf(i18n.tr(len(items), "%d item moved to the trash", "%d items moved to the trash"), len(items))
	body := message
	if undo { body = message != "" ? fmt.tprintf("%s %s", message, i18n.tr("Click to undo.")) : i18n.tr("Click to undo.") }
	action: proc(user: rawptr)
	if undo { action = file_browser_undo_clicked }
	// (the toast's user is the trash's serial, not a pointer: an older toast finds another serial and does nothing)
	toast_add(message != "" ? .Warn : .Info, action, rawptr(uintptr(fb.undo_serial)), body, title)
}

// A click on the trash's toast: its items back, while the dialog that trashed them is open (another dialog may read
// another source).
@(private = "file")
file_browser_undo_clicked :: proc(user: rawptr) {
	if current == nil { return }
	fb := current.files   // (the toast is the owner's: the trash's answer came at its build)
	if fb == nil || !fb.open || fb.undo_serial == 0 || u64(uintptr(user)) != fb.undo_serial || fb.undo_dialog != fb.serial { return }
	if len(fb.undo) == 0 || fb.source.restore == nil { return }
	items := make([]File_Trashed, len(fb.undo), context.temp_allocator)
	for it, i in fb.undo { items[i] = {path = strings.clone(it.path, context.temp_allocator), token = strings.clone(it.token, context.temp_allocator)} }
	file_trashed_clear(&fb.undo)   // (once: a second click does nothing)
	fb.undo_serial = 0
	context.allocator = runtime.heap_allocator()
	ticket := remote.begin(&fb.restore_call)
	fb.source.restore(&fb.source, items, {state = fb.state, dialog = fb.serial, ticket = ticket, kind = .Restore})
}

@(private)
file_browser_restored :: proc(fb: ^File_Browser, ticket: u64) {
	context.allocator = runtime.heap_allocator()
	if !remote.answer(&fb.restore_call, ticket, .Ready) { return }
	file_browser_refresh(fb)
}

// A rename, a trash or a restore that failed: said in a toast (the rename's field stays, to correct the name). A
// restore that failed for some of them read the folder again too.
@(private)
file_browser_row_failed :: proc(fb: ^File_Browser, kind: File_Reply_Kind, ticket: u64, message: string, refused: bool) {
	context.allocator = runtime.heap_allocator()
	state: remote.State = refused ? .Refused : .Failed
	#partial switch kind {
	case .Rename:
		if !remote.answer(&fb.rename_call, ticket, state, message) { return }
		fb.rename_key = 0   // (the field takes the keyboard again)
		toast_add(.Bad, nil, nil, message, i18n.tr("The name was not changed"))
	case .Trash:
		if !remote.answer(&fb.trash_call, ticket, state, message) { return }
		toast_add(.Bad, nil, nil, message, i18n.tr("Nothing was moved to the trash"))
		file_browser_refresh(fb)
	case .Restore:
		if !remote.answer(&fb.restore_call, ticket, state, message) { return }
		toast_add(.Bad, nil, nil, message, i18n.tr("Not everything was put back"))
		file_browser_refresh(fb)
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
file_browser_refresh :: proc(fb: ^File_Browser) {
	if !fb.open || fb.folder == "" { return }
	if file_browser_finds(fb) { file_browser_find_drop(fb) }   // (find_follow asks it again: its query is not the one found)
	file_browser_go(fb, fb.folder, .Again)
}

// Whether a name is the same as another but for its case (a rename that only changes it is let through).
@(private)
file_name_case_only :: proc(a, b: string) -> bool { return a != b && ascii.equal_fold(a, b) }
