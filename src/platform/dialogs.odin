package platform

// The system's file dialogs and shell actions, behind an API of our own (Windows: dialogs_win32.odin, IFileOpenDialog /
// IFileSaveDialog and ShellExecuteExW; other systems: dialogs_stub.odin answers "not supported").
//
//   * open_file_dialog / save_file_dialog / pick_folder_dialog show a modal dialog and return when the user closed it:
//     call them from a thread that may block (a worker of the app's blocking pool), never from the frame loop. The owner
//     window is disabled meanwhile, as the system does.
//   * open_url, open_path and reveal_in_folder hand a URL or a file to the system (its browser, the application of the
//     file's type, the file manager with the file selected).
//   * move_to_trash and put_back (trash.odin) move a file to the system's trash and back.
//
// Filters are pure data (`File_Filter`: a name and patterns such as "*.png"); filter_patterns, filter_matches and
// filters_from_accept are the logic every implementation shares, tested without a desktop.

import "base:runtime"
import "core:strings"

// A folder the system names (WICG File System Access "WellKnownDirectory" and the like). known_folder_path gives its path
// as the person's desktop names it (Windows: SHGetKnownFolderPath; Linux: user-dirs.dirs, read once and kept,
// known_folder_linux.odin): it asks the system, so call it from a task.
Known_Folder :: enum u8 { None, Desktop, Documents, Downloads, Music, Pictures, Videos, Home }

// One line of a dialog's file type list: "Images" with "*.png", "*.jpg".
File_Filter :: struct {
	name:     string,
	patterns: []string,   // "*.ext" (or "*" / "*.*" for anything); an extension without "*." is accepted too
}

// What a file dialog asks: files to open, a name to save under, a folder.
File_Dialog_Kind :: enum u8 { Open, Save, Folder }

// A question beside the files (the XDG portal's "choices": an encoding, "Open read-only"): a list of options, or a check
// box when it has none. The toolkit's file picker shows them; the system's dialogs do not.
File_Choice :: struct {
	id:      string,
	label:   string,
	options: []File_Choice_Option,   // empty: a check box
	initial: string,                 // the option chosen first (its id; "": the first); a check box: "true" or "false"
}

File_Choice_Option :: struct { id, label: string }

// A choice's value in the answer: an option's id, or "true" or "false" for a check box.
File_Choice_Answer :: struct { id, value: string }

// A request for a file picker as a plain value, apart from any interface: what a host serves (the toolkit's picker,
// the system's dialog, a program that answers the XDG portal or a command line). The answer is a Dialog_Result.
File_Request :: struct {
	kind:   File_Dialog_Kind,
	dialog: File_Dialog,
}

File_Dialog :: struct {
	owner:          ^Window,        // nil: no owner
	title:          string,         // "" : the system's
	filters:        []File_Filter,
	all_files:      bool,           // a last "All files (*.*)" line
	filter_index:   int,            // the line selected first
	start_dir:      string,         // a folder to start in ("" : the system remembers per `remember_id`, else start_known)
	start_known:    Known_Folder,
	remember_id:    string,         // the system keeps the last folder of dialogs with this id ("" : the app's default)
	suggested_name: string,         // save: the proposed file name
	default_ext:    string,         // save: appended when the user types none ("txt", without the dot)
	multiple:       bool,           // open: several files
	overwrite_prompt: bool,         // save: ask before replacing a file (the system's question)
	places:         []File_Place,   // the program's own places, after the source's (the toolkit's file browser; the
	                                // system's dialogs do not show them)
	find_deep:      bool,           // the toolkit's file browser: its filter starts searching the subfolders too
	act:            string,         // the toolkit's file browser: the act button's word ("": the mode's, Open, Choose, Save)
	row_actions:    []File_Row_Action,   // the toolkit's file browser: the program's acts in an entry's context menu
	row_actions_off: bit_set[File_Row_Builtin; u8],   // the toolkit's file browser: its own acts this dialog does not offer
	choices:        []File_Choice,  // the toolkit's file picker: questions beside the files, answered in Dialog_Result.choices
}

// A copy of `d`, every string and slice in `allocator` (the owner window and the row actions' procedures are the
// caller's). file_dialog_free frees it.
file_dialog_clone :: proc(d: File_Dialog, allocator := context.allocator) -> File_Dialog {
	a := allocator
	c := d
	c.title = strings.clone(d.title, a)
	c.start_dir = strings.clone(d.start_dir, a)
	c.remember_id = strings.clone(d.remember_id, a)
	c.suggested_name = strings.clone(d.suggested_name, a)
	c.default_ext = strings.clone(d.default_ext, a)
	c.act = strings.clone(d.act, a)
	filters := make([]File_Filter, len(d.filters), a)
	for f, i in d.filters {
		patterns := make([]string, len(f.patterns), a)
		for x, k in f.patterns { patterns[k] = strings.clone(x, a) }
		filters[i] = File_Filter{name = strings.clone(f.name, a), patterns = patterns}
	}
	c.filters = filters
	places := make([]File_Place, len(d.places), a)
	for p, i in d.places { places[i] = {name = strings.clone(p.name, a), path = strings.clone(p.path, a), icon = strings.clone(p.icon, a)} }
	c.places = places
	actions := make([]File_Row_Action, len(d.row_actions), a)
	for x, i in d.row_actions {
		actions[i] = x
		actions[i].label = strings.clone(x.label, a)
		actions[i].icon = strings.clone(x.icon, a)
	}
	c.row_actions = actions
	choices := make([]File_Choice, len(d.choices), a)
	for ch, i in d.choices {
		options := make([]File_Choice_Option, len(ch.options), a)
		for o, k in ch.options { options[k] = {id = strings.clone(o.id, a), label = strings.clone(o.label, a)} }
		choices[i] = {id = strings.clone(ch.id, a), label = strings.clone(ch.label, a), options = options, initial = strings.clone(ch.initial, a)}
	}
	c.choices = choices
	return c
}

// Frees what file_dialog_clone made (in the same allocator), and zeroes `d`.
file_dialog_free :: proc(d: ^File_Dialog, allocator := context.allocator) {
	a := allocator
	delete(d.title, a); delete(d.start_dir, a); delete(d.remember_id, a)
	delete(d.suggested_name, a); delete(d.default_ext, a); delete(d.act, a)
	for f in d.filters {
		delete(f.name, a)
		for x in f.patterns { delete(x, a) }
		delete(f.patterns, a)
	}
	delete(d.filters, a)
	for p in d.places { delete(p.name, a); delete(p.path, a); delete(p.icon, a) }
	delete(d.places, a)
	for x in d.row_actions { delete(x.label, a); delete(x.icon, a) }
	delete(d.row_actions, a)
	for ch in d.choices {
		delete(ch.id, a); delete(ch.label, a); delete(ch.initial, a)
		for o in ch.options { delete(o.id, a); delete(o.label, a) }
		delete(ch.options, a)
	}
	delete(d.choices, a)
	d^ = {}
}

// The toolkit's own acts in an entry's context menu of its file browser, before the program's (File_Row_Action). Each is
// offered when the dialog's source can do it; File_Dialog.row_actions_off removes the ones a program does not want.
File_Row_Builtin :: enum u8 {
	Copy_Path,            // every source
	Copy_Name,
	Copy_Relative_Path,   // relative to the folder the dialog started in
	Open,                 // the computer's files: with the system's program
	Reveal,               // the computer's files: shown selected in the system's file manager
	Rename,               // a source with File_Source.rename
	Trash,                // a source with File_Source.trash
}

// A program's act on an entry of the toolkit's file browser (File_Dialog.row_actions), in the entry's context menu
// (a right click, the Menu key): "Download". `act` runs on the interface's thread, once per entry chosen (a multiple
// selection gives each), with the entry's path in the source's form (valid during the call only); the dialog stays
// open. It must not block: a download starts a task. The system's dialogs do not show them.
File_Row_Action :: struct {
	label:   string,
	icon:    string,   // a glyph of the Lucide icons ("": none)
	folders: bool,     // offered on a folder too (false: on files only)
	act:     proc(user: rawptr, path: string),
	user:    rawptr,
}

// A folder a file dialog lists among its places, to go to at once.
File_Place :: struct {
	name: string,   // as shown ("Home"); "": the path's last part
	path: string,
	icon: string,   // a glyph of the Lucide icons ("": a folder's)
}

Dialog_Status :: enum u8 { Chosen, Cancelled, Unsupported, Failed }

// What the dialog gave: the chosen paths (allocated with the allocator given; dialog_result_destroy frees them).
Dialog_Result :: struct {
	status:  Dialog_Status,
	paths:   []string,
	filter:  int,                    // the type line selected when the user closed it
	choices: []File_Choice_Answer,   // per File_Dialog.choices, in their order (the system's dialogs: none)
}

dialog_result_destroy :: proc(r: ^Dialog_Result, allocator := context.allocator) {
	for p in r.paths { delete(p, allocator) }
	delete(r.paths, allocator)
	for c in r.choices { delete(c.id, allocator); delete(c.value, allocator) }
	delete(r.choices, allocator)
	r^ = {}
}

// A copy of `r` in `allocator` (dialog_result_destroy frees it).
dialog_result_clone :: proc(r: Dialog_Result, allocator := context.allocator) -> Dialog_Result {
	c := r
	c.paths = make([]string, len(r.paths), allocator)
	for p, i in r.paths { c.paths[i] = strings.clone(p, allocator) }
	c.choices = make([]File_Choice_Answer, len(r.choices), allocator)
	for x, i in r.choices { c.choices[i] = {id = strings.clone(x.id, allocator), value = strings.clone(x.value, allocator)} }
	return c
}

// The patterns of a filter joined as the systems want them ("*.png;*.jpg"); a bare extension ("png", ".png") becomes
// "*.png"; an empty list is "*.*".
filter_patterns :: proc(f: File_Filter, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	n := 0
	for raw in f.patterns {
		p := strings.trim_space(raw)
		if p == "" { continue }
		if n > 0 { strings.write_byte(&b, ';') }
		switch {
		case p == "*" || p == "*.*": strings.write_string(&b, "*.*")
		case strings.has_prefix(p, "*"): strings.write_string(&b, p)
		case strings.has_prefix(p, "."): strings.write_byte(&b, '*'); strings.write_string(&b, p)
		case: strings.write_string(&b, "*."); strings.write_string(&b, p)
		}
		n += 1
	}
	if n == 0 { strings.write_string(&b, "*.*") }
	return strings.to_string(b)
}

// Whether a file name matches one of the filters (case-insensitive "*.ext" and "*", as the dialogs match).
filter_matches :: proc(filters: []File_Filter, name: string) -> bool {
	if len(filters) == 0 { return true }
	for f in filters {
		pats := filter_patterns(f, context.temp_allocator)
		rest := pats
		for p in strings.split_iterator(&rest, ";") {
			if p == "*.*" || p == "*" { return true }
			if strings.has_prefix(p, "*.") {
				ext := p[1:]   // ".png"
				if len(name) > len(ext) && strings.equal_fold(name[len(name) - len(ext):], ext) { return true }
			} else if strings.equal_fold(p, name) {
				return true
			}
		}
	}
	return false
}

// A filter per entry of a web page's description of what it accepts (File System Access "types": a description and
// MIME types with their extensions; an <input type=file accept> list). `entries`: (description, MIME type or "",
// extensions such as ".png"). Entries without extensions add none; a MIME type alone adds what `mime_extensions` knows
// for it (the app's table: nil for none).
Accept_Entry :: struct {
	description: string,
	mime:        string,
	extensions:  []string,
}

filters_from_accept :: proc(entries: []Accept_Entry, mime_extensions: proc(mime: string) -> []string = nil, allocator := context.allocator) -> []File_Filter {
	out := make([dynamic]File_Filter, allocator)
	for e in entries {
		pats := make([dynamic]string, allocator)
		for x in e.extensions {
			p := strings.trim_space(x)
			if p == "" { continue }
			append(&pats, strings.concatenate({"*", strings.has_prefix(p, ".") ? "" : ".", p}, allocator))
		}
		if len(pats) == 0 && e.mime != "" && mime_extensions != nil {
			for x in mime_extensions(e.mime) { append(&pats, strings.concatenate({"*", strings.has_prefix(x, ".") ? "" : ".", x}, allocator)) }
		}
		if len(pats) == 0 { delete(pats); continue }
		name := e.description
		if name == "" { name = e.mime != "" ? e.mime : strings.join(pats[:], ", ", context.temp_allocator) }
		append(&out, File_Filter{name = strings.clone(name, allocator), patterns = pats[:]})
	}
	return out[:]
}

filters_destroy :: proc(filters: []File_Filter, allocator := context.allocator) {
	for f in filters {
		delete(f.name, allocator)
		for p in f.patterns { delete(p, allocator) }
		delete(f.patterns, allocator)
	}
	delete(filters, allocator)
}

// The kinds of dialog (dialog_test_hook's `kind`).
DIALOG_OPEN :: 0
DIALOG_SAVE :: 1
DIALOG_FOLDER :: 2

// Test hook: when set, the dialogs answer with it instead of showing anything (end-to-end tests of an app: the real
// dialogs need a person). `kind`: DIALOG_OPEN, DIALOG_SAVE, DIALOG_FOLDER.
dialog_test_hook: proc(kind: int, d: File_Dialog, allocator: runtime.Allocator) -> Dialog_Result
