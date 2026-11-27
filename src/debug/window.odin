package debug

// The debug window (debug-panel.md, "One surface"): a view of the window's Views, its tabs (View, then a tab per
// panel), a filter, the panel shown in a dense body that scrolls; a panel pinned is a view of its own.

import "core:fmt"
import "core:math"
import i18n "../i18n"
import lucide "../lucide"
import "../ui"

// The window's first width and height, and a pinned panel's, in the program's text sizes.
@(private) WINDOW_EM :: 24
@(private) WINDOW_HEIGHT_EM :: 42
@(private) PINNED_EM :: 20
@(private) PINNED_HEIGHT_EM :: 18

@(private)
window_open :: proc(sf: ^Surface) {
	vs := ui.state_views(sf.state)
	views_register(vs)
	ui.view_open(vs, DEBUG_VIEW, sf, window_instance(sf), sf.state)
}

@(private)
views_register :: proc(vs: ^ui.Views) {
	if ui.view_registered(vs, DEBUG_VIEW) { return }
	ui.view_register(vs, DEBUG_VIEW, window_build, ui.View_Options{
		title = i18n.later("Debug"), home = .Panel, home_place = {edge = .Right}, first = .Internal, float_edge = .Right,
		width_em = WINDOW_EM, height_em = WINDOW_HEIGHT_EM, extent_em = WINDOW_EM, resizable = true, square = true, dense = true,
	})
	ui.view_register(vs, DEBUG_PANEL_VIEW, pinned_build, ui.View_Options{
		home = .Panel, home_place = {edge = .Right}, first = .Internal, float_edge = .Right,
		width_em = PINNED_EM, height_em = PINNED_HEIGHT_EM, extent_em = PINNED_EM, resizable = true, square = true, dense = true,
	})
}

@(private)
window_build :: proc(v: ^ui.View, sf: ^Surface) {
	s := sf.state
	vs := ui.state_views(s)
	// (a pinned panel whose view closed is a tab again)
	for p in sf.panels {
		if p.pinned && !ui.view_is_open(vs, DEBUG_PANEL_VIEW, pinned_instance(p)) { p.pinned = false }
	}
	if s.build_index != sf.frame_build {
		sf.frame_build = s.build_index
		ui.value_history_push(&sf.frame_ms, s.dt * 1000)
	}
	if sf.panels[clamp(sf.tab, 0, len(sf.panels) - 1)].pinned { sf.tab = first_tab(sf) }
	sf.tab = clamp(sf.tab, 0, len(sf.panels) - 1)
	if ui.dense_scope() {
		em := ui.font_size()
		gap := ui.dense_gap()
		h := ui.dense_row_height()
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column() {
			// the tabs, and the pin of the one shown
			labels := make([dynamic]string, 0, len(sf.panels), context.temp_allocator)
			at := make([dynamic]int, 0, len(sf.panels), context.temp_allocator)
			chosen := 0
			for p, i in sf.panels {
				if p.pinned { continue }
				if i == sf.tab { chosen = len(labels) }
				append(&labels, i == 0 ? i18n.tr(VIEW_PANEL) : p.name)
				append(&at, i)
			}
			// (floating, the tabs are its title bar: the header's free part after them moves it, its moves at the end)
			head := math.round(em * ui.DENSE_HEADER_EM)
			in_head := false
			if v.presentation == .Internal {
				if ui.view_header_tools(v) { in_head = true; tabs_build(sf, labels[:], at[:], &chosen, head, h) }
			}
			if !in_head {
				// (its first tab at the edge, the line under the row from edge to edge: the chosen tab rises out of it)
				ui.next({width = ui.fill(), height = ui.px(head), axis = .X, cross = .Center})
				tab_row := ui.build_box({}, "###debug_tab_row")
				tab_row.custom = ui.tab_line_draw
				if ui.parent(tab_row) { tabs_build(sf, labels[:], at[:], &chosen, head, h) }
			}
			filter := filter_row(sf, "###debug_filter", gap, h)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###debug_body") { panel_body(sf, sf.panels[sf.tab], filter, gap, em) }
		}
	}
}

// The tabs of the panels not pinned, and the pin of the one shown.
@(private)
tabs_build :: proc(sf: ^Surface, labels: []string, at: []int, chosen: ^int, head, h: f32) {
	ui.next({height = ui.px(head)})
	if ui.tabs("###debug_tabs", labels, nil, chosen) { sf.tab = at[chosen^] }
	ui.next({width = ui.px(h), height = ui.px(h)})
	if ui.button("###debug_pin", icon = lucide.PIN, o = {icon_font = ui.lucide_icons(), face = .Ghost, tip = i18n.tr("Pin: this panel in a view of its own")}).clicked {
		pin(sf, sf.panels[sf.tab])
	}
}

// The filter's field over the rows; what it holds (its text, trimmed).
@(private)
filter_row :: proc(sf: ^Surface, id: string, gap, h: f32) -> string {
	ui.spacer(ui.px(gap * 2))
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center) {
		ui.spacer(ui.px(gap * 2))
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.line_edit(id, &sf.filter, {placeholder = i18n.tr("Filter"), clearable = true})
		ui.spacer(ui.px(gap * 2))
	}
	ui.spacer(ui.px(gap))
	return trim(ui.line_edit_string(&sf.filter))
}

// The rows of a panel, built by its procedure in the Build pass, inset from the body's sides.
@(private)
panel_body :: proc(sf: ^Surface, p: ^Panel, filter: string, gap, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row() {
		ui.spacer(ui.px(gap * 2))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = fmt.tprintf("###panel_%x", p.key)) {
			pass := Pass{kind = .Build, surface = sf, filter = filter}
			pass_run(&pass, p)
			ui.spacer(ui.px(math.round(em * 0.5)))
		}
		ui.spacer(ui.px(gap * 2))
	}
}

// The panel in a view of its own; the window shows the next tab.
@(private)
pin :: proc(sf: ^Surface, p: ^Panel) {
	vs := ui.state_views(sf.state)
	views_register(vs)
	p.pinned = true
	ui.view_open(vs, DEBUG_PANEL_VIEW, p, pinned_instance(p), sf.state)
	sf.tab = first_tab(sf)
}

@(private)
first_tab :: proc(sf: ^Surface) -> int {
	for p, i in sf.panels { if !p.pinned { return i } }
	return 0
}

@(private)
pinned_build :: proc(v: ^ui.View, p: ^Panel) {
	name := p == p.surface.panels[0] ? i18n.tr(VIEW_PANEL) : p.name
	ui.view_title(v, name)
	if ui.dense_scope() {
		// (its dense header has no title: the panel's name is put there, as the window's tabs)
		if ui.view_header_tools(v) {
			ui.next({width = ui.text_size(), height = ui.px(math.round(ui.font_size() * ui.DENSE_HEADER_EM))})
			ui.build_box({.Draw_Text}, fmt.tprintf("%s###pinned_name", ui.text_shown(name)))
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y(fmt.tprintf("###pinned_%x", p.key)) { panel_body(p.surface, p, "", ui.dense_gap(), ui.font_size()) }
	}
}

// The toolkit's own panel: the view's tools of the window and its frame's numbers. Its paths are the tools' too
// ("View/wireframe").
@(private)
view_panel :: proc(sf: ^Surface) {
	s := sf.state
	wire := s.wireframe
	if toggle("wireframe", &wire) { ui.set_wireframe(s, wire) }
	exploded := ui.exploded(s)
	if toggle("exploded", &exploded) { ui.set_exploded(s, exploded) }
	zoom := ui.zoom(s)
	if number("zoom", &zoom, ui.ZOOM_MIN, ui.ZOOM_MAX, 0.05) { ui.set_zoom(s, zoom) }
	density := ui.density(s)
	if number("density", &density, ui.DENSITY_MIN, ui.DENSITY_MAX, 0.01) { ui.set_density(s, density) }
	if section("Frame") {
		plot("frame ms", &sf.frame_ms)
		watch("build", s.build_index)
		watch("boxes", ui.boxes_built(s))
	}
	if section("Input") {
		watch("focus", fmt.tprintf("%x", u64(ui.focus_key_of(s))))
		watch("hot", fmt.tprintf("%x", u64(ui.hot_key_of(s))))
	}
}

@(private)
trim :: proc(s: string) -> string {
	a, b := 0, len(s)
	for a < b && (s[a] == ' ' || s[a] == '\t') { a += 1 }
	for b > a && (s[b - 1] == ' ' || s[b - 1] == '\t') { b -= 1 }
	return s[a:b]
}
