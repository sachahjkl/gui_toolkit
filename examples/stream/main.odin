// A thread that reads a stream (server-sent events, simulated) and hands each line to the interface with ui.post: no
// lock nor queue of the app's own. The window sleeps between lines (0 % CPU) and wakes for each batch.
//   build.bat stream
package stream

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:thread"
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
	lines:    [dynamic]string,
	received: int,
	last_tick: time.Tick,
	frames_requested: int,
	// the worker's controls (atomics: it reads them on its thread)
	stop, paused: bool,
	burst:    i32,
	worker:   ^thread.Thread,
}

KEEP_LINES :: 2000

// Runs on the interface's thread (begin_build): the line is the app's from here.
on_line :: proc(data: rawptr, word: u64) {
	app := the_app
	line := strings.string_from_ptr((^u8)(data), int(word))
	app.received += 1
	append(&app.lines, line)
	if len(app.lines) > KEEP_LINES {
		delete(app.lines[0])
		ordered_remove(&app.lines, 0)
	}
}

// A line that will never run (the window closed first): its text is freed.
on_drop :: proc(data: rawptr, word: u64) { free(data) }

the_app: ^App

worker_proc :: proc(t: ^thread.Thread) {
	app := (^App)(t.data)
	n := 0
	for !sync.atomic_load(&app.stop) {
		count := 1
		if b := sync.atomic_exchange(&app.burst, 0); b > 0 { count = int(b) }
		if sync.atomic_load(&app.paused) && count == 1 { time.sleep(50 * time.Millisecond); continue }
		for _ in 0 ..< count {
			n += 1
			line := fmt.aprintf("data: {{\"id\": %d, \"delta\": \"token %d\"}}", n, rand.int_max(100000))
			// Block (the default): a full ring makes this thread wait for the interface, no line is lost
			if !ui.post(&app.ui_state, on_line, raw_data(line), u64(len(line))) { delete(line); return }
		}
		time.sleep(time.Duration(30 + rand.int_max(90)) * time.Millisecond)
	}
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(em * 2.6)})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.text_size(), height = ui.px(em * 2)})
		ui.label(fmt.tprintf("%d lines received, %d calls run, %d waits###count", app.received, ui.post_stats(&app.ui_state).run, ui.post_stats(&app.ui_state).blocked))
		ui.spacer(ui.fill())
		paused := sync.atomic_load(&app.paused)
		ui.next({width = ui.text_size(em), height = ui.px(em * 2)})
		if ui.button(paused ? "Resume###pause" : "Pause###pause").clicked { sync.atomic_store(&app.paused, !paused) }
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.text_size(em), height = ui.px(em * 2)})
		if ui.button("Burst of 20000###burst").clicked { sync.atomic_store(&app.burst, 20000) }
		ui.spacer(ui.px(em * 0.6))
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("lines") {
		// the newest lines (a long log would use ui.vlist)
		from := max(0, len(app.lines) - 200)
		for line, i in app.lines[from:] {
			ui.next({width = ui.fill(), height = ui.px(em * 1.5)})
			ui.label(fmt.tprintf("%s###l%d", line, from + i))
		}
	}
}

frame :: proc(app: ^App) {
	render.wait_for_frame(&app.r)
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
	// begin_build runs the lines posted since the last frame, and wakes on the next ones (window = app.win)
	ui.begin_build(&app.ui_state, {window_size = size, events = events, dt = dt, animations = platform.os_animations_enabled(), dpi_scale = app.win.dpi_scale, base = base, window = app.win})
	build_ui(app)
	ui.end_build()
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r)
	free_all(context.temp_allocator)
}

main :: proc() {
	app := new(App)
	the_app = app
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit stream", {720, 560})
	if !render.init_window(&app.r, app.win, app.win.size) { fmt.eprintln("renderer init failed"); return }
	ok: bool
	app.ui_font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("cannot load a UI font"); return }
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	ui.post_configure(&app.ui_state, capacity = 256, overflow = .Block, per_build = 1000, on_drop = on_drop)
	app.last_tick = time.tick_now()
	app.frames_requested = 2
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)

	app.worker = thread.create(worker_proc)
	app.worker.data = app
	thread.start(app.worker)

	for !platform.is_closed(app.win) {
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) { platform.wait_event(app.win, ui.wake_in_ms(&app.ui_state)) }
		frame(app)
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}

	// the worker may wait on a full ring: closing the queue releases it (its post returns false), then it is joined;
	// ui.destroy frees the lines never run (on_drop)
	sync.atomic_store(&app.stop, true)
	ui.post_close(&app.ui_state)
	thread.join(app.worker)
	thread.destroy(app.worker)
	ui.destroy(&app.ui_state)
	for l in app.lines { delete(l) }
	delete(app.lines)
	draw.destroy(&app.dc)
	render.destroy(&app.r)
	font.destroy(&app.fonts)
	ui.theme_destroy(&app.theme)
	platform.destroy_window(app.win)
	free(app)
}
