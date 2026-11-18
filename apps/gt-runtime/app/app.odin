// gt-runtime: one plugin run as an application (src/md/features/plugins.md, "The toolkit as a runtime"). The window,
// the theme, the palette, the settings and the toasts are the toolkit's; the application brings only its JavaScript.
//
//   gt-runtime <folder>       a plugin's folder (its plugin.json and its files)
//   gt-runtime <main.js>      a lone file: its manifest is implied (its name, one view "main")
//
// The plugin's first view fills the window. Its commands are in the palette (Ctrl+K); the settings (Ctrl+,) hold the
// look and the Plugins page. It is the same host as a program's plugins (gt:plugins): no second mechanism.
//
// A package of its own, with open, frame and close, so that a tool can run it as the film tool runs the showcase
// (tools/film, the film "runtime"); ../main.odin is the program's loop.
package gt_runtime_app

import "core:fmt"
import "core:slice"
import "core:strings"
import config "gt:config"
import host "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import plugins "gt:plugins"
import prefs_page "gt:prefs_page"
import "gt:render"
import "gt:ui"

// The program's folders (platform.user_dir): its settings, plugins.toml, the plugins' logs.
APP_FOLDER :: "gt-runtime"
SETTINGS_FILE :: "settings.txt"
// What a manifest's "program" must say to be for gt-runtime only.
PROGRAM_ID :: "gt-runtime"
WINDOW_SIZE :: [2]int{760, 640}

Scene :: enum { Main, Settings }

App :: struct {
	shared:    host.Shared,
	main:      host.Host,
	palette:   ui.Command_Palette,
	palette_settings: prefs_page.Palette_Settings,
	announcer: ui.Announcer,
	plugins:   plugins.Host,
	prefs:     config.Prefs,
	writer:    config.User_Writer,
	watch:     prefs_page.Standard_Watch,
	page:      prefs_page.Page,
	shown:     ui.Theme_Shown,
	scene:     Scene,
	path:      string,   // what it runs (the command line's)
	settings_path: string,
	titled:    bool,     // the window has the plugin's name
}

Cmd :: enum { Settings }

@(rodata)
COMMANDS := [Cmd]ui.Command{
	.Settings = {id = "settings", label = "Settings…", group = "General", keys = {{.Comma, {.Ctrl}}}, icon = lucide.SETTINGS},
}

@(private = "file")
build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	plugins.host_build(&app.plugins, &app.palette)
	ui.palette_commands(&app.palette, slice.enumerated_array(&COMMANDS), nil)
	prefs_page.palette_settings_add(&app.palette, &app.palette_settings, &app.prefs, &app.page,
		proc(user: rawptr) -> prefs_page.Page_Options { return settings_options((^App)(user)) },
		proc(user: rawptr) { (^App)(user).scene = .Settings }, app)
	ui.palette_keys(&app.palette)
	if c, ok := ui.palette_chosen(&app.palette); ok {
		if i, is := ui.palette_chosen_command(&app.palette, c); is && Cmd(i) == .Settings { app.scene = .Settings }
	}
	if ui.command_pressed(COMMANDS[.Settings]) { app.scene = .Settings }
	p := the_plugin(app)
	if p != nil && !app.titled {
		app.titled = true
		platform.set_title(h.win, p.manifest.name)
	}
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(flags = {.Draw_Background}, id = "###window") {
		switch app.scene {
		case .Settings:
			o := settings_options(app)
			if prefs_page.back_bar(&app.page, o, "Settings", "Back (Escape)", em) || prefs_page.escape_leaves(&app.page) { app.scene = .Main }
			ui.next({width = ui.fill(), height = ui.fill()})
			prefs_page.build(&app.page, &app.prefs, o)
		case .Main:
			main_build(app, p, em)
		}
	}
	config.user_writer_save(&app.writer, &app.prefs)
}

// The plugin's first view, in the window's margins; or what keeps it from showing.
@(private = "file")
main_build :: proc(app: ^App, p: ^plugins.Plugin, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###main_scroll") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###main_row") {
			ui.space(ui.PAGE_MARGIN)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###main_column") {
				ui.space(ui.PAGE_MARGIN)
				main_content(app, p, em)
				ui.space(ui.PAGE_MARGIN)
			}
			ui.space(ui.PAGE_MARGIN)
		}
	}
}

@(private = "file")
main_content :: proc(app: ^App, p: ^plugins.Plugin, em: f32) {
	words := ""
	switch {
	case !plugins.loaded(&app.plugins): words = "Reading the plugin…"
	case p == nil:                      words = fmt.tprintf("Nothing to run at %s.", app.path)
	case p.state == .Refused:           words = fmt.tprintf("%s cannot run: %s.", p.manifest.name, p.refused)
	case p.state == .Suspended:         words = fmt.tprintf("%s is suspended: gt-runtime ended while it ran.", p.manifest.name)
	case len(p.manifest.views) == 0:    words = fmt.tprintf("%s has no view. Its commands are in the palette (Ctrl+K).", p.manifest.name)
	}
	if words != "" {
		ui.next({width = ui.fill()})
		ui.paragraph(fmt.tprintf("%s###main_words", words))
		if p != nil && p.state == .Suspended {
			ui.space(ui.ITEM_GAP)
			if ui.button("main_resume", "Run it again", o = {intent = .Primary}).clicked { plugins.set_enabled(&app.plugins, p.manifest.id, true) }
		}
		return
	}
	_ = plugins.view_body(&app.plugins, p.manifest.id, p.manifest.views[0].id)
}

// The one plugin of the host (nil: not read yet, or nothing there).
@(private = "file")
the_plugin :: proc(app: ^App) -> ^plugins.Plugin {
	list := plugins.host_plugins(&app.plugins)
	return len(list) > 0 ? list[0] : nil
}

@(private = "file")
settings_options :: proc(app: ^App) -> prefs_page.Page_Options {
	pages := make([dynamic]prefs_page.Page_Info, context.temp_allocator)
	append(&pages, prefs_page.Page_Info{category = "appearance", title = "Appearance", icon = lucide.PALETTE})
	append(&pages, ..plugins.settings_pages(&app.plugins))   // (the plugin's own settings, from its manifest)
	append(&pages, plugins.page_info(&app.plugins))
	return {
		user = app, pages = pages[:],
		icon_font = ui.lucide_icons(), search_icon = lucide.SEARCH, reset_icon = lucide.ROTATE_CCW,
		file = app.settings_path, version = "gt-runtime " + ui.VERSION,
		themes = ui.THEMES[:], themes_light = app.shown.light,
	}
}

// Before each build: the theme the settings choose (theme_show applies it only when what it reads changed).
@(private = "file")
params :: proc(h: ^host.Host, p: ^ui.Build_Params) {
	app := (^App)(h.user)
	a := prefs_page.appearance_read(&app.prefs, context.temp_allocator)
	if ui.theme_show(&app.shared.theme, ui.THEMES[:], prefs_page.appearance_choice(a), &app.shown, render.blend_space(&app.shared.r)) {
		platform.set_dark_title(h.win, !app.shown.light)
		h.background = ui.theme_lookup(&app.shared.theme, {}, "background")
	}
	p.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.shared.font, font_size = 15, text_pad = 6, cursor = .Arrow}
}

// How it opens. A film or a test sets `headless` (and `gpu`, to draw on the card) and `dirs`: its settings, plugins.toml
// and the plugin's log and data under a folder of its own, so a run never reads nor writes the person's.
Options :: struct {
	path:     string,   // what it runs: a plugin's folder or a lone .js file
	headless: bool,
	gpu:      bool,     // headless on the graphics card (a film's), not the software renderer
	dirs:     string,   // "": the user's folders; else <dirs>/config, <dirs>/state, <dirs>/data
	size:     [2]int,   // the window's logical size ({}: WINDOW_SIZE)
}

// The application, up to its first frame. nil: it cannot start, and has said why.
open :: proc(o: Options) -> ^App {
	app := new(App)
	app.path = strings.clone(o.path)
	if !host.host_open(&app.main, &app.shared, {title = "gt-runtime", size = o.size != {} ? o.size : WINDOW_SIZE, headless = o.headless, headless_gpu = o.gpu}, build, app) {
		free(app)
		return nil
	}
	h := &app.main
	h.state.icon_font = ui.lucide_icons()
	h.params = params
	h.after_input = 4
	h.settle = 4
	h.after_build = proc(h: ^host.Host) { if ui.needs_frame(&h.state) { h.settle = max(h.settle, 2) } }

	// (the settings are read here, before the first frame: the window's loop makes no disk call; writes go to the
	// writer's thread)
	app.prefs = config.prefs_make()
	d := prefs_page.STANDARD_DEFAULTS
	d.app_name, d.theme = "gt-runtime", "Midnight"
	prefs_page.standard_register(&app.prefs, {.Appearance, .Session}, d)
	config_dir := o.dirs != "" ? fmt.tprintf("%s/config", o.dirs) : platform.user_dir(.Config, APP_FOLDER, context.temp_allocator)
	if config_dir != "" {
		app.settings_path = strings.concatenate({config_dir, "/", SETTINGS_FILE})
		_, _ = config.load_file(&app.prefs, app.settings_path, .User)
		config.user_writer_start(&app.writer, &app.prefs, app.settings_path)
	}
	prefs_page.standard_watch(&app.watch, &app.prefs, &h.state, {renderer = &app.shared.r, fonts = &app.shared.fonts, window = h.win})
	app.announcer = {mode = prefs_page.announce_mode(&app.prefs), window = h.win, state = &h.state}
	ho := plugins.Host_Options{program = APP_FOLDER, program_id = PROGRAM_ID, single = o.path, announcer = &app.announcer, prefs = &app.prefs, sandbox = .If_Available}
	if o.dirs != "" {
		ho.config_dir = config_dir
		ho.state_dir = fmt.tprintf("%s/state", o.dirs)
		ho.data_dir = fmt.tprintf("%s/data", o.dirs)
	}
	plugins.host_open(&app.plugins, &h.state, ho)
	return app
}

// One frame of its window: what the program's loop runs after its wait, and a film at each of its frames.
frame :: proc(app: ^App) { host.host_frame(&app.main) }

close :: proc(app: ^App) {
	plugins.host_close(&app.plugins)   // (before the State goes)
	ui.palette_destroy(&app.palette)
	prefs_page.destroy(&app.page)
	prefs_page.standard_unwatch(&app.watch)
	_ = config.user_writer_stop(&app.writer, &app.prefs)
	config.prefs_destroy(&app.prefs)
	ui.chores_stop()
	host.host_close(&app.main)
	delete(app.path)
	delete(app.settings_path)
	free(app)
}
