// The mark editor (ui.Mark_Editor, docs/mark-editor.md) in a window of its own, with no renderer. What breaks first: a
// drag on the canvas that draws nothing (its presses lost to another box); an undo key that the canvas does not
// hear; a Done whose chore never answers, or answers pixels that are not the box's; a pen whose pressure is lost.
//   odin run tools/run_tests -- mark_editor
package mark_editor_test

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:testing"
import "gt:font"
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
	picture: [2]int,                  // the dialog's picture ({}: PICTURE)
	size_em: ui.Vec2,                 // the dialog's size asked by the program
	em:      f32,                     // the interface's em, from the last build
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	app.em = ui.font_size()
	if app.dialog {
		if app.ask {
			app.ask = false
			size := app.picture != {} ? app.picture : PICTURE
			pic := white(size)
			defer delete(pic)
			ui.mark_editor_dialog(s.state, pic, size.x, size.y, app.options, answered, app, size_em = app.size_em)
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

// Every control of the style line has a place of its own, at every width of the editor: none is drawn over another
// (rows of swatches measured at nothing put the labels, the sliders and the line's choice over the swatches).
@(private = "file")
style_line_apart :: proc(t: ^testing.T, width: int) {
	app: App
	defer ui.mark_editor_destroy(&app.editor)
	pic := white(PICTURE)
	testing.expect(t, ui.mark_editor_init(&app.editor, pic, PICTURE.x, PICTURE.y, {tool = marks.Tool.Rectangle}))
	delete(pic)
	s := session.start(t, {build = build, user = &app, no_renderer = true, size = {width, 700}})
	session.frames(s, SHOW_FRAMES)
	names := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< len(app.editor.colors) {
		append(&names, fmt.tprintf("mark_color_%d", i), fmt.tprintf("mark_fill_%d", i))
	}
	append(&names, "mark_fill_none", "mark_width", "mark_radius", "mark_dash")
	rects := make([dynamic]ui.Rect, context.temp_allocator)
	found := make([dynamic]string, context.temp_allocator)
	for n in names {
		if b := session.find(s, n); b != nil && b.rect.max.x > b.rect.min.x { append(&rects, b.rect); append(&found, n) }
	}
	testing.expectf(t, len(found) == len(names), "%d px: the style line's controls are built (%d of %d)", width, len(found), len(names))
	for a in 0 ..< len(rects) {
		for b in a + 1 ..< len(rects) {
			r, q := rects[a], rects[b]
			// (touching is not overlapping: half a pixel of rounding is allowed)
			over := min(r.max.x, q.max.x) - max(r.min.x, q.min.x) > 0.5 && min(r.max.y, q.max.y) - max(r.min.y, q.min.y) > 0.5
			testing.expectf(t, !over, "%d px: %s %v over %s %v", width, found[a], r, found[b], q)
		}
	}
}

@(test) the_style_line_is_apart_wide :: proc(t: ^testing.T) { style_line_apart(t, 1400) }
@(test) the_style_line_is_apart_at_1000 :: proc(t: ^testing.T) { style_line_apart(t, 1000) }
@(test) the_style_line_is_apart_at_700 :: proc(t: ^testing.T) { style_line_apart(t, 700) }
@(test) the_style_line_is_apart_narrow :: proc(t: ^testing.T) { style_line_apart(t, 480) }


////////////////////////////////
// The Text tool in the dialog, and the dialog's size

@(private = "file") DIALOG_WINDOW :: [2]int{1400, 1000}

// The editor of the dialog of s.
@(private = "file")
dialog_editor :: proc(s: ^session.Session) -> ^ui.Mark_Editor { return &s.state.mark_dialog.editor }

// The dialog's panel (its view's modal: the instance is its State's address).
@(private = "file")
dialog_panel :: proc(s: ^session.Session) -> ^ui.Box {
	return session.get(s, fmt.tprintf("modal_view_%s/%x", ui.MARK_DIALOG_VIEW, uintptr(s.state)))
}

// The size of a box of the last layout.
@(private = "file")
rect_size :: proc(b: ^ui.Box) -> ui.Vec2 { return b.rect.max - b.rect.min }

// Where the field's text starts, in the window: its box's top left inside its padding.
@(private = "file")
field_origin :: proc(s: ^session.Session) -> (at: ui.Vec2, ok: bool) {
	b := session.find(s, "mark_text")
	if b == nil { return }
	return b.rect.min + b.text_pad, true
}

@(private = "file")
near :: proc(a, b: ui.Vec2, within: f32 = 1) -> bool { return abs(a.x - b.x) <= within && abs(a.y - b.y) <= within }

// Whether the field's text starts at a point: x within a pixel; its line's top within a pixel of the point or above it
// by the room its line has over the letters (a field's line is 1.15 of the font's, its letters centred in it: their
// baseline is the text's, the pixel test the_field_and_the_text_kept_meet checks it).
@(private = "file")
field_at :: proc(s: ^session.Session, got, point: ui.Vec2) -> bool {
	b := session.find(s, "mark_text")
	if b == nil { return false }
	above := math.round(b.font_size * 0.15) + 1
	return abs(got.x - point.x) <= 1 && got.y <= point.y + 1 && got.y >= point.y - above
}

// A Text click at zoom, with a pan, in the dialog (centred: away from the window's corner): the field's text starts at
// the click, the mark is at the picture's point under it, the text drawn after Enter starts there too, and the field
// stays on its point while the wheel zooms and pans.
@(private = "file")
text_at_the_click :: proc(t: ^testing.T, zoom: f32) {
	app := App{dialog = true, ask = true, picture = {800, 500}, options = {tool = .Text}}
	s := session.start(t, {build = build, user = &app, no_renderer = true, size = DIALOG_WINDOW})
	session.wait_box(s, "mark_canvas")
	session.frames(s, SHOW_FRAMES)
	e := dialog_editor(s)
	m := &e.model
	canvas := session.get(s, "mark_canvas")
	testing.expectf(t, canvas.rect.min.x > 50 && canvas.rect.min.y > 50, "%v: the dialog's canvas is away from the window's corner (%v)", zoom, canvas.rect.min)
	marks.view_zoom_centre(m, zoom / m.view.zoom)
	m.view.offset += {37, -23}   // (a pan)
	session.frames(s, SHOW_FRAMES)
	click := canvas.rect.min + rect_size(canvas) * {0.3, 0.4}
	click = {f32(int(click.x)), f32(int(click.y))}
	want := (click - canvas.rect.min - m.view.offset) / m.view.zoom
	session.click_at(s, click)
	session.frames(s, SHOW_FRAMES)
	_, typing := m.mode.(marks.Typing)
	testing.expectf(t, typing, "%v: the click types", zoom)
	if got, ok := field_origin(s); testing.expectf(t, ok, "%v: the field is built", zoom) {
		testing.expectf(t, field_at(s, got, click), "%v: the field's text starts at %v, the click was at %v", zoom, got, click)
	}
	session.type_text(s, "Hi")
	// (glued: the wheel zooms about another point, then pans; the field follows its picture point)
	elsewhere := canvas.rect.min + rect_size(canvas) * {0.7, 0.7}
	session.wheel(s, elsewhere, {0, 1}, {.Ctrl})
	session.wheel(s, elsewhere, {0, -1})
	session.frames(s, SHOW_FRAMES)
	if len(m.doc.shapes) == 1 {
		point := canvas.rect.min + marks.to_canvas(m.view, m.doc.shapes[0].a)
		got, ok := field_origin(s)
		testing.expectf(t, ok && field_at(s, got, point), "%v: zoomed and panned, the field's text starts at %v, its point is at %v", zoom, got, point)
		testing.expectf(t, !near(point, click, 4), "%v: the wheel moved the point (%v)", zoom, point)
	}
	session.key(s, .Return)
	testing.expect_value(t, len(m.doc.shapes), 1)
	if len(m.doc.shapes) != 1 { return }
	sh := m.doc.shapes[0]
	testing.expect_value(t, sh.text, "Hi")
	testing.expectf(t, near(sh.a, want, 1 / zoom + 0.01), "%v: the mark is at %v of the picture, the click was over %v", zoom, sh.a, want)
	// (the painter draws a text from its top left by the view, in the window)
	testing.expectf(t, abs(marks.to_window(m.view, sh.a).x - (canvas.rect.min + marks.to_canvas(m.view, sh.a)).x) < 0.5, "%v: the painter and the layout agree", zoom)
	ui.mark_editor_cancel(e)
	session.frames(s, SHOW_FRAMES)
}

@(test) the_text_goes_at_the_click_at_50 :: proc(t: ^testing.T) { text_at_the_click(t, 0.5) }
@(test) the_text_goes_at_the_click_at_74 :: proc(t: ^testing.T) { text_at_the_click(t, 0.74) }
@(test) the_text_goes_at_the_click_at_100 :: proc(t: ^testing.T) { text_at_the_click(t, 1) }
@(test) the_text_goes_at_the_click_at_200 :: proc(t: ^testing.T) { text_at_the_click(t, 2) }

// A click near the canvas's right and bottom edges: the field stays in the canvas (which clips it), and a long text
// typed scrolls in it, its caret seen.
@(test)
the_field_near_the_edge_stays_in_the_canvas :: proc(t: ^testing.T) {
	app := App{dialog = true, ask = true, picture = {800, 500}, options = {tool = .Text}}
	s := session.start(t, {build = build, user = &app, no_renderer = true, size = DIALOG_WINDOW})
	session.wait_box(s, "mark_canvas")
	session.frames(s, SHOW_FRAMES)
	e := dialog_editor(s)
	canvas := session.get(s, "mark_canvas")
	click := canvas.rect.max - {30, 12}
	click = {f32(int(click.x)), f32(int(click.y))}
	session.click_at(s, click)
	session.type_text(s, "A text much longer than the room left")
	session.frames(s, SHOW_FRAMES)
	b := session.find(s, "mark_text")
	if !testing.expect(t, b != nil, "the field is built") { return }
	testing.expectf(t, b.rect.min.x >= canvas.rect.min.x && b.rect.max.x <= canvas.rect.max.x + 1 && b.rect.min.y >= canvas.rect.min.y && b.rect.max.y <= canvas.rect.max.y + 1, "the field %v is in the canvas %v", b.rect, canvas.rect)
	// (the caret at the text's end, in the field: the field scrolled to it)
	testing.expectf(t, e.field.scroll.x > 0, "the field scrolled to its caret (%v)", e.field.scroll)
	ui.mark_editor_cancel(e)
	session.frames(s, SHOW_FRAMES)
}

// The dialog of a picture, opened and laid out; its panel (the canvas's dialog).
@(private = "file")
dialog_open :: proc(t: ^testing.T, app: ^App) -> (^session.Session, ^ui.Box) {
	s := session.start(t, {build = build, user = app, no_renderer = true, size = DIALOG_WINDOW})
	session.wait_box(s, "mark_canvas")
	session.frames(s, SHOW_FRAMES * 2)
	return s, session.get(s, "mark_canvas")
}

// A picture that fits shows at 100 %, in a dialog as large as it needs, no larger than 90 % of the window.
@(test)
the_dialog_opens_at_the_picture :: proc(t: ^testing.T) {
	app := App{dialog = true, ask = true, picture = {900, 560}}
	s, canvas := dialog_open(t, &app)
	e := dialog_editor(s)
	testing.expectf(t, abs(e.model.view.zoom - 1) < 0.001, "zoom %v", e.model.view.zoom)
	c := rect_size(canvas)
	testing.expectf(t, c.x >= 900 && c.y >= 560, "the canvas %v holds the picture", c)
	testing.expectf(t, c.x < 900 / marks.FIT_MARGIN + 8 && c.y < 560 / marks.FIT_MARGIN + 8, "the canvas %v is no larger than the picture needs", c)
}

// A small picture: the dialog's least, the picture at 100 %.
@(test)
the_dialog_of_a_small_picture_is_its_least :: proc(t: ^testing.T) {
	app := App{dialog = true, ask = true, picture = {120, 80}}
	s, canvas := dialog_open(t, &app)
	e := dialog_editor(s)
	testing.expectf(t, abs(e.model.view.zoom - 1) < 0.001, "zoom %v", e.model.view.zoom)
	least := ui.Vec2{ui.MARK_DIALOG_MIN_WIDTH_EM, ui.MARK_DIALOG_MIN_HEIGHT_EM} * app.em
	testing.expectf(t, near(rect_size(dialog_panel(s)), least, 2), "the dialog %v is its least %v", rect_size(dialog_panel(s)), least)
	testing.expectf(t, rect_size(canvas).x > 120, "the canvas %v", rect_size(canvas))
}

// A huge picture: the dialog takes 90 % of the window, the picture fitted in it.
@(test)
the_dialog_of_a_huge_picture_is_most_of_the_window :: proc(t: ^testing.T) {
	app := App{dialog = true, ask = true, picture = {6000, 4000}}
	s, canvas := dialog_open(t, &app)
	e := dialog_editor(s)
	testing.expectf(t, e.model.view.zoom < 0.3, "zoom %v", e.model.view.zoom)
	box := dialog_panel(s)
	testing.expectf(t, abs(rect_size(box).x - 0.9 * f32(DIALOG_WINDOW.x)) < 0.02 * f32(DIALOG_WINDOW.x), "the dialog's width %v", rect_size(box).x)
	testing.expectf(t, rect_size(canvas).y > 0.6 * f32(DIALOG_WINDOW.y), "the canvas's height %v", rect_size(canvas).y)
}

// A program's size, then the person's: resized, closed and opened again, the dialog has the person's size.
@(test)
the_dialog_remembers_its_size :: proc(t: ^testing.T) {
	app := App{dialog = true, ask = true, picture = {6000, 4000}, size_em = {50, 34}}
	s, _ := dialog_open(t, &app)
	box := dialog_panel(s)
	asked := rect_size(box)
	testing.expectf(t, near(asked, ui.Vec2{50, 34} * app.em, 2), "the program's size: %v", asked)
	grip := session.center(session.get(s, "modal_grip3"))
	session.drag(s, grip, grip + {-120, -90})
	session.frames(s, SHOW_FRAMES)
	resized := rect_size(dialog_panel(s))
	testing.expectf(t, !near(resized, asked, 20), "the grip resized it (%v)", resized)
	session.key(s, .Escape)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return (^App)(s.user).answers > 0 }, "the dialog's cancel")
	session.wait_gone(s, "mark_canvas")
	app.ask = true
	session.wait_box(s, "mark_canvas")
	session.frames(s, SHOW_FRAMES * 2)
	again := rect_size(dialog_panel(s))
	testing.expectf(t, near(again, resized, 2), "opened again at %v; the person's size was %v", again, resized)
}

// The red letters' bounds in the canvas of the last frame (min > max: none).
@(private = "file")
red_bounds :: proc(s: ^session.Session, canvas: ui.Rect) -> (lo, hi: [2]int) {
	img := session.capture(s)
	lo, hi = {max(int), max(int)}, {-1, -1}
	for y in int(canvas.min.y) ..< int(canvas.max.y) {
		for x in int(canvas.min.x) ..< int(canvas.max.x) {
			c := session.pixel(img, x, y)
			if c[0] > 150 && c[1] < 110 && c[2] < 110 {
				lo, hi = {min(lo.x, x), min(lo.y, y)}, {max(hi.x, x), max(hi.y, y)}
			}
		}
	}
	return
}

// Drawn by the real renderer, at 74 % in the dialog: the letters typed in the field and the letters of the text kept
// after Enter are on the same pixels. Leaves text_field_74.png and text_kept_74.png in the test's folder.
@(test)
the_field_and_the_text_kept_meet :: proc(t: ^testing.T) {
	styles: [marks.Tool]marks.Style
	styles[.Text] = marks.STYLE_DEFAULT
	styles[.Text].color = RED
	styles[.Text].text_size = 40
	styles[.Text].text_look = .Plain
	app := App{dialog = true, ask = true, picture = {1600, 1000}, options = {tool = .Text, styles = styles}}
	s := session.start(t, {build = build, user = &app, no_renderer = false, size = DIALOG_WINDOW})
	session.wait_box(s, "mark_canvas")
	session.frames(s, SHOW_FRAMES)
	e := dialog_editor(s)
	m := &e.model
	marks.view_zoom_centre(m, 0.74 / m.view.zoom)
	session.frames(s, SHOW_FRAMES)
	canvas := session.get(s, "mark_canvas")
	click := canvas.rect.min + rect_size(canvas) * {0.25, 0.3}
	click = {f32(int(click.x)), f32(int(click.y))}
	session.click_at(s, click)
	session.type_text(s, "Here")
	session.frames(s, SHOW_FRAMES)
	session.save_png(s, "text_field_74.png")
	typed_lo, typed_hi := red_bounds(s, canvas.rect)
	session.key(s, .Return)
	session.frames(s, SHOW_FRAMES)
	session.save_png(s, "text_kept_74.png")
	kept_lo, kept_hi := red_bounds(s, canvas.rect)
	testing.expectf(t, typed_hi.x > typed_lo.x && kept_hi.x > kept_lo.x, "letters seen: typed %v..%v, kept %v..%v", typed_lo, typed_hi, kept_lo, kept_hi)
	d := kept_lo - typed_lo
	testing.expectf(t, abs(d.x) <= 1 && abs(d.y) <= 1, "the field's letters start at %v, the kept text's at %v", typed_lo, kept_lo)
	// (the letters start a little right of and under the text's top left: the side bearing, the space above the capitals)
	testing.expectf(t, f32(kept_lo.x) >= click.x - 1 && f32(kept_lo.x) <= click.x + 8, "the letters start at %v, the click at %v", kept_lo, click)
	testing.expectf(t, f32(kept_lo.y) >= click.y - 1 && f32(kept_lo.y) <= click.y + 20, "the letters' top at %v, the click at %v", kept_lo, click)
	ui.mark_editor_cancel(e)
	session.frames(s, SHOW_FRAMES)
}

// Whether a box or one under it is drawn in the face.
@(private = "file")
drawn_in :: proc(b: ^ui.Box, face: font.Font_Id) -> bool {
	if b.font == face { return true }
	for c := b.first; c != nil; c = c.next { if drawn_in(c, face) { return true } }
	return false
}

// The editor's icons are Lucide's, in a program whose icon font is another (the session's is the toolkit's widget
// font): each tool, the edit and zoom buttons, No fill and Bold draw in the Lucide face, not in the program's.
@(test)
the_icons_are_drawn_in_lucide :: proc(t: ^testing.T) {
	app: App
	defer ui.mark_editor_destroy(&app.editor)
	s := start(t, &app, {tool = .Text})
	lucide := s.state.lucide_font
	testing.expect(t, lucide != 0 && lucide != s.state.icon_font)
	names := [?]string{"mark_tool_0", "mark_tool_7", "mark_act_0", "mark_zoom_in", "mark_zoom_fit", "mark_bold"}
	for n in names {
		b := session.find(s, n)
		testing.expectf(t, b != nil && drawn_in(b, lucide), "%s: its icon in the Lucide face", n)
	}
}
