// Package plugins: a program's plugins in JavaScript (src/md/features/plugins.md; docs/plugins.md). The folder is read on
// a chore, each manifest gives commands to the palette, and a plugin's thread and runtime start at its first use. The
// interface's thread never runs JavaScript and never waits for a plugin: it sends messages and reads what was posted.
//
//	plugins.host_open(&app.plugins, &app.ui, {program = APP_FOLDER, announcer = &app.announcer})
//	plugins.host_build(&app.plugins, &app.palette)   // each build, before ui.palette_chosen: the source, the bounds
//	o.pages = {..., plugins.page_info(&app.plugins)}  // the settings' Plugins page
//	plugins.host_close(&app.plugins)                 // before ui.destroy
//
// Only a program that imports this package links the engine (2 MB): the toolkit's other packages never import it.
package tk_plugins

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import config "../config"
import plugin_api "../plugin_api"
import "../tasks"
import "../ui"

// A plugin's state (plugins.md, decision 5): one enum, the Plugins page's words.
//
//	Found -> Refused        (manifest, level, program)
//	Found -> Off -> Ready   (turned on; contributions registered, no runtime)
//	Ready -> Starting -> Running -> Ready      (stopped, reloaded)
//	Running -> Not_Responding -> Ready         (stopped by the person)
//	Running -> Failed                          (activate threw, memory limit)
//	Running -> Failed -> Ready                 (its process crashed; Restart)
//	any -> Suspended                           (its process crashed CRASHES_TO_SUSPEND times in a run)
Plugin_State :: enum u8 {
	Found,
	Refused,
	Off,
	Ready,
	Starting,
	Running,
	Not_Responding,
	Failed,
	Suspended,
}

PLUGIN_STATE_WORDS :: [Plugin_State]string{
	.Found = "Found", .Refused = "Refused", .Off = "Off", .Ready = "Ready", .Starting = "Starting",
	.Running = "Running", .Not_Responding = "Not responding", .Failed = "Failed", .Suspended = "Suspended",
}

// How long a message may go without a turn of the plugin's queue before it is Not_Responding.
NOT_RESPONDING_MS :: 2000
// A plugin's heap budget (Host_Config.malloc_limit), and the addresses its runtime reserves for its cells.
MEMORY_LIMIT :: 64 << 20
RESERVE_BYTES :: 1 << 30
// How long host_close waits for the plugins' threads to end after their Stop.
CLOSE_BOUND :: 2 * time.Second
// The command that reads the folder again, an item of the palette's plugin source.
RELOAD_COMMAND :: "plugins.reload"
// The prefix of a plugin's commands: plugin.<plugin id>.<command id>.
COMMAND_PREFIX :: "plugin."

Host_Options :: struct {
	program:      string,   // the program's folder (platform.user_dir's `program`: "<vendor>/<Title>")
	program_id:   string,   // what a manifest's "program" must say ("": a manifest that names a program is refused)
	folder:       string,   // the plugins' folder ("": user_dir(.Data, program)/plugins)
	config_dir:   string,   // where plugins.toml is ("": user_dir(.Config, program))
	state_dir:    string,   // the plugins' logs ("": user_dir(.State, program)/plugins)
	data_dir:     string,   // each plugin's own data folder is in it ("": user_dir(.Data, program)/plugin-data)
	// one plugin instead of the folder: its folder, or a lone .js file whose manifest is implied (gt-runtime). It is
	// on from the start; `folder` is not read
	single:       string,
	// the program's preferences: the plugins' settings are registered there (plugins.<plugin id>.<setting id>), shown
	// by its settings (settings_pages) and kept in its file. nil: a plugin's settings keep their defaults
	prefs:        ^config.Prefs,
	announcer:    ^ui.Announcer,   // where a plugin's messages go (nil: the window's toasts)
	bound_ms:     int,      // 0: NOT_RESPONDING_MS
	memory_limit: i64,      // 0: MEMORY_LIMIT
	sandbox:      Sandbox_Mode,   // whether a plugin's process is isolated by the system (sandbox_linux.odin)
	// the program's own module, `import { ... } from "app"` (app.odin; nil: none). The program keeps it, unchanged,
	// while the host is open
	app:          ^App_Module,
}

// A program's own module and its parts (plugin_api's: the same reflection as the module "gt"; plugins.md, "As built:
// a program's own module").
App_Module :: plugin_api.App_Module
App_Call :: plugin_api.App_Call
App_Event :: plugin_api.App_Event
App_Permission :: plugin_api.App_Permission
App_Token :: plugin_api.App_Token

// How a plugin's process is isolated by the system (plugins.md, "As built: the sandbox").
Sandbox_Mode :: enum u8 {
	If_Available,   // isolated where the system can; elsewhere it runs as before, and its log says so once
	Required,       // a plugin whose process cannot be isolated is Failed
	Off,            // not isolated (a program's own debugging)
}

// The program's plugins, kept by the program between frames (host_open to host_close), at a place that does not move.
Host :: struct {
	o:         Host_Options,   // (strings owned)
	state:     ^ui.State,
	plugins:   [dynamic]^Plugin,
	views:     [dynamic]^View_Record,   // every plugin view declared since host_open, kept across reloads (view.odin)
	link:      ^Host_Link,
	// the paths the folder's chore found (owned; "" until the first read came)
	folder, toml_path, state_dir: string,
	read_serial: u64,      // the read in flight's (a reload's answer replaces an older one's)
	read_once:   bool,     // the first read was asked
	loaded:      bool,     // a read came
	source:      ui.Palette_Source,
	palette:     ^ui.Command_Palette,   // the palette host_build added the source to (host_close removes it)
	watch:       int,                   // config.watch's id of the plugins' preferences (0: none)
	clip:        Clip_Wait,             // a clipboard.read waiting for the window's answer (broker.odin)
	grant_for:   string,                // the plugin whose grant dialog is open or due (owned; "": none; grant.odin)
	grant_due:   bool,                  // the dialog opens at the next build
	grant_view:  bool,                  // the dialog's view is registered
	single_asked: bool,                 // gt-runtime's plugin was looked at for a grant at its start
	// plugins.toml's writer, one write at a time: idle, writing, or writing with another asked (the last state wins;
	// two writes on two chores could end in either order, the older content last)
	toml_writing: bool,
	toml_again:   bool,
	toml_failures: int,   // the writes that failed one after another (TOML_RETRIES)
	window_announcer: ui.Announcer,   // Host_Options.announcer nil: the window's toasts
	// what a test reads: the toasts said (count), and the last one's words (owned)
	toasts:      int,
	last_toast:  string,
	// the program's module's calls that wait for the program's answer, by their token (app.odin)
	app_waiting: map[App_Token]App_Waiting,
	app_tokens:  App_Token,   // the last token given
}

// What the chores and the plugins' threads reach the host by: `open` false once host_close ran (under `lock`, which a
// post holds: no post can reach a State after host_close).
@(private)
Host_Link :: struct {
	lock:  sync.Mutex,
	open:  bool,
	state: ^ui.State,
	host:  ^Host,  // (the interface thread's: a chore's answer finds the host by it; nil once closed)
	refs:  i32,    // (atomic) the host's and each job's
}

@(private)
link_release :: proc(l: ^Host_Link) {
	if sync.atomic_sub(&l.refs, 1) == 1 { free(l, runtime.heap_allocator()) }
}

// Posts `fn(data)` to the host's interface thread. False: the host is closed, or the queue refused it; the caller frees
// `data`.
@(private)
link_post :: proc(l: ^Host_Link, fn: ui.Post_Proc, data: rawptr) -> bool {
	sync.lock(&l.lock)
	defer sync.unlock(&l.lock)
	return l.open && ui.post(l.state, fn, data)
}

// Starts the host: the folder is read on a chore at the first host_build. Call it on the interface's thread.
host_open :: proc(h: ^Host, s: ^ui.State, o: Host_Options) {
	context.allocator = runtime.heap_allocator()
	h^ = {}
	h.state = s
	h.o = o
	h.o.program, h.o.program_id = strings.clone(o.program), strings.clone(o.program_id)
	h.o.folder, h.o.config_dir, h.o.state_dir = strings.clone(o.folder), strings.clone(o.config_dir), strings.clone(o.state_dir)
	h.o.single, h.o.data_dir = strings.clone(o.single), strings.clone(o.data_dir)
	if h.o.bound_ms <= 0 { h.o.bound_ms = NOT_RESPONDING_MS }
	if h.o.memory_limit <= 0 { h.o.memory_limit = MEMORY_LIMIT }
	if h.o.app != nil {
		// (a declaration that is wrong is the program's bug, found at its first run, not by a plugin's author)
		why := plugin_api.app_module_check(h.o.app)
		fmt.assertf(why == "", "plugins: Host_Options.app: %s", why)
	}
	h.window_announcer = {mode = .Window, state = s}
	h.link = new(Host_Link)
	h.link^ = {open = true, state = s, host = h, refs = 1}
	if h.o.prefs != nil { h.watch = config.watch(h.o.prefs, SETTINGS_PREFIX, setting_changed, h) }
	h.source = {
		name = "plugin", title = "Plugins", prefix = .Commands, plain = true, listed = true, remember = true,
		read = source_read, act = source_act, user = h,
	}
}

// Stops every plugin, waits for their threads within CLOSE_BOUND, and frees the host. Call it before ui.destroy (a
// thread that did not end in time posts nothing after this).
host_close :: proc(h: ^Host) {
	context.allocator = runtime.heap_allocator()
	for p in h.plugins { plugin_stop(p) }
	began := time.tick_now()
	for time.tick_since(began) < CLOSE_BOUND {
		all := true
		for p in h.plugins { all &&= !p.alive || sync.atomic_load(&p.ended) }
		if all { break }
		time.sleep(time.Millisecond)   // (the program's end: the window is gone, nothing waits for a frame)
	}
	// (a process that did not end in time does not outlive the program's interest in it)
	for p in h.plugins { if p.alive && !sync.atomic_load(&p.ended) && p.ch != nil { channel_kill(p.ch) } }
	sync.lock(&h.link.lock)
	h.link.open = false
	h.link.host = nil
	sync.unlock(&h.link.lock)
	link_release(h.link)
	plugins_drop(h)
	if h.o.prefs != nil && h.watch != 0 { config.unwatch(h.o.prefs, h.watch) }
	// (the window's views of the plugins close: their build's record goes)
	vs := ui.state_views(h.state)
	for r in h.views {
		if r.registered && ui.view_is_open(vs, r.ui_id) { ui.view_close(vs, r.ui_id) }
		view_record_free(r)
	}
	delete(h.views)
	if h.grant_view && ui.view_is_open(vs, GRANT_VIEW) { ui.view_close(vs, GRANT_VIEW) }
	delete(h.grant_for)
	if h.clip.p != nil { plugin_release(h.clip.p) }
	// (the palette outlives the host in most programs: it must not ask a source that is gone)
	if h.palette != nil { ui.palette_remove(h.palette, &h.source) }
	delete(h.plugins)
	delete(h.o.program); delete(h.o.program_id); delete(h.o.folder); delete(h.o.config_dir); delete(h.o.state_dir); delete(h.o.single); delete(h.o.data_dir)
	delete(h.folder); delete(h.toml_path); delete(h.state_dir)
	delete(h.last_toast)
	app_waiting_free(h)
	h^ = {}
}

// Each build of the window, before ui.palette_chosen: the first read of the folder, the palette's source (nil: none),
// and the plugins whose message ran past the bound (Not_Responding). Reads atomics only: it never waits.
host_build :: proc(h: ^Host, palette: ^ui.Command_Palette) {
	context.allocator = runtime.heap_allocator()
	if !h.read_once {
		h.read_once = true
		folder_read(h)
	}
	views_build(h)
	grant_build(h)
	clipboard_poll(h)
	if palette != nil && !ui.palette_has(palette, &h.source) {
		ui.palette_add(palette, &h.source)
		h.palette = palette
	}
	now := -1.0
	for p in h.plugins {
		since := sync.atomic_load(&p.busy_since)
		if since == 0 || p.state != .Running && p.state != .Starting { continue }
		if now < 0 { now = f64(now_ms()) }
		if now - f64(since) > f64(h.o.bound_ms) {
			p.state = .Not_Responding
			say(h, .Warn, fmt.tprintf("%s is not responding", p.manifest.name), "Stop it in the settings' Plugins page")
		}
	}
}

// The plugins found, in the folder's order: what the Plugins page lists.
host_plugins :: proc(h: ^Host) -> []^Plugin { return h.plugins[:] }

// The plugin of id `id` (nil: none).
find :: proc(h: ^Host, id: string) -> ^Plugin {
	for p in h.plugins { if p.manifest.id == id { return p } }
	return nil
}

// The state of plugin `id` (Found: no such plugin, or the folder not read yet).
state_of :: proc(h: ^Host, id: string) -> Plugin_State {
	p := find(h, id)
	return p != nil ? p.state : .Found
}

// Whether the folder was read (a test waits for it).
loaded :: proc(h: ^Host) -> bool { return h.loaded }

// Runs a command of the palette's plugin source: RELOAD_COMMAND, or plugin.<plugin id>.<command id>. False: no such
// command, or its plugin cannot run now (off, refused, failed, suspended).
run_command :: proc(h: ^Host, full_id: string) -> bool {
	context.allocator = runtime.heap_allocator()
	if full_id == RELOAD_COMMAND { reload(h); return true }
	if strings.has_prefix(full_id, VIEW_PREFIX) {
		rest := full_id[len(VIEW_PREFIX):]
		dot := strings.index_byte(rest, '.')
		return dot > 0 && open_view(h, rest[:dot], rest[dot + 1:])
	}
	plugin_id, command, ok := command_split(full_id)
	if !ok { return false }
	p := find(h, plugin_id)
	if p == nil || !can_run(p) { return false }
	known := false
	for c in p.manifest.commands { known ||= c.id == command }
	if !known { return false }
	if !p.alive { plugin_start(h, p) }
	queue_push(p, {kind = .Command, command = strings.clone(command)})
	wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
	return true
}

// plugin.<plugin id>.<command id> as its two ids (the plugin's has no dot).
command_split :: proc(full_id: string) -> (plugin_id, command: string, ok: bool) {
	if !strings.has_prefix(full_id, COMMAND_PREFIX) { return }
	rest := full_id[len(COMMAND_PREFIX):]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 || dot == len(rest) - 1 { return }
	return rest[:dot], rest[dot + 1:], true
}

// The palette's id of a plugin's command.
command_id :: proc(plugin_id, command: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({COMMAND_PREFIX, plugin_id, ".", command}, allocator)
}

// Turns a plugin on or off: kept in plugins.toml (written on a chore). Off stops its runtime. On also ends a
// suspension.
set_enabled :: proc(h: ^Host, id: string, on: bool) {
	context.allocator = runtime.heap_allocator()
	p := find(h, id)
	if p == nil || p.state == .Refused { return }
	// (one that asks for what was not granted: the person sees what it asks first, its Allow turns it on: grant)
	if on && len(p.manifest.permissions) > 0 && !permissions_covered(p.manifest.permissions, p.granted[:]) {
		grant_ask(h, id)
		return
	}
	p.enabled = on
	p.suspended = false
	if on {
		if !p.alive { p.state = .Ready }
	} else {
		plugin_stop(p)
		if !p.alive { p.state = .Off }
	}
	h.source.version += 1
	toml_write(h)
}

// Stops a plugin's runtime (its JavaScript is interrupted at its next loop or call; its process is killed when that
// does not end it within STOP_BOUND_MS): Ready once its process ended.
stop :: proc(h: ^Host, id: string) {
	if p := find(h, id); p != nil { plugin_stop(p) }
}

// A Failed plugin, Ready again: its next use starts a new process (its views' Restart). False: it is not Failed, or
// its process has not ended yet.
restart :: proc(h: ^Host, id: string) -> bool {
	p := find(h, id)
	if p == nil || p.state != .Failed || p.alive { return false }
	p.state = p.enabled ? .Ready : .Off
	h.source.version += 1
	return p.enabled
}

// Reads the folder again: every runtime stops, the manifests and plugins.toml are read on a chore, and the commands are
// registered again at the next build. The JavaScript state is lost.
reload :: proc(h: ^Host) {
	context.allocator = runtime.heap_allocator()
	folder_read(h)
}

@(private)
can_run :: proc(p: ^Plugin) -> bool {
	#partial switch p.state {
	case .Ready, .Starting, .Running, .Not_Responding: return true
	}
	return false
}

// A plugin's message, or the host's: a toast (`title` and `text` owned by the caller), counted for a test.
@(private)
say :: proc(h: ^Host, kind: ui.Toast_Kind, title: string, text := "") {
	h.toasts += 1
	delete(h.last_toast)
	h.last_toast = strings.clone(text != "" ? fmt.tprintf("%s: %s", title, text) : title)
	a := h.o.announcer != nil ? h.o.announcer : &h.window_announcer
	ui.announce(a, kind, title, text)
}

// The plugins dropped from the host: their runtimes stopped, their posts ignored from now on (`dropped`), each freed
// when its thread and its posts let go of it.
@(private)
plugins_drop :: proc(h: ^Host) {
	for p in h.plugins {
		plugin_stop(p)
		p.dropped = true
		plugin_release(p)
	}
	clear(&h.plugins)
	h.source.version += 1
}

// The margin of the wake after the bound: the build that sees the bound passed comes after it.
@(private)
WAKE_MARGIN_MS :: 50

// A build of the window in `ms`: a plugin that hangs makes no post, and the window may have nothing else to draw.
@(private)
wake_after :: proc(h: ^Host, ms: int) {
	sync.atomic_add(&h.link.refs, 1)
	if !tasks.add(ui.chores(), wake_work, h.link, {after_ms = ms}) { link_release(h.link) }
}

@(private)
wake_work :: proc(data: rawptr) {
	l := (^Host_Link)(data)
	link_post(l, proc(data: rawptr, word: u64) {}, nil)
	link_release(l)
}

@(private)
now_ms :: proc "contextless" () -> i64 {
	// (never 0: 0 is "waiting" in Plugin.busy_since)
	return max(time.tick_now()._nsec / 1_000_000, 1)
}
