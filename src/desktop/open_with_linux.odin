package tk_desktop

// "Open with" on Linux, from the XDG specifications:
//   - the type of a file: shared-mime-info's globs2 (`weight:type:glob`) under each data directory's mime/, and its
//     parents: mime/subclasses, and text/plain for every text/* type;
//   - the applications: each desktop entry under a data directory's applications/ (its id is its path there, '/' made
//     '-'; the first directory that has an id wins), of Type=Application, not Hidden, not run in a terminal, with an
//     Exec line the Desktop Entry specification accepts;
//   - the MIME Applications specification (mime-apps-spec): the mimeapps.list files and the desktop entries' MimeType,
//     level by level, in the order of `mime_levels`.
// The data directories: $XDG_DATA_HOME, then $XDG_DATA_DIRS (default /usr/local/share:/usr/share). The configuration
// ones: $XDG_CONFIG_HOME, then $XDG_CONFIG_DIRS (default /etc/xdg). The desktops: $XDG_CURRENT_DESKTOP (names apart by
// ':'), in ASCII lower case.
//
// Reading all of that takes 3 to 4 ms in an optimized build, 10 to 16 ms in a debug one (a desktop with 83 entries in 9
// data directories): a call on the UI thread would miss a frame. `mime_cache` keeps what was read while no file or folder
// read has changed; checking that is a stat of each.

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "../ascii"
import "../platform"

// Where the specifications are read: the data directories and the configuration ones, most important first, and the
// names of the current desktop.
@(private)
Xdg_Roots :: struct {
	data:     []string,
	config:   []string,
	desktops: []string,
}

@(private)
xdg_roots :: proc() -> Xdg_Roots {
	data := make([dynamic]string, context.temp_allocator)
	config := make([dynamic]string, context.temp_allocator)
	desktops := make([dynamic]string, context.temp_allocator)
	if h := xdg_data_home(); h != "" { append(&data, h) }
	dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if dirs == "" { dirs = "/usr/local/share:/usr/share" }
	for d in strings.split(dirs, ":", context.temp_allocator) { if filepath.is_abs(d) { append(&data, d) } }
	if h := xdg_config_home(); h != "" { append(&config, h) }
	cdirs := os.get_env("XDG_CONFIG_DIRS", context.temp_allocator)
	if cdirs == "" { cdirs = "/etc/xdg" }
	for d in strings.split(cdirs, ":", context.temp_allocator) { if filepath.is_abs(d) { append(&config, d) } }
	for d in strings.split(os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator), ":", context.temp_allocator) {
		if d != "" { append(&desktops, ascii.lower(d, context.temp_allocator)) }
	}
	return {data[:], config[:], desktops[:]}
}

@(private)
handlers_for_file_native :: proc(path: string, allocator: runtime.Allocator) -> []Handler {
	sync.mutex_guard(&mime_cache.mutex)
	return handlers_of(mime_cache_get(&mime_cache, xdg_roots()), path, allocator)
}

@(private)
open_with_native :: proc(path: string, id: string) -> bool {
	args: []string
	ok: bool
	{
		sync.mutex_guard(&mime_cache.mutex)
		args, ok = open_command(mime_cache_get(&mime_cache, xdg_roots()), path, id)
	}
	return ok && platform.launch_detached(args)
}

// An application's desktop entry, as "Open with" reads it.
@(private)
App_Entry :: struct {
	id, file, name, exec, icon: string,
	mimes:  []string,
	level:  int,    // the index in mime_levels of the applications/ folder it is in
	usable: bool,   // an application that can open a file here
}

// What one mimeapps.list says: by MIME type, the desktop file ids of each group, in the file's order.
@(private)
Mimeapps_List :: struct {
	defaults, added, removed: map[string][]string,
}

// A level of the MIME Applications specification: a configuration directory, or a data directory's applications/
// (`data`: it has desktop entries). `defaults`: the [Default Applications] of `<desktop>-mimeapps.list` for each current
// desktop, then of mimeapps.list. `list`: mimeapps.list, the one file whose added and removed associations count.
@(private)
Mime_Level :: struct {
	dir:      string,
	data:     bool,
	defaults: []Mimeapps_List,
	list:     Mimeapps_List,
	ids:      [dynamic]string,   // the ids of `apps` whose entry is in this folder, sorted
}

// A line of globs2: the glob in ASCII lower case unless `case_sensitive`.
@(private)
Mime_Glob :: struct {
	weight:         int,
	mime, glob:     string,
	case_sensitive: bool,
}

// A file or folder the database was read from, as it was then (`found`: it was there).
@(private)
File_Stamp :: struct {
	path:          string,
	found:         bool,
	device, inode: u64,
	size:          u64,
	modified:      linux.Statx_Timestamp,
}

// What the specifications say of the system, all of it in `allocator`: the applications by id, the levels (most
// important first), the globs and the parents of the types, and every file and folder read.
@(private)
Mime_Database :: struct {
	allocator: runtime.Allocator,
	apps:      map[string]App_Entry,
	levels:    []Mime_Level,
	globs:     [dynamic]Mime_Glob,
	parents:   map[string][dynamic]string,
	stamps:    [dynamic]File_Stamp,
}

// The database read last and the roots it was read from (`key`), in `arena`. Locked: `mutex`.
@(private)
Mime_Cache :: struct {
	mutex: sync.Mutex,
	arena: virtual.Arena,
	ready: bool,
	key:   string,
	db:    Mime_Database,
	reads: int,   // how many times the database was read (the tests count them)
}

@(private) mime_cache: Mime_Cache

// The database of `roots`: the cached one while it is of the same roots and no file or folder it read has changed, else
// read again. The caller holds `c.mutex`.
@(private)
mime_cache_get :: proc(c: ^Mime_Cache, roots: Xdg_Roots) -> ^Mime_Database {
	key := strings.join({strings.join(roots.data, ":", context.temp_allocator), strings.join(roots.config, ":", context.temp_allocator),
		strings.join(roots.desktops, ":", context.temp_allocator)}, "\n", context.temp_allocator)
	if c.ready && c.key == key && stamps_current(c.db.stamps[:]) { return &c.db }
	if c.ready { virtual.arena_destroy(&c.arena) }
	c.arena = {}
	_ = virtual.arena_init_growing(&c.arena)   // (a failure leaves an arena whose allocations fail: an empty database)
	a := virtual.arena_allocator(&c.arena)
	c.key = strings.clone(key, a)
	c.db = mime_database(roots, a)
	c.ready = true
	c.reads += 1
	return &c.db
}

// One statx (os.stat opens the file and reads its path back: four calls), through links.
@(private)
stamp_of :: proc(path: string) -> File_Stamp {
	s: linux.Statx
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if linux.statx(linux.AT_FDCWD, cpath, {}, {.INO, .SIZE, .MTIME}, &s) != .NONE { return {path = path} }
	return {path, true, u64(linux.makedev(s.dev_major, s.dev_minor)), u64(s.ino), s.size, s.mtime}
}

@(private)
stamps_current :: proc(stamps: []File_Stamp) -> bool {
	for s in stamps {
		now := stamp_of(s.path)
		now.path = s.path
		if now != s { return false }
	}
	return true
}

// The text of the file at `path` (false: missing or unreadable, which says nothing), its stamp kept.
@(private)
database_read :: proc(db: ^Mime_Database, path: string) -> (string, bool) {
	s := stamp_of(path)
	s.path = strings.clone(path, db.allocator)
	append(&db.stamps, s)
	if !s.found { return "", false }
	text, err := os.read_entire_file(path, db.allocator)
	return string(text), err == nil
}

@(private)
mime_database :: proc(roots: Xdg_Roots, allocator: runtime.Allocator) -> Mime_Database {
	a := allocator
	db := Mime_Database{
		allocator = a,
		apps      = make(map[string]App_Entry, a),
		globs     = make([dynamic]Mime_Glob, a),
		parents   = make(map[string][dynamic]string, a),
		stamps    = make([dynamic]File_Stamp, a),
	}
	for root in roots.data {
		if text, ok := database_read(&db, strings.concatenate({root, "/mime/globs2"}, context.temp_allocator)); ok { globs_read(&db, text) }
		if text, ok := database_read(&db, strings.concatenate({root, "/mime/subclasses"}, context.temp_allocator)); ok {
			for line in strings.split_lines(text, context.temp_allocator) {
				f := strings.fields(line, context.temp_allocator)
				if len(f) != 2 { continue }
				if f[0] not_in db.parents { db.parents[f[0]] = make([dynamic]string, a) }
				append(&db.parents[f[0]], f[1])
			}
		}
	}
	levels := make([dynamic]Mime_Level, a)
	for c in roots.config { append(&levels, Mime_Level{dir = strings.clone(c, a)}) }
	for r in roots.data { append(&levels, Mime_Level{dir = strings.concatenate({r, "/applications"}, a), data = true}) }
	for &l in levels {
		defaults := make([dynamic]Mimeapps_List, a)
		for d in roots.desktops {
			append(&defaults, mimeapps_read(&db, strings.concatenate({l.dir, "/", d, "-mimeapps.list"}, context.temp_allocator)))
		}
		l.list = mimeapps_read(&db, strings.concatenate({l.dir, "/mimeapps.list"}, context.temp_allocator))
		append(&defaults, l.list)
		l.defaults = defaults[:]
		l.ids = make([dynamic]string, a)
	}
	db.levels = levels[:]
	for &l, i in db.levels {
		if !l.data { continue }
		visited := make(map[[2]u64]bool, context.temp_allocator)
		app_entries_under(&db, &visited, l.dir, "", i, 0)
	}
	for id, e in db.apps { append(&db.levels[e.level].ids, id) }
	for &l in db.levels { slice.sort(l.ids[:]) }
	return db
}

@(private)
globs_read :: proc(db: ^Mime_Database, text: string) {
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" || line[0] == '#' { continue }
		f := strings.split(line, ":", context.temp_allocator)
		if len(f) < 3 { continue }
		g := Mime_Glob{mime = f[1], glob = f[2], case_sensitive = len(f) > 3 && strings.contains(f[3], "cs")}
		for c in f[0] { if c >= '0' && c <= '9' { g.weight = g.weight * 10 + int(c - '0') } }
		if !g.case_sensitive { g.glob = ascii.lower(g.glob, db.allocator) }
		append(&db.globs, g)
	}
}

@(private)
mimeapps_read :: proc(db: ^Mime_Database, path: string) -> Mimeapps_List {
	a := db.allocator
	m := Mimeapps_List{defaults = make(map[string][]string, a), added = make(map[string][]string, a), removed = make(map[string][]string, a)}
	text, ok := database_read(db, path)
	if !ok { return m }
	group: ^map[string][]string
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		if line[0] == '[' {
			switch line {
			case "[Default Applications]": group = &m.defaults
			case "[Added Associations]":   group = &m.added
			case "[Removed Associations]": group = &m.removed
			case:                          group = nil
			}
			continue
		}
		eq := strings.index_byte(line, '=')
		if group == nil || eq < 0 { continue }
		key := strings.trim_space(line[:eq])
		ids := split_list(strings.trim_space(line[eq + 1:]), a)
		// (a type twice in a group: its lists join)
		if old, found := group^[key]; found { ids = slice.concatenate([][]string{old, ids}, a) }
		group^[key] = ids
	}
	return m
}

// The handlers of the file at `path`, in `allocator`: the default first, then the others by name.
@(private)
handlers_of :: proc(db: ^Mime_Database, path: string, allocator: runtime.Allocator) -> []Handler {
	types := mime_family(db, mime_of_file(db, path))
	out := make([dynamic]Handler, allocator)
	seen := make(map[string]bool, context.temp_allocator)
	rest := make([dynamic]App_Entry, context.temp_allocator)
	default := ""
	// the type first, then its parents: an application for text/x-csrc is a better default than one for text/plain
	for t in types {
		apps := mime_associated(db, t)
		if default == "" { default = mime_default(db, t, apps) }
		for id in apps {
			if seen[id] { continue }
			seen[id] = true
			append(&rest, db.apps[id])
		}
	}
	if default != "" {
		e := db.apps[default]
		append(&out, handler_clone(e.id, e.name, true, allocator))
	}
	slice.sort_by(rest[:], proc(a, b: App_Entry) -> bool { return ascii.lower(a.name, context.temp_allocator) < ascii.lower(b.name, context.temp_allocator) })
	for e in rest {
		if e.id == default || !e.usable { continue }
		append(&out, handler_clone(e.id, e.name, false, allocator))
	}
	return out[:]
}

// The applications of type `t`, most preferred first: the specification's algorithm. Level by level: the ids that
// mimeapps.list adds (if no level before took them off), the ones it removes, then the entries of the folder that list
// `t` (if none took them off); an entry of the folder hides the same id further on.
@(private)
mime_associated :: proc(db: ^Mime_Database, t: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	blocked := make(map[string]bool, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, id: string) { if !slice.contains(out[:], id) { append(out, id) } }
	for &l in db.levels {
		for id in l.list.added[t] { if !blocked[id] && id in db.apps { add(&out, id) } }
		for id in l.list.removed[t] { blocked[id] = true }
		if !l.data { continue }
		for id in l.ids {
			if !blocked[id] && slice.contains(db.apps[id].mimes, t) { add(&out, id) }
		}
		for id in l.ids { blocked[id] = true }
	}
	return out[:]
}

// The default application of type `t` ("" when none): the first id of the [Default Applications] lists, level by level,
// that is a usable application associated with `t`; else the most preferred usable one of `associated`.
@(private)
mime_default :: proc(db: ^Mime_Database, t: string, associated: []string) -> string {
	for &l in db.levels {
		for list in l.defaults {
			for id in list.defaults[t] {
				if e, ok := db.apps[id]; ok && e.usable && slice.contains(associated, id) { return id }
			}
		}
	}
	for id in associated { if db.apps[id].usable { return id } }
	return ""
}

// The command that opens `path` with the application `id` (in the temporary allocator); false when there is none.
@(private)
open_command :: proc(db: ^Mime_Database, path: string, id: string) -> ([]string, bool) {
	e, ok := db.apps[id]
	if !ok || !e.usable { return nil, false }
	return exec_expand(e.exec, path, e.name, e.icon, e.file)
}

// The type of the file at `path`: a folder is inode/directory; else the glob of shared-mime-info that matches its name
// with the highest weight (then the longest); application/octet-stream when none does.
@(private)
mime_of_file :: proc(db: ^Mime_Database, path: string) -> string {
	if os.is_dir(path) { return "inode/directory" }
	name := filepath.base(path)
	lower := ascii.lower(name, context.temp_allocator)
	best, best_weight, best_len := "application/octet-stream", -1, 0
	for g in db.globs {
		n := g.case_sensitive ? name : lower
		// most globs are `*.ext`: a suffix, without filepath.match (character classes are rare: it reads them as it can)
		match: bool
		if len(g.glob) > 1 && g.glob[0] == '*' && !strings.contains_any(g.glob[1:], "*?[\\") {
			match = strings.has_suffix(n, g.glob[1:])
		} else {
			match, _ = filepath.match(g.glob, n)
		}
		if !match { continue }
		if g.weight > best_weight || g.weight == best_weight && len(g.glob) > best_len {
			best, best_weight, best_len = g.mime, g.weight, len(g.glob)
		}
	}
	return best
}

// `mime` and the types it is a kind of (mime/subclasses, and text/plain for text/*), nearest first.
@(private)
mime_family :: proc(db: ^Mime_Database, mime: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, mime)
	for i := 0; i < len(out); i += 1 {
		if ps, ok := db.parents[out[i]]; ok { for p in ps { if !slice.contains(out[:], p) { append(&out, p) } } }
	}
	if strings.has_prefix(mime, "text/") && !slice.contains(out[:], "text/plain") { append(&out, "text/plain") }
	return out[:]
}

// How deep the folders under applications/ are read. Ids with a folder are one or two deep (kde4-okular.desktop); the
// limit and the folders already read stop a link that loops (x -> ..).
@(private = "file") APP_FOLDER_DEPTH :: 8

// The desktop entries under `dir` (a level's applications/ folder) that no folder before had. A folder is read once
// (`visited`: its device and inode, a linked one's target).
@(private = "file")
app_entries_under :: proc(db: ^Mime_Database, visited: ^map[[2]u64]bool, dir, prefix: string, level, depth: int) {
	if depth > APP_FOLDER_DEPTH { return }
	s := stamp_of(dir)
	s.path = strings.clone(dir, db.allocator)
	append(&db.stamps, s)   // (an entry added or taken off changes its folder)
	if !s.found { return }
	if visited^[{s.device, s.inode}] { return }
	visited^[{s.device, s.inode}] = true
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in entries {
		if fi.type == .Directory || fi.type == .Symlink && os.is_dir(fi.fullpath) {   // (NixOS: the profiles are links)
			app_entries_under(db, visited, fi.fullpath, strings.concatenate({prefix, fi.name, "-"}, context.temp_allocator), level, depth + 1)
			continue
		}
		if !strings.has_suffix(fi.name, ".desktop") { continue }
		id := strings.concatenate({prefix, fi.name}, context.temp_allocator)
		if id in db.apps { continue }
		text, ok := database_read(db, fi.fullpath)
		if !ok { continue }
		e := app_entry_read(strings.clone(id, db.allocator), strings.clone(fi.fullpath, db.allocator), text, db.allocator)
		e.level = level
		db.apps[e.id] = e
	}
}

// The entry of the file `file` (`text` its content); its strings are slices of `text` or in `allocator`.
@(private)
app_entry_read :: proc(id, file, text: string, allocator: runtime.Allocator) -> App_Entry {
	e := App_Entry{id = id, file = file}
	value :: proc(text, key: string, allocator: runtime.Allocator) -> string { v, _ := entry_value(text, key); return unescape_value(v, allocator) }
	e.name = value(text, "Name", allocator)
	e.exec, _ = entry_value(text, "Exec")
	e.icon = value(text, "Icon", allocator)
	e.mimes = split_list(value(text, "MimeType", allocator), allocator)
	_, exec_valid := exec_expand(e.exec, "/", e.name, e.icon, file, context.temp_allocator)
	e.usable = value(text, "Type", context.temp_allocator) == "Application" && value(text, "Hidden", context.temp_allocator) != "true" &&
		value(text, "Terminal", context.temp_allocator) != "true" && exec_valid && e.name != ""
	return e
}
