package film_tool

import "core:fmt"
import "core:math"
import "gt:draw"
import "gt:film"
import host "gt:host"
import "gt:platform"
import "gt:ui"

// A title card, drawn by the toolkit itself in a window of its own: a deep ground with a slow glow of the accent, a small
// word above, the title, a line under it; each comes up in turn, the title on a spring, a stroke of the accent drawn under
// it. Its time starts at its first frame after card_show.
Card :: struct {
	shared: host.Shared,
	host:   host.Host,
	kicker, title, line: string,
	start:  f64,   // the clock at its first frame (< 0: not shown yet)
}

CARD_ACCENT :: [3]f32{0.36, 0.64, 1}
CARD_TOP    :: [3]f32{0.10, 0.13, 0.24}
CARD_BOTTOM :: [3]f32{0.015, 0.017, 0.03}

card_open :: proc() -> ^Card {
	c := new(Card)
	c.start = -1
	if !host.host_open(&c.host, &c.shared, {title = "film card", size = WINDOW_LOGICAL, headless = true, headless_gpu = true}, card_build, c) {
		free(c)
		return nil
	}
	platform.set_offscreen_dpi(c.host.win, DPI_FULL)
	return c
}

card_close :: proc(c: ^Card) {
	host.host_close(&c.host)
	free(c)
}

card_app :: proc(c: ^Card) -> film.App {
	return {win = c.host.win, state = &c.host.state, renderer = &c.shared.r, user = &c.host,
		frame = proc(user: rawptr) { host.host_frame((^host.Host)(user)) }}
}

card_show :: proc(c: ^Card, kicker, title, line: string) {
	c.kicker, c.title, c.line = kicker, title, line
	c.start = -1
}

@(private = "file")
card_build :: proc(h: ^host.Host, size: host.Vec2) {
	c := (^Card)(h.user)
	if c.start < 0 { c.start = ui.now_ms() }
	t := f32((ui.now_ms() - c.start) / 1000)
	h.state.anim_busy = true   // (it moves the whole time it shows)
	em := ui.font_size()
	accent := draw.srgb(CARD_ACCENT.x, CARD_ACCENT.y, CARD_ACCENT.z)

	ground := ui.frame_new(Ground)
	ground^ = {t = t}
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(size.x), height = ui.px(size.y)})
	ui.custom("###ground", ground_draw, ground)

	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, cross = .Center})
	if ui.column(.Center, id = "###card") {
		ui.spacer(ui.fill())
		if c.kicker != "" {
			rise_line(c.kicker, "kicker", t, 0.1, math.round(em * 1.25), draw.srgb(CARD_ACCENT.x, CARD_ACCENT.y, CARD_ACCENT.z), em, spring = false)
			ui.spacer(ui.px(math.round(em * 0.6)))
		}
		rise_line(c.title, "title", t, 0.25, math.round(em * 4.2), draw.srgb(0.96, 0.97, 1), em, spring = true)
		// the stroke under the title: drawn from the middle out
		e := film.ease_in_out((t - 0.55) / 0.7)
		ui.spacer(ui.px(math.round(em * 0.9)))
		ui.next({width = ui.px(math.round(em * 9 * e)), height = ui.px(math.max(2, math.round(em * 0.18))), bg = accent, radius = em * 0.1})
		ui.build_box({.Draw_Background}, "###stroke")
		ui.spacer(ui.px(math.round(em * 1.1)))
		if c.line != "" {
			rise_line(c.line, "line", t, 0.75, math.round(em * 1.45), draw.srgb(0.68, 0.72, 0.82), em, spring = false)
		}
		ui.spacer(ui.fill())
	}
}

// A line of words that comes up into place and appears from `delay` seconds.
@(private = "file")
rise_line :: proc(words, id: string, t, delay, size: f32, color: draw.Color, em: f32, spring: bool) {
	k := clamp((t - delay) / 0.75, 0, 1)
	e := spring ? film.ease_out_back(k, 1.2) : film.ease_in_out(k)
	// (a box as tall as the line, the words in it lower while they rise: the lines below never move)
	h := math.round(size * 1.35)
	ui.next({width = ui.children_sum(), height = ui.px(h), axis = .Y})
	if ui.column(id = fmt.tprintf("###%s_slot", id)) {
		ui.spacer(ui.px(math.round(size * 0.55 * (1 - e))))
		ui.next({width = ui.text_size(), height = ui.text_size(), font_size = size, fg = color, transparency = 1 - film.smooth(k * 1.6), text_pad = 0})
		ui.build_box({.Draw_Text, .No_Text_Trunc}, ui_id(words, id))
	}
}

@(private = "file")
ui_id :: proc(text, id: string) -> string { return fmt.tprintf("%s###%s", text, id) }

@(private = "file")
Ground :: struct { t: f32 }

// The ground: a gradient from deep blue to near black, a glow of the accent that breathes in its middle.
@(private = "file")
ground_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	g := (^Ground)(user)
	r := b.rect
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	stops := [2]draw.Gradient_Stop{
		{color = draw.srgb(CARD_TOP.x, CARD_TOP.y, CARD_TOP.z), pos = 0},
		{color = draw.srgb(CARD_BOTTOM.x, CARD_BOTTOM.y, CARD_BOTTOM.z), pos = 1},
	}
	draw.gradient(dc, r, {kind = .Linear, space = .Oklab, start = {0, 0}, end = {0, h}, stops = stops[:], dither = true})
	breathe := 0.5 + 0.5 * math.sin(g.t * 1.3)
	glow := [2]draw.Gradient_Stop{
		{color = draw.srgb(CARD_ACCENT.x, CARD_ACCENT.y, CARD_ACCENT.z, 0.16 + 0.06 * breathe), pos = 0},
		{color = draw.srgb(CARD_ACCENT.x, CARD_ACCENT.y, CARD_ACCENT.z, 0), pos = 1},
	}
	draw.gradient(dc, r, {kind = .Radial, space = .Oklab, center = {w * 0.5, h * 0.48}, radii = {w * (0.42 + 0.03 * breathe), h * 0.55}, stops = glow[:], dither = true})
}
