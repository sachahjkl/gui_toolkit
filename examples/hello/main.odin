// The smallest application of the toolkit: a window, a label, a text field and a button that counts its clicks.
// docs/getting-started.md walks through it.
//   odin build examples/hello -vet -out:build/hello.exe -subsystem:windows
//   build\hello.exe                 the window
//   build\hello.exe --frames=3      three frames without showing the window, then exit (a check that it runs)
package hello

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

App :: struct {
	win:    ^platform.Window,
	r:      render.Renderer,
	fonts:  font.State,
	dc:     draw.Context,
	theme:  ui.Theme,
	s:      ui.State,
	font:   font.Font_Id,
	name:   ui.Text_Field,
	clicks: int,
	pacer:  render.Pacer,   // frame pacing (render/pacer.odin)
	slept:  bool,           // the loop slept before this frame
}

// The interface, built again each frame: the state that must last (the field's text, the clicks) is the app's.
build :: proc(app: ^App) {
	em := ui.font_size()
	ui.spacer(ui.px(em))
	ui.next({width = ui.fill()})
	if ui.row() {
		ui.spacer(ui.px(em))
		build_column(app, em)
	}
}

build_column :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill()})
	if ui.column() {
		ui.label("Hello from gui_toolkit###title")
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.px(em * 16)})
		ui.line_edit("###name", &app.name, "Your name")
		ui.spacer(ui.px(em * 0.5))
		name := ui.field_string(&app.name)
		ui.label(fmt.tprintf("Hello, %s!###greeting", name if name != "" else "world"))
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("accent_button") {
			if ui.button(fmt.tprintf("Clicked %d times###count", app.clicks)).clicked { app.clicks += 1 }
		}
	}
}

the_app: ^App   // (for the clipboard procedures, which take no argument)

frame :: proc(app: ^App) {
	if ui.building() { return }   // (a frame asked for from a loop of the system while one is being built: skip it)
	at_once := render.pace_frame(&app.pacer, &app.r, app.win, idled = app.slept, dragging = ui.active_key() != 0)
	app.slept = false
	events := platform.poll_events(app.win, false)
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	ui.begin_build(&app.s, {
		window_size = size, events = events, dt = 1.0 / 60, animations = platform.os_animations_enabled(),
		dpi_scale = app.win.dpi_scale, window = app.win,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.font, font_size = 15, text_pad = 6, cursor = .Arrow},
		clipboard_get = proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) },
		clipboard_set = proc(text: string) { platform.set_clipboard(the_app.win, text) },
	})
	build(app)
	ui.end_build()
	platform.set_cursor(app.win, ui.cursor(&app.s))
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, ui.theme_lookup(&app.theme, {}, "background"))   // the palette's window colour
	ui.draw_tree(&app.s, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r, !at_once)
	render.paced_present(&app.pacer)
	free_all(context.temp_allocator)
}

main :: proc() {
	frames := -1   // --frames=N: N frames of a hidden window, then exit
	for a in os.args[1:] {
		if strings.has_prefix(a, "--frames=") { frames, _ = strconv.parse_int(a[len("--frames="):]) }
	}
	app := new(App)
	defer free(app)
	the_app = app
	font.init(&app.fonts)
	defer font.destroy(&app.fonts)
	app.win = platform.open_window("Hello, gui_toolkit", {640, 400})
	if app.win == nil { fmt.eprintln("hello: no window"); os.exit(1) }
	defer platform.destroy_window(app.win)
	if !render.init_window(&app.r, app.win, app.win.size) { fmt.eprintln("hello: no renderer"); os.exit(1) }
	defer render.destroy(&app.r)
	ok: bool
	app.font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("hello: no UI font"); os.exit(1) }
	draw.init(&app.dc, &app.r, &app.fonts)
	defer draw.destroy(&app.dc)
	ui.apply_palette(&app.theme, ui.PALETTE_MIDNIGHT)
	defer ui.theme_destroy(&app.theme)
	ui.init(&app.s, &app.fonts, &app.theme)
	defer ui.destroy(&app.s)
	defer ui.field_destroy(&app.name)
	platform.set_dark_title(app.win, true)
	// frames from inside the system's loops (live resize, a menu): WM_PAINT calls on_frame
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }

	if frames >= 0 {
		for _ in 0 ..< frames { frame(app) }
		fmt.printfln("hello: %d frames, %d boxes", frames, app.s.boxes_built)
		return
	}
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		// 0 % CPU at rest: sleep until input, or until the interface's next timed wake (caret blink, tooltip)
		if !ui.needs_frame(&app.s) { platform.wait_event(app.win, ui.wake_in_ms(&app.s)); app.slept = true }
		frame(app)
	}
}
