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
import "../../src/host"
import "../../src/platform"
import "../../src/ui"

App :: struct {
	shared: host.Shared,   // the device, the fonts, the theme
	main:   host.Host,     // the window, its interface, its frames
	name:   ui.Text_Field,
	clicks: int,
}

// The interface, built again each frame: the state that must last (the field's text, the clicks) is the app's.
build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
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

main :: proc() {
	frames := -1   // --frames=N: N frames of a hidden window, then exit
	for a in os.args[1:] {
		if strings.has_prefix(a, "--frames=") { frames, _ = strconv.parse_int(a[len("--frames="):]) }
	}
	app := new(App)
	defer free(app)
	// a composition surface whose buffers keep the screen's size while the window is resized: a frame of the old size is
	// clipped by the window, never stretched over the new one; frames from inside the system's loops (live resize, a menu)
	if !host.host_open(&app.main, &app.shared, {title = "Hello, gui_toolkit", size = {640, 400}}, build, app) { os.exit(1) }
	defer host.host_close(&app.main)
	defer ui.field_destroy(&app.name)
	app.main.background = ui.theme_lookup(&app.shared.theme, {}, "background")   // the palette's window colour
	platform.set_dark_title(app.main.win, true)

	if frames >= 0 {
		for _ in 0 ..< frames { host.host_frame(&app.main) }
		fmt.printfln("hello: %d frames, %d boxes", frames, app.main.state.boxes_built)
		return
	}
	platform.show_window(app.main.win)
	for !platform.is_closed(app.main.win) {
		// 0 % CPU at rest: sleep until input, or until the interface's next timed wake (caret blink, tooltip)
		host.hosts_wait({&app.main})
		host.host_frame(&app.main)
	}
}
