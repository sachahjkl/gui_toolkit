// pane_split, pane_toggle and the pane's text (ui/panes.odin): resizing from a few em to all the room but a few em,
// folding by a drag, a double click, Enter and the button; the strip that brings the pane back by a click or a pull; the
// keyboard; the app's save callback; what the strip draws. The text is 15 px: the minimum is 45 px, and 400 px of room
// keep 45 px for the other side.
package panes_test

import "core:testing"
import "../../src/ui"

// Frames of 16 ms past the toolkit's double click time (450 ms).
@(private = "file") DOUBLE_CLICK_FRAMES :: 30

@(private)
frame_pane :: proc(f: ^Fx) {
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row() {
		f.popts.on_save, f.popts.user = proc(user: rawptr, p: ^ui.Pane) { (^Fx)(user).saves += 1 }, f
		after := f.popts.side == .After
		if ext := ui.pane_extent(&f.pane, .X, f.popts); !after && ext > 0 { ui.next({width = ui.px(ext), height = ui.fill()}); ui.build_box({}, "###pane") }
		if after { ui.next({width = ui.fill(), height = ui.fill()}); ui.build_box({}, "###other") }
		if f.toggle { ui.pane_toggle("###toggle", .X, &f.pane, f.popts) }
		f.pres = ui.pane_split("###split", .X, &f.pane, f.popts)
		if after && f.pres.size > 0 { ui.next({width = ui.px(f.pres.size), height = ui.fill()}); ui.build_box({}, "###pane") }
		if !after { ui.next({width = ui.fill(), height = ui.fill()}); ui.build_box({}, "###other") }
	}
}

@(private = "file")
pane_setup :: proc(t: ^testing.T, opts: ui.Pane_Options, drawing := false) -> ^Fx {
	f := setup(t, drawing)
	if f == nil { return nil }
	f.pane_mode, f.popts = true, opts
	f.pane.size[.X] = 100
	return f
}

@(private = "file")
row_box :: proc(name: string) -> ^ui.Box {
	r := ui.box_from_key(ui.key_from_string(0, "root"))
	for c := r.first.first; c != nil; c = c.next { if c.name == name { return c } }
	return nil
}

@(test)
pane_resizes_from_a_few_em_to_nearly_all :: proc(t: ^testing.T) {
	f := pane_setup(t, {total = 400})
	if f == nil { return }
	defer teardown(f)
	frame(f)
	frame(f)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	testing.expect_value(t, b.rect.min.x, 100)
	x := (b.rect.min.x + b.rect.max.x) * 0.5
	frame(f, {press({x, 50})})
	frame(f, {move({x + 500, 50})})
	testing.expect_value(t, f.pane.size[.X], 355)   // all but 3 em for the other side
	testing.expect(t, f.pres.changed && !f.pres.finished)
	frame(f, {move({x - 500, 50})})
	testing.expect_value(t, f.pane.size[.X], 45)    // 3 em: not collapsible, it stops there
	testing.expect(t, !f.pane.collapsed)
	testing.expect_value(t, f.saves, 0)
	frame(f, {release({x - 500, 50})})
	testing.expect(t, f.pres.finished)
	testing.expect_value(t, f.saves, 1)
	frame(f)
	testing.expect(t, !ui.needs_frame(&f.s), "nothing to draw at rest")
}

@(test)
pane_folds_and_comes_back :: proc(t: ^testing.T) {
	f := pane_setup(t, {side = .After, total = 400, collapsible = true, title = "Styles"})
	if f == nil { return }
	defer teardown(f)
	frame(f)
	frame(f)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	testing.expect_value(t, b.rect.min.x, 400 - 100 - 5)
	x := (b.rect.min.x + b.rect.max.x) * 0.5

	// dragged under half the minimum it folds; back past it, it opens at the pointer; folded again, it keeps its size
	frame(f, {press({x, 50})})
	frame(f, {move({x + 90, 50})})
	testing.expect(t, f.pane.collapsed && f.pres.toggled)
	testing.expect_value(t, f.pres.size, 0)
	frame(f, {move({x + 60, 50})})
	testing.expect(t, !f.pane.collapsed)
	testing.expect_value(t, f.pane.size[.X], 45)
	frame(f, {move({x + 90, 50})})
	testing.expect(t, f.pane.collapsed)
	testing.expect_value(t, f.pane.size[.X], 100)
	frame(f, {release({x + 90, 50})})
	testing.expect_value(t, f.saves, 1)
	frame(f)

	// folded: a strip at the edge; a click brings the pane back at its size
	b = split_box()
	testing.expect_value(t, b.rect.max.x - b.rect.min.x, 19)   // 1.25 em
	testing.expect_value(t, b.rect.max.x, 400)
	testing.expect(t, row_box("pane") == nil, "nothing built for a folded pane")
	sx := (b.rect.min.x + b.rect.max.x) * 0.5
	for _ in 0 ..< DOUBLE_CLICK_FRAMES { frame(f) }   // (the drag's press is no first click of a double click)
	frame(f, {press({sx, 50})})
	frame(f, {release({sx, 50})})
	testing.expect(t, !f.pane.collapsed && f.pres.toggled)
	testing.expect_value(t, f.pres.size, 100)
	testing.expect_value(t, f.saves, 2)
	frame(f)
	// a click on the bar right after the one on the strip is no double click: the pane stays open
	frame(f, {press({x, 50}), release({x, 50})})
	testing.expect(t, !f.pane.collapsed, "the strip's click and the bar's are no double click")
	frame(f)

	// a double click on the handle folds it; the release that follows is no click on the strip
	frame(f, {press({x, 50}), release({x, 50})})
	frame(f, {press({x, 50})})
	testing.expect(t, f.pane.collapsed)
	frame(f, {release({x, 50})})
	frame(f)
	testing.expect(t, f.pane.collapsed)
	testing.expect_value(t, f.pane.size[.X], 100)

	// pulled out of the strip: open at the pointer
	b = split_box()
	sx = (b.rect.min.x + b.rect.max.x) * 0.5
	frame(f, {press({sx, 50})})
	frame(f, {move({sx - 10, 50})})
	testing.expect(t, f.pane.collapsed, "a short pull stays folded")
	frame(f, {move({sx - 150, 50})})
	testing.expect(t, !f.pane.collapsed)
	testing.expect_value(t, f.pane.size[.X], 150)
	frame(f, {release({sx - 150, 50})})
}

@(test)
pane_keyboard :: proc(t: ^testing.T) {
	f := pane_setup(t, {total = 400, collapsible = true})
	if f == nil { return }
	defer teardown(f)
	frame(f)
	frame(f)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	testing.expect(t, .Focusable in b.flags, "a Tab stop")
	x := (b.rect.min.x + b.rect.max.x) * 0.5
	frame(f, {press({x, 50}), release({x, 50})})
	testing.expect_value(t, ui.focus_key(), b.key)
	frame(f, {key(.Right)})
	testing.expect_value(t, f.pane.size[.X], 110)
	frame(f, {key(.Left, {.Ctrl})})
	testing.expect_value(t, f.pane.size[.X], 108)
	frame(f, {key(.End)})
	testing.expect_value(t, f.pane.size[.X], 355)
	frame(f, {key(.Home)})
	testing.expect_value(t, f.pane.size[.X], 45)
	testing.expect(t, f.pres.finished)
	frame(f, {key(.Up)})
	testing.expect_value(t, f.pane.size[.X], 45)   // the other axis' keys are not its own
	saves := f.saves
	frame(f, {key(.Return)})
	testing.expect(t, f.pane.collapsed, "Enter folds")
	testing.expect_value(t, f.saves, saves + 1)
	frame(f, {key(.Right)})
	testing.expect(t, f.pane.collapsed, "folded, the arrows do nothing")
	frame(f, {key(.Return)})
	testing.expect(t, !f.pane.collapsed, "Enter brings it back")
	testing.expect_value(t, f.pres.size, 45)
}

@(test)
pane_toggle_button :: proc(t: ^testing.T) {
	f := pane_setup(t, {side = .After, total = 400, collapsible = true, title = "Styles"})
	if f == nil { return }
	defer teardown(f)
	f.toggle = true
	frame(f)
	frame(f)
	tb := row_box("toggle")
	if !testing.expect(t, tb != nil) { return }
	testing.expect_value(t, tb.rect.max.x - tb.rect.min.x, 24)   // 1.6 em
	c := (tb.rect.min + tb.rect.max) * 0.5
	frame(f, {press(c)})
	frame(f, {release(c)})
	testing.expect(t, f.pane.collapsed, "a click folds the pane")
	testing.expect_value(t, f.saves, 1)
	frame(f)
	tb = row_box("toggle")   // (it moved: the pane's room went to the other side)
	c = (tb.rect.min + tb.rect.max) * 0.5
	frame(f, {press(c)})
	frame(f, {release(c)})
	testing.expect(t, !f.pane.collapsed, "and brings it back")
}

@(test)
pane_text_and_place :: proc(t: ^testing.T) {
	p := ui.Pane{size = {.X = 320, .Y = 180}, collapsed = true, place = .Below}
	s := ui.pane_format(p)
	testing.expect_value(t, s, "320 180 1 below")
	q, ok := ui.pane_parse(s)
	testing.expect(t, ok && q == p)
	for bad in ([]string{"", "320 180 1", "320 180 2 side", "-1 180 0 side", "a 1 0 auto", "1 1 0 left"}) {
		_, ok2 := ui.pane_parse(bad)
		testing.expectf(t, !ok2, "%q is no pane", bad)
	}
	testing.expect_value(t, ui.pane_axis(.Side, 100, 600), ui.Axis.X)
	testing.expect_value(t, ui.pane_axis(.Below, 1000, 600), ui.Axis.Y)
	testing.expect_value(t, ui.pane_axis(.Auto, 700, 600), ui.Axis.X)
	testing.expect_value(t, ui.pane_axis(.Auto, 500, 600), ui.Axis.Y)
	free_all(context.temp_allocator)
}

@(test)
pane_strip_draws_a_chevron :: proc(t: ^testing.T) {
	f := pane_setup(t, {side = .After, total = 400, collapsible = true}, true)
	if f == nil { return }
	defer teardown(f)
	f.pane.collapsed = true
	delete(frame(f))
	px := frame(f)
	defer delete(px)
	b := split_box()
	if !testing.expect(t, b != nil) { return }
	c := (b.rect.min + b.rect.max) * 0.5
	marked := 0
	for y in int(c.y) - 6 ..= int(c.y) + 6 {
		for x in int(b.rect.min.x) + 2 ..< int(b.rect.max.x) { if pixel(px, x, y) != pixel(px, x, 10) { marked += 1 } }
	}
	testing.expect(t, marked > 4, "a chevron in the middle of the strip")
	testing.expect(t, pixel(px, int(b.rect.min.x), 10) != pixel(px, int(b.rect.min.x) + 4, 10), "its edge towards the other side")
}
