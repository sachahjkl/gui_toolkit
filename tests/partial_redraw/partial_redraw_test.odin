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
	field:     ui.Text_Field,
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
	ui.button("Hover me###hover")
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
	menu := ui.key_from_string(0, "menu")
	if app.menu_now {
		ui.ctx_menu_open(menu, {400, 60})
		app.menu_now = false
	}
	if ui.ctx_menu(menu) {
		_ = ui.menu_item("First")
		_ = ui.menu_item("Second")
	}
	if app.toast_now {
		ui.toast(.Good, "Saved %d files", 3)
		app.toast_now = false
	}
	ui.toasts_build()
}

// A session of the app with partial redraw on and every partial frame checked against the whole one.
@(private = "file")
open :: proc(t: ^testing.T, app: ^App, animations := true) -> ^session.Session {
	s := session.start(t, {size = WINDOW, build = app_build, user = app, animations = animations, palette = ui.PALETTE_MIDNIGHT})
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
	defer ui.field_destroy(&app.field)
	s := open(t, &app)
	settle(s)
	for _ in 0 ..< 5 {
		session.frame(s)
		px, active := region_px(s)
		testing.expectf(t, active && px == 0, "idle: a region of %d px (active %v)", px, active)
	}
	st := ui.damage_stats(s.state)
	testing.expect_value(t, st.changed, 0)
	testing.expect(t, st.spans > 10, "the boxes are spans")
	log.infof("idle frame: 0 px of %d, %d spans", WINDOW.x * WINDOW.y, st.spans)
	expect_exact(t, s, "idle")
}

// Hovering a button redraws the button, not the window; its animation too.
@(test)
a_hover_redraws_the_button :: proc(t: ^testing.T) {
	app: App
	defer ui.field_destroy(&app.field)
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
	defer ui.field_destroy(&app.field)
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
	defer ui.field_destroy(&app.field)
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
	defer ui.field_destroy(&app.field)
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
	defer ui.field_destroy(&app.field)
	s := open(t, &app)
	settle(s)
	app.palette = ui.PALETTE_DAYLIGHT
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
	defer ui.field_destroy(&app.field)
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
	defer ui.field_destroy(&app.field)
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
	defer ui.field_destroy(&app.field)
	s := session.start(t, {size = WINDOW, build = app_build, user = &app, palette = ui.PALETTE_MIDNIGHT})
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
