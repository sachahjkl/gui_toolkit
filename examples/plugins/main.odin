// gui_toolkit example: plugins in JavaScript (gt:plugins). The window shows the settings' Plugins page and opens the
// command palette (Ctrl+K), where the commands of the plugins that are on appear. The plugins are the folders beside
// this file (sample/): turn Sample on, then run "Say hello" or "Loop forever" from the palette, and Stop it.
package plugins_example

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "gt:devtools"
import host "gt:host"
import "gt:platform"
import plugins "gt:plugins"
import "gt:ui"

// The program's folders (platform.user_dir): plugins.toml, the plugins' logs.
APP_FOLDER :: "gui_toolkit_plugins"

App :: struct {
	devtools:  ^devtools.Server,
	shared:    host.Shared,
	main:      host.Host,
	palette:   ui.Command_Palette,
	announcer: ui.Announcer,
	plugins:   plugins.Host,
}

@(private = "file")
build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	plugins.host_build(&app.plugins, &app.palette)
	ui.palette_keys(&app.palette)
	_, _ = ui.palette_chosen(&app.palette)   // (the plugins' source acts here)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(flags = {.Draw_Background}, id = "###page") {
		ui.space(ui.PAGE_MARGIN)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
		if ui.row(id = "###top") {
			ui.space(ui.PAGE_MARGIN)
			ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.3), text_pad = 0})
			ui.label("Plugins###title")
			ui.next({width = ui.px(math.round(em * 16)), height = ui.pct(1)})
			if ui.search_launcher("###commands", "Run a command", "Ctrl+K", tip = "The command palette").clicked {
				ui.palette_open(&app.palette, ">")
			}
			ui.space(ui.PAGE_MARGIN)
		}
		ui.space(ui.ITEM_GAP)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###body") {
			ui.space(ui.PAGE_MARGIN)
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###plugins") {
				page := plugins.page_info(&app.plugins)
				page.build(page.user, em)
			}
			ui.space(ui.PAGE_MARGIN)
		}
	}
}

@(private = "file")
params :: proc(h: ^host.Host, p: ^ui.Build_Params) {
	app := (^App)(h.user)
	ui.apply_palette(&app.shared.theme, ui.palette_of("Midnight"))
	platform.set_dark_title(h.win, true)
	p.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.shared.font, font_size = 15, text_pad = 6, cursor = .Arrow}
}

// The plugins' folder: this example's own (examples/plugins, beside the build folder), or the one given as the first
// argument.
@(private = "file")
plugins_folder :: proc() -> string {
	if len(os.args) > 1 { return os.args[1] }
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return "" }
	return fmt.tprintf("%s/../examples/plugins", filepath.dir(exe))
}

WINDOW_SIZE :: [2]int{720, 560}

open :: proc(headless := false) -> ^App {
	app := new(App)
	if !host.host_open(&app.main, &app.shared, {title = "gui_toolkit plugins", size = WINDOW_SIZE, headless = headless}, build, app) {
		free(app)
		return nil
	}
	h := &app.main
	h.state.icon_font = ui.lucide_icons()
	h.params = params
	h.after_input = 4
	h.settle = 4
	h.after_build = proc(h: ^host.Host) { if ui.needs_frame(&h.state) { h.settle = max(h.settle, 2) } }
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }
	app.announcer = {mode = .Window, state = &h.state}
	plugins.host_open(&app.plugins, &h.state, {program = APP_FOLDER, program_id = "plugins_example", folder = plugins_folder(), announcer = &app.announcer})
	app.devtools = devtools.start_from_env(h.win, "gui_toolkit plugins")
	return app
}

close :: proc(app: ^App) {
	devtools.stop(app.devtools)
	plugins.host_close(&app.plugins)   // (before the State goes: a plugin's last posts find the host closed)
	ui.palette_destroy(&app.palette)
	ui.chores_stop()
	host.host_close(&app.main)
	free(app)
}

main :: proc() {
	app := open()
	if app == nil { return }
	defer close(app)
	platform.show_window(app.main.win)
	for !platform.is_closed(app.main.win) {
		host.hosts_wait({&app.main})
		host.host_frame(&app.main)
	}
}
