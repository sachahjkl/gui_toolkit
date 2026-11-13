// Automatic partial redraw of the box tree (ui.set_partial_redraw, draw.damage_auto): each interaction redraws only what it
// changed, and every partial frame is the whole frame to the byte (draw.set_damage_verify draws each one whole on the side).
//   odin test tests/partial_redraw -vet -define:ODIN_TEST_THREADS=1
package partial_redraw_test

import "core:fmt"
import "core:log"
import "core:testing"
import "../../src/draw"
import "../../src/platform"
import "../../src/render"
import "../../src/testkit/session"
import "../../src/ui"

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

// A session of the app with partial redraw on and every partial frame checked against the whole one.
@(private = "file")
open :: proc(t: ^testing.T, app: ^App, animations := true) -> ^session.Session {
	s := session.start(t, {size = WINDOW, build = app_build, user = app, animations = animations, palette = ui.palette_of("Midnight")})
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

// Frames until nothing moves; the largest region on the way.
@(private = "file")
settle :: proc(s: ^session.Session, frames := SETTLE_FRAMES) -> (most: int) {
	for _ in 0 ..< frames {
		session.frame(s)
		px, _ := region_px(s)
		most = max(most, px)
	}
	return
}

@(private = "file")
expect_exact :: proc(t: ^testing.T, s: ^session.Session, what: string, loc := #caller_location) {
	testing.expectf(t, render.damage_verify_differences(s.renderer) == 0, "%s: %d partial frames differ from the whole frame", what, render.damage_verify_differences(s.renderer), loc = loc)
}

// A frame where nothing changed redraws nothing.
@(test)
an_idle_frame_redraws_nothing :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
a_hover_redraws_the_button :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
a_caret_blink_redraws_a_small_rect :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
a_scrolled_list_redraws_exactly :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
overlays_come_and_go_exactly :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
a_palette_change_is_exact :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
custom_draws_are_compared_by_what_they_draw :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
a_resize_redraws_the_whole_frame :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := open(t, &app)
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
the_check_catches_a_region_that_misses :: proc(t: ^testing.T) {
	app: App
	defer ui.line_edit_destroy(&app.field)
	s := session.start(t, {size = WINDOW, build = app_build, user = &app, palette = ui.palette_of("Midnight")})
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
