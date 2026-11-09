package tk_desktop

// "Open with" on Linux, from the XDG specifications:
//   - the type of a file: shared-mime-info's globs2 (`weight:type:glob`) under each data directory's mime/, and its
//     parents: mime/subclasses, and text/plain for every text/* type;
//   - the applications: each desktop entry under a data directory's applications/ (its id is its path there, '/' made
//     '-'; the first directory that has an id wins), of Type=Application, not Hidden, not run in a terminal, whose
//     MimeType names the type or a parent;
//   - mimeapps.list (the user's configuration first, then the system's, then the data directories'): its
//     [Default Applications] give the default, [Added Associations] add applications, [Removed Associations] take some off.
// The data directories: $XDG_DATA_HOME, then $XDG_DATA_DIRS (default /usr/local/share:/usr/share). The configuration
// ones: $XDG_CONFIG_HOME, then $XDG_CONFIG_DIRS (default /etc/xdg).

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../ascii"
import "../platform"

// Where the specifications are read: the data directories and the configuration ones, most important first.
@(private)
Xdg_Roots :: struct {
	data:   []string,
	config: []string,
}

@(private)
xdg_roots :: proc() -> Xdg_Roots {
	data := make([dynamic]string, context.temp_allocator)
	config := make([dynamic]string, context.temp_allocator)
	if h := xdg_data_home(); h != "" { append(&data, h) }
	dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if dirs == "" { dirs = "/usr/local/share:/usr/share" }
	for d in strings.split(dirs, ":", context.temp_allocator) { if filepath.is_abs(d) { append(&data, d) } }
	if h := xdg_config_home(); h != "" { append(&config, h) }
	cdirs := os.get_env("XDG_CONFIG_DIRS", context.temp_allocator)
	if cdirs == "" { cdirs = "/etc/xdg" }
	for d in strings.split(cdirs, ":", context.temp_allocator) { if filepath.is_abs(d) { append(&config, d) } }
	return {data[:], config[:]}
}

@(private)
handlers_for_file_native :: proc(path: string, allocator: runtime.Allocator) -> []Handler {
	return handlers_in(xdg_roots(), path, allocator)
}

@(private)
open_with_native :: proc(path: string, id: string) -> bool {
	return open_with_in(xdg_roots(), path, id)
}

// An application's desktop entry, as "Open with" reads it.
@(private)
App_Entry :: struct {
	id, file, name, exec, icon: string,
	mimes: []string,
	usable: bool,   // an application that can open a file here
}

@(private)
handlers_in :: proc(roots: Xdg_Roots, path: string, allocator: runtime.Allocator) -> []Handler {
	types := mime_family(roots, mime_of_file(roots, path))
	apps := app_entries(roots)
	defaults, added, removed := mime_associations(roots, types)
	out := make([dynamic]Handler, allocator)
	seen := make(map[string]bool, context.temp_allocator)
	add :: proc(out: ^[dynamic]Handler, seen: ^map[string]bool, e: App_Entry, default: bool, allocator: runtime.Allocator) {
		if seen[e.id] || !e.usable { return }
		seen[e.id] = true
		append(out, handler_clone(e.id, e.name, default, allocator))
	}
	// the default: the first one named that is there and not removed
	for id in defaults {
		if removed[id] { continue }
		if e, ok := apps[id]; ok && e.usable { add(&out, &seen, e, true, allocator); break }
	}
	rest := make([dynamic]App_Entry, context.temp_allocator)
	for id in added { if e, ok := apps[id]; ok && !removed[id] && !seen[id] { append(&rest, e) } }
	for _, e in apps {
		if removed[e.id] { continue }
		for m in e.mimes { if slice.contains(types, m) { append(&rest, e); break } }
	}
	slice.sort_by(rest[:], proc(a, b: App_Entry) -> bool { return ascii.lower(a.name, context.temp_allocator) < ascii.lower(b.name, context.temp_allocator) })
	for e in rest { add(&out, &seen, e, false, allocator) }
	return out[:]
}

@(private)
open_with_in :: proc(roots: Xdg_Roots, path: string, id: string) -> bool {
	apps := app_entries(roots)
	e, ok := apps[id]
	if !ok || !e.usable { return false }
	args := exec_expand(e.exec, path, e.name, e.icon, e.file)
	if len(args) == 0 { return false }
	return platform.launch_detached(args)
}

// The type of the file at `path`: a folder is inode/directory; else the glob of shared-mime-info that matches its name
// with the highest weight (then the longest); application/octet-stream when none does.
@(private)
mime_of_file :: proc(roots: Xdg_Roots, path: string) -> string {
	if os.is_dir(path) { return "inode/directory" }
	name := filepath.base(path)
	lower := ascii.lower(name, context.temp_allocator)
	best, best_weight, best_len := "application/octet-stream", -1, 0
	for root in roots.data {
		text, err := os.read_entire_file(strings.concatenate({root, "/mime/globs2"}, context.temp_allocator), context.temp_allocator)
		if err != nil { continue }
		for line in strings.split_lines(string(text), context.temp_allocator) {
			if line == "" || line[0] == '#' { continue }
			f := strings.split(line, ":", context.temp_allocator)
			if len(f) < 3 { continue }
			weight := 0
			for c in f[0] { if c >= '0' && c <= '9' { weight = weight * 10 + int(c - '0') } }
			glob := f[2]
			cs := len(f) > 3 && strings.contains(f[3], "cs")
			if !glob_matches(glob, cs ? name : lower, cs) { continue }
			if weight > best_weight || weight == best_weight && len(glob) > best_len {
				best, best_weight, best_len = f[1], weight, len(glob)
			}
		}
	}
	return best
}

// A glob of globs2 against a name: `*`, `?` and the rest as they are (character classes are rare there and read as
// themselves). Not case-sensitive: the glob is lowered and the name was.
@(private)
glob_matches :: proc(glob, name: string, case_sensitive: bool) -> bool {
	g := case_sensitive ? glob : ascii.lower(glob, context.temp_allocator)
	match, _ := filepath.match(g, name)
	return match
}

// `mime` and the types it is a kind of (mime/subclasses, and text/plain for text/*), nearest first.
@(private)
mime_family :: proc(roots: Xdg_Roots, mime: string) -> []string {
	parents := make(map[string][dynamic]string, context.temp_allocator)
	for root in roots.data {
		text, err := os.read_entire_file(strings.concatenate({root, "/mime/subclasses"}, context.temp_allocator), context.temp_allocator)
		if err != nil { continue }
		for line in strings.split_lines(string(text), context.temp_allocator) {
			f := strings.fields(line, context.temp_allocator)
			if len(f) != 2 { continue }
			if f[0] not_in parents { parents[f[0]] = make([dynamic]string, context.temp_allocator) }
			append(&parents[f[0]], f[1])
		}
	}
	out := make([dynamic]string, context.temp_allocator)
	append(&out, mime)
	for i := 0; i < len(out); i += 1 {
		if ps, ok := parents[out[i]]; ok { for p in ps { if !slice.contains(out[:], p) { append(&out, p) } } }
	}
	if strings.has_prefix(mime, "text/") && !slice.contains(out[:], "text/plain") { append(&out, "text/plain") }
	return out[:]
}

// Every application's desktop entry, by id (the first data directory that has an id wins).
@(private)
app_entries :: proc(roots: Xdg_Roots) -> map[string]App_Entry {
	apps := make(map[string]App_Entry, context.temp_allocator)
	for root in roots.data {
		dir := strings.concatenate({root, "/applications"}, context.temp_allocator)
		app_entries_under(&apps, dir, "")
	}
	return apps
}

@(private = "file")
app_entries_under :: proc(apps: ^map[string]App_Entry, dir, prefix: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in entries {
		if fi.type == .Directory || fi.type == .Symlink && os.is_dir(fi.fullpath) {   // (NixOS: the profiles are links)
			app_entries_under(apps, fi.fullpath, strings.concatenate({prefix, fi.name, "-"}, context.temp_allocator))
			continue
		}
		if !strings.has_suffix(fi.name, ".desktop") { continue }
		id := strings.concatenate({prefix, fi.name}, context.temp_allocator)
		if id in apps { continue }
		text, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		apps[id] = app_entry_read(id, fi.fullpath, string(text))
	}
}

@(private)
app_entry_read :: proc(id, file, text: string) -> App_Entry {
	e := App_Entry{id = id, file = file}
	value :: proc(text, key: string) -> string { v, _ := entry_value(text, key); return unescape_value(v) }
	e.name = value(text, "Name")
	e.exec, _ = entry_value(text, "Exec")
	e.icon = value(text, "Icon")
	e.mimes = split_list(value(text, "MimeType"))
	e.usable = value(text, "Type") == "Application" && value(text, "Hidden") != "true" && value(text, "Terminal") != "true" &&
		e.exec != "" && e.name != ""
	return e
}

// What mimeapps.list says of `types`: the defaults (in the order of the files, then of their lists), the applications
// added, the ones removed.
@(private)
mime_associations :: proc(roots: Xdg_Roots, types: []string) -> (defaults, added: []string, removed: map[string]bool) {
	d := make([dynamic]string, context.temp_allocator)
	a := make([dynamic]string, context.temp_allocator)
	removed = make(map[string]bool, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	for c in roots.config { append(&files, strings.concatenate({c, "/mimeapps.list"}, context.temp_allocator)) }
	for r in roots.data { append(&files, strings.concatenate({r, "/applications/mimeapps.list"}, context.temp_allocator)) }
	// the type first, then its parents: an application for text/x-csrc is a better default than one for text/plain
	for t in types {
		for path in files {
			text, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil { continue }
			group := ""
			for raw in strings.split_lines(string(text), context.temp_allocator) {
				line := strings.trim_space(raw)
				if line == "" || line[0] == '#' { continue }
				if line[0] == '[' { group = line; continue }
				eq := strings.index_byte(line, '=')
				if eq < 0 || strings.trim_space(line[:eq]) != t { continue }
				ids := split_list(strings.trim_space(line[eq + 1:]))
				switch group {
				case "[Default Applications]":  append(&d, ..ids)
				case "[Added Associations]":    append(&a, ..ids)
				case "[Removed Associations]":  for id in ids { removed[id] = true }
				}
			}
		}
	}
	return d[:], a[:], removed
}
