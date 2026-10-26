// The splitter and the accordion (ui/split.odin): dragging within the limits of both panes, the pane after the handle,
// a double click and Enter back to the default, the arrow keys, the cursor, no frame at rest; folding and unfolding
// with an animated height, the keyboard, content built only while visible; what is drawn.
//   odin test tests/panes -vet -define:ODIN_TEST_THREADS=1
package panes_test

import "core:testing"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

@(private = "file") SIZE :: [2]int{400, 240}

@(private = "file")
Fx :: struct {
	r:       render.Renderer,
	drawing: bool,
	fonts:   font.State,
	dc:      draw.Context,
	theme:   ui.Theme,
	s:       ui.State,
	ui_font: font.Font_Id,
	// what the frame builds
	size:    f32,
	opts:    ui.Splitter_Options,
	res:     ui.Splitter_Result,
	open:    bool,
	content_built: bool,
	accordion: bool,
	anim:    bool,
}

@(private = "file")
setup :: proc(t: ^testing.T, drawing := false) -> ^Fx {
	f := new(Fx)
	f.drawing = drawing
	if drawing && !testing.expect(t, render.init_offscreen(&f.r, SIZE, warp = true), "WARP") { free(f); return nil }
	font.init(&f.fonts)
	f.ui_font, _ = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if drawing { draw.init(&f.dc, &f.r, &f.fonts) }
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.size = 100
	return f
}

@(private = "file")
teardown :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	if f.drawing { draw.destroy(&f.dc) }
	font.destroy(&f.fonts)
	if f.drawing { render.destroy(&f.r) }
	free(f)
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event = nil) -> []u8 {
	ui.begin_build(&f.s, {
		window_size = {f32(SIZE.x), f32(SIZE.y)}, events = events, dt = 1.0 / 60, animations = f.anim, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
	})
	if f.accordion {
		ui.next({width = ui.px(300)})
		if ui.accordion("###acc", "Details", &f.open) {
			f.content_built = true
			ui.next({width = ui.fill(), height = ui.px(80)})
			ui.label("content###c")
		} else {
			f.content_built = false
		}
	} else {
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.row() {
			ui.next({width = ui.px(f.opts.after ? 0 : f.size), height = ui.fill()})
			ui.build_box({}, "###left")
			if f.opts.after { ui.next({width = ui.fill(), height = ui.fill()}); ui.build_box({}, "###grow") }
			f.res = ui.splitter("###split", .X, &f.size, 50, 300, f.opts)
			ui.next({width = f.opts.after ? ui.px(f.size) : ui.fill(), height = ui.fill()})
			ui.build_box({}, "###right")
		}
	}
	ui.end_build()
	px: []u8
	if f.drawing {
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

@(private = "file") press :: proc(p: [2]f32) -> platform.Event { return {kind = .Mouse_Press, pos = p, button = .Left} }
@(private = "file") release :: proc(p: [2]f32) -> platform.Event { return {kind = .Mouse_Release, pos = p, button = .Left} }
@(private = "file") move :: proc(p: [2]f32) -> platform.Event { return {kind = .Mouse_Move, pos = p} }
@(private = "file") key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

@(private = "file")
split_box :: proc() -> ^ui.Box {
	root := ui.key_from_string(0, "root")
	// (the row is anonymous: the splitter is found by walking the root's first child)
	r := ui.box_from_key(root)
	for c := r.first.first; c != nil; c = c.next { if c.name == "split" { return c } }
	return nil
}

@(test)
splitter_drags_within_limits :: proc(t: ^testing.T) {
	f := setup(t)
	if f == nil { return }
	defer teardown(f)
	f.opts = {total = 400, min_other = 120}
	frame(f)
	frame(f)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	testing.expect_value(t, b.rect.min.x, 100)
	testing.expect_value(t, b.rect.max.x - b.rect.min.x, 5)
	x := (b.rect.min.x + b.rect.max.x) * 0.5
	frame(f, {move({x, 50})})
	testing.expect_value(t, ui.cursor(&f.s), platform.Cursor.Resize_H)
	frame(f, {press({x, 50})})
	testing.expect(t, f.res.dragging)
	frame(f, {move({x + 60, 50})})
	testing.expect_value(t, f.size, 160)
	testing.expect(t, f.res.changed)
	frame(f, {move({x + 500, 50})})
	testing.expect_value(t, f.size, 280)   // the other pane keeps 120 of 400
	testing.expect_value(t, ui.cursor(&f.s), platform.Cursor.Resize_H)   // the pointer is far from the handle
	frame(f, {move({x - 500, 50})})
	testing.expect_value(t, f.size, 50)
	testing.expect(t, !f.res.finished)
	frame(f, {release({x - 500, 50})})
	testing.expect(t, f.res.finished, "the drag ended: persist")
	testing.expect(t, !f.res.dragging)
	frame(f)
	testing.expect(t, !ui.needs_frame(&f.s), "nothing to draw at rest")
}

@(test)
splitter_pane_after_the_handle :: proc(t: ^testing.T) {
	f := setup(t)
	if f == nil { return }
	defer teardown(f)
	f.opts = {after = true}
	frame(f)
	frame(f)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	testing.expect_value(t, b.rect.min.x, 400 - 100 - 5)
	x := (b.rect.min.x + b.rect.max.x) * 0.5
	frame(f, {press({x, 50})})
	frame(f, {move({x - 40, 50})})
	testing.expect_value(t, f.size, 140)   // dragged towards the left: the right pane grows
	frame(f, {release({x - 40, 50})})
}

@(test)
splitter_double_click_and_keys :: proc(t: ^testing.T) {
	f := setup(t)
	if f == nil { return }
	defer teardown(f)
	f.opts = {default_size = 120}
	f.size = 200
	frame(f)
	frame(f)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	x := (b.rect.min.x + b.rect.max.x) * 0.5
	frame(f, {press({x, 50}), release({x, 50})})
	frame(f, {press({x, 50})})
	testing.expect_value(t, f.size, 120)
	frame(f, {move({x + 10, 50})})
	testing.expect_value(t, f.size, 130)   // a move after the double click starts from the default
	frame(f, {release({x + 10, 50})})

	// the click gave it the keyboard focus
	testing.expect_value(t, ui.focus_key(), b.key)
	frame(f, {key(.Right)})
	testing.expect_value(t, f.size, 140)
	frame(f, {key(.Left, {.Ctrl})})
	testing.expect_value(t, f.size, 138)
	frame(f, {key(.End)})
	testing.expect_value(t, f.size, 300)
	frame(f, {key(.Home)})
	testing.expect_value(t, f.size, 50)
	frame(f, {key(.Return)})
	testing.expect_value(t, f.size, 120)
	testing.expect(t, f.res.finished)
	frame(f, {key(.Up)})
	testing.expect_value(t, f.size, 120)   // the other axis' keys are not its own
}

@(test)
splitter_without_keyboard_is_no_tab_stop :: proc(t: ^testing.T) {
	f := setup(t)
	if f == nil { return }
	defer teardown(f)
	f.opts = {no_keyboard = true}
	frame(f)
	frame(f)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	testing.expect(t, .Focusable not_in b.flags)
	x := (b.rect.min.x + b.rect.max.x) * 0.5
	frame(f, {press({x, 50}), release({x, 50})})
	frame(f, {key(.Right)})
	testing.expect_value(t, f.size, 100)
}

@(private = "file")
acc_box :: proc(name: string) -> ^ui.Box {
	k := ui.key_from_string(ui.key_from_string(0, "root"), "###acc")
	switch name {
	case "header": k = ui.key_from_string(k, "###accordion_header")
	case "body":   k = ui.key_from_string(k, "###accordion_body")
	case "outer":
	}
	return ui.box_from_key(k)
}

@(test)
accordion_folds_with_animation :: proc(t: ^testing.T) {
	f := setup(t)
	if f == nil { return }
	defer teardown(f)
	f.accordion = true
	f.anim = true
	frame(f)
	frame(f)
	testing.expect(t, !f.content_built, "closed: the content is not built")
	testing.expect(t, acc_box("body") == nil)
	testing.expect(t, !ui.needs_frame(&f.s))
	h := acc_box("header")
	if !testing.expect(t, h != nil) { return }
	c := (h.rect.min + h.rect.max) * 0.5
	frame(f, {press(c), release(c)})
	testing.expect(t, f.open)
	heights := make([dynamic]f32)   // (not the temporary allocator: each frame frees it)
	defer delete(heights)
	for _ in 0 ..< 120 {
		frame(f)
		if b := acc_box("body"); b != nil { append(&heights, b.size.y) }
		if !ui.needs_frame(&f.s) { break }
	}
	testing.expect(t, !ui.needs_frame(&f.s), "at rest once unfolded")
	testing.expect(t, len(heights) > 3, "several frames of animation")
	for i in 1 ..< len(heights) { testing.expect(t, heights[i] >= heights[i - 1], "grows") }
	if len(heights) > 0 { testing.expect_value(t, heights[len(heights) - 1], 80) }
	if len(heights) > 2 { testing.expectf(t, heights[1] > 0 && heights[1] < 80, "partway: %v", heights[:]) }

	// Space on the focused header folds it; the content is built until it is gone
	testing.expect_value(t, ui.focus_key(), acc_box("header").key)
	frame(f, {key(.Space)})
	testing.expect(t, !f.open)
	frame(f)
	testing.expect(t, f.content_built, "still folding")
	for _ in 0 ..< 120 { frame(f); if !ui.needs_frame(&f.s) { break } }
	frame(f)
	testing.expect(t, !f.content_built, "folded")
	testing.expect(t, !ui.needs_frame(&f.s))
	frame(f, {key(.Return)})
	testing.expect(t, f.open, "Enter unfolds")
}

@(test)
accordion_without_animation_jumps :: proc(t: ^testing.T) {
	f := setup(t)
	if f == nil { return }
	defer teardown(f)
	f.accordion = true
	f.open = true
	frame(f)
	frame(f)
	b := acc_box("body")
	if testing.expect(t, b != nil) { testing.expect_value(t, b.size.y, 80) }
	f.open = false
	frame(f)
	testing.expect(t, !f.content_built)
}

@(private = "file")
pixel :: proc(px: []u8, x, y: int) -> [4]u8 {
	p := px[(y * SIZE.x + x) * 4:]
	return {p[0], p[1], p[2], p[3]}
}

@(test)
splitter_draws_a_rule :: proc(t: ^testing.T) {
	f := setup(t, true)
	if f == nil { return }
	defer teardown(f)
	delete(frame(f))
	px := frame(f)
	defer delete(px)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	x := int((b.rect.min.x + b.rect.max.x) * 0.5)
	rest := pixel(px, x, 100)
	beside := pixel(px, x + 2, 100)
	testing.expect(t, rest != beside, "a rule in the middle of the handle")
	px2 := frame(f, {move({f32(x), 100})})
	delete(px2)
	px3 := frame(f)
	defer delete(px3)
	hot := pixel(px3, x, 100)
	testing.expect(t, hot != rest, "the accent colour under the pointer")
	testing.expect(t, pixel(px3, x + 1, 100) != beside || pixel(px3, x - 1, 100) != beside, "twice as thick")
}
