package showcase

// The frame every scene stands in: a bar along the top (the brand, the search of the commands, the light and dark switch,
// the settings), a sidebar of the scenes, the scene, a status bar; the overlays last, over all of it.

import "core:fmt"
import "core:math"
import host "gt:host"
import lucide "gt:lucide"
import prefs_page "gt:prefs_page"
import "gt:ui"

// The scenes the sidebar lists (the overlays' scenes stand on one of them), their titles and icons.
NAV := [?]Scene{.Intents, .Controls, .Values, .Steppers, .Menus, .Toolbar, .Views, .Graph, .Themes, .Settings}

SCENE_TITLES := [Scene]string{
	.Intents = "Intents and hues", .Controls = "Numbers and ranges", .Palette = "Command palette", .Menus = "Menus",
	.Dialog = "Dialogs", .Confirm = "Confirmation", .Prompt = "Prompt", .Settings = "Settings", .Graph = "Node graph",
	.Toasts = "Toasts", .Themes = "Themes", .Toolbar = "Tool bars", .Views = "Views", .Files = "File browser",
	.Steppers = "Steppers", .Values = "Values",
}

SCENE_ICONS := [Scene]string{
	.Intents = lucide.PALETTE, .Controls = lucide.SLIDERS_HORIZONTAL, .Palette = lucide.COMMAND, .Menus = lucide.FOLDER_OPEN,
	.Dialog = lucide.DOWNLOAD, .Confirm = lucide.TRASH_2, .Prompt = lucide.KEY_ROUND, .Settings = lucide.SETTINGS,
	.Graph = lucide.GIT_BRANCH, .Toasts = lucide.BELL, .Themes = lucide.SUN, .Toolbar = lucide.PENCIL_RULER,
	.Views = lucide.LAYOUT_DASHBOARD, .Files = lucide.FOLDER_OPEN, .Steppers = lucide.LIST_CHECKS, .Values = lucide.SHAPES,
}

// The page under an overlay's scene.
page_of :: proc(s: Scene) -> Scene {
	#partial switch s {
	case .Palette:                  return .Intents
	case .Dialog, .Confirm, .Prompt, .Files: return .Controls
	case .Toasts:                   return .Graph
	}
	return s
}

// The commands of the palette (its commands source); its settings source lists the preferences, its moves source the
// views' moves.
COMMANDS := [?]ui.Command{
	{id = "window.new", label = "New window", group = "File", keys = {{.N, {.Ctrl, .Shift}}}, icon = lucide.PLUS},
	{id = "open", label = "Open…", group = "File", keys = {{.O, {.Ctrl}}}, icon = lucide.FOLDER_OPEN},
	{id = "save", label = "Save", group = "File", keys = {{.S, {.Ctrl}}}, icon = lucide.SAVE},
	{id = "export", label = "Export pictures…", group = "File", keys = {{.E, {.Ctrl, .Shift}}}, icon = lucide.DOWNLOAD},
	{id = "theme.next", label = "Theme: next", group = "View", tags = {"colours", "look"}, keys = {{.T, {.Ctrl}}}, icon = lucide.PALETTE},
	{id = "theme.mode", label = "Theme: light or dark", group = "View", tags = {"mode", "night", "day"}, keys = {{.L, {.Ctrl, .Shift}}}, icon = lucide.MOON},
	{id = "theme.file", label = "Theme: open the themes file", group = "View", tags = {"colours", "custom"}, icon = lucide.FILE_TEXT},
	{id = "finish.machined", label = "Finish: machined", group = "View", tags = {"bevel", "relief"}, icon = lucide.SPARKLES},
	{id = "zoom.in", label = "Zoom in", group = "View", keys = ui.ZOOM_IN_KEYS[:], icon = lucide.PLUS},
	{id = "zoom.out", label = "Zoom out", group = "View", keys = ui.ZOOM_OUT_KEYS[:], icon = lucide.MINUS},
	{id = "graph.fit", label = "Node graph: fit the view", group = "Graph", keys = {{.F, {}}}, icon = lucide.SCAN},
	{id = "settings", label = "Settings…", group = "General", keys = {{.Comma, {.Ctrl}}}, icon = lucide.SETTINGS},
	{id = "shortcuts", label = "Keyboard shortcuts", group = "General", keys = {{.F1, {}}}, icon = lucide.KEYBOARD},
}

build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	app.builds += 1
	em := ui.font_size()
	// (in a build: a toast is born at the build's time, a view's owner is this window; nothing typed in the palette:
	// every command under its group, with its keys)
	if app.builds == 1 { scene_open(app, app.scene) }
	views_scene_follow(app)   // (the views scene's panels go with it: their space is built in that scene only)
	palette_sources(app)   // (before the keys open it; O(1) once added)
	ui.palette_keys(&app.palette)
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
				palette_show(app)
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
			// the scenes and the overlays: a column of choices on a vertical strip, with up and down arrows when the
			// window is too short for them (docs/strip.md)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.strip("###nav_strip", {axes = {.Y}}) {
				ui.spacer(ui.px(em * 0.9))
				for s in NAV {
					if s == .Settings { continue }
					ui.next({width = ui.fill(), height = ui.px(em * 2.3), axis = .X})
					if ui.row(id = fmt.tprintf("###navrow%v", s)) {
						// (a row's face is inset in it: its face stands 0.6 em from the sidebar's sides)
						ui.spacer(ui.px(em * (0.6 - ui.ROW_FACE_INSET_EM)))
						sig := ui.button(fmt.tprintf("###nav%v", s), SCENE_TITLES[s], SCENE_ICONS[s], {face = .Row, selected = s == shown, width = ui.fill(), left = true})
						if s == shown { ui.strip_reveal(sig.box) }
						if sig.clicked { app.scene = s }
						ui.spacer(ui.px(em * (0.6 - ui.ROW_FACE_INSET_EM)))
					}
					ui.spacer(ui.px(em * 0.1))
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
				overlay_link(app, "###open_files", lucide.FOLDER_OPEN, "Open a file…", .Files, em)
				overlay_link(app, "###open_toasts", lucide.BELL, "Say what was done", .Toasts, em)
			}
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
	case .Palette: palette_show(app)
	case .Dialog:  ui.view_open(ui.views(), EXPORT_VIEW, app)
	case .Confirm:
		ui.confirm_open("delete", {
			title = "Delete 4 pictures for good?", note = "They leave the disk at once: the bin does not keep them.", act = "Delete",
			lines = {"harbour-at-dusk.webp", "harbour-at-dusk-2.webp", "pier-in-fog.png", "lighthouse.jpg"},
		})
	case .Prompt:
		ui.prompt_open("unlock", &app.pin, {
			title = "Unlock the key", note = "Type the PIN of the security key to sign the release.", placeholder = "PIN",
			secret = true, reveal = &app.reveal, act = "Unlock",
		})
	case .Toasts:  toasts_say(app)
	case .Files:   files_open(app)
	}
}

// The palette's sources given their data: the commands (a constant table: O(1)), the settings (added once: the source
// asks for the page options when it reads, the themes' slice as it is then).
@(private = "file")
palette_sources :: proc(app: ^App) {
	ui.palette_commands(&app.palette, COMMANDS[:], nil)
	prefs_page.palette_settings_add(&app.palette, &app.palette_settings, &app.prefs, &app.page,
		proc(user: rawptr) -> prefs_page.Page_Options { return settings_options((^App)(user)) },
		proc(user: rawptr) { (^App)(user).scene = .Settings }, app)
}

@(private = "file")
palette_show :: proc(app: ^App) {
	palette_sources(app)
	ui.palette_open(&app.palette)
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

// The answers of the scene's overlays (views shown as dialogs, built at the end of the build); the menu is the menus
// scene's own.
@(private = "file")
overlays :: proc(app: ^App, em: f32) {
	// (a setting or a view's move acts in palette_chosen; the showcase's own commands only show themselves)
	_, _ = ui.palette_chosen(&app.palette)
	if ui.confirm_answer("delete") == .Confirmed { ui.announce(&app.announcer, .Good, "4 pictures deleted") }
	switch ui.prompt_answer("unlock") {
	case .Confirmed, .Cancelled: ui.line_edit_wipe(&app.pin)
	case .None:
	}
}
