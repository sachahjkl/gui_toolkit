// Selection of text outside fields: a drag across a label, a paragraph and a rich paragraph, words and paragraphs by
// double / triple click, Shift+click, Shift+arrows, Ctrl+C, a press elsewhere, links, the text cursor, the change
// notifications, and what is drawn.
package keyboard_test

import "core:strings"
import "core:sync"
import "core:testing"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

@(private = "file") SIZE :: [2]int{460, 300}
@(private = "file") lock: sync.Mutex
@(private = "file") clip: string

@(private = "file")
Sx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	theme: ui.Theme,
	s:     ui.State,
	ui_font: font.Font_Id,
	link:  ui.Rich_Result,
	clicks: int,
}

PARA :: "The paragraph wraps across several lines in this narrow box, so that a drag can end in its middle."
RICH := []ui.Rich_Run{{text = "Rich "}, {text = "bold", style = {bold = true}}, {text = " and a "}, {text = "link", style = {link = "x"}}, {text = "."}}

// the builds' clock, 16 ms a frame: a double click is two frames apart however slow the frames are
@(private = "file", thread_local) clock_ms: f64

@(private = "file")
frame :: proc(f: ^Sx, events: []platform.Event = nil, draw_it := false) -> []u8 {
	clock_ms += 16
	ui.begin_build(&f.s, {
		window_size = {f32(SIZE.x), f32(SIZE.y)}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		time_ms = clock_ms,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
		clipboard_get = proc() -> string { return clip },
		clipboard_set = proc(t: string) { delete(clip); clip = strings.clone(t) },
	})
	ui.next({fixed_x = 10, fixed_y = 10, flags = {.Selectable}})
	ui.label("Hello world###l")
	ui.next({fixed_x = 10, fixed_y = 50, width = ui.px(200), flags = {.Selectable}})
	ui.paragraph(PARA + "###p")
	ui.next({fixed_x = 10, fixed_y = 200, width = ui.px(300), flags = {.Selectable}})
	f.link = ui.rich_paragraph("###r", RICH)
	ui.next({fixed_x = 330, fixed_y = 10, width = ui.px(100)})
	if ui.button("Copy###b").clicked { f.clicks += 1 }
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

@(private = "file") press :: proc(p: [2]f32, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Mouse_Press, pos = p, button = .Left, mods = mods} }
@(private = "file") release :: proc(p: [2]f32) -> platform.Event { return {kind = .Mouse_Release, pos = p, button = .Left} }
@(private = "file") move :: proc(p: [2]f32) -> platform.Event { return {kind = .Mouse_Move, pos = p} }
@(private = "file") box :: proc(id: string) -> ^ui.Box { return ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), id)) }

@(test)
selection_across_boxes :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Sx)
	defer free(f)
	if !testing.expect(t, render.init_offscreen(&f.r, SIZE, warp = true), "WARP") { free(f); return }
	font.init(&f.fonts)
	f.ui_font, _ = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&f.s, &f.fonts, &f.theme)
	defer { ui.destroy(&f.s); ui.theme_destroy(&f.theme); draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts); delete(clip); clip = "" }
	plain := frame(f, draw_it = true)
	defer delete(plain)
	delete(frame(f))
	l, p, r := box("###l"), box("###p"), box("###r")
	if !testing.expect(t, l != nil && p != nil && r != nil, "built") { return }
	start := [2]f32{l.rect.min.x + 6.5, (l.rect.min.y + l.rect.max.y) * 0.5}
	mid := [2]f32{(p.rect.min.x + p.rect.max.x) * 0.5, (p.rect.min.y + p.rect.max.y) * 0.5}
	// the text cursor over selectable text
	delete(frame(f, {move(start)}))
	testing.expect_value(t, ui.cursor(&f.s), platform.Cursor.Text)
	// a drag from the label's start into the paragraph's middle
	serial := ui.selection_serial(&f.s)
	delete(frame(f, {press(start)}))
	delete(frame(f, {move(mid)}))
	testing.expect(t, ui.selection_serial(&f.s) != serial && ui.selection_changed(&f.s), "the change is announced")
	delete(frame(f, {release(mid)}))
	got := ui.selected_text(&f.s)
	defer delete(got)
	testing.expectf(t, strings.has_prefix(got, "Hello world\nThe paragraph") && len(got) < len("Hello world\n" + PARA) && strings.has_prefix(PARA, got[len("Hello world\n"):]),
		"label, then the start of the paragraph: %q", got)
	// Ctrl+C copies it
	delete(frame(f, {{kind = .Key_Press, key = .C, mods = {.Ctrl}}}))
	testing.expect_value(t, clip, got)
	// Shift+Right: one character more
	delete(frame(f, {{kind = .Key_Press, key = .Right, mods = {.Shift}}}))
	more := ui.selected_text(&f.s)
	testing.expect_value(t, len(more), len(got) + 1)
	delete(more)
	// Shift+click on the rich paragraph extends to it
	rp := [2]f32{r.rect.min.x + 30, (r.rect.min.y + r.rect.max.y) * 0.5}
	delete(frame(f, {press(rp, {.Shift})}))
	delete(frame(f, {release(rp)}))
	ext := ui.selected_text(&f.s, context.temp_allocator)
	testing.expectf(t, strings.has_prefix(ext, "Hello world\n" + PARA + "\nRi"), "extended into the rich paragraph: %q", ext)
	// what is drawn: only the selection changes the picture, inside the boxes' text
	sel := frame(f, draw_it = true)
	defer delete(sel)
	changed, outside := 0, 0
	for y in 0 ..< SIZE.y {
		for x in 0 ..< SIZE.x {
			k := (y * SIZE.x + x) * 4
			if sel[k] == plain[k] && sel[k + 1] == plain[k + 1] && sel[k + 2] == plain[k + 2] { continue }
			changed += 1
			q := [2]f32{f32(x), f32(y)}
			in_box := false
			for b in ([]^ui.Box{l, p, r}) { if q.x >= b.rect.min.x && q.x < b.rect.max.x && q.y >= b.rect.min.y && q.y < b.rect.max.y { in_box = true } }
			if !in_box { outside += 1 }
		}
	}
	testing.expectf(t, changed > 500 && outside == 0, "the selection is drawn in the boxes (%d pixels, %d outside)", changed, outside)
	// a press on the button keeps the selection (an app's Copy button reads it on release)
	bp := [2]f32{380, 25}
	delete(frame(f, {press(bp)}))
	delete(frame(f, {release(bp)}))
	testing.expect(t, ui.has_selection(&f.s) && f.clicks == 1, "the button clicked, the selection kept")
	// double click: a word; triple click: the paragraph
	wp := [2]f32{p.rect.min.x + 10, p.rect.min.y + 12}
	delete(frame(f, {press(wp), release(wp)}))
	delete(frame(f, {press(wp), release(wp)}))
	testing.expect_value(t, ui.selected_text(&f.s, context.temp_allocator), "The")
	delete(frame(f, {press(wp), release(wp)}))
	testing.expect_value(t, ui.selected_text(&f.s, context.temp_allocator), PARA)
	// a press on nothing: no selection
	delete(frame(f, {press({440, 280}), release({440, 280})}))
	testing.expect(t, !ui.has_selection(&f.s), "cleared")
	// a press on a link clicks it and selects nothing
	ll := ui.rich_layout_cached(RICH, {fonts = &f.fonts, base_font = f.ui_font, base_size = 15, faces = &f.s.rich_faces}, r.size.x - 12)
	lr := ui.rich_range_rects(ll, &f.fonts, RICH, 16, 20)
	lp := r.rect.min + {6, 6} + (lr[0].min + lr[0].max) * 0.5
	delete(frame(f, {move(lp)}))
	testing.expect_value(t, ui.cursor(&f.s), platform.Cursor.Hand)
	delete(frame(f, {press(lp)}))
	delete(frame(f, {release(lp)}))
	testing.expect(t, f.link.link_clicked == 3 && !ui.has_selection(&f.s), "the link, not a selection")
}
