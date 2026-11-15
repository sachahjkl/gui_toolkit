#+build linux
package platform

// The person's folders on Linux (Known_Folder), as their desktop names them: xdg-user-dirs' file,
// $XDG_CONFIG_HOME/user-dirs.dirs, written at login in the person's language (XDG_DESKTOP_DIR="$HOME/Bureau"). The file is
// read once per process and kept, while its path and the home are the same (src/md/features/folders.md).

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import base "../base"

// What user-dirs.dirs said, kept for the process (heap memory): read at the first call, again when the file's path or the
// home changed (a test points XDG_CONFIG_HOME elsewhere).
@(private = "file")
User_Dirs_Cache :: struct {
	lock: sync.Mutex,
	read: bool,
	file: string,                 // the file read
	home: string,                 // the home its "$HOME" was made
	dirs: [Known_Folder]string,   // user_dirs_parse's answer
}

@(private = "file") user_dirs_cache: User_Dirs_Cache

// A folder the file names, else $HOME/<English name> (user-dirs.defaults, and the folders of a system without
// xdg-user-dirs); "" for one the file disables (its value is the home) and without a home. .Home and .None: the home.
known_folder_path :: proc(k: Known_Folder, allocator := context.allocator, loc := #caller_location) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if k == .Home || k == .None { return strings.clone(home, allocator) }
	if home == "" { return "" }
	said := user_dirs_said(k, home, loc)
	if said == home { return "" }   // (disabled: xdg-user-dirs-update points a folder at the home to turn it off)
	if said != "" { return strings.clone(said, allocator) }
	ENGLISH :: [Known_Folder]string{
		.None = "", .Home = "", .Desktop = "Desktop", .Documents = "Documents", .Downloads = "Downloads",
		.Music = "Music", .Pictures = "Pictures", .Videos = "Videos",
	}
	names := ENGLISH
	return strings.concatenate({home, "/", names[k]}, allocator)
}

// The folder user-dirs.dirs gives `k` (temp memory; "": it names none), read when the cache is not of this file and home.
@(private = "file")
user_dirs_said :: proc(k: Known_Folder, home: string, loc: runtime.Source_Code_Location) -> string {
	config := user_dir(.Config, "", context.temp_allocator)
	if config == "" { return "" }
	file := strings.concatenate({config, "/user-dirs.dirs"}, context.temp_allocator)
	c := &user_dirs_cache
	sync.mutex_guard(&c.lock)
	if !c.read || c.file != file || c.home != home {
		heap := runtime.heap_allocator()
		delete(c.file, heap)
		delete(c.home, heap)
		for d in c.dirs { delete(d, heap) }
		dirs: [Known_Folder]string
		base.blocking("platform.known_folder_path", loc)   // (the file read: once a process; $HOME and the cache wait on nothing)
		if text, err := os.read_entire_file(file, context.temp_allocator); err == nil { dirs = user_dirs_parse(string(text), home) }
		for d, i in dirs { c.dirs[i] = strings.clone(d, heap) }
		c.file = strings.clone(file, heap)
		c.home = strings.clone(home, heap)
		c.read = true
	}
	return strings.clone(c.dirs[k], context.temp_allocator)
}

// The folders a user-dirs.dirs text names, "$HOME" made `home` (temp memory; "": not named). What GLib's
// g_get_user_special_dir takes: a line XDG_<NAME>_DIR="<value>" (spaces around "="), the value "$HOME" (then "/" or its end)
// or an absolute path, "\" taking the next character as it is, a last "/" gone; the last line of a name wins (a shell's
// reading). A comment, a name no Known_Folder has (TEMPLATES, PUBLICSHARE), another form of value are left out.
@(private)
user_dirs_parse :: proc(text, home: string) -> (dirs: [Known_Folder]string) {
	rest := text
	lines: for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_left_space(line)
		if !strings.has_prefix(l, "XDG_") { continue }   // (a comment, an empty line)
		l = l[len("XDG_"):]
		end := strings.index(l, "_DIR")
		if end < 0 { continue }
		k: Known_Folder
		switch l[:end] {
		case "DESKTOP":   k = .Desktop
		case "DOCUMENTS": k = .Documents
		case "DOWNLOAD":  k = .Downloads
		case "MUSIC":     k = .Music
		case "PICTURES":  k = .Pictures
		case "VIDEOS":    k = .Videos
		case:             continue lines
		}
		l = strings.trim_left_space(l[end + len("_DIR"):])
		if !strings.has_prefix(l, "=") { continue }
		l = strings.trim_left_space(l[1:])
		if !strings.has_prefix(l, "\"") { continue }
		l = l[1:]
		b := strings.builder_make(context.temp_allocator)
		if strings.has_prefix(l, "$HOME") {
			after := l[len("$HOME"):]
			if !strings.has_prefix(after, "/") && !strings.has_prefix(after, "\"") { continue }   // ($HOMEDIR: not the home)
			strings.write_string(&b, home)
			l = after
		} else if !strings.has_prefix(l, "/") {
			continue
		}
		for i := 0; i < len(l); i += 1 {
			c := l[i]
			if c == '"' { break }
			if c == '\\' && i + 1 < len(l) { i += 1; c = l[i] }
			strings.write_byte(&b, c)
		}
		v := strings.to_string(b)
		if len(v) > 1 && strings.has_suffix(v, "/") { v = v[:len(v) - 1] }
		dirs[k] = v
	}
	return
}
