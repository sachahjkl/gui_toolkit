package tk_plugins

// The program's own module "app" on the program's side (plugins.md, "As built: a program's own module"): a call of a
// plugin's is a request of the broker's (op App_Call: args[0] the call's name, args[1] its argument encoded), run on
// the interface's thread in the request's event; its answer is the broker's answer, its result encoded in `text`.
// The plugin's process side is app_run.odin.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import plugin_api "../plugin_api"

// A call that waits for the program's answer (App_Run returned pending).
@(private)
App_Waiting :: struct {
	p:      ^Plugin,   // (counted)
	serial: u64,       // its process's
	call:   u64,       // the call's id in that process
	index:  int,       // in App_Module.calls
}

// A call of a plugin's (broker_request): its grant, its argument, the program's `run`, its answer now or later.
@(private)
app_request :: proc(h: ^Host, p: ^Plugin, serial: u64, req: Request) {
	context.allocator = runtime.heap_allocator()
	m := h.o.app
	if m == nil {
		answer(p, serial, req.call, ok = false, error = "Error", text = "this program gives no module \"app\"")
		return
	}
	i := plugin_api.app_call_index(m, req.args[0])
	if i < 0 {
		answer(p, serial, req.call, ok = false, error = "TypeError", text = fmt.tprintf("this program's module \"app\" has no call %s", req.args[0]))
		return
	}
	c := m.calls[i]
	if c.permission != "" && !has_permission(p, c.permission) {
		refuse(p, serial, req, fmt.tprintf("app.%s needs the permission %s, which the person did not grant", c.name, c.permission))
		return
	}
	// (the argument as the plugin's process wrote it from its struct: the same struct here, the same executable)
	args_ti := type_info_of(c.arguments)
	args, _ := mem.alloc(max(args_ti.size, 1), max(args_ti.align, 1), context.temp_allocator)
	r := plugin_api.Wire_Reader{data = transmute([]u8)req.args[1]}
	plugin_api.value_decode(&r, args_ti, args, context.temp_allocator)
	if r.bad || r.at != len(r.data) {
		answer(p, serial, req.call, ok = false, error = "Error", text = fmt.tprintf("app.%s: its argument cannot be read", c.name))
		return
	}
	result_ti := type_info_of(c.result)
	result, _ := mem.alloc(max(result_ti.size, 1), max(result_ti.align, 1), context.temp_allocator)
	h.app_tokens += 1
	token := h.app_tokens
	pending, why := c.run(m.user, token, args, result)
	switch {
	case why != "":
		answer(p, serial, req.call, ok = false, error = "Error", text = why)
	case !pending:
		answer(p, serial, req.call, ok = true, has_value = true, text = app_encode(result_ti, result))
	case:
		sync_add_ref(p)
		h.app_waiting[token] = App_Waiting{p = p, serial = serial, call = req.call, index = i}
	}
}

// The answer of a call that waited (its `run` returned pending): `result` is its result struct, of the call's result
// type (false: no call waits for this token, or `result` is of another type). Interface thread. The plugin's promise
// resolves with it as a plain object; a plugin whose process ended meanwhile hears nothing.
app_answer :: proc(h: ^Host, token: App_Token, result: ^$T) -> bool {
	context.allocator = runtime.heap_allocator()
	w, ok := h.app_waiting[token]
	if !ok || h.o.app == nil || h.o.app.calls[w.index].result != typeid_of(T) { return false }
	delete_key(&h.app_waiting, token)
	answer(w.p, w.serial, w.call, ok = true, has_value = true, text = app_encode(type_info_of(T), result))
	plugin_release(w.p)
	return true
}

// The failure of a call that waited: the plugin's promise rejects with an Error of `why`. False: no call waits for this
// token. Interface thread.
app_fail :: proc(h: ^Host, token: App_Token, why: string) -> bool {
	context.allocator = runtime.heap_allocator()
	w, ok := h.app_waiting[token]
	if !ok { return false }
	delete_key(&h.app_waiting, token)
	answer(w.p, w.serial, w.call, ok = false, error = "Error", text = why)
	plugin_release(w.p)
	return true
}

// Sends the event `event` of the program's module, its payload `payload` (of the event's payload type), to each
// running plugin that listens to it (app.on) and may hear it (its permission granted). A plugin that does not run is
// not started. It returns how many plugins it reached (-1: no such event, or `payload` is of another type). Interface
// thread.
app_emit :: proc(h: ^Host, event: string, payload: ^$T) -> int {
	context.allocator = runtime.heap_allocator()
	m := h.o.app
	if m == nil { return -1 }
	i := plugin_api.app_event_index(m, event)
	if i < 0 || m.events[i].payload != typeid_of(T) { return -1 }
	e := m.events[i]
	bytes := ""
	reached := 0
	for p in h.plugins {
		if !p.alive || p.dropped { continue }
		if e.permission != "" && !has_permission(p, e.permission) { continue }
		listens := false
		for l in p.app_listens { listens ||= l == event }
		if !listens { continue }
		if bytes == "" { bytes = app_encode(type_info_of(T), payload) }
		queue_push(p, Message{kind = .App_Event, command = strings.clone(event), text = strings.clone(bytes)})
		wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
		reached += 1
	}
	return reached
}

// The waiting calls are let go of (host_close): their plugins' processes are ending.
@(private)
app_waiting_free :: proc(h: ^Host) {
	for _, w in h.app_waiting { plugin_release(w.p) }
	delete(h.app_waiting)
}

// A value of type `ti` at `at` as the wire's bytes, in a string (the answer's and the event's `text`). Temp memory.
@(private)
app_encode :: proc(ti: ^runtime.Type_Info, at: rawptr) -> string {
	w := plugin_api.Wire_Writer{buf = make([dynamic]u8, context.temp_allocator)}
	plugin_api.value_encode(&w, ti, at)
	return string(w.buf[:])
}
