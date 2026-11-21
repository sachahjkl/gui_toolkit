package ui

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import "../render"
import turn "../turn"

// The licence card (src/md/features/licence-card.md, docs/widgets.md): a registered licence shown as an object, the same in
// every program. A dark foil engraved like a banknote, iridescent, a light that sweeps across it, the person's name raised in
// brushed silver, a gold-and-enamel seal in relief, a back with the program's logo raised; it tilts towards the pointer and
// turns over.
//
//   ui.licence_card("licence", {product = "Inspecteur", edition = "Personal licence", name = lic.name, email = lic.email,
//       date = lic.date, order = lic.order, logo = LOGO_PNG, back_line = "INSPECTEUR · FROMENT SOFTWARE"})
//
// How it is made:
//  - the card is two faces and a thickness composed in 3D: the front and the back are planes (draw.push_plane) drawn by the
//    toolkit's application shader licence_card.wgsl (two passes: the engraving's shade, then the light), the seal a plane of
//    its own above the front, the rim of the card and the edge of the seal flat facets projected and shaded by their
//    orientation. Seen from the front, the back is not drawn; seen from behind, the front and the seal are not. At rest
//    (no tilt) the planes are drawn straight, with no layer: the same pixels;
//  - its textures (the relief, the lettering, the seal, the back, the logo) are made on chores and kept with the renderer
//    (licence_card_kept.odin). Until they are there, where the shader cannot be had (Direct3D 11 without its blob, a
//    refused module), while a picture is recorded, or when the State asks for it (set_licence_card_flat), the card is drawn
//    flat: the dark gradient, the text plain, a drawn medal. It reads as well;
//  - its motion is a small state machine (Licence_Card_Memory): the tilt follows the pointer, eases back when it leaves; the
//    free mode (the Turn over button) turns it on two axes with a drag, a fling, the arrows; Escape or Done bring it home by
//    the short way. The sweep passes once when the card first shows and when the pointer comes onto it.
//  - AT REST IT ASKS FOR NO FRAME: a frame is asked only while an ease, the sweep, a fling or the button's fade runs; the
//    pointer's own moves make the frames of the tilt.
//  - With less motion (the animations off: platform.os_animations_enabled, set_animations) it does not tilt, sweep or turn,
//    and has no button: the foil lit at a fixed angle.

// What the card shows. Strings are read during the build and the frame's draw; `logo` is a constant of the program.
Licence_Card :: struct {
	product:   string,   // the program's name ("Inspecteur"): the top left, and the microprint of the frame
	edition:   string,   // the edition's title for people ("Personal licence"): the top right, in small capitals
	name:      string,   // who the licence is made out to
	email:     string,   // "": none
	date:      string,   // the day it was issued ("2026-11-16"; "": none)
	order:     string,   // the order number ("": none)
	logo:      []u8,     // the program's logo, a picture file's bytes (#load of a PNG: printed on the front, raised on the back; nil: none)
	back_line: string,   // the line along the back's bottom (the vendor's: "INSPECTEUR · FROMENT SOFTWARE"; "": the product's name)
}

// The card's look at a moment, for a test or a tool (licence_card_look).
Licence_Card_Look :: struct {
	found:      bool,    // a card of this id was built in the last build
	settled:    bool,    // its textures are made, or cannot be: its look will not change by itself any more
	shaded:     bool,    // its last draw drew the foil with the shader (else flat)
	plain_text: bool,    // its last draw drew the text plain (flat, or the lettering could not be raised)
	turned:     bool,    // the free mode is on
	back:       bool,    // its last draw showed the back
	rx, ry:     f32,     // the turn now, turns (rotateX, rotateY)
	sweeping:   bool,    // the sweep is on its way
	moving:     bool,    // something moves: the card asks for frames
}

// The card's size: its width at a font size of 15 is the 440 units of its design; its height follows (a bank card's shape).
LICENCE_CARD_WIDTH_EM :: 440.0 / 15
@(private = "file") DESIGN_W :: f32(440)
@(private = "file") DESIGN_H :: DESIGN_W / f32(LICENCE_CARD_ASPECT)
// The room above and below the card for its tilt, units.
@(private = "file") PAD :: 12
// The corner radius, the thickness (a bank card's rim: 8 shows from a tilt of 0.05 turns), the facets of a corner of the rim.
@(private = "file") RADIUS :: 14
@(private = "file") THICKNESS :: 8
@(private = "file") FACETS :: 4
// The eye's distance (CSS perspective), and the depth the card turns about (the middle of its thickness).
@(private = "file") PERSPECTIVE :: 900
@(private = "file") ORIGIN_Z :: -THICKNESS / 2
// The tilt at the card's edges, turns (rotateX, rotateY).
@(private = "file") TILT_X :: 14.0 / 360
@(private = "file") TILT_Y :: 18.0 / 360
// The eases (CSS transitions): their curve, and how long each takes, ms.
@(private = "file") EASE :: [4]f32{0.2, 0.7, 0.2, 1}
@(private = "file") EASE_BACK_MS :: 550   // the pointer gone: back to rest
@(private = "file") FLING_MS :: 1000      // a drag let go while it moved
@(private = "file") ARROW_MS :: 350       // an arrow in the free mode
@(private = "file") HOME_MS :: 750        // Done or Escape: home by the short way
@(private = "file") BUTTON_MS :: 180      // the button's fade
// The sweep: its way (the shader's 0 .. 1 with its fades), how long it takes, its curve; where it rests with less motion.
@(private = "file") SWEEP_FROM :: -0.3
@(private = "file") SWEEP_TO :: 1.25
@(private = "file") SWEEP_MS :: 2800
@(private = "file") SWEEP_CURVE :: [4]f32{0.45, 0, 0.35, 1}
@(private = "file") SWEEP_STILL :: 0.42
// The free mode: turns per pixel of a drag; a release later than this after the last move flings nothing; a fling's least
// speed (turns per ms, both axes), how far its speed takes it (ms of it), at most (turns); an arrow's step (turns).
@(private = "file") DRAG_TURNS_PER_PX :: 0.45 / 360
@(private = "file") FLING_LATE_MS :: 90
@(private = "file") FLING_LEAST :: 0.03 / 360
@(private = "file") FLING_GAIN :: 380
@(private = "file") FLING_MOST :: 300.0 / 360
@(private = "file") ARROW_STEP :: 1.0 / 12
// The seal: its middle and diameter on the design, how high it stands, the facets of its edge, its edge's radius (a hair
// under the face's, which the perspective enlarges).
@(private = "file") SEAL_X :: 380
@(private = "file") SEAL_Y :: DESIGN_H - 14 - 44
@(private = "file") SEAL_Z :: 5
@(private = "file") SEAL_SIDES :: 32
@(private = "file") SEAL_EDGE_R :: 43.75
// The logo printed on the front: where, how large.
@(private = "file") LOGO_X :: 22
@(private = "file") LOGO_Y :: 18
@(private = "file") LOGO_SIZE :: 26

// The lettering of the front, on the design (shared by the raised lettering and the plain text).
@(private) LICENCE_PRODUCT_SIZE :: 17.0
@(private) LICENCE_PRODUCT_TRACK :: 0.02
@(private) LICENCE_EDITION_SIZE :: 11.0
@(private) LICENCE_EDITION_TRACK :: 0.16
@(private) LICENCE_NAME_SIZE :: 24.0
@(private) LICENCE_EMAIL_SIZE :: 12.0
@(private) LICENCE_META_LABEL_SIZE :: 10.0
@(private) LICENCE_META_LABEL_TRACK :: 0.14
@(private) LICENCE_META_VALUE_SIZE :: 13.0
@(private) LICENCE_META_LABEL_Y :: 233.0
@(private) LICENCE_META_VALUE_Y :: 254.0
@(private = "file") TEXT_LEFT :: 22
@(private = "file") TEXT_RIGHT :: 418
@(private = "file") TEXT_ROOM :: 396        // the width the name and the e-mail fit in
@(private = "file") NAME_LEAST :: 11.0      // a long name is set smaller, down to this
@(private = "file") EMAIL_LEAST :: 8.0
@(private = "file") META_GAP :: 26

// Where the front's text goes (units of the design; y: baselines).
@(private)
Licence_Layout :: struct {
	product, edition, name, email: [2]f32,
	name_size, email_size:         f32,
	meta:                          [2]struct { label, value: string, at: [2]f32 },
	metas:                         int,
}

// The front's text laid out: the product beside the logo, the edition at the top right, the name and the e-mail in the
// middle, the date and the order at the bottom left (the seal is at the bottom right). The name and the e-mail are set
// smaller when they are wider than the card, so that they are whole.
@(private)
licence_card_layout :: proc(fs: ^font.State, faces: Engrave_Faces, c: Licence_Card) -> (l: Licence_Layout) {
	b := faces.bold
	l.product = {c.logo != nil ? 57 : TEXT_LEFT, 38}
	l.edition = {TEXT_RIGHT, 36}
	l.name_size = LICENCE_NAME_SIZE
	if w := engrave_width(fs, b, c.name, LICENCE_NAME_SIZE, 0); w > TEXT_ROOM { l.name_size = max(LICENCE_NAME_SIZE * TEXT_ROOM / w, NAME_LEAST) }
	l.name = {TEXT_LEFT, 134}
	l.email_size = LICENCE_EMAIL_SIZE
	if w := engrave_width(fs, b, c.email, LICENCE_EMAIL_SIZE, 0); w > TEXT_ROOM { l.email_size = max(LICENCE_EMAIL_SIZE * TEXT_ROOM / w, EMAIL_LEAST) }
	l.email = {TEXT_LEFT, 152}
	x := f32(TEXT_LEFT)
	pairs := [2][2]string{{licence_upper(i18n.tr("Issued")), c.date}, {licence_upper(i18n.tr("Order")), c.order}}
	for p in pairs {
		if p[1] == "" { continue }
		l.meta[l.metas] = {label = p[0], value = p[1], at = {x, LICENCE_META_LABEL_Y}}
		l.metas += 1
		x += max(engrave_width(fs, b, p[0], LICENCE_META_LABEL_SIZE, LICENCE_META_LABEL_TRACK), engrave_width(fs, b, p[1], LICENCE_META_VALUE_SIZE, 0)) + META_GAP
	}
	return
}

// `text` in capitals, in the frame's temporary memory (display text: the card's small capitals fold by Unicode).
@(private)
licence_upper :: proc(text: string) -> string {
	return strings.to_upper(text, context.temp_allocator)
}

// What a card keeps between builds (State.licence_cards; on the heap: the frame's draw holds it while other cards are built).
@(private)
Licence_Card_Memory :: struct {
	seen:        u64,      // the last build that built it
	id_hash:     u64,      // its id's (licence_card_look)
	turn:        bool,     // the free mode (Turn over)
	drag:        bool,     // a drag of the free mode is on
	live:        bool,     // the pointer is on the card
	from, to:    [4]f32,   // the ease of (rx, ry, light x, light y): turns, and 0 .. 1 on the card
	ease_t0:     f64,
	ease_ms:     f32,
	va, vb:      f32,      // the turn's speed while dragged, turns per ms
	last_at:     Vec2,
	last_ms:     f64,
	sweep_t0:    f64,      // the sweep's start (0: none yet)
	swept:       bool,     // the first show's sweep started
	button_from: f32,      // the button's fade
	button_to:   f32,
	button_t0:   f64,
	button_hot:  bool,     // the button was under the pointer or had the keyboard at the last build
	width:       f32,      // the card's width at the last layout: its height follows
	// written by the draw
	settled:     bool,
	shaded:      bool,
	plain_text:  bool,
	back:        bool,
}

// The rest: no turn, the light in the middle.
@(private = "file") REST :: [4]f32{0, 0, 0.5, 0.5}

// What the frame's draw of a card needs.
@(private = "file")
Card_Draw :: struct {
	s:         ^State,
	m:         ^Licence_Card_Memory,
	c:         Licence_Card,
	faces:     Engrave_Faces,
	seal_word: string,
	back_line: string,
	pad:       f32,       // the room above and below the card in the box, px
	turn:      [4]f32,    // rx, ry, light x, light y
	live:      f32,
	sweep:     f32,
	motion:    bool,
	flat:      bool,      // the State asks for the flat card
}

// The card (see the top of the file), as wide as LICENCE_CARD_WIDTH_EM font sizes or its parent if narrower; with motion, a
// "Turn over" button under it, shown while the pointer is on the card or the button has the keyboard. The signal is the
// card's.
licence_card :: proc(id: string, c: Licence_Card) -> Signal {
	s := gs()
	em := font_size()
	motion := s.anim_rate != 0
	now := s.time_ms
	want := math.round(LICENCE_CARD_WIDTH_EM * em)
	next_default({width = px(want, 0), height = children_sum(), axis = .Y})
	outer := build_box({}, id)
	m := licence_card_memory(s, outer.key, id)
	sig: Signal
	if parent(outer) {
		w := m.width > 0 ? m.width : want
		k := w / DESIGN_W
		pad := math.round(PAD * k)
		// (free, the card is held: a hand that grabs; else nothing to click)
		cursor := platform.Cursor.Arrow
		if m.turn { cursor = m.drag ? platform.Cursor.Grabbing : platform.Cursor.Grab }
		next({width = fill(), height = px(math.round(w / f32(LICENCE_CARD_ASPECT) + 2 * pad)), cursor = cursor})
		b := build_box({.Clickable}, "###licence_card")
		sig = signal(b)
		if b.rect.max.x > b.rect.min.x {
			cw := b.rect.max.x - b.rect.min.x
			// (the height follows the width the layout gave: one frame more when it changed)
			if abs(cw - m.width) > 0.5 { m.width = cw; s.anim_busy = true }
		}
		hover := sig.hovering || sig.dragging
		cur := card_ease_at(m, now)
		if !motion {
			m.turn, m.drag, m.live = false, false, false
			card_set(m, REST, now)
			cur = REST
		} else {
			cur = card_motion(s, m, b, sig, hover, cur, now)
		}
		// the first show's sweep: when the card first draws its foil
		if motion && m.shaded && !m.swept { m.swept, m.sweep_t0 = true, now }
		d := frame_new(Card_Draw)
		d^ = {s = s, m = m, c = card_frame_copy(c), pad = pad, turn = cur, live = m.live ? 1 : 0, motion = motion, flat = s.licence_card_flat}
		d.faces = {regular = top_style().font, bold = styled_face(top_style().font, true, false)}
		d.seal_word = strings.clone(i18n.tr("CERTIFIED"), frame_allocator())
		back := c.back_line != "" ? c.back_line : licence_upper(c.product)
		d.back_line = strings.clone(back, frame_allocator())
		d.sweep = card_sweep(m, now, motion)
		b.custom, b.custom_user = licence_card_draw, d
		a11y_default(b, {role = .Image, name = card_a11y_name(c)})
		if motion { card_button(s, m, sig, hover, now, em) }
		if card_moving(m, now, motion) { s.anim_busy = true }
	}
	return sig
}

// The card's memory for `key`, made at its first build.
@(private = "file")
licence_card_memory :: proc(s: ^State, key: Key, id: string) -> ^Licence_Card_Memory {
	m := s.licence_cards[key] or_else nil
	if m == nil {
		m = new(Licence_Card_Memory, runtime.heap_allocator())
		m.from, m.to = REST, REST
		s.licence_cards[key] = m
	}
	m.seen = s.build_index
	h := kept_hash_begin(.Logo)
	kept_hash_string(&h, hash_part(id))
	m.id_hash = h.h
	return m
}

// The frame's copy of what the card shows (the caller's strings may change before the draw).
@(private = "file")
card_frame_copy :: proc(c: Licence_Card) -> Licence_Card {
	a := frame_allocator()
	return {
		product = strings.clone(c.product, a), edition = strings.clone(c.edition, a), name = strings.clone(c.name, a),
		email = strings.clone(c.email, a), date = strings.clone(c.date, a), order = strings.clone(c.order, a),
		logo = c.logo, back_line = strings.clone(c.back_line, a),
	}
}

// What a screen reader reads of the card: all it says.
@(private = "file")
card_a11y_name :: proc(c: Licence_Card) -> string {
	b := strings.builder_make(frame_allocator())
	fmt.sbprintf(&b, i18n.tr("%s licence, %s: %s"), c.product, c.edition, c.name)
	if c.email != "" { fmt.sbprintf(&b, ", %s", c.email) }
	if c.date != "" { fmt.sbprintf(&b, i18n.tr(", issued %s"), c.date) }
	if c.order != "" { fmt.sbprintf(&b, i18n.tr(", order %s"), c.order) }
	return strings.to_string(b)
}

// The motion of a build: the pointer's tilt, or the free mode's drag, fling, arrows and way home. Returns the turn now.
@(private = "file")
card_motion :: proc(s: ^State, m: ^Licence_Card_Memory, b: ^Box, sig: Signal, hover: bool, start: [4]f32, now: f64) -> [4]f32 {
	cur := start
	size := b.rect.max - b.rect.min
	p := Vec2{0, 0}
	if size.x > 0 && size.y > 0 {
		p = {clamp((s.mouse.x - b.rect.min.x) / size.x * 2 - 1, -1, 1), clamp((s.mouse.y - b.rect.min.y) / size.y * 2 - 1, -1, 1)}
	}
	light := Vec2{0.5 + p.x * 0.5, 0.5 + p.y * 0.5}
	if hover && !m.live {
		m.live = true
		// (the pointer comes onto the card: a pass of the light, unless one is on its way; a flat card has no light to pass)
		if m.shaded && now - m.sweep_t0 >= SWEEP_MS { m.sweep_t0 = now }
	}
	if !m.turn {
		if hover {
			card_set(m, {-p.y * TILT_X, p.x * TILT_Y, light.x, light.y}, now)
			cur = m.to
		} else if m.live {
			m.live = false
			card_ease(m, cur, REST, EASE_BACK_MS, now)
		}
		return cur
	}
	// the free mode: a drag turns the card, with no limit
	scale := s.scale > 0 ? s.scale : 1
	if sig.pressed && !m.drag {
		m.drag, m.va, m.vb, m.last_at, m.last_ms = true, 0, 0, s.mouse, now
		card_set(m, cur, now)
	}
	if m.drag && sig.dragging {
		d := (s.mouse - m.last_at) / scale
		da, db := -d.y * DRAG_TURNS_PER_PX, d.x * DRAG_TURNS_PER_PX
		if d != {} {
			dt := f32(max(1, now - m.last_ms))
			m.va, m.vb = 0.6 * da / dt + 0.4 * m.va, 0.6 * db / dt + 0.4 * m.vb
			m.last_at, m.last_ms = s.mouse, now
		}
		card_set(m, {cur[0] + da, cur[1] + db, light.x, light.y}, now)
		return m.to
	}
	if m.drag {
		// let go: the card keeps turning for a moment, slowing down
		m.drag = false
		if now - m.last_ms > FLING_LATE_MS { m.va, m.vb = 0, 0 }
		if abs(m.va) + abs(m.vb) > FLING_LEAST {
			to := cur
			to[0] += clamp(m.va * FLING_GAIN, -FLING_MOST, FLING_MOST)
			to[1] += clamp(m.vb * FLING_GAIN, -FLING_MOST, FLING_MOST)
			card_ease(m, cur, to, FLING_MS, now)
		}
	}
	if hover && !card_easing(m, now) {
		m.to[2], m.to[3], m.from[2], m.from[3] = light.x, light.y, light.x, light.y
		cur[2], cur[3] = light.x, light.y
	}
	if !hover { m.live = false }
	if key_press(.Escape) {
		card_home(m, cur, now)
		return card_ease_at(m, now)
	}
	return cur
}

// The free mode ends: home to the pointer's tilt by the short way (the turn taken modulo a whole turn: the card does not
// unwind a spin).
@(private = "file")
card_home :: proc(m: ^Licence_Card_Memory, cur: [4]f32, now: f64) {
	from := cur
	from[0] -= math.round(from[0])
	from[1] -= math.round(from[1])
	m.turn, m.drag, m.live = false, false, false
	card_ease(m, from, REST, HOME_MS, now)
}

// The button under the card: Turn over (the free mode on), Done (off). Its fade follows the pointer on the card and its own
// state; the arrows turn the card while it is free and the button or the card has the keyboard or the pointer.
@(private = "file")
card_button :: proc(s: ^State, m: ^Licence_Card_Memory, card: Signal, hover: bool, now: f64, em: f32) {
	shown := hover || m.button_hot || m.turn
	target: f32 = shown ? 1 : 0
	if target != m.button_to {
		m.button_from, m.button_to, m.button_t0 = card_button_at(m, now), target, now
	}
	words_off, words_on := i18n.tr("Turn over"), i18n.tr("Done")
	st := top_style()
	wide := max(text_width(st.font, st.font_size, words_off), text_width(st.font, st.font_size, words_on))
	next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
	if row(.Center, id = "###licence_card_bar") {
		spacer(fill())
		next({transparency = 1 - card_button_at(m, now)})
		tip := m.turn ? i18n.tr("Drag the card to turn it; the arrows turn it too; Escape brings it back") : i18n.tr("Turn the card over")
		bsig := button("licence_turn", m.turn ? words_on : words_off, m.turn ? lucide.CHECK : lucide.REFRESH_CW,
			{icon_font = lucide_icons(), face = .Ghost, quiet = true, width = px(math.round(wide + em * 3.2)), tip = tip})
		m.button_hot = bsig.hovering || bsig.focused
		if bsig.clicked {
			if m.turn { card_home(m, card_ease_at(m, now), now) } else { m.turn = true }
		}
		if m.turn && (bsig.focused || card.hovering) {
			step := [4]f32{}
			if key_press(.Left)  { step[1] -= ARROW_STEP }
			if key_press(.Right) { step[1] += ARROW_STEP }
			if key_press(.Up)    { step[0] += ARROW_STEP }
			if key_press(.Down)  { step[0] -= ARROW_STEP }
			if step != {} {
				cur := card_ease_at(m, now)
				to := cur + step
				card_ease(m, cur, to, ARROW_MS, now)
			}
		}
	}
}

// The ease's values now.
@(private = "file")
card_ease_at :: proc(m: ^Licence_Card_Memory, now: f64) -> [4]f32 {
	if m.ease_ms <= 0 { return m.to }
	t := f32((now - m.ease_t0) / f64(m.ease_ms))
	if t >= 1 { return m.to }
	e := EASE
	k := bezier_ease(e, max(t, 0))
	return m.from + (m.to - m.from) * k
}

@(private = "file")
card_easing :: proc(m: ^Licence_Card_Memory, now: f64) -> bool { return m.ease_ms > 0 && now - m.ease_t0 < f64(m.ease_ms) }

// The values at once (the pointer's tilt, a drag).
@(private = "file")
card_set :: proc(m: ^Licence_Card_Memory, v: [4]f32, now: f64) {
	m.from, m.to, m.ease_t0, m.ease_ms = v, v, now, 0
}

// An ease from `from` to `to` over `ms`.
@(private = "file")
card_ease :: proc(m: ^Licence_Card_Memory, from, to: [4]f32, ms: f32, now: f64) {
	m.from, m.to, m.ease_t0, m.ease_ms = from, to, now, ms
}

@(private = "file")
card_button_at :: proc(m: ^Licence_Card_Memory, now: f64) -> f32 {
	t := f32((now - m.button_t0) / BUTTON_MS)
	if t >= 1 { return m.button_to }
	return m.button_from + (m.button_to - m.button_from) * max(t, 0)
}

// Where the sweep is: off before its first pass and after each, on its way between; fixed with less motion.
@(private = "file")
card_sweep :: proc(m: ^Licence_Card_Memory, now: f64, motion: bool) -> f32 {
	if !motion { return SWEEP_STILL }
	if m.sweep_t0 == 0 { return SWEEP_FROM }
	e := f32((now - m.sweep_t0) / SWEEP_MS)
	if e >= 1 { return SWEEP_TO }
	c := SWEEP_CURVE
	return SWEEP_FROM + (SWEEP_TO - SWEEP_FROM) * bezier_ease(c, max(e, 0))
}

// Whether something of the card moves now: an ease, the sweep, the button's fade (the pointer's tilt moves with the
// pointer's own events: no frame of its own).
@(private = "file")
card_moving :: proc(m: ^Licence_Card_Memory, now: f64, motion: bool) -> bool {
	if !motion { return false }
	if card_easing(m, now) { return true }
	if m.sweep_t0 != 0 && now - m.sweep_t0 < SWEEP_MS { return true }
	return now - m.button_t0 < BUTTON_MS && m.button_from != m.button_to
}

// CSS's cubic-bezier(x1, y1, x2, y2) at `x` (0 .. 1): the time solved by Newton's steps, then the value.
@(private)
bezier_ease :: proc(c: [4]f32, x: f32) -> f32 {
	if x <= 0 { return 0 }
	if x >= 1 { return 1 }
	at :: proc(a, b, t: f32) -> f32 { u := 1 - t; return 3 * a * u * u * t + 3 * b * u * t * t + t * t * t }
	slope :: proc(a, b, t: f32) -> f32 { u := 1 - t; return 3 * a * u * u + 6 * (b - a) * u * t + 3 * (1 - b) * t * t }
	t := x
	for _ in 0 ..< 8 {
		d := at(c[0], c[2], t) - x
		if abs(d) < 1e-5 { break }
		sl := slope(c[0], c[2], t)
		if abs(sl) < 1e-6 { break }
		t = clamp(t - d / sl, 0, 1)
	}
	return at(c[1], c[3], t)
}

// Every card of the State drawn flat (no shader: the same picture on every device; a test of the fallback). Off by default.
set_licence_card_flat :: proc(s: ^State, on: bool) {
	s.licence_card_flat = on
	s.anim_busy = true
}

// The look of the card `id` (as licence_card was given it) at the last build and draw of `s`: for a test or a tool.
licence_card_look :: proc(s: ^State, id: string) -> Licence_Card_Look {
	h := kept_hash_begin(.Logo)
	kept_hash_string(&h, hash_part(id))
	for _, m in s.licence_cards {
		if m.id_hash != h.h || m.seen != s.build_index { continue }
		now := s.time_ms
		cur := card_ease_at(m, now)
		motion := s.anim_rate != 0
		return {
			found = true, settled = m.settled, shaded = m.shaded, plain_text = m.plain_text, turned = m.turn, back = m.back, rx = cur[0], ry = cur[1],
			sweeping = motion && m.sweep_t0 != 0 && now - m.sweep_t0 < SWEEP_MS, moving = card_moving(m, now, motion),
		}
	}
	return {}
}

// The cards this build did not build.
@(private)
licence_card_trim :: proc(s: ^State) {
	if len(s.licence_cards) == 0 { return }
	dead := make([dynamic]Key, context.temp_allocator)
	for k, m in s.licence_cards { if m.seen != s.build_index { append(&dead, k) } }
	for k in dead {
		free(s.licence_cards[k], runtime.heap_allocator())
		delete_key(&s.licence_cards, k)
	}
}

@(private)
licence_card_destroy :: proc(s: ^State) {
	for _, m in s.licence_cards { free(m, runtime.heap_allocator()) }
	delete(s.licence_cards)
}

////////////////////////////////
// The draw

// The textures of a card's draw, and what each is ready for.
@(private = "file")
Card_Textures :: struct {
	shader:                        render.App_Shader,
	relief, lettering:             render.Texture,
	seal_relief, seal_lettering:   render.Texture,
	back_relief, back_lettering:   render.Texture,
	logo:                          render.Texture,
	front, seal, back:             bool,   // each drawn with the shader
	settled:                       bool,   // every texture asked for is made, or cannot be
}

@(private = "file")
Input_Ask :: struct {
	d:  ^Card_Draw,
	fs: ^font.State,
}

// What a texture is made of (kept_texture's `input`): taken on this thread, the lettering's glyphs too.
@(private = "file")
card_input :: proc(kind: Licence_Texture, user: rawptr) -> (in_: Kept_Input, ok: bool) {
	a := (^Input_Ask)(user)
	d := a.d
	heap := runtime.heap_allocator()
	switch kind {
	case .Front_Relief:
		in_.word = strings.clone(d.c.product, heap)
	case .Back_Relief:
		in_.word, in_.logo = strings.clone(d.c.product, heap), d.c.logo
	case .Seal_Relief:
	case .Logo:
		if len(d.c.logo) == 0 { return {}, false }
		in_.logo = d.c.logo
	case .Front_Lettering, .Seal_Lettering, .Back_Lettering:
		if a.fs == nil { return {}, false }
		made: bool
		#partial switch kind {
		case .Front_Lettering: made = engrave_front(a.fs, d.faces, d.c, &in_.engrave)
		case .Seal_Lettering:  made = engrave_seal(a.fs, d.faces, d.seal_word, &in_.engrave)
		case:                  made = engrave_back(a.fs, d.faces, d.back_line, &in_.engrave)
		}
		if !made { engrave_input_destroy(&in_.engrave); return {}, false }
	}
	return in_, true
}

// The key of each texture of the card: what it is made of.
@(private = "file")
card_key :: proc(d: ^Card_Draw, kind: Licence_Texture) -> u64 {
	h := kept_hash_begin(kind)
	switch kind {
	case .Front_Relief:
		kept_hash_string(&h, d.c.product)
	case .Back_Relief:
		kept_hash_string(&h, d.c.product)
		kept_hash_u64(&h, u64(uintptr(raw_data(d.c.logo))))
		kept_hash_u64(&h, u64(len(d.c.logo)))
	case .Seal_Relief:
	case .Logo:
		kept_hash_u64(&h, u64(uintptr(raw_data(d.c.logo))))
		kept_hash_u64(&h, u64(len(d.c.logo)))
	case .Front_Lettering:
		for f in ([]string{d.c.product, d.c.edition, d.c.name, d.c.email, d.c.date, d.c.order, i18n.tr("Issued"), i18n.tr("Order")}) { kept_hash_string(&h, f) }
		kept_hash_u64(&h, u64(d.faces.bold))
		kept_hash_u64(&h, u64(d.c.logo != nil))
	case .Seal_Lettering:
		kept_hash_string(&h, d.seal_word)
		kept_hash_u64(&h, u64(d.faces.bold))
	case .Back_Lettering:
		kept_hash_string(&h, d.back_line)
		kept_hash_u64(&h, u64(d.faces.bold))
	}
	return h.h
}

// The card's textures on this renderer, asking a chore for those that are not there. Each face is drawn with the shader once
// its relief and its lettering are settled (a lettering that cannot be raised: the text plain over the foil).
@(private = "file")
card_textures :: proc(dc: ^draw.Context, d: ^Card_Draw) -> (t: Card_Textures) {
	if dc.renderer == nil { return }
	shader := kept_sync(dc.renderer)
	ask := Input_Ask{d = d, fs = dc.fonts}
	get :: proc(dc: ^draw.Context, d: ^Card_Draw, ask: ^Input_Ask, kind: Licence_Texture) -> (render.Texture, bool) {
		return kept_texture(dc.renderer, d.s, dc.frame_no, kind, card_key(d, kind), card_input, ask)
	}
	settled: [Licence_Texture]bool
	// (the logo is a picture: the flat card prints it too)
	t.logo, settled[.Logo] = get(dc, d, &ask, .Logo)
	t.settled = settled[.Logo]
	if shader == 0 || d.flat || dc.rec != nil { return }
	t.shader = shader
	t.relief, settled[.Front_Relief] = get(dc, d, &ask, .Front_Relief)
	t.lettering, settled[.Front_Lettering] = get(dc, d, &ask, .Front_Lettering)
	t.seal_relief, settled[.Seal_Relief] = get(dc, d, &ask, .Seal_Relief)
	t.seal_lettering, settled[.Seal_Lettering] = get(dc, d, &ask, .Seal_Lettering)
	t.front = t.relief != 0 && settled[.Front_Lettering]
	t.seal = t.seal_relief != 0 && t.seal_lettering != 0
	// (the back only where the card can be turned over)
	if d.motion {
		t.back_relief, settled[.Back_Relief] = get(dc, d, &ask, .Back_Relief)
		t.back_lettering, settled[.Back_Lettering] = get(dc, d, &ask, .Back_Lettering)
		t.back = t.back_relief != 0 && settled[.Back_Lettering]
	} else {
		settled[.Back_Relief], settled[.Back_Lettering] = true, true
	}
	t.settled = true
	for k in settled { t.settled = t.settled && k }
	return
}

@(private = "file")
licence_card_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Card_Draw)(user)
	m := d.m
	card := draw.Rect{{b.rect.min.x, b.rect.min.y + d.pad}, {b.rect.max.x, b.rect.max.y - d.pad}}
	w := card.max.x - card.min.x
	if w <= 0 || card.max.y <= card.min.y { return }
	k := w / DESIGN_W
	t := card_textures(dc, d)
	m.settled = t.settled
	m.shaded = t.front
	m.plain_text = !t.front || t.lettering == 0
	// a soft shadow on the page under the card: it lies on the page, it does not turn with the card
	draw.box_shadow(dc, draw.rect_shift(card, {0, 6 * k}), {RADIUS * k, RADIUS * k, RADIUS * k, RADIUS * k}, 10 * k, {0, 0, 0, 0.28})
	rx, ry := d.turn[0], d.turn[1]
	flat_on_screen := abs(rx) < 0.01 / 360 && abs(ry) < 0.01 / 360
	if flat_on_screen || dc.rec != nil {
		// at rest the planes would be drawn straight: drawn so at once, with no layer
		m.back = false
		draw.push_transform(dc, draw.Affine{a = k, d = k, e = card.min.x, f = card.min.y})
		card_front(dc, d, &t, k)
		draw.push_transform(dc, draw.Affine{a = 1, d = 1, e = SEAL_X - 44, f = SEAL_Y - 44})
		card_seal(dc, d, &t)
		draw.pop_transform(dc)
		draw.pop_transform(dc)
		return
	}
	center := (card.min + card.max) * 0.5
	view := card_view(k, center)
	world := card_world(rx, ry)
	vw := draw.mat4_mul(view, world)
	front := card_faces_eye(world, {0, 0, 0}, {0, 0, 1})
	m.back = !front
	card_rim(dc, vw, world)
	if front {
		draw.push_plane(dc, {{0, 0}, {DESIGN_W, DESIGN_H}}, k)
		card_front(dc, d, &t, k)
		draw.pop_plane_draw(dc, draw.mat4_mul(vw, m4_translate(-DESIGN_W / 2, -DESIGN_H / 2, 0)), 1, {cull_back = true})
		card_seal_edge(dc, vw, world)
		// (the seal's face SEAL_Z above the card, made smaller by as much as the perspective enlarges it: at rest it is where the
		// flat card has it)
		k_seal := f32(PERSPECTIVE - SEAL_Z) / PERSPECTIVE
		at := Vec2{SEAL_X - DESIGN_W / 2, SEAL_Y - DESIGN_H / 2}
		local := draw.mat4_mul(m4_translate(at.x, at.y, SEAL_Z), draw.mat4_mul(m4_scale(k_seal, k_seal, 1), m4_translate(-44, -44, 0)))
		draw.push_plane(dc, {{0, 0}, {88, 88}}, k)
		card_seal(dc, d, &t)
		draw.pop_plane_draw(dc, draw.mat4_mul(vw, local), 1, {cull_back = true})
	} else {
		// the back: laid on the card's other side, turned half a turn about the vertical axis
		local := draw.mat4_mul(m4_translate(0, 0, -THICKNESS), draw.mat4_mul(m4_rot_y(0.5), m4_translate(-DESIGN_W / 2, -DESIGN_H / 2, 0)))
		draw.push_plane(dc, {{0, 0}, {DESIGN_W, DESIGN_H}}, k)
		card_back(dc, d, &t)
		draw.pop_plane_draw(dc, draw.mat4_mul(vw, local), 1, {cull_back = true})
	}
}

// Screen pixels from the design's units centred on the card: the perspective of an eye PERSPECTIVE units in front, then
// `k` pixels a unit about the card's middle on the screen.
@(private = "file")
card_view :: proc(k: f32, center: Vec2) -> draw.Mat4 {
	persp := draw.MAT4_IDENTITY
	persp[11] = -1.0 / PERSPECTIVE
	screen := draw.Mat4{k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1, 0, center.x, center.y, 0, 1}
	return draw.mat4_mul(screen, persp)
}

// The card's turn: rotateX(rx) rotateY(ry) about the middle of its thickness (CSS's order: the y turn first).
@(private = "file")
card_world :: proc(rx, ry: f32) -> draw.Mat4 {
	return draw.mat4_mul(m4_translate(0, 0, ORIGIN_Z), draw.mat4_mul(m4_rot_x(rx), draw.mat4_mul(m4_rot_y(ry), m4_translate(0, 0, -ORIGIN_Z))))
}

@(private = "file")
m4_translate :: proc(x, y, z: f32) -> draw.Mat4 { return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1} }

@(private = "file")
m4_scale :: proc(x, y, z: f32) -> draw.Mat4 { return {x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1} }

@(private = "file")
m4_rot_x :: proc(turns: f32) -> draw.Mat4 {
	s, c := turn.sincos(turns)
	return {1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1}
}

@(private = "file")
m4_rot_y :: proc(turns: f32) -> draw.Mat4 {
	s, c := turn.sincos(turns)
	return {c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1}
}

// A direction turned by the card (no translation).
@(private = "file")
card_turn_dir :: proc(world: draw.Mat4, n: [3]f32) -> [3]f32 {
	return {
		world[0] * n.x + world[4] * n.y + world[8] * n.z,
		world[1] * n.x + world[5] * n.y + world[9] * n.z,
		world[2] * n.x + world[6] * n.y + world[10] * n.z,
	}
}

// Whether a face of the card at `p` (design units, centred) with the outward normal `n` faces the eye once turned.
@(private = "file")
card_faces_eye :: proc(world: draw.Mat4, p, n: [3]f32) -> bool {
	q := draw.mat4_apply(world, p)
	nw := card_turn_dir(world, n)
	eye := [3]f32{0, 0, PERSPECTIVE} - q.xyz
	return nw.x * eye.x + nw.y * eye.y + nw.z * eye.z > 0
}

// A point of the design (centred) on the screen.
@(private = "file")
card_project :: proc(vw: draw.Mat4, p: [3]f32) -> Vec2 {
	q := draw.mat4_apply(vw, p)
	w := max(q.w, 1e-4)
	return {q.x / w, q.y / w}
}

// One flat facet of a side, from (a, b) at z0 to z1, its outward normal `n` in the card's plane: drawn when it faces the eye,
// shaded by its turned normal against a light from the top left, between `dark` and `light` (sRGB, 0 .. 255).
@(private = "file")
card_facet :: proc(dc: ^draw.Context, vw, world: draw.Mat4, a, b: Vec2, z0, z1: f32, n: Vec2, dark, light: [3]f32) {
	mid := [3]f32{(a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (z0 + z1) * 0.5}
	if !card_faces_eye(world, mid, {n.x, n.y, 0}) { return }
	nw := card_turn_dir(world, {n.x, n.y, 0})
	k := clamp(0.5 + 0.5 * (nw.x * -0.6 + nw.y * -0.8 + nw.z * 0.35), 0, 1)
	c := dark + (light - dark) * k
	p := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&p, card_project(vw, {a.x, a.y, z0}))
	draw.path_line_to(&p, card_project(vw, {b.x, b.y, z0}))
	draw.path_line_to(&p, card_project(vw, {b.x, b.y, z1}))
	draw.path_line_to(&p, card_project(vw, {a.x, a.y, z1}))
	draw.path_close(&p)
	draw.path_fill(dc, &p, draw.srgb(c.r / 255, c.g / 255, c.b / 255))
}

// The rim of the card: its outline (the four sides and the rounded corners cut into FACETS flat strips) stood up from the
// front (z 0) to the back (z -THICKNESS). The faces of a convex solid that face the eye never cover each other: drawn in
// any order, before the face.
@(private = "file")
card_rim :: proc(dc: ^draw.Context, vw, world: draw.Mat4) {
	hw, hh := DESIGN_W / 2, DESIGN_H / 2
	pts := make([dynamic]Vec2, 0, 4 * (FACETS + 1), context.temp_allocator)
	// the corners clockwise from the top left (y down): their centres, and the angle each arc starts at
	centres := [4]Vec2{{-hw + RADIUS, -hh + RADIUS}, {hw - RADIUS, -hh + RADIUS}, {hw - RADIUS, hh - RADIUS}, {-hw + RADIUS, hh - RADIUS}}
	for c, i in centres {
		a0 := 0.5 + 0.25 * f32(i)
		for f in 0 ..= FACETS {
			s, k := turn.sincos(a0 + f32(f) * (0.25 / FACETS))
			append(&pts, c + Vec2{k, s} * RADIUS)
		}
	}
	dark, light := [3]f32{22, 26, 42}, [3]f32{176, 186, 222}
	for i in 0 ..< len(pts) {
		a, b := pts[i], pts[(i + 1) % len(pts)]
		e := b - a
		if e.x * e.x + e.y * e.y < 1e-6 { continue }
		l := math.sqrt(e.x * e.x + e.y * e.y)
		card_facet(dc, vw, world, a, b, 0, -THICKNESS, {e.y / l, -e.x / l}, dark, light)
	}
}

// The edge of the seal: a coin's milled rim, SEAL_SIDES strips round it, from the card to the seal's face.
@(private = "file")
card_seal_edge :: proc(dc: ^draw.Context, vw, world: draw.Mat4) {
	c := Vec2{SEAL_X - DESIGN_W / 2, SEAL_Y - DESIGN_H / 2}
	dark, light := [3]f32{96, 66, 14}, [3]f32{222, 182, 78}
	for i in 0 ..< SEAL_SIDES {
		s0, c0 := turn.sincos(f32(i) / SEAL_SIDES)
		s1, c1 := turn.sincos(f32(i + 1) / SEAL_SIDES)
		sm, cm := turn.sincos((f32(i) + 0.5) / SEAL_SIDES)
		p0 := c + Vec2{c0, s0} * SEAL_EDGE_R
		p1 := c + Vec2{c1, s1} * SEAL_EDGE_R
		card_facet(dc, vw, world, p0, p1, 0, SEAL_Z, {cm, sm}, dark, light)
	}
}

// The shader's parameters: the engine's slot, the pass, the light, the mode and the turn (licence_card.wgsl reads the back's
// engraved code from the slot after them).
@(private = "file") CARD_PARAMS :: 5
@(private = "file")
card_params :: proc(d: ^Card_Draw, size: Vec2, k: f32, pass: int, engrave: f32, mode: f32) -> [CARD_PARAMS]draw.Vec4 {
	return {
		{size.x, size.y, k, d.motion ? 0 : 1},
		{f32(pass), 0, 0, 0},
		{d.sweep, d.turn[2], d.turn[3], d.live},
		// (the shader takes the turn in degrees: its compiled form is rebuilt on Windows only)
		{1, engrave, mode, turn.to_degrees(d.turn[0])},
		{turn.to_degrees(d.turn[1]), 0, 0, 0},
	}
}

// The dark gradient of the card's ground (CSS: linear-gradient(<angle>, #232a40, #151926 58 %, #1c2132)) and its edge.
@(private = "file")
card_ground :: proc(dc: ^draw.Context, angle: f32) {
	r := draw.Rect{{0, 0}, {DESIGN_W, DESIGN_H}}
	radii := [4]f32{RADIUS, RADIUS, RADIUS, RADIUS}
	draw.rect(dc, r, draw.hex(0x161a26ff), RADIUS)
	// (`angle` in turns, clockwise from up as CSS's)
	s, c := turn.sincos(angle)
	dir := Vec2{s, -c}
	half := (abs(DESIGN_W * dir.x) + abs(DESIGN_H * dir.y)) * 0.5
	mid := Vec2{DESIGN_W, DESIGN_H} * 0.5
	stops := [3]draw.Gradient_Stop{{color = draw.hex(0x232a40ff), pos = 0}, {color = draw.hex(0x151926ff), pos = 0.58}, {color = draw.hex(0x1c2132ff), pos = 1}}
	draw.gradient(dc, r, {kind = .Linear, start = mid - dir * half, end = mid + dir * half, stops = stops[:], dither = true}, radii)
}

@(private = "file")
card_edge :: proc(dc: ^draw.Context) {
	draw.rect(dc, {{0, 0}, {DESIGN_W, DESIGN_H}}, {1, 1, 1, 0.16}, RADIUS, 1)
}

// Text on the card at `at` (left, baseline; its right edge when `right`), in units of the design.
@(private = "file")
card_text :: proc(dc: ^draw.Context, face: font.Font_Id, size: f32, at: [2]f32, color: draw.Color, text: string, track: f32 = 0, right := false) {
	if text == "" || dc.fonts == nil { return }
	o := font.Shape_Options{letter_spacing = track * size}
	x := at.x
	if right { x -= font.measure(dc.fonts, face, size, text, o) - track * size }
	draw.text_ex(dc, face, size, {x, at.y}, color, text, o)
}

// The front, in units of the design: the ground, the foil (or the flat card), the logo printed on it, the seal's shadow, the
// text plain where it is not raised.
@(private = "file")
card_front :: proc(dc: ^draw.Context, d: ^Card_Draw, t: ^Card_Textures, k: f32) {
	card_ground(dc, 150.0 / 360)
	size := Vec2{DESIGN_W, DESIGN_H}
	r := draw.Rect{{0, 0}, size}
	radii := [4]f32{RADIUS, RADIUS, RADIUS, RADIUS}
	engrave: f32 = t.lettering != 0 ? 1 : 0
	if t.front {
		for pass in 0 ..< 2 {
			p := card_params(d, size, k, pass, engrave, 0)
			draw.app_shader(dc, t.shader, r, p[:], {t.relief, t.lettering}, pass == 0 ? .Normal : .Add, radii)
		}
	}
	card_edge(dc)
	// (the pointer's parallax of what stands over the foil: the seal's shadow slides away from it, the plain text with it)
	fx, fy := (d.turn[2] - 0.5) * 2, (d.turn[3] - 0.5) * 2
	if d.m.turn { fx, fy = 0, 0 }
	if t.logo != 0 {
		at := Vec2{LOGO_X, LOGO_Y}
		box := draw.Rect{at, at + LOGO_SIZE}
		draw.image(dc, t.logo, draw.rect_shift(box, {0, 1}), tint = {0, 0, 0, 0.55})
		draw.image(dc, t.logo, box)
	}
	shadow_at := Vec2{SEAL_X + 3 - fx * 5, SEAL_Y + 5 - fy * 4}
	draw.box_shadow(dc, {shadow_at - 31, shadow_at + 31}, {31, 31, 31, 31}, 3.5, {0, 0, 0, 0.6})
	if engrave == 0 || !t.front {
		card_plain_text(dc, d, {-fx * 2, -fy * 1.6})
	}
}

// The front's text plain (the flat card, or a lettering that cannot be raised), moved by `shift` (the parallax).
@(private = "file")
card_plain_text :: proc(dc: ^draw.Context, d: ^Card_Draw, shift: Vec2) {
	if dc.fonts == nil { return }
	l := licence_card_layout(dc.fonts, d.faces, d.c)
	b := d.faces.bold
	ink :: proc(a: f32) -> draw.Color { return draw.srgb(236.0 / 255, 239.0 / 255, 247.0 / 255, a) }
	draw.push_transform(dc, draw.Affine{a = 1, d = 1, e = shift.x, f = shift.y})
	defer draw.pop_transform(dc)
	card_text(dc, b, LICENCE_PRODUCT_SIZE, l.product, ink(1), d.c.product, LICENCE_PRODUCT_TRACK)
	card_text(dc, b, LICENCE_EDITION_SIZE, l.edition, ink(0.66), licence_upper(d.c.edition), LICENCE_EDITION_TRACK, right = true)
	card_text(dc, b, l.name_size, l.name, ink(1), d.c.name)
	card_text(dc, d.faces.regular, l.email_size, l.email, ink(0.6), d.c.email)
	for mt in l.meta[:l.metas] {
		card_text(dc, b, LICENCE_META_LABEL_SIZE, {mt.at.x, LICENCE_META_LABEL_Y}, ink(0.5), mt.label, LICENCE_META_LABEL_TRACK)
		card_text(dc, d.faces.regular, LICENCE_META_VALUE_SIZE, {mt.at.x, LICENCE_META_VALUE_Y}, ink(1), mt.value)
	}
}

// The seal, in its own units (0 .. 88): lit by the shader, or the drawn medal.
@(private = "file")
card_seal :: proc(dc: ^draw.Context, d: ^Card_Draw, t: ^Card_Textures) {
	r := draw.Rect{{0, 0}, {88, 88}}
	if t.seal {
		for pass in 0 ..< 2 {
			p := card_params(d, {88, 88}, 1, pass, 1, 1)
			draw.app_shader(dc, t.shader, r, p[:], {t.seal_relief, t.seal_lettering}, pass == 0 ? .Normal : .Add, {44, 44, 44, 44})
		}
		return
	}
	card_medal(dc, d)
}

// The medal drawn without the shader (Wren's layers): a reeded gold edge, a green enamel face with fine rings and a gold
// rim, a gloss that follows the pointer, the word and the tick in cream gold.
@(private = "file")
card_medal :: proc(dc: ^draw.Context, d: ^Card_Draw) {
	full := draw.Rect{{0, 0}, {88, 88}}
	round := [4]f32{44, 44, 44, 44}
	// the reeded edge: gold stripes round it, every 8 degrees
	g1, g2, g3 := draw.hex(0xf6e29aff), draw.hex(0xd3a93dff), draw.hex(0x8f6a1cff)
	// (a conic's 0 .. 1 is a whole turn: the stops span the 8 degrees of one period, and repeat)
	reeds := [6]draw.Gradient_Stop{{color = g1, pos = 0}, {color = g1, pos = 1.5 / 360}, {color = g2, pos = 1.5 / 360}, {color = g2, pos = 5.0 / 360}, {color = g3, pos = 5.0 / 360}, {color = g3, pos = 8.0 / 360}}
	draw.gradient(dc, full, {kind = .Conic, repeating = true, center = {44, 44}, stops = reeds[:]}, round)
	draw.rect(dc, full, {0, 0, 0, 0.4}, 44, 1)
	draw.rect(dc, {{1, 1}, {87, 87}}, {1, 1, 1, 0.35}, 43, 1)
	// the enamel face
	face := draw.Rect{{6, 6}, {82, 82}}
	enamel := [3]draw.Gradient_Stop{{color = draw.hex(0x5ad98eff), pos = 0}, {color = draw.hex(0x1f8a52ff), pos = 0.55}, {color = draw.hex(0x0f5a36ff), pos = 1}}
	draw.gradient(dc, face, {kind = .Radial, center = {76 * 0.34, 76 * 0.28}, radii = {74.2, 74.2}, stops = enamel[:]}, {38, 38, 38, 38})
	rings := [4]draw.Gradient_Stop{{color = {1, 1, 1, 0.09}, pos = 0}, {color = {1, 1, 1, 0.09}, pos = 1.0 / 3}, {color = {1, 1, 1, 0}, pos = 1.0 / 3}, {color = {1, 1, 1, 0}, pos = 1}}
	draw.gradient(dc, face, {kind = .Radial, repeating = true, center = {38, 38}, radii = {3, 3}, stops = rings[:]}, {38, 38, 38, 38})
	draw.rect(dc, face, draw.hex(0xf4df9aff), 38, 2)
	draw.rect(dc, {{12, 12}, {76, 76}}, draw.srgb(244.0 / 255, 223.0 / 255, 154.0 / 255, 0.6), 32, 1)
	// the gloss, where the pointer's light is
	gx, gy := 50 + (d.turn[2] - 0.5) * 2 * 28, 50 + (d.turn[3] - 0.5) * 2 * 28
	gloss := [2]draw.Gradient_Stop{{color = {1, 1, 1, 0.55}, pos = 0}, {color = {1, 1, 1, 0}, pos = 1}}
	draw.gradient(dc, face, {kind = .Radial, center = {76 * gx / 100, 76 * gy / 100}, radii = {34, 34}, stops = gloss[:]}, {38, 38, 38, 38})
	// the word and the tick, embossed: a dark line under, a light one over
	if dc.fonts != nil {
		size := seal_word_size(dc.fonts, d.faces.bold, d.seal_word)
		o := font.Shape_Options{letter_spacing = LICENCE_SEAL_WORD_TRACK * size}
		w := font.measure(dc.fonts, d.faces.bold, size, d.seal_word, o) - LICENCE_SEAL_WORD_TRACK * size
		x := 44 - w / 2
		draw.text_ex(dc, d.faces.bold, size, {x, LICENCE_SEAL_WORD_BASELINE + 1}, {0, 0, 0, 0.5}, d.seal_word, o)
		draw.text_ex(dc, d.faces.bold, size, {x, LICENCE_SEAL_WORD_BASELINE}, draw.hex(0xf7e9b0ff), d.seal_word, o)
	}
	tick := LICENCE_SEAL_TICK
	shade := [3]Vec2{tick[0] + {0, 2}, tick[1] + {0, 2}, tick[2] + {0, 2}}
	draw.polyline(dc, shade[:], LICENCE_SEAL_TICK_W, {0, 0, 0, 0.45})
	pts := [3]Vec2{tick[0], tick[1], tick[2]}
	draw.polyline(dc, pts[:], LICENCE_SEAL_TICK_W, draw.hex(0xfbf0c4ff))
}

// The back, in units of the design: the ground turned the other way, the foil struck from behind with the logo raised and
// the code engraved (or, flat, the logo and the code faint), the line along the bottom.
@(private = "file")
card_back :: proc(dc: ^draw.Context, d: ^Card_Draw, t: ^Card_Textures) {
	card_ground(dc, 210.0 / 360)
	size := Vec2{DESIGN_W, DESIGN_H}
	engrave: f32 = t.back_lettering != 0 ? 1 : 0
	if t.back {
		for pass in 0 ..< 2 {
			// (the card's parameters, then the engraved code's: its place, the turn that reveals it, its matrix)
			base := card_params(d, size, 1, pass, engrave, 2)
			p: [CARD_PARAMS + LICENCE_SEAL_PARAMS]draw.Vec4
			copy(p[:], base[:])
			seal_params(p[CARD_PARAMS:], d.m.width / DESIGN_W)
			draw.app_shader(dc, t.shader, {{0, 0}, size}, p[:], {t.back_relief, t.back_lettering}, pass == 0 ? .Normal : .Add, {RADIUS, RADIUS, RADIUS, RADIUS})
		}
	} else {
		if t.logo != 0 {
			side: f32 = 140
			at := Vec2{DESIGN_W / 2, DESIGN_H / 2 - 8} - side / 2
			draw.image(dc, t.logo, {at, at + side}, tint = {1, 1, 1, 0.22})
		}
		seal_draw_flat(dc)
	}
	card_edge(dc)
	if !t.back || engrave == 0 {
		if dc.fonts == nil { return }
		o := font.Shape_Options{letter_spacing = LICENCE_BACK_TEXT_TRACK * LICENCE_BACK_TEXT_SIZE}
		w := font.measure(dc.fonts, d.faces.bold, LICENCE_BACK_TEXT_SIZE, d.back_line, o) - LICENCE_BACK_TEXT_TRACK * LICENCE_BACK_TEXT_SIZE
		draw.text_ex(dc, d.faces.bold, LICENCE_BACK_TEXT_SIZE, {DESIGN_W / 2 - w / 2, LICENCE_BACK_TEXT_BASELINE}, draw.srgb(236.0 / 255, 239.0 / 255, 247.0 / 255, 0.55), d.back_line, o)
	}
}
