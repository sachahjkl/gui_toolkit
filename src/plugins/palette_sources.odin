package tk_plugins

// A plugin's palette sources on the program's side (plugins.md, "As built: palette sources, menus, the tool bar, a
// plugin's languages"): one ui.Palette_Source per source the manifests declare, a searching source. The palette asks at
// each query; the plugin is asked one question at a time (the newest waits; the one it replaces is dropped), and its
// rows come back as an event. The plugin's process side is palette_run.odin.

import "base:runtime"
import "core:fmt"
import "core:strings"
import plugin_api "../plugin_api"
import "../ui"

// The most rows of an answer: a plugin's more are dropped (its log says so).
PALETTE_MAX_ROWS :: 200

// A plugin's palette source, kept by the host at a place that does not move while the palette has it.
@(private)
Plugin_Source :: struct {
	src:        ui.Palette_Source,
	host:       ^Host,
	plugin_id:  string,   // (owned, the three of them)
	source_id:  string,
	name:       string,   // plugin.<plugin id>.<source id>: the usage memory's part
	added:      bool,     // in the palette now
	// the question its plugin is answering, and the newest one that waits for it
	flight:     ui.Palette_Question,
	in_flight:  bool,
	flight_ms:  i64,
	asks:       u64,      // the questions sent: an answer for another is dropped
	waiting:    ui.Palette_Question,
	has_waiting: bool,
	waiting_query: string,   // (owned)
	// what a test reads (source_info)
	answered, dropped: int,
}

// What the host knows of a plugin's palette source, for a test.
Source_Info :: struct {
	asks:      u64,    // the questions sent to the plugin
	answered:  int,    // the answers taken
	dropped:   int,    // the answers dropped: for a question no longer asked
	in_flight: bool,
	waiting:   bool,
}

// Plugin `plugin_id`'s palette source `source_id`, as the host knows it. False: no such source.
source_info :: proc(h: ^Host, plugin_id, source_id: string) -> (Source_Info, bool) {
	ps := source_of(h, plugin_id, source_id)
	if ps == nil { return {}, false }
	return {asks = ps.asks, answered = ps.answered, dropped = ps.dropped, in_flight = ps.in_flight, waiting = ps.has_waiting}, true
}

@(private)
source_of :: proc(h: ^Host, plugin_id, source_id: string) -> ^Plugin_Source {
	for ps in h.sources { if ps.plugin_id == plugin_id && ps.source_id == source_id { return ps } }
	return nil
}

// The sources of the plugins read (folder_take, after the plugins are the host's).
@(private)
sources_declare :: proc(h: ^Host) {
	for p in h.plugins {
		if p.refused != "" { continue }
		for d in p.manifest.palette {
			ps := new(Plugin_Source)
			ps.host = h
			ps.plugin_id, ps.source_id = strings.clone(p.manifest.id), strings.clone(d.id)
			ps.name = strings.concatenate({"plugin.", p.manifest.id, ".", d.id})
			ps.src = {
				name = ps.name, title = d.label, prefix = d.prefix, plain = d.prefix == .None, searches = true, remember = true,
				read = source_ask, act = source_choose, user = ps,
			}
			append(&h.sources, ps)
		}
	}
}

// The sources let go of (a read of the folder, the host's end): out of the palette, their questions ended.
@(private)
sources_drop :: proc(h: ^Host) {
	for ps in h.sources {
		if ps.added && h.palette != nil { ui.palette_remove(h.palette, &ps.src) }
		source_questions_drop(ps)
		delete(ps.plugin_id); delete(ps.source_id); delete(ps.name)
		free(ps)
	}
	clear(&h.sources)
}

// Each build (host_build): each source in the palette while its plugin may run, out of it while not; its label in the
// person's language; a question past the bound answered as not responding.
@(private)
sources_build :: proc(h: ^Host, palette: ^ui.Command_Palette) {
	if palette == nil { return }
	now := now_ms()
	for ps in h.sources {
		p := find(h, ps.plugin_id)
		wanted := p != nil && gives_entries(p)
		if wanted && !ps.added {
			ui.palette_add(palette, &ps.src)
			ps.added = true
		} else if !wanted && ps.added {
			ui.palette_remove(palette, &ps.src)
			ps.added = false
			source_questions_drop(ps)
		}
		if p == nil { continue }
		for d in p.manifest.palette { if d.id == ps.source_id { ps.src.title = manifest_tr(&p.manifest, d.label) } }
		if ps.in_flight && now - ps.flight_ms > i64(h.o.bound_ms) {
			// (no answer within the bound: the palette says so; the answer that comes later is dropped)
			ps.in_flight = false
			ui.palette_answer_error(ps.flight, "not responding")
			if ps.has_waiting { source_send_waiting(h, p, ps) }
		}
	}
}

// The palette's question (Palette_Source.read): sent at once, or kept as the newest while another is in flight.
@(private)
source_ask :: proc(pal: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	context.allocator = runtime.heap_allocator()
	ps := (^Plugin_Source)(src.user)
	h := ps.host
	p := find(h, ps.plugin_id)
	if p == nil || !can_run(p) {
		ui.palette_answer_error(q, "this plugin cannot run now")
		return
	}
	// (typing in its source is using the plugin: it starts, as at a command)
	if !p.alive { plugin_start(h, p) }
	if ps.in_flight {
		if ps.has_waiting { ui.palette_question_drop(ps.waiting) }
		delete(ps.waiting_query)
		ps.waiting, ps.has_waiting, ps.waiting_query = q, true, strings.clone(q.query)
		return
	}
	source_send(h, p, ps, q, q.query)
}

@(private)
source_send :: proc(h: ^Host, p: ^Plugin, ps: ^Plugin_Source, q: ui.Palette_Question, query: string) {
	context.allocator = runtime.heap_allocator()
	ps.asks += 1
	ps.flight, ps.in_flight, ps.flight_ms = q, true, now_ms()
	queue_push(p, Message{kind = .Palette_Query, key = strings.clone(ps.source_id), text = strings.clone(query), serial = ps.asks})
	wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
}

@(private)
source_send_waiting :: proc(h: ^Host, p: ^Plugin, ps: ^Plugin_Source) {
	q, query := ps.waiting, ps.waiting_query
	ps.has_waiting, ps.waiting_query = false, ""
	source_send(h, p, ps, q, query)
	delete(query, runtime.heap_allocator())
}

// The questions of a source ended without an answer (its plugin's process ended, the source left the palette).
@(private)
source_questions_drop :: proc(ps: ^Plugin_Source) {
	if ps.in_flight { ui.palette_question_drop(ps.flight) }
	if ps.has_waiting { ui.palette_question_drop(ps.waiting) }
	ps.in_flight, ps.has_waiting = false, false
	delete(ps.waiting_query, runtime.heap_allocator())
	ps.waiting_query = ""
}

// A plugin's process ended (event_run's Ended): its sources' questions with it.
@(private)
sources_ended :: proc(h: ^Host, p: ^Plugin) {
	for ps in h.sources { if ps.plugin_id == p.manifest.id { source_questions_drop(ps) } }
}

// Rows came (event_run): the answer of the question in flight, or dropped; then the question that waits goes.
@(private)
source_take :: proc(h: ^Host, p: ^Plugin, source_id: string, ask: u64, ok: bool, text: string) {
	context.allocator = runtime.heap_allocator()
	ps := source_of(h, p.manifest.id, source_id)
	if ps == nil { return }
	if !ps.in_flight || ask != ps.asks {
		ps.dropped += 1
		return
	}
	ps.in_flight = false
	ps.answered += 1
	if ok {
		rows: []plugin_api.Palette_Row
		ti := type_info_of([]plugin_api.Palette_Row)
		r := plugin_api.Wire_Reader{data = transmute([]u8)text}
		plugin_api.value_decode(&r, ti, &rows, context.temp_allocator)
		if r.bad || r.at != len(r.data) {
			ui.palette_answer_error(ps.flight, "its rows cannot be read")
		} else {
			a: ui.Palette_Answer
			al := ui.palette_answer_allocator(&a)
			items := make([]ui.Palette_Item, min(len(rows), PALETTE_MAX_ROWS), al)
			for &it, i in items {
				row := rows[i]
				it = ui.palette_item_clone({id = row.id, title = row.label, detail = row.detail, icon = icon_glyph_of(string(row.icon)), group = row.group}, al)
			}
			a.items = items
			ui.palette_answer(ps.flight, &a)
		}
	} else {
		ui.palette_answer_error(ps.flight, text)
	}
	if ps.has_waiting { source_send_waiting(h, p, ps) }
}

// A row chosen (Palette_Source.act): the plugin's onChoose hears it, a person's act.
@(private)
source_choose :: proc(pal: ^ui.Command_Palette, src: ^ui.Palette_Source, c: ui.Palette_Choice) {
	context.allocator = runtime.heap_allocator()
	ps := (^Plugin_Source)(src.user)
	h := ps.host
	p := find(h, ps.plugin_id)
	if p == nil || !can_run(p) {
		say(h, .Warn, fmt.tprintf("%s cannot run now", ps.name))
		return
	}
	if !p.alive { plugin_start(h, p) }
	queue_push(p, Message{kind = .Palette_Choose, key = strings.clone(ps.source_id), text = strings.clone(c.id)})
	wake_after(h, h.o.bound_ms + WAKE_MARGIN_MS)
}
