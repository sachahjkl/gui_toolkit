// Side panes as views (ui.views_frame) and sections the user folds (ui.accordion): a sidebar of sections at the left,
// the content, a bottom panel. Drag a pane's handle to resize it. On the hover of a pane's top, its icons float it or
// close it; a right click there docks it at another edge ("Place the bottom panel" opens the bottom panel's menu acts
// as buttons). Tab to a handle and use the arrow keys; F6 goes through the areas.
//   odin run tools/tk -- build panes
package panes

import "core:fmt"
import "core:time"
import "../../src/draw"
import "../../src/font"
import "../../src/platform"
import "../../src/render"
import "../../src/ui"

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
	open:     [4]bool,   // the sections unfolded
	pacer: render.Pacer,
	slept: bool,
}

SECTIONS := [4]string{"Conversations", "Contacts", "Files", "Settings"}

sidebar_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {.Draw_Background}, "###sidebar") {
		ui.next({width = ui.fill(), height = ui.px(em * 2)})
		title := ui.label("  Sections###title")
		ui.view_drag_handle(v, title.box)
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

bottom_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	room := ui.view_room(v)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {.Draw_Background}, "###bottom") {
		ui.next({width = ui.text_size(), height = ui.px(em * 2)})
		ui.label(fmt.tprintf("  Bottom panel (%.0f x %.0f px)###words", room.x, room.y))
	}
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	vs := ui.views()
	if ui.views_frame(vs) {
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(.Center, {}, "###content") {
			ui.spacer(ui.px(em))
			panes := [2]string{"sidebar", "bottom"}
			for p, i in panes {
				ui.next({width = ui.text_size(), height = ui.px(em * 2)})
				name := i == 0 ? "Sidebar" : "Bottom panel"
				open := ui.view_is_open(vs, p)
				if ui.button(fmt.tprintf("toggle%d", i), fmt.tprintf("%s %s", open ? "Close the" : "Open the", name)).clicked {
					if open { ui.view_close(vs, p) } else { ui.view_open(vs, p, app) }
				}
			}
			ui.next({width = ui.text_size(), height = ui.px(em * 2)})
			if ui.button("place", "Place the bottom panel").clicked { ui.menu_open("place_menu", ui.mouse_pos()) }
			if ui.menu("place_menu") {
				// (the palette's commands of the views: the bottom panel's only)
				commands, acts := ui.views_commands(vs)
				for c, i in commands {
					if acts[i].id != "bottom" { continue }
					if ui.menu_item(fmt.tprintf("%s###c%d", c.label, i), icon = c.icon).clicked { ui.views_command_run(vs, acts[i]) }
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
	ui.apply_palette(&app.theme, ui.palette_of("Midnight"))
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
	app.open = {true, false, true, false}
	vs := ui.state_views(&app.ui_state)
	ui.view_register(vs, "sidebar", sidebar_view, ui.View_Options{title = "Sidebar", home = .Panel, home_place = {edge = .Left}, extent_em = 17})
	ui.view_register(vs, "bottom", bottom_view, ui.View_Options{title = "Bottom panel", home = .Panel, home_place = {edge = .Bottom}, extent_em = 11})
	ui.view_open(vs, "sidebar", app, owner = &app.ui_state)
	ui.view_open(vs, "bottom", app, owner = &app.ui_state)
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
