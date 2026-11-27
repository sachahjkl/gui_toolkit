// A preview: its pure steps (what fits, a zoom around a point, the reach of a pan), and in a session the wheel, a drag,
// a double click, the keys and the bar's buttons.
//   odin test tests/preview -collection:gt=src -vet
package preview_test

import "core:testing"
import "gt:draw"
import "gt:testkit/session"
import "gt:ui"

@(test)
what_fits :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.preview_fit({1000, 500}, {500, 500}, false), f32(0.5))
	testing.expect_value(t, ui.preview_fit({100, 100}, {500, 500}, false), f32(1))   // (a small one is not blown up)
	testing.expect_value(t, ui.preview_fit({100, 100}, {500, 400}, true), f32(4))
}

@(test)
a_zoom_keeps_its_point :: proc(t: ^testing.T) {
	p := ui.Preview{zoom = 1}
	ui.preview_zoom_to(&p, 2, 0.5, 8, {100, 0})
	testing.expect_value(t, p.zoom, f32(2))
	testing.expect_value(t, p.pan, ui.Vec2{-100, 0})   // (the point 100 to the right stays under the pointer)
	ui.preview_zoom_to(&p, 100, 0.5, 8, {})
	testing.expect_value(t, p.zoom, f32(8))
	testing.expect_value(t, ui.preview_pan_clamp({500, -500}, {800, 300}, {400, 400}), ui.Vec2{200, 0})
}

@(private = "file")
Run :: struct { p: ui.Preview, res: ui.Preview_Result, drawn: draw.Rect, wheel: ui.Preview_Wheel }

@(private = "file")
start :: proc(t: ^testing.T, r: ^Run) -> ^session.Session {
	r.p = {zoom = 1}
	return session.start(t, {size = {600, 400}, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(400), height = ui.px(300)})
		r.res = ui.preview("###pv", &r.p, {800, 600}, proc(dc: ^draw.Context, dst: ui.Rect, user: rawptr) {
			(^Run)(user).drawn = dst
		}, r, {buttons = true})
	}})
}

// The wheel zooms, a drag moves what is larger than the box, a double click fits again.
@(test)
the_pointer_zooms_and_moves :: proc(t: ^testing.T) {
	r: Run
	s := start(t, &r)
	session.frames(s, 2)
	testing.expect_value(t, r.res.fit, f32(0.5))
	c := session.center(r.res.box)
	session.wheel(s, c, {0, -2})
	session.frame(s)
	testing.expect(t, r.p.zoom > 1.5, "zoomed in")
	before := r.p.pan
	session.drag(s, c, c + {60, 0})
	session.frame(s)
	testing.expect(t, r.p.pan.x > before.x + 30, "moved with the pointer")
	session.click_at(s, c, count = 2)
	session.frame(s)
	testing.expect_value(t, r.p.zoom, f32(1))   // (zoomed: back to what fits)
}

// The bar's buttons: 1:1 shows the content's pixels, Fit what fits; the keys do the same.
@(test)
the_buttons_and_keys :: proc(t: ^testing.T) {
	r: Run
	s := start(t, &r)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "50%") != nil, "the bar says the zoom")
	bar, fit := session.find(s, "preview_bar"), session.find(s, "preview_fit")
	testing.expect(t, bar != nil && fit != nil && fit.rect.max.x <= bar.rect.max.x && bar.rect.max.x <= r.res.box.rect.max.x, "its buttons inside it, it inside the box")
	session.click(s, "preview_native")
	session.frame(s)
	testing.expect_value(t, r.res.percent, f32(100))
	session.click(s, "preview_fit")
	session.frame(s)
	testing.expect_value(t, r.res.percent, f32(50))
	session.click_at(s, session.center(r.res.box))   // (the keyboard on it)
	session.key(s, .Equal)
	session.frame(s)
	testing.expect_value(t, r.p.zoom, f32(ui.PREVIEW_ZOOM_STEP))
	session.key(s, .N0)
	session.frame(s)
	testing.expect_value(t, r.p.zoom, f32(1))
}

// The first frame of a preview already fits: the box is new, the build knows no size of it yet.
@(test)
the_first_frame_fits :: proc(t: ^testing.T) {
	r: Run
	s := start(t, &r)
	session.frame(s)
	testing.expect(t, r.drawn.max.x - r.drawn.min.x <= 401, "no larger than its box at its first frame")
}

@(private = "file")
start_panning :: proc(t: ^testing.T, r: ^Run) -> ^session.Session {
	r.p = {zoom = 1}
	return session.start(t, {size = {600, 400}, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(400), height = ui.px(300)})
		r.res = ui.preview("###pv", &r.p, {800, 600}, proc(dc: ^draw.Context, dst: ui.Rect, user: rawptr) {
			(^Run)(user).drawn = dst
		}, r, {wheel = r.wheel})
	}})
}

// With .Pans, the wheel moves the content and Ctrl with it zooms the preview, not the interface.
@(test)
the_wheel_pans_and_ctrl_zooms :: proc(t: ^testing.T) {
	r := Run{wheel = .Pans}
	s := start_panning(t, &r)
	session.frames(s, 2)
	c := session.center(r.res.box)
	session.wheel(s, c, {0, -2}, {.Ctrl})
	session.frame(s)
	testing.expect(t, r.p.zoom > 1.5, "Ctrl and the wheel zoom it")
	testing.expect_value(t, s.state.zoom, f32(1))   // (the interface keeps its zoom)
	zoom, before := r.p.zoom, r.p.pan
	session.wheel(s, c, {0, 1})
	session.frame(s)
	testing.expect_value(t, r.p.zoom, zoom)
	testing.expect(t, r.p.pan.y < before.y, "the wheel down moves the content up")
	session.wheel(s, c, {0, 1}, {.Shift})
	session.frame(s)
	testing.expect(t, r.p.pan.x < before.x, "with Shift, across")
}

// With .Ctrl_Pans, the wheel zooms and Ctrl with it moves the content; the interface keeps its zoom.
@(test)
the_wheel_zooms_and_ctrl_pans :: proc(t: ^testing.T) {
	r := Run{wheel = .Ctrl_Pans}
	s := start_panning(t, &r)
	session.frames(s, 2)
	c := session.center(r.res.box)
	session.wheel(s, c, {0, -2})
	session.frame(s)
	testing.expect(t, r.p.zoom > 1.5, "the wheel zooms it")
	zoom, before := r.p.zoom, r.p.pan
	session.wheel(s, c, {0, 1}, {.Ctrl})
	session.frame(s)
	testing.expect_value(t, r.p.zoom, zoom)
	testing.expect_value(t, s.state.zoom, f32(1))   // (the interface keeps its zoom)
	testing.expect(t, r.p.pan.y < before.y, "Ctrl and the wheel down move the content up")
	session.wheel(s, c, {0, 1}, {.Ctrl, .Shift})
	session.frame(s)
	testing.expect(t, r.p.pan.x < before.x, "with Shift, across")
}

@(private = "file")
Free_Run :: struct { p: ui.Preview, res: ui.Preview_Result, free: bool, wheel: ui.Vec2, shift: bool }

@(private = "file")
start_free :: proc(t: ^testing.T, r: ^Free_Run) -> ^session.Session {
	r.p = {zoom = 1}
	return session.start(t, {size = {600, 400}, user = r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Free_Run)(s.user)
		ui.next({width = ui.px(400), height = ui.px(300)})
		r.res = ui.preview("###pv", &r.p, {800, 600}, proc(dc: ^draw.Context, dst: ui.Rect, user: rawptr) {}, nil, {shift_wheel_free = r.free})
		if d, mods := ui.wheel_free(); d != {} { r.wheel += d; r.shift = .Shift in mods }
	}})
}

// With shift_wheel_free, Shift+wheel is the program's (ui.wheel_free) and does not zoom; without it, it zooms.
@(test)
shift_wheel_free_leaves_it_to_the_program :: proc(t: ^testing.T) {
	r := Free_Run{free = true}
	s := start_free(t, &r)
	session.frames(s, 2)
	c := session.center(r.res.box)
	session.wheel(s, c, {0, -2}, {.Shift})
	session.frame(s)
	testing.expect_value(t, r.p.zoom, f32(1))
	testing.expect_value(t, r.wheel, ui.Vec2{0, -2})
	testing.expect(t, r.shift, "the program reads Shift with it")
	// the wheel alone still zooms, and the program gets none of it
	session.wheel(s, c, {0, -2})
	session.frame(s)
	testing.expect(t, r.p.zoom > 1.5, "the wheel zooms")
	testing.expect_value(t, r.wheel, ui.Vec2{0, -2})
}

@(test)
shift_wheel_zooms_by_default :: proc(t: ^testing.T) {
	r: Free_Run
	s := start_free(t, &r)
	session.frames(s, 2)
	session.wheel(s, session.center(r.res.box), {0, -2}, {.Shift})
	session.frame(s)
	testing.expect(t, r.p.zoom > 1.5, "without the option, Shift+wheel zooms")
	testing.expect_value(t, r.wheel, ui.Vec2{})
}
