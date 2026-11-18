package tk_plugins

// A plugin's palette sources in its process (palette_sources.odin is the program's side): `palette.source(id, search)`
// keeps the search; a question of the program calls it with the query, its rows (or the promise of them) are read by
// the bridge's reflection into Palette_Rows and sent back with the question's number. The last answer's rows are kept:
// a choice gives its row back as the plugin made it. And the person's language (context.language).

import "core:fmt"
import "core:strings"
import js "../js"
import plugin_api "../plugin_api"

// A source the plugin answers: its search, what choosing does, its last answer's rows (each retained).
@(private)
Run_Source :: struct {
	search: js.Value,
	choose: js.Value,
	rows:   js.Value,
}

// An answer that waits for the search's promise: its source and its question's number.
@(private)
Run_Ask :: struct {
	source: string,   // (owned)
	ask:    u64,
}

@(private)
palette_close :: proc(r: ^Run) {
	// (the values went with the runtime)
	for k in r.palette_sources { delete(k) }
	delete(r.palette_sources)
	for _, a in r.palette_asks { delete(a.source) }
	delete(r.palette_asks)
}

// palette.source(id, search, options).
@(private)
palette_source :: proc(c: ^plugin_api.Call, a: ^plugin_api.Palette_Source_Call) -> js.Value {
	r := (^Run)(c.realm.user)
	if !palette_declared(r, a.id) { return js.throw_type_error(c.ctx, fmt.tprintf("palette.source: plugin.json declares no palette source \"%s\"", a.id)) }
	rs := palette_run_source(r, a.id)
	if js.is_callable(rs.search) { js.release(c.ctx.rt, rs.search) }
	rs.search = js.retain(c.ctx.rt, js.Value(a.search))
	if js.is_callable(js.Value(a.options.onChoose)) {
		if js.is_callable(rs.choose) { js.release(c.ctx.rt, rs.choose) }
		rs.choose = js.retain(c.ctx.rt, js.Value(a.options.onChoose))
	}
	return js.UNDEFINED
}

// palette.onChoose(id, handler).
@(private)
palette_on_choose :: proc(c: ^plugin_api.Call, a: ^plugin_api.Palette_On_Choose) -> js.Value {
	r := (^Run)(c.realm.user)
	if !palette_declared(r, a.id) { return js.throw_type_error(c.ctx, fmt.tprintf("palette.onChoose: plugin.json declares no palette source \"%s\"", a.id)) }
	rs := palette_run_source(r, a.id)
	if js.is_callable(rs.choose) { js.release(c.ctx.rt, rs.choose) }
	rs.choose = js.retain(c.ctx.rt, js.Value(a.handler))
	return js.UNDEFINED
}

@(private)
palette_declared :: proc(r: ^Run, id: string) -> bool {
	for d in r.p.manifest.palette { if d.id == id { return true } }
	return false
}

@(private)
palette_run_source :: proc(r: ^Run, id: string) -> ^Run_Source {
	if id not_in r.palette_sources { r.palette_sources[strings.clone(id)] = {} }
	return &r.palette_sources[id]
}

// A question: the search called with the query; its rows now, or when its promise settles.
@(private)
palette_query :: proc(r: ^Run, m: Message) {
	rs, ok := r.palette_sources[m.key]
	if !ok || !js.is_callable(rs.search) {
		palette_post_failure(r, m.key, m.serial, fmt.tprintf("its palette source %s has no search: call palette.source(\"%s\", search) in activate", m.key, m.key))
		return
	}
	v := js.call_function(r.ctx, rs.search, js.UNDEFINED, {js.new_string(r.ctx, m.text)})
	if js.is_exception(v) {
		exception(r)
		if !r.ended { palette_post_failure(r, m.key, m.serial, "its search threw (its log says why)") }
		return
	}
	js.root(r.rt, v)
	then := js.is_object(v) ? js.get_property_str(r.ctx, v, "then") : js.UNDEFINED
	if !js.is_callable(then) {
		palette_rows_take(r, m.key, m.serial, v)
		return
	}
	// (a promise: its answer comes in a later job of this turn, or of a later one, with this ask's slot)
	r.next_ask += 1
	slot := r.next_ask
	r.palette_asks[slot] = Run_Ask{source = strings.clone(m.key), ask = m.serial}
	ok_fn := js.new_function(r.ctx, palette_promise_rows, "rows", 1, slot)
	js.root(r.rt, ok_fn)
	err_fn := js.new_function(r.ctx, palette_promise_failed, "failed", 1, slot)
	js.root(r.rt, err_fn)
	if res := js.call_function(r.ctx, then, v, {ok_fn, err_fn}); js.is_exception(res) || !js.run_jobs(r.rt) { exception(r) }
}

@(private)
palette_promise_rows :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	r := (^Run)((^plugin_api.Realm)(ctx.rt.host_data).user)
	a, ok := r.palette_asks[magic]
	if !ok { return js.UNDEFINED }
	delete_key(&r.palette_asks, magic)
	defer delete(a.source)
	palette_rows_take(r, a.source, a.ask, js.arg(args, 0))
	return js.UNDEFINED
}

@(private)
palette_promise_failed :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	r := (^Run)((^plugin_api.Realm)(ctx.rt.host_data).user)
	a, ok := r.palette_asks[magic]
	if !ok { return js.UNDEFINED }
	delete_key(&r.palette_asks, magic)
	defer delete(a.source)
	why := describe(r, js.arg(args, 0))
	log_write(r.p, fmt.tprintf("its palette source %s: %s", a.source, why))
	palette_post_failure(r, a.source, a.ask, why)
	return js.UNDEFINED
}

// The rows a search gave: read by the bridge's reflection, PALETTE_MAX_ROWS at most, sent to the program; kept for a
// choice.
@(private)
palette_rows_take :: proc(r: ^Run, source: string, ask: u64, v: js.Value) {
	ctx := r.ctx
	if !js.is_object(v) {
		palette_post_failure(r, source, ask, "its search gave no array of rows")
		return
	}
	length_v := js.get_property_str(ctx, v, "length")
	n, _ := js.to_number(ctx, length_v)
	count := int(clamp(n, 0, f64(PALETTE_MAX_ROWS)))
	if int(n) > PALETTE_MAX_ROWS {
		log_write(r.p, fmt.tprintf("its palette source %s gave %d rows: the first %d are shown", source, int(n), PALETTE_MAX_ROWS))
	}
	rows := make([]plugin_api.Palette_Row, count, context.temp_allocator)
	ti := type_info_of(plugin_api.Palette_Row)
	for k in 0 ..< count {
		item := js.get_property_str(ctx, v, fmt.tprintf("%d", k))
		js.root(r.rt, item)
		if !plugin_api.value_from_js(ctx, item, ti, &rows[k], fmt.tprintf("its palette source %s's row %d", source, k)) {
			exception(r)
			if !r.ended { palette_post_failure(r, source, ask, fmt.tprintf("its row %d is not { id, label }", k)) }
			return
		}
	}
	if source in r.palette_sources {
		rs := &r.palette_sources[source]
		if js.is_object(rs.rows) { js.release(r.rt, rs.rows) }
		rs.rows = js.retain(r.rt, v)
	}
	w := plugin_api.Wire_Writer{buf = make([dynamic]u8, context.temp_allocator)}
	plugin_api.value_encode(&w, type_info_of([]plugin_api.Palette_Row), &rows)
	event_post(r.p, r.serial, .Palette_Rows, title = source, text = string(w.buf[:]), rows = Rows_Ask{seq = ask, version = 1})
}

@(private)
palette_post_failure :: proc(r: ^Run, source: string, ask: u64, why: string) {
	event_post(r.p, r.serial, .Palette_Rows, title = source, text = why, rows = Rows_Ask{seq = ask, version = 0})
}

// A row chosen: the source's onChoose, with the row as the last answer gave it ({ id } when it is not there any more).
@(private)
palette_choose :: proc(r: ^Run, m: Message) {
	rs, ok := r.palette_sources[m.key]
	if !ok || !js.is_callable(rs.choose) {
		uncaught(r, fmt.tprintf("its palette source %s has no onChoose: give one in palette.source's options, or call palette.onChoose(\"%s\", f)", m.key, m.key))
		return
	}
	row := js.UNDEFINED
	if js.is_object(rs.rows) {
		length_v := js.get_property_str(r.ctx, rs.rows, "length")
		n, _ := js.to_number(r.ctx, length_v)
		for k in 0 ..< int(clamp(n, 0, f64(PALETTE_MAX_ROWS))) {
			item := js.get_property_str(r.ctx, rs.rows, fmt.tprintf("%d", k))
			if !js.is_object(item) { continue }
			id := js.get_property_str(r.ctx, item, "id")
			if s, good := js.to_utf8(r.ctx, id, context.temp_allocator); good && js.is_string(id) && s == m.text { row = item; break }
		}
	}
	if js.is_undefined(row) {
		row = js.new_object(r.ctx)
		js.root(r.rt, row)
		js.set_property_str(r.ctx, row, "id", js.new_string(r.ctx, m.text))
	}
	call_settled(r, rs.choose, {row})
}

// The person's language changed: context.language, and every open view renders again (a render reads it).
@(private)
language_changed :: proc(r: ^Run, m: Message) {
	js.set_property_str(r.ctx, r.context_object, "language", js.new_string(r.ctx, m.text))
	for _, rv in r.views { if rv.open { rv.dirty = true } }
}
