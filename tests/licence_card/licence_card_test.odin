// The licence card (ui.licence_card, src/md/features/licence-card.md): a picture per finish on a dark and a light theme, no
// frame at rest after the sweep and an ease, the tilt that follows the pointer and comes back, the turn over and its way
// home, the flat card when the shader is refused.   odin run tools/run_tests -- licence_card
// The pictures are compared with references/<theme>_<finish>.png; TOOLKIT_TEST_UPDATE=1 writes them (review them like code).
package licence_card_test

import "core:fmt"
import "core:math"
import "core:testing"
import "gt:render"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") LOGO :: #load("../../site/img/logo.png")

@(private = "file")
SAMPLE :: ui.Licence_Card{
	product = "Sample", edition = "Supporter", name = "Ada Lovelace", email = "ada@example.org", date = "2026-11-16",
	order = "A-1042", logo = LOGO, back_line = "SAMPLE · EXAMPLE SOFTWARE",
}

// The card on a panel of the theme, so that the finish shows around it.
@(private = "file")
Scene :: struct {
	card: ui.Licence_Card,
}

@(private = "file")
scene_build :: proc(s: ^session.Session) {
	sc := (^Scene)(s.user)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###page") {
		ui.space(ui.GROUP_GAP)
		if ui.card("Licence", id = "###panel") {
			ui.licence_card("licence", sc.card)
			ui.space(ui.LINE_GAP)
			ui.label("Thank you for supporting Sample.###thanks")
		}
	}
}

@(private = "file")
look :: proc(s: ^session.Session) -> ui.Licence_Card_Look { return ui.licence_card_look(s.state, "licence") }

// Its textures are made (or cannot be: the card stays flat), and nothing moves.
@(private = "file")
wait_settled :: proc(s: ^session.Session, loc := #caller_location) {
	session.wait_until(s, proc(s: ^session.Session) -> bool { l := look(s); return l.found && l.settled }, "the card's textures", loc = loc)
	session.wait_idle(s, loc = loc)
}

// The card's box (the card and the room for its tilt) and the card in it.
@(private = "file")
card_rect :: proc(s: ^session.Session) -> (min, max: [2]f32) {
	b := session.get(s, "licence_card")
	w := b.rect.max.x - b.rect.min.x
	h := w / f32(ui.LICENCE_CARD_ASPECT)
	mid := (b.rect.min.y + b.rect.max.y) * 0.5
	return {b.rect.min.x, mid - h / 2}, {b.rect.max.x, mid + h / 2}
}

@(private = "file")
pictures :: proc(t: ^testing.T, light: bool) {
	sc := Scene{card = SAMPLE}
	p := ui.palette_of("Midnight", light)
	s := session.start(t, {size = {640, 520}, palette = p, user = &sc, build = scene_build})
	// (the foil where this backend has the shader (Direct3D 11 needs its blob) on a device of its own: on WARP, the software
	// rasterizer of the Windows runners, a foil frame takes seconds and its pixels are not a GPU's, and the foil's relief is
	// not even made there (the runners' chores took minutes for it); the flat card everywhere)
	software := render.adapter_info(s.renderer).software
	if software { ui.set_licence_card_flat(s.state, true) }
	wait_settled(s)
	shaded := look(s).shaded && !software
	for flat in ([]bool{false, true}) {
		if !flat && !shaded { continue }
		ui.set_licence_card_flat(s.state, flat)
		for finish in ui.Finish {
			p.finish = finish
			ui.apply_palette(&s.own.theme, p, s.renderer.space)
			session.frames(s, 2)
			wait_settled(s)
			testing.expect_value(t, look(s).shaded, !flat)
			name := fmt.tprintf("%s_%v_%s.png", light ? "light" : "dark", finish, flat ? "flat" : "foil")
			session.expect_like(s, fmt.tprintf("%s/tests/licence_card/references/%s", session.repo_root(), name))
		}
	}
}

@(test)
a_picture_per_finish_on_a_dark_theme :: proc(t: ^testing.T) { pictures(t, false) }

@(test)
a_picture_per_finish_on_a_light_theme :: proc(t: ^testing.T) { pictures(t, true) }

// The design's single test: a card shown for a minute with the pointer elsewhere asks for no frame after its sweep, nor after
// the ease that brings the tilt back.
@(test)
at_rest_no_frame_is_due :: proc(t: ^testing.T) {
	sc := Scene{card = SAMPLE}
	s := session.start(t, {size = {640, 520}, animations = true, user = &sc, build = scene_build})
	ui.set_licence_card_flat(s.state, true)   // (the motion is the same on the flat card; the foil's frames cost seconds each on WARP: the pictures test the foil)
	session.wait_until(s, proc(s: ^session.Session) -> bool { l := look(s); return l.found && l.settled }, "the card's textures")
	// (the first show's sweep, then the pointer on the card and away: a sweep and an ease)
	session.advance(s, 3200)
	lo, hi := card_rect(s)
	session.move(s, (lo + hi) * 0.5 + {60, 30})
	testing.expect(t, ui.needs_frame(s.state) || !look(s).shaded, "the sweep asks for frames while it passes")
	session.leave(s)
	testing.expect(t, look(s).moving, "the tilt eases back")
	session.advance(s, 3200)
	session.frame(s)
	l := look(s)
	testing.expect(t, !l.moving && !l.sweeping, "nothing moves any more")
	testing.expect(t, !ui.needs_frame(s.state), "no frame is due at rest")
	testing.expect_value(t, ui.wake_in_ms(s.state), 0)
	// a minute later, the pointer elsewhere: still nothing due
	s.clock += 60_000
	session.frame(s)
	testing.expect(t, !ui.needs_frame(s.state), "no frame is due a minute later")
	testing.expect_value(t, ui.wake_in_ms(s.state), 0)
}

// The pointer on the card's top left corner turns the card towards it (its top towards the eye: rotateX > 0, its left away:
// rotateY < 0); gone, the card eases back to zero.
@(test)
the_tilt_follows_the_pointer_and_comes_back :: proc(t: ^testing.T) {
	sc := Scene{card = SAMPLE}
	s := session.start(t, {size = {640, 520}, animations = true, user = &sc, build = scene_build})
	ui.set_licence_card_flat(s.state, true)   // (the motion is the same on the flat card; the foil's frames cost seconds each on WARP: the pictures test the foil)
	wait_settled(s)
	b := session.get(s, "licence_card")
	session.move(s, b.rect.min + {2, 2})
	session.frames(s, 2)
	l := look(s)
	testing.expectf(t, l.rx > 12 && l.rx <= 14, "rotateX towards the top: %v", l.rx)
	testing.expectf(t, l.ry < -16 && l.ry >= -18, "rotateY towards the left: %v", l.ry)
	session.leave(s)
	session.advance(s, 700)
	l = look(s)
	testing.expectf(t, abs(l.rx) < 1e-3 && abs(l.ry) < 1e-3, "back to zero: %v, %v", l.rx, l.ry)
	// (the pointer's coming set off a sweep: at rest once it has passed)
	session.advance(s, 3200)
	testing.expect(t, !look(s).moving, "at rest")
}

// Turn over: the button frees the card; a drag of half a turn (let go once still: no fling) shows the back, its front not
// drawn; Escape brings it back by the short way.
@(test)
turned_over_it_shows_its_back_and_escape_brings_it_home :: proc(t: ^testing.T) {
	sc := Scene{card = SAMPLE}
	s := session.start(t, {size = {720, 560}, animations = true, user = &sc, build = scene_build})
	ui.set_licence_card_flat(s.state, true)   // (the motion is the same on the flat card; the foil's frames cost seconds each on WARP: the pictures test the foil)
	wait_settled(s)
	session.click(s, "licence_turn")
	testing.expect(t, look(s).turned, "the card is free")
	b := session.get(s, "licence_card")
	from := [2]f32{b.rect.min.x + 10, (b.rect.min.y + b.rect.max.y) * 0.5}
	// (180 degrees at DRAG_DEG_PER_PX = 0.45 a logical pixel: 400 pixels)
	to := from + {400, 0}
	session.press(s, from)
	steps :: 20
	for i in 1 ..= steps {
		at := from + (to - from) * (f32(i) / steps)
		s.pointer = at
		session.event(s, {kind = .Mouse_Move, pos = at})
		session.frame(s)
	}
	session.advance(s, 200)
	session.release(s, to)
	session.wait_idle(s)
	l := look(s)
	half := math.mod(abs(l.ry), 360)
	testing.expectf(t, abs(half - 180) < 3, "half a turn: %v", l.ry)
	testing.expect(t, l.back, "the back shows")
	session.key(s, .Escape)
	testing.expect(t, !look(s).turned, "Escape ends the free mode")
	// (the pointer away: home is the card at rest, not the pointer's tilt)
	session.leave(s)
	session.advance(s, 900)
	l = look(s)
	testing.expectf(t, abs(l.rx) < 1e-3 && abs(l.ry) < 1e-3, "home: %v, %v", l.rx, l.ry)
	testing.expect(t, !l.back, "the front shows again")
}

// With the shader refused, the card is flat: the ground, the text plain, a drawn medal. A long name is set smaller: whole on
// the card, up to its right margin and not past it.
@(test)
the_flat_card_reads_whole :: proc(t: ^testing.T) {
	sc := Scene{card = SAMPLE}
	sc.card.name = "Marie-Hélène de La Tour d'Auvergne-Lauraguais"
	s := session.start(t, {size = {640, 520}, user = &sc, build = scene_build})
	ui.set_licence_card_flat(s.state, true)
	wait_settled(s)
	l := look(s)
	testing.expect(t, l.found && !l.shaded && l.plain_text, "flat, its text plain")
	img := session.capture(s)
	lo, hi := card_rect(s)
	k := (hi.x - lo.x) / 440
	bright :: proc(img: session.Image, x0, x1, y0, y1: f32) -> int {
		n := 0
		for y in int(y0) ..< int(y1) {
			for x in int(x0) ..< int(x1) {
				c := session.pixel(img, x, y)
				if c[0] > 150 && c[1] > 150 && c[2] > 150 { n += 1 }
			}
		}
		return n
	}
	// the name's band: its baseline at 134 of the design, its letters above it
	y0, y1 := lo.y + 112 * k, lo.y + 140 * k
	testing.expect(t, bright(img, lo.x + 22 * k, lo.x + 120 * k, y0, y1) > 20, "the name's start is drawn")
	testing.expect(t, bright(img, lo.x + 360 * k, lo.x + 418 * k, y0, y1) > 5, "the name reaches the right margin")
	testing.expect_value(t, bright(img, lo.x + 424 * k, hi.x, y0, y1), 0)
	// the product and the date are there too
	testing.expect(t, bright(img, lo.x + 22 * k, lo.x + 200 * k, lo.y + 22 * k, lo.y + 42 * k) > 20, "the product")
	testing.expect(t, bright(img, lo.x + 22 * k, lo.x + 120 * k, lo.y + 242 * k, lo.y + 258 * k) > 10, "the date")
}
