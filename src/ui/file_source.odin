package ui

// What the file browser reads its folders through (docs/file-browser.md): the computer's own files (local_files) or any
// other file system a program reaches (a server's, an archive's). A source's calls start the work and return at once;
// the source answers later, on the interface's thread, through the reply it was given (file_reply_listed,
// file_reply_read, file_reply_made, file_reply_found, file_reply_failed). An answer of a reading given up (another folder asked since,
// another file selected, the dialog closed) changes nothing: the reply carries its ticket (remote) and its dialog.
//
// The paths are the source's: absolute, its separator between their parts. The helpers below read them for any
// separator, so that a server's "/" paths are walked on Windows as they are.

import "core:mem"
import "core:strings"
import "../ascii"
import lucide "../lucide"
import "../platform"
import syntax "../syntax"

File_Kind :: enum u8 { File, Folder }

// What a source knows and does: the size and the date of its entries, the start of a file (the preview), a new folder.
// A column the source does not know is not shown.
File_Cap :: enum u8 { Size, Modified, Read, Make_Folder }
File_Caps :: bit_set[File_Cap; u8]

// One entry of a folder, as a source lists it. The browser copies what it keeps.
File_Entry :: struct {
	name:     string,
	kind:     File_Kind,   // a link's: what it points to
	link:     bool,
	size:     i64,         // bytes; -1: not known
	modified: i64,         // Unix milliseconds; 0: not known
	hidden:   bool,        // the source's flag; a name that starts with "." is hidden whatever it says
}

// What a reply answers.
File_Reply_Kind :: enum u8 { List, Read, Make, Find }

// The way back of one call of a source: give it to the file_reply_ procedure that answers, on the interface's thread.
// It is a value: keep it as long as the work takes (it holds no memory).
File_Reply :: struct {
	state:  ^State,
	dialog: u64,     // the dialog that asked (an answer after it closed is dropped)
	ticket: u64,     // the reading (an answer of a reading given up is dropped)
	kind:   File_Reply_Kind,
	hidden: bool,    // .Find: Hidden files is on; else the hidden entries, and what is in hidden folders, are not found
}

File_Source :: struct {
	user:        rawptr,
	caps:        File_Caps,
	separator:   u8,   // '/' or '\\': how its paths are joined
	// The entries of the folder `path` (file_reply_listed).
	list:        proc(src: ^File_Source, path: string, reply: File_Reply),
	// The first `max` bytes of the file `path`, for its preview (file_reply_read). nil: no preview.
	read:        proc(src: ^File_Source, path: string, max: int, reply: File_Reply),
	// Makes the folder `path` (file_reply_made). nil: no New folder.
	make_folder: proc(src: ^File_Source, path: string, reply: File_Reply),
	// The entries under `folder`, at any depth, that match `query`, best first, at most `limit` (file_reply_found);
	// `reply.hidden`: hidden ones too. nil: the source cannot, the browser offers no search in subfolders.
	find:        proc(src: ^File_Source, folder, query: string, limit: int, reply: File_Reply),
	// The places it knows already, at once (cheap: no reading), in `allocator`. nil: none.
	places:      proc(src: ^File_Source, allocator: mem.Allocator) -> []platform.File_Place,
	// Where a dialog starts that knows no folder ("": the first of its places), in `allocator`. nil: its first place.
	start:       proc(src: ^File_Source, allocator: mem.Allocator) -> string,
}

// The entries of the folder asked. They are copied: the source frees its own after the call.
file_reply_listed :: proc(reply: File_Reply, entries: []File_Entry) {
	if fb := file_reply_browser(reply); fb != nil && reply.kind == .List { file_browser_listed(fb, reply.ticket, entries) }
}

// The start of the file asked (`bytes`, copied) and its whole size (-1: not known).
file_reply_read :: proc(reply: File_Reply, bytes: []u8, size: i64) {
	if fb := file_reply_browser(reply); fb != nil && reply.kind == .Read { file_browser_read(fb, reply.ticket, bytes, size) }
}

// The folder asked was made.
file_reply_made :: proc(reply: File_Reply) {
	if fb := file_reply_browser(reply); fb != nil && reply.kind == .Make { file_browser_made(fb, reply.ticket) }
}

// What a find found, best first: each entry's `name` is its path relative to the folder asked, with the source's
// separator ("docs/notes.md"). They are copied: the source frees its own after the call.
file_reply_found :: proc(reply: File_Reply, entries: []File_Entry) {
	if fb := file_reply_browser(reply); fb != nil && reply.kind == .Find { file_browser_found(fb, reply.ticket, entries) }
}

// The call did not end well: `message` is what the person reads (the source's words, in the language in use).
// `refused`: the source said no (no right to read it); `missing`: what was asked is not there (a folder deleted since: the
// browser goes up to the nearest one that is).
file_reply_failed :: proc(reply: File_Reply, message: string, refused := false, missing := false) {
	if fb := file_reply_browser(reply); fb != nil { file_browser_failed(fb, reply.kind, reply.ticket, message, refused, missing) }
}

// The browser a reply is for, nil when its dialog closed (or another one opened since).
@(private = "file")
file_reply_browser :: proc(reply: File_Reply) -> ^File_Browser {
	if reply.state == nil { return nil }
	fb := reply.state.files
	if fb == nil || !fb.open || fb.serial != reply.dialog { return nil }
	return fb
}

////////////////////////////////
// Paths of any separator

// The length of the root at the start of `path`: "/" (1), "C:\" (3), "\\server\share\"; 0: a relative path.
file_path_root :: proc(path: string, sep: u8) -> int {
	if sep == '\\' {
		if len(path) >= 2 && path[1] == ':' { return len(path) >= 3 && (path[2] == '\\' || path[2] == '/') ? 3 : 2 }
		if len(path) >= 2 && path[0] == '\\' && path[1] == '\\' {
			seps := 0
			for i in 2 ..< len(path) {
				if path[i] != '\\' { continue }
				seps += 1
				if seps == 2 { return i + 1 }
			}
			return len(path)
		}
	}
	if len(path) > 0 && path[0] == sep { return 1 }
	return 0
}

// `path` without the separators at its end (its root keeps its own).
file_path_trim :: proc(path: string, sep: u8) -> string {
	root := file_path_root(path, sep)
	p := path
	for len(p) > root && p[len(p) - 1] == sep { p = p[:len(p) - 1] }
	return p
}

// The folder that holds `path` (a slice of it); a root is its own.
file_path_parent :: proc(path: string, sep: u8) -> string {
	root := file_path_root(path, sep)
	p := file_path_trim(path, sep)
	if len(p) <= root { return p }
	i := strings.last_index_byte(p[root:], sep)
	if i < 0 { return p[:root] }
	return file_path_trim(p[:root + i], sep)
}

// The last part of `path` (a slice of it); a root is its own.
file_path_name :: proc(path: string, sep: u8) -> string {
	p := file_path_trim(path, sep)
	root := file_path_root(p, sep)
	if len(p) <= root { return p }
	i := strings.last_index_byte(p[root:], sep)
	return i < 0 ? p[root:] : p[root + i + 1:]
}

// `name` in the folder `dir`.
file_path_join :: proc(dir, name: string, sep: u8, allocator := context.temp_allocator) -> string {
	if dir == "" { return strings.clone(name, allocator) }
	if dir[len(dir) - 1] == sep { return strings.concatenate({dir, name}, allocator) }
	s := [1]u8{sep}
	return strings.concatenate({dir, string(s[:]), name}, allocator)
}

// `path` with its "." and ".." parts walked and its separators single; a path typed with "/" on a source of "\" reads
// as one of "\" (what a person types on Windows).
file_path_clean :: proc(path: string, sep: u8, allocator := context.temp_allocator) -> string {
	p := path
	if sep == '\\' {
		p, _ = strings.replace_all(path, "/", "\\", context.temp_allocator)
	}
	root := file_path_root(p, sep)
	parts := make([dynamic]string, context.temp_allocator)
	rest := p[root:]
	for len(rest) > 0 {
		i := strings.index_byte(rest, sep)
		part := i < 0 ? rest : rest[:i]
		rest = i < 0 ? "" : rest[i + 1:]
		switch part {
		case "", ".":
		case "..": if len(parts) > 0 && parts[len(parts) - 1] != ".." { pop(&parts) } else if root == 0 { append(&parts, part) }
		case: append(&parts, part)
		}
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, p[:root])
	if root > 0 && p[root - 1] != sep && len(parts) > 0 { strings.write_byte(&b, sep) }   // ("C:" then a part)
	for part, i in parts {
		if i > 0 { strings.write_byte(&b, sep) }
		strings.write_string(&b, part)
	}
	return strings.to_string(b)
}

// One part of a path in a breadcrumb: what it says, and the path up to it.
File_Path_Part :: struct { name, path: string }

// The parts of `path` from its root, in `allocator` (the strings are slices of `path`).
file_path_parts :: proc(path: string, sep: u8, allocator := context.temp_allocator) -> []File_Path_Part {
	out := make([dynamic]File_Path_Part, allocator)
	p := file_path_trim(path, sep)
	root := file_path_root(p, sep)
	if root > 0 {
		// ("/" says itself; "C:\" reads "C:")
		name := p[:root]
		if root > 1 && name[root - 1] == sep { name = name[:root - 1] }
		append(&out, File_Path_Part{name = name, path = p[:root]})
	}
	at := root
	for at < len(p) {
		i := strings.index_byte(p[at:], sep)
		end := i < 0 ? len(p) : at + i
		if end > at { append(&out, File_Path_Part{name = p[at:end], path = p[:end]}) }
		at = end + 1
	}
	return out[:]
}

// Whether `path` is `folder` or inside it.
file_path_within :: proc(path, folder: string, sep: u8) -> bool {
	p, f := file_path_trim(path, sep), file_path_trim(folder, sep)
	if f == "" || !strings.has_prefix(p, f) { return false }
	return len(p) == len(f) || f[len(f) - 1] == sep || p[len(f)] == sep
}

////////////////////////////////
// What an entry is

// Hidden: the source's flag, or a name that starts with ".".
file_entry_hidden :: proc(e: File_Entry) -> bool { return e.hidden || (len(e.name) > 0 && e.name[0] == '.') }

// What an entry looks like in the list: its icon, its kind's word.
File_Look :: enum u8 { Folder, File, Image, Code, Archive, Text, Link }

file_entry_look :: proc(e: File_Entry) -> File_Look {
	if e.link { return .Link }
	if e.kind == .Folder { return .Folder }
	ext := file_extension(e.name)
	switch ext {
	case "png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "ico", "tif", "tiff": return .Image
	case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst": return .Archive
	case "txt", "md", "log", "csv", "rst": return .Text
	}
	if _, ok := syntax.language_of_file(e.name); ok { return .Code }
	return .File
}

// The extension of a file's name in lower case ASCII, without its dot ("" none), in the frame's memory.
@(private)
file_extension :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 || dot == len(name) - 1 { return "" }
	return ascii.lower(name[dot + 1:])
}

// The Lucide glyph of a look.
file_look_icon :: proc(l: File_Look) -> string {
	switch l {
	case .Folder:  return lucide.FOLDER
	case .File:    return lucide.FILE
	case .Image:   return lucide.FILE_IMAGE
	case .Code:    return lucide.FILE_CODE
	case .Archive: return lucide.FILE_ARCHIVE
	case .Text:    return lucide.FILE_TEXT
	case .Link:    return lucide.FILE_SYMLINK
	}
	return lucide.FILE
}
