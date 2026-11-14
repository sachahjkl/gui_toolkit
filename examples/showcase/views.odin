package showcase

// The views scene: a section of a program with its own dock space (views_dock, docs/views.md "Panels"): its content in
// the centre, two terminals stacked as tabs at the bottom (their strip: the tabs, the "+", the moves, then minimise,
// maximise and close), a lone inspector at the right (no strip: a panel alone adds nothing), and, by --views=, a
// floating window over the content or a dialog, or every terminal open (--views=tabs: in a narrow window their tabs
// overflow the strip, which scrolls with arrows). The views open when the scene shows and close when it goes: a panel
// whose space is not built would float over the other scenes. Their memory is the window's own: in memory only.

import "core:fmt"
import "core:math"
import "../../src/draw"
import lucide "../../src/lucide"
import "../../src/ui"

// What the scene opens with it (--views=).
Views_Variant :: enum u8 {
	Docked,     // the panels only
	Floating,   // the panels and a floating window over the content
	Dialog,     // the panels and a dialog over all of it (its header: the Detach icon, the close cross)
	Tabs,       // the panels, every terminal open: in a narrow window their tabs overflow the strip (its arrows)
}
VIEWS_VARIANT_NAMES := [Views_Variant]string{.Docked = "docked", .Floating = "floating", .Dialog = "dialog", .Tabs = "tabs"}

VIEWS_SPACE :: "views_scene"
TERMINAL_VIEW :: "terminal"
INSPECTOR_VIEW :: "inspector"
COLOUR_VIEW :: "colour"
TERMINALS_MAX :: 6

// A terminal's tab: its name and what it shows.
Terminal :: struct {
	app:   ^App,
	name:  string,   // its instance and its tab's words
	lines: []string,
}

TERMINAL_LINES := [?][]string{
	{"$ odin run tools/tk -- screenshots -only:showcase_views", "building showcase…", "showcase_views_docked.webp   1280x720   41 KB", "showcase_views_floating.webp 1280x720   46 KB", "$ _"},
	{"$ git log --oneline -4", "7a41473 a slider keeps its track", "5c1cda9 a tool opens a menu", "b0d9ac6 one tool bar: wrap or fold", "2b7d64a the update said once", "$ _"},
	{"$ tail -f build/showcase.log", "frame 412  build 0.31 ms  draw 0.62 ms", "frame 413  build 0.29 ms  draw 0.58 ms", "frame 414  build 0.30 ms  draw 0.61 ms"},
}
TERMINAL_NAMES := [?]string{"build", "git", "log", "shell"}

views_register :: proc(app: ^App) {
	vs := ui.state_views(&app.main.state)
	ui.view_register(vs, TERMINAL_VIEW, terminal_view, ui.View_Options{
		title = "Terminal", icon = lucide.TERMINAL, home = .Panel, home_place = {space = VIEWS_SPACE, edge = .Bottom},
		tabs_always = true, new_tab = terminal_new_tab, new_tab_label = "New terminal",
	})
	ui.view_register(vs, INSPECTOR_VIEW, inspector_view, ui.View_Options{
		title = "Inspector", icon = lucide.SCAN_EYE, home = .Panel, home_place = {space = VIEWS_SPACE, edge = .Right},
	})
	ui.view_register(vs, COLOUR_VIEW, colour_view, ui.View_Options{
		title = "Colour", icon = lucide.PALETTE, home = .Dialog, first = .Internal, width_em = 19,
	})
}

views_build :: proc(app: ^App, em: f32) {
	vs := ui.views()
	// (the space: its content in the centre, the terminals' zone a share of its height, the inspector's a sidebar's width)
	if ui.views_dock(vs, VIEWS_SPACE, {content = true, extent_frac = #partial [ui.View_Edge]f32{.Bottom = 0.36}, extent_em = #partial [ui.View_Edge]f32{.Right = 17}}) {
		heading("Views", "One build procedure each, shown where the person puts it: docked in a panel, floating over the content, in a window of its own, or a dialog. Drag a tab or a header to move it.", em)
		views_canvas(app, em)
	}
	// (opened after their space in this build: they show docked from their first frame)
	if !app.views_opened { views_scene_open(app) }
}

// The section's own content: a picture being edited, its colour the floating window's.
@(private = "file")
views_canvas :: proc(app: ^App, em: f32) {
	// (a box that draws its ground: a column draws none. Its caption a dark chip at its bottom left, where the floating
	// window over its middle leaves it whole)
	tint := draw.hsv(app.views_hue / 360, app.views_sat, 0.32 + 0.5 * app.views_val)
	margin := math.round(em * 0.9)
	ui.next({width = ui.fill(), height = ui.fill(), radius = math.round(em * 0.6), bg = tint, axis = .Y})
	canvas := ui.build_box({.Draw_Background}, "###views_canvas")
	if ui.parent(canvas) {
		ui.spacer(ui.fill())
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###views_canvas_foot") {
			ui.spacer(ui.px(margin))
			ui.next({width = ui.text_size(math.round(em * 0.3)), height = ui.px(math.round(em * 1.9)), radius = math.round(em * 0.4), bg = draw.Color{0, 0, 0, 0.45}, fg = draw.Color{1, 1, 1, 0.92}})
			ui.build_box({.Draw_Background, .Draw_Text, .No_Text_Trunc}, "harbour-at-dusk.webp · 1920 × 1080###views_canvas_name")
		}
		ui.spacer(ui.px(margin))
	}
	ui.spacer(ui.px(math.round(em * 0.9)))   // (before the terminals' zone)
}

// Opens the scene's views, as the variant says.
@(private = "file")
views_scene_open :: proc(app: ^App) {
	vs := ui.views()
	app.views_opened = true
	app.terminal_count = 0
	terminal_open(app)
	terminal_open(app)
	ui.view_open(vs, INSPECTOR_VIEW, app)
	switch app.views_variant {
	case .Docked:
	case .Floating: ui.view_open(vs, COLOUR_VIEW, app)
	case .Dialog:   ui.view_open(vs, EXPORT_VIEW, app)
	case .Tabs:     for app.terminal_count < TERMINALS_MAX { terminal_open(app) }
	}
}

// The scene's views close when another scene shows (each build, before the scenes).
views_scene_follow :: proc(app: ^App) {
	if app.scene == .Views || !app.views_opened { return }
	vs := ui.views()
	for i in 0 ..< app.terminal_count { ui.view_close(vs, TERMINAL_VIEW, app.terminals[i].name) }
	ui.view_close(vs, INSPECTOR_VIEW)
	ui.view_close(vs, COLOUR_VIEW)
	app.views_opened = false
}

// A terminal more, its tab last in the terminals' stack.
@(private = "file")
terminal_open :: proc(app: ^App) {
	if app.terminal_count >= TERMINALS_MAX { return }
	names := TERMINAL_NAMES
	k := app.terminal_count
	t := &app.terminals[k]
	t.app = app
	t.name = k < len(names) ? names[k] : fmt.aprintf("shell %d", k + 1)
	t.lines = TERMINAL_LINES[k % len(TERMINAL_LINES)]
	app.terminal_count += 1
	ui.view_open(ui.views(), TERMINAL_VIEW, t, t.name)
}

// The "+" of the terminals' strip: a new terminal, which joins the stack.
@(private = "file")
terminal_new_tab :: proc(data: rawptr) { terminal_open((^Terminal)(data).app) }

@(private = "file")
terminal_view :: proc(v: ^ui.View, t: ^Terminal) {
	em := ui.font_size()
	ui.view_title(v, t.name)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###term") {
		ui.spacer(ui.px(em * 0.5))
		// (a terminal's rows: one line each, the font's height and a little, no padding above or below)
		size := math.round(em * 0.92)
		row := math.round(size * 1.4)
		if ui.style({font = t.app.main.state.mono_font, font_size = size}) {
			for line, i in t.lines {
				ui.next({width = ui.fill(), height = ui.px(row), text_pad = math.round(em * 0.8)})
				ui.label(fmt.tprintf("%s###line%d", line, i))
			}
		}
	}
}

@(private = "file")
inspector_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###inspector") {
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.text_size(), text_pad = math.round(em * 0.8)})
			ui.label("PICTURE###insp_title")
		}
		facts := [?][2]string{{"Name", "harbour-at-dusk"}, {"Format", "WebP"}, {"Size", "1920 × 1080"}, {"Weight", "58 KB"}, {"Taken", "today, 18:42"}}
		for f, i in facts {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9)), axis = .X, cross = .Center})
			if ui.row(id = fmt.tprintf("###insp_row%d", i)) {
				ui.spacer(ui.px(math.round(em * 0.8)))
				if ui.tags("weak") {
					ui.next({width = ui.px(math.round(em * 5)), height = ui.pct(1), text_pad = 0})
					ui.label(fmt.tprintf("%s###k", f[0]))
				}
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###v", f[1]))
			}
		}
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(id = "###insp_toggle") {
			ui.spacer(ui.px(math.round(em * 0.8)))
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.toggle("###insp_meta", "Keep its metadata", &app.views_keep_meta)
			ui.spacer(ui.px(math.round(em * 0.8)))
		}
	}
}

// The floating window: the picture's tint, its swatch and three sliders.
@(private = "file")
colour_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	if ui.dialog_body("colour_body") {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 3)), radius = math.round(em * 0.5), bg = draw.hsv(app.views_hue / 360, app.views_sat, 0.32 + 0.5 * app.views_val)})
		ui.build_box({.Draw_Background, .Draw_Border}, "###colour_swatch")
		if ui.form_row("Hue") { ui.slider("###colour_hue", &app.views_hue, 0, 360, 1, "%.0f°") }
		if ui.form_row("Saturation") { ui.slider("###colour_sat", &app.views_sat, 0, 1, 0.01, "%.2f") }
		if ui.form_row("Light") { ui.slider("###colour_val", &app.views_val, 0, 1, 0.01, "%.2f") }
	}
}
