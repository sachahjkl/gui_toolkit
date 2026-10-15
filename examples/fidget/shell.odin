package fidget

import "core:fmt"
import "core:math"
import "core:strings"
import "../../draw"
import "../../platform"
import "../../ui"

////////////////////////////////
// Commands

run_cmd :: proc(app: ^App, cmd: Command) {
	switch cmd {
	case .Go_Controls: app.page = .Controls
	case .Go_Inputs: app.page = .Inputs
	case .Go_Data: app.page = .Data
	case .Go_Playground: app.page = .Playground
	case .Theme_Midnight, .Theme_Graphite, .Theme_Daylight, .Theme_Nord, .Theme_Dracula, .Theme_Amber:
		set_palette(app, int(cmd) - int(Command.Theme_Midnight))
		ui.toast(.Info, "Theme: %s", palettes[app.palette_idx].name)
	case .Next_Theme:
		set_palette(app, app.palette_idx + 1)
		ui.toast(.Info, "Theme: %s", palettes[app.palette_idx].name)
	case .Toggle_Status: app.show_status = !app.show_status
	case .Toggle_Animations:
		app.anim_mode = animations_enabled(app) ? .Off : .On
		ui.toast(.Info, "Animations %s", app.anim_mode == .Off ? "off" : "on")
	case .Anim_System: app.anim_mode = .System; app.os_anim_checked_ms = 0; ui.toast(.Info, "Animations follow the system setting")
	case .Anim_On: app.anim_mode = .On; ui.toast(.Info, "Animations always on")
	case .Anim_Off: app.anim_mode = .Off; ui.toast(.Info, "Animations always off")
	case .Toggle_Slowmo:
		app.slowmo = !app.slowmo
		ui.toast(.Info, app.slowmo ? "Slow motion: animations at 1/5 speed" : "Slow motion off")
	case .Toggle_Boxes: app.show_boxes = !app.show_boxes
	case .Toast_Info: ui.toast(.Info, "Heads up: this is an info toast")
	case .Toast_Good: ui.toast(.Good, "Saved successfully")
	case .Toast_Warn: ui.toast(.Warn, "Careful: the disk is 91%% full")
	case .Toast_Bad: ui.toast(.Bad, "Something went wrong (just kidding)")
	case .Clear_Toasts: ui.toasts_clear()
	case .Open_Modal: app.modal_open = true
	case .About: app.about_open = true
	case .Settings: app.settings_open = true
	case .Spawn_Balls: app.page = .Playground; spawn_balls(app, 25)
	case .Confetti: app.page = .Playground; spawn_confetti(app, {app.arena_size.x * 0.5, app.arena_size.y * 0.7}, 120)
	case .Clear_Balls: for &b in app.balls { b.alive = false }
	case .Reset_Values: reset_values(app); ui.toast(.Good, "All widget values reset")
	case .Zoom_In: ui.set_zoom(&app.ui_state, ui.zoom(&app.ui_state) * ui.ZOOM_STEP)
	case .Zoom_Out: ui.set_zoom(&app.ui_state, ui.zoom(&app.ui_state) / ui.ZOOM_STEP)
	case .Zoom_Reset: ui.set_zoom(&app.ui_state, 1)
	case .Quit: app.want_quit = true
	}
	app.frames_requested = 4
}

palette_toggle :: proc(app: ^App) {
	app.palette_open = !app.palette_open
	if app.palette_open {
		ui.field_clear(&app.palette_field)
		app.palette_sel, app.palette_scroll, app.palette_frames = 0, 0, 0
		app.palette_focus = true
	}
}

handle_shortcuts :: proc(app: ^App) {
	ctrl := platform.Modifiers{.Ctrl}
	if ui.key_press(.K, ctrl) || ui.key_press(.P, {.Ctrl, .Shift}) { palette_toggle(app) }
	if ui.key_press(.N1, ctrl) { run_cmd(app, .Go_Controls) }
	if ui.key_press(.N2, ctrl) { run_cmd(app, .Go_Inputs) }
	if ui.key_press(.N3, ctrl) { run_cmd(app, .Go_Data) }
	if ui.key_press(.N4, ctrl) { run_cmd(app, .Go_Playground) }
	if ui.key_press(.T, ctrl) { run_cmd(app, .Next_Theme) }
	if ui.key_press(.B, ctrl) { run_cmd(app, .Toggle_Status) }
	if ui.key_press(.J, ctrl) { run_cmd(app, .Toggle_Animations) }
	if ui.key_press(.F1) { run_cmd(app, .About) }
	if ui.key_press(.Comma, ctrl) { run_cmd(app, .Settings) }
}

////////////////////////////////
// Shell

build_ui :: proc(app: ^App) {
	handle_shortcuts(app)
	if app.debug_toasts && app.frame_index == 3 {
		ui.toast(.Info, "Heads up: this is an info toast")
		ui.toast(.Good, "Saved successfully")
		ui.toast(.Warn, "Careful: the disk is almost full")
		ui.toast(.Bad, "Something went wrong")
	}
	em := ui.font_size()
	if ui.style({width = ui.fill(), height = ui.fill(), radius = em * 0.45}) {
		ui.next({axis = .Y})
		page := ui.build_box({.Draw_Background}, "###page")
		if ui.parent(page) {
			build_menubar(app, em)
			build_tab_row(app, em)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.column(flags = {.Clip}, id = "###content") {
				switch app.page {
				case .Controls: page_controls(app)
				case .Inputs: page_inputs(app)
				case .Data: page_data(app)
				case .Playground: page_playground(app)
				}
			}
			build_statusbar(app, em)
		}
		build_palette(app)
		build_confirm(app)
		build_about(app)
		build_settings(app)
		// toasts live in the content area: below the menu bar + tabs, above the status bar
		top := em * (2.6 + 2.9)
		bottom := f32(app.win.size.y) - (app.show_status ? em * 2.1 : 0)
		ui.set_toast_area({{0, top}, {f32(app.win.size.x), bottom}})
		ui.toasts_build()
	}
}

build_menubar :: proc(app: ^App, em: f32) {
	menu_w := em * 21
	if ui.tags("bar") {
		ui.next({width = ui.fill(), height = ui.px(em * 2.6)})
		if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###menubar") {
			ui.spacer(ui.px(em * 0.6))
			if ui.tags("weak") { ui.icon(ICON_CUBE, em * 2) }
			ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
			if ui.style({font_size = math.round(em * 1.05)}) { ui.label("gui_toolkit") }
			ui.spacer(ui.px(em * 0.8))
			file_m := ui.menu_bar_button("File###menu_file")
			view_m := ui.menu_bar_button("View###menu_view")
			theme_m := ui.menu_bar_button("Theme###menu_theme")
			help_m := ui.menu_bar_button("Help###menu_help")
			ui.spacer(ui.fill())
			if ui.tags("ghost_button") {
				ui.next({width = ui.px(em * 15), height = ui.px(em * 2)})
				if ui.button_icon("bar_palette###bar_palette", ICON_FIND, "Command palette").clicked { palette_toggle(app) }
			}
			ui.spacer(ui.px(em * 0.4))
			ui.kbd("Ctrl+K")
			ui.spacer(ui.px(em * 0.8))

			if ui.ctx_menu(file_m, menu_w) {
				if ui.menu_item("Reset all values", "", false, ICON_UNDO).clicked { run_cmd(app, .Reset_Values) }
				if ui.menu_item("Dismiss all toasts", "", false, ui.ICON_X).clicked { run_cmd(app, .Clear_Toasts) }
				ui.hline(ui.px(menu_w))
				if ui.menu_item("Quit", "Alt+F4", false, ICON_STOP).clicked { run_cmd(app, .Quit) }
			}
			if ui.ctx_menu(view_m, menu_w) {
				if ui.menu_item("Settings...", "Ctrl+,", false, ICON_GEAR).clicked { run_cmd(app, .Settings) }
				ui.hline(ui.px(menu_w))
				if ui.menu_item("Status bar", "Ctrl+B", app.show_status).clicked { run_cmd(app, .Toggle_Status) }
				if ui.menu_item("Count UI boxes", "", app.show_boxes).clicked { run_cmd(app, .Toggle_Boxes) }
				if ui.menu_item("Slow-motion animations", "", app.slowmo).clicked { run_cmd(app, .Toggle_Slowmo) }
				ui.hline(ui.px(menu_w))
				if ui.menu_item("Animations: system setting", "", app.anim_mode == .System).clicked { run_cmd(app, .Anim_System) }
				if ui.menu_item("Animations: always on", "", app.anim_mode == .On).clicked { run_cmd(app, .Anim_On) }
				if ui.menu_item("Animations: always off", "Ctrl+J", app.anim_mode == .Off).clicked { run_cmd(app, .Anim_Off) }
				ui.hline(ui.px(menu_w))
				if ui.menu_item("Zoom in", "Ctrl +").clicked { run_cmd(app, .Zoom_In) }
				if ui.menu_item("Zoom out", "Ctrl -").clicked { run_cmd(app, .Zoom_Out) }
				if ui.menu_item("Reset zoom", "Ctrl 0").clicked { run_cmd(app, .Zoom_Reset) }
				ui.hline(ui.px(menu_w))
				for p in Page {
					if ui.menu_item(page_names[int(p)], fmt.tprintf("Ctrl+%d", int(p) + 1), app.page == p, page_icons[int(p)]).clicked { app.page = p }
				}
			}
			if ui.ctx_menu(theme_m, menu_w) {
				for p, i in palettes {
					if ui.menu_item(p.name, "", app.palette_idx == i).clicked { run_cmd(app, Command(int(Command.Theme_Midnight) + i)) }
				}
				ui.hline(ui.px(menu_w))
				if ui.menu_item("Cycle next", "Ctrl+T", false, ICON_REFRESH).clicked { run_cmd(app, .Next_Theme) }
			}
			if ui.ctx_menu(help_m, menu_w) {
				if ui.menu_item("Command palette", "Ctrl+K", false, ICON_FIND).clicked { palette_toggle(app) }
				if ui.menu_item("Confirm dialog demo", "", false, ICON_QUESTION).clicked { run_cmd(app, .Open_Modal) }
				ui.hline(ui.px(menu_w))
				if ui.menu_item("About", "F1", false, ui.ICON_INFO).clicked { run_cmd(app, .About) }
			}
		}
	}
}

build_tab_row :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2.9)})
	if ui.row(.Start, id = "###tabrow") {
		ui.spacer(ui.px(em * 0.8))
		sel := int(app.page)
		if ui.tabs("tab", page_names[:], page_icons[:], &sel) { app.page = Page(sel) }
	}
}

Spark_Draw :: struct { v: [64]f32, idx: int, color: draw.Color }

spark_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Spark_Draw)(user)
	r := b.rect
	w := (r.max.x - r.min.x) / 64
	h := r.max.y - r.min.y
	for i in 0 ..< 64 {
		ms := d.v[(d.idx + i) % 64]
		bh := clamp(ms / 8 * h, 1, h)
		c := d.color
		c.a = 0.35 + 0.65 * f32(i) / 63
		draw.rect(dc, {{r.min.x + f32(i) * w, r.max.y - bh}, {r.min.x + f32(i) * w + max(1, w - 1), r.max.y}}, c)
	}
}

build_statusbar :: proc(app: ^App, em: f32) {
	if !app.show_status { return }
	if ui.tags("bar") {
		ui.next({width = ui.fill(), height = ui.px(em * 2.1)})
		if ui.row(.Center, {.Draw_Background, .Draw_Side_Top}, "###statusbar") {
			if ui.style({font_size = math.round(em * 0.85)}) {
				ui.spacer(ui.px(em * 0.9))
				if ui.tags("weak") {
					ui.next({width = ui.text_size(), height = ui.pct(1)})
					ui.label(fmt.tprintf("%s  |  %s  |  zoom %d%%", page_names[int(app.page)], palettes[app.palette_idx].name, int(math.round(ui.zoom(&app.ui_state) * 100))))
				}
				ui.spacer(ui.fill())
				d := ui.frame_new(Spark_Draw)
				d.v, d.idx, d.color = app.ms_hist, app.ms_idx % 64, ui.color("accent")
				ui.next({width = ui.px(em * 8), height = ui.px(em * 1.2)})
				ui.custom("spark", spark_draw, d)
				ui.spacer(ui.px(em * 0.8))
				if ui.style({font = app.mono}) {
					if ui.tags("weak") {
						ui.next({width = ui.text_size(), height = ui.pct(1)})
						ui.label(app.show_boxes ? fmt.tprintf("%d boxes  |  frame %.2f ms", ui.boxes_built(&app.ui_state), app.ui_ms) : fmt.tprintf("frame %.2f ms", app.ui_ms))
					}
				}
				ui.spacer(ui.px(em * 0.9))
			}
		}
	}
}

////////////////////////////////
// Command palette

build_palette :: proc(app: ^App) {
	if !app.palette_open { return }
	em := ui.font_size()
	app.palette_frames += 1
	pw := min(em * 46, f32(app.win.size.x) / app.win.dpi_scale * 0.92)

	// rank commands: every space-separated needle part must match somewhere in the title
	entries := make([dynamic]Palette_Entry, context.temp_allocator)
	needle := ui.field_string(&app.palette_field)
	for cmd in Command {
		ranges, ok := ui.fuzzy_find(needle, command_info[cmd].title)
		if ok { append(&entries, Palette_Entry{cmd, ranges}) }
	}
	// keep matches that start earlier first (stable otherwise)
	for i in 1 ..< len(entries) {
		e := entries[i]
		start := len(e.ranges) > 0 ? e.ranges[0][0] : 0
		j := i - 1
		for j >= 0 && (len(entries[j].ranges) > 0 ? entries[j].ranges[0][0] : 0) > start { entries[j + 1] = entries[j]; j -= 1 }
		entries[j + 1] = e
	}
	n := len(entries)
	ROWS :: 9
	if n > 0 {
		if ui.key_press(.Down) { app.palette_sel = (app.palette_sel + 1) % n }
		if ui.key_press(.Up) { app.palette_sel = (app.palette_sel + n - 1) % n }
		if ui.key_press(.Page_Down) { app.palette_sel = min(app.palette_sel + ROWS, n - 1) }
		if ui.key_press(.Page_Up) { app.palette_sel = max(app.palette_sel - ROWS, 0) }
		app.palette_sel = clamp(app.palette_sel, 0, n - 1)
		if app.palette_sel < app.palette_scroll { app.palette_scroll = app.palette_sel }
		if app.palette_sel >= app.palette_scroll + ROWS { app.palette_scroll = app.palette_sel - ROWS + 1 }
	}
	mouse := ui.mouse_pos()
	moved := abs(mouse.x - app.palette_mouse.x) + abs(mouse.y - app.palette_mouse.y) > 0.5
	app.palette_mouse = mouse
	run := -1

	if ui.modal("palette", pw, &app.palette_open, 0.11) {
		if ui.style({width = ui.px(pw)}) {
			ui.next({width = ui.px(pw), height = ui.px(em * 3.4)})
			if ui.row(.Center, id = "###pal_head") {
				ui.spacer(ui.px(em * 0.9))
				input_key := ui.key_from_string(ui.parent_box().key, "###pal_input")
				ui.next({width = ui.fill(), height = ui.px(em * 2.4)})
				field_ui := ui.line_edit("###pal_input", &app.palette_field, "Type a command...")
				if field_ui.changed { app.palette_sel, app.palette_scroll = 0, 0 }
				if field_ui.committed && n > 0 { run = int(entries[app.palette_sel].cmd) }
				if app.palette_focus { ui.set_focus(input_key); app.palette_focus = false }
				ui.spacer(ui.px(em * 0.9))
			}
			ui.hline(ui.px(pw))
			ui.spacer(ui.px(em * 0.4))
			for vi in 0 ..< min(n, ROWS) {
				hi := app.palette_scroll + vi
				e := entries[hi]
				info := command_info[e.cmd]
				selected := hi == app.palette_sel
				if selected { ui.push_tags("selected") }
				ui.next({width = ui.px(pw - em * 1.2), height = ui.px(em * 2.6), radius = em * 0.5})
				row_sig: ui.Signal
				row_flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects}
				if selected { row_flags += {.Draw_Background} }
				if ui.row(.Center, row_flags, fmt.tprintf("###pal_row_%d", int(e.cmd))) {
					row_sig = ui.signal(ui.parent_box())
					ui.spacer(ui.px(em * 0.5))
					if ui.tags("weak") { ui.icon(info.icon, em * 1.9) }
					ui.next({width = ui.fill(), height = ui.pct(1)})
					ui.label_fuzzy(info.title, e.ranges)
					if ui.tags("weak") {
						ui.next({width = ui.text_size(em * 0.5), height = ui.pct(1), font_size = math.round(em * 0.85)})
						ui.label(info.category)
					}
					if info.shortcut != "" { ui.spacer(ui.px(em * 0.6)); ui.kbd(info.shortcut) }
					ui.spacer(ui.px(em * 0.6))
				}
				if selected { ui.pop_tags() }
				if row_sig.clicked { run = int(e.cmd) }
				if row_sig.hovering && moved { app.palette_sel = hi }
			}
			if n == 0 {
				if ui.tags("weak") {
					ui.next({width = ui.px(pw), height = ui.px(em * 4), text_align = .Center})
					ui.label("No matching commands")
				}
			}
			ui.spacer(ui.px(em * 0.4))
			ui.hline(ui.px(pw))
			ui.next({width = ui.px(pw), height = ui.px(em * 2.3)})
			if ui.row(.Center, id = "###pal_foot") {
				ui.spacer(ui.px(em))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.82)})
					ui.label(fmt.tprintf("%d of %d commands   |   Up/Down select   Enter run   Esc close", n, len(Command)))
				}
			}
		}
	}
	if run >= 0 { app.palette_open = false; run_cmd(app, Command(run)) }
}

build_confirm :: proc(app: ^App) {
	em := ui.font_size()
	w := min(em * 30, f32(app.win.size.x) / app.win.dpi_scale * 0.9)
	if ui.modal("confirm", w, &app.modal_open) {
		if ui.style({width = ui.px(w)}) {
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.px(w), height = ui.px(em * 2.4)})
			if ui.row(.Center, id = "###cf_title") {
				ui.spacer(ui.px(em * 1.4))
				if ui.tags("bad") { ui.icon(ui.ICON_WARN_BIG, em * 2.2) }
				ui.next({width = ui.fill(), height = ui.pct(1)})
				if ui.style({font_size = math.round(em * 1.25)}) { ui.label("Delete everything?") }
			}
			if ui.tags("weak") {
				for line in ([]string{"This is a demo dialog: a modal floating panel,", "a scrim that eats clicks, Esc to dismiss."}) {
					ui.next({width = ui.px(w - em * 2.8), height = ui.px(em * 1.7), text_align = .Left})
					ui.label(line)
				}
			}
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.px(w), height = ui.px(em * 2.6)})
			if ui.row(.Center, id = "###cf_btns") {
				ui.spacer(ui.fill())
				if ui.button_icon("Cancel###cf_cancel", "", "Cancel").clicked { app.modal_open = false; ui.toast(.Info, "Cancelled") }
				ui.spacer(ui.px(em * 0.6))
				if ui.tags("danger_button") {
					if ui.button_icon("Delete###cf_ok", ICON_TRASH, "Delete").clicked { app.modal_open = false; ui.toast(.Bad, "Deleted... nothing, it's a demo") }
				}
				ui.spacer(ui.px(em * 1.4))
			}
			ui.spacer(ui.px(em * 1.2))
		}
	}
}

////////////////////////////////
// About dialog

Logo_Draw :: struct { angle: f32, accent, track, text, frame: draw.Color }

// the app logo, drawn live: rounded frame + the spinner (it turns while the dialog is open)
logo_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Logo_Draw)(user)
	r := b.rect
	w := r.max.x - r.min.x
	draw.rect(dc, r, d.frame, w * 0.25)
	inner := Spin_Draw{angle = d.angle, accent = d.accent, track = d.frame, text = d.text}
	spinner_draw(b, &inner, dc)
}

build_about :: proc(app: ^App) {
	em := ui.font_size()
	w := min(em * 32, f32(app.win.size.x) * 0.9)
	pad := em * 1.6
	inner := w - 2 * pad
	if ui.modal("about", w, &app.about_open, 0.16) {
		if ui.style({width = ui.px(w)}) {
			ui.spacer(ui.px(em * 1.6))
			// header: logo + name + tagline
			ui.next({width = ui.px(w), height = ui.px(em * 5.2)})
			if ui.row(.Center, id = "###ab_head") {
				ui.spacer(ui.px(pad))
				d := ui.frame_new(Logo_Draw)
				// time-driven: only when animations are on (otherwise it would jump on every mouse event)
				d.angle = animations_enabled(app) ? f32(math.mod(ui.now_ms() / 1000 * 0.15, 1)) : 0.08
				d.accent, d.track, d.text = ui.color("accent"), ui.color("track"), ui.color("text")
				d.frame = draw.hex(0x121212ff)   // same look as the project logo: dark rounded square, spinner on top
				d.text = draw.hex(0xf0f0f0ff)
				ui.next({width = ui.px(em * 5.2), height = ui.px(em * 5.2)})
				ui.custom("logo", logo_draw, d)
				if animations_enabled(app) { app.frames_requested = max(app.frames_requested, 2) }
				ui.spacer(ui.px(em * 1.2))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###ab_title") {
					if ui.style({font_size = math.round(em * 1.5)}) {
						ui.next({width = ui.fill(), height = ui.px(em * 2.2)})
						ui.label("gui_toolkit fidget")
					}
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(em * 1.6)})
						ui.label("A widget gallery for gui_toolkit")
					}
				}
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(em * 1.0))
			ui.next({width = ui.px(w), height = ui.px(1)})
			if ui.row(id = "###ab_line") { ui.spacer(ui.px(pad)); ui.hline(ui.px(inner)) }
			ui.spacer(ui.px(em * 0.6))

			// facts: label / value pairs
			Fact :: struct { k, v: string }
			facts := [?]Fact{
				{"Toolkit", fmt.tprintf("gui_toolkit %s (Odin, immediate-mode UI)", ui.VERSION)},
				{"Renderer", "Direct3D 11, SDF rects + glyph atlas"},
				{"Compiler", fmt.tprintf("Odin %s", ODIN_VERSION)},
				{"Display", fmt.tprintf("%dx%d px, scale %.2f, zoom %d%%", app.win.size.x, app.win.size.y, app.win.dpi_scale, int(math.round(ui.zoom(&app.ui_state) * 100)))},
				{"Theme", palettes[app.palette_idx].name},
				{"Animations", app.anim_mode == .System ? fmt.tprintf("system (%s)", animations_enabled(app) ? "on" : "off") : (app.anim_mode == .On ? "always on" : "always off")},
				{"Frame", fmt.tprintf("%.2f ms to build and draw", app.ui_ms)},
				{"License", "MIT, design after the RAD Debugger UI"},
			}
			for f in facts {
				ui.next({width = ui.px(w), height = ui.px(em * 1.9)})
				if ui.row(.Center, id = fmt.tprintf("###ab_%s", f.k)) {
					ui.spacer(ui.px(pad))
					if ui.tags("weak") {
						ui.next({width = ui.px(em * 7), height = ui.pct(1)})
						ui.label(f.k)
					}
					ui.next({width = ui.px(inner - em * 7), height = ui.pct(1)})
					ui.label(f.v)
				}
			}
			ui.spacer(ui.px(em * 1.0))

			// actions
			ui.next({width = ui.px(w), height = ui.px(em * 2.6)})
			if ui.row(.Center, id = "###ab_btns") {
				ui.spacer(ui.px(pad))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.85)})
					ui.label("Esc or a click outside closes")
				}
				if ui.button_icon("###ab_copy", ICON_CLIPBOARD, "Copy info").clicked {
					sb := strings.builder_make(context.temp_allocator)
					for f in facts { fmt.sbprintf(&sb, "%s: %s\n", f.k, f.v) }
					platform.set_clipboard(app.win, strings.to_string(sb))
					ui.toast(.Good, "Copied to the clipboard")
				}
				ui.spacer(ui.px(em * 0.6))
				if ui.tags("accent_button") {
					if ui.button_icon("###ab_close", "", "Close").clicked { app.about_open = false }
				}
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(em * 1.4))
		}
	}
}