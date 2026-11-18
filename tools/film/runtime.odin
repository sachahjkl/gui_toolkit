package film_tool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import runtime_app "../../apps/gt-runtime/app"
import "gt:film"
import "gt:platform"
import "gt:ui"

// A plugin written, then run: examples/js/logs, a log explorer of a quarter of a million lines. The editor shows its
// main.js and its key part typed (the lazy list's row), the terminal starts gt-runtime, and gt-runtime runs it: a scroll
// through every line, a search, a line opened, a command of the plugin's from the palette. The plugin's process is this
// tool's executable started again (gt:plugins' @(init)), as a program's would be.
@(private = "file") RUNTIME_PLUGIN :: "examples/js/logs"
@(private = "file") RUNTIME_MAIN :: "examples/js/logs/main.js"
// The part of main.js the film types: the row of the lazy list, from its first line to the next function.
@(private = "file") TYPED_FROM :: "function line(i) {"
@(private = "file") TYPED_TO :: "function render() {"
// The longest wait for the plugin's first view: its process starts, makes its lines, renders.
@(private = "file") RUNTIME_READY :: 20 * time.Second

shoot_runtime :: proc(path: string) -> string {
	source, err := os.read_entire_file(RUNTIME_MAIN, context.allocator)
	if err != nil { return fmt.tprintf("%s cannot be read: %v", RUNTIME_MAIN, err) }
	defer delete(source)
	text := string(source)
	from, to := strings.index(text, TYPED_FROM), strings.index(text, TYPED_TO)
	if from < 0 || to < from { return fmt.tprintf("%s has no %q before %q", RUNTIME_MAIN, TYPED_FROM, TYPED_TO) }
	typed := text[from:to]
	// (the heap's: the frames run below empty the temporary memory before the editor opens)
	before := strings.concatenate({text[:from], text[to:]})
	defer delete(before)

	// (the film's own folders: it never reads nor writes the person's settings, plugins.toml or logs)
	dirs := fmt.tprintf("build/films/runtime-profile-%d", os.get_pid())
	_ = os.remove_all(dirs)
	defer os.remove_all(dirs)
	app := runtime_app.open({path = RUNTIME_PLUGIN, headless = true, gpu = true, dirs = dirs, size = WINDOW_LOGICAL})
	if app == nil { return "gt-runtime does not open" }
	defer runtime_app.close(app)
	platform.set_offscreen_dpi(app.main.win, DPI_STAGED)
	// (the plugin's view comes from its process: frames until its list is built, with a bound)
	began := time.tick_now()
	for ui.box_find(&app.main.state, "pv:query") == nil {
		if time.tick_since(began) > RUNTIME_READY { return "the plugin's view did not come" }
		runtime_app.frame(app)
		time.sleep(5 * time.Millisecond)
	}
	for _ in 0 ..< 8 { runtime_app.frame(app) }

	ed := editor_open(RUNTIME_MAIN, before)
	if ed == nil { return "the editor does not open" }
	defer editor_close(ed)
	card := card_open()
	if card == nil { return "the title card does not open" }
	defer card_close(card)
	rec: film.Recorder
	if why := film.start(&rec, card_app(card), {out = path, size = FILM_SIZE}); why != "" { return why }
	shown := film.App{win = app.main.win, state = &app.main.state, renderer = &app.shared.r, user = app,
		frame = proc(user: rawptr) { runtime_app.frame((^runtime_app.App)(user)) }}

	// 1. what it is
	card_show(card, "gt-runtime", "Write a plugin, run it", "A log explorer in JavaScript: 250 000 lines in a lazy list")
	film.switch_to(&rec, card_app(card))
	film.hold(&rec, 2.8)

	// 2. the code: its row typed into main.js, saved, then started from the terminal
	film.switch_to(&rec, editor_app(ed))
	film.fade(&rec, 0.7)
	film.hold(&rec, 1.2)
	editor_type(ed, editor_offset(text, TYPED_FROM), typed, per_second = 48)
	film.hold(&rec, f64(len(typed)) / 48 + 0.6)
	film.key(&rec, .S, {.Ctrl}, after = 0.1)
	ed.saved = true
	film.hold(&rec, 0.9)
	editor_command(ed, "gt-runtime examples/js/logs")
	film.hold(&rec, f64(len("gt-runtime examples/js/logs")) / 16 + 0.5)
	film.key(&rec, .Return, after = 0.3)

	// 3. the run
	film.switch_to(&rec, shown)
	film.fade(&rec, 0.6)
	film.hold(&rec, 1.4)
	list := film.box(&rec, "pv:lines")
	if list != nil {
		film.pointer_show(&rec, true, film.center(list, {0.5, 0.9}))
		film.move_to(&rec, film.center(list, {0.55, 0.5}), 0.6)
		// a fast scroll: the program asks the plugin only for the rows that come into view
		film.wheel(&rec, {0, 60}, 2.2)
		film.hold(&rec, 0.5)
		film.wheel(&rec, {0, 400}, 1.6)
		film.hold(&rec, 0.8)
	} else {
		fmt.eprintln("film runtime: no list to scroll")
		film.pointer_show(&rec, true, {300, 300})
	}
	// a search of every line, as it is typed
	runtime_tap(&rec, "pv:query", after = 0.3)
	film.type_text(&rec, "timeout", per_second = 9)
	film.hold(&rec, 1.2)
	// back to the first matches, then a line opened: the third button in view (the list builds rows past its edges too)
	if list != nil {
		film.move_to(&rec, film.center(list, {0.55, 0.5}), 0.4)
		film.wheel(&rec, {0, -400}, 0.9)
		film.hold(&rec, 0.6)
	}
	if b := open_in_view(&rec, film.box(&rec, "pv:lines"), 2); b != nil {
		film.move_to(&rec, film.center(b), 0.6)
		film.hold(&rec, 0.08)
		film.click(&rec)
		film.hold(&rec, 1.6)
	}
	// a command of the plugin's, from the palette: its toast says what it found
	film.key(&rec, .K, {.Ctrl}, after = 0.5)
	film.type_text(&rec, "only the errors", per_second = 12)
	film.hold(&rec, 0.5)
	film.key(&rec, .Return, after = 2.4)

	film.pointer_show(&rec, false)
	card_show(card, "", "gui_toolkit", "gt.sacha.house")
	film.switch_to(&rec, card_app(card))
	film.fade(&rec, 0.7)
	film.hold(&rec, 2.4)
	return film.finish(&rec)
}

// The `nth` "Open" button whose whole box is inside the list's (nil: none).
@(private = "file")
open_in_view :: proc(rec: ^film.Recorder, list: ^ui.Box, nth: int) -> ^ui.Box {
	if list == nil { return nil }
	seen := 0
	for i in 0 ..< 200 {
		b := film.box(rec, "", "Open", index = i)
		if b == nil { break }
		if b.rect.min.y < list.rect.min.y || b.rect.max.y > list.rect.max.y { continue }
		if seen == nth { return b }
		seen += 1
	}
	fmt.eprintln("film runtime: no Open button in view")
	return nil
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
