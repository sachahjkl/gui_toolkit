// A selecting drag held near or past the edge of a scroll view scrolls it (ui/drag_autoscroll.odin): the speed curve,
// then builds without a window: a long text in a scroll view and in a text_edit, dragged from a line past the bottom
// edge, scroll each frame, and the selection reaches a line that was off screen; the release stops it; the band is
// slower than past the edge. The ui state of a build is global: one test thread.
//   odin run tools/run_tests -- drag_autoscroll
package drag_autoscroll_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:font"
import "gt:platform"
import "gt:ui"

@(private = "file") WINDOW :: ui.Vec2{400, 400}
@(private = "file") VIEW_H :: 200   // the scroll view's height, at the window's top
@(private = "file") LINES :: 40
@(private = "file") FRAMES_MAX :: 400   // a bound on every wait

////////////////////////////////
// The curve

@(test)
speed_curve :: proc(t: ^testing.T) {
	band: f32 = 24
	lo, hi: f32 = 0, 200
	testing.expect_value(t, ui.drag_autoscroll_speed(100, lo, hi, band), 0)
	testing.expect_value(t, ui.drag_autoscroll_speed(hi - band, lo, hi, band), 0)
	in_band := ui.drag_autoscroll_speed(hi - 4, lo, hi, band)
	at_edge := ui.drag_autoscroll_speed(hi, lo, hi, band)
	past := ui.drag_autoscroll_speed(hi + 100, lo, hi, band)
	far := ui.drag_autoscroll_speed(hi + 5000, lo, hi, band)
	testing.expectf(t, 0 < in_band && in_band < at_edge && at_edge < past && past < far, "grows: %v %v %v %v", in_band, at_edge, past, far)
	testing.expect_value(t, far, ui.DRAG_AUTOSCROLL.max_speed)
	testing.expect_value(t, ui.drag_autoscroll_speed(lo + 4, lo, hi, band), -in_band)
	// a view smaller than two bands: each band is half of it, and its middle does not scroll
	testing.expect_value(t, ui.drag_autoscroll_speed(10, 0, 20, band), 0)
	testing.expect(t, ui.drag_autoscroll_speed(19, 0, 20, band) > 0)
	testing.expect_value(t, ui.drag_autoscroll_speed(5, 10, 10, band), 0)
}

////////////////////////////////
// Builds

@(private = "file")
Fx :: struct {
	fonts:     font.State,
	theme:     ui.Theme,
	s:         ui.State,
	ui_font:   font.Font_Id,
	clock:     f64,
	editor:    bool,                // build the text_edit (else the selectable lines)
	view:      ^ui.Box,             // the scroll view of the lines
	lines:     [LINES]^ui.Box,
	te:        ui.Text_Edit,
	te_box:    ^ui.Box,
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.ui_font = id
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.text_edit_destroy(&f.te)
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event = nil) {
	f.clock += 16
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1, time_ms = f.clock,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
	})
	if f.editor {
		ui.next({width = ui.px(300), height = ui.px(VIEW_H)})
		f.te_box = ui.text_edit("###te", &f.te).box
	} else {
		ui.next({width = ui.fill(), height = ui.px(VIEW_H)})
		if ui.scroll_y("###view") {
			for i in 0 ..< LINES {
				ui.next({flags = {.Selectable}})
				f.lines[i] = ui.label(fmt.tprintf("line %d###l%d", i, i)).box
			}
		}
		f.view = f.lines[0].parent
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file") press :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Press, pos = p, button = .Left} }
@(private = "file") release :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Release, pos = p, button = .Left} }
@(private = "file") move :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Move, pos = p} }

@(private = "file")
line_at :: proc(f: ^Fx, i: int) -> ui.Vec2 {
	r := f.lines[i].rect
	return {r.min.x + 4, (r.min.y + r.max.y) * 0.5}
}

// Frames with the pointer held still, until `done` or the bound; the number of frames, -1 at the bound.
@(private = "file")
frames_until :: proc(f: ^Fx, done: proc(f: ^Fx) -> bool) -> int {
	for n in 0 ..< FRAMES_MAX {
		if done(f) { return n }
		frame(f)
	}
	return -1
}

@(test)
selection_past_the_bottom_scrolls :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "the embedded face") { return }
	defer close(f)
	frame(f)
	frame(f)
	if !testing.expect(t, f.view != nil && .View_Scroll_Y in f.view.flags, "the scroll view") { return }
	far := f.lines[30]
	testing.expect(t, far.rect.min.y > VIEW_H, "line 30 is off screen at the start")
	start := line_at(f, 1)
	frame(f, {press(start)})
	frame(f, {move({start.x, VIEW_H + 150})})
	// frames come while the drag is held, the view scrolls, and the selection reaches line 30
	testing.expect(t, ui.needs_frame(&f.s), "a frame is asked for")
	n := frames_until(f, proc(f: ^Fx) -> bool {
		got := ui.selected_text(&f.s, context.temp_allocator)
		return strings.contains(got, "line 30")
	})
	testing.expectf(t, n > 0, "the selection reached line 30 (frames: %d)", n)
	testing.expect(t, f.view.view_target.y > 0, "the view scrolled")
	got := ui.selected_text(&f.s, context.temp_allocator)
	testing.expectf(t, strings.has_prefix(got, "line 1\nline 2\n"), "from the line pressed: %q", got)
	// the release stops it
	frame(f, {release({start.x, VIEW_H + 150})})
	at := f.view.view_target.y
	for _ in 0 ..< 10 { frame(f) }
	testing.expect_value(t, f.view.view_target.y, at)
	// the end of the view stops it too: dragged on, the target stays at the limit
	p := ui.Vec2{start.x, f.view.rect.min.y + 15}   // (on a line shown, wherever the view is)
	frame(f, {press(p)})
	frame(f, {move({p.x, VIEW_H + 150})})
	for _ in 0 ..< FRAMES_MAX {
		if f.view.view_target.y >= ui.view_limit(f.view) { break }
		frame(f)
	}
	testing.expect_value(t, f.view.view_target.y, ui.view_limit(f.view))
	frame(f)
	testing.expect_value(t, f.view.view_target.y, ui.view_limit(f.view))
	last := ui.selected_text(&f.s, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(last, fmt.tprintf("line %d", LINES - 1)), "to the last line: %q", last)
	frame(f, {release({p.x, VIEW_H + 150})})
}

@(test)
band_slower_than_past_the_edge :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "the embedded face") { return }
	defer close(f)
	frame(f)
	frame(f)
	// `below`: the pointer's distance under the view's bottom edge (negative: above it, inside the view)
	travel :: proc(f: ^Fx, line: int, below: f32) -> f32 {
		ui.view_jump(f.view, 0)
		frame(f)
		p := line_at(f, line)
		y := f.view.rect.max.y + below
		frame(f, {press(p)})
		frame(f, {move({p.x, y})})
		from := f.view.view_target.y
		for _ in 0 ..< 10 { frame(f) }
		d := f.view.view_target.y - from
		frame(f, {release({p.x, y})})
		for _ in 0 ..< 40 { frame(f) }   // (the next press is no double click)
		return d
	}
	inside := travel(f, 1, -4)         // in the band, 4 px from the edge
	still := travel(f, 2, -VIEW_H / 2) // between the bands
	past := travel(f, 3, 60)           // 60 px past the edge
	testing.expectf(t, 0 < inside && inside < past, "the band scrolls slower than past the edge: %v < %v", inside, past)
	testing.expect_value(t, still, 0)
}

@(test)
text_edit_selection_past_the_bottom :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f), "the embedded face") { return }
	defer close(f)
	f.editor = true
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 60 { fmt.sbprintf(&sb, "row %d\n", i) }
	ui.text_edit_set(&f.te, strings.to_string(sb))
	frame(f)
	frame(f)
	r := f.te_box.rect
	start := r.min + {20, 12}
	frame(f, {press(start)})
	frame(f, {move({start.x, r.max.y + 150})})
	target := strings.index(string(f.te.buf[:]), "row 30")
	n := frames_until(f, proc(f: ^Fx) -> bool { return f.te.cursor >= strings.index(string(f.te.buf[:]), "row 30") })
	testing.expectf(t, n > 0, "the caret reached row 30 (at %d, frames: %d)", target, n)
	testing.expect(t, f.te.scroll.y > 0, "the editor scrolled")
	testing.expect(t, f.te.mark < 8, "the selection starts on the first row")
	frame(f, {release({start.x, r.max.y + 150})})
	at := f.te.scroll.y
	for _ in 0 ..< 10 { frame(f) }
	testing.expect_value(t, f.te.scroll.y, at)
}
