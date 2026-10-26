// rich_paragraph: the layout of mixed runs (breaks on the whole text, "\n", long words, max_lines and "…",
// alignment), its geometry (hit test, carets, ranges, links), the cache, links by pointer and keyboard, and drawing.
package keyboard_test

import "core:strings"
import "core:sync"
import "core:testing"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

@(private = "file")
Rx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	theme: ui.Theme,
	s:     ui.State,
	ui_font, mono: font.Font_Id,
	runs:  []ui.Rich_Run,
	res:   ui.Rich_Result,
	width: f32,
	max_lines: int,
}

@(private = "file") SIZE :: [2]int{420, 240}
@(private = "file") lock: sync.Mutex

@(private = "file")
open :: proc(f: ^Rx) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true) { return false }
	font.init(&f.fonts)
	ok, ok2: bool
	f.ui_font, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	f.mono, ok2 = font.load_embedded(&f.fonts, font.FALLBACK_MONO_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.s.mono_font = f.mono
	return ok && ok2
}

@(private = "file")
close :: proc(f: ^Rx) {
	ui.destroy(&f.s); ui.theme_destroy(&f.theme)
	draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts)
}

@(private = "file")
ctx :: proc(f: ^Rx) -> ui.Rich_Context { return {fonts = &f.fonts, base_font = f.ui_font, base_size = 15, mono = f.mono} }

@(private = "file")
frame :: proc(f: ^Rx, events: []platform.Event = nil, draw_it := false) -> []u8 {
	ui.begin_build(&f.s, {
		window_size = {f32(SIZE.x), f32(SIZE.y)}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
	})
	ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(f.width)})
	f.res = ui.rich_paragraph("###rich", f.runs, f.max_lines)
	ui.end_build()
	px: []u8
	if draw_it {
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		render.frame_begin(&f.r, {0, 0, 0, 1})
		ui.draw_tree(&f.s, &f.dc)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		px = render.read_pixels(&f.r, context.allocator)
	}
	free_all(context.temp_allocator)
	return px
}

@(private = "file")
RUNS := []ui.Rich_Run{
	{text = "Rich text mixes "},
	{text = "bold", style = {bold = true}},
	{text = ", "},
	{text = "italic", style = {italic = true}},
	{text = " and "},
	{text = "inline code", style = {code = true}},
	{text = " with "},
	{text = "a link", style = {link = "https://example.org"}},
	{text = " in one para"},
	{text = "graph", style = {underline = true}},
	{text = " that wraps.\nA second paragraph."},
}

@(test)
rich_layout_breaks_across_runs :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Rx)
	defer free(f)
	if !testing.expect(t, open(f), "renderer and fonts") { close(f); return }
	defer close(f)
	frame(f)   // the ui state is current (faces of bold / italic runs)
	text := ui.rich_text(RUNS)
	W :: f32(180)
	l := ui.rich_layout(ctx(f), RUNS, W)
	defer ui.rich_layout_destroy(&l)
	testing.expect(t, len(l.lines) >= 4, "wrapped")
	for li, i in l.lines {
		testing.expectf(t, li.width <= W + 0.01, "line %d fits (%v)", i, li.width)
		if i > 0 { testing.expect(t, li.start >= l.lines[i - 1].end, "lines in order") }
	}
	// "paragraph" is two runs ("para" + underlined "graph"): never broken between them
	pi := strings.index(text, "paragraph")
	for li in l.lines { testing.expect(t, !(li.start > pi && li.start < pi + len("paragraph")), "no break inside a word made of two runs") }
	// "\n": the second paragraph starts a line
	nl := strings.index_byte(text, '\n')
	found := false
	for li in l.lines { if li.start == nl + 1 { found = true } }
	testing.expect(t, found, "a line starts after the new line")
	testing.expect_value(t, l.lines[len(l.lines) - 1].end, len(text))
	// pieces are in their runs, in order, the bold run in another face than the regular one
	for li in l.lines {
		for k in li.first ..< li.first + li.count {
			fr := l.frags[k]
			testing.expect(t, fr.start < fr.end && fr.end <= len(RUNS[fr.run].text), "pieces inside their runs")
			if fr.run == 1 { testing.expect(t, fr.face != f.ui_font, "bold face") }
			if fr.run == 5 { testing.expect_value(t, fr.face, f.mono) }
		}
	}
	// hit test and carets agree on every grapheme boundary of the first line
	l0 := l.lines[0]
	for i := l0.start; i <= l0.end; i += 1 {
		if !font.is_grapheme_boundary(text, i) { continue }
		line, x := ui.rich_caret(&l, &f.fonts, RUNS, i, upstream = i == l0.end)   // the line's end is also the next one's start
		testing.expect_value(t, line, 0)
		got := ui.rich_index_at(&l, &f.fonts, RUNS, {x, l0.y + 2})
		testing.expectf(t, got == i, "caret %d at x %v hits %d", i, x, got)
	}
	// a range across runs and lines: rectangles on each line it touches
	rects := ui.rich_range_rects(&l, &f.fonts, RUNS, 5, len(text) - 5)
	testing.expect(t, len(rects) >= len(l.lines), "rectangles on every line")
	// the link run under its own rectangle
	li := strings.index(text, "a link")
	lr := ui.rich_range_rects(&l, &f.fonts, RUNS, li, li + 6)
	testing.expect(t, len(lr) > 0 && ui.rich_link_at(&l, RUNS, (lr[0].min + lr[0].max) * 0.5) == 7, "link hit")
	testing.expect_value(t, ui.rich_link_at(&l, RUNS, {1, l.lines[0].y + 2}), -1)
	// no width: only "\n" breaks
	nw := ui.rich_layout(ctx(f), RUNS, 0)
	defer ui.rich_layout_destroy(&nw)
	testing.expect_value(t, len(nw.lines), 2)
}

@(test)
rich_layout_limits_and_alignment :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Rx)
	defer free(f)
	if !testing.expect(t, open(f), "renderer and fonts") { close(f); return }
	defer close(f)
	frame(f)
	W :: f32(160)
	two := ui.rich_layout(ctx(f), RUNS, W, max_lines = 2)
	defer ui.rich_layout_destroy(&two)
	testing.expect_value(t, len(two.lines), 2)
	testing.expect(t, two.truncated && two.lines[1].ellipsis_x > 0, "\"…\" on the last line")
	testing.expectf(t, two.lines[1].width <= W + 0.01, "the line with its ellipsis fits (%v)", two.lines[1].width)
	// a word wider than the line: cut between clusters, nothing lost
	long := []ui.Rich_Run{{text = "Pneumonoultramicroscopicsilicovolcanoconiosis"}, {text = "AndMoreOfIt", style = {bold = true}}}
	ll := ui.rich_layout(ctx(f), long, 120)
	defer ui.rich_layout_destroy(&ll)
	testing.expect(t, len(ll.lines) >= 2, "a long word is cut")
	total := 0
	for li in ll.lines { testing.expect(t, li.width <= 120.01, "pieces fit"); total += li.end - li.start }
	testing.expect_value(t, total, len(ui.rich_text(long)))
	// alignment: right lines end at the width, centred ones sit in the middle
	short := []ui.Rich_Run{{text = "short"}}
	r := ui.rich_layout(ctx(f), short, 300, align = .Right)
	defer ui.rich_layout_destroy(&r)
	fr := r.frags[0]
	testing.expectf(t, abs(fr.x + fr.width - 300) < 1, "right aligned (%v)", fr.x + fr.width)
	cl := ui.rich_layout(ctx(f), short, 300, align = .Center)
	defer ui.rich_layout_destroy(&cl)
	testing.expectf(t, abs(cl.frags[0].x - (300 - cl.frags[0].width) * 0.5) < 1, "centred")
	// thousands of runs: laid out once, then from the cache
	many := make([]ui.Rich_Run, 3000)
	defer delete(many)
	words := []string{"alpha ", "beta ", "gamma ", "delta "}
	for &m, i in many { m.text = words[i % 4]; m.bold = i % 3 == 0; m.color = i % 5 == 0 ? ui.Color{1, 0, 0, 1} : {} }
	c := ctx(f)
	a := ui.rich_layout_cached(many, c, 400)
	n := ui.rich_cache_len(&f.s)
	b := ui.rich_layout_cached(many, c, 400)
	testing.expect(t, a == b && ui.rich_cache_len(&f.s) == n, "the same layout from the cache")
	testing.expect(t, len(a.lines) > 50 && a.lines[len(a.lines) - 1].end == len(ui.rich_text(many)), "all laid out")
}

@(test)
rich_links_pointer_keyboard_and_drawing :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Rx)
	defer free(f)
	if !testing.expect(t, open(f), "renderer and fonts") { close(f); return }
	defer close(f)
	f.runs, f.width = RUNS, 220
	delete(frame(f, draw_it = true))
	delete(frame(f, draw_it = true))
	b := ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###rich"))
	if !testing.expect(t, b != nil, "built") { return }
	text := ui.rich_text(RUNS)
	l := ui.rich_layout_cached(RUNS, {fonts = &f.fonts, base_font = f.ui_font, base_size = 15, mono = f.mono, faces = &f.s.rich_faces}, b.size.x - 12)
	testing.expectf(t, abs(b.size.y - (l.size.y + 12)) < 1, "as tall as its lines (%v, %v)", b.size.y, l.size.y)
	li := strings.index(text, "a link")
	lr := ui.rich_range_rects(l, &f.fonts, RUNS, li, li + 6)
	p := b.rect.min + {6, 6} + (lr[0].min + lr[0].max) * 0.5
	delete(frame(f, {{kind = .Mouse_Move, pos = p}}))
	testing.expect_value(t, f.res.link_hovered, 7)
	testing.expect_value(t, ui.cursor(&f.s), platform.Cursor.Hand)
	delete(frame(f, {{kind = .Mouse_Press, pos = p, button = .Left}}))
	delete(frame(f, {{kind = .Mouse_Release, pos = p, button = .Left}}))
	testing.expect(t, f.res.link_clicked == 7 && f.res.link == "https://example.org", "clicked")
	// keyboard: the paragraph is a Tab stop, Enter chooses its link
	delete(frame(f, {{kind = .Mouse_Move, pos = {400, 230}}}))
	delete(frame(f, {{kind = .Key_Press, key = .Tab}}))
	delete(frame(f))
	testing.expect_value(t, f.res.link_focused, 7)
	delete(frame(f, {{kind = .Key_Press, key = .Return}}))
	testing.expect_value(t, f.res.link_clicked, 7)
	// drawing: the inline code's background and the underline of the link are there
	px := frame(f, draw_it = true)
	defer delete(px)
	ci := strings.index(text, "inline code")
	cr := ui.rich_range_rects(l, &f.fonts, RUNS, ci, ci + 2)
	lit := 0
	o := b.rect.min + {6, 6}
	for y in int(o.y + cr[0].min.y) ..< int(o.y + cr[0].max.y) {
		x := int(o.x + cr[0].min.x) + 1
		k := (y * SIZE.x + x) * 4
		if int(px[k]) + int(px[k + 1]) + int(px[k + 2]) > 30 { lit += 1 }
	}
	testing.expectf(t, lit > 4, "the code background is drawn (%d lit pixels)", lit)
	// the underline: a row under the letters lit across the link's width (letters leave gaps; the line does not)
	best := 0
	span := int(lr[0].max.x - lr[0].min.x) - 4
	for y in int(o.y + lr[0].min.y) ..< int(o.y + lr[0].max.y) + 2 {
		row := 0
		for x in int(o.x + lr[0].min.x) + 2 ..< int(o.x + lr[0].max.x) - 2 {
			k := (y * SIZE.x + x) * 4
			if int(px[k]) + int(px[k + 1]) + int(px[k + 2]) > 120 { row += 1 }
		}
		best = max(best, row)
	}
	testing.expectf(t, best >= span * 9 / 10, "the link is underlined (best row %d of %d)", best, span)
}
