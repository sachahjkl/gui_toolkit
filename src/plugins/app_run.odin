package tk_plugins

// The program's module "app" in the plugin's process (app.odin is the program's side): the module made from what the
// start frame named (plugin_api.app_install), each call a request of the broker's whose answer is decoded into the
// call's result struct and given to the promise as a plain object, `app.on` and the events the program sends.

import "core:fmt"
import "core:mem"
import "core:strings"
import js "../js"
import plugin_api "../plugin_api"

// The module "app" of a runtime (run_open): its object, its source, the handlers of its events.
@(private)
app_open :: proc(r: ^Run) {
	if !r.p.app_given { return }
	r.realm.app_calls = r.p.app_calls
	r.realm.app_impl = app_impl
	r.app_api = js.retain(r.rt, plugin_api.app_install(r.ctx, &r.realm, app_on))
	r.app_source = plugin_api.app_module_source(&r.realm)
}

@(private)
app_close :: proc(r: ^Run) {
	// (the handlers' values went with the runtime)
	for k, l in r.app_handlers { delete(k); delete(l) }
	delete(r.app_handlers)
	delete(r.app_source)
}

// A call of the module: its argument, filled by the bridge, sent to the program; the promise waits for its answer.
@(private)
app_impl :: proc(c: ^plugin_api.Call, index: int, args: rawptr) -> js.Value {
	spec := c.realm.app_calls[index]
	w := plugin_api.Wire_Writer{buf = make([dynamic]u8, context.temp_allocator)}
	plugin_api.value_encode(&w, type_info_of(spec.types[0]), args)
	return broker_call(c, .App_Call, {spec.name, string(w.buf[:]), "", ""}, result = spec.types[1])
}

// The program's answer of a call, as the plain object of its result struct. False: the bytes are not one.
@(private)
app_result_js :: proc(r: ^Run, result: typeid, bytes: string) -> (js.Value, bool) {
	ti := type_info_of(result)
	buf, _ := mem.alloc(max(ti.size, 1), max(ti.align, 1), context.temp_allocator)
	rd := plugin_api.Wire_Reader{data = transmute([]u8)bytes}
	plugin_api.value_decode(&rd, ti, buf, context.temp_allocator)
	if rd.bad || rd.at != len(rd.data) { return js.UNDEFINED, false }
	v := plugin_api.value_to_js(r.ctx, ti, buf)
	js.root(r.rt, v)
	return v, true
}

// app.on(event, handler): the handler hears each of the program's `event`. The first handler of an event tells the
// program, which then sends it here (a plugin that listens to nothing is not woken by events).
@(private)
app_on :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	r := (^Run)((^plugin_api.Realm)(ctx.rt.host_data).user)
	name_v := js.arg(args, 0)
	f := js.arg(args, 1)
	if !js.is_string(name_v) { return js.throw_type_error(ctx, "app.on: the event's name must be a string") }
	if !js.is_callable(f) { return js.throw_type_error(ctx, "app.on: the handler must be a function") }
	name, _ := js.to_utf8(ctx, name_v, context.temp_allocator)
	known := false
	for e in r.p.app_events { known ||= e.name == name }
	if !known { return js.throw_type_error(ctx, fmt.tprintf("app.on: %s's module \"app\" has no event \"%s\"", r.p.app_name, name)) }
	if name in r.app_handlers {
		append(&r.app_handlers[name], js.retain(ctx.rt, f))
		return js.UNDEFINED
	}
	list := make([dynamic]js.Value)
	append(&list, js.retain(ctx.rt, f))
	r.app_handlers[strings.clone(name)] = list
	event_post(r.p, r.serial, .App_Listen, title = name)
	return js.UNDEFINED
}

// An event of the program's: its payload as a plain object, given to each handler.
@(private)
app_event_message :: proc(r: ^Run, m: Message) {
	list, ok := r.app_handlers[m.command]
	if !ok { return }
	payload: typeid
	for e in r.p.app_events { if e.name == m.command { payload = e.types[0] } }
	if payload == nil { return }
	v, good := app_result_js(r, payload, m.text)
	if !good {
		uncaught(r, fmt.tprintf("the program's event %s came with a payload that cannot be read", m.command))
		return
	}
	for f in list {
		if r.ended { return }
		call_settled(r, f, {v})
	}
}
