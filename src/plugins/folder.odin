package tk_plugins

// The plugins' folder and plugins.toml, read on a chore (the interface's thread makes no system call), the result
// posted back whole: the plugins of a read replace those of the last.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "../fsx"
import "../platform"
import plugin_api "../plugin_api"
import "../ui"

TOML_FILE :: "plugins.toml"
TOML_MAX_BYTES :: 1 << 20

@(private)
Read_Job :: struct {
	link:      ^Host_Link,   // (counted)
	serial:    u64,
	program, program_id, folder_opt, config_opt, state_opt, data_opt, single: string,
	// made by the chore
	folder, toml_path, state_dir: string,
	data_dir:  string,   // <data>/<program>/plugin-data: each plugin's own folder is in it
	plugins:   [dynamic]^Plugin,
}

// Drops the plugins (their runtimes stop) and reads the folder again. Interface thread.
@(private)
folder_read :: proc(h: ^Host) {
	plugins_drop(h)
	h.read_serial += 1
	j := new(Read_Job)
	j^ = {
		link = h.link, serial = h.read_serial,
		program = strings.clone(h.o.program), program_id = strings.clone(h.o.program_id),
		folder_opt = strings.clone(h.o.folder), config_opt = strings.clone(h.o.config_dir), state_opt = strings.clone(h.o.state_dir),
		single = strings.clone(h.o.single), data_opt = strings.clone(h.o.data_dir),
	}
	sync.atomic_add(&h.link.refs, 1)
	ui.task(h.state, read_work, read_done, j, read_lost)
}

@(private)
read_job_free :: proc(j: ^Read_Job) {
	context.allocator = runtime.heap_allocator()
	for p in j.plugins { plugin_release(p) }
	delete(j.plugins)
	delete(j.program); delete(j.program_id); delete(j.folder_opt); delete(j.config_opt); delete(j.state_opt); delete(j.single); delete(j.data_opt)
	delete(j.folder); delete(j.toml_path); delete(j.state_dir); delete(j.data_dir)
	link_release(j.link)
	free(j)
}

@(private)
read_lost :: proc(data: rawptr) { read_job_free((^Read_Job)(data)) }

@(private)
read_work :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	j := (^Read_Job)(data)
	j.folder = j.folder_opt != "" ? strings.clone(j.folder_opt) : in_user_dir(.Data, j.program, "plugins")
	config := j.config_opt != "" ? strings.clone(j.config_opt, context.temp_allocator) : platform.user_dir(.Config, j.program, context.temp_allocator)
	j.toml_path = config != "" ? strings.clone(fsx.path_join(config, TOML_FILE)) : strings.clone("")
	j.state_dir = j.state_opt != "" ? strings.clone(j.state_opt) : in_user_dir(.State, j.program, "plugins")
	if j.state_dir != "" { fsx.make_dirs(j.state_dir) }
	// (a plugin's data is beside its code, not in it: an update or a removal of the folder does not lose it)
	j.data_dir = j.data_opt != "" ? strings.clone(j.data_opt) : in_user_dir(.Data, j.program, "plugin-data")

	t := toml_read(j.toml_path)
	defer toml_state_free(&t)
	if j.single != "" {
		single_read(j, &t)
		return
	}
	if j.folder == "" { return }
	entries, err := fsx.read_folder(j.folder, context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: fsx.Folder_Entry) -> bool { return a.name < b.name })
	for e in entries {
		if e.kind != .Directory { continue }
		dir := fsx.path_join(j.folder, e.name)
		p := plugin_new()
		p.folder = strings.clone(dir)
		text, ok := fsx.read_all(fsx.path_join(dir, MANIFEST_FILE), context.temp_allocator, MANIFEST_MAX_BYTES)
		if !ok {
			p.refused = strings.clone("its folder has no plugin.json")
		} else {
			p.manifest, p.refused = manifest_parse(string(text), j.program_id)
			if p.refused == "" && p.manifest.id != e.name {
				p.refused = fmt.aprintf("its id is \"%s\" and its folder \"%s\": they must be the same", p.manifest.id, e.name)
			}
		}
		if p.manifest.name == "" {
			delete(p.manifest.name)
			p.manifest.name = strings.clone(e.name)
		}
		for o in j.plugins {
			if p.refused == "" && o.refused == "" && o.manifest.id == p.manifest.id {
				p.refused = fmt.aprintf("another folder has the id \"%s\"", p.manifest.id)
			}
		}
		plugin_place(j, p, t.enabled[p.manifest.id], &t)
	}
}

// A plugin read: its log, its state from what the person decided and what plugins.toml kept of its crashes.
@(private)
plugin_place :: proc(j: ^Read_Job, p: ^Plugin, on: bool, t: ^Toml_State) {
	id := p.manifest.id
	if j.state_dir != "" && id_valid(id, false) {
		p.log_path = strings.clone(fsx.path_join(j.state_dir, fmt.tprintf("%s.log", id)))
	}
	if j.data_dir != "" && id_valid(id, false) {
		p.data_dir = strings.clone(fsx.path_join(j.data_dir, id))
	}
	if l, has := t.granted[id]; has { for g in l { append(&p.granted, strings.clone(g)) } }
	if l, has := t.picked[id]; has { for g in l { append(&p.picked, strings.clone(g)) } }
	p.suspended = t.suspended[id]
	p.enabled = on && !p.suspended
	// (a version that asks more than the person granted asks again: off until they do)
	p.asks_more = len(p.manifest.permissions) > 0 && !permissions_covered(p.manifest.permissions, p.granted[:])
	switch {
	case p.refused != "":           p.state = .Refused
	case p.suspended:               p.state = .Suspended
	case p.enabled && !p.asks_more: p.state = .Ready
	case:                           p.state = .Off
	}
	append(&j.plugins, p)
}

// Host_Options.single: one plugin, a folder with its plugin.json or a lone entry file whose manifest is implied (its
// id and name from the file's name, this toolkit's level, one view "main"). It is on: the program was started to run
// it (gt-runtime); only a suspension stops it.
@(private)
single_read :: proc(j: ^Read_Job, t: ^Toml_State) {
	p := plugin_new()
	path := j.single
	if fsx.path_kind(path) == .Directory {
		p.folder = strings.clone(path)
		text, ok := fsx.read_all(fsx.path_join(path, MANIFEST_FILE), context.temp_allocator, MANIFEST_MAX_BYTES)
		if !ok {
			p.refused = fmt.aprintf("%s has no plugin.json", path)
		} else {
			p.manifest, p.refused = manifest_parse(string(text), j.program_id)
		}
	} else if fsx.path_kind(path) == .File && (strings.has_suffix(path, ".js") || strings.has_suffix(path, ".mjs")) {
		dir, file := dir_of(path), base_of(path)
		p.folder = strings.clone(dir != "" ? dir : ".")
		p.manifest = manifest_implied(file)
	} else {
		p.refused = fmt.aprintf("%s is neither a plugin's folder nor a .js file", path)
	}
	if p.manifest.name == "" {
		delete(p.manifest.name)
		p.manifest.name = strings.clone(base_of(path))
	}
	plugin_place(j, p, true, t)
}

// The manifest of a lone entry file `file` ("todo.js"): what single_read gives a plugin without plugin.json.
manifest_implied :: proc(file: string, allocator := context.allocator) -> Manifest {
	context.allocator = allocator
	stem := file
	if dot := strings.last_index_byte(stem, '.'); dot > 0 { stem = stem[:dot] }
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)stem {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', '-': strings.write_byte(&b, c)
		case 'A' ..= 'Z':                        strings.write_byte(&b, c + 'a' - 'A')
		case:                                    strings.write_byte(&b, '-')
		}
		if strings.builder_len(b) == ID_MAX_BYTES { break }
	}
	id := strings.to_string(b)
	if id == "" { id = "app" }
	views := make([]View_Decl, 1)
	views[0] = {id = strings.clone("main"), title = strings.clone(stem), place = .Internal}
	return Manifest{
		id = strings.clone(id), name = strings.clone(stem), version = strings.clone(""), api = plugin_api.PLUGIN_API_LEVEL,
		main = strings.clone(file), program = strings.clone(""), views = views,
	}
}

@(private)
base_of :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return path[i + 1:]
}

@(private)
read_done :: proc(data: rawptr, word: u64) {
	context.allocator = runtime.heap_allocator()
	j := (^Read_Job)(data)
	defer read_job_free(j)
	h := j.link.host
	if h == nil || j.serial != h.read_serial { return }
	plugins_drop(h)
	for p in j.plugins {
		p.host = h
		append(&h.plugins, p)
	}
	clear(&j.plugins)   // (the host's now)
	views_declare(h)
	settings_register(h)
	delete(h.folder); delete(h.toml_path); delete(h.state_dir)
	h.folder, h.toml_path, h.state_dir = j.folder, j.toml_path, j.state_dir
	j.folder, j.toml_path, j.state_dir = "", "", ""
	h.loaded = true
	h.source.version += 1
}

// What plugins.toml says (keys and words owned; toml_state_free).
@(private)
Toml_State :: struct {
	enabled:   map[string]bool,
	suspended: map[string]bool,
	granted:   map[string][dynamic]string,   // the permissions the person granted, by plugin
	picked:    map[string][dynamic]string,   // the files and folders the person picked for it (files.pick)
}

@(private)
toml_state_free :: proc(t: ^Toml_State) {
	for k in t.enabled { delete(k) }
	delete(t.enabled)
	for k in t.suspended { delete(k) }
	delete(t.suspended)
	for k, l in t.granted { delete(k); for s in l { delete(s) }; delete(l) }
	delete(t.granted)
	for k, l in t.picked { delete(k); for s in l { delete(s) }; delete(l) }
	delete(t.picked)
}

// The sections [enabled] and [suspended] (`<id> = true`), [granted] (`<id> = "word word"`) and [picked] (`<id> =
// "path"`, a line per path, `\"` and `\\` escaped).
@(private)
toml_read :: proc(path: string) -> (t: Toml_State) {
	t.enabled = make(map[string]bool)
	t.suspended = make(map[string]bool)
	t.granted = make(map[string][dynamic]string)
	t.picked = make(map[string][dynamic]string)
	if path == "" { return }
	data, ok := fsx.read_all(path, context.temp_allocator, TOML_MAX_BYTES)
	if !ok { return }
	section := ""
	rest := string(data)
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		if line[0] == '[' { section = strings.trim(line, "[] "); continue }
		key, _, value := strings.partition(line, "=")
		key = strings.trim(strings.trim_space(key), "\"")
		value = strings.trim_space(value)
		if !id_valid(key, false) { continue }
		switch section {
		case "enabled":   if value == "true" { t.enabled[strings.clone(key)] = true }
		case "suspended": if value == "true" { t.suspended[strings.clone(key)] = true }
		case "granted":
			list := toml_list(&t.granted, key)
			for w in strings.fields(toml_unquote(value), context.temp_allocator) {
				if _, normal, good := permission_parse(w, context.allocator); good { append(list, normal) }
			}
		case "picked":
			if p := toml_unquote(value); p != "" { append(toml_list(&t.picked, key), strings.clone(p)) }
		}
	}
	return
}

@(private)
toml_list :: proc(m: ^map[string][dynamic]string, key: string) -> ^[dynamic]string {
	if key not_in m^ { m^[strings.clone(key)] = make([dynamic]string) }
	return &m^[key]
}

// A quoted value's text ("a \"b\" c\\d" -> a "b" c\d), in the temporary memory.
@(private)
toml_unquote :: proc(value: string) -> string {
	if len(value) < 2 || value[0] != '"' || value[len(value) - 1] != '"' { return "" }
	b := strings.builder_make(context.temp_allocator)
	inner := value[1:len(value) - 1]
	for i := 0; i < len(inner); i += 1 {
		if inner[i] == '\\' && i + 1 < len(inner) { i += 1 }
		strings.write_byte(&b, inner[i])
	}
	return strings.to_string(b)
}

@(private)
toml_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]u8)s {
		if c == '"' || c == '\\' { strings.write_byte(b, '\\') }
		if c == '\n' || c == '\r' { continue }
		strings.write_byte(b, c)
	}
	strings.write_byte(b, '"')
}

// plugins.toml from the host's plugins, written on a chore. Interface thread.
@(private)
toml_write :: proc(h: ^Host) {
	if h.toml_path == "" { return }
	// (one write at a time: the one under way is followed by another, of the state then)
	if h.toml_writing { h.toml_again = true; return }
	h.toml_writing = true
	// (what goes to the chore is freed with the heap's allocator: the caller's may be a test's, or a frame's)
	context.allocator = runtime.heap_allocator()
	b := strings.builder_make()
	strings.write_string(&b, "# The plugins turned on, those suspended because their process crashed again and again, what the person granted each (gt:plugins).\n[enabled]\n")
	for p in h.plugins { if p.enabled && p.refused == "" { fmt.sbprintf(&b, "%s = true\n", p.manifest.id) } }
	strings.write_string(&b, "\n[suspended]\n")
	for p in h.plugins { if p.suspended && p.refused == "" { fmt.sbprintf(&b, "%s = true\n", p.manifest.id) } }
	strings.write_string(&b, "\n[granted]\n")
	for p in h.plugins {
		if p.refused != "" || len(p.granted) == 0 { continue }
		fmt.sbprintf(&b, "%s = ", p.manifest.id)
		toml_quote(&b, strings.join(p.granted[:], " ", context.temp_allocator))
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "\n[picked]\n")
	for p in h.plugins {
		if p.refused != "" { continue }
		for path in p.picked {
			fmt.sbprintf(&b, "%s = ", p.manifest.id)
			toml_quote(&b, path)
			strings.write_byte(&b, '\n')
		}
	}
	w := new(Toml_Write)
	w^ = {path = strings.clone(h.toml_path), text = strings.to_string(b), link = h.link}
	sync.atomic_add(&h.link.refs, 1)
	ui.task(h.state, toml_work, toml_done, w, toml_lost)
}

@(private)
Toml_Write :: struct {
	path, text: string,
	link:       ^Host_Link,   // (counted) the host, when the write is done: its next write, if one was asked
	written:    bool,         // the chore's: the file holds the text
}

// The writes of plugins.toml tried again after one failed (another program held the file), before giving up until the
// next change.
@(private) TOML_RETRIES :: 5

@(private)
toml_work :: proc(data: rawptr) {
	w := (^Toml_Write)(data)
	if dir := dir_of(w.path); dir != "" { fsx.make_dirs(dir) }
	w.written = fsx.write_atomic(w.path, transmute([]u8)w.text)
}

// The write done, on the interface's thread: the one asked meanwhile goes now.
@(private)
toml_done :: proc(data: rawptr, word: u64) {
	w := (^Toml_Write)(data)
	if h := w.link.host; h != nil {
		h.toml_writing = false
		// (a write that failed is made again, of the state now, a few times)
		if w.written {
			h.toml_failures = 0
		} else if h.toml_failures < TOML_RETRIES {
			h.toml_failures += 1
			h.toml_again = true
		}
		if h.toml_again {
			h.toml_again = false
			toml_write(h)
		}
	}
	toml_free(w)
}

// The window went before the write's answer: the host goes with it, nothing more is written.
@(private)
toml_lost :: proc(data: rawptr) { toml_free((^Toml_Write)(data)) }

@(private)
toml_free :: proc(w: ^Toml_Write) {
	context.allocator = runtime.heap_allocator()
	delete(w.path); delete(w.text)
	link_release(w.link)
	free(w)
}

@(private)
dir_of :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return i > 0 ? path[:i] : ""
}

// <the user's folder of `kind` for `program`>/<leaf>, owned ("": the system has none).
@(private)
in_user_dir :: proc(kind: platform.User_Dir, program, leaf: string) -> string {
	base := platform.user_dir(kind, program, context.temp_allocator)
	if base == "" { return strings.clone("") }
	return strings.clone(fsx.path_join(base, leaf))
}
