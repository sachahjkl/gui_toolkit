package scenarios_test

// What is drawn, by its pixels: boxes, borders, rounded corners, clips, order, text, hover and press, the theme, a palette's fade; fonts; partial redraw.

import "core:testing"
import "../../src/draw"
import "../../src/font"
import "../../src/render"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{320, 200}
@(private = "file") RED :: session.Color{255, 0, 0, 255}
@(private = "file") GREEN :: session.Color{0, 255, 0, 255}
@(private = "file") BLUE :: session.Color{0, 0, 255, 255}
// Longer than a palette's cross-fade (ui.Feel.palette_fade_ms).
@(private = "file") FADE_OVER_MS :: 1000

@(private = "file")
fixed_box :: proc(id: string, x, y, w, h: f32, bg: ui.Color, flags: ui.Box_Flags = {.Draw_Background}, radius: f32 = 0) -> ^ui.Box {
	ui.next({fixed_x = x, fixed_y = y, width = ui.px(w), height = ui.px(h), bg = bg, radius = radius})
	return ui.build_box(flags, id)
}

@(test)
boxes_are_where_they_are_in_their_order :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		fixed_box("###under", 10, 10, 50, 50, {1, 0, 0, 1})
		fixed_box("###over", 30, 30, 50, 50, {0, 1, 0, 1})
	}})
	img := session.capture(s)
	testing.expect(t, session.near(session.pixel(img, 15, 15), RED), "the first where it is alone")
	testing.expect(t, session.near(session.pixel(img, 40, 40), GREEN), "the later one over it")
	testing.expect_value(t, session.count_color(img, {0, 0}, WINDOW, RED), 50 * 50 - 30 * 30)
	testing.expect_value(t, session.count_color(img, {0, 0}, WINDOW, GREEN), 50 * 50)
}) }

@(test)
a_clip_cuts_what_is_inside :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(40), height = ui.px(40)})
		if ui.column(flags = {.Clip}, id = "###clip") {
			fixed_box("###wide", 0, 0, 200, 200, {0, 0, 1, 1})
		}
	}})
	img := session.capture(s)
	testing.expect_value(t, session.count_color(img, {0, 0}, WINDOW, BLUE), 40 * 40)
	testing.expect(t, session.near(session.pixel(img, 59, 59), BLUE), "to its last pixel")
	testing.expect(t, !session.near(session.pixel(img, 60, 60), BLUE), "and no further")
}) }

// A corner's radius takes pixels out of a corner, and leaves its edges.
@(test)
a_rounded_box_has_no_corners :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		fixed_box("###round", 20, 20, 60, 60, {1, 0, 0, 1}, radius = 20)
	}})
	img := session.capture(s)
	testing.expect(t, !session.near(session.pixel(img, 20, 20), RED), "no corner")
	testing.expect(t, session.near(session.pixel(img, 50, 20), RED), "the top edge in its middle")
	testing.expect(t, session.near(session.pixel(img, 50, 50), RED), "the inside")
	covered := session.count_color(img, {0, 0}, WINDOW, RED, 40)
	testing.expect(t, covered < 60 * 60 && covered > 60 * 60 * 3 / 4, "about what a rounded square covers")
}) }

@(test)
a_box_s_transparency_lets_through_what_is_under_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, palette = ui.palette_of("Midnight"), build = proc(s: ^session.Session) {
		fixed_box("###white", 0, 0, 100, 100, {1, 1, 1, 1})
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(100), height = ui.px(100), bg = {0, 0, 0, 1}, transparency = 0.5})
		ui.build_box({.Draw_Background}, "###half")
	}})
	c := session.pixel(session.capture(s), 50, 50)
	testing.expect(t, c.r > 60 && c.r < 200, "between black and white")
	testing.expect_value(t, c.a, 255)
}) }

// Text draws ink in its box, in its colour, and more text draws more.
@(test)
text_is_drawn_in_its_box :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(200), height = ui.px(40), fg = {1, 1, 1, 1}, bg = {0, 0, 0, 1}})
		ui.build_box({.Draw_Text, .Draw_Background}, "Hamburgefonts###words")
		ui.next({fixed_x = 10, fixed_y = 60, width = ui.px(200), height = ui.px(40), fg = {1, 1, 1, 1}, bg = {0, 0, 0, 1}})
		ui.build_box({.Draw_Text, .Draw_Background}, "H###letter")
	}})
	img := session.capture(s)
	black := session.Color{0, 0, 0, 255}
	words := session.count_other(img, {10, 10}, {210, 50}, black)
	letter := session.count_other(img, {10, 60}, {210, 100}, black)
	testing.expect(t, letter > 10, "a letter has ink")
	testing.expect(t, words > letter * 3, "more letters, more ink")
	testing.expect(t, session.count_color(img, {10, 10}, {210, 50}, {255, 255, 255, 255}, 10) > 0, "white at its strongest")
}) }

// Hover and press show at once, in the frame's colours; leaving brings the first back.
@(test)
a_button_shows_its_states :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 40, fixed_y = 40, width = ui.px(120), height = ui.px(40)})
		ui.button("b")
	}})
	at := [2]int{50, 50}
	rest := session.pixel(session.capture(s), at.x, at.y)
	p := session.center(session.get(s, "b"))
	session.move(s, p)
	hot := session.pixel(session.capture(s), at.x, at.y)
	testing.expect(t, !session.near(hot, rest, 0), "under the pointer it changes")
	session.press(s, p)
	pressed := session.pixel(session.capture(s), at.x, at.y)
	testing.expect(t, !session.near(pressed, hot, 0), "pressed it changes again")
	session.release(s, p)
	session.move(s, {f32(WINDOW.x - 1), f32(WINDOW.y - 1)})
	testing.expect(t, session.near(session.pixel(session.capture(s), at.x, at.y), rest, 0), "it comes back")
}) }

// A pattern with more tags wins; the same widget under a tag takes its colours; a change of the theme shows in the next frame.
@(test)
the_theme_goes_by_tags :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(60), height = ui.px(40)})
		ui.build_box({.Draw_Background}, "###plain")
		if ui.tags("special") {
			ui.next({fixed_x = 80, fixed_y = 0, width = ui.px(60), height = ui.px(40)})
			ui.build_box({.Draw_Background}, "###tagged")
		}
	}})
	theme := s.state.theme
	ui.theme_set(theme, "background", {1, 0, 0, 1})
	ui.theme_set(theme, "special background", {0, 0, 1, 1})
	session.advance(s, FADE_OVER_MS)
	testing.expect_value(t, ui.theme_lookup(theme, {}, "background"), ui.Color{1, 0, 0, 1})
	testing.expect_value(t, ui.theme_lookup(theme, {"special"}, "background"), ui.Color{0, 0, 1, 1})
	img := session.capture(s)
	testing.expect(t, session.near(session.pixel(img, 30, 20), RED), "plain")
	testing.expect(t, session.near(session.pixel(img, 110, 20), BLUE), "tagged")
	ui.theme_set(theme, "special background", {0, 1, 0, 1})
	session.advance(s, FADE_OVER_MS)
	testing.expect(t, session.near(session.pixel(session.capture(s), 110, 20), GREEN), "a change shows")
}) }

// Another palette cross-fades by the clock: the colours are between the two on the way, the new ones at the end. With no animations it jumps.
@(test)
a_palette_change_fades_by_the_clock :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, animations = true, palette = ui.palette_of("Midnight"), build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(60), height = ui.px(40)})
		ui.build_box({.Draw_Background}, "###panel")
	}})
	session.wait_idle(s)
	dark := session.pixel(session.capture(s), 30, 20)
	ui.apply_palette(s.state.theme, ui.palette_of("Midnight", light = true))
	session.frames(s, 2)
	between := session.pixel(session.capture(s), 30, 20)
	session.advance(s, FADE_OVER_MS)
	session.wait_idle(s)
	light := session.pixel(session.capture(s), 30, 20)
	testing.expect(t, int(light.r) > int(dark.r), "a lighter palette")
	testing.expect(t, int(between.r) > int(dark.r) && int(between.r) < int(light.r), "in between on the way")
}) }

// Every palette names what the widgets ask for: nothing is drawn in the colour of a missing entry (magenta).
@(test)
every_palette_gives_every_widget_a_colour :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { on: bool, value: f32, field: ui.Text_Field }
	r: Run
	defer ui.field_destroy(&r.field)
	s := session.start(t, {size = {500, 300}, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(120)})
		ui.button("b", "Button")
		ui.next({width = ui.px(200)})
		ui.checkbox("###c", "Check", &r.on)
		ui.next({width = ui.px(200)})
		ui.toggle("###to", "Toggle", &r.on)
		ui.next({width = ui.px(200)})
		ui.slider("###sl", &r.value, 0, 1)
		ui.next({width = ui.px(200)})
		ui.line_edit("###f", &r.field, "Placeholder")
		ui.next({width = ui.px(200)})
		if ui.tags("menu_item") { ui.button("i", "Item") }
	}})
	magenta := session.Color{255, 0, 255, 255}
	for p in ui.theme_palettes(ui.THEMES[:]) {
		ui.apply_palette(s.state.theme, p.palette)
		session.advance(s, FADE_OVER_MS)
		testing.expectf(t, session.count_color(session.capture(s), {0, 0}, {500, 300}, magenta, 8) == 0, "%s has them all", p.name)
	}
}) }

// A slider's track shows on the theme's "track" surface (a dialog's colour in some themes): at 0, its whole length is
// the part that is off, and it is not the colour under it.
@(test)
a_sliders_track_shows_on_any_surface :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { value: f32 }
	r: Run
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		fixed_box("###surface", 0, 0, 320, 200, ui.color("track"))
		ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(280), height = ui.px(30)})
		ui.slider("###sl", &r.value, 0, 1)
	}})
	b := session.get(s, "sl")
	img := session.capture(s)
	// (halfway along the track, away from the knob at its left end and the value at its right)
	x := int(b.rect.min.x + (b.rect.max.x - b.rect.min.x) * 0.4)
	cy := int((b.rect.min.y + b.rect.max.y) * 0.5)
	surface := session.pixel(img, x, int(b.rect.min.y) + 2)
	testing.expect(t, !session.near(session.pixel(img, x, cy), surface, 8), "the track is not the surface's colour")
}) }

// A cascade: each character from the first face that has it (no system font in this: both faces are compiled in).
@(test)
a_cascade_takes_each_character_from_its_face :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true})
	own := s.own
	c := font.cascade(&own.fonts, {{font = own.mono_font, ranges = {{'0', '9'}}}, {font = own.ui_font}}, no_system_fallback = true)
	sh := font.shape(&own.fonts, c, 16, "a1", {}, context.temp_allocator)
	if !testing.expect_value(t, len(sh.glyphs), 2) { return }
	testing.expect(t, sh.glyphs[0].face != sh.glyphs[1].face, "a letter and a digit from two faces")
	digit := font.shape(&own.fonts, own.mono_font, 16, "1", {}, context.temp_allocator)
	testing.expect_value(t, sh.glyphs[1].face, digit.glyphs[0].face)
	testing.expect_value(t, sh.glyphs[1].id, digit.glyphs[0].id)
}) }

// A character no face has: with no system fallback, the first face's "missing" glyph; with it, a face that has it, when the system has one.
@(test)
a_character_no_face_has :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	CJK :: "漢"
	s := session.start(t, {size = WINDOW, no_renderer = true})
	own := s.own
	alone := font.cascade(&own.fonts, {{font = own.ui_font}}, no_system_fallback = true)
	none := font.shape(&own.fonts, alone, 16, CJK, {}, context.temp_allocator)
	if testing.expect_value(t, len(none.glyphs), 1) {
		testing.expect_value(t, none.glyphs[0].face, font.shape(&own.fonts, alone, 16, "a", {}, context.temp_allocator).glyphs[0].face)
		testing.expect_value(t, none.glyphs[0].id, 0)
	}
	when ODIN_OS == .Windows {   // (every Windows has a font for it; a Linux may not)
		with := font.shape(&own.fonts, own.ui_font, 16, CJK, {}, context.temp_allocator)
		if testing.expect_value(t, len(with.glyphs), 1) {
			testing.expect(t, with.glyphs[0].id != 0, "the system's fallback has it")
			testing.expect(t, with.glyphs[0].face != none.glyphs[0].face, "in another face")
		}
	}
}) }

// A label through a cascade measures what its characters measure, whatever face each comes from.
@(test)
a_label_measures_its_cascade :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Fonts :: struct { c: font.Font_Id }
	f: Fonts
	s := session.start(t, {size = WINDOW, user = &f, no_renderer = true, build = proc(s: ^session.Session) {
		f := (^Fonts)(s.user)
		if f.c == 0 { return }
		ui.next({width = ui.text_size(), font = f.c})
		ui.label("a1b2###mixed")
	}})
	own := s.own
	f.c = font.cascade(&own.fonts, {{font = own.mono_font, ranges = {{'0', '9'}}}, {font = own.ui_font}}, no_system_fallback = true)
	session.frames(s, 2)
	b := session.get(s, "mixed")
	want := font.measure(&own.fonts, own.ui_font, b.font_size, "ab") + font.measure(&own.fonts, own.mono_font, b.font_size, "12")
	testing.expectf(t, abs(b.text_dim.x - want) <= 2, "its width is its characters': %v and %v", b.text_dim.x, want)
}) }

// Partial redraw through the session's renderer: a frame of a region changes the region and nothing else, and matches a whole frame.
@(test)
a_region_redraws_only_itself :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { color: ui.Color, region: Maybe(draw.Rect) }
	r := Run{color = {1, 0, 0, 1}}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		fixed_box("###left", 0, 0, 100, 100, r.color)
		fixed_box("###right", 150, 0, 100, 100, r.color)
		s.damage = r.region
	}})
	dc := session.draw_context(s)
	draw.set_partial_redraw(dc, true)
	r.region = draw.Rect{{0, 0}, {100, 100}}
	session.frames(s, 2)   // (the first frame of a region composes everything)
	testing.expect(t, session.near(session.pixel(session.capture(s), 50, 50), RED))
	// the colour of both changes; only the left one is said to have: the right one stays as it was
	r.color = {0, 1, 0, 1}
	session.frame(s)
	img := session.capture(s)
	testing.expect(t, session.near(session.pixel(img, 50, 50), GREEN), "inside the region: the new picture")
	testing.expect(t, session.near(session.pixel(img, 200, 50), RED), "outside it: the old one")
	_, _, px_region, px_frame, active := draw.damage_stats(dc)
	testing.expect(t, active, "the region was used")
	testing.expectf(t, px_region < px_frame, "%d of %d pixels", px_region, px_frame)
	// the right region of what really changed: the same bytes as a whole frame
	render.set_damage_verify(s.renderer, true)
	r.color = {0, 0, 1, 1}
	r.region = draw.Rect{{0, 0}, {250, 100}}
	session.frame(s)
	testing.expect_value(t, render.damage_verify_differences(s.renderer), 0)
	testing.expect(t, session.near(session.pixel(session.capture(s), 200, 50), BLUE), "the whole region is drawn")
}) }
