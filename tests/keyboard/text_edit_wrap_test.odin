// text_edit with wrap and auto_height: visual lines, the caret at the end of a wrapped line, Up / Down / Home / End on
// visual lines, the height within its limits, the caret rectangle.
package keyboard_test

import "core:strings"
import "core:sync"
import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

@(private = "file")
Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	ui_font: font.Font_Id,
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.ui_font = id
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

@(private = "file")
Run :: struct {
	area:   ui.Text_Area,
	width:  f32,
	min_l, max_l: int,
	res:    ui.Edit_Result,
}

@(private = "file")
build :: proc(r: ^Run) {
	ui.next({width = ui.px(r.width), height = ui.px(40)})
	r.res = ui.text_edit("###w", &r.area, wrap = true, auto_height = true, min_lines = r.min_l, max_lines = r.max_l)
}

@(private = "file")
frame :: proc(f: ^Fx, r: ^Run, events: []platform.Event = nil) {
	ui.begin_build(&f.s, {
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
	})
	build(r)
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

@(private = "file")
the_box :: proc() -> ^ui.Box { return ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###w")) }

@(private = "file")
lock: sync.Mutex

@(test)
visual_lines_break_and_fit :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	W :: f32(120)
	measure :: proc(f: ^Fx, s: string) -> f32 { return font.measure(&f.fonts, f.ui_font, 15, s) }
	// words: every line fits without its trailing spaces, the spaces stay on their line, nothing is lost
	text := "The quick brown fox jumps over the lazy dog again and again"
	lines := ui.text_visual_lines(&f.fonts, f.ui_font, 15, text, W)
	testing.expect(t, len(lines) >= 3, "wrapped")
	for l, i in lines {
		testing.expectf(t, measure(&f, strings.trim_right(text[l.start:l.end], " ")) <= W + 0.01, "line %d fits", i)
		if i + 1 < len(lines) {
			testing.expect(t, l.soft && l.next == lines[i + 1].start && l.end == l.next, "wrapped lines follow each other")
			testing.expect(t, text[l.end - 1] == ' ', "a line ends after its space")
		}
	}
	testing.expect_value(t, lines[0].start, 0)
	testing.expect_value(t, lines[len(lines) - 1].end, len(text))
	// a word wider than the line: cut between grapheme clusters, none lost, none empty
	long := "Supercalifragilisticexpialidocious_and_more_without_any_space"
	ll := ui.text_visual_lines(&f.fonts, f.ui_font, 15, long, W)
	testing.expect(t, len(ll) >= 2, "a long word is cut")
	for l in ll { testing.expect(t, l.end > l.start && measure(&f, long[l.start:l.end]) <= W + 0.01, "each piece fits") }
	// a cluster is never cut (a letter with its mark)
	marks := strings.repeat("e\u0301", 40, context.temp_allocator)
	for l in ui.text_visual_lines(&f.fonts, f.ui_font, 15, marks, W) { testing.expect(t, l.start % 3 == 0, "cut between clusters") }
	// paragraphs: "\n" always breaks; an empty paragraph is a line
	pl := ui.text_visual_lines(&f.fonts, f.ui_font, 15, "a\n\nb", W)
	testing.expect_value(t, len(pl), 3)
	testing.expect(t, pl[1].start == 2 && pl[1].end == 2 && !pl[1].soft && pl[2].first && pl[2].para == 2, "empty paragraph")
	// no width: one line per paragraph
	testing.expect_value(t, len(ui.text_visual_lines(&f.fonts, f.ui_font, 15, text, 0)), 1)
	// the caret's line at a wrap: downstream (the next line) unless upstream
	testing.expect_value(t, ui.visual_line_of(lines, lines[0].end), 1)
	testing.expect_value(t, ui.visual_line_of(lines, lines[0].end, true), 0)
}

@(test)
wrapped_editor_keys_height_and_caret :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Run{width = 150, min_l = 2, max_l = 4}
	defer ui.area_destroy(&r.area)
	m := font.metrics(&f.fonts, f.ui_font, 15)
	lh := f32(int(m.line_height * 1.15 + 0.5))
	frame(&f, &r)
	frame(&f, &r)
	b := the_box()
	if !testing.expect(t, b != nil, "built") { return }
	testing.expectf(t, abs(b.size.y - (2 * lh + 12)) < 1, "empty: min_lines tall (%v)", b.size.y)
	ui.set_focus(b.key)
	ui.area_set(&r.area, "one two three four five six seven eight nine ten eleven twelve thirteen")
	r.area.cursor, r.area.mark = 0, 0
	frame(&f, &r)
	frame(&f, &r)
	lines := ui.text_visual_lines(&f.fonts, f.ui_font, 15, ui.area_string(&r.area), 150 - 12, context.allocator)
	defer delete(lines)
	testing.expect(t, len(lines) >= 3, "several visual lines")
	want := min(len(lines), 4)
	testing.expectf(t, abs(the_box().size.y - (f32(want) * lh + 12)) < 1, "as tall as its lines, at most max_lines (%v for %d lines)", the_box().size.y, len(lines))
	// End: the end of the first visual line, the caret stays on it (after its space)
	frame(&f, &r, {key(.End)})
	testing.expect_value(t, r.area.cursor, lines[0].end)
	testing.expect(t, r.area.upstream, "at the end of the wrapped line")
	testing.expectf(t, r.res.caret.min.y < lh, "caret on the first line (y %v)", r.res.caret.min.y)
	// Home comes back
	frame(&f, &r, {key(.Home)})
	testing.expect_value(t, r.area.cursor, 0)
	// Down: the second visual line, same column; Up: back
	frame(&f, &r, {key(.Right)})
	frame(&f, &r, {key(.Right)})
	frame(&f, &r, {key(.Down)})
	testing.expectf(t, r.area.cursor > lines[1].start && r.area.cursor < lines[1].end, "down a visual line (%d in %v)", r.area.cursor, lines[1])
	testing.expectf(t, abs(r.res.caret.min.y - (6 + lh)) < 1, "caret one line down (y %v)", r.res.caret.min.y)
	frame(&f, &r, {key(.Up)})
	testing.expect_value(t, r.area.cursor, 2)
	// the caret rectangle as drawn: window coordinates (no draw in this test: nothing yet)
	_, _, drawn := ui.text_edit_caret_rect(&r.area)
	testing.expect(t, !drawn, "not drawn without a renderer")
	// Ctrl+End: the last line, scrolled into view within max_lines
	frame(&f, &r, {key(.End, {.Ctrl})})
	testing.expect_value(t, r.area.cursor, len(ui.area_string(&r.area)))
	if len(lines) > 4 { testing.expect(t, r.area.scroll.y > 0, "scrolls past max_lines") }
}
