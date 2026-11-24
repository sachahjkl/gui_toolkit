// The mark editor (ui.Mark_Editor, docs/mark-editor.md) in a window of its own, with no renderer. What breaks first: a
// drag on the canvas that draws nothing (its presses lost to another box); an undo key that the canvas does not
// hear; a Done whose chore never answers, or answers pixels that are not the box's; a pen whose pressure is lost.
//   odin run tools/run_tests -- mark_editor
package mark_editor_test

import "base:runtime"
import "core:testing"
import "gt:marks"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") PICTURE :: [2]int{200, 100}
@(private = "file") WINDOW :: [2]int{900, 600}
@(private = "file") SHOW_FRAMES :: 4
@(private = "file") RED :: u32(0xE53935)
@(private = "file") BLUE :: u32(0x1E88E5)

@(private = "file")
App :: struct {
	editor:  ui.Mark_Editor,
	events:  ui.Mark_Editor_Events,   // every event the builds returned
	ask:     bool,                    // the next build opens the dialog
	options: ui.Mark_Editor_Options,
	answers: int,
	ok:      bool,
	rgba:    []u8,                    // the dialog's answer (heap)
	size:    [2]int,
	dialog:  bool,                    // the test of the dialog: no editor of its own
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if app.dialog {
		if app.ask {
			app.ask = false
			pic := white(PICTURE)
			defer delete(pic)
			ui.mark_editor_dialog(s.state, pic, PICTURE.x, PICTURE.y, app.options, answered, app)
		}
		return
	}
	app.events += ui.mark_editor("marks", &app.editor)
}

@(private = "file")
answered :: proc(rgba: []u8, size: [2]int, ok: bool, user: rawptr) {
	app := (^App)(user)
	app.answers += 1
	app.ok, app.rgba, app.size = ok, rgba, size
}

@(private = "file")
white :: proc(size: [2]int) -> []u8 {
	out := make([]u8, size.x * size.y * 4)
	for &v in out { v = 255 }
	return out
}

@(private = "file")
pixel :: proc(rgba: []u8, w, x, y: int) -> [4]u8 {
	i := (y * w + x) * 4
	return {rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]}
}

// An editor on a white picture, its first tool and styles from the options, laid out (its view fitted).
@(private = "file")
start :: proc(t: ^testing.T, app: ^App, o: ui.Mark_Editor_Options) -> ^session.Session {
	pic := white(PICTURE)
	defer delete(pic)
	testing.expect(t, ui.mark_editor_init(&app.editor, pic, PICTURE.x, PICTURE.y, o))
	s := session.start(t, {build = build, user = app, no_renderer = true, size = WINDOW})
	session.frames(s, SHOW_FRAMES)
	return s
}

// Where a point of the picture is in the window, by the view of the last build.
@(private = "file")
at :: proc(app: ^App, p: [2]f32) -> [2]f32 { return marks.to_window(app.editor.model.view, p) }

@(private = "file")
done_seen :: proc(s: ^session.Session) -> bool { return .Done in (^App)(s.user).events }

// A box drawn on the canvas, undone, done again, then flattened: its inside is its fill, its edge its colour.
@(test)
a_box_is_drawn_undone_and_flattened :: proc(t: ^testing.T) {
	app: App
	defer ui.mark_editor_destroy(&app.editor)
	styles: [marks.Tool]marks.Style
	styles[.Rectangle] = marks.STYLE_DEFAULT
	styles[.Rectangle].color = RED
	styles[.Rectangle].fill_color = marks.OPAQUE | BLUE
	s := start(t, &app, {tool = .Rectangle, styles = styles})
	m := &app.editor.model
	session.drag(s, at(&app, {20, 20}), at(&app, {120, 80}))
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect(t, .Changed in app.events)
	if len(m.doc.shapes) == 1 {
		r := marks.box_of(m.doc.shapes[0].a, m.doc.shapes[0].b)
		testing.expect(t, abs(r.min.x - 20) < 1 && abs(r.max.y - 80) < 1)
	}
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, len(m.doc.shapes), 0)
	session.key(s, .Y, {.Ctrl})
	testing.expect_value(t, len(m.doc.shapes), 1)
	session.key(s, .Return, {.Ctrl})
	session.wait_until(s, done_seen, "the flattened picture")
	rgba, size, ok := ui.mark_editor_result(&app.editor)
	defer delete(rgba, runtime.heap_allocator())
	testing.expect(t, ok)
	testing.expect_value(t, size, PICTURE)
	if !ok { return }
	testing.expect_value(t, pixel(rgba, size.x, 70, 50), [4]u8{0x1E, 0x88, 0xE5, 255})   // (inside: the fill)
	testing.expect_value(t, pixel(rgba, size.x, 20, 50), [4]u8{0xE5, 0x39, 0x35, 255})   // (its left edge)
	testing.expect_value(t, pixel(rgba, size.x, 160, 50), [4]u8{255, 255, 255, 255})     // (the picture)
	_, _, again := ui.mark_editor_result(&app.editor)
	testing.expect(t, !again)   // (taken once)
}

// The tools' keys, the selection's keys, Escape: deselects, then cancels.
@(test)
the_keys_choose_and_cancel :: proc(t: ^testing.T) {
	app: App
	defer ui.mark_editor_destroy(&app.editor)
	s := start(t, &app, {})
	m := &app.editor.model
	testing.expect_value(t, m.tool, marks.Tool.Arrow)
	session.key(s, .L)
	testing.expect_value(t, m.tool, marks.Tool.Line)
	session.drag(s, at(&app, {10, 10}), at(&app, {150, 60}))
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect(t, marks.has_selection(m))
	session.key(s, .D, {.Ctrl})
	testing.expect_value(t, len(m.doc.shapes), 2)
	session.key(s, .Delete)
	testing.expect_value(t, len(m.doc.shapes), 1)
	session.key(s, .A, {.Ctrl})
	testing.expect_value(t, marks.selection_count(m), 1)
	session.key(s, .Escape)
	testing.expect(t, !marks.has_selection(m))
	testing.expect(t, .Cancelled not_in app.events)
	session.key(s, .Escape)
	testing.expect(t, .Cancelled in app.events)
}

// A pen's stroke keeps the pen's pressure, and its ink is made.
@(test)
the_pen_keeps_the_pressure :: proc(t: ^testing.T) {
	app: App
	defer ui.mark_editor_destroy(&app.editor)
	s := start(t, &app, {tool = .Pen})
	m := &app.editor.model
	session.pen_drag(s, at(&app, {20, 50}), at(&app, {180, 50}), {0.2, 0.9})
	testing.expect_value(t, len(m.doc.shapes), 1)
	if len(m.doc.shapes) != 1 { return }
	sh := &m.doc.shapes[0]
	testing.expect_value(t, sh.kind, marks.Kind.Pen)
	testing.expect(t, len(sh.samples) > 3)
	last := sh.samples[len(sh.samples) - 1]
	testing.expect(t, last.pressure > 0.5)
	testing.expect(t, len(sh.polygon) >= 3)
}

// A text typed on the picture: its letters in the flattened picture.
@(test)
a_text_is_typed_and_flattened :: proc(t: ^testing.T) {
	app: App
	defer ui.mark_editor_destroy(&app.editor)
	styles: [marks.Tool]marks.Style
	styles[.Text] = marks.STYLE_DEFAULT
	styles[.Text].color = 0x000000
	styles[.Text].text_size = 40
	s := start(t, &app, {tool = .Text, styles = styles})
	m := &app.editor.model
	session.click_at(s, at(&app, {10, 10}))
	_, typing := m.mode.(marks.Typing)
	testing.expect(t, typing)
	session.type_text(s, "Hi")
	session.key(s, .Return)
	testing.expect_value(t, len(m.doc.shapes), 1)
	if len(m.doc.shapes) != 1 { return }
	testing.expect_value(t, m.doc.shapes[0].text, "Hi")
	box := marks.box_of(m.doc.shapes[0].a, m.doc.shapes[0].b)
	ui.mark_editor_done(&app.editor)
	session.wait_until(s, done_seen, "the flattened picture")
	rgba, size, ok := ui.mark_editor_result(&app.editor)
	defer delete(rgba, runtime.heap_allocator())
	testing.expect(t, ok)
	if !ok { return }
	dark := 0
	for y in int(box.min.y) ..< min(int(box.max.y), size.y) {
		for x in int(box.min.x) ..< min(int(box.max.x), size.x) {
			if pixel(rgba, size.x, x, y)[0] < 64 { dark += 1 }
		}
	}
	testing.expect(t, dark > 20)   // (the letters' ink)
}

// The dialog: opened in one call, its Done answers once with the picture, and it closes.
@(test)
the_dialog_answers_once :: proc(t: ^testing.T) {
	app := App{dialog = true, ask = true, options = {tool = .Highlighter}}
	defer delete(app.rgba, runtime.heap_allocator())
	s := session.start(t, {build = build, user = &app, no_renderer = true, size = WINDOW})
	session.frames(s, SHOW_FRAMES)
	testing.expect(t, ui.mark_editor_dialog_shown(s.state))
	session.wait_box(s, "mark_canvas")
	session.click(s, "mark_canvas")
	session.key(s, .Return, {.Ctrl})
	session.wait_until(s, proc(s: ^session.Session) -> bool { return (^App)(s.user).answers > 0 }, "the dialog's answer")
	testing.expect_value(t, app.answers, 1)
	testing.expect(t, app.ok)
	testing.expect_value(t, app.size, PICTURE)
	session.frames(s, SHOW_FRAMES)
	testing.expect(t, !ui.mark_editor_dialog_shown(s.state))
	session.wait_gone(s, "mark_canvas")
	testing.expect_value(t, app.answers, 1)
}
// The canvas drawn by the real renderer: the picture, a filled box, a pen's ink, a pixelated part once its mosaic is
// made (a flat grey before).
@(test)
the_canvas_shows_the_marks :: proc(t: ^testing.T) {
	app: App
	defer ui.mark_editor_destroy(&app.editor)
	pic := white(PICTURE)
	defer delete(pic)
	styles: [marks.Tool]marks.Style
	styles[.Rectangle] = marks.STYLE_DEFAULT
	styles[.Rectangle].fill_color = marks.OPAQUE | BLUE
	testing.expect(t, ui.mark_editor_init(&app.editor, pic, PICTURE.x, PICTURE.y, {tool = .Rectangle, styles = styles}))
	s := session.start(t, {build = build, user = &app, no_renderer = false, size = WINDOW})
	session.frames(s, SHOW_FRAMES)
	session.drag(s, at(&app, {20, 20}), at(&app, {80, 80}))
	app.editor.model.tool = .Pixelate
	session.drag(s, at(&app, {120, 20}), at(&app, {180, 80}))
	app.editor.model.tool = .Pen
	session.drag(s, at(&app, {20, 90}), at(&app, {180, 92}))
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		for f in (^App)(s.user).editor.filters { if f.job != nil { return false } }
		return true
	}, "the mosaic made")
	session.frames(s, SHOW_FRAMES)
	img := session.capture(s)
	inside := at(&app, {50, 50})
	c := session.pixel(img, int(inside.x), int(inside.y))
	testing.expect(t, c[2] > 180 && c[0] < 100)   // (the fill's blue)
	hidden := at(&app, {150, 50})
	h := session.pixel(img, int(hidden.x), int(hidden.y))
	testing.expect(t, h[0] > 240 && h[1] > 240)   // (the mosaic of a white picture: white, not its grey stand-in)
	ink := at(&app, {100, 91})
	k := session.pixel(img, int(ink.x), int(ink.y))
	testing.expect(t, k[0] > 150 && k[1] < 120)   // (the pen's red)
}
