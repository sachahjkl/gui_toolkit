package tk_plugins

// The broker (plugins.md, "As built: capabilities"): what a plugin asks of files, the network and the clipboard is done
// by the program, not by the plugin's process. The grants live in the program (plugins.toml); a check made in the
// plugin's process is one its own code could skip if the engine were exploited. So the process sends a request (a call
// id, an operation, its arguments); the program checks the grant on the interface's thread (in memory, at once), does
// the work on the chores (a file, a request, a dialog: system calls), and answers with the call id. The process
// resolves or rejects the call's promise (PermissionError without the grant).
//
// What a request needs beyond its permission is checked where the work is done: a path's folder and every component
// under it (no `..`, no link), each redirect's origin, a person's act for clipboard.read and files.pick (the turn that
// runs when the request was read: Queue.turns).

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import "../ascii"
import "../fsx"
import http "../http"
import "../platform"
import "../tasks"
import "../ui"

// What a request asks.
@(private)
Broker_Op :: enum u8 { Files_Read, Files_Write, Files_Pick, Fetch, Clipboard_Read, Clipboard_Write, App_Call }

// A request of a plugin's process: its call id (unique in the process), what it asks, its arguments (heap, owned), and
// whether the turn that sent it is a person's act (the program's reader says it; the process cannot).
@(private)
Request :: struct {
	call:    u64,
	op:      Broker_Op,
	args:    [4]string,
	gesture: bool,
}

@(private)
request_clone :: proc(r: Request) -> Request {
	c := r
	for &a in c.args { a = strings.clone(a, runtime.heap_allocator()) }
	return c
}

@(private)
request_free :: proc(r: ^Request) {
	for a in r.args { delete(a, runtime.heap_allocator()) }
	r.args = {}
}

// The largest file a plugin reads or writes, the largest answer of a request, how long a request may take.
FILE_MAX_BYTES :: 16 << 20
FETCH_MAX_BYTES :: 16 << 20
FETCH_TIMEOUT :: 60 * time.Second

// The error names an answer gives the process (its promise's rejection).
PERMISSION_ERROR :: "PermissionError"
NETWORK_ERROR :: "NetworkError"
FILE_ERROR :: "FileError"

// A request, on the interface's thread (event_run): its grant, then its work.
@(private)
broker_request :: proc(h: ^Host, p: ^Plugin, serial: u64, req: Request) {
	switch req.op {
	case .Clipboard_Write:
		if !has_permission(p, "clipboard.write") { refuse(p, serial, req, "clipboard.write was not granted"); return }
		if h.state.window != nil { platform.set_clipboard(h.state.window, req.args[0]) }
		answer(p, serial, req.call, ok = true)
	case .Clipboard_Read:
		if !has_permission(p, "clipboard.read") { refuse(p, serial, req, "clipboard.read was not granted"); return }
		if !req.gesture { refuse(p, serial, req, "the clipboard is read only while the person acts in the plugin"); return }
		clipboard_ask(h, p, serial, req.call)
	case .Files_Pick:
		if !has_permission(p, "files") { refuse(p, serial, req, "files was not granted"); return }
		if !req.gesture { refuse(p, serial, req, "a file is picked only while the person acts in the plugin"); return }
		pick_ask(h, p, serial, req)
	case .Files_Read, .Files_Write:
		job := work_new(p, serial, req)
		if !tasks.add(ui.chores(), file_work, job) { work_lost(job) }
	case .Fetch:
		// (the first check here, the others on the worker with each hop: a call with no net permission at all is refused at once)
		if !net_allowed(p.granted[:], req.args[0]) { refuse(p, serial, req, "this address's origin was not granted"); return }
		job := work_new(p, serial, req)
		if !tasks.add(ui.chores(), fetch_work, job) { work_lost(job) }
	case .App_Call:
		app_request(h, p, serial, req)
	}
}

@(private)
has_permission :: proc(p: ^Plugin, word: string) -> bool {
	for g in p.granted { if g == word { return true } }
	return false
}

@(private)
refuse :: proc(p: ^Plugin, serial: u64, req: Request, why: string) {
	answer(p, serial, req.call, ok = false, error = PERMISSION_ERROR, text = why)
}

// The answer to call `call` of process `serial`, queued for the process (any thread). A process that ended meanwhile
// never reads it: the next start clears the queue.
@(private)
answer :: proc(p: ^Plugin, serial: u64, call: u64, ok: bool, has_value := false, text := "", error := "", status := 0, url := "") {
	context.allocator = runtime.heap_allocator()
	if sync_serial(p) != serial { return }
	queue_push(p, Message{
		kind = .Answer, serial = call, flag = ok, is_flag = has_value, text = strings.clone(text), key = strings.clone(error),
		number = f64(status), command = strings.clone(url),
	})
}

// (the serial of the plugin's process now: read on a worker, written on the interface's thread at a start; a stale
// read only drops an answer a new process would not know)
@(private)
sync_serial :: proc(p: ^Plugin) -> u64 { return sync.atomic_load(&p.serial) }

@(private)
sync_add_ref :: proc(p: ^Plugin) { sync.atomic_add(&p.refs, 1) }

@(private)
sync_add_link :: proc(l: ^Host_Link) { sync.atomic_add(&l.refs, 1) }

////////////////////////////////
// Work on the chores

// What a worker needs, copied on the interface's thread: the request, and the grants as they were.
@(private)
Work :: struct {
	p:        ^Plugin,   // (counted)
	serial:   u64,
	req:      Request,   // (owned)
	data_dir: string,    // (owned, the lists' strings too)
	granted:  [dynamic]string,
	picked:   [dynamic]string,
}

@(private)
work_new :: proc(p: ^Plugin, serial: u64, req: Request) -> ^Work {
	context.allocator = runtime.heap_allocator()
	w := new(Work)
	w^ = {p = p, serial = serial, req = request_clone(req), data_dir = strings.clone(p.data_dir)}
	for g in p.granted { append(&w.granted, strings.clone(g)) }
	for g in p.picked { append(&w.picked, strings.clone(g)) }
	sync_add_ref(p)
	return w
}

@(private)
work_free :: proc(w: ^Work) {
	context.allocator = runtime.heap_allocator()
	request_free(&w.req)
	delete(w.data_dir)
	for g in w.granted { delete(g) }
	delete(w.granted)
	for g in w.picked { delete(g) }
	delete(w.picked)
	plugin_release(w.p)
	free(w)
}

// The chores refused the work (the program ends): the call fails.
@(private)
work_lost :: proc(w: ^Work) {
	answer(w.p, w.serial, w.req.call, ok = false, error = FILE_ERROR, text = "the program is ending")
	work_free(w)
}

@(private)
file_work :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	w := (^Work)(data)
	defer work_free(w)
	full, refused, why := path_resolve(w.req.args[0], w.data_dir, w.granted[:], w.picked[:])
	if why != "" {
		answer(w.p, w.serial, w.req.call, ok = false, error = refused ? PERMISSION_ERROR : FILE_ERROR, text = why)
		return
	}
	switch w.req.op {
	case .Files_Read:
		data, ok := fsx.read_all(full, context.temp_allocator, FILE_MAX_BYTES)
		if !ok { answer(w.p, w.serial, w.req.call, ok = false, error = FILE_ERROR, text = "the file cannot be read"); return }
		answer(w.p, w.serial, w.req.call, ok = true, has_value = true, text = string(data))
	case .Files_Write:
		text := w.req.args[1]
		if len(text) > FILE_MAX_BYTES { answer(w.p, w.serial, w.req.call, ok = false, error = FILE_ERROR, text = "the text is too large"); return }
		if dir := dir_of(full); dir != "" { fsx.make_dirs(dir) }
		// (an atomic write renames a new file over the name: a link put there since the check is replaced, not followed)
		if !fsx.write_atomic(full, transmute([]u8)text) { answer(w.p, w.serial, w.req.call, ok = false, error = FILE_ERROR, text = "the file cannot be written"); return }
		answer(w.p, w.serial, w.req.call, ok = true)
	case .Files_Pick, .Fetch, .Clipboard_Read, .Clipboard_Write, .App_Call:
	}
}

// A plugin's path as a path of the system, on the worker. `refused`: the path is not the plugin's to reach (a
// permission's answer), else the error is the file's. The forms: relative (its data folder), "~documents/...",
// "~downloads/..." (their permission), absolute (a file the person picked, or a file under a folder they picked). Each
// component under the folder is looked at, links never followed: `..` and a link anywhere are refused.
path_resolve :: proc(path, data_dir: string, granted, picked: []string) -> (full: string, refused: bool, why: string) {
	if path == "" { return "", false, "the path is empty" }
	root, rel: string
	named :: proc(granted: []string, word: string) -> bool { for g in granted { if g == word { return true } }; return false }
	switch {
	case strings.has_prefix(path, "~documents/"), strings.has_prefix(path, "~downloads/"):
		docs := strings.has_prefix(path, "~documents/")
		if !named(granted, docs ? "folder:documents" : "folder:downloads") { return "", true, "this folder was not granted" }
		root = platform.known_folder_path(docs ? .Documents : .Downloads, context.temp_allocator)
		if root == "" { return "", false, "the system has no such folder" }
		rel = path[len("~documents/"):]
	case path_is_absolute(path):
		for g in picked {
			if path == g {
				// (a file picked: the name itself, never a link put there since)
				if fsx.path_kind(g) == .Link { return "", true, "the file picked is now a link" }
				return path, false, ""
			}
			if strings.has_prefix(path, g) && len(path) > len(g) && (path[len(g)] == '/' || path[len(g)] == '\\') {
				root, rel = g, path[len(g) + 1:]
				break
			}
		}
		if root == "" { return "", true, "this path is not one the person picked" }
	case:
		if data_dir == "" { return "", false, "the system has no data folder" }
		root, rel = data_dir, path
		fsx.make_dirs(data_dir)
	}
	parts := strings.split_multi(rel, {"/", "\\"}, context.temp_allocator)
	cur := root
	kept := 0
	for part, i in parts {
		switch part {
		case "", ".": continue
		case "..":    return "", true, "the path leaves its folder"
		}
		if strings.contains(part, ":") { return "", true, "the path has a drive or a stream in it" }
		cur = fsx.path_join(cur, part)
		kept += 1
		kind := fsx.path_kind(cur)
		if kind == .Link { return "", true, "the path goes through a link" }
		if i < len(parts) - 1 && kind == .File { return "", false, "a file is where a folder should be" }
	}
	if kept == 0 { return "", false, "the path names no file" }
	return cur, false, ""
}

@(private)
path_is_absolute :: proc(path: string) -> bool {
	if strings.has_prefix(path, "/") || strings.has_prefix(path, "\\") { return true }
	return len(path) >= 3 && path[1] == ':' && (path[2] == '\\' || path[2] == '/')
}

// A request, hop by hop: the client follows no redirect, the worker checks each hop's origin first.
@(private)
fetch_work :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	w := (^Work)(data)
	defer work_free(w)
	url := w.req.args[0]
	method := w.req.args[1] != "" ? ascii.upper(w.req.args[1]) : "GET"   // (an HTTP method folds by ASCII)
	body := w.req.args[2]
	content_type := w.req.args[3]
	for hop := 0; ; hop += 1 {
		if !net_allowed(w.granted[:], url) {
			why := hop == 0 ? "this address's origin was not granted" : "a redirect goes to an origin that was not granted"
			answer(w.p, w.serial, w.req.call, ok = false, error = PERMISSION_ERROR, text = why)
			return
		}
		headers := make([dynamic]http.Header, context.temp_allocator)
		if content_type != "" { append(&headers, http.Header{"Content-Type", content_type}) }
		req := http.Request{max_bytes = FETCH_MAX_BYTES, timeout = FETCH_TIMEOUT, headers = headers[:], no_redirects = true}
		if body != "" { req.body = transmute([]u8)body }
		res, err := http.request(method, url, req, context.temp_allocator)
		if err != .None {
			answer(w.p, w.serial, w.req.call, ok = false, error = NETWORK_ERROR, text = http.error_text(err))
			return
		}
		switch res.status {
		case 301, 302, 303, 307, 308:
			if location, has := http.header_value(res.headers, "Location"); has && hop < http.MAX_REDIRECTS {
				url = url_join(url, location)
				// (as a browser does: a 303, and a 301 or a 302 after a POST, go on as a GET without the body)
				if res.status == 303 || (method == "POST" && res.status != 307 && res.status != 308) { method, body, content_type = "GET", "", "" }
				continue
			}
		}
		answer(w.p, w.serial, w.req.call, ok = true, has_value = true, text = string(res.body), status = res.status, url = url)
		return
	}
}

// A redirect's Location from the address `base`.
url_join :: proc(base, location: string) -> string {
	if strings.contains(location, "://") { return location }
	scheme := strings.has_prefix(base, "https://") ? "https:" : "http:"
	if strings.has_prefix(location, "//") { return strings.concatenate({scheme, location}, context.temp_allocator) }
	origin, _ := origin_of(base)
	if strings.has_prefix(location, "/") { return strings.concatenate({origin, location}, context.temp_allocator) }
	path := base[len(origin):]
	if q := strings.index_any(path, "?#"); q >= 0 { path = path[:q] }
	dir := path[:max(strings.last_index_byte(path, '/'), 0)]
	return strings.concatenate({origin, dir, "/", location}, context.temp_allocator)
}

////////////////////////////////
// The clipboard and the file dialog: the window's, on the interface's thread or a worker that may block

// The key of the paste the broker asks for (ui.paste_request): one waits at a time, a newer one replaces it.
@(private)
CLIPBOARD_KEY_NAME :: "plugins.clipboard"

@(private)
clipboard_ask :: proc(h: ^Host, p: ^Plugin, serial, call: u64) {
	if h.clip.p != nil {
		// (one read waits at a time: the newer one wins, as a second paste replaces the first)
		answer(h.clip.p, h.clip.serial, h.clip.call, ok = false, error = FILE_ERROR, text = "another read of the clipboard came")
		plugin_release(h.clip.p)
	}
	sync_add_ref(p)
	h.clip = {p = p, serial = serial, call = call}
	if !ui.paste_request(ui.key_from_string(0, CLIPBOARD_KEY_NAME), {.Text}) {
		answer(p, serial, call, ok = false, error = FILE_ERROR, text = "this window has no clipboard")
		plugin_release(p)
		h.clip = {}
	}
}

// Each build (host_build): the clipboard's answer, when it came.
@(private)
clipboard_poll :: proc(h: ^Host) {
	if h.clip.p == nil { return }
	a, ok := ui.paste_answer(ui.key_from_string(0, CLIPBOARD_KEY_NAME), {.Text})
	if !ok { return }
	answer(h.clip.p, h.clip.serial, h.clip.call, ok = true, has_value = true, text = a.text)
	plugin_release(h.clip.p)
	h.clip = {}
}

// What the broker's clipboard read waits for.
@(private)
Clip_Wait :: struct {
	p:      ^Plugin,   // (counted; nil: none waits)
	serial: u64,
	call:   u64,
}

@(private)
Pick :: struct {
	using work: ^Work,
	folder:     bool,
	title:      string,   // (owned by work's request)
	result:     platform.Dialog_Result,   // (heap)
	host_link:  ^Host_Link,               // (counted)
}

@(private)
pick_ask :: proc(h: ^Host, p: ^Plugin, serial: u64, req: Request) {
	context.allocator = runtime.heap_allocator()
	k := new(Pick)
	k.work = work_new(p, serial, req)
	k.folder, k.title = req.args[0] == "folder", k.work.req.args[1]
	k.host_link = h.link
	sync_add_link(h.link)
	ui.task(h.state, pick_work, pick_done, k, pick_lost)
}

// The dialog, on a chore (it waits for the person).
@(private)
pick_work :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	k := (^Pick)(data)
	d := platform.File_Dialog{title = k.title}
	k.result = k.folder ? platform.pick_folder_dialog(d) : platform.open_file_dialog(d)
}

// What the person picked is granted (kept in plugins.toml until revoked), then the answer.
@(private)
pick_done :: proc(data: rawptr, word: u64) {
	context.allocator = runtime.heap_allocator()
	k := (^Pick)(data)
	defer pick_free(k)
	if k.result.status != .Chosen || len(k.result.paths) == 0 {
		answer(k.p, k.serial, k.req.call, ok = k.result.status == .Cancelled, text = k.result.status == .Cancelled ? "" : "the system has no file dialog", error = k.result.status == .Cancelled ? "" : FILE_ERROR)
		return
	}
	path := k.result.paths[0]
	if h := k.host_link.host; h != nil && !k.p.dropped {
		known := false
		for g in k.p.picked { known ||= g == path }
		if !known { append(&k.p.picked, strings.clone(path)) }
		toml_write(h)
	}
	answer(k.p, k.serial, k.req.call, ok = true, has_value = true, text = path)
}

@(private)
pick_lost :: proc(data: rawptr) {
	k := (^Pick)(data)
	answer(k.p, k.serial, k.req.call, ok = false, error = FILE_ERROR, text = "the program is ending")
	pick_free(k)
}

@(private)
pick_free :: proc(k: ^Pick) {
	context.allocator = runtime.heap_allocator()
	platform.dialog_result_destroy(&k.result)
	link_release(k.host_link)
	work_free(k.work)
	free(k)
}
