package film_tool

import "core:fmt"
import "core:os"
import "core:time"
import runtime_app "../../apps/gt-runtime/app"
import "gt:film"
import "gt:platform"
import "gt:ui"

// The todo list of examples/js, run by gt-runtime: a plugin in JavaScript as an application. Its plugin's process is
// this tool's executable started again (gt:plugins' @(init)), as a program's would be.
@(private = "file") RUNTIME_PLUGIN :: "examples/js/todo"
// The longest wait for the plugin's first view: its process starts, reads its start, renders.
@(private = "file") RUNTIME_READY :: 10 * time.Second

shoot_runtime :: proc(path: string) -> string {
	// (the film's own folders: it never reads nor writes the person's settings, plugins.toml or logs)
	dirs := fmt.tprintf("build/films/runtime-profile-%d", os.get_pid())
	_ = os.remove_all(dirs)
	defer os.remove_all(dirs)
	app := runtime_app.open({path = RUNTIME_PLUGIN, headless = true, gpu = true, dirs = dirs})
	if app == nil { return "gt-runtime does not open" }
	defer runtime_app.close(app)
	platform.set_offscreen_dpi(app.main.win, DPI_STAGED)
	// (the plugin's view comes from its process: frames until its field is built, with a bound)
	began := time.tick_now()
	for ui.box_find(&app.main.state, "pv:draft") == nil {
		if time.tick_since(began) > RUNTIME_READY { return "the plugin's view did not come" }
		runtime_app.frame(app)
		time.sleep(5 * time.Millisecond)
	}
	for _ in 0 ..< 4 { runtime_app.frame(app) }

	card := card_open()
	if card == nil { return "the title card does not open" }
	defer card_close(card)
	rec: film.Recorder
	if why := film.start(&rec, card_app(card), {out = path, size = FILM_SIZE}); why != "" { return why }
	shown := film.App{win = app.main.win, state = &app.main.state, renderer = &app.shared.r, user = app,
		frame = proc(user: rawptr) { runtime_app.frame((^runtime_app.App)(user)) }}

	card_show(card, "gt-runtime", "A plugin in JavaScript, run as an application", "examples/js/todo: its view is the toolkit's widgets")
	film.switch_to(&rec, card_app(card))
	film.hold(&rec, 2.6)
	film.switch_to(&rec, shown)
	film.fade(&rec, 0.7)
	film.pointer_show(&rec, true, {200, 520})
	film.hold(&rec, 0.4)

	// two tasks: one by Enter, one by its button
	runtime_tap(&rec, "pv:draft")
	film.type_text(&rec, "Film the runtime")
	film.hold(&rec, 0.3)
	film.key(&rec, .Return, after = 0.6)
	runtime_tap(&rec, "pv:draft")
	film.type_text(&rec, "Post the film")
	film.hold(&rec, 0.3)
	runtime_tap(&rec, "pv:add", after = 0.7)
	// done, one after the other: the count follows
	runtime_tap(&rec, "pv:done-2", after = 0.5)
	runtime_tap(&rec, "pv:done-3", after = 0.8)
	// the plugin's own command, from the palette: its toast says what it did
	film.key(&rec, .K, {.Ctrl}, after = 0.5)
	film.type_text(&rec, "clear")
	film.hold(&rec, 0.5)
	film.key(&rec, .Return, after = 2.2)

	film.pointer_show(&rec, false)
	card_show(card, "", "gui_toolkit", "gt.sacha.house")
	film.switch_to(&rec, card_app(card))
	film.fade(&rec, 0.7)
	film.hold(&rec, 2.4)
	return film.finish(&rec)
}

// The pointer glides to the box and clicks it; a word on standard error when it is not there (the film goes on).
@(private = "file")
runtime_tap :: proc(rec: ^film.Recorder, name: string, after := 0.4) {
	b := film.box(rec, name)
	if b == nil {
		fmt.eprintfln("film runtime: no box %q to click", name)
		return
	}
	film.move_to(rec, film.center(b), 0.55)
	film.hold(rec, 0.08)
	film.click(rec)
	film.hold(rec, after)
}
