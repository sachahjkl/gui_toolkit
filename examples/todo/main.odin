// gui_toolkit example: a todo app (the Odin counterpart of apps/todo in gui_fidget).
package todo

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "../../src/devtools"
import "../../src/draw"
import "../../src/font"
import "../../src/host"
import "../../src/platform"
import "../../src/ui"

Filter :: enum { All, Active, Done }

Task :: struct {
	id:    int,
	title: string,
	done:  bool,
}

App :: struct {
	devtools: ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven with the Chrome DevTools Protocol
	shared:   host.Shared,        // the device, the fonts (shared.font: the interface's), the theme
	main:     host.Host,          // the window, its interface (main.state), its frames
	icons:    font.Font_Id,

	tasks:     [dynamic]Task,
	next_id:   int,
	input:     ui.Text_Field,
	search:    ui.Text_Field,
	filter:    Filter,
	dark:      bool,
	dirty:     bool,
	menu_task: int,
	saved_zoom: f32,

	stats_boxes:      int,
	data_in: string,   // Open_Options.data_dir
}

the_app: ^App

// Icon font characters (same icons.ttf as raddebugger)
ICON_TRASH :: "3"
ICON_PALETTE :: "E"
ICON_X :: "x"

data_dir :: proc() -> string {
	if the_app.data_in != "" { return the_app.data_in }
	return platform.user_dir(.Config, "gui_toolkit_todo", context.temp_allocator)
}

save :: proc(app: ^App) {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "#theme\t%d\n", app.dark ? 1 : 0)
	fmt.sbprintf(&sb, "#zoom\t%.3f\n", ui.zoom(&app.main.state))
	app.saved_zoom = ui.zoom(&app.main.state)
	for t in app.tasks { fmt.sbprintf(&sb, "%d\t%s\n", t.done ? 1 : 0, t.title) }
	dir := data_dir()
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/todos.tsv", dir), transmute([]byte)strings.to_string(sb))
	app.dirty = false
}

add_task :: proc(app: ^App, title: string, done := false) {
	append(&app.tasks, Task{id = app.next_id, title = strings.clone(title), done = done})
	app.next_id += 1
	app.dirty = true
}

load :: proc(app: ^App) {
	data, err := os.read_entire_file(fmt.tprintf("%s/todos.tsv", data_dir()), context.temp_allocator)
	if err != nil {
		for t in ([?]string{"Read the raddebugger UI core", "Port the box tree to Odin", "Ship gui_toolkit"}) { add_task(app, t) }
		app.tasks[0].done = true
		return
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "#theme\t") { app.dark = strings.has_suffix(line, "1"); continue }
		if strings.has_prefix(line, "#zoom\t") {
			if z, ok := strconv.parse_f32(line[6:]); ok { ui.set_zoom(&app.main.state, z) }
			continue
		}
		if i := strings.index_byte(line, '\t'); i > 0 { add_task(app, line[i + 1:], line[:i] == "1") }
	}
}

////////////////////////////////
// UI

Progress_Draw :: struct { t: f32, track, fill: draw.Color }

progress_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Progress_Draw)(user)
	r := b.rect
	h := r.max.y - r.min.y
	draw.rect(dc, r, d.track, ui.rad(h * 0.5))
	if d.t > 0.001 {
		w := max(h, (r.max.x - r.min.x) * d.t)
		draw.rect(dc, {r.min, {r.min.x + w, r.max.y}}, d.fill, ui.rad(h * 0.5))
	}
}

matches :: proc(t: Task, filter: Filter, query: string) -> bool {
	switch filter {
	case .All:
	case .Active: if t.done { return false }
	case .Done:   if !t.done { return false }
	}
	return query == "" || strings.contains(strings.to_lower(t.title, context.temp_allocator), strings.to_lower(query, context.temp_allocator))
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	total, done := len(app.tasks), 0
	for t in app.tasks { if t.done { done += 1 } }

	if ui.style({width = ui.fill(), height = ui.fill(), radius = em * 0.45}) {
		ui.next({axis = .Y, radius = 0})   // touches the window edges: square
		page := ui.build_box({.Draw_Background}, "###page")
		if ui.parent(page) {
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.row() {
				ui.spacer(ui.px(em * 2))
				ui.next({width = ui.fill(), height = ui.fill()})
				if ui.column() {
					ui.spacer(ui.px(em * 1.6))
					build_header(app, em, done, total)
					ui.spacer(ui.px(em * 0.8))
					build_input_row(app, em)
					ui.spacer(ui.px(em * 0.8))
					build_filters(app, em, total, done)
					ui.spacer(ui.px(em * 0.8))
					build_list(app, em)
					ui.spacer(ui.px(em * 0.6))
					build_footer(app, em, total, done)
					ui.spacer(ui.px(em * 1.0))
				}
				ui.spacer(ui.px(em * 2))
			}
		}

		// context menu for a task row
		menu_key := ui.key_from_string(0, "task_menu")
		if ui.ctx_menu(menu_key, em * 14) {
			idx := -1
			for t, i in app.tasks { if t.id == app.menu_task { idx = i } }
			if idx >= 0 {
				if ui.menu_item(app.tasks[idx].done ? "Mark as active" : "Mark as done", "", false).clicked { app.tasks[idx].done = !app.tasks[idx].done; app.dirty = true }
				if ui.menu_item("Delete", "Del", false, ICON_TRASH).clicked { ordered_remove(&app.tasks, idx); app.dirty = true }
			}
		}
	}
}

build_header :: proc(app: ^App, em: f32, done, total: int) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3))})
	if ui.row(.Center) {
		ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2.4))})
		if ui.style({font_size = math.round(em * 1.7)}) { ui.label("Tasks") }
		ui.spacer(ui.fill())
		ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.4)})
		sig := ui.icon_button("toggle_theme", ICON_PALETTE)
		if sig.clicked { app.dark = !app.dark; app.dirty = true }
		if ui.hovered_for(sig) {
			if ui.tooltip() {
				ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 2))})
				ui.label("Toggle light / dark")
			}
		}
	}
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.4))})
	if ui.tags("weak") {
		ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 1.4))})
		ui.label(fmt.tprintf("%d of %d done", done, total))
	}
	ui.spacer(ui.px(em * 0.3))
	d := ui.frame_new(Progress_Draw)
	d.t = ui.anim(ui.key_from_string(0, "progress"), total > 0 ? f32(done) / f32(total) : 0, 24)
	d.track = ui.color("track")
	d.fill = ui.color("accent")
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 0.5))})
	ui.custom("progress_bar", progress_draw, d)
}

build_input_row :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
	if ui.row(.Center) {
		input_key := ui.key_from_string(ui.parent_box().key, "###new_task")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
		res := ui.line_edit("###new_task", &app.input, "What needs doing?")
		submit := res.committed
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("accent_button") {
			ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.6))})
			if ui.button("Add###add").clicked { submit = true }
		}
		if submit && len(app.input.buf) > 0 {
			add_task(app, ui.field_string(&app.input))
			ui.field_clear(&app.input)
			ui.set_focus(input_key)   // keep typing after pressing the Add button
		}
	}
}

build_filters :: proc(app: ^App, em: f32, total, done: int) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		names := [Filter]string{.All = "All", .Active = "Active", .Done = "Done"}
		counts := [Filter]int{.All = total, .Active = total - done, .Done = done}
		for f in Filter {
			selected := app.filter == f
			if selected { ui.push_tags("accent_button") }
			ui.next({width = ui.text_size(em * 1.0), height = ui.px(ui.dense(em * 2.2))})
			if ui.button(fmt.tprintf("%s %d###filter_%d", names[f], counts[f], int(f))).clicked { app.filter = f }
			if selected { ui.pop_tags() }
			ui.spacer(ui.px(em * 0.4))
		}
		ui.spacer(ui.fill())
		ui.next({width = ui.px(em * 11, 0), height = ui.px(em * 2.2)})   // strictness 0: shrinks when the window (or zoom) leaves no room
		ui.line_edit("###search", &app.search, "Search")
	}
}

build_list :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill()})
	menu_key := ui.key_from_string(0, "task_menu")
	if ui.scroll_y("###list") {
		query := ui.field_string(&app.search)
		shown := 0
		remove_id := -1
		for &t in app.tasks {
			if !matches(t, app.filter, query) { continue }
			shown += 1
			if ui.tags("card") {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3)), radius = em * 0.6})
				if ui.row(.Center, {.Draw_Background, .Draw_Border}, fmt.tprintf("###task_%d", t.id)) {
					ui.spacer(ui.px(em * 0.8))
					dim := t.done   // the checkbox toggles t.done: remember what we pushed
					if dim { ui.push_tags("weak") }
					ui.next({width = ui.fill(), height = ui.pct(1)})
					sig := ui.checkbox(fmt.tprintf("###chk_%d", t.id), t.title, &t.done)
					if dim { ui.pop_tags() }
					if sig.clicked { app.dirty = true }
					if sig.right_clicked { app.menu_task = t.id; ui.ctx_menu_open(menu_key, ui.mouse_pos()) }
					ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2)})
					del := ui.icon_button(fmt.tprintf("del_%d", t.id), ICON_TRASH)
					if del.clicked { remove_id = t.id }
					if ui.hovered_for(del) {
						if ui.tooltip() {
							ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 2))})
							ui.label("Delete task")
						}
					}
					ui.spacer(ui.px(em * 0.5))
				}
			}
			ui.spacer(ui.px(em * 0.5))
		}
		if shown == 0 {
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 6))})
				if ui.style({text_align = .Center}) { ui.label(app.tasks == nil || len(app.tasks) == 0 ? "Nothing here yet. Add a task above." : "No task matches.") }
			}
		}
		if remove_id >= 0 {
			for t, i in app.tasks { if t.id == remove_id { delete(t.title); ordered_remove(&app.tasks, i); break } }
			app.dirty = true
		}
	}
}

build_footer :: proc(app: ^App, em: f32, total, done: int) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		if ui.tags("weak") {
			ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
			ui.label(fmt.tprintf("%d left", total - done))
		}
		ui.spacer(ui.fill())
		if done > 0 {
			ui.next({width = ui.text_size(em * 1.0), height = ui.px(ui.dense(em * 2.2))})
			if ui.button("Clear completed###clear").clicked {
				for i := len(app.tasks) - 1; i >= 0; i -= 1 { if app.tasks[i].done { delete(app.tasks[i].title); ordered_remove(&app.tasks, i) } }
				app.dirty = true
			}
		}
	}
}

////////////////////////////////
// Frames (host: the window, its interface, its frames)

// One frame of the window: what a test calls, as the loop does.
frame :: proc(app: ^App) { host.host_frame(&app.main) }

@(private = "file")
todo_build :: proc(h: ^host.Host, size: host.Vec2) { build_ui((^App)(h.user)) }

// The base style is in LOGICAL pixels: the toolkit multiplies it by dpi scale * zoom (Ctrl+wheel, Ctrl +/-/0).
@(private = "file")
todo_params :: proc(h: ^host.Host, p: ^ui.Build_Params) {
	app := (^App)(h.user)
	ui.apply_palette(&app.shared.theme, app.dark ? ui.palette_of("Midnight") : ui.palette_of("Midnight", light = true))
	platform.set_dark_title(h.win, app.dark)
	p.base = ui.Style{
		pref = {.X = ui.text_size(), .Y = ui.px(36)},
		font = app.shared.font, font_size = 15, text_pad = 7,
		cursor = .Arrow,
	}
}

@(private = "file")
todo_after_build :: proc(h: ^host.Host) {
	app := (^App)(h.user)
	if ui.needs_frame(&h.state) { h.settle = max(h.settle, 2) }
	if ui.zoom(&h.state) != app.saved_zoom { app.dirty = true }
	if app.dirty { save(app) }
}

// What `open` starts from.
Open_Options :: struct {
	headless: bool,     // no window of the system: offscreen, on the software renderer, with the font compiled in
	data_dir: string,   // where todos.tsv is ("": the user's folder)
}

WINDOW_SIZE :: [2]int{640, 860}

// The application, up to its first frame (the caller makes the frames: `frame`). nil: it cannot start, and has said why.
open :: proc(o: Open_Options) -> ^App {
	app := new(App)
	the_app = app
	app.data_in = o.data_dir
	app.dark = true
	if !host.host_open(&app.main, &app.shared, {title = "gui_toolkit todo", size = WINDOW_SIZE, headless = o.headless}, todo_build, app) {
		the_app = nil
		free(app)
		return nil
	}
	ok: bool
	app.icons, ok = font.load_embedded(&app.shared.fonts, ui.ICON_FONT_DATA)
	if !ok { fmt.eprintln("cannot load the icon font"); close(app); return nil }
	h := &app.main
	h.state.icon_font = app.icons
	h.background = {0, 0, 0, 1}
	h.after_input = 4
	h.settle = 4
	h.params = todo_params
	h.after_build = todo_after_build
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }
	load(app)
	app.saved_zoom = ui.zoom(&h.state)
	app.devtools = devtools.start_from_env(h.win, "gui_toolkit todo")
	return app
}

// The end of what `open` made.
close :: proc(app: ^App) {
	devtools.stop(app.devtools)
	for t in app.tasks { delete(t.title) }
	delete(app.tasks)
	ui.field_destroy(&app.input)
	ui.field_destroy(&app.search)
	host.host_close(&app.main)
	the_app = nil
	free(app)
}

main :: proc() {
	app := open({})
	if app == nil { return }
	defer close(app)
	platform.show_window(app.main.win)
	for !platform.is_closed(app.main.win) {
		host.hosts_wait({&app.main})
		frame(app)
	}
}
