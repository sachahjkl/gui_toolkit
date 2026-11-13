package showcase

// The frame every scene stands in: a bar along the top (the brand, the search of the commands, the light and dark switch,
// the settings), a sidebar of the scenes, the scene, a status bar; the overlays last, over all of it.

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import config "../../src/config"
import "../../src/host"
import lucide "../../src/lucide"
import prefs_page "../../src/prefs_page"
import "../../src/ui"

// The scenes the sidebar lists (the overlays' scenes stand on one of them), their titles and icons.
NAV := [?]Scene{.Intents, .Controls, .Menus, .Graph, .Themes, .Settings}

SCENE_TITLES := [Scene]string{
	.Intents = "Intents and hues", .Controls = "Numbers and ranges", .Palette = "Command palette", .Menus = "Menus",
	.Dialog = "Dialogs", .Confirm = "Confirmation", .Prompt = "Prompt", .Settings = "Settings", .Graph = "Node graph",
	.Toasts = "Toasts", .Themes = "Themes",
}

SCENE_ICONS := [Scene]string{
	.Intents = lucide.PALETTE, .Controls = lucide.SLIDERS_HORIZONTAL, .Palette = lucide.COMMAND, .Menus = lucide.FOLDER_OPEN,
	.Dialog = lucide.DOWNLOAD, .Confirm = lucide.TRASH_2, .Prompt = lucide.KEY_ROUND, .Settings = lucide.SETTINGS,
	.Graph = lucide.GIT_BRANCH, .Toasts = lucide.BELL, .Themes = lucide.SUN,
}

// The page under an overlay's scene.
page_of :: proc(s: Scene) -> Scene {
	#partial switch s {
	case .Palette:                  return .Intents
	case .Dialog, .Confirm, .Prompt: return .Controls
	case .Toasts:                   return .Graph
	}
	return s
}

// The commands of the palette: the program's own, then one per preference of its settings (prefs_page.palette_commands).
COMMANDS := [?]ui.Command{
	{label = "New window", group = "File", keys = {{.N, {.Ctrl, .Shift}}}, icon = lucide.PLUS},
	{label = "Open…", group = "File", keys = {{.O, {.Ctrl}}}, icon = lucide.FOLDER_OPEN},
	{label = "Save", group = "File", keys = {{.S, {.Ctrl}}}, icon = lucide.SAVE},
	{label = "Export pictures…", group = "File", keys = {{.E, {.Ctrl, .Shift}}}, icon = lucide.DOWNLOAD},
	{label = "Theme: next", group = "View", tags = {"colours", "look"}, keys = {{.T, {.Ctrl}}}, icon = lucide.PALETTE},
	{label = "Theme: light or dark", group = "View", tags = {"mode", "night", "day"}, keys = {{.L, {.Ctrl, .Shift}}}, icon = lucide.MOON},
	{label = "Theme: open the themes file", group = "View", tags = {"colours", "custom"}, icon = lucide.FILE_TEXT},
	{label = "Finish: machined", group = "View", tags = {"bevel", "relief"}, icon = lucide.SPARKLES},
	{label = "Zoom in", group = "View", keys = {{.Equal, {.Ctrl}}}, icon = lucide.PLUS},
	{label = "Zoom out", group = "View", keys = {{.Minus, {.Ctrl}}}, icon = lucide.MINUS},
	{label = "Node graph: fit the view", group = "Graph", keys = {{.F, {}}}, icon = lucide.SCAN},
	{label = "Settings…", group = "General", keys = {{.Comma, {.Ctrl}}}, icon = lucide.SETTINGS},
	{label = "Keyboard shortcuts", group = "General", keys = {{.F1, {}}}, icon = lucide.KEYBOARD},
}

build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	app.builds += 1
	em := ui.font_size()
	if app.builds == 1 && app.scene == .Toasts { toasts_say(app) }   // (in a build: a toast is born at the build's time)
	if ui.key_press(.K, {.Ctrl}) { ui.palette_open(&app.palette) }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###app") {
		top_bar(app, em)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###body") {
			if app.scene == .Settings {
				ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
				if ui.column(id = "###settings") { settings_build(app, em) }
			} else {
				sidebar(app, em)
				scene_build(app, page_of(app.scene), em)
			}
		}
		status_line(app, em)
	}
	overlays(app, em)
	// (between the bars: a toast never hides the status line; end_build shows them there)
	ui.set_toast_area({{0, ui.dense(em * 2.8)}, {size.x, size.y - ui.dense(em * 2)}})
}

@(private = "file")
top_bar :: proc(app: ^App, em: f32) {
	if ui.tags("bar") {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8)), radius = 0})
		if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###top") {
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.px(em * 1.6), height = ui.pct(1), font = ui.lucide_icons(), text_align = .Center, fg = ui.hue_color(.Accent)})
			ui.build_box({.Draw_Text, .No_Text_Trunc}, lucide.SPARKLES + "###logo")
			ui.spacer(ui.px(em * 0.3))
			ui.next({width = ui.text_size(), height = ui.pct(1), font_size = math.round(em * 1.05), text_pad = 0})
			ui.label("gui_toolkit###brand")
			ui.spacer(ui.px(em * 0.5))
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("showcase  ·  %s###what", ui.VERSION))
			}
			ui.spacer(ui.fill())
			if ui.search_launcher("###search", "Search the commands", "Ctrl+K", tip = "The command palette").clicked {
				ui.palette_open(&app.palette)
			}
			ui.spacer(ui.px(em * 1.2))
			light := app.shown.light
			ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2), radius = em * 0.45})
			if ui.button("mode", icon = light ? lucide.MOON : lucide.SUN, o = {tip = light ? "Dark" : "Light"}).clicked {
				app.choice.mode = light ? .Dark : .Light
			}
			ui.spacer(ui.px(em * 0.2))
			ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2), radius = em * 0.45})
			bell := ui.button("bell", icon = lucide.BELL, o = {tip = "Messages"})
			ui.badge(bell.box, 3, .Danger)
			ui.spacer(ui.px(em * 0.2))
			ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2), radius = em * 0.45})
			if ui.button("settings", icon = lucide.SETTINGS, o = {tip = "Settings (Ctrl+,)", face = app.scene == .Settings ? .Toggled : .Ghost}).clicked {
				app.scene = app.scene == .Settings ? .Intents : .Settings
			}
			ui.spacer(ui.px(em * 0.8))
		}
	}
}

@(private = "file")
sidebar :: proc(app: ^App, em: f32) {
	shown := page_of(app.scene)
	if ui.tags("bar") {
		ui.next({width = ui.px(em * 14), height = ui.fill(), axis = .Y, radius = 0})
		if ui.column(flags = {.Draw_Background, .Draw_Side_Right}, id = "###nav") {
			ui.spacer(ui.px(em * 0.9))
			for s in NAV {
				if s == .Settings { continue }
				ui.next({width = ui.fill(), height = ui.px(em * 2.3), axis = .X})
				if ui.row(id = fmt.tprintf("###navrow%v", s)) {
					ui.spacer(ui.px(em * 0.6))
					face := s == shown ? ui.Button_Face.Toggled : .Ghost
					if ui.button(fmt.tprintf("###nav%v", s), SCENE_TITLES[s], SCENE_ICONS[s], {face = face, width = ui.fill(), left = true}).clicked {
						app.scene = s
					}
					ui.spacer(ui.px(em * 0.6))
				}
				ui.spacer(ui.px(em * 0.25))
			}
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###navline") {
				ui.spacer(ui.px(em * 0.9))
				ui.hline(ui.fill())
				ui.spacer(ui.px(em * 0.9))
			}
			ui.spacer(ui.px(em * 0.6))
			// the overlays, opened from here as a program would
			overlay_link(app, "###open_palette", lucide.COMMAND, "Command palette", .Palette, em)
			overlay_link(app, "###open_dialog", lucide.DOWNLOAD, "Export dialog", .Dialog, em)
			overlay_link(app, "###open_confirm", lucide.TRASH_2, "Delete for good…", .Confirm, em)
			overlay_link(app, "###open_prompt", lucide.KEY_ROUND, "Unlock the key…", .Prompt, em)
			overlay_link(app, "###open_toasts", lucide.BELL, "Say what was done", .Toasts, em)
			ui.spacer(ui.fill())
			ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
			if ui.row(id = "###health") {
				ui.spacer(ui.px(em * 1.1))
				ui.dot("###health_dot", em * 0.55, .Success)
				ui.spacer(ui.px(em * 0.6))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = math.round(em * 0.9)})
					ui.label("Every service answers###health_words")
				}
			}
			ui.spacer(ui.px(em * 0.6))
		}
	}
}

// A line of the sidebar that opens an overlay: a button of the Link face, words that do what they say.
@(private = "file")
overlay_link :: proc(app: ^App, id, glyph, words: string, s: Scene, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.9), axis = .X, cross = .Center})
	if ui.row(id = fmt.tprintf("%s_row", id)) {
		ui.spacer(ui.px(em * 1.1))
		if ui.button(id, words, glyph, {face = .Link, icon_font = ui.lucide_icons(), intent = app.scene == s ? .Primary : .Neutral}).clicked { scene_open(app, s) }
	}
}

// Shows the scene `s`, its overlay open.
scene_open :: proc(app: ^App, s: Scene) {
	app.scene = s
	#partial switch s {
	case .Palette: ui.palette_open(&app.palette)
	case .Dialog:  app.dialog_open = true
	case .Confirm: app.confirm_open = true
	case .Prompt:  app.prompt_open = true
	case .Toasts:  toasts_say(app)
	}
}

@(private = "file")
status_line :: proc(app: ^App, em: f32) {
	if ui.status_bar("###status", 2, 0.86) {
		if ui.status_fill("###status_left") {
			ui.status_item(fmt.tprintf("%s###st_scene", SCENE_TITLES[app.scene]))
			ui.status_separator()
			ui.status_item(fmt.tprintf("%s%s###st_theme", app.shown.def.name, app.shown.light ? ", light" : ""))
			ui.status_separator()
			ui.status_item(fmt.tprintf("%s finish###st_finish", ui.FINISH_NAMES[app.shared.theme.finish]))
		}
		ui.status_item("Ctrl+K: every command###st_keys")
	}
}

// The palette's table: the program's commands, then one per preference (prefs_page.palette_commands), and each line's
// key in the memory of choices (a command's label, "pref:" and a preference's name). Made again only when the settings
// change (a frame does not walk the preferences), in an arena of its own.
Palette_Table :: struct {
	arena:    virtual.Arena,
	commands: []ui.Command,
	keys:     []string,
	names:    []string,   // the preferences' names, the lines after COMMANDS
	version:  u64,        // the settings' version it was made for, plus one (0: not made); the palette's version
}

palette_table_make :: proc(table: ^Palette_Table, prefs: ^config.Prefs, o: prefs_page.Page_Options) {
	virtual.arena_destroy(&table.arena)
	table^ = {}
	a := virtual.arena_allocator(&table.arena)
	settings, names := prefs_page.palette_commands(prefs, o, a)
	table.commands = slice.concatenate([][]ui.Command{COMMANDS[:], settings}, a)
	table.keys = make([]string, len(table.commands), a)
	for c, i in COMMANDS { table.keys[i] = c.label }
	for n, i in names { table.keys[len(COMMANDS) + i] = fmt.aprintf("pref:%s", n, allocator = a) }
	table.names = make([]string, len(names), a)
	for n, i in names { table.names[i] = strings.clone(n, a) }
	table.version = prefs.version + 1
}

palette_table_destroy :: proc(table: ^Palette_Table) {
	virtual.arena_destroy(&table.arena)
	table^ = {}
}

// The overlays of the scene: the palette, the dialogs; the menu is the menus scene's own.
@(private = "file")
overlays :: proc(app: ^App, em: f32) {
	o := settings_options(app)
	table := &app.palette_table
	if app.palette.open && table.version != app.prefs.version + 1 { palette_table_make(table, &app.prefs, o) }
	if i, _ := ui.palette(&app.palette, table.commands, nil, {memory = &app.choices, names = table.keys, version = table.version}); i >= 0 {
		ui.choice_note(&app.choices, table.keys[i])
		if i >= len(COMMANDS) {
			app.scene = .Settings
			prefs_page.show(&app.page, &app.prefs, o, table.names[i - len(COMMANDS)])
		}
	}
	dialog_build(app, em)
	switch ui.confirm("delete", &app.confirm_open, {
		title = "Delete 4 pictures for good?", note = "They leave the disk at once: the bin does not keep them.", act = "Delete",
		lines = {"harbour-at-dusk.webp", "harbour-at-dusk-2.webp", "pier-in-fog.png", "lighthouse.jpg"},
	}) {
	case .Confirmed: ui.announce(&app.announcer, .Good, "4 pictures deleted")
	case .Cancelled, .None:
	}
	switch ui.prompt("unlock", &app.prompt_open, &app.pin, {
		title = "Unlock the key", note = "Type the PIN of the security key to sign the release.", placeholder = "PIN",
		secret = true, reveal = &app.reveal, act = "Unlock",
	}) {
	case .Confirmed, .Cancelled: ui.line_edit_wipe(&app.pin)
	case .None:
	}
}
