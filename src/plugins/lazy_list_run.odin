package tk_plugins

// A plugin's lazy lists in its process (lazy_list.odin is the program's side): a `list` node's `row` function is kept
// with the render's handlers (by "<key>\x1frow"); an ask of the program calls it for each row of the range, writes
// the rows as one display list (plugin_api.list_write_rows) and sends it back with the ask. The handlers of a row's
// nodes are kept by the list until the program lets go of the row.

import "core:fmt"
import "core:strings"
import js "../js"
import plugin_api "../plugin_api"

// A lazy list's rows' handlers, by "<node key>\x1f<event>" (keys owned, values retained).
@(private)
Run_Rows :: struct {
	handlers: map[string]js.Value,
}

// An ask of the program (a turn: the rows' handlers run, if any, in turns of their own later).
@(private)
rows_message :: proc(r: ^Run, m: Message) {
	rv := run_view(r, m.view)
	if rv == nil || !rv.open { return }
	// (no such list in the last render: the ask was made for one that is gone, the program drops it too)
	f, ok := rv.handlers[handler_key(m.key, "row")]
	if !ok { return }
	a := m.rows
	if a.from < 0 || a.to <= a.from || a.to - a.from > plugin_api.ROWS_MAX_PER_ASK { return }
	rl := rv.lists[m.key] or_else nil
	if rl == nil {
		rl = new(Run_Rows)
		rv.lists[strings.clone(m.key)] = rl
	}
	rows_release(r.rt, rl, m.key, a.keep_from, a.keep_to)
	s := Render_Sink{run = r, rv = rv, rt = r.rt, handlers = make(map[string]js.Value)}
	list, good := plugin_api.list_write_rows(r.ctx, f, m.key, a.from, a.to, render_sink(&s))
	if !good {
		handlers_release(r.rt, &s.handlers)
		delete(s.handlers)
		exception(r)
		if r.ended { return }
		// (rows that threw are answered empty: asked again, they would throw again at each bound)
		event_post(r.p, r.serial, .Rows, title = m.view, text = m.key, rows = a)
		return
	}
	for p in list.problems { log_write(r.p, fmt.tprintf("its view %s, its list %s: %s", m.view, m.key, p)) }
	for k, fn in s.handlers {
		if old, had := rl.handlers[k]; had {
			js.release(r.rt, old)
			rl.handlers[k] = fn
			delete(k)
		} else {
			rl.handlers[k] = fn
		}
	}
	delete(s.handlers)
	event_post(r.p, r.serial, .Rows, title = m.view, text = m.key, list = list, rows = a)
}

// The handlers of the rows the program no longer keeps (out of `keep_from ..< keep_to`).
@(private)
rows_release :: proc(rt: ^js.Runtime, rl: ^Run_Rows, list_key: string, keep_from, keep_to: int) {
	prefix := strings.concatenate({list_key, "~"}, context.temp_allocator)
	gone := make([dynamic]string, context.temp_allocator)
	for k in rl.handlers {
		i, ok := row_of_key(k, prefix)
		if !ok || i < keep_from || i >= keep_to { append(&gone, k) }
	}
	for k in gone {
		js.release(rt, rl.handlers[k])
		delete_key(&rl.handlers, k)
		delete(k)
	}
}

// After a render: the lists it no longer has, and their rows' handlers, let go of.
@(private)
rows_forget :: proc(r: ^Run, rv: ^Run_View) {
	gone := make([dynamic]string, context.temp_allocator)
	for k in rv.lists { if handler_key(k, "row") not_in rv.handlers { append(&gone, k) } }
	for k in gone {
		rl := rv.lists[k]
		delete_key(&rv.lists, k)
		handlers_release(r.rt, &rl.handlers)
		delete(rl.handlers)
		free(rl)
		delete(k)
	}
}
