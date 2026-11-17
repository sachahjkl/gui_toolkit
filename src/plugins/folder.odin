package tk_plugins

// The plugins' folder, plugins.toml and the markers, read on a chore (the interface's thread makes no system call),
// the result posted back whole: the plugins of a read replace those of the last.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "../fsx"
import "../platform"
import "../process"
import "../ui"

TOML_FILE :: "plugins.toml"
TOML_MAX_BYTES :: 1 << 20
// A marker's file name: inside-<pid>-<plugin id>.txt in the state folder.
MARKER_PREFIX :: "inside-"
MARKER_SUFFIX :: ".txt"

@(private)
Read_Job :: struct {
	link:      ^Host_Link,   // (counted)
	serial:    u64,
	program, program_id, folder_opt, config_opt, state_opt: string,
	// made by the chore
	folder, toml_path, state_dir: string,
	plugins:   [dynamic]^Plugin,
	suspended_now: [dynamic]string,   // the plugins the last run of a process ended inside
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
	}
	sync.atomic_add(&h.link.refs, 1)
	ui.task(h.state, read_work, read_done, j, read_lost)
}

@(private)
read_job_free :: proc(j: ^Read_Job) {
	context.allocator = runtime.heap_allocator()
	for p in j.plugins { plugin_release(p) }
	delete(j.plugins)
	for s in j.suspended_now { delete(s) }
	delete(j.suspended_now)
	delete(j.program); delete(j.program_id); delete(j.folder_opt); delete(j.config_opt); delete(j.state_opt)
	delete(j.folder); delete(j.toml_path); delete(j.state_dir)
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

	enabled, suspended := toml_read(j.toml_path)
	defer {
		for k in enabled { delete(k) }
		delete(enabled)
		for k in suspended { delete(k) }
		delete(suspended)
	}
	markers_read(j)
	if j.folder == "" { return }
	entries, err := fsx.read_folder(j.folder, context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: fsx.Folder_Entry) -> bool { return a.name < b.name })
	pid := os.get_pid()
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
		id := p.manifest.id
		if j.state_dir != "" && id_valid(id, false) {
			p.log_path = strings.clone(fsx.path_join(j.state_dir, fmt.tprintf("%s.log", id)))
			p.marker_path = strings.clone(fsx.path_join(j.state_dir, fmt.tprintf("%s%d-%s%s", MARKER_PREFIX, pid, id, MARKER_SUFFIX)))
		}
		now_suspended := false
		for s in j.suspended_now { now_suspended ||= s == id }
		p.suspended = suspended[id] || now_suspended
		p.enabled = enabled[id] && !p.suspended
		switch {
		case p.refused != "": p.state = .Refused
		case p.suspended:     p.state = .Suspended
		case p.enabled:       p.state = .Ready
		case:                 p.state = .Off
		}
		append(&j.plugins, p)
	}
}

// The markers of the state folder: one of a process that is gone (or whose id now names another process) names the
// plugin it ended inside. It goes; another instance's, alive, stays.
@(private)
markers_read :: proc(j: ^Read_Job) {
	if j.state_dir == "" { return }
	own := u64(os.get_pid())
	for f in fsx.list_files(j.state_dir, context.temp_allocator) {
		if !strings.has_prefix(f.name, MARKER_PREFIX) || !strings.has_suffix(f.name, MARKER_SUFFIX) { continue }
		path := fsx.path_join(j.state_dir, f.name)
		text, ok := fsx.read_all(path, context.temp_allocator, 4096)
		if !ok { continue }
		pid, start: u64
		plugin := ""
		rest := string(text)
		for line in strings.split_lines_iterator(&rest) {
			key, _, value := strings.partition(line, ": ")
			switch key {
			case "pid":    pid, _ = strconv.parse_u64(value, 10)
			case "start":  start, _ = strconv.parse_u64(value, 10)
			case "plugin": plugin = value
			}
		}
		if pid == 0 || pid == own { continue }   // (this process's own: a runtime of a reload that still ends)
		now, alive := process.process_start_time(i32(pid))
		if alive && now == start { continue }
		if plugin != "" { append(&j.suspended_now, strings.clone(plugin)) }
		_ = fsx.delete_file(path)
	}
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
	delete(h.folder); delete(h.toml_path); delete(h.state_dir)
	h.folder, h.toml_path, h.state_dir = j.folder, j.toml_path, j.state_dir
	j.folder, j.toml_path, j.state_dir = "", "", ""
	h.loaded = true
	h.source.version += 1
	if len(j.suspended_now) > 0 {
		toml_write(h)
		for id in j.suspended_now {
			if p := find(h, id); p != nil {
				say(h, .Warn, fmt.tprintf("%s is suspended", p.manifest.name), "The program ended while it ran. Turn it on again in the settings' Plugins page.")
			}
		}
	}
}

// What plugins.toml says: the plugins turned on, and those suspended. Keys owned.
@(private)
toml_read :: proc(path: string) -> (enabled, suspended: map[string]bool) {
	enabled = make(map[string]bool)
	suspended = make(map[string]bool)
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
		if strings.trim_space(value) != "true" || !id_valid(key, false) { continue }
		switch section {
		case "enabled":   enabled[strings.clone(key)] = true
		case "suspended": suspended[strings.clone(key)] = true
		}
	}
	return
}

// plugins.toml from the host's plugins, written on a chore. Interface thread.
@(private)
toml_write :: proc(h: ^Host) {
	if h.toml_path == "" { return }
	b := strings.builder_make()
	strings.write_string(&b, "# The plugins turned on, and those suspended because the program ended while they ran (gt:plugins).\n[enabled]\n")
	for p in h.plugins { if p.enabled && p.refused == "" { fmt.sbprintf(&b, "%s = true\n", p.manifest.id) } }
	strings.write_string(&b, "\n[suspended]\n")
	for p in h.plugins { if p.suspended && p.refused == "" { fmt.sbprintf(&b, "%s = true\n", p.manifest.id) } }
	w := new(Toml_Write)
	w^ = {path = strings.clone(h.toml_path), text = strings.to_string(b)}
	ui.task(h.state, toml_work, nil, w, toml_free)
}

@(private)
Toml_Write :: struct { path, text: string }

@(private)
toml_work :: proc(data: rawptr) {
	w := (^Toml_Write)(data)
	if dir := dir_of(w.path); dir != "" { fsx.make_dirs(dir) }
	_ = fsx.write_atomic(w.path, transmute([]u8)w.text)
	toml_free(w)
}

@(private)
toml_free :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	w := (^Toml_Write)(data)
	delete(w.path); delete(w.text)
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
