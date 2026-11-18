package tk_plugins

// A plugin's thread: its runtime from its first use to its stop, and its turns. Everything here runs on that thread;
// what the interface must know goes back as an Event (plugin.odin).

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "../fsx"
import js "../js"
import plugin_api "../plugin_api"
import "../ui"

// The names of the host's modules: the API, and the one that starts the plugin's entry.
GT_MODULE :: "gt"
BOOT_MODULE :: "gt:boot"
// The most a module of a plugin may weigh.
MODULE_MAX_BYTES :: 8 << 20
// The most a plugin's log keeps (its tail).
LOG_MAX_BYTES :: 256 * 1024

// The host's module that starts the entry. A syntax error of the entry, an entry with no activate, and an activate that
// throws or rejects all end in boot.done(text): one place, which makes the plugin Failed.
@(private)
BOOT_HEAD :: `const boot = import.meta.boot;
const describe = (e) => (e instanceof Error && e.stack ? String(e) + "\n" + e.stack : String(e));
import(`
@(private)
BOOT_TAIL :: `).then((m) => {
	if (typeof m.activate !== "function") throw new TypeError("the entry exports no activate(context)");
	return m.activate(boot.context);
}).then(() => boot.done(""), (e) => boot.done(describe(e)));
`

// One runtime of a plugin.
@(private)
Run :: struct {
	p:          ^Plugin,
	serial:     u64,
	rt:         ^js.Runtime,
	ctx:        ^js.Context,
	realm:      plugin_api.Realm,
	api:        js.Value,                  // the API object (retained): import.meta.gt of the module "gt"
	boot:       js.Value,                  // import.meta.boot of BOOT_MODULE (retained)
	gt_source:  string,
	modules:    map[string]js.Value,       // each module read, by its name (retained; keys owned)
	handlers:   map[string]js.Value,       // commands.on's, by command id (retained; keys owned)
	views:      map[string]^Run_View,      // the views the plugin registered or the interface opened, by id (keys owned)
	settings:   map[string]Setting_Now,    // its settings' values, by id (settings_run.odin)
	setting_handlers: [dynamic]js.Value,   // settings.onChange's (retained)
	rejections: [dynamic][2]js.Value,      // the promises rejected with no handler yet, and their reasons (retained)
	boot_done:  bool,
	boot_error: string,
	toasted:    bool,                      // an uncaught exception was said once in this run
	ended:      bool,                      // stopped or failed: the thread leaves its loop
}

// The plugin's runtime in its process (child.odin): its start, then its turns until a Stop, a Quit or the end of the
// program's channel.
@(private)
plugin_thread :: proc(p: ^Plugin) {
	r := Run{p = p, serial = p.serial}
	opened := run_open(&r)
	free_all(context.temp_allocator)
	if opened {
		for !r.ended {
			m := queue_take(p)
			if m.kind == .Quit { message_free(m); break }
			run_turn(&r, m)
			message_free(m)
			// (what a turn made in the temporary memory, the bridge's strings among it: a plugin's thread lives long)
			free_all(context.temp_allocator)
		}
	}
	run_close(&r)
	event_post(p, r.serial, .Ended)
	plugin_release(p)
}

@(private)
run_open :: proc(r: ^Run) -> bool {
	p := r.p
	cfg := js.DEFAULT_CONFIG
	cfg.malloc_limit = p.memory_limit
	cfg.reserve_bytes = RESERVE_BYTES
	cfg.interrupt, cfg.interrupt_user = interrupt_hook, p
	cfg.load_module, cfg.load_user = load_module, r
	cfg.import_meta, cfg.meta_user = import_meta, r
	cfg.rejection, cfg.rejection_user = rejection_hook, r
	cfg.date_now_hook = date_now
	r.rt = js.engine_new(context.allocator, cfg)
	r.ctx = js.context_new(r.rt)
	r.realm.user = r
	plugin_api.realm_set(&r.realm, "commands", "on", plugin_api.implement(plugin_api.Commands_On, commands_on))
	plugin_api.realm_set(&r.realm, "toast", "show", plugin_api.implement(plugin_api.Toast_Show, toast_show))
	plugin_api.realm_set(&r.realm, "views", "register", plugin_api.implement(plugin_api.Views_Register, views_register))
	plugin_api.realm_set(&r.realm, "views", "update", plugin_api.implement(plugin_api.Views_Update, views_update))
	plugin_api.realm_set(&r.realm, "settings", "get", plugin_api.implement(plugin_api.Settings_Get, settings_get))
	plugin_api.realm_set(&r.realm, "settings", "onChange", plugin_api.implement(plugin_api.Settings_On_Change, settings_on_change))
	settings_take(r)
	// (no script runs until eval_source, so nothing is collected between these cells and their retain)
	r.api = js.retain(r.rt, plugin_api.install(r.ctx, &r.realm))
	r.gt_source = plugin_api.module_source()
	boot := js.new_object(r.ctx)
	js.set_property_str(r.ctx, boot, "done", js.new_function(r.ctx, boot_done, "done", 1))
	js.set_property_str(r.ctx, boot, "context", context_object(r))
	r.boot = js.retain(r.rt, boot)

	main := p.manifest.main
	spec := strings.concatenate({BOOT_HEAD, quoted("./", main), BOOT_TAIL}, context.temp_allocator)
	v := js.eval_source(r.ctx, spec, BOOT_MODULE, .module)
	ok := !js.is_exception(v) && js.run_jobs(r.rt)
	failure := ""
	if !ok {
		uncatchable := r.rt.uncatchable
		text := describe(r, js.pending_exception(r.ctx))
		if sync.atomic_load(&p.stop) { log_write(p, "stopped while it started"); return false }
		failure = uncatchable ? text : fmt.tprintf("its start threw: %s", text)
	} else if !r.boot_done {
		failure = "activate(context) returned a promise that did not settle"
	} else if r.boot_error != "" {
		failure = r.boot_error
	}
	if failure != "" {
		log_write(p, failure)
		event_post(p, r.serial, .Failed, text = failure)
		return false
	}
	log_write(p, "started")
	event_post(p, r.serial, .Started)
	return true
}

@(private)
run_close :: proc(r: ^Run) {
	if r.rt != nil { js.engine_free(r.rt) }   // (its block goes whole: every value retained above with it)
	for k in r.modules { delete(k) }
	delete(r.modules)
	for k in r.handlers { delete(k) }
	delete(r.handlers)
	for k, rv in r.views { delete(k); run_view_free(rv) }
	delete(r.views)
	settings_free(r)
	delete(r.rejections)
	delete(r.gt_source)
	delete(r.boot_error)
}

// One message: a command's handler, a view's opening or a node's handler, the jobs they left, then the renders of the
// views they made dirty. All of it counts as the message's time (the program's bound of Not_Responding counts from
// the message's write to its Turn_Done).
@(private)
run_turn :: proc(r: ^Run, m: Message) {
	switch m.kind {
	case .Command:
		h, ok := r.handlers[m.command]
		if !ok {
			uncaught(r, fmt.tprintf("no handler for its command %s: call commands.on(\"%s\", handler) in activate", m.command, m.command))
		} else {
			call_settled(r, h, {})
		}
	case .View_Open:  view_opened(r, m.view, true)
	case .View_Close: view_opened(r, m.view, false)
	case .View_Event: view_event(r, m)
	case .Setting:    setting_message(r, m)
	case .Test_Crash:
		// (what an engine's bug does to a process: it ends here, and only here)
		panic("plugins.test_crash: this plugin's process was asked to crash")
	case .Test_Hang:
		// (a host procedure stuck in the system: the interrupt flag is never read, only a kill ends it)
		for { time.sleep(time.Second) }
	case .Quit, .Stop:   // (the child's reader takes them: never queued for a turn)
	}
	if !r.ended { renders(r) }
	if !r.ended { event_post(r.p, r.serial, .Turn_Done) }
}

// Calls a function of the plugin, then runs the jobs it left; an exception goes to `exception`.
@(private)
call_settled :: proc(r: ^Run, f: js.Value, args: []js.Value) {
	v := js.call_function(r.ctx, f, js.UNDEFINED, args)
	if js.is_exception(v) || !js.run_jobs(r.rt) {
		exception(r)
	} else {
		rejections_report(r)
	}
}

// The exception pending after a call: a Stop (the interrupt), the memory limit (Failed), or the plugin's own error
// (logged, said once: the plugin goes on).
@(private)
exception :: proc(r: ^Run) {
	uncatchable := r.rt.uncatchable
	text := describe(r, js.pending_exception(r.ctx))
	if sync.atomic_load(&r.p.stop) {
		r.ended = true
		log_write(r.p, "stopped")
		return
	}
	if uncatchable {
		r.ended = true
		log_write(r.p, text)
		event_post(r.p, r.serial, .Failed, text = text)
		return
	}
	uncaught(r, text)
}

@(private)
uncaught :: proc(r: ^Run, text: string) {
	log_write(r.p, text)
	if r.toasted { return }
	r.toasted = true
	event_post(r.p, r.serial, .Toast, title = fmt.tprintf("%s: an error", r.p.manifest.name), text = text, toast = .Bad)
}

@(private)
rejections_report :: proc(r: ^Run) {
	for pair in r.rejections {
		uncaught(r, describe(r, pair[1]))
		js.release(r.rt, pair[0])
		js.release(r.rt, pair[1])
	}
	clear(&r.rejections)
}

// A value as the log says it: its text, and its stack when it is an error.
@(private)
describe :: proc(r: ^Run, e: js.Value) -> string {
	text, _ := js.to_utf8(r.ctx, e, context.temp_allocator)
	if js.is_object(e) {
		stack := js.get_property_str(r.ctx, e, "stack")
		if js.is_string(stack) {
			s, _ := js.to_utf8(r.ctx, stack, context.temp_allocator)
			if s != "" { return strings.concatenate({text, "\n", s}, context.temp_allocator) }
		}
	}
	return text
}

// What activate(context) is given.
@(private)
context_object :: proc(r: ^Run) -> js.Value {
	m := &r.p.manifest
	o := js.new_object(r.ctx)
	js.set_property_str(r.ctx, o, "id", js.new_string(r.ctx, m.id))
	js.set_property_str(r.ctx, o, "name", js.new_string(r.ctx, m.name))
	js.set_property_str(r.ctx, o, "version", js.new_string(r.ctx, m.version))
	js.set_property_str(r.ctx, o, "api", js.new_number(f64(plugin_api.PLUGIN_API_LEVEL)))
	return o
}

// `prefix` + `s` as a JavaScript string literal.
@(private)
quoted :: proc(prefix, s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]u8)strings.concatenate({prefix, s}, context.temp_allocator) {
		switch c {
		case '"', '\\': strings.write_byte(&b, '\\'); strings.write_byte(&b, c)
		case '\n': strings.write_string(&b, "\\n")
		case: strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

////////////////////////////////
// The engine's hooks

@(private)
interrupt_hook :: proc(rt: ^js.Runtime, user: rawptr) -> bool {
	return sync.atomic_load(&(^Plugin)(user).stop)
}

@(private)
date_now :: proc() -> f64 {
	return f64(time.to_unix_nanoseconds(time.now())) / 1e6
}

@(private)
rejection_hook :: proc(ctx: ^js.Context, promise: js.Value, reason: js.Value, handled: bool, user: rawptr) {
	r := (^Run)(user)
	if !handled {
		append(&r.rejections, [2]js.Value{js.retain(ctx.rt, promise), js.retain(ctx.rt, reason)})
		return
	}
	for pair, i in r.rejections {
		if pair[0].u.ptr != promise.u.ptr { continue }   // (a promise is a cell: its pointer names it)
		js.release(ctx.rt, pair[0])
		js.release(ctx.rt, pair[1])
		ordered_remove(&r.rejections, i)
		return
	}
}

// The plugin's modules: "gt", and its own files by a relative specifier, read once each.
@(private)
load_module :: proc(ctx: ^js.Context, referrer: string, specifier: string, attr_type: string, user: rawptr) -> js.Value {
	r := (^Run)(user)
	name := GT_MODULE
	if specifier != GT_MODULE {
		ok: bool
		name, ok = module_resolve(referrer, specifier)
		if !ok {
			return js.throw_type_error(ctx, fmt.tprintf("cannot import \"%s\": a plugin imports \"gt\" and the files of its own folder (\"./...\")", specifier))
		}
	}
	if v, had := r.modules[name]; had { return v }
	source := r.gt_source
	if name != GT_MODULE {
		data, ok := fsx.read_all(fsx.path_join(r.p.folder, name), context.temp_allocator, MODULE_MAX_BYTES)
		if !ok { return js.throw_error(ctx, .reference, fmt.tprintf("cannot read the module %s of its folder", name)) }
		source = string(data)
	}
	req := js.Compile_Request{kind = .module, source = source, filename = name}
	v := js.compile(ctx, &req)
	if js.is_exception(v) { return v }
	r.modules[strings.clone(name)] = js.retain(ctx.rt, v)
	return v
}

// A specifier ("./a.js", "../b.js") from the module `referrer`, as a path in the plugin's folder ("lib/a.js"). False:
// not relative, or out of the folder.
module_resolve :: proc(referrer, specifier: string) -> (name: string, ok: bool) {
	if !strings.has_prefix(specifier, "./") && !strings.has_prefix(specifier, "../") { return }
	parts := make([dynamic]string, context.temp_allocator)
	if referrer != BOOT_MODULE && referrer != GT_MODULE {
		if slash := strings.last_index_byte(referrer, '/'); slash >= 0 {
			for part in strings.split(referrer[:slash], "/", context.temp_allocator) { append(&parts, part) }
		}
	}
	for part in strings.split(specifier, "/", context.temp_allocator) {
		switch part {
		case ".":
		case "..":
			if len(parts) == 0 { return }
			pop(&parts)
		case "":
			return
		case:
			if strings.contains_any(part, "\\:") { return }
			append(&parts, part)
		}
	}
	if len(parts) == 0 { return }
	return strings.join(parts[:], "/", context.temp_allocator), true
}

@(private)
import_meta :: proc(ctx: ^js.Context, module_name: string, meta: js.Value, user: rawptr) {
	r := (^Run)(user)
	switch module_name {
	case GT_MODULE:   js.set_property_str(ctx, meta, "gt", r.api)
	case BOOT_MODULE: js.set_property_str(ctx, meta, "boot", r.boot)
	}
}

@(private)
boot_done :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	r := (^Run)((^plugin_api.Realm)(ctx.rt.host_data).user)
	text, _ := js.to_utf8(ctx, js.arg(args, 0), context.allocator)
	r.boot_done = true
	delete(r.boot_error)
	r.boot_error = text
	return js.UNDEFINED
}

////////////////////////////////
// The API's implementations (gt:plugin_api's declarations)

@(private)
commands_on :: proc(c: ^plugin_api.Call, a: ^plugin_api.Commands_On) -> js.Value {
	r := (^Run)(c.realm.user)
	known := false
	for d in r.p.manifest.commands { known ||= d.id == a.id }
	if !known {
		return js.throw_type_error(c.ctx, fmt.tprintf("commands.on: plugin.json declares no command \"%s\"", a.id))
	}
	f := js.retain(c.ctx.rt, js.Value(a.handler))
	if old, had := r.handlers[a.id]; had {
		js.release(c.ctx.rt, old)
		r.handlers[a.id] = f
	} else {
		r.handlers[strings.clone(a.id)] = f
	}
	return js.UNDEFINED
}

@(private)
toast_show :: proc(c: ^plugin_api.Call, a: ^plugin_api.Toast_Show) -> js.Value {
	r := (^Run)(c.realm.user)
	kinds := [plugin_api.Toast_Kind]ui.Toast_Kind{.info = .Info, .good = .Good, .warn = .Warn, .bad = .Bad}
	event_post(r.p, r.serial, .Toast, title = a.options.title, text = a.text, toast = kinds[a.options.kind])
	return js.UNDEFINED
}

////////////////////////////////
// The plugin's log

// A line at the end of the plugin's log, the oldest lines dropped past LOG_MAX_BYTES.
@(private)
log_write :: proc(p: ^Plugin, text: string) {
	if p.log_path == "" { return }
	old, _ := fsx.read_all(p.log_path, context.temp_allocator, LOG_MAX_BYTES * 2)
	line := fmt.tprintf("%d %s\n", time.to_unix_seconds(time.now()), text)
	all := strings.concatenate({string(old), line}, context.temp_allocator)
	if len(all) > LOG_MAX_BYTES {
		all = all[len(all) - LOG_MAX_BYTES:]
		if nl := strings.index_byte(all, '\n'); nl >= 0 { all = all[nl + 1:] }
	}
	_ = fsx.write_atomic(p.log_path, transmute([]u8)all)
}
