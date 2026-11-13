package showcase

// The settings scene: every standard preference of the toolkit (prefs_page.STANDARD_ALL) on prefs_page's page, its
// sidebar, its groups and its folded Advanced part, the themes as cards with the user's own under them. Nothing is read
// from or written to the disk: the registry starts at its defaults, and the paths shown are examples.

import "core:strings"
import config "../../src/config"
import lucide "../../src/lucide"
import prefs_page "../../src/prefs_page"
import "../../src/ui"

// Where a program keeps them (shown at the foot of the sidebar and under the themes' cards; never opened here).
SETTINGS_FILE :: "~/.config/gui_toolkit_showcase/settings.txt"
THEMES_FILE   :: "~/.config/gui_toolkit_showcase/themes.txt"

SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "general", title = "General", icon = lucide.SETTINGS},
	{category = "appearance", title = "Appearance", icon = lucide.PALETTE},
	{category = "window", title = "Window", icon = lucide.MONITOR},
	{category = "scrolling", title = "Scrolling", icon = lucide.MOUSE_POINTER_2},
	{category = "input", title = "Input", icon = lucide.KEYBOARD},
	{category = "timing", title = "Timing", icon = lucide.TIMER},
	{category = "rendering", title = "Rendering", icon = lucide.CPU},
	{category = "update", title = "Update", icon = lucide.REFRESH_CW},
}

// `page`: the category shown first ("": the first one); `advanced`: its Advanced part unfolded.
settings_open :: proc(app: ^App, page: string, advanced: bool) {
	app.prefs = config.prefs_make()
	d := prefs_page.STANDARD_DEFAULTS
	d.app_name = "the showcase"
	d.theme = app.choice.name   // (from the command line: it lives as long as the program)
	d.mode = app.choice.mode == .Light ? "light" : "dark"
	d.finish = ui.FINISH_NAMES[app.choice.finish]
	prefs_page.standard_register(&app.prefs, prefs_page.STANDARD_ALL, d)
	prefs_page.standard_watch(&app.watch, &app.prefs, &app.main.state, {renderer = &app.shared.r, fonts = &app.shared.fonts})
	prefs_page.themes_file_init(&app.themes_file, THEMES_FILE, app.themes[:])
	if page != "" {
		app.page.current = strings.clone(page)
		if advanced { app.page.unfolded[strings.clone(page)] = true }
	}
	if app.scene == .Settings { prefs_page.focus_search(&app.page) }   // (what is typed searches)
}

settings_close :: proc(app: ^App) {
	prefs_page.standard_unwatch(&app.watch)
	prefs_page.themes_file_destroy(&app.themes_file)
	prefs_page.destroy(&app.page)
	config.prefs_destroy(&app.prefs)
}

settings_options :: proc(app: ^App) -> prefs_page.Options {
	return {
		user = app,
		pages = SETTINGS_PAGES[:],
		icon_font = ui.lucide_icons(), search_icon = lucide.SEARCH, reset_icon = lucide.ROTATE_CCW,
		file = SETTINGS_FILE,
		version = "gui_toolkit showcase " + ui.VERSION,
		themes = app.themes_file.all[:], themes_light = app.shown.light,
		themes_file = &app.themes_file,
		changed = settings_changed,
	}
}

// A value set or reset: the look follows the appearance's preferences at once (the others: standard_watch).
@(private = "file")
settings_changed :: proc(user: rawptr, name: string) {
	app := (^App)(user)
	if !strings.has_prefix(name, "appearance.") { return }
	a := prefs_page.appearance_read(&app.prefs, context.temp_allocator)
	c := prefs_page.appearance_choice(a)
	// (the name kept is the list's own, which lives as long as the list; the registry's copy was temporary)
	name_kept := app.choice.name
	for t in app.themes { if t.name == c.name { name_kept = t.name } }
	c.name = name_kept
	app.choice = c
}

settings_build :: proc(app: ^App, em: f32) {
	o := settings_options(app)
	if prefs_page.back_bar(&app.page, o, "Settings", "Back to the showcase (Escape)", em) { app.scene = .Intents }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, o)
}
