package examples_test

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "../../examples/todo"
import "../../src/draw"
import "../../src/render"
import "../../src/testkit"
import "../../src/testkit/session"
import "../../src/ui"

// examples/todo as a user meets it: a task added, its box ticked, the filters, a tooltip, the context menu, the theme, a deletion, each read back from the
// application and from the file it saves.

// Longer than a tooltip's delay (ui.FEEL_DEFAULT.tooltip_delay_ms, 500 ms).
@(private = "file") TOOLTIP_WAIT_MS :: 600
// A point of the page's background.
@(private = "file") BACKGROUND_AT :: 4

@(private = "file")
start_todo :: proc(t: ^testing.T, loc := #caller_location) -> (s: ^session.Session, app: ^todo.App) {
	dir := testkit.temp_folder(t, "todo")
	context.allocator = runtime.heap_allocator()
	app = todo.open({headless = true, data_dir = dir})
	if !testing.expect(t, app != nil, "todo opens", loc = loc) { session.stop_test(t, "no application", loc) }
	testing.cleanup(t, proc(p: rawptr) { todo.close((^todo.App)(p)) }, app)
	s = session.attach(t, {win = app.main.win, state = &app.main.state, renderer = &app.shared.r, user = app, allocator = context.allocator,
		frame = proc(user: rawptr) { todo.frame((^todo.App)(user)) }}, loc)
	session.frames(s, 2)
	return
}

@(private = "file")
saved :: proc(app: ^todo.App) -> string {
	data, err := os.read_entire_file(fmt.tprintf("%s/todos.tsv", app.data_in), context.temp_allocator)
	return err != nil ? "" : string(data)
}

@(test)
todo_add_tick_filter_delete :: proc(t: ^testing.T) {
	s, app := start_todo(t)
	first_tasks := len(app.tasks)
	session.click(s, "new_task")
	session.type_text(s, "Test the Odin port")
	session.key(s, .Return)
	testing.expect_value(t, len(app.tasks), first_tasks + 1)
	testing.expect(t, strings.contains(saved(app), "0\tTest the Odin port"), "Enter adds it, and it is saved")
	testing.expect_value(t, ui.field_string(&app.input), "")
	testing.expect_value(t, session.focused_name(s), "new_task")

	// the box of the second task
	second := fmt.tprintf("chk_%d", app.tasks[1].id)
	testing.expect(t, !app.tasks[1].done)
	session.click(s, second)
	testing.expect(t, app.tasks[1].done, "the click ticks it")
	testing.expect(t, strings.contains(saved(app), fmt.tprintf("1\t%s", app.tasks[1].title)), "and it is saved")

	// Active shows what is not done: the task just ticked goes
	session.click(s, "filter_1")
	testing.expect(t, session.find(s, second) == nil, "Active hides what is done")
	testing.expect(t, session.find(s, fmt.tprintf("chk_%d", app.tasks[2].id)) != nil, "and shows the others")
	session.click(s, "filter_0")
	testing.expect(t, session.find(s, second) != nil, "All shows it again")

	// the first task's bin
	gone := app.tasks[0].id
	count := len(app.tasks)
	session.click(s, fmt.tprintf("del_%d", gone))
	testing.expect_value(t, len(app.tasks), count - 1)
	testing.expect(t, session.find(s, fmt.tprintf("chk_%d", gone)) == nil, "the row goes")
}

@(test)
todo_tooltip_context_menu_and_theme :: proc(t: ^testing.T) {
	s, app := start_todo(t)
	row := app.tasks[1].id
	session.hover(s, fmt.tprintf("del_%d", row))
	testing.expect(t, session.find_text(s, "Delete task") == nil, "not yet")
	session.advance(s, TOOLTIP_WAIT_MS)
	testing.expect(t, session.find_text(s, "Delete task") != nil, "the tooltip, after its delay")

	session.click(s, fmt.tprintf("chk_%d", row), .Right)
	testing.expect(t, ui.ctx_menu_any_open(), "the right button opens the menu")
	testing.expect_value(t, app.menu_task, row)
	testing.expect(t, session.find_text(s, "Mark as done") != nil, "with what it can do")
	session.key(s, .Escape)
	testing.expect(t, !ui.ctx_menu_any_open(), "Esc closes it")

	bg_dark := session.pixel(session.capture(s), BACKGROUND_AT, BACKGROUND_AT)
	session.click(s, "toggle_theme")
	session.wait_idle(s)
	testing.expect(t, !app.dark, "the theme turns")
	testing.expect(t, strings.contains(saved(app), "#theme\t0"), "and it is saved")
	testing.expect(t, !session.near(session.pixel(session.capture(s), BACKGROUND_AT, BACKGROUND_AT), bg_dark), "and the page changes colour")
}

// Frames of a measure: how many had a region, the largest and the total of their pixels.
@(private = "file")
Damage_Run :: struct { frames, partial, most, total: int }

@(private = "file")
damage_run :: proc(s: ^session.Session, app: ^todo.App, n: int) -> (run: Damage_Run) {
	for _ in 0 ..< n {
		session.frame(s)
		_, _, px, _, active := draw.damage_stats(&app.shared.dc)
		run.frames += 1
		if active { run.partial += 1 }
		run.most = max(run.most, px)
		run.total += px
	}
	return
}

// What partial redraw takes on a whole application (Host.partial_redraw): every frame of a session is drawn whole on the side and
// must be the same (draw.set_damage_verify), an idle frame redraws nothing, a hover and a caret a small part of the window.
@(test)
todo_partial_redraw_is_exact_and_small :: proc(t: ^testing.T) {
	IDLE_FRAMES :: 30
	WATCH_FRAMES :: 90
	s, app := start_todo(t)
	app.main.partial_redraw = true
	draw.set_damage_verify(&app.shared.dc, true)
	window := app.main.win.size.x * app.main.win.size.y
	session.wait_idle(s)
	idle := damage_run(s, app, IDLE_FRAMES)
	testing.expectf(t, idle.total == 0 && idle.partial == IDLE_FRAMES, "idle frames redraw nothing: %v", idle)

	session.event(s, {kind = .Mouse_Move, pos = session.center(session.get(s, "toggle_theme"))})
	hover := damage_run(s, app, WATCH_FRAMES)
	testing.expectf(t, hover.most > 0 && hover.most < window / 10, "a hover redraws a little: %v of %d", hover, window)

	session.click(s, "new_task")
	session.type_text(s, "partial")
	session.wait_idle(s)
	caret := damage_run(s, app, WATCH_FRAMES)
	testing.expectf(t, caret.most > 0 && caret.most < window / 20, "a caret blink redraws a little: %v of %d", caret, window)

	session.key(s, .Return)
	session.click(s, "toggle_theme")
	session.wait_idle(s)
	testing.expect_value(t, render.damage_verify_differences(&app.shared.r), 0)
	log.infof("todo %d px: idle %v, hover %v, caret %v", window, idle, hover, caret)
}
