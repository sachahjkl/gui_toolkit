// Automatic partial redraw of the box tree (ui.set_partial_redraw, draw.damage_auto): each interaction redraws only what it
// changed, and every partial frame is the whole frame to the byte (draw.set_damage_verify draws each one whole on the side).
// The scenes run in both frame formats, 8 bits and half floats (a translucent window's), and their last frame holds only
// values in [0, 1], opaque.
//   odin test tests/partial_redraw -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package partial_redraw_test

import "core:fmt"
import "core:log"
import "core:testing"
import "gt:draw"
import "gt:markdown"
import "gt:platform"
import "gt:render"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{640, 480}
@(private = "file") ROWS :: 40
@(private = "file") ROW_HEIGHT :: 24
@(private = "file") CUSTOM_SIZE :: [2]f32{160, 40}
@(private = "file") SQUARE :: 16
@(private = "file") LIST_SIZE :: [2]f32{300, 150}
@(private = "file") LIST_FADE :: 12
// A caret's blink and the frames around it: well past one period (ui CARET_BLINK_MS).
@(private = "file") BLINK_WATCH_MS :: 1500
// What a blink of the caret may redraw at most: the caret and the box that draws it, a field's height, not the window.
@(private = "file") CARET_PX_MAX :: 20_000
// What a hovered button may redraw at most (its row of the window at the most).
@(private = "file") HOVER_PX_MAX :: 40_000
@(private = "file") SETTLE_FRAMES :: 90
// Frames in a row that redraw nothing: at rest (longer than a gap inside an animation; a caret's blink is half a second).
@(private = "file") QUIET_FRAMES :: 12

@(private = "file")
App :: struct {
	field:     ui.Line_Edit,
	square_x:  f32,    // where the changing custom draw puts its square
	toast_now: bool,
	menu_now:  bool,
	palette:   Maybe(ui.Palette),
}

@(private = "file")
moving_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := (^App)(user)
	x := b.rect.min.x + app.square_x
	draw.rect(dc, {{x, b.rect.min.y + 4}, {x + SQUARE, b.rect.min.y + 4 + SQUARE}}, {0.9, 0.3, 0.1, 1}, 3)
}

@(private = "file")
still_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	draw.rect(dc, draw.rect_pad(b.rect, -4), {0.1, 0.5, 0.9, 1}, 6)
}

@(private = "file")
app_build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if p, ok := app.palette.?; ok {
		ui.apply_palette(s.state.theme, p)
		app.palette = nil
	}
	ui.button("hover", "Hover me")
	ui.next({width = ui.px(240)})
	ui.line_edit("###field", &app.field)
	ui.next({width = ui.px(CUSTOM_SIZE.x), height = ui.px(CUSTOM_SIZE.y)})
	moving := ui.build_box({}, "###moving")
	moving.custom, moving.custom_user = moving_draw, app
	ui.next({width = ui.px(CUSTOM_SIZE.x), height = ui.px(CUSTOM_SIZE.y)})
	still := ui.build_box({}, "###still")
	still.custom, still.custom_user = still_draw, app
	ui.next({width = ui.px(LIST_SIZE.x), height = ui.px(LIST_SIZE.y), edge_fade = [4]f32{0, LIST_FADE, 0, LIST_FADE}})
	if ui.scroll_y("###list") {
		for i in 0 ..< ROWS {
			ui.next({width = ui.fill(), height = ui.px(ROW_HEIGHT)})
			ui.label(fmt.tprintf("Row %d###row%d", i, i))
		}
	}
	menu := "menu"
	if app.menu_now {
		ui.menu_open(menu, ui.Vec2{400, 60})
		app.menu_now = false
	}
	if ui.menu(menu) {
		_ = ui.menu_item("First")
		_ = ui.menu_item("Second")
	}
	if app.toast_now {
		ui.announce(&ui.Announcer{mode = .Window}, .Good, fmt.tprintf("Saved %d files", 3))
		app.toast_now = false
	}
}

// Each scene runs in both frame formats: 8 bits a channel, then half floats as a translucent window's frame (which keeps
// what an 8-bit one clamps; src/md/infrastructure/frame-formats.md).
@(private = "file") FORMATS :: [2]bool{false, true}

// A session of the app with partial redraw on and every partial frame checked against the whole one; `half`: its frame in
// half floats.
@(private = "file")
open :: proc(t: ^testing.T, app: ^App, animations := true, half := false) -> ^session.Session {
	s := session.start(t, {size = WINDOW, build = app_build, user = app, animations = animations, palette = ui.palette_of("Midnight"), half_float = half})
	ui.set_partial_redraw(s.state, true)
	draw.set_damage_verify(session.draw_context(s), true)
	session.frames(s, 3)
	return s
}

// The pixels the last frame's region covered, and whether the frame had a region.
@(private = "file")
region_px :: proc(s: ^session.Session) -> (px: int, active: bool) {
	_, _, px, _, active = draw.damage_stats(session.draw_context(s))
	return
}

// Frames until nothing moves (QUIET_FRAMES in a row redraw nothing), `frames` at most; the largest region on the way.
// (A fixed count ran every scene its whole bound: twice the scenes with half floats passed 420 s on WebGPU's WARP, where
// the verify draws each frame twice.)
@(private = "file")
settle :: proc(s: ^session.Session, frames := SETTLE_FRAMES) -> (most: int) {
	quiet := 0
	for _ in 0 ..< frames {
		session.frame(s)
		px, active := region_px(s)
		most = max(most, px)
		quiet = active && px == 0 ? quiet + 1 : 0
		if quiet >= QUIET_FRAMES { break }
	}
	return
}

// Every partial frame was the whole frame to the bit (in the frame's format), and the last frame holds only values in
// [0, 1], its alpha whole (every scene here is opaque: a window shows nothing behind it).
@(private = "file")
expect_exact :: proc(t: ^testing.T, s: ^session.Session, what: string, loc := #caller_location) {
	format := render.frame_is_half(s.renderer) ? "half floats" : "8 bits"
	testing.expectf(t, render.damage_verify_differences(s.renderer) == 0, "%s (%s): %d partial frames differ from the whole frame", what, format, render.damage_verify_differences(s.renderer), loc = loc)
	expect_opaque(t, s, what, loc)
}

// The last frame's values: finite, in [0, 1], alpha 1 (both within OPAQUE_MARGIN, a half's rounding of a blend).
@(private = "file") OPAQUE_MARGIN :: 1e-3
@(private = "file")
expect_opaque :: proc(t: ^testing.T, s: ^session.Session, what: string, loc := #caller_location) {
	format := render.frame_is_half(s.renderer) ? "half floats" : "8 bits"
	n, at, v := session.out_of_range(session.capture_float(s), least_alpha = 1 - OPAQUE_MARGIN, margin = OPAQUE_MARGIN)
	testing.expectf(t, n == 0, "%s (%s): %d pixels out of [0, 1] or not opaque, the first at %v: %v", what, format, n, at, v, loc = loc)
}

// A frame where nothing changed redraws nothing.
@(test)
an_idle_frame_redraws_nothing :: proc(t: ^testing.T) { for half in FORMATS { idle_scene(t, half) } }

@(private = "file")
idle_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	settle(s)
	for _ in 0 ..< 5 {
		session.frame(s)
		px, active := region_px(s)
		testing.expectf(t, active && px == 0, "idle: a region of %d px (active %v)", px, active)
	}
	st := ui.damage_stats(s.state)
	testing.expect_value(t, st.changed, 0)
	testing.expect(t, st.parts > 10, "the boxes are spans")
	log.infof("idle frame: 0 px of %d, %d parts", WINDOW.x * WINDOW.y, st.parts)
	expect_exact(t, s, "idle")
}

// Hovering a button redraws the button, not the window; its animation too.
@(test)
a_hover_redraws_the_button :: proc(t: ^testing.T) { for half in FORMATS { hover_scene(t, half) } }

@(private = "file")
hover_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	settle(s)
	// (the event alone: session.hover would make the frames of the change itself)
	session.event(s, {kind = .Mouse_Move, pos = session.center(session.get(s, "hover"))})
	most := settle(s)
	testing.expectf(t, most > 0 && most <= HOVER_PX_MAX, "hover: at most %d px a frame", most)
	log.infof("hover: at most %d px a frame of %d", most, WINDOW.x * WINDOW.y)
	session.press(s, session.center(session.get(s, "hover")))
	settle(s, 20)
	session.release(s, session.center(session.get(s, "hover")))
	session.leave(s)
	settle(s)
	expect_exact(t, s, "hover and press")
}

// Typing in a field, then its caret blinking: each blink redraws a small rectangle.
@(test)
a_caret_blink_redraws_a_small_rect :: proc(t: ^testing.T) { for half in FORMATS { caret_scene(t, half) } }

@(private = "file")
caret_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	session.click(s, "field")
	session.type_text(s, "hello partial")
	settle(s)
	blinks, most := 0, 0
	for _ in 0 ..< int(BLINK_WATCH_MS / session.FRAME_MS) {
		session.frame(s)
		px, _ := region_px(s)
		if px > 0 { blinks += 1 }
		most = max(most, px)
	}
	testing.expectf(t, blinks > 0, "the caret blinked")
	testing.expectf(t, most <= CARET_PX_MAX, "a blink redraws %d px", most)
	log.infof("caret blink: %d frames with a region, at most %d px of %d", blinks, most, WINDOW.x * WINDOW.y)
	expect_exact(t, s, "typing and blinking")
}

// The wheel scrolls a list whose edges fade (a masked layer): what moved is redrawn, exactly.
@(test)
a_scrolled_list_redraws_exactly :: proc(t: ^testing.T) { for half in FORMATS { scroll_scene(t, half) } }

@(private = "file")
scroll_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	list := session.get(s, "list")
	session.wheel(s, session.center(list), {0, 3})
	settle(s)
	testing.expect(t, session.get(s, "list").view_off.y > 0, "it scrolled")
	session.wheel(s, session.center(list), {0, -2})
	settle(s)
	expect_exact(t, s, "scrolling")
}

// A toast comes and goes, a menu opens over the rest and closes: overlays are spans like any box.
@(test)
overlays_come_and_go_exactly :: proc(t: ^testing.T) { for half in FORMATS { overlays_scene(t, half) } }

@(private = "file")
overlays_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	app.toast_now = true
	settle(s)
	app.menu_now = true
	settle(s)
	testing.expect(t, session.find_text(s, "Second") != nil, "the menu shows")
	session.key(s, .Escape)
	settle(s)
	ui.toasts_clear()
	settle(s)
	expect_exact(t, s, "toast and menu")
}

// Another palette changes every box: exact through its cross-fade.
@(test)
a_palette_change_is_exact :: proc(t: ^testing.T) { for half in FORMATS { palette_scene(t, half) } }

@(private = "file")
palette_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	settle(s)
	app.palette = ui.palette_of("Midnight", light = true)
	session.frame(s)
	px, _ := region_px(s)
	testing.expectf(t, px >= WINDOW.x * WINDOW.y / 2, "a new palette redraws most of the window (%d px)", px)
	settle(s)
	expect_exact(t, s, "palette")
}

// A custom draw is compared by what it draws: one that changes is redrawn, one that does not is not.
@(test)
custom_draws_are_compared_by_what_they_draw :: proc(t: ^testing.T) { for half in FORMATS { custom_scene(t, half) } }

@(private = "file")
custom_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	settle(s)
	app.square_x = 40
	session.frame(s)
	px, _ := region_px(s)
	moving := session.get(s, "moving").rect
	area := int((moving.max.x - moving.min.x + 4) * (moving.max.y - moving.min.y + 4))
	testing.expectf(t, px > 0 && px <= area, "the moved square redraws within its box: %d px (box %d)", px, area)
	session.frame(s)
	px, _ = region_px(s)
	testing.expectf(t, px == 0, "the still one is not redrawn: %d px", px)
	expect_exact(t, s, "custom draws")
}

// The window grows: the whole frame, then partial frames again.
@(test)
a_resize_redraws_the_whole_frame :: proc(t: ^testing.T) { for half in FORMATS { resize_scene(t, half) } }

@(private = "file")
resize_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app, half = half)
	settle(s)
	// (by hand: session.resize makes two frames, the second one partial again)
	platform.set_size(s.win, {WINDOW.x + 80, WINDOW.y + 40})
	render.resize(s.renderer, s.win.size)
	session.frame(s)
	testing.expect_value(t, ui.damage_stats(s.state).whole, draw.Damage_Whole.Environment)
	settle(s)
	session.frame(s)
	px, _ := region_px(s)
	testing.expect_value(t, px, 0)
	expect_exact(t, s, "resize")
}

// The check itself: a region marked by hand that misses a change is caught (what the tests above rely on to say "exact").
@(test)
the_check_catches_a_region_that_misses :: proc(t: ^testing.T) { for half in FORMATS { check_scene(t, half) } }

// (in half floats too: the frames are compared in the format they are stored in)
@(private = "file")
check_scene :: proc(t: ^testing.T, half: bool) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := session.start(t, {size = WINDOW, build = app_build, user = &app, palette = ui.palette_of("Midnight"), half_float = half})
	dc := session.draw_context(s)
	draw.set_partial_redraw(dc, true)
	draw.set_damage_verify(dc, true)
	settle(s, 10)
	// (a frame of a region first: after frames without one the kept target is behind, and the next region is composed whole)
	s.damage = draw.Rect{{0, 0}, {f32(WINDOW.x), f32(WINDOW.y)}}
	session.frame(s)
	testing.expect_value(t, render.damage_verify_differences(s.renderer), 0)
	app.square_x = 60
	s.damage = draw.Rect{{0, 0}, {2, 2}}   // (far from the square)
	session.frame(s)
	testing.expect(t, render.damage_verify_differences(s.renderer) > 0, "the moved square is outside the region: the frame differs")
}

// Spans drawn with draw directly, a grid of boxes of two instances each: what working out the region costs, and the calls of
// draw that change what is compared (damage_volatile, damage_whole, damage_memory_reset, an offscreen target).
@(private = "file") BOXES_WINDOW :: [2]int{800, 500}   // (cells of 8 by 5: each box still two instances; the region's cost is the CPU's, the pixels only slow WARP)
@(private = "file") BOXES_SIDE :: 100       // 10,000 boxes, 20,000 instances
@(private = "file") FEW_SIDE :: 10          // 100 boxes
@(private = "file") BOXES_FRAMES :: 10
@(private = "file") OFFSCREEN_SIZE :: [2]int{32, 32}
@(private = "file") READBACK_FRAMES :: 10   // frames to wait for a readback at the most
// What working out the region of 10,000 spans may take at the most (optimized, -o:speed): a tenth of a frame at 60 Hz.
@(private = "file") BOXES_MS_MAX :: 1.6

@(private = "file")
Boxes :: struct {
	side:      int,
	lit:       int,    // the box drawn in another colour (-1: none)
	volatile:  int,    // the box that calls damage_volatile (-1: none)
	whole:     bool,   // damage_whole
	offscreen: Maybe([4]f32),   // a box that also draws into an offscreen target, of this colour
	readback:  render.Readback_Id,
}

@(private = "file")
boxes_frame :: proc(s: ^session.Session, memory: ^draw.Damage_Memory, b: ^Boxes) -> draw.Damage_Auto_Stats {
	dc := session.draw_context(s)
	size := [2]f32{f32(BOXES_WINDOW.x), f32(BOXES_WINDOW.y)}
	cell := size / f32(b.side)
	draw.begin_frame(dc, size)
	render.frame_begin(s.renderer, {0, 0, 0, 1})
	draw.damage_auto(dc, memory)
	if b.whole { draw.damage_whole(dc) }
	for i in 0 ..< b.side * b.side {
		draw.damage_span_begin(dc, u64(i) + 1)
		at := cell * {f32(i % b.side), f32(i / b.side)}
		r := draw.Rect{at + 1, at + cell - 1}
		draw.rect(dc, r, i == b.lit ? draw.Color{0.9, 0.5, 0.1, 1} : draw.Color{0.2, 0.3, 0.4, 1}, 2)
		draw.rect(dc, r, {0.8, 0.8, 0.8, 1}, 2, 1)
		if i == b.volatile { draw.damage_volatile(dc) }
		if colour, ok := b.offscreen.?; ok && i == 0 && draw.offscreen_begin(dc, OFFSCREEN_SIZE) {
			draw.rect(dc, {{0, 0}, {f32(OFFSCREEN_SIZE.x), f32(OFFSCREEN_SIZE.y)}}, colour)
			b.readback = draw.offscreen_end(dc)
		}
		draw.damage_span_end(dc)
	}
	draw.end_frame(dc)
	render.frame_end(s.renderer, false)
	return memory.stats
}

// A session for the boxes: its window, partial redraw on, every partial frame checked against the whole one.
@(private = "file")
boxes_open :: proc(t: ^testing.T, app: ^App) -> ^session.Session {
	s := session.start(t, {size = BOXES_WINDOW, build = proc(s: ^session.Session) {}, user = app})
	dc := session.draw_context(s)
	draw.set_partial_redraw(dc, true)
	draw.set_damage_verify(dc, true)
	return s
}

@(test)
ten_thousand_spans_cost_little :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := boxes_open(t, &app)
	memory: draw.Damage_Memory
	defer draw.damage_memory_destroy(&memory)
	b := Boxes{side = BOXES_SIDE, lit = -1, volatile = -1}
	boxes_frame(s, &memory, &b)
	idle_ms, lit_ms: f32
	for k in 0 ..< BOXES_FRAMES {
		b.lit = -1
		st := boxes_frame(s, &memory, &b)
		testing.expect_value(t, st.changed, 0)
		testing.expect_value(t, st.px_drawn, 0)
		idle_ms += st.ms
		b.lit = k * 37
		st = boxes_frame(s, &memory, &b)
		testing.expect_value(t, st.changed, 1)
		testing.expect_value(t, st.whole, draw.Damage_Whole.No)
		lit_ms += st.ms
		// (the next frame changes the same box back)
		b.lit = -1
		_ = boxes_frame(s, &memory, &b)
	}
	idle_ms /= BOXES_FRAMES
	lit_ms /= BOXES_FRAMES
	log.infof("10,000 spans, 20,000 instances: %.3f ms a frame when nothing changes, %.3f ms when one span changes", idle_ms, lit_ms)
	when ODIN_OPTIMIZATION_MODE == .Speed {
		testing.expectf(t, idle_ms < BOXES_MS_MAX && lit_ms < BOXES_MS_MAX, "the region of 10,000 spans takes %.3f / %.3f ms", idle_ms, lit_ms)
	}
	expect_exact(t, s, "10,000 spans")
}

// A box added in the middle and one taken out redraw themselves alone; boxes raised above others redraw the window.
@(test)
added_removed_and_raised_spans :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := boxes_open(t, &app)
	memory: draw.Damage_Memory
	defer draw.damage_memory_destroy(&memory)
	dc := session.draw_context(s)
	frame :: proc(s: ^session.Session, memory: ^draw.Damage_Memory, ids: []u64) -> draw.Damage_Auto_Stats {
		dc := session.draw_context(s)
		draw.begin_frame(dc, {f32(BOXES_WINDOW.x), f32(BOXES_WINDOW.y)})
		render.frame_begin(s.renderer, {0, 0, 0, 1})
		draw.damage_auto(dc, memory)
		for id in ids {
			draw.damage_span_begin(dc, id)
			at := [2]f32{f32(id % 10) * 40, f32(id / 10) * 40}
			draw.rect(dc, {at, at + 60}, {f32(id % 3) / 3, 0.4, f32(id % 7) / 7, 1})   // (they overlap their neighbours)
			draw.damage_span_end(dc)
		}
		draw.end_frame(dc)
		render.frame_end(s.renderer, false)
		return memory.stats
	}
	frame(s, &memory, {1, 2, 3, 4, 5, 6})
	st := frame(s, &memory, {1, 2, 3, 9, 4, 5, 6})
	testing.expect_value(t, st.whole, draw.Damage_Whole.No)
	testing.expect_value(t, st.changed, 1)
	st = frame(s, &memory, {1, 2, 9, 4, 5, 6})
	testing.expect_value(t, st.whole, draw.Damage_Whole.No)
	testing.expect_value(t, st.changed, 1)
	st = frame(s, &memory, {1, 2, 9, 5, 4, 6})
	testing.expect_value(t, st.whole, draw.Damage_Whole.Order)
	_, _, px, _, _ := draw.damage_stats(dc)
	testing.expect_value(t, px, BOXES_WINDOW.x * BOXES_WINDOW.y)
	st = frame(s, &memory, {1, 2, 9, 5, 4, 6})
	testing.expect_value(t, st.changed, 0)
	expect_exact(t, s, "added, removed and raised")
}

// damage_volatile: the box is redrawn every frame, alone.
@(test)
a_volatile_span_is_redrawn_every_frame :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := boxes_open(t, &app)
	memory: draw.Damage_Memory
	defer draw.damage_memory_destroy(&memory)
	b := Boxes{side = FEW_SIDE, lit = -1, volatile = 7}
	boxes_frame(s, &memory, &b)
	cell := BOXES_WINDOW / FEW_SIDE
	for _ in 0 ..< 3 {
		st := boxes_frame(s, &memory, &b)
		testing.expect_value(t, st.whole, draw.Damage_Whole.No)
		testing.expect_value(t, st.changed, 1)
		testing.expectf(t, st.px_drawn > 0 && st.px_drawn <= (cell.x + 4) * (cell.y + 4), "a volatile box redraws %d px", st.px_drawn)
	}
	b.volatile = -1
	boxes_frame(s, &memory, &b)
	st := boxes_frame(s, &memory, &b)
	testing.expect_value(t, st.changed, 0)
	expect_exact(t, s, "volatile")
}

// damage_whole: that frame is whole, the next one partial again.
@(test)
damage_whole_makes_one_frame_whole :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := boxes_open(t, &app)
	memory: draw.Damage_Memory
	defer draw.damage_memory_destroy(&memory)
	b := Boxes{side = FEW_SIDE, lit = -1, volatile = -1}
	boxes_frame(s, &memory, &b)
	b.whole = true
	st := boxes_frame(s, &memory, &b)
	testing.expect_value(t, st.whole, draw.Damage_Whole.Asked)
	testing.expect_value(t, st.px_drawn, BOXES_WINDOW.x * BOXES_WINDOW.y)
	b.whole = false
	st = boxes_frame(s, &memory, &b)
	testing.expect_value(t, st.whole, draw.Damage_Whole.No)
	testing.expect_value(t, st.px_drawn, 0)
	expect_exact(t, s, "damage_whole")
}

// damage_memory_reset: the next frame is whole (nothing to compare with), the one after partial again.
@(test)
a_reset_memory_makes_the_next_frame_whole :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := boxes_open(t, &app)
	memory: draw.Damage_Memory
	defer draw.damage_memory_destroy(&memory)
	b := Boxes{side = FEW_SIDE, lit = -1, volatile = -1}
	boxes_frame(s, &memory, &b)
	st := boxes_frame(s, &memory, &b)
	testing.expect_value(t, st.changed, 0)
	draw.damage_memory_reset(&memory)
	st = boxes_frame(s, &memory, &b)
	testing.expect_value(t, st.whole, draw.Damage_Whole.First)
	testing.expect_value(t, st.px_drawn, BOXES_WINDOW.x * BOXES_WINDOW.y)
	st = boxes_frame(s, &memory, &b)
	testing.expect_value(t, st.whole, draw.Damage_Whole.No)
	testing.expect_value(t, st.changed, 0)
	expect_exact(t, s, "damage_memory_reset")
}

// An offscreen target (a drag image) is never shown: what changes in it changes no part and redraws nothing of the window, and
// it is read back whole.
@(test)
an_offscreen_target_damages_nothing :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := boxes_open(t, &app)
	memory: draw.Damage_Memory
	defer draw.damage_memory_destroy(&memory)
	colours := [2][4]f32{{1, 0, 0, 1}, {0, 0, 1, 1}}
	b := Boxes{side = FEW_SIDE, lit = -1, volatile = -1, offscreen = colours[0]}
	boxes_frame(s, &memory, &b)
	for k in 1 ..= 3 {
		b.offscreen = colours[k % 2]
		st := boxes_frame(s, &memory, &b)
		testing.expect_value(t, st.whole, draw.Damage_Whole.No)
		testing.expect_value(t, st.changed, 0)
		testing.expect_value(t, st.px_drawn, 0)
	}
	// the last one, blue, read back whole although the window's frame drew nothing
	id := b.readback
	b.offscreen = nil
	pixels: []u8
	status: render.Capture_Status
	for _ in 0 ..< READBACK_FRAMES {
		pixels, _, status = render.readback_poll(s.renderer, id, context.temp_allocator)
		if status != .Pending { break }
		boxes_frame(s, &memory, &b)
	}
	testing.expect_value(t, status, render.Capture_Status.Ready)
	if len(pixels) >= 4 * OFFSCREEN_SIZE.x * OFFSCREEN_SIZE.y {
		last := len(pixels) - 4
		testing.expectf(t, pixels[2] > 200 && pixels[0] < 50 && pixels[last + 2] > 200, "the offscreen target is blue: %v", pixels[:4])
	}
	expect_exact(t, s, "offscreen")
}

@(private = "file")
Replayed :: struct {
	pic:      draw.Picture,
	slot:     u32,
	record:   bool,   // record it (again) at the next draw
	color:    draw.Color,
	slot_x:   f32,    // where the slot puts its square
	compare:  bool,
	dc:       ^draw.Context,
}

@(private = "file")
replayed_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	r := (^Replayed)(user)
	r.dc = dc
	if r.record {
		r.record = false
		draw.picture_begin(dc, &r.pic)
		draw.rect(dc, {{0, 0}, {120, 40}}, {0.2, 0.2, 0.2, 1}, 4)
		draw.push_transform(dc, draw.affine_translate({0, 0}))
		r.slot = draw.current_slot(dc)
		draw.rect(dc, {{4, 4}, {4 + SQUARE, 4 + SQUARE}}, r.color, 3)
		draw.pop_transform(dc)
		draw.picture_end(dc)
	}
	draw.picture_set_slot(&r.pic, r.slot, draw.affine_translate({r.slot_x, 0}))
	_ = draw.replay(dc, &r.pic, draw.affine_translate(b.rect.min), compare = r.compare)
}

// A picture replayed with `compare` is drawn again only when something of it changed: an idle frame draws nothing, its slot
// moved or a new recording redraws it. Without, it is redrawn every frame.
@(test)
a_compared_replay_redraws_only_when_it_changed :: proc(t: ^testing.T) {
	r := Replayed{record = true, color = {0.9, 0.3, 0.1, 1}, compare = true}
	s := session.start(t, {size = WINDOW, user = &r, palette = ui.palette_of("Midnight"), build = proc(s: ^session.Session) {
		r := (^Replayed)(s.user)
		ui.next({width = ui.px(200), height = ui.px(60)})
		b := ui.build_box({}, "###replayed")
		b.custom, b.custom_user = replayed_draw, r
	}})
	defer if r.dc != nil { draw.picture_destroy(r.dc, &r.pic) }
	ui.set_partial_redraw(s.state, true)
	draw.set_damage_verify(session.draw_context(s), true)
	settle(s, 5)
	for _ in 0 ..< 3 {
		session.frame(s)
		px, active := region_px(s)
		testing.expectf(t, active && px == 0, "an unchanged replay redraws %d px", px)
	}
	r.slot_x = 30
	session.frame(s)
	px, _ := region_px(s)
	testing.expectf(t, px > 0 && px < WINDOW.x * WINDOW.y / 4, "the slot moved: %d px", px)
	session.frame(s)
	px, _ = region_px(s)
	testing.expect_value(t, px, 0)
	r.color, r.record = {0.1, 0.8, 0.3, 1}, true
	session.frame(s)
	px, _ = region_px(s)
	testing.expectf(t, px > 0, "recorded again: %d px", px)
	r.compare = false
	session.frame(s)
	session.frame(s)
	px, _ = region_px(s)
	testing.expectf(t, px > 0, "without compare, every frame: %d px", px)
}

////////////////////////////////
// What covers a change is drawn again over it, and no pixel is left less than opaque (expect_opaque: a pixel with an
// alpha under 1, or a value past [0, 1], is a hole where a translucent window shows what is behind it)

@(private = "file") UNDER_W :: 640
@(private = "file") UNDER_H :: 480
@(private = "file") UNDER_WINDOW :: [2]int{UNDER_W, UNDER_H}
@(private = "file") UNDER_ROWS :: 30
@(private = "file") UNDER_LIST_H :: 160
@(private = "file") UNDER_FADE :: 20
@(private = "file") UNDER_STEPS :: 8
@(private = "file") UNDER_STEP_PX :: 70
@(private = "file") UNDER_BAND_PX :: 40
// The most a step may redraw: the band where it was and where it is (2 x 40 x 480), its reach around, room to spare;
// a quarter of the window.
@(private = "file") UNDER_PARTIAL_PX_MAX :: UNDER_W * UNDER_H / 4

@(private = "file")
Under_Body :: struct {
	rows: int,
}

@(private = "file")
Under :: struct {
	views:  ui.Views,
	body:   Under_Body,
	want:   bool,
	band_x: f32,   // where the page's band is: it moves under the dialog
}

// The page: a ground that never changes, and a band that moves, each a box of its own. (One box that drew both was one
// part whose bounds were the whole window: each move of the band redrew the whole frame.)
@(private = "file")
under_build :: proc(s: ^session.Session) {
	u := (^Under)(s.user)
	if u.want {
		ui.view_open(&u.views, "files", &u.body)
		u.want = false
	}
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(f32(UNDER_WINDOW.x)), height = ui.px(f32(UNDER_WINDOW.y)), radius = 0, bg = {0.85, 0.85, 0.8, 1}})
	ui.build_box({.Draw_Background}, "###page")
	ui.next({fixed_x = u.band_x, fixed_y = 0, width = ui.px(UNDER_BAND_PX), height = ui.px(f32(UNDER_WINDOW.y)), radius = 0, bg = {0.9, 0.2, 0.1, 1}})
	ui.build_box({.Draw_Background}, "###band")
}

@(private = "file")
under_view :: proc(v: ^ui.View, b: ^Under_Body) {
	b.rows = UNDER_ROWS
	if ui.dialog_body("under_body") {
		ui.next({width = ui.fill(), height = ui.px(UNDER_LIST_H), edge_fade = [4]f32{0, UNDER_FADE, 0, UNDER_FADE}})
		if ui.scroll_y("###under_list") {
			for i in 0 ..< b.rows {
				ui.next({width = ui.fill(), height = ui.px(ROW_HEIGHT)})
				ui.label(fmt.tprintf("File %d###file%d", i, i))
			}
		}
	}
}

// A page box changes under a dialog: wherever the region is, everything over it is drawn again in it, in its order: the
// scrim, the dialog, its list that fades at both edges (a masked layer). Each partial frame is the whole frame to the bit,
// and no pixel of the window is left less than opaque, in both frame formats.
@(test)
a_change_under_a_dialog_redraws_the_dialog_over_it :: proc(t: ^testing.T) { for half in FORMATS { under_scene(t, half) } }

@(private = "file")
under_scene :: proc(t: ^testing.T, half: bool) {
	u: Under
	defer ui.views_destroy(&u.views)
	ui.view_register(&u.views, "files", under_view, ui.View_Options{title = "Files"})
	s := session.start(t, {size = UNDER_WINDOW, build = under_build, user = &u, palette = ui.palette_of("Midnight", light = true), half_float = half})
	ui.set_partial_redraw(s.state, true)
	draw.set_damage_verify(session.draw_context(s), true)
	session.frames(s, 3)
	u.want = true
	session.wait_until(s, "modal_view_files", proc(s: ^session.Session, panel: string) -> bool {
		b := session.find(s, panel)
		return b != nil && b.transparency <= 0
	}, "the dialog to show")
	settle(s)
	list := session.get(s, "under_list")
	session.wheel(s, session.center(list), {0, 2})
	settle(s)
	testing.expect(t, session.get(s, "under_list").view_off.y > 0, "the list scrolled: both its edges fade")
	panel := session.get(s, "modal_view_files").rect
	under := 0   // the steps whose band, before or after it moved, lies under the dialog
	for k in 1 ..= UNDER_STEPS {
		was := u.band_x
		u.band_x = f32(k * UNDER_STEP_PX)
		session.frame(s)
		px, active := region_px(s)
		// (where the band was and where it is, each a little wider than the band: far from the whole window)
		testing.expectf(t, active && px > 0 && px < UNDER_PARTIAL_PX_MAX, "step %d: a partial frame (%d px, active %v, why whole: %v)", k, px, active, ui.damage_stats(s.state).whole)
		for x in ([]f32{was, u.band_x}) {
			if x < panel.max.x && x + UNDER_BAND_PX > panel.min.x { under += 1; break }
		}
		expect_opaque(t, s, fmt.tprintf("step %d (the dialog at %v)", k, panel))
	}
	testing.expectf(t, under > 0, "the band moved under the dialog (at %v)", panel)
	expect_exact(t, s, "a change under a dialog")
}

// An internal window (a view floated in the window: its frame, its shadow, its plate) over lines of text that change
// each step (a shell's output under it, opencode native's Statistics over a conversation): the text never shows through
// the window. Each partial frame is the whole frame to the bit, in both frame formats.
@(private = "file") FLOAT_STEPS :: 6

@(private = "file")
Float_Run :: struct {
	views: ui.Views,
	body:  Under_Body,
	want:  bool,
	step:  int,
}

@(private = "file")
float_build :: proc(s: ^session.Session) {
	u := (^Float_Run)(s.user)
	if u.want {
		ui.view_open(&u.views, "files", &u.body)
		ui.view_present(&u.views, "files", .Internal)
		u.want = false
	}
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(f32(UNDER_WINDOW.x)), height = ui.px(f32(UNDER_WINDOW.y)), axis = .Y})
	if ui.column(id = "###lines") {
		for i in 0 ..< 24 {
			ui.next({width = ui.fill(), height = ui.px(ROW_HEIGHT), font = ui.mono_font()})
			ui.label(fmt.tprintf("line %d of step %d: /run/systemd/app.slice/opencode.service %d###line%d", i, u.step, u.step * 31 + i, i))
		}
	}
}

@(test)
text_that_changes_under_an_internal_window_stays_under_it :: proc(t: ^testing.T) { for half in FORMATS { float_scene(t, half) } }

@(private = "file")
float_scene :: proc(t: ^testing.T, half: bool) { for f in ui.Finish { float_scene_in(t, half, f) } }

@(private = "file")
float_scene_in :: proc(t: ^testing.T, half: bool, finish: ui.Finish) {
	u: Float_Run
	defer ui.views_destroy(&u.views)
	ui.view_register(&u.views, "files", under_view, ui.View_Options{title = "Files"})
	pal := ui.palette_of("Midnight")
	pal.finish = finish
	s := session.start(t, {size = UNDER_WINDOW, build = float_build, user = &u, palette = pal, half_float = half})
	s.state.theme.glow = 1
	ui.set_partial_redraw(s.state, true)
	draw.set_damage_verify(session.draw_context(s), true)
	session.frames(s, 3)
	u.want = true
	session.wait_until(s, "internal_view_files", proc(s: ^session.Session, frame: string) -> bool {
		b := session.find(s, frame)
		return b != nil && b.transparency <= 0
	}, "the internal window to show")
	settle(s)
	for k in 1 ..= FLOAT_STEPS {
		u.step = k
		session.frame(s)
		settle(s)
		expect_opaque(t, s, fmt.tprintf("step %d", k))
	}
	expect_exact(t, s, fmt.tprintf("text that changes under an internal window, %v", finish))
}

// A Markdown table wider than its place (it scrolls sideways in a masked layer), inline code in its striped rows, in the
// machined finish on a light palette: the pointer over it (its corner's tool comes and goes) and a scroll sideways. Each
// partial frame is the whole frame to the byte; no pixel is left less than opaque around the code's chips.
@(private = "file") TABLE_WINDOW :: [2]int{640, 400}
@(private = "file") TABLE_COLUMN_PX :: 600
@(private = "file") TABLE_TEXT :: "| Name | What it does | Where it is |\n|---|---|---|\n" +
	"| `first` | reads the lines of a block and keeps the cases it meets | in the reader of blocks, under the parser |\n" +
	"| `case_lines` | splits a case into its lines, one run of code each | in the table code, beside the measure |\n" +
	"| `x` | a name that says little and stays short in its cell | nowhere in particular, a cell of the test |\n" +
	"| `case_lines` | the same name again, in a striped row of its own | in the second striped row of the table |\n"
@(private = "file") TABLE_MOVES :: 6

@(private = "file")
Table_Run :: struct {
	doc: markdown.Doc,
}

@(private = "file")
table_build :: proc(s: ^session.Session) {
	tr := (^Table_Run)(s.user)
	cfg := markdown.View_Options{user = tr, table_corner = proc(user: rawptr, t: ^markdown.Table, source: []string, size: f32) {
		_ = ui.button("table_copy", "Copy")
	}}
	ui.next({width = ui.px(TABLE_COLUMN_PX), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###doc") { markdown.view(&tr.doc, "md", TABLE_TEXT, cfg) }
}

@(test)
a_table_with_code_in_striped_rows_is_exact_and_opaque :: proc(t: ^testing.T) { for half in FORMATS { table_scene(t, half) } }

@(private = "file")
table_scene :: proc(t: ^testing.T, half: bool) {
	tr := Table_Run{doc = {alloc = context.allocator}}
	defer markdown.doc_destroy(&tr.doc)
	p := ui.palette_of("Midnight", light = true)
	p.finish = .Machined
	s := session.start(t, {size = TABLE_WINDOW, build = table_build, user = &tr, palette = p, half_float = half})
	ui.set_partial_redraw(s.state, true)
	draw.set_damage_verify(session.draw_context(s), true)
	settle(s)
	expect_opaque(t, s, "shown")
	table := session.get(s, "hs").rect
	for k in 0 ..< TABLE_MOVES {
		// (across the table, row by row: its corner's tool comes, the rows under the pointer change nothing else)
		f := (f32(k) + 0.5) / TABLE_MOVES
		session.move(s, {table.min.x + 20 + f * (table.max.x - table.min.x - 40), table.min.y + f * (table.max.y - table.min.y)})
		settle(s, 10)
		expect_opaque(t, s, fmt.tprintf("pointer move %d", k))
	}
	session.wheel(s, session.center(session.get(s, "hs")), {0, 2}, {.Shift})
	settle(s)
	testing.expect(t, session.get(s, "hs").view_off.x > 0, "the table scrolled sideways: it is wider than its place")
	expect_opaque(t, s, "scrolled sideways")
	session.leave(s)
	settle(s)
	expect_opaque(t, s, "the pointer gone")
	expect_exact(t, s, "a table with code in its cells")
}
