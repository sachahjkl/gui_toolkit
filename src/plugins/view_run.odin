package tk_plugins

// A plugin's views on its own thread: the renders it registered, which runs when a view opens, after each of its
// handlers and after views.update; each render written as a display list and posted to the interface (view.odin).

import "core:fmt"
import "core:strings"
import js "../js"
import plugin_api "../plugin_api"

// A view of the runtime.
@(private)
Run_View :: struct {
	render:     js.Value,              // (retained; with `registered`)
	registered: bool,
	open:       bool,                  // the interface shows it
	dirty:      bool,                  // its render runs at the end of the turn
	said:       bool,                  // "no render" was said for this opening
	handlers:   map[string]js.Value,   // the last render's, by "<key>\x1f<event>" (retained; keys owned)
	seen:       map[string]u64,        // the person's last change of each key the plugin heard of (keys owned)
	lists:      map[string]^Run_Rows,  // its lazy lists' rows' handlers, by the list's key (keys owned; lazy_list_run.odin)
}

@(private)
run_view_free :: proc(rv: ^Run_View) {
	// (the values go with the runtime: engine_free; only the keys are the heap's)
	for k in rv.handlers { delete(k) }
	delete(rv.handlers)
	for k, rl in rv.lists {
		for hk in rl.handlers { delete(hk) }
		delete(rl.handlers)
		free(rl)
		delete(k)
	}
	delete(rv.lists)
	for k in rv.seen { delete(k) }
	delete(rv.seen)
	free(rv)
}

// The runtime's record of view `id`, made at its first use. nil: the manifest declares no such view.
@(private)
run_view :: proc(r: ^Run, id: string) -> ^Run_View {
	if rv, ok := r.views[id]; ok { return rv }
	if manifest_view(&r.p.manifest, id) == nil { return nil }
	rv := new(Run_View)
	r.views[strings.clone(id)] = rv
	return rv
}

@(private)
view_opened :: proc(r: ^Run, id: string, open: bool) {
	rv := run_view(r, id)
	if rv == nil { return }
	rv.open = open
	rv.dirty = open
	rv.said = false
}

// A node of an open view was used: the change heard of, its handler called, the view rendered again after it.
@(private)
view_event :: proc(r: ^Run, m: Message) {
	rv := run_view(r, m.view)
	if rv == nil || !rv.open { return }
	if m.event == .onChange {
		if _, had := rv.seen[m.key]; had { rv.seen[m.key] = m.serial } else { rv.seen[strings.clone(m.key)] = m.serial }
	}
	names := [View_Event]string{.onClick = "onClick", .onChange = "onChange", .onSubmit = "onSubmit"}
	hk := handler_key(m.key, names[m.event])
	f, ok := rv.handlers[hk]
	// (a node of a lazy list's row: its handler came with its row, not with the render)
	if !ok { for _, rl in rv.lists { if g, has := rl.handlers[hk]; has { f, ok = g, true; break } } }
	if !ok { return }
	arg: js.Value
	switch {
	case m.event == .onClick: call_settled(r, f, {})
	case m.is_flag:           call_settled(r, f, {js.new_bool(m.flag)})
	case:
		arg = js.new_string(r.ctx, m.text)
		call_settled(r, f, {arg})
	}
	rv.dirty = true
}

@(private)
handler_key :: proc(key, event: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({key, "\x1f", event}, allocator)
}

// Each open view that changed renders, once, at the end of the turn.
@(private)
renders :: proc(r: ^Run) {
	for id, rv in r.views {
		if r.ended { return }
		if !rv.open || !rv.dirty { continue }
		rv.dirty = false
		if !rv.registered {
			if !rv.said { uncaught(r, fmt.tprintf("its view %s has no render: call views.register(\"%s\", render) in activate", id, id)) }
			rv.said = true
			continue
		}
		render(r, id, rv)
	}
}

@(private)
Render_Sink :: struct {
	rv:       ^Run_View,
	rt:       ^js.Runtime,
	handlers: map[string]js.Value,   // the new render's
}

@(private)
render :: proc(r: ^Run, id: string, rv: ^Run_View) {
	tree := js.call_function(r.ctx, rv.render, js.UNDEFINED, {})
	if js.is_exception(tree) { exception(r); return }
	// (kept while the list is written: a getter of a node may run a collection between two reads)
	js.retain(r.rt, tree)
	defer js.release(r.rt, tree)
	s := Render_Sink{rv = rv, rt = r.rt, handlers = make(map[string]js.Value)}
	list, ok := plugin_api.list_write(r.ctx, tree, render_sink(&s))
	if !ok {
		handlers_release(r.rt, &s.handlers)
		delete(s.handlers)
		exception(r)
		return
	}
	for p in list.problems { log_write(r.p, fmt.tprintf("its view %s: %s", id, p)) }
	handlers_release(r.rt, &rv.handlers)
	delete(rv.handlers)
	rv.handlers = s.handlers
	rows_forget(r, rv)
	event_post(r.p, r.serial, .List, title = id, list = list)
}

// What a list's writer gives back to a render (or to a lazy list's rows): the changes heard of, the handlers.
@(private)
render_sink :: proc(s: ^Render_Sink) -> plugin_api.List_Sink {
	return plugin_api.List_Sink{
		user = s,
		seen = proc(user: rawptr, key: string) -> u64 { return (^Render_Sink)(user).rv.seen[key] or_else 0 },
		handler = proc(user: rawptr, key: string, event: string, f: js.Value) {
			s := (^Render_Sink)(user)
			// (the plugin's thread's context: the heap, which run_view_free gives the keys back to)
			s.handlers[handler_key(key, event, context.allocator)] = js.retain(s.rt, f)
		},
	}
}

@(private)
handlers_release :: proc(rt: ^js.Runtime, m: ^map[string]js.Value) {
	for k, f in m {
		js.release(rt, f)
		delete(k)
	}
	clear(m)
}

////////////////////////////////
// The API's implementations

@(private)
views_register :: proc(c: ^plugin_api.Call, a: ^plugin_api.Views_Register) -> js.Value {
	r := (^Run)(c.realm.user)
	rv := run_view(r, a.id)
	if rv == nil { return js.throw_type_error(c.ctx, fmt.tprintf("views.register: plugin.json declares no view \"%s\"", a.id)) }
	if rv.registered { js.release(c.ctx.rt, rv.render) }
	rv.render = js.retain(c.ctx.rt, js.Value(a.render))
	rv.registered = true
	rv.dirty = true
	return js.UNDEFINED
}

@(private)
views_update :: proc(c: ^plugin_api.Call, a: ^plugin_api.Views_Update) -> js.Value {
	r := (^Run)(c.realm.user)
	rv := run_view(r, a.id)
	if rv == nil { return js.throw_type_error(c.ctx, fmt.tprintf("views.update: plugin.json declares no view \"%s\"", a.id)) }
	rv.dirty = true
	return js.UNDEFINED
}
