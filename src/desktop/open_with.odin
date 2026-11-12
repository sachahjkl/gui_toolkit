package tk_desktop

// "Open with": the applications the system knows for a type of file, and a file opened with one of them. Linux reads
// the XDG specifications (shared-mime-info for the type, the desktop entries' MimeType, mimeapps.list for the default
// and the user's own associations); Windows asks the shell (SHAssocEnumHandlers). Opening with the default application
// is platform.open_path.

import "base:runtime"

// An application that opens a type of file.
Handler :: struct {
	id:      string,   // what open_with takes: Linux, the desktop file id ("org.gnome.TextEditor.desktop"); Windows, the handler's name
	name:    string,   // what a menu shows
	default: bool,     // the system opens the file with it
}

// The applications that open the file at `path` (it need not exist: its name says its type), the default first, then the
// others by name. Owned by `allocator` (handlers_destroy). Empty when the system knows none.
handlers_for_file :: proc(path: string, allocator := context.allocator) -> []Handler {
	return handlers_for_file_native(path, allocator)
}

handlers_destroy :: proc(hs: []Handler, allocator := context.allocator) {
	for h in hs {
		delete(h.id, allocator)
		delete(h.name, allocator)
	}
	delete(hs, allocator)
}

// What the system calls the type of a file named `name` ("Plain text document", "PNG image"): on Linux the comment
// shared-mime-info gives the type its name says, on Windows the shell's type name. "" when the system says nothing (a
// name of no known type). Reads the system's files the first time a type is asked (Linux): call it on a worker, and keep
// the answer by extension.
type_name :: proc(name: string, allocator := context.allocator) -> string {
	return type_name_native(name, allocator)
}

// Opens the file at `path` with the handler `id` (one of handlers_for_file's). False when it cannot start.
open_with :: proc(path: string, id: string) -> bool {
	return open_with_native(path, id)
}

@(private)
handler_clone :: proc(id, name: string, default: bool, allocator: runtime.Allocator) -> Handler {
	return {clone_or_empty(id, allocator), clone_or_empty(name, allocator), default}
}
