package ui

// The file tree's acts (src/md/features/tree-view.md, "The acts"): its menu (a right click on rows or under them, the
// Menu key, Shift+F10), its keys (file_tree_commands: a program puts them in its palette too), its file operations, its
// drags. Every operation runs on the chores; a failure is said in a toast with its reason, a trash's toast undoes it.
// The rows follow the disk through the watch; the folders an operation touched are read again at once.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import desktop "../desktop"
import "../ascii"
import "../fsx"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// The toolkit's acts on a file tree's entries.
File_Tree_Act :: enum u8 {
	New_File, New_Folder, Rename, Duplicate, Trash,
	Cut, Copy, Paste, Copy_Path, Copy_Relative_Path,
	Reveal, Open_With, Terminal,
	Expand, Collapse_All, Refresh,
}
File_Tree_Acts :: bit_set[File_Tree_Act; u32]

// A program's act in the menu, after the toolkit's: what it says, its icon, and what it does with the paths of the rows
// acted on (once, all of them). `folders`: offered on folders too (else on files only).
File_Tree_Action :: struct {
	label:   string,
	icon:    string,
	folders: bool,
	act:     proc(user: rawptr, paths: []string),
	user:    rawptr,
}

File_Tree_Acts_State :: struct {
	menu_paths:  [dynamic]string,   // (owned) what the open menu acts on (empty: the tree itself)
	menu_folder: string,            // (owned) where its New and Paste go
	open_with:   Open_With,
	undo:        [dynamic]File_Trashed,   // (owned) the last trash, to put back
	undo_serial: u64,
	paste_into:  string,            // (owned) where an asked paste goes
	drag_paths:  [dynamic]string,   // (owned) the paths of the rows dragged
	rename_path: string,            // (owned) the entry whose name is edited in its row
	new_path:    string,            // (owned) an entry made by New: its name is edited once its row shows
	ops:         int,               // operations under way
}

@(private)
file_tree_acts_destroy :: proc(t: ^File_Tree) {
	a := runtime.heap_allocator()
	file_tree_strings_clear(&t.menu_paths)
	delete(t.menu_paths)
	file_tree_strings_clear(&t.drag_paths)
	delete(t.drag_paths)
	file_trashed_clear(&t.undo)
	delete(t.undo)
	delete(t.menu_folder, a)
	delete(t.paste_into, a)
	delete(t.rename_path, a)
	delete(t.new_path, a)
	open_with_destroy(&t.open_with)
}

@(private = "file")
file_tree_strings_clear :: proc(list: ^[dynamic]string) {
	a := runtime.heap_allocator()
	for p in list { delete(p, a) }
	clear(list)
}

@(private = "file")
file_tree_set_string :: proc(s: ^string, v: string) {
	a := runtime.heap_allocator()
	delete(s^, a)
	s^ = strings.clone(v, a)
}

////////////////////////////////
// The commands

// The commands of a file tree, in the language in use (temp memory): their keys act while the tree has the keyboard
// (file_tree reads them); a program lists them in its palette and runs a choice with file_tree_command_run.
file_tree_commands :: proc(allocator := context.temp_allocator) -> []Command {
	out := make([]Command, len(File_Tree_Act), allocator)
	group := i18n.tr("Files")
	for act in File_Tree_Act {
		text, icon := file_tree_act_words(act)
		keys := file_tree_act_keys(act)
		out[int(act)] = {id = file_tree_act_id(act), label = text, group = group, icon = icon, keys = keys}
	}
	return out
}

// Does what command `id` of file_tree_commands says, on the rows selected (none: the tree's folder).
file_tree_command_run :: proc(t: ^File_Tree, id: string) {
	for act in File_Tree_Act {
		if file_tree_act_id(act) == id { file_tree_act_run(t, act, file_tree_targets(t)) }
	}
}

@(private = "file")
file_tree_act_id :: proc(act: File_Tree_Act) -> string {
	switch act {
	case .New_File:           return "file_tree.new_file"
	case .New_Folder:         return "file_tree.new_folder"
	case .Rename:             return "file_tree.rename"
	case .Duplicate:          return "file_tree.duplicate"
	case .Trash:              return "file_tree.trash"
	case .Cut:                return "file_tree.cut"
	case .Copy:               return "file_tree.copy"
	case .Paste:              return "file_tree.paste"
	case .Copy_Path:          return "file_tree.copy_path"
	case .Copy_Relative_Path: return "file_tree.copy_relative_path"
	case .Reveal:             return "file_tree.reveal"
	case .Open_With:          return "file_tree.open_with"
	case .Terminal:           return "file_tree.terminal"
	case .Expand:             return "file_tree.expand"
	case .Collapse_All:       return "file_tree.collapse_all"
	case .Refresh:            return "file_tree.refresh"
	}
	return ""
}

@(private = "file")
file_tree_act_words :: proc(act: File_Tree_Act) -> (text, icon: string) {
	switch act {
	case .New_File:           return i18n.tr("New file"), lucide.FILE_PLUS
	case .New_Folder:         return i18n.tr("New folder"), lucide.FOLDER_PLUS
	case .Rename:             return i18n.tr("Rename"), lucide.PENCIL
	case .Duplicate:          return i18n.tr("Duplicate"), lucide.COPY_PLUS
	case .Trash:              return i18n.tr("Move to the trash"), lucide.TRASH_2
	case .Cut:                return i18n.tr("Cut"), lucide.SCISSORS
	case .Copy:               return i18n.tr("Copy"), lucide.COPY
	case .Paste:              return i18n.tr("Paste"), lucide.CLIPBOARD_PASTE
	case .Copy_Path:          return i18n.tr("Copy path"), ""
	case .Copy_Relative_Path: return i18n.tr("Copy relative path"), ""
	case .Reveal:             return i18n.tr("Show in the file manager"), lucide.FOLDER_SEARCH
	case .Open_With:          return i18n.tr("Open with"), lucide.APP_WINDOW
	case .Terminal:           return i18n.tr("Open in a terminal"), lucide.SQUARE_TERMINAL
	case .Expand:             return i18n.tr("Expand all here"), lucide.LIST_TREE
	case .Collapse_All:       return i18n.tr("Collapse all"), lucide.LIST_COLLAPSE
	case .Refresh:            return i18n.tr("Refresh"), lucide.REFRESH_CW
	}
	return "", ""
}

@(private = "file")
file_tree_act_keys :: proc(act: File_Tree_Act) -> []Chord {
	one :: proc(c: Chord) -> []Chord {
		out := make([]Chord, 1, context.temp_allocator)
		out[0] = c
		return out
	}
	#partial switch act {
	case .Rename:             return one({.F2, {}})
	case .Trash:              return one({.Delete, {}})
	case .Cut:                return one({.X, {.Ctrl}})
	case .Copy:               return one({.C, {.Ctrl}})
	case .Paste:              return one({.V, {.Ctrl}})
	case .Copy_Path:          return one({.C, {.Alt, .Shift}})
	case .Copy_Relative_Path: return one({.C, {.Ctrl, .Alt, .Shift}})
	case .Reveal:             return one({.R, {.Alt, .Shift}})
	case .Refresh:            return one({.F5, {}})
	}
	return nil
}

////////////////////////////////
// Before the rows: the keys

// The keys of the tree and of its filter: Ctrl+F, typing (type_filters), each command's key while the rows have the
// keyboard.
@(private)
file_tree_keys :: proc(t: ^File_Tree) {
	s := gs()
	on_rows := t.key != 0 && s.focus_key == t.key
	in_filter := t.filter_key != 0 && s.focus_key == t.filter_key
	if (on_rows || in_filter) && key_press(.F, {.Ctrl}) { file_tree_filter_open(t) }
	if !on_rows || t.renaming || len(s.events.list) == 0 && len(s.typed) == 0 { return }
	if t.type_filters && !t.filter_open && len(s.typed) > 0 {
		b := strings.builder_make(context.temp_allocator)
		for r in s.typed { strings.write_rune(&b, r) }
		clear(&s.typed)
		file_tree_filter_open(t, strings.to_string(b))
	}
	for c, i in file_tree_commands() {
		act := File_Tree_Act(i)
		if len(c.keys) == 0 || act in t.acts_off { continue }
		if command_pressed(c) { file_tree_act_run(t, act, file_tree_targets(t)) }
	}
}

// The paths acted on: the rows selected, else the cursor's row (temp memory; none: the tree's folder).
@(private = "file")
file_tree_targets :: proc(t: ^File_Tree) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	ids := list_selected_ids(&t.list)
	if len(ids) > 0 {
		want := make(map[u64]struct{}, len(ids), context.temp_allocator)
		for id in ids { want[id] = {} }
		for r, i in t.file_rows { if r.id in want { append(&out, file_tree_path(t, i)) } }
	} else if t.sel >= 0 && t.sel < len(t.file_rows) {
		append(&out, file_tree_path(t, t.sel))
	}
	return out[:]
}

// Whether `path` is a folder, as the rows know it.
@(private = "file")
file_tree_is_folder :: proc(t: ^File_Tree, path: string) -> bool {
	if path == t.root { return true }
	parent := file_path_parent(path, LOCAL_SEPARATOR)
	f, ok := t.folders[parent]
	if !ok { f, ok = t.found[parent] }
	if !ok { return false }
	name := file_path_name(path, LOCAL_SEPARATOR)
	for e in f.entries { if e.name == name { return e.folder } }
	return false
}

// Where a New or a Paste on `paths` goes: the one folder acted on, else the folder of the first path, else the root.
@(private = "file")
file_tree_folder_for :: proc(t: ^File_Tree, paths: []string) -> string {
	if len(paths) == 0 { return t.root }
	if len(paths) == 1 && file_tree_is_folder(t, paths[0]) { return paths[0] }
	return file_path_parent(paths[0], LOCAL_SEPARATOR)
}

// An act of the toolkit on `paths` (none: the tree's folder).
@(private)
file_tree_act_run :: proc(t: ^File_Tree, act: File_Tree_Act, paths: []string) {
	s := gs()
	sep := u8(LOCAL_SEPARATOR)
	switch act {
	case .New_File, .New_Folder:
		folder := file_tree_folder_for(t, paths)
		name := act == .New_File ? i18n.tr("New file") : i18n.tr("New folder")
		file_tree_op(t, act == .New_File ? .New_File : .New_Folder, {folder}, name)
	case .Rename:
		if len(paths) != 1 { return }
		id := file_tree_id_of(t, paths[0])
		file_tree_set_string(&t.rename_path, paths[0])
		tree_rename_begin(&t.tree, id, file_path_name(paths[0], sep))
		if file_tree_is_folder(t, paths[0]) { line_edit_select_all(&t.rename_edit) }
	case .Duplicate:
		if len(paths) > 0 { file_tree_op(t, .Duplicate, paths, i18n.tr("copy")) }
	case .Trash:
		if len(paths) > 0 { file_tree_op(t, .Trash, paths) }
	case .Cut, .Copy:
		if len(paths) == 0 || s.window == nil { return }
		platform.clipboard_set(s.window, {files = paths, files_cut = act == .Cut, text = strings.join(paths, "\n", context.temp_allocator)})
	case .Paste:
		file_tree_set_string(&t.paste_into, file_tree_folder_for(t, paths))
		paste_request(t.key, {.Files})
	case .Copy_Path, .Copy_Relative_Path:
		if len(paths) == 0 || s.clipboard_set == nil { return }
		lines := make([]string, len(paths), context.temp_allocator)
		for p, i in paths { lines[i] = act == .Copy_Path ? p : file_path_relative(p, t.root, sep) }
		s.clipboard_set(strings.join(lines, "\n", context.temp_allocator))
	case .Reveal:
		open(len(paths) > 0 ? paths[0] : t.root, .Reveal)
	case .Open_With:
		// (the menu's submenu lists the programs: from a key, the system's own choice)
		if len(paths) == 1 { open(paths[0], .Path) }
	case .Terminal:
		file_tree_op(t, .Terminal, {file_tree_folder_for(t, paths)})
	case .Expand:
		folder := file_tree_folder_for(t, paths)
		file_tree_set_string(&t.expanding, folder)
		t.expanded = 0
		if folder != t.root { tree_set_open(&t.tree, file_tree_id_of(t, folder), true) }
		t.stale = true
	case .Collapse_All:
		clear(&t.open)
		t.open_version += 1
	case .Refresh:
		file_tree_refresh(t)
	}
}

////////////////////////////////
// After the rows: the menu, a rename, a drop, a paste

@(private = "file")
file_tree_menu_id :: proc(t: ^File_Tree) -> string { return fmt.tprintf("###ft_menu_%x", u64(t.key)) }

@(private)
file_tree_after :: proc(t: ^File_Tree) {
	s := gs()
	sep := u8(LOCAL_SEPARATOR)
	if t.cancelled && t.filter_open { file_tree_filter_close(t) }
	// the menu asked: what it acts on is kept while it is open
	if t.menu >= 0 || t.menu_empty {
		file_tree_strings_clear(&t.menu_paths)
		if !t.menu_empty {
			for p in file_tree_targets(t) { append(&t.menu_paths, strings.clone(p, runtime.heap_allocator())) }
		}
		file_tree_set_string(&t.menu_folder, file_tree_folder_for(t, t.menu_paths[:]))
		menu_open(file_tree_menu_id(t), t.menu_at, from_keyboard = t.menu_keyboard)
		if len(t.menu_paths) == 1 && !file_tree_is_folder(t, t.menu_paths[0]) { open_with_ask(&t.open_with, s, t.menu_paths[0]) }
	}
	file_tree_menu(t)
	// a rename's Enter: the entry renamed on the chores, a name this system refuses said at once
	if name, ok := t.renamed.?; ok && t.rename_path != "" {
		name = strings.trim_space(name)
		if name != "" && name != file_path_name(t.rename_path, sep) {
			if problem := file_name_problem(name); problem != .None {
				toast_add(.Warn, nil, nil, file_name_problem_words(problem, name), i18n.tr("Not renamed"))
			} else {
				file_tree_op(t, .Rename, {t.rename_path}, name)
			}
		}
		file_tree_set_string(&t.rename_path, "")
	}
	// an entry made by New: its name edited once its row shows
	if t.new_path != "" && !t.renaming {
		id := file_tree_id_of(t, t.new_path)
		for r in t.file_rows {
			if r.id != id { continue }
			file_tree_set_string(&t.rename_path, t.new_path)
			tree_rename_begin(&t.tree, id, file_path_name(t.new_path, sep))
			file_tree_set_string(&t.new_path, "")
			break
		}
	}
	file_tree_drags(t)
	// a paste's files, into the folder it was asked for
	if a, ok := paste_answer(t.key, {.Files}); ok && t.paste_into != "" && len(a.files) > 0 {
		file_tree_op(t, a.cut ? .Move : .Copy, a.files, i18n.tr("copy"), t.paste_into)
	}
}

// The menu of the rows acted on (or of the tree's folder): the toolkit's acts in groups, then the program's.
@(private = "file")
file_tree_menu :: proc(t: ^File_Tree) {
	paths := t.menu_paths[:]
	n := len(paths)
	picked: Maybe(File_Tree_Act)
	picked_action := -1
	picked_with := false
	if menu(file_tree_menu_id(t)) {
		// (what is offered, only while the menu is open: a folder's entries are looked through)
		one_file := n == 1 && !file_tree_is_folder(t, paths[0])
		offered: File_Tree_Acts
		offered += {.New_File, .New_Folder, .Paste, .Refresh, .Collapse_All, .Terminal, .Expand}
		if n > 0 { offered += {.Duplicate, .Trash, .Cut, .Copy, .Copy_Path, .Copy_Relative_Path} }
		if n == 1 { offered += {.Rename, .Reveal} }
		if one_file { offered += {.Open_With} }
		if n == 0 { offered += {.Reveal} }
		offered -= t.acts_off
		groups := [?]File_Tree_Acts{
			{.New_File, .New_Folder},
			{.Open_With, .Reveal, .Terminal},
			{.Cut, .Copy, .Paste, .Duplicate},
			{.Copy_Path, .Copy_Relative_Path},
			{.Rename, .Trash},
			{.Expand, .Collapse_All, .Refresh},
		}
		shown := false
		for g in groups {
			if g & offered == {} { continue }
			if shown { menu_separator() }
			shown = true
			for act in File_Tree_Act {
				if act not_in g || act not_in offered { continue }
				text, icon := file_tree_act_words(act)
				if act == .Open_With {
					if menu_submenu(fmt.tprintf("%s###ft_open_with", text), icon) {
						if open_with_items(&t.open_with, "ft_ow") { picked_with = true }
					}
					continue
				}
				keys := file_tree_act_keys(act)
				key_text := len(keys) > 0 ? chord_text(keys[0]) : ""
				if menu_item(fmt.tprintf("%s###ft_%v", text, act), key_text, icon = icon, icon_font = lucide_icons()).clicked { picked = act }
			}
		}
		separated := false
		for x, i in t.actions {
			if x.act == nil || n == 0 { continue }
			takes := x.folders
			if !takes { for p in paths { if !file_tree_is_folder(t, p) { takes = true; break } } }
			if !takes { continue }
			if shown && !separated { menu_separator(); separated = true }
			if menu_item(fmt.tprintf("%s###ft_act_%d", x.label, i), icon = x.icon, icon_font = lucide_icons()).clicked { picked_action = i }
		}
	}
	// (after the menu: an act runs once it is done)
	if picked_with { open_with_run(&t.open_with); return }
	if act, ok := picked.?; ok { file_tree_act_run(t, act, paths); return }
	if picked_action >= 0 {
		x := t.actions[picked_action]
		copied := make([]string, n, context.temp_allocator)
		for p, i in paths { copied[i] = strings.clone(p, context.temp_allocator) }
		x.act(x.user, copied)
	}
}

////////////////////////////////
// Drags: rows moved or copied between folders, out to other programs, other programs' files in

@(private = "file")
file_tree_drags :: proc(t: ^File_Tree) {
	s := gs()
	a := runtime.heap_allocator()
	// a drag began: its rows' paths kept
	if len(t.drag_rows) > 0 {
		file_tree_strings_clear(&t.drag_paths)
		want := make(map[u64]struct{}, len(t.drag_rows), context.temp_allocator)
		for id in t.drag_rows { want[id] = {} }
		for r, i in t.file_rows { if r.id in want { append(&t.drag_paths, file_tree_path(t, i, a)) } }
	}
	// let go over the tree: into the branch under it (Ctrl: copied)
	if t.dropped && len(t.drag_paths) > 0 {
		target := t.drop_row >= 0 ? file_tree_path(t, t.drop_row) : t.root
		file_tree_op(t, .Ctrl in s.mods ? .Copy : .Move, t.drag_paths[:], i18n.tr("copy"), target)
		file_tree_strings_clear(&t.drag_paths)
		tree_drop_leave(&t.tree)
	}
	// out of the window: the system's drag, with the files (it holds the thread until it ends)
	if t.dragging && len(t.drag_paths) > 0 && s.window != nil {
		m := s.mouse
		if m.x < 0 || m.y < 0 || m.x >= s.window_size.x || m.y >= s.window_size.y {
			t.dragging = false
			tree_drop_leave(&t.tree)
			d: platform.Drag_Data
			d.files = make([dynamic]string, 0, len(t.drag_paths), context.temp_allocator)
			for p in t.drag_paths { append(&d.files, p) }
			effect, ok := platform.drag_start(s.window, d, {.Copy, .Move})
			if e, done := effect.?; ok && done && e == .Move {
				for p in t.drag_paths { file_tree_dirty(t, file_path_parent(p, LOCAL_SEPARATOR)) }
			}
			file_tree_strings_clear(&t.drag_paths)
		}
	}
	// other programs' files over the tree
	if t.no_system_drops || s.window == nil { return }
	for e in build_events(s) {
		#partial switch e.kind {
		case .Drop_Enter, .Drop_Over:
			if _, over := tree_drop_target(&t.tree, e.pos); !over {
				if t.drop_outside { tree_drop_leave(&t.tree) }
				continue
			}
			tree_drop_hover(&t.tree, e.pos, true)
			platform.drop_set_effect(s.window, file_tree_drop_has_files(s.window) ? platform.drop_effect_for(e.drop_allowed, e.mods) : nil)
		case .Drop_Leave:
			tree_drop_leave(&t.tree)
		case .Drop:
			if !t.drop_outside { continue }
			target := t.drop_row >= 0 ? file_tree_path(t, t.drop_row) : t.root
			if d := platform.drop_data(s.window); d != nil && len(d.files) > 0 {
				effect := platform.drop_effect_for(e.drop_allowed, e.mods)
				move := false
				if x, ok := effect.?; ok { move = x == .Move }
				file_tree_op(t, move ? .Move : .Copy, d.files[:], i18n.tr("copy"), target)
			}
			platform.drop_data_release(s.window)
			tree_drop_leave(&t.tree)
		}
	}
}

// Whether a drag over the window brings files (Linux: the types it offers; Windows: its data, read when it came).
@(private = "file")
file_tree_drop_has_files :: proc(w: ^platform.Window) -> bool {
	if d := platform.drop_data(w); d != nil && len(d.files) > 0 { return true }
	for ty in platform.drop_types(w) { if ty == "text/uri-list" { return true } }
	return false
}

// A folder of the tree read again now (an operation changed it; the watch would tell it a little later).
@(private = "file")
file_tree_dirty :: proc(t: ^File_Tree, folder: string) {
	if f, ok := t.folders[folder]; ok { file_tree_mark_dirty(t, f) }
}

////////////////////////////////
// Names

// What makes a name unfit for an entry of a folder: none, or the first rule it breaks (file_name_problem).
File_Name_Problem :: enum u8 {
	None,
	Empty,            // "", or only spaces
	Dots,             // "." or ".."
	Separator,        // a "/" (and a "\" on Windows)
	Control,          // a control character (NUL among them)
	Windows_Char,     // one of < > : " | ? * (Windows)
	Windows_End,      // a dot or a space at its end (Windows drops them: another name than the one typed)
	Windows_Device,   // CON, PRN, AUX, NUL, COM0 to COM9, LPT0 to LPT9, CONIN$, CONOUT$, with or without an extension (Windows)
}

// What makes `name` unfit for a file or a folder of this system (`windows`: Windows' rules too): the system refuses it,
// or makes another name of it. Checked before an entry is named, so the person reads why at once.
file_name_problem :: proc(name: string, windows := ODIN_OS == .Windows) -> File_Name_Problem {
	if strings.trim_space(name) == "" { return .Empty }
	if name == "." || name == ".." { return .Dots }
	for i in 0 ..< len(name) {
		c := name[i]
		switch {
		case c == '/' || (windows && c == '\\'): return .Separator
		case c < 0x20 || c == 0x7f:              return .Control
		case windows && strings.index_byte(`<>:"|?*`, c) >= 0: return .Windows_Char
		}
	}
	if !windows { return .None }
	if last := name[len(name) - 1]; last == '.' || last == ' ' { return .Windows_End }
	// (the device's name is what comes before the first dot, spaces at its end dropped: "nul .txt" is NUL)
	stem := name
	if dot := strings.index_byte(stem, '.'); dot >= 0 { stem = stem[:dot] }
	stem = strings.trim_right(stem, " ")
	switch ascii.lower(stem) {
	case "con", "prn", "aux", "nul", "conin$", "conout$": return .Windows_Device
	}
	if len(stem) == 4 && stem[3] >= '0' && stem[3] <= '9' {
		switch ascii.lower(stem[:3]) {
		case "com", "lpt": return .Windows_Device
		}
	}
	return .None
}

// Why `name` is refused, in the language in use (temp memory).
@(private = "file")
file_name_problem_words :: proc(p: File_Name_Problem, name: string) -> string {
	switch p {
	case .None:           return ""
	case .Empty:          return i18n.tr("A name cannot be empty.")
	case .Dots:           return i18n.tr("A name cannot be a dot or two dots.")
	case .Separator:      return i18n.tr("A name has no separator in it.")
	case .Control:        return i18n.tr("A name has no control character in it.")
	case .Windows_Char:   return i18n.tr("A name on Windows has no < > : | ? * or double quote in it.")
	case .Windows_End:    return i18n.tr("A name on Windows does not end with a dot or a space.")
	case .Windows_Device: return fmt.tprintf(i18n.tr("Windows keeps the name %s for a device."), name)
	}
	return ""
}

////////////////////////////////
// The operations, on the chores

@(private = "file")
File_Tree_Op_Kind :: enum u8 { New_File, New_Folder, Rename, Duplicate, Trash, Restore, Copy, Move, Terminal }

@(private = "file")
File_Tree_Op :: struct {
	link:    ^File_Tree_Link,
	kind:    File_Tree_Op_Kind,
	paths:   []string,              // (heap) what it acts on (New, Terminal: the folder)
	name:    string,                // (heap) a new name (New: the first tried; Rename: the new; Duplicate: the word "copy")
	target:  string,                // (heap) Copy, Move: the folder they go in
	items:   [dynamic]File_Trashed, // Trash: what moved; Restore: what to put back
	made:    string,                // (heap) the entry made or renamed: revealed
	errors:  [dynamic]File_Tree_Failure,   // one per entry that failed
	touched: [dynamic]string,       // (heap) the folders it changed: read again
	done:    int,                   // entries done
}

@(private = "file")
file_tree_op :: proc(t: ^File_Tree, kind: File_Tree_Op_Kind, paths: []string, name := "", target := "", items: []File_Trashed = nil) {
	if t.link == nil { return }
	a := runtime.heap_allocator()
	op := new(File_Tree_Op, a)
	op.link, op.kind = t.link, kind
	op.paths = make([]string, len(paths), a)
	for p, i in paths { op.paths[i] = strings.clone(p, a) }
	op.name, op.target = strings.clone(name, a), strings.clone(target, a)
	for it in items { append(&op.items, File_Trashed{path = strings.clone(it.path, a), token = strings.clone(it.token, a)}) }
	sync.atomic_add(&t.link.refs, 1)
	t.ops += 1
	task(gs(), file_tree_op_work, file_tree_op_done, op, file_tree_op_lost)
}

@(private = "file")
file_tree_op_free :: proc(op: ^File_Tree_Op) {
	a := runtime.heap_allocator()
	for p in op.paths { delete(p, a) }
	delete(op.paths, a)
	delete(op.name, a)
	delete(op.target, a)
	delete(op.made, a)
	file_trashed_clear(&op.items)
	delete(op.items)
	for x in op.errors { delete(x.name, a) }
	delete(op.errors)
	for x in op.touched { delete(x, a) }
	delete(op.touched)
	file_tree_link_release(op.link)
	free(op, a)
}

@(private = "file")
file_tree_op_lost :: proc(d: rawptr) { file_tree_op_free((^File_Tree_Op)(d)) }

// A name free in `folder`: `name`, else "<stem> <word>.<ext>", "<stem> <word> 2.<ext>"... (`word` "": "<stem> 2"). A
// folder's name has no extension: "v1.2" gives "v1.2 copy".
@(private = "file")
file_tree_free_name :: proc(folder, name, word: string, first_taken := false, is_folder := false) -> string {
	sep := u8(LOCAL_SEPARATOR)
	if !first_taken && fsx.path_kind(fsx.path_join(folder, name, sep, context.temp_allocator)) == .Absent { return name }
	dot := is_folder ? -1 : strings.last_index_byte(name, '.')
	stem, ext := name, ""
	if dot > 0 { stem, ext = name[:dot], name[dot:] }
	for n in 1 ..< 10_000 {
		mid := word
		if n > 1 { mid = word == "" ? fmt.tprint(n) : fmt.tprintf("%s %d", word, n) }
		try := mid == "" ? name : fmt.tprintf("%s %s%s", stem, mid, ext)
		if fsx.path_kind(fsx.path_join(folder, try, sep, context.temp_allocator)) == .Absent { return try }
	}
	return name
}

// Why an entry failed: the system's error, or one the tree says (worded on the interface's thread, in its language).
@(private = "file")
File_Tree_Why :: enum u8 { System, Taken, No_Trash, No_Put_Back, Into_Itself, Not_Removed, No_Terminal }

@(private = "file")
File_Tree_Failure :: struct {
	name: string,   // (heap)
	why:  File_Tree_Why,
	err:  os.Error,
}

@(private = "file")
file_tree_op_failed :: proc(op: ^File_Tree_Op, path: string, err: os.Error, why := File_Tree_Why.System) {
	append(&op.errors, File_Tree_Failure{name = strings.clone(file_path_name(path, LOCAL_SEPARATOR), runtime.heap_allocator()), why = why, err = err})
}

@(private = "file")
file_tree_why_words :: proc(x: File_Tree_Failure) -> string {
	switch x.why {
	case .System:      return os.error_string(x.err)
	case .Taken:       return i18n.tr("an entry of that name is already there")
	case .No_Trash:    return i18n.tr("it could not be moved to the trash")
	case .No_Put_Back: return i18n.tr("it could not be put back")
	case .Into_Itself: return i18n.tr("a folder cannot go into itself")
	case .Not_Removed: return i18n.tr("copied, but the original could not be removed")
	case .No_Terminal: return i18n.tr("no terminal could be started")
	}
	return ""
}

@(private = "file")
file_tree_touch :: proc(op: ^File_Tree_Op, folder: string) {
	for x in op.touched { if x == folder { return } }
	append(&op.touched, strings.clone(folder, runtime.heap_allocator()))
}

@(private = "file")
file_tree_op_work :: proc(d: rawptr) {
	op := (^File_Tree_Op)(d)
	a := runtime.heap_allocator()
	context.allocator = a
	sep := u8(LOCAL_SEPARATOR)
	switch op.kind {
	case .New_File, .New_Folder:
		folder := op.paths[0]
		name := file_tree_free_name(folder, op.name, "")
		path := fsx.path_join(folder, name, sep, a)
		err: os.Error
		if op.kind == .New_Folder {
			err = os.make_directory(path)
		} else {
			f: ^os.File
			f, err = os.open(path, {.Write, .Create, .Excl})
			if err == nil { os.close(f) }
		}
		if err != nil { file_tree_op_failed(op, path, err); delete(path); break }
		op.made = path
		file_tree_touch(op, folder)
	case .Rename:
		from := op.paths[0]
		folder := file_path_parent(from, sep)
		to := fsx.path_join(folder, op.name, sep, a)
		// (never over another entry: on a disk that ignores case, "a" -> "A" finds the entry itself there; on one that
		// does not, "A" is another file, which a rename would replace)
		if fsx.path_kind(to) != .Absent && !fsx.same_entry(from, to) {
			file_tree_op_failed(op, from, nil, .Taken)
			delete(to)
			break
		}
		if err := os.rename(from, to); err != nil { file_tree_op_failed(op, from, err); delete(to); break }
		op.made = to
		file_tree_touch(op, folder)
	case .Duplicate:
		for p in op.paths {
			folder := file_path_parent(p, sep)
			name := file_tree_free_name(folder, file_path_name(p, sep), op.name, true, fsx.path_kind(p) == .Directory)
			dst := fsx.path_join(folder, name, sep, context.temp_allocator)
			if err := file_tree_copy(p, dst); err != nil { file_tree_op_failed(op, p, err); continue }
			if op.made == "" { op.made = strings.clone(dst) }
			file_tree_touch(op, folder)
			op.done += 1
		}
	case .Trash:
		for p in op.paths {
			in_trash, ok := platform.move_to_trash(p, a)
			if !ok { file_tree_op_failed(op, p, nil, .No_Trash); continue }
			append(&op.items, File_Trashed{path = strings.clone(p), token = in_trash})
			file_tree_touch(op, file_path_parent(p, sep))
			op.done += 1
		}
	case .Restore:
		for it in op.items {
			if !platform.put_back(it.token, it.path) { file_tree_op_failed(op, it.path, nil, .No_Put_Back); continue }
			file_tree_touch(op, file_path_parent(it.path, sep))
			op.done += 1
		}
	case .Copy, .Move:
		for p in op.paths {
			name := file_path_name(p, sep)
			from_folder := file_path_parent(p, sep)
			// (a folder moved onto its own row, a drag that came back: nothing to do; a copy into itself or a move into
			// one of its own folders: refused)
			if op.kind == .Move && file_path_trim(op.target, sep) == file_path_trim(p, sep) { continue }
			if file_path_within(op.target, p, sep) { file_tree_op_failed(op, p, nil, .Into_Itself); continue }
			if op.kind == .Move && file_path_trim(from_folder, sep) == file_path_trim(op.target, sep) { continue }
			dst_name := name
			if op.kind == .Copy { dst_name = file_tree_free_name(op.target, name, op.name, is_folder = fsx.path_kind(p) == .Directory) }
			dst := fsx.path_join(op.target, dst_name, sep, context.temp_allocator)
			if op.kind == .Move && fsx.path_kind(dst) != .Absent {
				file_tree_op_failed(op, p, nil, .Taken)
				continue
			}
			err: os.Error
			if op.kind == .Move {
				err = os.rename(p, dst)
				// (another volume, and only then: a copy, then the original removed; a rename refused for another
				// reason, a folder not writable, is said as it is, and nothing is copied)
				if err != nil && fsx.path_kind(p) != .Absent && !fsx.same_volume(p, op.target) {
					err = file_tree_copy(p, dst)
					if err == nil && !fsx.remove_tree(p) { file_tree_op_failed(op, p, nil, .Not_Removed) }
				}
			} else {
				err = file_tree_copy(p, dst)
			}
			if err != nil { file_tree_op_failed(op, p, err); continue }
			file_tree_touch(op, op.target)
			if op.kind == .Move { file_tree_touch(op, from_folder) }
			if op.made == "" { op.made = strings.clone(dst) }
			op.done += 1
		}
	case .Terminal:
		if !desktop.open_terminal(op.paths[0]) { file_tree_op_failed(op, op.paths[0], nil, .No_Terminal) }
	}
	free_all(context.temp_allocator)
}

// A file or a folder copied whole to `dst`, which is not there: a folder entry by entry, a link as a link (what it
// points to is not copied: a link to a folder above it would copy without end). On a failure what it made goes: no
// half copy is left beside the original.
@(private)
file_tree_copy :: proc(src, dst: string) -> os.Error {
	if fsx.path_kind(dst) != .Absent { return os.General_Error.Exist }
	err := file_tree_copy_entry(src, dst, fsx.path_kind(src))
	if err != nil { _ = fsx.remove_tree(dst) }
	return err
}

@(private = "file")
file_tree_copy_entry :: proc(src, dst: string, kind: fsx.Path_Kind) -> os.Error {
	sep := u8(LOCAL_SEPARATOR)
	kind := kind
	if kind == .Link {
		// (a reparse point that is no link, a cloud file on Windows, is the file or the folder it stands for)
		if target, err := os.read_link(src, context.temp_allocator); err == nil { return os.symlink(target, dst) }
		kind, _ = fsx.stat_follow(src)
	}
	#partial switch kind {
	case .Directory:
		entries, err := fsx.read_folder(src, context.temp_allocator)
		if err != nil { return err }
		if e := os.make_directory(dst); e != nil { return e }
		for e in entries {
			if x := file_tree_copy_entry(fsx.path_join(src, e.name, sep, context.temp_allocator), fsx.path_join(dst, e.name, sep, context.temp_allocator), e.kind); x != nil { return x }
		}
		return nil
	case .File:
		return os.copy_file(dst, src)
	}
	return os.General_Error.Not_Exist
}

// On the interface's thread: a failure said with its reasons; the folders touched read again; what was made
// revealed (New: its name edited); a trash's toast that undoes it.
@(private = "file")
file_tree_op_done :: proc(d: rawptr, _: u64) {
	op := (^File_Tree_Op)(d)
	defer file_tree_op_free(op)
	t := op.link.tree
	if t == nil { return }
	t.ops -= 1
	for f in op.touched { file_tree_dirty(t, f) }
	if len(op.errors) > 0 {
		title := ""
		switch op.kind {
		case .New_File:   title = i18n.tr("The file was not made")
		case .New_Folder: title = i18n.tr("The folder was not made")
		case .Rename:     title = i18n.tr("Not renamed")
		case .Duplicate:  title = i18n.tr("Not duplicated")
		case .Trash:      title = i18n.tr("Not moved to the trash")
		case .Restore:    title = i18n.tr("Not put back")
		case .Copy:       title = i18n.tr("Not copied")
		case .Move:       title = i18n.tr("Not moved")
		case .Terminal:   title = i18n.tr("No terminal")
		}
		lines := make([]string, len(op.errors), context.temp_allocator)
		for x, i in op.errors { lines[i] = fmt.tprintf("%s: %s", x.name, file_tree_why_words(x)) }
		toast_add(.Bad, nil, nil, strings.join(lines, "\n", context.temp_allocator), title)
	}
	if op.made != "" {
		file_tree_reveal(t, op.made)
		if op.kind == .New_File || op.kind == .New_Folder { file_tree_set_string(&t.new_path, op.made) }
	}
	if op.kind == .Trash && len(op.items) > 0 { file_tree_trashed(t, op.items[:]) }
}

// A trash that moved `items`: its toast, a click on it puts them back (the last trash only).
@(private = "file")
file_tree_trashed :: proc(t: ^File_Tree, items: []File_Trashed) {
	s := gs()
	a := runtime.heap_allocator()
	file_trashed_clear(&t.undo)
	for it in items {
		if it.token != "" { append(&t.undo, File_Trashed{path = strings.clone(it.path, a), token = strings.clone(it.token, a)}) }
	}
	s.file_tree_serial += 1
	t.undo_serial = s.file_tree_serial
	title := len(items) == 1 ? fmt.tprintf(i18n.tr("%s moved to the trash"), file_path_name(items[0].path, LOCAL_SEPARATOR)) : fmt.tprintf(i18n.tr(len(items), "%d item moved to the trash", "%d items moved to the trash"), len(items))
	action: proc(user: rawptr)
	body := ""
	if len(t.undo) > 0 {
		action = file_tree_undo_clicked
		body = i18n.tr("Click to undo.")
	}
	// (its user is the trash's serial, not a pointer: an older toast, or one of a tree gone, finds nothing)
	toast_add(.Info, action, rawptr(uintptr(t.undo_serial)), body, title)
}

@(private = "file")
file_tree_undo_clicked :: proc(user: rawptr) {
	if current == nil { return }
	serial := u64(uintptr(user))
	for t in current.file_trees {
		if t.undo_serial != serial || serial == 0 || len(t.undo) == 0 { continue }
		file_tree_op(t, .Restore, nil, items = t.undo[:])
		file_trashed_clear(&t.undo)
		t.undo_serial = 0
		return
	}
}

// The last trash put back (Ctrl+Z of a program's own): false when there is none.
file_tree_undo :: proc(t: ^File_Tree) -> bool {
	if len(t.undo) == 0 { return false }
	file_tree_op(t, .Restore, nil, items = t.undo[:])
	file_trashed_clear(&t.undo)
	t.undo_serial = 0
	return true
}
