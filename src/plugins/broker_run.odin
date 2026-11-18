package tk_plugins

// The broker's calls in the plugin's process (broker.odin is the program's side): each call makes a promise, sends its
// request, and keeps the promise's resolving functions by the call's id until the answer comes, as a message like any
// other (a turn: its continuations run then, and the views it made dirty render).

import js "../js"
import plugin_api "../plugin_api"

// A call that waits for its answer.
@(private)
Pending_Call :: struct {
	op:      Broker_Op,
	resolve: js.Value,   // (retained)
	reject:  js.Value,
	result:  typeid,     // an App_Call's result struct: its answer is decoded as one (app_run.odin)
}

// The promise of a request `op`, sent at once.
@(private)
broker_call :: proc(c: ^plugin_api.Call, op: Broker_Op, args: [4]string, result: typeid) -> js.Value {
	r := (^Run)(c.realm.user)
	cap, ok := plugin_api.promise_new(c.ctx)
	if !ok { return js.EXCEPTION }
	js.root(c.ctx.rt, cap.promise)
	// (ids unique across this plugin's processes: an answer for an earlier process never meets a call of this one)
	if r.next_call == 0 { r.next_call = r.serial << 32 }
	r.next_call += 1
	r.calls[r.next_call] = Pending_Call{op = op, resolve = js.retain(c.ctx.rt, cap.resolve), reject = js.retain(c.ctx.rt, cap.reject), result = result}
	event_post(r.p, r.serial, .Request, req = Request{call = r.next_call, op = op, args = args})
	return cap.promise
}

// The broker's answer: the call's promise settles, its continuations run.
@(private)
broker_answer :: proc(r: ^Run, m: Message) {
	pc, ok := r.calls[m.serial]
	if !ok { return }
	delete_key(&r.calls, m.serial)
	defer {
		js.release(r.rt, pc.resolve)
		js.release(r.rt, pc.reject)
	}
	if !m.flag {
		name := m.key != "" ? m.key : "Error"
		call_settled(r, pc.reject, {plugin_api.named_error(r.ctx, name, m.text)})
		return
	}
	v := js.UNDEFINED
	switch pc.op {
	case .Files_Read, .Clipboard_Read: v = js.new_string(r.ctx, m.text)
	case .Files_Write, .Clipboard_Write:
	case .Files_Pick:                  v = m.is_flag ? js.new_string(r.ctx, m.text) : js.NULL
	case .Fetch:
		o := js.new_object(r.ctx)
		js.root(r.rt, o)
		js.set_property_str(r.ctx, o, "status", js.new_number(m.number))
		js.set_property_str(r.ctx, o, "url", js.new_string(r.ctx, m.command))
		js.set_property_str(r.ctx, o, "text", js.new_string(r.ctx, m.text))
		v = o
	case .App_Call:
		good: bool
		v, good = app_result_js(r, pc.result, m.text)
		if !good {
			call_settled(r, pc.reject, {plugin_api.named_error(r.ctx, "Error", "the program's answer cannot be read")})
			return
		}
	}
	js.root(r.rt, v)
	call_settled(r, pc.resolve, {v})
}

////////////////////////////////
// The API's implementations (level 4)

@(private)
files_read :: proc(c: ^plugin_api.Call, a: ^plugin_api.Files_Read) -> js.Value {
	return broker_call(c, .Files_Read, {a.path, "", "", ""}, nil)
}

@(private)
files_write :: proc(c: ^plugin_api.Call, a: ^plugin_api.Files_Write) -> js.Value {
	return broker_call(c, .Files_Write, {a.path, a.text, "", ""}, nil)
}

@(private)
files_pick :: proc(c: ^plugin_api.Call, a: ^plugin_api.Files_Pick) -> js.Value {
	return broker_call(c, .Files_Pick, {a.options.folder ? "folder" : "", a.options.title, "", ""}, nil)
}

@(private)
http_fetch :: proc(c: ^plugin_api.Call, a: ^plugin_api.Http_Fetch) -> js.Value {
	return broker_call(c, .Fetch, {a.url, a.options.method, a.options.body, a.options.contentType}, nil)
}

@(private)
clipboard_read :: proc(c: ^plugin_api.Call, a: ^plugin_api.Clipboard_Read) -> js.Value {
	return broker_call(c, .Clipboard_Read, {}, nil)
}

@(private)
clipboard_write :: proc(c: ^plugin_api.Call, a: ^plugin_api.Clipboard_Write) -> js.Value {
	return broker_call(c, .Clipboard_Write, {a.text, "", "", ""}, nil)
}
