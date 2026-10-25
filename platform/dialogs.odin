package platform

// The system's file dialogs and shell actions, behind an API of our own (Windows: dialogs_win32.odin, IFileOpenDialog /
// IFileSaveDialog and ShellExecuteExW; other systems: dialogs_stub.odin answers "not supported").
//
//   * open_file_dialog / save_file_dialog / pick_folder_dialog show a modal dialog and return when the user closed it:
//     call them from a thread that may block (a worker of the app's blocking pool), never from the frame loop. The owner
//     window is disabled meanwhile, as the system does.
//   * open_url, open_path and reveal_in_folder hand a URL or a file to the system (its browser, the application of the
//     file's type, the file manager with the file selected).
//
// Filters are pure data (`File_Filter`: a name and patterns such as "*.png"); filter_patterns, filter_matches and
// filters_from_accept are the logic every implementation shares, tested without a desktop.

import "base:runtime"
import "core:strings"

// A folder the system names (WICG File System Access "WellKnownDirectory" and the like).
Known_Folder :: enum u8 { None, Desktop, Documents, Downloads, Music, Pictures, Videos, Home }

// One line of a dialog's file type list: "Images" with "*.png", "*.jpg".
File_Filter :: struct {
	name:     string,
	patterns: []string,   // "*.ext" (or "*" / "*.*" for anything); an extension without "*." is accepted too
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
}

Dialog_Status :: enum u8 { Chosen, Cancelled, Unsupported, Failed }

// What the dialog gave: the chosen paths (allocated with the allocator given; dialog_result_destroy frees them).
Dialog_Result :: struct {
	status: Dialog_Status,
	paths:  []string,
	filter: int,          // the type line selected when the user closed it
}

dialog_result_destroy :: proc(r: ^Dialog_Result, allocator := context.allocator) {
	for p in r.paths { delete(p, allocator) }
	delete(r.paths, allocator)
	r^ = {}
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

// Test hook: when set, the dialogs answer with it instead of showing anything (end-to-end tests of an app: the real
// dialogs need a person). `kind`: 0 open, 1 save, 2 folder.
dialog_test_hook: proc(kind: int, d: File_Dialog, allocator: runtime.Allocator) -> Dialog_Result
