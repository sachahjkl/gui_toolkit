package tk_desktop

// "Open with": the applications the system knows for a type of file, and a file opened with one of them. Linux reads
// the XDG specifications (shared-mime-info for the type, the desktop entries' MimeType, mimeapps.list for the default
// and the user's own associations); Windows asks the shell (SHAssocEnumHandlers). Opening with the default application
// is platform.open_path.

import "base:runtime"
import base "../base"

// An application that opens a type of file.
Handler :: struct {
	id:      string,   // what open_with takes: Linux, the desktop file id ("org.gnome.TextEditor.desktop"); Windows, the handler's name
	name:    string,   // what a menu shows
	icon:    string,   // where its icon is (handler_icon): Linux, the desktop entry's Icon key (a theme's name or a file);
	                   // Windows, the shell's location "file,index"; "": none
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
		delete(h.icon, allocator)
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
open_with :: proc(path: string, id: string, loc := #caller_location) -> bool {
	base.blocking("desktop.open_with", loc)
	if base.restricted() { return false }   // (the handler is the user's to change: never with an administrator's rights)
	return open_with_native(path, id)
}

// The icon of the handler `h`, about `size` pixels square: Linux, its name in the person's icon theme (theme_icon);
// Windows, the icon the shell gives for it. ok is false when it has none. It reads files: call it on a worker, once
// per handler and size.
handler_icon :: proc(h: Handler, size: int, allocator := context.allocator, loc := #caller_location) -> (icon: File_Icon, ok: bool) {
	base.blocking("desktop.handler_icon", loc)
	if h.icon == "" { return }
	return handler_icon_native(h.icon, size, allocator)
}

@(private)
handler_clone :: proc(id, name, icon: string, default: bool, allocator: runtime.Allocator) -> Handler {
	return {id = clone_or_empty(id, allocator), name = clone_or_empty(name, allocator), icon = clone_or_empty(icon, allocator), default = default}
}
