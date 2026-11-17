package tk_prefs_page

// The Diagnostics page (Page_Options.diagnostics: the window the settings are in): what a person on a slow machine copies
// and sends. The program and the toolkit and their versions, the system, the graphics adapter and its API (and whether it
// is a software rasterizer, which no setting makes fast), the window's size and scale, the last frames' build and draw
// times (host.frame_stats: kept in every build, a release too), and partial redraw with the share of pixels it drew. A
// Copy button puts it all on the clipboard as text.
//
// The page reads a Diagnostics_Source, plain data: a program on the toolkit's host gives diagnostics_of(&its_host); a
// program with a loop of its own (Wren) gives its renderer, its window and a host.Frame_Ring it fills (host.frame_add).

import "core:fmt"
import "core:math"
import "core:strings"
import si "core:sys/info"
import host "../host"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import "../render"
import "../ui"

// How often the page makes its numbers again while it is shown: a sort of the frames kept, not each frame.
DIAGNOSTICS_REFRESH_MS :: 1000

// What the page reads, at each build: no field is kept past it. `renderer` nil: no page.
Diagnostics_Source :: struct {
	renderer:       ^render.Renderer,   // the adapter and its API
	window:         ^platform.Window,   // its size and scale (nil: no such line)
	frames:         ^host.Frame_Ring,   // the last pictures' times (nil: none drawn yet)
	partial_redraw: bool,               // each frame redraws only what changed (ui.set_partial_redraw)
}

// The source of a window on the toolkit's host.
diagnostics_of :: proc(h: ^host.Host) -> Diagnostics_Source {
	if h == nil || h.shared == nil { return {} }
	return {renderer = &h.shared.r, window = h.win, frames = &h.frames, partial_redraw = h.partial_redraw}
}

Diagnostics_View :: struct {
	source:     Diagnostics_Source,   // Page_Options.diagnostics, at each build
	version:    string,       // Page_Options.version, at each build
	rows:       [dynamic]Diagnostics_Row,   // owned: what the page shows, made again every DIAGNOSTICS_REFRESH_MS
	text:       string,       // owned: the same as text, for Copy
	made_ms:    f64,
	system:     string,       // owned: the system's name and version, read once on a task ("": not yet)
	reading:    bool,
	copied_ms:  f64,          // when Copy was clicked (its check shows a moment)
	software:   bool,         // the adapter is a software rasterizer
}

Diagnostics_Row :: struct { key, value: string }   // both owned

@(private)
diagnostics_destroy :: proc(v: ^Diagnostics_View) {
	diagnostics_rows_free(v)
	delete(v.rows)
	delete(v.text)
	delete(v.system)
	v^ = {}
}

@(private = "file")
diagnostics_rows_free :: proc(v: ^Diagnostics_View) {
	for r in v.rows { delete(r.key); delete(r.value) }
	clear(&v.rows)
}

@(private)
diagnostics_page_info :: proc(p: ^Page) -> Page_Info {
	return {category = DIAGNOSTICS_PAGE, title = i18n.later("Diagnostics"), icon = lucide.ACTIVITY, build = diagnostics_build, user = p, tags = DIAGNOSTICS_TAGS[:]}
}

@(private = "file")
System_Job :: struct { p: ^Page, text: string }

// The report as text: the rows, "key: value" a line. What Copy puts on the clipboard (temp memory).
diagnostics_text :: proc(rows: []Diagnostics_Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in rows { fmt.sbprintf(&b, "%s: %s\n", r.key, r.value) }
	return strings.to_string(b)
}

@(private = "file")
diagnostics_build :: proc(user: rawptr, em: f32) {
	p := (^Page)(user)
	v := &p.diagnostics
	if v.source.renderer == nil { return }
	// (the system's version is in files on Linux: read once, on a task)
	if v.system == "" && !v.reading && p.state != nil {
		v.reading = true
		j := new(System_Job)
		j.p = p
		ui.task(p.state, proc(data: rawptr) {
			j := (^System_Job)(data)
			if ver, ok := si.os_version(context.allocator); ok {
				j.text = strings.clone(ver.full)
				si.destroy_os_version(ver, context.allocator)
			}
		}, proc(data: rawptr, _: u64) {
			j := (^System_Job)(data)
			v := &j.p.diagnostics
			v.reading = false
			delete(v.system)
			v.system = j.text != "" ? j.text : strings.clone(fmt.tprintf("%v", ODIN_OS))
			v.made_ms = 0
			free(j)
		}, j, proc(data: rawptr) {
			j := (^System_Job)(data)
			delete(j.text)
			free(j)
		})
	}
	now := ui.now_ms()
	if v.made_ms == 0 || now - v.made_ms >= DIAGNOSTICS_REFRESH_MS {
		diagnostics_make(v)
		v.made_ms = now
	}
	ui.wake_within(p.state, DIAGNOSTICS_REFRESH_MS)   // (the numbers follow while the page is shown)
	if v.software {
		if ui.tags("warn") {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###diag_software", i18n.tr("The frames are drawn by a software rasterizer, not the graphics card: everything is slower. Updating the graphics driver usually lets the program use the card again.")))
		}
		ui.space(ui.LINE_GAP)
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, radius = math.round(em * 0.4)})
	well: ^ui.Box
	if ui.tags("input") { well = ui.build_box({.Draw_Background, .Draw_Border}, "###diag_rows") }
	if ui.parent(well) {
		// (a well's inset, INNER_PAD on four sides; its rows stay its direct children, found by their ids)
		ui.space(ui.INNER_PAD)
		for r, i in v.rows {
			if i > 0 { ui.space(ui.SPACE_1) }
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Start})
			if ui.row(.Start, id = fmt.tprintf("###diag_row_%d", i)) {
				ui.space(ui.INNER_PAD)
				if ui.tags("weak") {
					ui.next({width = ui.px(em * 10), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###k", r.key))
				}
				ui.next({width = ui.fill(), text_pad = 0, font = ui.mono_font(), font_size = math.round(em * 0.9)})
				ui.paragraph(fmt.tprintf("%s###v", r.value))
				ui.space(ui.INNER_PAD)
			}
		}
		ui.space(ui.INNER_PAD)
	}
	ui.space(ui.ITEM_GAP)
	copied := v.copied_ms > 0 && now - v.copied_ms < 1500
	if ui.button("###diag_copy", copied ? i18n.tr("Copied") : i18n.tr("Copy"), copied ? lucide.CHECK : lucide.COPY, {icon_font = ui.lucide_icons(), intent = .Primary}).clicked {
		ui.window_clipboard_set(v.text)
		v.copied_ms = now
	}
	if copied { ui.wake_within(p.state, 1600) }
}

@(private = "file")
diagnostics_make :: proc(v: ^Diagnostics_View) {
	diagnostics_rows_free(v)
	rows, software := diagnostics_rows(v.source, v.version, v.system)
	for r in rows { append(&v.rows, Diagnostics_Row{strings.clone(r.key), strings.clone(r.value)}) }
	v.software = software
	delete(v.text)
	v.text = strings.clone(diagnostics_text(v.rows[:]))
}

// The page's rows, from a source, the program's version ("": no line) and the system's name ("": not read yet), in the
// temporary allocator; `software`: the adapter is a software rasterizer. What the page shows and Copy copies.
diagnostics_rows :: proc(s: Diagnostics_Source, version, system: string) -> (rows: []Diagnostics_Row, software: bool) {
	out := make([dynamic]Diagnostics_Row, context.temp_allocator)
	add :: proc(out: ^[dynamic]Diagnostics_Row, key, value: string) { append(out, Diagnostics_Row{key, value}) }
	if version != "" { add(&out, i18n.tr("Program"), version) }
	add(&out, "gui_toolkit", ui.VERSION)   // (a product's name: never translated)
	add(&out, i18n.tr("System"), fmt.tprintf("%s (%v %v)", system != "" ? system : "…", ODIN_OS, ODIN_ARCH))
	if s.renderer != nil {
		a := render.adapter_info(s.renderer)
		software = a.software
		adapter := a.name != "" ? a.name : "?"
		add(&out, i18n.tr("Graphics adapter"), a.software ? fmt.tprintf(i18n.tr("%s (software rasterizer)"), adapter) : adapter)
		add(&out, i18n.tr("Graphics API"), fmt.tprintf("%s (%s)", a.api, render.backend_name()))
	}
	if w := s.window; w != nil {
		add(&out, i18n.tr("Window"), fmt.tprintf(i18n.tr("%d × %d pixels, scale %s"), w.size.x, w.size.y, i18n.decimal(f64(w.dpi_scale), 2)))
	}
	st: host.Frame_Stats
	if s.frames != nil { st = host.frame_stats(s.frames) }
	ms :: proc(v: f64) -> string { return i18n.decimal(v, 1) }
	if st.frames == 0 {
		add(&out, i18n.tr("Frames"), i18n.tr("none drawn yet"))
	} else {
		add(&out, i18n.tr("Frames"), fmt.tprintf(i18n.tr("the last %d: median %s ms, 95th percentile %s ms"), st.frames, ms(f64(st.total_p50)), ms(f64(st.total_p95))))
		add(&out, i18n.tr("Build"), fmt.tprintf(i18n.tr("median %s ms, 95th percentile %s ms"), ms(f64(st.build_p50)), ms(f64(st.build_p95))))
		add(&out, i18n.tr("Draw"), fmt.tprintf(i18n.tr("median %s ms, 95th percentile %s ms"), ms(f64(st.draw_p50)), ms(f64(st.draw_p95))))
	}
	if s.partial_redraw {
		add(&out, i18n.tr("Partial redraw"), st.drawn_share > 0 ? fmt.tprintf(i18n.tr("on: %s of the pixels drawn"), i18n.percent(f64(st.drawn_share))) : i18n.tr("on"))
	} else {
		add(&out, i18n.tr("Partial redraw"), i18n.tr("off"))
	}
	return out[:], software
}
