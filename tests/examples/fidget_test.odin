// examples/fidget as a user meets it, in this process, with no window of the system: each action checks what it changed.
//   odin test tests/examples -vet -define:ODIN_TEST_THREADS=1
package examples_test

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "../../examples/fidget"
import "../../src/testkit"
import "../../src/testkit/session"
import "../../src/ui"

// The pages, by what the command line says.
@(private = "file") CONTROLS_ARGS := []string{"--anim=off"}
@(private = "file") INPUTS_ARGS := []string{"--anim=off", "--page=1"}
// What Ctrl + and Ctrl - do to a zoom of 100 %, in whole percents.
@(private = "file") ZOOM_NORMAL_PCT :: 100
@(private = "file") ZOOM_IN_PCT :: 110
@(private = "file") ZOOM_OUT_TWICE_PCT :: 91
// A wheel's worth of notches on the Controls page: the page moves.
@(private = "file") WHEEL_NOTCHES :: 6
// Longer than a hovered_for of the examples (0.4 s).
@(private = "file") TOOLTIP_WAIT_MS :: 600
// A press at this share of the Volume slider's track, and what its value may then be.
@(private = "file") SLIDER_AT :: 0.35
@(private = "file") SLIDER_MIN :: 25
@(private = "file") SLIDER_MAX :: 45

@(private = "file")
start_fidget :: proc(t: ^testing.T, args: []string, loc := #caller_location) -> (s: ^session.Session, app: ^fidget.App) {
	dir := testkit.temp_folder(t, "fidget")
	context.allocator = runtime.heap_allocator()
	app = fidget.open({args = args, headless = true, settings_dir = dir})
	if !testing.expect(t, app != nil, "fidget opens", loc = loc) { session.stop_test(t, "no application", loc) }
	testing.cleanup(t, proc(p: rawptr) { fidget.close((^fidget.App)(p)) }, app)
	s = session.attach(t, {win = app.win, state = &app.ui_state, renderer = &app.r, user = app, allocator = context.allocator,
		frame = proc(user: rawptr) { fidget.frame((^fidget.App)(user)) }}, loc)
	session.frames(s, 2)
	return
}

@(private = "file")
zoom_pct :: proc(app: ^fidget.App) -> int { return int(math.round(ui.zoom(&app.ui_state) * 100)) }

// The line edits, the clipboard, Tab and Shift+Tab.
@(test)
fidget_line_edits_clipboard_and_tab :: proc(t: ^testing.T) {
	s, app := start_fidget(t, INPUTS_ARGS)
	session.click(s, "in_name")
	testing.expect_value(t, session.focused_name(s), "in_name")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "Grace Hopper")
	testing.expect_value(t, ui.field_string(&app.name), "Grace Hopper")
	session.key(s, .A, {.Ctrl})
	session.key(s, .C, {.Ctrl})
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "in_email")
	session.key(s, .Tab, {.Shift})
	testing.expect_value(t, session.focused_name(s), "in_name")
	session.click(s, "in_bio")
	testing.expect_value(t, session.focused_name(s), "in_bio")
	session.key(s, .V, {.Ctrl})
	testing.expect_value(t, ui.field_string(&app.bio), "Grace Hopper")
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "ck_agree")
	session.key(s, .Space)
	testing.expect(t, app.agree, "Space activates the checkbox")
	// the arrows move the focus through space
	session.key(s, .Down)
	testing.expect_value(t, session.focused_name(s), "b_submit")
	session.key(s, .Up)
	testing.expect_value(t, session.focused_name(s), "ck_agree")
	session.key(s, .Up)
	testing.expect_value(t, session.focused_name(s), "in_bio")
}

// The multi-line editor: typing, Enter, undo, redo, Delete of a selection, Esc.
@(test)
fidget_editor_undo_and_redo :: proc(t: ^testing.T) {
	s, app := start_fidget(t, INPUTS_ARGS)
	lines, length := ui.area_line_count(&app.editor), len(app.editor.buf)
	session.click(s, "editor")
	testing.expect_value(t, session.focused_name(s), "editor")
	session.key(s, .End, {.Ctrl})
	session.type_text(s, "hello")
	session.key(s, .Return)
	session.type_text(s, "world")
	testing.expect_value(t, ui.area_line_count(&app.editor), lines + 1)
	testing.expect_value(t, len(app.editor.buf), length + len("hello\nworld"))
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, len(app.editor.buf), length + len("hello\n"))
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.area_line_count(&app.editor), lines)
	session.key(s, .Y, {.Ctrl})
	testing.expect_value(t, ui.area_line_count(&app.editor), lines + 1)
	session.key(s, .A, {.Ctrl})
	session.key(s, .Delete)
	testing.expect_value(t, len(app.editor.buf), 0)
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, len(app.editor.buf), length + len("hello\n"))
	session.key(s, .Escape)
	testing.expect_value(t, session.focused_name(s), "")
}

// The multi-line editor takes the clipboard's IBM chords as a line edit does: Ctrl+Insert copies, Shift+Delete cuts,
// Shift+Insert pastes.
@(test)
fidget_editor_clipboard_by_insert_and_delete :: proc(t: ^testing.T) {
	s, app := start_fidget(t, INPUTS_ARGS)
	session.click(s, "editor")
	session.key(s, .A, {.Ctrl})
	session.key(s, .Delete)
	session.type_text(s, "hello")
	session.key(s, .A, {.Ctrl})
	session.key(s, .Insert, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), "hello")
	session.key(s, .Delete, {.Shift})
	testing.expect_value(t, len(app.editor.buf), 0)
	testing.expect_value(t, session.clipboard(s), "hello")
	session.key(s, .Insert, {.Shift})
	session.key(s, .Insert, {.Shift})
	testing.expect_value(t, ui.area_string(&app.editor), "hellohello")
}

// Ctrl +, Ctrl -, Ctrl 0, and the zoom is written to the settings.
@(test)
fidget_zoom_keys_and_settings :: proc(t: ^testing.T) {
	s, app := start_fidget(t, INPUTS_ARGS)
	session.key(s, .Equal, {.Ctrl})
	testing.expect_value(t, zoom_pct(app), ZOOM_IN_PCT)
	text, err := os.read_entire_file(fmt.tprintf("%s/settings.txt", app.settings_in), context.temp_allocator)
	testing.expectf(t, err == nil && strings.contains(string(text), "zoom=1.100"), "the zoom is in the settings, got %q", string(text))
	session.key(s, .Minus, {.Ctrl}, repeat = 2)
	testing.expect_value(t, zoom_pct(app), ZOOM_OUT_TWICE_PCT)
	session.key(s, .N0, {.Ctrl})
	testing.expect_value(t, zoom_pct(app), ZOOM_NORMAL_PCT)
}

// The palette and Settings by their keys, a dialog's Tab order, a dropdown by the keyboard.
@(test)
fidget_overlays_by_the_keyboard :: proc(t: ^testing.T) {
	s, app := start_fidget(t, INPUTS_ARGS)
	session.key(s, .K, {.Ctrl})
	testing.expect(t, app.palette_open)
	session.key(s, .Escape)
	testing.expect(t, !app.palette_open)
	session.key(s, .Comma, {.Ctrl})
	testing.expect(t, app.settings_open)
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "st_close")
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "st_theme")
	before := app.palette_idx
	session.key(s, .Return)
	session.key(s, .Down)
	session.key(s, .Return)
	testing.expect_value(t, app.palette_idx, before + 1)
	session.key(s, .Escape)
	testing.expect(t, !app.settings_open)
}

// A menu opens by its button and closes on a click anywhere else.
@(test)
fidget_menu_closes_on_a_click_outside :: proc(t: ^testing.T) {
	s, _ := start_fidget(t, INPUTS_ARGS)
	session.click(s, "menu_file")
	testing.expect(t, ui.ctx_menu_any_open(), "File opens its menu")
	session.click(s, "statusbar")
	testing.expect(t, !ui.ctx_menu_any_open(), "a click on the status bar closes it")
}

// The widgets of the first page by the mouse: each changes what it says it changes.
@(test)
fidget_controls_by_the_mouse :: proc(t: ^testing.T) {
	s, app := start_fidget(t, CONTROLS_ARGS)
	was := app.sw[1]
	session.click(s, "sw1")
	testing.expect(t, app.sw[1] != was, "the toggle turns")
	session.click_text(s, "Month")
	testing.expect_value(t, fidget.seg_labels[app.seg], "Month")
	chips := app.chips
	session.click_text(s, "Beta")
	testing.expect(t, app.chips != chips, "the chip turns")
	session.click(s, "dd_lang")
	session.click_text(s, "Odin")
	testing.expect_value(t, fidget.lang_items[app.dd[0]], "Odin")
	// a press on a slider's track puts its value there
	track := session.get(s, "sl0")
	session.click_at(s, {track.rect.min.x + (track.rect.max.x - track.rect.min.x) * SLIDER_AT, session.center(track).y})
	testing.expectf(t, app.slider[0] > SLIDER_MIN && app.slider[0] < SLIDER_MAX, "Volume about 35 %%, got %v", app.slider[0])
}

// A tooltip comes after its delay, a context menu by the right button and goes with Esc, the wheel scrolls.
@(test)
fidget_tooltip_menu_and_wheel :: proc(t: ^testing.T) {
	s, _ := start_fidget(t, CONTROLS_ARGS)
	session.hover(s, "b_tip")
	testing.expect(t, session.find_text(s, "floating boxes") == nil, "not yet")
	session.advance(s, TOOLTIP_WAIT_MS)
	testing.expect(t, session.find_text(s, "floating boxes") != nil, "the tooltip, after its delay")
	session.click_text(s, "Right-click", .Right)
	testing.expect(t, ui.ctx_menu_any_open(), "the right button opens the menu")
	testing.expect(t, session.find_text(s, "Duplicate") != nil, "with its items")
	session.key(s, .Escape)
	testing.expect(t, !ui.ctx_menu_any_open(), "Esc closes it")
	page := session.get(s, "pg_controls")
	session.wheel(s, session.center(page), {0, WHEEL_NOTCHES})
	session.wait_idle(s)
	page = session.get(s, "pg_controls")
	testing.expect(t, page.view_target.y != 0 || page.view_off.y != 0, "the wheel scrolls the page")
}

// The palette by the mouse: typing filters, Enter runs; F1 opens About, Esc closes it; the app still answers.
@(test)
fidget_palette_and_about :: proc(t: ^testing.T) {
	s, app := start_fidget(t, CONTROLS_ARGS)
	session.click(s, "bar_palette")
	testing.expect(t, app.palette_open)
	session.type_text(s, "machined")
	session.key(s, .Return)
	testing.expect(t, !app.palette_open, "Enter runs the command and closes the palette")
	testing.expect(t, app.machined, "the machined finish is on")
	session.key(s, .F1)
	testing.expect(t, app.about_open)
	session.key(s, .Escape)
	testing.expect(t, !app.about_open)
	was := app.sw[1]
	session.click(s, "sw1")
	testing.expect(t, app.sw[1] != was, "it still answers")
}
