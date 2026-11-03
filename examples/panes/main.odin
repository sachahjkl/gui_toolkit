// Panes the user resizes, folds and places (ui.pane_split, ui.pane_toggle, ui.pane_place_menu) and sections the user
// folds (ui.accordion): a sidebar of sections, a content area and a bottom panel (below or at the right). Double-click a
// handle or press Enter on it to fold its pane; click the strip to bring it back; Tab to a handle and use the arrow keys.
//   build.bat panes
package panes

import "core:fmt"
import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	theme:    ui.Theme,
	ui_state: ui.State,
	ui_font:  font.Font_Id,
	icons:    font.Font_Id,
	last_tick: time.Tick,
	frames_requested: int,
	sidebar:  ui.Pane,   // what an app saves (ui.pane_format)
	bottom:   ui.Pane,
	open:     [4]bool,
	saved:    int,       // pane changes finished (where an app would write its settings: Pane_Options.on_save)
	pacer: render.Pacer,
	slept: bool,
}

SECTIONS := [4]string{"Conversations", "Contacts", "Files", "Settings"}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	sc := ui.scale()
	room := [2]f32{f32(app.win.size.x), f32(app.win.size.y)} / sc
	save := ui.Pane_Options{on_save = proc(user: rawptr, p: ^ui.Pane) { (^App)(user).saved += 1 }, user = app}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row() {
		// sidebar: folds to a strip (double click, Enter, a drag under half its minimum, its chevron)
		side := save
		side.default_size, side.total, side.collapsible, side.title = 240, room.x, true, "Sidebar"
		if w := ui.pane_extent(&app.sidebar, .X, side); w > 0 {
			ui.next({width = ui.px(w * sc), height = ui.fill()})
			if ui.column(.Start, {.Draw_Background}, "###sidebar") {
				if ui.row() { ui.next({width = ui.fill()}); ui.label("  Sections"); ui.pane_toggle("###side_fold", .X, &app.sidebar, side) }
				for name, i in SECTIONS {
					if ui.accordion(fmt.tprintf("###sec%d", i), name, &app.open[i]) {
						for j in 0 ..< 3 + i {
							ui.next({width = ui.fill(), height = ui.px(em * 1.8)})
							ui.label(fmt.tprintf("    %s item %d###it%d", name, j + 1, j))
						}
					}
				}
			}
		}
		ui.pane_split("###side_split", .X, &app.sidebar, side)
		// content and the bottom panel (below, or at the right: its menu)
		axis := ui.pane_axis(app.bottom.place, room.x)
		bottom := save
		bottom.side, bottom.default_size, bottom.collapsible, bottom.title = .After, 160, true, "Bottom panel"
		bottom.total = axis == .Y ? room.y : room.x - ui.pane_extent(&app.sidebar, .X, side)
		ui.next({width = ui.fill(), height = ui.fill(), axis = axis})
		if ui.parent(ui.build_box({}, "###main")) {
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.column(.Center, {}, "###content") {
				ui.spacer(ui.px(em))
				ui.next({width = ui.text_size(), height = ui.px(em * 2)})
				ui.label(fmt.tprintf("sidebar %.0f px, bottom panel %.0f px, %d saves###info", ui.pane_extent(&app.sidebar, .X, side), ui.pane_extent(&app.bottom, axis, bottom), app.saved))
				ui.next({width = ui.text_size(), height = ui.px(em * 2)})
				if ui.button("Place the bottom panel###place").clicked { ui.ctx_menu_open(ui.key_from_string(0, "place_menu"), ui.mouse_pos()) }
				if ui.ctx_menu(ui.key_from_string(0, "place_menu")) { ui.pane_place_menu(&app.bottom) }
			}
			r := ui.pane_split("###bottom_split", axis, &app.bottom, bottom)
			if r.size > 0 {
				if axis == .Y { ui.next({width = ui.fill(), height = ui.px(r.size * sc)}) } else { ui.next({width = ui.px(r.size * sc), height = ui.fill()}) }
				if ui.column(.Start, {.Draw_Background}, "###bottom") {
					ui.next({width = ui.text_size(), height = ui.px(em * 2)})
					ui.label("  Bottom panel")
				}
			}
		}
	}
}

frame :: proc(app: ^App, inner := false) {
	at_once := render.pace_frame(&app.pacer, &app.r, app.win, idled = app.slept, dragging = ui.active_key() != 0, inner = inner)
	app.slept = false
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)
	if len(events) > 0 { app.frames_requested = max(app.frames_requested, 2) }
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), 0.0005, 0.1)
	app.last_tick = now
	ui.apply_palette(&app.theme, ui.PALETTE_MIDNIGHT)
	platform.set_dark_title(app.win, true)
	base := ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.ui_font, font_size = 14, text_pad = 6, cursor = .Arrow}
	ui.begin_build(&app.ui_state, {window_size = size, events = events, dt = dt, animations = platform.os_animations_enabled(), dpi_scale = app.win.dpi_scale, base = base, window = app.win})
	build_ui(app)
	ui.end_build()
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	if ui.needs_frame(&app.ui_state) { app.frames_requested = max(app.frames_requested, 1) }
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r, !at_once)
	render.paced_present(&app.pacer)
	free_all(context.temp_allocator)
}

main :: proc() {
	app := new(App)
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit panes", {900, 600}, transparent = true)
	if !render.init_window(&app.r, app.win, app.win.size, transparent = true) { fmt.eprintln("renderer init failed"); return }
	render.set_fixed_surface(&app.r, platform.monitor_size(app.win))   // (a resize never stretches a frame: docs/getting-started.md)
	ok: bool
	app.ui_font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("cannot load a UI font"); return }
	app.icons, _ = font.load_embedded(&app.fonts, ui.ICON_FONT_DATA)
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.icon_font = app.icons
	app.sidebar.size[.X], app.bottom.size = 240, {.X = 240, .Y = 160}
	app.open = {true, false, true, false}
	app.last_tick = time.tick_now()
	app.frames_requested = 2
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user), inner = true) }
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) { platform.wait_event(app.win, ui.wake_in_ms(&app.ui_state)); app.slept = true }
		frame(app)
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}
	ui.destroy(&app.ui_state)
	draw.destroy(&app.dc)
	render.destroy(&app.r)
	font.destroy(&app.fonts)
	ui.theme_destroy(&app.theme)
	platform.destroy_window(app.win)
	free(app)
}
