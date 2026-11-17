package tk_plugins

// A plugin's settings on its own thread: the values its thread started with, each change the interface sent, and
// settings.onChange's handlers (settings.odin is the interface's side).

import "core:fmt"
import "core:strings"
import js "../js"
import plugin_api "../plugin_api"

// The values the thread starts with, taken from the plugin (plugin_start made them).
@(private)
settings_take :: proc(r: ^Run) {
	for s in r.p.settings_start { r.settings[s.id] = s }   // (the keys are the values' ids: one allocation each)
	delete(r.p.settings_start)
}

@(private)
settings_free :: proc(r: ^Run) {
	for _, s in r.settings { setting_now_free(s) }
	delete(r.settings)
	delete(r.setting_handlers)   // (the values go with the runtime)
}

// A setting changed (a Setting message): the copy updated, each handler called with its id and value.
@(private)
setting_message :: proc(r: ^Run, m: Message) {
	s, ok := r.settings[m.key]
	if !ok || s.kind != m.setting { return }
	delete(s.value.s)
	switch m.setting {
	case .Bool:   s.value.b = m.flag
	case .Int:    s.value.i = i64(m.number)
	case .Float:  s.value.f = m.number
	case .String: s.value.s = strings.clone(m.text)
	}
	if m.setting != .String { s.value.s = "" }
	r.settings[s.id] = s
	for f in r.setting_handlers {
		if r.ended { return }
		id := js.new_string(r.ctx, s.id)
		call_settled(r, f, {id, setting_value(r, s)})
	}
	// (a handler may change what a view shows: each open view renders again)
	for _, rv in r.views { rv.dirty = true }
}

@(private)
setting_value :: proc(r: ^Run, s: Setting_Now) -> js.Value {
	switch s.kind {
	case .Bool:   return js.new_bool(s.value.b)
	case .Int:    return js.new_number(f64(s.value.i))
	case .Float:  return js.new_number(s.value.f)
	case .String: return js.new_string(r.ctx, s.value.s)
	}
	return js.UNDEFINED
}

@(private)
settings_get :: proc(c: ^plugin_api.Call, a: ^plugin_api.Settings_Get) -> js.Value {
	r := (^Run)(c.realm.user)
	s, ok := r.settings[a.id]
	if !ok { return js.throw_type_error(c.ctx, fmt.tprintf("settings.get: plugin.json declares no setting \"%s\"", a.id)) }
	return setting_value(r, s)
}

@(private)
settings_on_change :: proc(c: ^plugin_api.Call, a: ^plugin_api.Settings_On_Change) -> js.Value {
	r := (^Run)(c.realm.user)
	append(&r.setting_handlers, js.retain(c.ctx.rt, js.Value(a.handler)))
	return js.UNDEFINED
}
