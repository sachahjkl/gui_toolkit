// The licence card (ui.licence_card, src/md/features/licence-card.md): a picture per finish on a dark and a light theme, no
// frame at rest after the sweep and an ease, the tilt that follows the pointer and comes back, the turn over and its way
// home, the flat card when the shader is refused, the code engraved on the back and the turn that reveals it.
//   odin run tools/run_tests -- licence_card
// The pictures are compared with references/<theme>_<finish>.png; TOOLKIT_TEST_UPDATE=1 writes them (review them like code).
package licence_card_test

@(require) import "core:fmt"   // (the pictures' names: Linux only)
import "core:math"
import "core:slice"
import "core:testing"
import "gt:qr"
import "gt:render"
import "gt:testkit/session"
import turn "gt:turn"
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
	// (WebGPU over WARP: a frame costs a third of a second, ten pictures pass the test's limit; the Direct3D 11 job
	// compares the flat card on WARP, and Linux compares both on a device of its own)
	if software && render.USE_WGPU { return }
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
			// (the references are Linux's text: Windows draws its letters with DirectWrite, other pixels at every edge)
			when ODIN_OS == .Linux {
				name := fmt.tprintf("%s_%v_%s.png", light ? "light" : "dark", finish, flat ? "flat" : "foil")
				session.expect_like(s, fmt.tprintf("%s/tests/licence_card/references/%s", session.repo_root(), name))
			}
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
	testing.expectf(t, l.rx > 12.0 / 360 && l.rx <= 14.0 / 360, "rotateX towards the top: %v", l.rx)
	testing.expectf(t, l.ry < -16.0 / 360 && l.ry >= -18.0 / 360, "rotateY towards the left: %v", l.ry)
	session.leave(s)
	session.advance(s, 700)
	l = look(s)
	testing.expectf(t, abs(l.rx) < 1e-3 / 360 && abs(l.ry) < 1e-3 / 360, "back to zero: %v, %v", l.rx, l.ry)
	// (the pointer's coming set off a sweep: at rest once it has passed)
	session.advance(s, 3200)
	testing.expect(t, !look(s).moving, "at rest")
}

// A drag of the free card from `from` to `to` in 20 moves, let go once still (no fling).
@(private = "file")
drag :: proc(s: ^session.Session, from, to: [2]f32) {
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
	// (half a turn at DRAG_TURNS_PER_PX = 0.45 / 360 a logical pixel: 400 pixels)
	drag(s, from, from + {400, 0})
	l := look(s)
	half := math.mod(abs(l.ry), 1)
	testing.expectf(t, abs(half - 0.5) < 3.0 / 360, "half a turn: %v", l.ry)
	testing.expect(t, l.back, "the back shows")
	session.key(s, .Escape)
	testing.expect(t, !look(s).turned, "Escape ends the free mode")
	// (the pointer away: home is the card at rest, not the pointer's tilt)
	session.leave(s)
	session.advance(s, 900)
	l = look(s)
	testing.expectf(t, abs(l.rx) < 1e-3 / 360 && abs(l.ry) < 1e-3 / 360, "home: %v, %v", l.rx, l.ry)
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

// The code engraved on the back, as the shader and the flat card read it, is the hunt's address: as a matrix, and drawn black
// on white with its quiet zone, 4 pixels a module, as a phone sees it at its turn. (An address that needs another version
// than the place on the back is made for engraves no code: this fails.)
@(test)
the_engraved_code_reads_the_hunts_address :: proc(t: ^testing.T) {
	n :: ui.LICENCE_CARD_SEAL_MODULES
	modules := make([]bool, n * n, context.temp_allocator)
	for y in 0 ..< n {
		for x in 0 ..< n { modules[y * n + x] = ui.licence_card_seal_module(x, y) }
	}
	m, err := qr.decode_modules(modules, n)
	defer qr.decoded_destroy(&m)
	testing.expect_value(t, err, qr.Decode_Error.None)
	testing.expect_value(t, string(m.data), ui.LICENCE_CARD_SEAL_URL)

	k :: 4
	side := (n + 2 * qr.QUIET_ZONE) * k
	gray := make([]u8, side * side, context.temp_allocator)
	for y in 0 ..< side {
		for x in 0 ..< side {
			dark := ui.licence_card_seal_module(x / k - qr.QUIET_ZONE, y / k - qr.QUIET_ZONE)
			gray[y * side + x] = dark ? 0 : 255
		}
	}
	p, perr := qr.decode_gray(gray, side, side, side)
	defer qr.decoded_destroy(&p)
	testing.expect_value(t, perr, qr.Decode_Error.None)
	testing.expect_value(t, string(p.data), ui.LICENCE_CARD_SEAL_URL)
}

// The ramp of the code's contrast: none straight on (the back at rotateY 180), whole at its turn and a little off it (a person
// holds it there), part of the way between, none far from it (the opposite tilt, the front's side).
@(test)
the_code_shows_at_its_turn_alone :: proc(t: ^testing.T) {
	// (the angles below in degrees, as a person reads them)
	reveal :: proc(rx, ry: f32) -> f32 { return ui.licence_card_seal_reveal(turn.from_degrees(rx), turn.from_degrees(ry)) }
	testing.expectf(t, reveal(0, 180) < 0.01, "straight on: %v", reveal(0, 180))
	testing.expectf(t, reveal(-11, 191) > 0.99, "at its turn: %v", reveal(-11, 191))
	testing.expectf(t, reveal(-11, -169) > 0.99, "at its turn, a whole turn less: %v", reveal(-11, -169))
	testing.expectf(t, reveal(-10, 192) > 0.99, "held a degree off: %v", reveal(-10, 192))
	r := reveal(-11, 186)
	testing.expectf(t, r > 0.05 && r < 0.95, "5 degrees off, on its way: %v", r)
	testing.expectf(t, reveal(-11, 182) < 0.01, "9 degrees off: %v", reveal(-11, 182))
	testing.expectf(t, reveal(11, 169) < 0.01, "the opposite tilt: %v", reveal(11, 169))
	testing.expectf(t, reveal(0, 0) < 0.01, "the front towards the eye: %v", reveal(0, 0))
}

// On a device of its own, the code on the foil: the back seen straight on does not decode from its pixels; turned to the
// code's angle (from the back, a drag 24.4 logical pixels right and down: 11 degrees on each axis) it does. A screen at 200 %:
// 4 pixels a module.
@(test)
the_engraved_code_scans_at_its_angle_alone :: proc(t: ^testing.T) {
	sc := Scene{card = SAMPLE}
	s := session.start(t, {size = {1440, 1120}, dpi_scale = 2, animations = true, user = &sc, build = scene_build})
	// (the foil only: on WARP its frames take seconds, and the flat card shows no code by design; Mesa's software
	// rasterizer draws it in a few seconds, so Linux scans it)
	if ODIN_OS == .Windows && render.adapter_info(s.renderer).software { return }
	wait_settled(s)
	if !look(s).shaded { return }
	scale := s.state.scale > 0 ? s.state.scale : 1
	session.click(s, "licence_turn")
	b := session.get(s, "licence_card")
	mid := (b.rect.min + b.rect.max) * 0.5
	// (DRAG_TURNS_PER_PX = 0.45 / 360 a logical pixel: 400 for half a turn)
	from := [2]f32{b.rect.min.x + 10 * scale, mid.y}
	drag(s, from, from + [2]f32{400, 0} * scale)
	wait_settled(s)
	testing.expect(t, look(s).back, "the back shows")
	lo, hi := card_rect(s)
	_, err := read_corner(s, lo, hi)
	testing.expect(t, err != .None, "straight on, the code does not read")

	step := f32(11) / 0.45
	drag(s, mid, mid + [2]f32{step, step} * scale)
	l := look(s)
	testing.expectf(t, ui.licence_card_seal_reveal(l.rx, l.ry) > 0.99, "at the code's turn: %v, %v", l.rx, l.ry)
	address, err2 := read_corner(s, lo, hi)
	testing.expect_value(t, err2, qr.Decode_Error.None)
	testing.expect(t, address, "the code reads the hunt's address")

	// Its look at the turn: metal, not a sticker, and still far enough apart for a reader. The middle of the code (36 units
	// square about its centre at (381, 199) of the design: the turn moves it by less than 9 units on the screen, its half
	// side is 33) holds dots and the silver between them. A dot is 3 to 4 pixels wide, so its smoothed edge is a large
	// share of it: the pits' tone is their core (a low percentile of the luminance), the silver's its bright side (the
	// 90th); the silver under white, the pits dark, the gap above what a reader needs, and no channel reaches white.
	img := session.capture(s)
	k := (hi.x - lo.x) / 440
	lumas := make([dynamic]f32, context.temp_allocator)
	brightest := 0
	for y in int(lo.y + (199 - 18) * k) ..< int(lo.y + (199 + 18) * k) {
		for x in int(lo.x + (381 - 18) * k) ..< int(lo.x + (381 + 18) * k) {
			c := session.pixel(img, x, y)
			brightest = max(brightest, int(c[0]), int(c[1]), int(c[2]))
			append(&lumas, (0.2126 * f32(c[0]) + 0.7152 * f32(c[1]) + 0.0722 * f32(c[2])) / 255)
		}
	}
	testing.expectf(t, brightest < 245, "no pure white in the code: %v", brightest)
	if !testing.expect(t, len(lumas) > 100, "the code's middle sampled") { return }
	slice.sort(lumas[:])
	// (the pits are a small share of the middle: their core is the 2nd percentile; on lavapipe it is about 0.14, the
	// silver's 90th percentile about 0.79)
	dark, light := lumas[len(lumas) / 50], lumas[len(lumas) * 9 / 10]
	testing.expectf(t, light > 0.55 && light < 0.92, "the silver's luminance: %v", light)
	testing.expectf(t, dark < 0.25, "the pits' luminance: %v", dark)
	testing.expectf(t, light - dark > 0.4, "the gap a reader needs: %v - %v", light, dark)
}

// Whether a code in the bottom right of the card on the last frame reads the hunt's address, and why none was read (lo, hi:
// the card at rest; a tilt moves it a little, so a margin).
@(private = "file")
read_corner :: proc(s: ^session.Session, lo, hi: [2]f32) -> (bool, qr.Decode_Error) {
	img := session.capture(s)
	w, h := hi.x - lo.x, hi.y - lo.y
	x0, y0 := int(lo.x + w * 0.6), int(lo.y + h * 0.35)
	x1, y1 := min(int(hi.x + w * 0.04), img.width), min(int(hi.y + h * 0.04), img.height)
	cw, ch := x1 - x0, y1 - y0
	crop := make([]u8, cw * ch * 4, context.temp_allocator)
	for y in 0 ..< ch {
		copy(crop[y * cw * 4:][:cw * 4], img.rgba[((y0 + y) * img.width + x0) * 4:][:cw * 4])
	}
	// (the decoder's own temporary memory is released before it returns: its data in the heap)
	d, err := qr.decode_rgba(crop, cw, ch, cw * 4)
	defer qr.decoded_destroy(&d)
	return err == .None && string(d.data) == ui.LICENCE_CARD_SEAL_URL, err
}
