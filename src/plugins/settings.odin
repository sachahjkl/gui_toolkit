package tk_plugins

// A plugin's settings (plugins.md, slice 2): the manifest's "settings" registered as the program's preferences,
// plugins.<plugin id>.<setting id>, so the program's settings show them and its file keeps them. The plugin's thread
// never reads the registry (the interface thread's): it gets the values when it starts, then each change as a message.
// settings.get answers from that copy at once.

import "base:runtime"
import "core:strings"
import config "../config"
import prefs_page "../prefs_page"

// The prefix of a plugin's preferences.
SETTINGS_PREFIX :: "plugins."

// A setting's value as a plugin's thread holds it (`value.s` owned).
@(private)
Setting_Now :: struct {
	id:    string,   // (owned)
	kind:  config.Kind,
	value: config.Value,
}

@(private)
setting_now_free :: proc(s: Setting_Now) {
	a := runtime.heap_allocator()
	delete(s.id, a)
	delete(s.value.s, a)
}

// The preference of a plugin's setting.
setting_pref :: proc(plugin_id, setting_id: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({SETTINGS_PREFIX, plugin_id, ".", setting_id}, allocator)
}

// The plugins' settings registered with the program's preferences, after a read. A definition stays the registry's
// for its life (it has no unregister): its strings are kept for the process, a few bytes per setting a plugin ever
// declared. A setting registered again with another kind keeps the first (the registry's rule): its plugin's reload
// after the change needs the program's next start. Interface thread.
@(private)
settings_register :: proc(h: ^Host) {
	prefs := h.o.prefs
	if prefs == nil { return }
	a := runtime.heap_allocator()
	for p in h.plugins {
		if p.refused != "" || len(p.manifest.settings) == 0 { continue }
		defs := make([dynamic]config.Def, 0, len(p.manifest.settings), context.temp_allocator)
		for s in p.manifest.settings {
			name := setting_pref(p.manifest.id, s.id)
			if r := config.ref_of(prefs, name); r != config.NO_REF {
				if config.entry(prefs, r).def.kind != s.kind { continue }   // (see above: the registry asserts on a new kind)
			}
			d := config.Def{
				// (in the language in use now; settings_label gives them the next language's words)
				name = strings.clone(name, a), title = strings.clone(manifest_tr(&p.manifest, s.title), a), description = strings.clone(manifest_tr(&p.manifest, s.description), a),
				kind = s.kind, default = s.default, min = s.min, max = s.max, bounded = s.bounded,
			}
			d.default.s = strings.clone(s.default.s, a)
			if len(s.choices) > 0 {
				choices := make([]string, len(s.choices), a)
				for c, i in s.choices { choices[i] = strings.clone(c, a) }
				d.choices = choices
			}
			append(&defs, d)
		}
		config.register(prefs, defs[:])
	}
	// (a setting registered by an earlier read keeps its first Def: register does nothing for a known name, so the
	// words of a manifest read again come from here)
	settings_label(h)
}

// The titles and descriptions of the plugins' settings in the registry, in the language in use: after a read, and at
// each change of language (language_follow), never per build. The registry has no call to relabel a definition, but
// the Def of a plugin's setting is this package's own (settings_register cloned its strings on the heap), so its two
// strings are replaced in place. The words replaced are kept until the next relabel: a widget may hold a string of
// the build before for one build. Interface thread.
@(private)
settings_label :: proc(h: ^Host) {
	prefs := h.o.prefs
	if prefs == nil { return }
	a := runtime.heap_allocator()
	for old in h.labels_retired { delete(old, a) }
	clear(&h.labels_retired)
	for p in h.plugins {
		if p.refused != "" || len(p.manifest.settings) == 0 { continue }
		for s in p.manifest.settings {
			r := config.ref_of(prefs, setting_pref(p.manifest.id, s.id))
			if r == config.NO_REF { continue }
			d := &config.entry(prefs, r).def
			if d.kind != s.kind { continue }   // (another kind's Def, kept by the registry: settings_register)
			title, description := manifest_tr(&p.manifest, s.title), manifest_tr(&p.manifest, s.description)
			if d.title != title {
				append(&h.labels_retired, d.title)
				d.title = strings.clone(title, a)
			}
			if d.description != description {
				append(&h.labels_retired, d.description)
				d.description = strings.clone(description, a)
			}
		}
	}
}

// Each change of a plugin's preference (config.watch): its plugin hears it when its thread runs; a thread that starts
// later reads the values then (settings_snapshot).
@(private)
setting_changed :: proc(user: rawptr, name: string, prefs: ^config.Prefs) {
	context.allocator = runtime.heap_allocator()
	h := (^Host)(user)
	rest := name[len(SETTINGS_PREFIX):]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 { return }
	p := find(h, rest[:dot])
	if p == nil || !p.alive { return }
	r := config.ref_of(prefs, name)
	if r == config.NO_REF { return }
	e := config.entry(prefs, r)
	queue_push(p, Message{
		kind = .Setting, key = strings.clone(rest[dot + 1:]), setting = e.def.kind,
		flag = e.value.b, number = e.def.kind == .Int ? f64(e.value.i) : e.value.f, text = strings.clone(e.value.s),
	})
	wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
}

// The values of a plugin's settings now, for its thread that starts (heap; the thread frees them).
@(private)
settings_snapshot :: proc(h: ^Host, p: ^Plugin) -> []Setting_Now {
	prefs := h.o.prefs
	a := runtime.heap_allocator()
	out := make([dynamic]Setting_Now, 0, len(p.manifest.settings), a)
	for s in p.manifest.settings {
		now := Setting_Now{id = strings.clone(s.id, a), kind = s.kind, value = s.default}
		if prefs != nil {
			if r := config.ref_of(prefs, setting_pref(p.manifest.id, s.id)); r != config.NO_REF && config.entry(prefs, r).def.kind == s.kind {
				now.value = config.entry(prefs, r).value
			}
		}
		now.value.s = strings.clone(now.value.s, a)   // (the manifest's or the registry's: the thread's own from here)
		append(&out, now)
	}
	return out[:]
}

// The program's settings pages of the plugins: one per plugin that has settings, under its name (temp memory). A
// program puts them in Page_Options.pages, beside page_info's Plugins page.
settings_pages :: proc(h: ^Host) -> []prefs_page.Page_Info {
	out := make([dynamic]prefs_page.Page_Info, context.temp_allocator)
	if h.o.prefs == nil { return out[:] }
	for p in h.plugins {
		if p.refused != "" || len(p.manifest.settings) == 0 { continue }
		names := make([]string, len(p.manifest.settings), context.temp_allocator)
		for s, i in p.manifest.settings { names[i] = setting_pref(p.manifest.id, s.id) }
		category := strings.concatenate({SETTINGS_PREFIX, p.manifest.id}, context.temp_allocator)
		append(&out, prefs_page.Page_Info{category = category, title = p.manifest.name, names = names, heading = len(out) == 0 ? "PLUGINS" : ""})
	}
	return out[:]
}
