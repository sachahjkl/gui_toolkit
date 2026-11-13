// text_edit's keys and pointer, without a window: the clipboard, every move, the edits and their undo steps, clicks, drags,
// the wheel, its scrollbars, what a screen reader asks.
package keyboard_test

import "core:strings"
import "core:sync"
import "core:testing"
import "../../src/font"
import "../../src/platform"
import "../../src/ui"

@(private = "file")
Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	ui_font: font.Font_Id,
	area:  ui.Text_Edit,
	res:   ui.Edit_Result,
	tabs, numbers, no_clipboard: bool,
	highlight: ^ui.Text_Highlight,
	clock: f64,
}

@(private = "file") lock: sync.Mutex
@(private = "file") clip: string
@(private = "file") set_clip :: proc(t: string) { delete(clip); clip = strings.clone(t) }

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.ui_font = id
	f.clock = 1000
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.text_edit_destroy(&f.area)
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
	delete(clip)
	clip = ""
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event = nil) {
	f.clock += 16
	p := ui.Build_Params{
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1, time_ms = f.clock,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
	}
	if !f.no_clipboard {
		p.clipboard_get = proc() -> string { return clip }
		p.clipboard_set = set_clip
	}
	ui.begin_build(&f.s, p)
	ui.next({width = ui.px(300), height = ui.px(200)})
	f.res = ui.text_edit("###k", &f.area, {line_numbers = f.numbers, tab_indents = f.tabs, highlight = f.highlight})
	ui.end_build()
	free_all(context.temp_allocator)
}

// The editor with `text`, focused and laid out.
@(private = "file")
start :: proc(f: ^Fx, text: string) {
	ui.text_edit_set(&f.area, text)
	frame(f)
	ui.set_focus(f.res.box.key)
	frame(f)
}

@(private = "file") key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }
@(private = "file") tap :: proc(f: ^Fx, k: platform.Key, mods: platform.Modifiers = {}) { frame(f, {key(k, mods)}) }
@(private = "file") text :: proc(f: ^Fx) -> string { return ui.text_edit_string(&f.area) }

@(private = "file")
expect_caret :: proc(t: ^testing.T, f: ^Fx, cursor, mark: int, loc := #caller_location) {
	testing.expect_value(t, f.area.cursor, cursor, loc)
	testing.expect_value(t, f.area.mark, mark, loc)
}

// Where index `i` of paragraph `line` is on screen (paragraphs do not wrap here).
@(private = "file")
point :: proc(f: ^Fx, line_start, i, line: int) -> ui.Vec2 {
	b := f.res.box
	t := text(f)
	e := strings.index_byte(t[line_start:], '\n')
	stop := e < 0 ? len(t) : line_start + e
	x := font.x_from_index(&f.fonts, f.ui_font, 15, t[line_start:stop], i - line_start)
	m := font.metrics(&f.fonts, f.ui_font, 15)
	lh := f32(int(m.line_height * 1.15 + 0.5))
	return {b.rect.min.x + b.text_pad + x + 0.4, b.rect.min.y + b.text_pad + (f32(line) + 0.5) * lh}
}

@(private = "file") press :: proc(p: ui.Vec2, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Mouse_Press, pos = p, button = .Left, mods = mods} }
@(private = "file") release :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Release, pos = p, button = .Left} }
@(private = "file") move_to :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Move, pos = p} }

@(test)
text_edit_clipboard :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "fonts") { return }
	defer close(f)
	start(f, "hello world")
	// copy: the selection, the text stays; nothing selected: the clipboard stays
	tap(f, .A, {.Ctrl})
	expect_caret(t, f, 11, 0)
	tap(f, .C, {.Ctrl})
	testing.expect_value(t, clip, "hello world")
	testing.expect_value(t, text(f), "hello world")
	tap(f, .End)
	set_clip("kept")
	tap(f, .C, {.Ctrl})
	tap(f, .X, {.Ctrl})
	testing.expect_value(t, clip, "kept")
	testing.expect_value(t, text(f), "hello world")
	// cut: copied and gone, in one undo step
	tap(f, .Home, {.Ctrl})
	for _ in 0 ..< 5 { tap(f, .Right, {.Shift}) }
	expect_caret(t, f, 5, 0)
	tap(f, .X, {.Ctrl})
	testing.expect_value(t, clip, "hello")
	testing.expect_value(t, text(f), " world")
	expect_caret(t, f, 0, 0)
	tap(f, .Z, {.Ctrl})
	testing.expect_value(t, text(f), "hello world")
	// paste: over the selection, line ends and tabs made the editor's
	tap(f, .A, {.Ctrl})
	set_clip("a\r\nb\tc\rd")
	tap(f, .V, {.Ctrl})
	testing.expect_value(t, text(f), "hello world")   // (asked: the text comes in the next build)
	frame(f)
	testing.expect_value(t, text(f), "a\nb    c\nd")
	expect_caret(t, f, 10, 10)
	// one undo step takes it back; Shift+Insert pastes too
	tap(f, .Z, {.Ctrl})
	testing.expect_value(t, text(f), "hello world")
	tap(f, .End, {.Ctrl})
	set_clip("!")
	tap(f, .Insert, {.Shift})
	frame(f)
	testing.expect_value(t, text(f), "hello world!")
	// an empty clipboard is no edit
	n := len(f.area.history.undo)
	set_clip("")
	tap(f, .V, {.Ctrl})
	frame(f)
	testing.expect_value(t, len(f.area.history.undo), n)
	// no clipboard given (and no window): the cut still cuts, the paste does nothing
	f.no_clipboard = true
	tap(f, .A, {.Ctrl})
	tap(f, .C, {.Ctrl})
	tap(f, .V, {.Ctrl})
	frame(f)
	testing.expect_value(t, text(f), "hello world!")
	tap(f, .X, {.Ctrl})
	testing.expect_value(t, text(f), "")
}

@(test)
text_edit_moves :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "fonts") { return }
	defer close(f)
	start(f, "one two\n  three four\nfive")
	expect_caret(t, f, 25, 25)
	tap(f, .Home, {.Ctrl})
	expect_caret(t, f, 0, 0)
	tap(f, .Right)
	expect_caret(t, f, 1, 1)
	tap(f, .Right, {.Shift})
	expect_caret(t, f, 2, 1)
	tap(f, .Left)   // a selection collapses to its end, it does not move
	expect_caret(t, f, 1, 1)
	tap(f, .Right, {.Shift})
	tap(f, .Right)
	expect_caret(t, f, 2, 2)
	tap(f, .Left, {.Shift})
	expect_caret(t, f, 1, 2)
	tap(f, .Left)
	expect_caret(t, f, 1, 1)
	// words
	tap(f, .Right, {.Ctrl})
	expect_caret(t, f, 3, 3)
	tap(f, .Right, {.Ctrl})
	expect_caret(t, f, 7, 7)
	tap(f, .Left, {.Ctrl, .Shift})
	expect_caret(t, f, 4, 7)
	tap(f, .Right, {.Ctrl, .Shift})
	expect_caret(t, f, 7, 7)
	tap(f, .Left, {.Ctrl})
	expect_caret(t, f, 4, 4)
	// the line's ends
	tap(f, .End)
	expect_caret(t, f, 7, 7)
	tap(f, .Home, {.Shift})
	expect_caret(t, f, 0, 7)
	tap(f, .End, {.Shift})
	expect_caret(t, f, 7, 7)
	// Up / Down keep the column
	tap(f, .Down)
	testing.expect(t, f.area.cursor > 8 && f.area.cursor <= 20, "on the second line")
	tap(f, .Up)
	expect_caret(t, f, 7, 7)
	tap(f, .Up)
	expect_caret(t, f, 0, 0)   // past the first line: the start
	// Home: the first character that is no space, then the line's start
	tap(f, .Home, {.Ctrl})
	tap(f, .Down)
	expect_caret(t, f, 8, 8)
	tap(f, .Home)
	expect_caret(t, f, 10, 10)
	tap(f, .Home)
	expect_caret(t, f, 8, 8)
	tap(f, .End)
	expect_caret(t, f, 20, 20)
	// the document's ends, the pages
	tap(f, .End, {.Ctrl})
	expect_caret(t, f, 25, 25)
	tap(f, .Down)
	expect_caret(t, f, 25, 25)
	tap(f, .Page_Up)
	expect_caret(t, f, 0, 0)
	tap(f, .Page_Down)
	expect_caret(t, f, 25, 25)
	tap(f, .Home, {.Ctrl, .Shift})
	expect_caret(t, f, 0, 25)
	tap(f, .End, {.Ctrl, .Shift})
	expect_caret(t, f, 25, 25)
	tap(f, .Page_Up, {.Shift})
	expect_caret(t, f, 0, 25)
	tap(f, .Page_Down, {.Shift})
	expect_caret(t, f, 25, 25)
	tap(f, .Up, {.Shift})
	testing.expect(t, f.area.cursor < 25 && f.area.mark == 25, "Shift+Up selects")
	tap(f, .Down, {.Shift})
	expect_caret(t, f, 25, 25)
	// a move is no edit
	testing.expect(t, !f.res.changed && len(f.area.history.undo) == 0, "nothing to undo")
}

@(test)
text_edit_edits :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "fonts") { return }
	defer close(f)
	// Enter keeps the indentation; Ctrl+Enter commits and edits nothing
	start(f, "  ab")
	tap(f, .Return)
	testing.expect_value(t, text(f), "  ab\n  ")
	testing.expect(t, f.res.changed, "changed")
	expect_caret(t, f, 7, 7)
	tap(f, .Return, {.Ctrl})
	testing.expect(t, f.res.committed && !f.res.changed, "committed")
	// undo and the two redos
	tap(f, .Z, {.Ctrl})
	testing.expect_value(t, text(f), "  ab")
	tap(f, .Y, {.Ctrl})
	testing.expect_value(t, text(f), "  ab\n  ")
	tap(f, .Z, {.Ctrl})
	tap(f, .Z, {.Ctrl, .Shift})
	testing.expect_value(t, text(f), "  ab\n  ")
	// Tab: four spaces when asked, else the editor's text stays
	frame(f, {key(.Tab)})
	testing.expect_value(t, text(f), "  ab\n  ")
	ui.set_focus(f.res.box.key)
	frame(f)
	f.tabs = true
	frame(f, {key(.Tab)})
	testing.expect_value(t, text(f), "  ab\n      ")
	f.tabs = false
	// deleting: a cluster, a word, a selection
	start(f, "foo bar é")
	tap(f, .Backspace)
	testing.expect_value(t, text(f), "foo bar ")
	tap(f, .Backspace, {.Ctrl})
	testing.expect_value(t, text(f), "foo ")
	tap(f, .Home, {.Ctrl})
	tap(f, .Delete)
	testing.expect_value(t, text(f), "oo ")
	tap(f, .Delete, {.Ctrl})
	testing.expect_value(t, text(f), " ")
	start(f, "foo bar")
	tap(f, .Home, {.Ctrl})
	tap(f, .Right, {.Ctrl, .Shift})
	tap(f, .Delete)
	testing.expect_value(t, text(f), " bar")
	tap(f, .A, {.Ctrl})
	tap(f, .Backspace, {.Shift})
	testing.expect_value(t, text(f), "")
	start(f, "foo bar")
	tap(f, .Home, {.Ctrl})
	tap(f, .Right, {.Ctrl, .Shift})
	tap(f, .Backspace, {.Ctrl})
	testing.expect_value(t, text(f), " bar")
	tap(f, .Right, {.Ctrl, .Shift})
	tap(f, .Delete, {.Ctrl})
	testing.expect_value(t, text(f), "")
	// typing within a second is one undo step; a pause starts another
	start(f, "")
	frame(f, {{kind = .Text, text = 'a'}})
	frame(f, {{kind = .Text, text = 'b'}})
	f.clock += 1200
	frame(f, {{kind = .Text, text = 'c'}})
	testing.expect_value(t, text(f), "abc")
	tap(f, .Z, {.Ctrl})
	testing.expect_value(t, text(f), "ab")
	tap(f, .Z, {.Ctrl})
	testing.expect_value(t, text(f), "")
	testing.expect(t, !f.res.changed || len(f.area.history.undo) == 0, "the history is empty")
	// typing over a selection; deleting after a pause is its own step
	start(f, "xyz")
	tap(f, .A, {.Ctrl})
	frame(f, {{kind = .Text, text = 'q'}})
	testing.expect_value(t, text(f), "q")
	tap(f, .Z, {.Ctrl})
	testing.expect_value(t, text(f), "xyz")
	// Escape leaves the field
	tap(f, .Escape)
	testing.expect(t, f.res.cancelled, "cancelled")
	testing.expect_value(t, ui.focus_key(), ui.Key(0))
	frame(f, {{kind = .Text, text = 'q'}})
	testing.expect_value(t, text(f), "xyz")   // no focus, no typing
}

@(test)
text_edit_pointer :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "fonts") { return }
	defer close(f)
	start(f, "one two\nthree")
	// a click places the caret; Shift+click extends; a drag selects
	p3 := point(f, 0, 3, 0)
	frame(f, {move_to(p3)})
	frame(f, {press(p3), release(p3)})
	expect_caret(t, f, 3, 3)
	f.clock += 1000
	p5 := point(f, 0, 5, 0)
	shift_up := release(p5)
	shift_up.mods = {.Shift}   // (still held: a release says what is held after it)
	frame(f, {press(p5, {.Shift}), shift_up})
	expect_caret(t, f, 5, 3)
	f.clock += 1000
	p1, p6 := point(f, 0, 1, 0), point(f, 0, 6, 0)
	frame(f, {press(p1)})
	frame(f, {move_to(p6)})
	expect_caret(t, f, 6, 1)
	frame(f, {release(p6)})
	expect_caret(t, f, 6, 1)
	f.clock += 1000
	// the second line, by its height
	p := point(f, 8, 10, 1)
	frame(f, {press(p), release(p)})
	expect_caret(t, f, 10, 10)
	f.clock += 1000
	// a double click: the word
	pw := point(f, 0, 5, 0)
	frame(f, {press(pw), release(pw)})
	frame(f, {press(pw), release(pw)})
	expect_caret(t, f, 7, 4)
	f.clock += 1000
	// the same at the far end of a double click's time, and not past it
	frame(f, {press(pw), release(pw)})
	f.clock += 420
	frame(f, {press(pw), release(pw)})
	expect_caret(t, f, 7, 4)
	f.clock += 1000
	frame(f, {press(pw), release(pw)})
	f.clock += 470
	frame(f, {press(pw), release(pw)})
	expect_caret(t, f, 5, 5)
	f.clock += 1000
	// the caret is after the line numbers' gutter
	x0 := f.res.caret.min.x
	f.numbers = true
	frame(f)
	testing.expect(t, f.res.caret.min.x > x0, "the gutter moves the text")
	frame(f, {press(point(f, 0, 0, 0) + {f.res.caret.min.x - x0, 0}), release(point(f, 0, 0, 0) + {f.res.caret.min.x - x0, 0})})
	expect_caret(t, f, 0, 0)
	f.numbers = false
	f.clock += 1000

	// the wheel, the vertical bar: a press on its track jumps, a drag follows, the caret stays
	long := strings.repeat("line\n", 200)
	defer delete(long)
	start(f, long)
	frame(f, {press({100, 100}), release({100, 100})})
	f.clock += 1000
	c := f.area.cursor
	wheel := []platform.Event{{kind = .Scroll, pos = {100, 100}, delta = {0, 1}}}
	before := f.area.scroll.y
	frame(f, wheel)
	testing.expect(t, f.area.scroll.y > before, "the wheel scrolls")
	d := (^ui.Text_Edit_Draw)(f.res.box.custom_user)
	testing.expect(t, d.bars.has_v && !d.bars.has_h, "a vertical bar")
	testing.expect_value(t, d.bars.vtrack, ui.Rect{{289, 3}, {297, 197}})
	testing.expect_value(t, d.bars.vthumb.max.y - d.bars.vthumb.min.y, 24)   // (the least: the text is far longer than the view)
	bar: ui.Vec2 = {f.res.box.rect.max.x - 6, f.res.box.rect.max.y - 8}
	frame(f, {press(bar)})
	far := f.area.scroll.y
	testing.expect(t, far > 1000, "a press on the track jumps")
	testing.expect_value(t, f.area.cursor, c)
	frame(f, {move_to({bar.x, f.res.box.rect.min.y})})
	testing.expect(t, f.area.scroll.y < far, "the drag follows")
	frame(f, {release({bar.x, f.res.box.rect.min.y})})
	testing.expect_value(t, f.area.cursor, c)
	f.clock += 1000

	// the horizontal bar
	wide := strings.repeat("w", 400)
	defer delete(wide)
	start(f, wide)
	frame(f, {press({100, 100}), release({100, 100})})
	f.clock += 1000
	tap(f, .Home, {.Ctrl})
	testing.expect_value(t, f.area.scroll.x, 0)
	c = f.area.cursor
	hbar: ui.Vec2 = {f.res.box.rect.max.x - 20, f.res.box.rect.max.y - 6}
	frame(f, {press(hbar)})
	testing.expect(t, f.area.scroll.x > 100, "a press on the track jumps")
	testing.expect_value(t, f.area.cursor, c)
	frame(f, {release(hbar)})
	f.clock += 1000

	// the paragraph under the pointer, with a classifier
	h := ui.Text_Highlight{}
	f.highlight = &h
	start(f, "a\nb\nc")
	testing.expect_value(t, f.res.hover_line, -1)
	frame(f, {move_to(point(f, 2, 2, 1))})
	frame(f)
	testing.expect_value(t, f.res.hover_line, 1)
	f.highlight = nil
}

// What a screen reader asks: text over the selection (an undo step), the caret by text run.
@(test)
text_edit_screen_reader :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "fonts") { return }
	defer close(f)
	start(f, "one two")
	tap(f, .Home, {.Ctrl})
	tap(f, .Right, {.Ctrl, .Shift})
	b := f.res.box
	ui.a11y_inject(&f.s, {action = .Replace_Selected_Text, data = .Value, value = "ONE", target = u64(b.key)})
	frame(f)
	testing.expect_value(t, text(f), "ONE two")
	testing.expect(t, f.res.changed, "changed")
	tap(f, .Z, {.Ctrl})
	testing.expect_value(t, text(f), "one two")
	run := ui.a11y_run_id(b, 0)
	ui.a11y_inject(&f.s, {action = .Set_Text_Selection, data = .Text_Selection, sel = {run, 1, run, 4}, target = u64(b.key)})
	frame(f)
	expect_caret(t, f, 4, 1)
}
