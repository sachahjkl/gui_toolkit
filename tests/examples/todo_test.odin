package examples_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../examples/todo"
import "../../testkit"
import "../../testkit/session"
import "../../ui"

// examples/todo as a user meets it: a task added, its box ticked, the filters, a tooltip, the context menu, the theme, a deletion, each read back from the
// application and from the file it saves.

// Longer than a hovered_for of the example (0.4 s).
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
	s = session.attach(t, {win = app.win, state = &app.ui_state, renderer = &app.r, user = app, allocator = context.allocator,
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
