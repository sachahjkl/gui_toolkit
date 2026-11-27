package ui

// The widget set beyond the basics: toggles, sliders, numbers, segmented controls, progress,
// dropdowns, tabs, key caps, cards and form rows. Every widget takes a stable `id` string (see key.odin) and keeps its
// state in the caller's variables; hover/press/animation state lives in the box tree.

import "base:intrinsics"
import "core:fmt"
import "core:math"
import turn "../turn"
import "core:strconv"
import "core:strings"
import "../draw"
import "../font"
import "../platform"
import lucide "../lucide"
import i18n "../i18n"

// The icon font (raddebugger's icons.ttf), compiled into every app that uses the toolkit: load it with
// `font.load_embedded(&fonts, ui.ICON_FONT_DATA)`.
ICON_FONT_DATA :: #load("icons.ttf")

// The toolkit's icon font, for the widgets' own marks (a check, an arrow, a radio's dot): whatever icon font the program
// sets as `icon_font` (Lucide, its own), the marks are these characters of this font. Loaded the first time a widget
// draws one (0: no font state).
widget_icons :: proc() -> font.Font_Id {
	s := gs()
	if s.widget_icon_font == 0 && s.fonts != nil { s.widget_icon_font, _ = font.load_embedded(s.fonts, ICON_FONT_DATA) }
	return s.widget_icon_font
}

// The Lucide face (the lucide package), for a widget's mark the toolkit's own font has not (the eye of a secret field), loaded when
// first needed.
lucide_icons :: proc() -> font.Font_Id {
	s := gs()
	if s.lucide_font == 0 && s.fonts != nil { s.lucide_font, _ = font.load_embedded(s.fonts, lucide.DATA) }
	return s.lucide_font
}

// Characters of the toolkit's icon font (widget_icons) that the widgets use.
ICON_CHECK :: "V"
ICON_UP :: "^"
ICON_DOWN :: "v"
ICON_RADIO :: "O"
ICON_RADIO_ON :: "o"
ICON_ADD :: "+"
ICON_MINUS :: "-"
ICON_INFO :: "i"
ICON_WARN :: "w"
ICON_WARN_BIG :: "W"
ICON_X :: "x"

mono_font :: proc() -> font.Font_Id {
	if f := text_face(.Mono); f != 0 { return f }   // (the family chosen, else the program's: text_faces.odin)
	return top_style().font
}

////////////////////////////////
// Small building blocks

// A glyph in a cell `width` wide, as tall as its parent: `icon`, a character of `icon_font` (0: State.icon_font, the
// program's icons; widget_icons() for one of the ICON_ marks of the toolkit's own), in `fg` (nil: the words' colour).
icon :: proc(icon: string, width: f32, fg: Maybe(Color) = nil, icon_font: font.Font_Id = 0) {
	next({width = px(width), height = pct(1), font = icon_font != 0 ? icon_font : gs().icon_font, text_align = .Center, fg = fg})
	build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico%d", icon, parent_box().child_count))
}

// A horizontal rule across `width`: a line of the border's colour; in the machined finish a groove, a dark line and the
// lit one under it, both inside the box (the next box, drawn after, would cover a line outside it).
hline :: proc(width: Size) {
	line := max(1, math.round(scale()))
	next({width = width, height = px(machined() ? 2 * line : line), bg = color("border")})
	build_box({.Draw_Background, .Groove}, "")
}

// Value stored at press time for the active drag (column width at start, note position, ...). One for the State, which no press
// owns: it outlives its press, which a gesture that reads the press before this one needs (panes.odin). What lasts only as long
// as its press is better kept by press_data, typed and ended with it.
Drag_Payload :: [4]f32
drag_store :: proc(v: Drag_Payload) { gs().drag_payload = v }
drag_load :: proc() -> Drag_Payload { return gs().drag_payload }

// Persistent timers (hold-to-repeat, delays). `timer_due` is true once `next_ms` has passed. A timer that nothing asked
// about (timer_due) for TIMER_KEEP_BUILDS builds is forgotten.
TIMER_KEEP_BUILDS :: 1200
timer_set :: proc(key: Key, delay_ms: f64) { gs().timers[key] = Timer{next_ms = gs().time_ms + delay_ms, last_build = gs().build_index} }
timer_due :: proc(key: Key) -> bool {
	s := gs()
	t, ok := s.timers[key]
	if !ok { return false }
	t.last_build = s.build_index
	s.timers[key] = t
	return s.time_ms >= t.next_ms
}

// The box of an id under the current parent: the one this build made when it was just built, else the last build's (its
// rect and size are the last layout's, e.g. for scroll geometry). A value widget returns whether its value changed; what
// else its box says is `ui.signal(ui.prev_box(id))` right after it (hovered for a tooltip, a right click, its key).
prev_box :: proc(id: string) -> ^Box { return box_from_key(key_from_string(parent_box().key, id)) }

////////////////////////////////
// Check marks and radios

@(private = "file") MARK_RATE :: 30
@(private = "file") MARK_RING_PX :: 1.5
@(private = "file") MARK_BOX_RADIUS_FRACTION :: 0.28     // of the check box's width
@(private = "file") MARK_FILL_FADE_SPEED :: 1.6          // the fill is opaque before the mark has grown
@(private = "file") MARK_CHECK_MIN_T :: 0.05             // no check glyph this small
@(private = "file") MARK_RING_ALPHA :: 0.5
@(private = "file") MARK_RING_HOT_ALPHA :: 0.3
// Under the pointer the ring goes this far toward the accent; the box's face (inside the ring, or the accent's when
// checked) lifts a hover step and sinks a press step toward the theme's tint. A machined well darkens this much pressed.
@(private = "file") MARK_RING_HOT_ACCENT :: 0.45
@(private = "file") MARK_HOVER_STEP :: 0.08
@(private = "file") MARK_PRESS_STEP :: 0.15
@(private = "file") MARK_WELL_PRESS :: 0.25
@(private = "file") MARK_WELL_PRESS_DIM :: 0.7
// The least contrast of a check box's check on its accent fill (WCAG AA).
@(private = "file") MARK_CHECK_RATIO :: 4.5

// A check box's or a radio's mark: `t` how far it is checked, `row` its row (the row is the target, the mark is what
// reacts: its states are read when the mark is drawn, end_build having stepped them), its colours.
Mark_Draw :: struct { t: f32, row: ^Box, accent, check, ring: Color, size: f32, radio: bool, square: bool }   // square: a dense scope's check box

// Foreground colour of a check box's check on its accent fill: the theme's `accent_text`, else `ink_on(accent)` when
// that does not reach WCAG AA (4.5), so a bright accent on a dark theme never draws a white check on white.
@(private = "file")
mark_check_color :: proc(accent: Color) -> Color {
	ink := color("accent_text")
	ink.a = 1
	ground := accent
	ground.a = 1
	if contrast(ink, ground) < MARK_CHECK_RATIO { return ink_on(ground) }
	return ink
}

// The colours of a mark in its state: `inside` the box's face inside its ring (alpha 0: none at rest), `ring` its ring,
// `fill` its accent face (checked). `under` the surface the box is carved in, `tint` the theme's (state_tint). Pure: the
// tests call it.
Mark_Colors :: struct { inside, ring, fill: Color }

mark_colors :: proc(st: Face_State, t: f32, ring, accent, under, tint: Color) -> (c: Mark_Colors) {
	k := face_step(st, MARK_HOVER_STEP, MARK_PRESS_STEP)
	if k > 0 {
		c.inside = srgb_step({under.r, under.g, under.b, 1}, tint, k)
		c.inside.a = min(1, st.hot + st.pressing)
	}
	c.ring = draw.mix(ring, accent, max(t, MARK_RING_HOT_ACCENT * st.hot))
	c.fill = srgb_step(accent, tint, k)
	return
}

@(private)
mark_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) { mark_face(dc, b, b.rect, (^Mark_Draw)(user)) }

// A check box's or a radio's mark in `r`, its colours read under `b`'s tags and over what is under `b`: a mark's own box,
// or a switch's drawn as a check box (Toggle_Form.Check), whose box is wider than its mark.
@(private = "file")
mark_face :: proc(dc: ^draw.Context, b: ^Box, r: Rect, d: ^Mark_Draw) {
	s := gs()
	w := r.max.x - r.min.x
	radius := d.radio ? w * 0.5 : (d.square ? 0 : rad(w * MARK_BOX_RADIUS_FRACTION))
	st := face_state(d.row)
	ring := d.ring
	ring.a = min(1, ring.a * (1 + MARK_RING_HOT_ALPHA / MARK_RING_ALPHA * st.hot))
	mc := mark_colors(st, d.t, ring, d.accent, box_under(b), state_tint())
	if machined() {   // a hole in the surface; checked, a raised key of the accent in it (a radio: a lit bead)
		well := color_from_tags(s, b.tags_key, "well")
		if st.pressing > 0 { well = relief_darken(well, MARK_WELL_PRESS * st.pressing) }
		prev := draw.set_circular_corners(dc, d.radio)
		// (pressed, the hole goes deeper: its lit rim dims again; a darker black alone did not show on a dark well)
		machined_well(dc, r, radius, well, hot = st.hot * (1 - MARK_WELL_PRESS_DIM * st.pressing))
		draw.set_circular_corners(dc, prev)
		if d.t <= MARK_CHECK_MIN_T { return }
		if d.radio {
			machined_lamp(dc, draw.rect_center(r), w * 0.55 * d.t, mc.fill, 1, 0)
			return
		}
		inset := max(1, math.round(scale())) + (1 - d.t) * w * 0.5
		draw.push_alpha(dc, min(1, d.t * MARK_FILL_FADE_SPEED))
		machined_bevel(dc, draw.rect_pad(r, -inset), radius - inset * 0.5, mc.fill, st.hot, st.pressing)
		draw.pop_alpha(dc)
		mark_check(s, dc, r, d)
		return
	}
	// (the box's own face under its ring: lifted under the pointer, sunk pressed; none at rest, the surface shows)
	if mc.inside.a > 0 && d.t < 1 { draw.rect(dc, r, mc.inside, radius) }
	if d.radio {
		draw.rect(dc, r, mc.ring, radius, MARK_RING_PX * scale())
		dot := w * 0.5 * d.t
		c := draw.rect_center(r)
		a := mc.fill
		a.a *= d.t
		draw.rect(dc, {{c.x - dot * 0.5, c.y - dot * 0.5}, {c.x + dot * 0.5, c.y + dot * 0.5}}, a, dot * 0.5)
		return
	}
	inset := (1 - d.t) * w * 0.5
	fill := mc.fill
	fill.a *= min(1, d.t * MARK_FILL_FADE_SPEED)
	paint_rect_corners(dc, draw.rect_pad(r, -inset), fill, {radius, radius, radius, radius}, d.t, sunk = st.pressing)
	draw.rect(dc, r, mc.ring, radius, MARK_RING_PX * scale())
	mark_check(s, dc, r, d)
}

// The check of a check box, grown with `d.t`, in its centre.
@(private = "file")
mark_check :: proc(s: ^State, dc: ^draw.Context, r: Rect, d: ^Mark_Draw) {
	marks := s.widget_icon_font
	if d.t <= MARK_CHECK_MIN_T || marks == 0 { return }
	size := d.size * d.t
	m := font.metrics(s.fonts, marks, size)
	dim := font.text_width(s.fonts, marks, size, ICON_CHECK)
	c := draw.rect_center(r)
	ink := d.check
	ink.a = d.t
	draw.text(dc, marks, size, {math.round(c.x - dim * 0.5), math.round(c.y + (m.ascent - m.descent) * 0.5)}, ink, ICON_CHECK)
}

// A width for a row of controls whose text is a child of it (check boxes, radios, switches): as wide as its children
// unless `next` gave one. (From the style it took the text size of its own text, which is empty: the clickable row was
// a sliver at the left of its mark and label.) Returns whether it fits its children.
@(private)
fit_row_width :: proc() -> bool {
	s := gs()
	if s.has_next {
		if _, given := s.next_mod.width.?; given { return false }
	} else {
		s.next_mod = {}
		s.has_next = true
	}
	s.next_mod.width = children_sum()
	return true
}

@(private)
mark_row :: proc(id, text: string, on, radio: bool, wrap := false) -> Signal {
	_ = widget_icons()   // (the check is drawn in it: loaded before the draw)
	em := font_size()
	fit := fit_row_width() && !wrap
	if wrap {
		// as tall as its lines, its mark on the first one
		s := gs()
		if !s.has_next { s.next_mod, s.has_next = {}, true }
		if s.next_mod.height == nil { s.next_mod.height = children_sum() }   // (what else the caller said stays)
		set_next_axis(.X, .Start)
	} else {
		set_next_axis(.X, .Center)
	}
	// (the row is the target and draws nothing: its mark reacts, on the mark's own geometry; a fill over the row was a
	// plate larger than the box and off its centre)
	row_box := build_box({.Clickable, .Focusable}, id)
	a11y_default(row_box, {role = radio ? .Radio_Button : .Check_Box, toggled = on ? .True : .False})
	sig := signal(row_box)
	if parent(row_box) {
		t := anim(key_from_string(row_box.key, "t"), on ? 1 : 0, MARK_RATE)
		spacer(px(em * 0.4))
		// (wrapped, the mark stands on the first line: centered in that line's height, as the label's box lays it out)
		cell := em * MARK_CELL_EM
		lined := false
		if wrap {
			st := top_style()
			line := font.metrics(gs().fonts, st.font, st.font_size).line_height + 2 * st.text_pad
			if line > cell {
				next({width = px(cell), height = px(line), axis = .Y})
				push_parent(build_box({}, "###mark_line"))
				spacer(px(math.round((line - cell) * 0.5)))
				lined = true
			}
		}
		next({width = px(cell), height = px(cell)})
		d := frame_new(Mark_Draw)
		d.t = t
		d.accent = color("accent")
		d.check = mark_check_color(d.accent)
		d.row = row_box
		d.ring = color("text")
		d.ring.a = MARK_RING_ALPHA
		d.ring = tuned(d.ring)
		d.size = em * 0.95
		d.radio = radio
		d.square = gs().square_depth > 0
		custom("mark", mark_draw, d)
		if lined { pop_parent() }
		spacer(px(em * 0.6))
		if wrap {
			next({width = fill(), height = text_size()})
			build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, text)
		} else {
			next({width = fit ? text_size() : fill(), height = pct(1)})
			build_box({.Draw_Text}, text)
		}
	}
	return sig
}

// Clickable row: animated check box + label. `value` is toggled on click. `wrap`: a label longer than the row goes on to
// the next lines (the row as tall as they are, the mark on the first) instead of running past it. True when `value`
// changed this frame.
checkbox :: proc(id: string, text: string, value: ^bool, wrap := false) -> (changed: bool) {
	sig := mark_row(id, text, value^, false, wrap)
	if sig.clicked { value^ = !value^; a11y_state_toggled(sig.box, value^); changed = true }
	return
}

// A check box's mark, in font sizes: its box is the mark (mark_face draws over the whole box).
@(private = "file") MARK_CELL_EM :: 1.4

// `if check_mark("###id", &on) { ... }`: a check box with no words, its mark alone. Its box is the mark, a check box's
// size, so it sits where the caller puts it, as a value does (the debug panel's toggle at its row's end, under the
// numbers' last digits). `checkbox` is a row: its mark at its start, room for its words after it. Clicked, Space or
// a screen reader's press toggles `value`; true when it changed.
check_mark :: proc(id: string, value: ^bool) -> (changed: bool) {
	_ = widget_icons()   // (the check is drawn in it: loaded before the draw)
	em := font_size()
	cell := math.round(em * MARK_CELL_EM)
	next_default({width = px(cell), height = px(cell)})
	b := build_box({.Clickable, .Focusable}, id)
	a11y_default(b, {role = .Check_Box, toggled = value^ ? .True : .False})
	sig := signal(b)
	d := frame_new(Mark_Draw)
	d.t = anim(key_from_string(b.key, "t"), value^ ? 1 : 0, MARK_RATE)
	d.accent = color("accent")
	d.check = mark_check_color(d.accent)
	d.row = b
	d.ring = color("text")
	d.ring.a = MARK_RING_ALPHA
	d.ring = tuned(d.ring)
	d.size = em * 0.95
	d.square = gs().square_depth > 0
	b.custom, b.custom_user = mark_draw, d
	if sig.clicked { value^ = !value^; a11y_state_toggled(b, value^); changed = true }
	return
}

// One choice of several: `selected^` becomes `index` on click. True when `selected` changed this frame.
radio :: proc(id: string, text: string, selected: ^int, index: int) -> (changed: bool) {
	s := gs()
	group := rawptr(selected)
	// (its group's radios as the last build had them, in their order: a radio knows its siblings only from there)
	members := make([dynamic]Radio_Slot, 0, 8, frame_allocator())
	chosen_there := false
	for r in s.radios_last {
		if r.group != group { continue }
		append(&members, r)
		if r.index == selected^ { chosen_there = true }
	}
	sig := mark_row(id, text, selected^ == index, true)
	append(&s.radios, Radio_Slot{group = group, index = index, key = sig.box.key})
	// (one Tab stop: the chosen one; none chosen, the first; a group not seen yet, each, until the next build knows it)
	stop := index == selected^ || len(members) == 0 || (!chosen_there && members[0].index == index)
	if !stop { not_a_tab_stop(sig.box) }
	if sig.clicked && selected^ != index { selected^ = index; a11y_state_toggled(sig.box, true); changed = true }
	if sig.focused && len(members) > 0 {
		at := -1
		for r, i in members { if r.index == index { at = i } }
		if at >= 0 {
			if to := choice_group_step(true, at, len(members)); to >= 0 {
				selected^, changed = members[to].index, true
				set_focus(members[to].key)
			}
		}
	}
	return
}

// `b`, built Focusable, is no Tab stop after all (a choice of a group but the chosen one): its flag and its place in
// this build's Tab order go (build_box put it there).
@(private)
not_a_tab_stop :: proc(b: ^Box) {
	if b == nil || .Focusable not_in b.flags { return }
	b.flags -= {.Focusable}
	s := gs()
	#reverse for e, i in s.focus_order {
		if e.key == b.key { ordered_remove(&s.focus_order, i); break }
	}
}

// A radio button of the last build or of this one: its group (the caller's `selected`), its index, its box.
Radio_Slot :: struct {
	group: rawptr,
	index: int,
	key:   Key,
}

// The state screen readers read follows a change made after the box was built (the click of this frame).
@(private)
a11y_state_toggled :: proc(b: ^Box, on: bool) {
	if b != nil && b.a11y != nil { b.a11y.toggled = on ? .True : .False }
}

////////////////////////////////
// Toggle switch

@(private = "file") TOGGLE_RATE :: 34
@(private = "file") TOGGLE_TRACK_ALPHA :: 0.28
@(private = "file") TOGGLE_KNOB_PAD_FRACTION :: 0.14     // of the track's height
@(private = "file") TOGGLE_KNOB_PRESS_STRETCH :: 0.28
@(private = "file") TOGGLE_KNOB_HOT_STRETCH :: 0.06
@(private = "file") TOGGLE_KNOB_SHADOW_ALPHA :: 0.30
@(private = "file") TOGGLE_KNOB_SHADOW_SOFT_PX :: 3
// machined: how much of the accent lights the channel when on; the knob's face
@(private = "file") TOGGLE_MACHINED_LIT :: 0.85
@(private = "file") TOGGLE_MACHINED_KNOB :: Color{0.62, 0.62, 0.62, 1}

// The face of a switch's or a slider's knob when the relief draws it: the machined metal, or under a relief of rings the
// theme's raised face (its rings are tones of it: a metal grey in Old Head's grey was a key of another set).
@(private = "file")
knob_face :: proc(b: ^Box) -> Color {
	if relief_ringed() == nil { return TOGGLE_MACHINED_KNOB }
	c := color_from_tags(gs(), b.tags_key, "button background")
	return {c.r, c.g, c.b, 1}
}

// A switch: `t` how far it is on, `row` its row (the target; its states read when drawn, as a check box's mark).
// `mark`: the check box it is drawn as (Toggle_Form.Check), nil for the standard track.
Toggle_Draw :: struct { t: f32, row: ^Box, hot, active: f32, track, accent: Color, mark: ^Mark_Draw }

@(private)
toggle_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Toggle_Draw)(user)
	st := face_state(d.row)
	d.hot, d.active = st.hot, st.pressing
	if d.mark != nil {
		// (a square of the switch's height, on whole pixels so a relief's one-pixel rings stay crisp, centred in the
		// switch's box: the box, its row and its hit area are the switch's in every form)
		h := math.round(b.rect.max.y - b.rect.min.y)
		c := draw.rect_center(b.rect)
		at := Vec2{math.round(c.x - h * 0.5), math.round(c.y - h * 0.5)}
		d.mark.t = d.t
		mark_face(dc, b, {at, at + Vec2{h, h}}, d.mark)
		return
	}
	r := b.rect
	h := r.max.y - r.min.y
	pad := h * TOGGLE_KNOB_PAD_FRACTION
	kd := h - 2 * pad
	kw := kd * (1 + TOGGLE_KNOB_PRESS_STRETCH * d.active + TOGGLE_KNOB_HOT_STRETCH * d.hot)
	x := math.lerp(r.min.x + pad, r.max.x - pad - kw, d.t)
	if machined() {   // a channel carved in the surface, lit with the accent when on; the knob a raised key in it
		// (on whole device pixels: the 1 px rims of the channel and of the key, at a fraction, step along the curves)
		r = draw.Rect{{math.round(r.min.x), math.round(r.min.y)}, {math.round(r.max.x), math.round(r.max.y)}}
		h = r.max.y - r.min.y
		pad = math.max(math.round(h * TOGGLE_KNOB_PAD_FRACTION), px1())
		kd = h - 2 * pad
		kw = math.round(kd * (1 + TOGGLE_KNOB_PRESS_STRETCH * d.active + TOGGLE_KNOB_HOT_STRETCH * d.hot))
		x = math.round(math.lerp(r.min.x + pad, r.max.x - pad - kw, d.t))
		well := color_from_tags(gs(), b.tags_key, "well")
		machined_well(dc, r, shape_rad(h * 0.5), draw.mix(well, d.accent, d.t * TOGGLE_MACHINED_LIT), hot = d.hot)
		machined_bevel(dc, {{x, r.min.y + pad}, {x + kw, r.max.y - pad}}, shape_rad(kd * 0.5), knob_face(b), d.hot, d.active)
		return
	}
	// (the track is the switch's face: it lifts under the pointer and sinks pressed, as a check box's does)
	track := srgb_step(draw.mix(d.track, d.accent, d.t), state_tint(), face_step({hot = d.hot, pressing = d.active}, MARK_HOVER_STEP, MARK_PRESS_STEP))
	tr := rad(h * 0.5)
	paint_rect_corners(dc, r, track, {tr, tr, tr, tr}, d.t, sunk = d.active)
	sc := scale()
	draw.rect(dc, {{x - sc, r.min.y + pad + sc}, {x + kw + sc, r.max.y - pad + 2 * sc}}, {0, 0, 0, TOGGLE_KNOB_SHADOW_ALPHA}, rad(kd * 0.5), 0, TOGGLE_KNOB_SHADOW_SOFT_PX * sc)
	draw.rect(dc, {{x, r.min.y + pad}, {x + kw, r.max.y - pad}}, {1, 1, 1, 1}, rad(kd * 0.5))
}

// The part of a switch or a slider that is off: a tint of the text, so that it shows on any surface (the theme's "track"
// is a surface, the colour of a dialog in some themes: a slider's track on it was not seen, only its lit run).
@(private = "file")
off_track :: proc() -> Color {
	c := color("text")
	c.a = TOGGLE_TRACK_ALPHA
	return tuned(c)
}

// Switch (named `toggle` because `switch` is an Odin keyword). True when `value` changed this frame. `wrap`: a label longer
// than the row goes on to the next lines (the row as tall as they are, the switch on the first), as checkbox's.
toggle :: proc(id: string, text: string, value: ^bool, wrap := false) -> (changed: bool) {
	em := font_size()
	fit := fit_row_width() && !wrap
	if wrap {
		s := gs()
		if !s.has_next { s.next_mod, s.has_next = {}, true }
		if s.next_mod.height == nil { s.next_mod.height = children_sum() }
		set_next_axis(.X, .Start)
	} else {
		set_next_axis(.X, .Center)
	}
	// (the row is the target and draws nothing: the switch reacts, toggle_draw)
	row_box := build_box({.Clickable, .Focusable}, id)
	sig := signal(row_box)
	if sig.clicked { value^ = !value^; changed = true }
	a11y_default(row_box, {role = .Switch, toggled = value^ ? .True : .False})
	if parent(row_box) {
		spacer(px(em * 0.4))
		lined := false
		if wrap {
			next({width = fill(), height = text_size()})
			build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, text)
			// (the switch on the first line: centred in that line's height)
			st := top_style()
			line := font.metrics(gs().fonts, st.font, st.font_size).line_height + 2 * st.text_pad
			if line > em * 1.4 {
				next({width = px(em * 2.6), height = px(line), axis = .Y})
				push_parent(build_box({}, "###switch_line"))
				spacer(px(math.round((line - em * 1.4) * 0.5)))
				lined = true
			}
		} else {
			next({width = fit ? text_size() : fill(), height = pct(1)})
			build_box({.Draw_Text}, text)
		}
		next({width = px(em * 2.6), height = px(em * 1.4)})
		d := frame_new(Toggle_Draw)
		d.t = anim(key_from_string(row_box.key, "t"), value^ ? 1 : 0, TOGGLE_RATE)
		d.row = row_box
		d.track = off_track()
		d.accent = color("accent")
		if toggle_shown() == .Check {
			// (the colours a check box's mark takes in mark_row, read here under the same tags)
			_ = widget_icons()   // (the check is drawn in it: loaded before the draw)
			m := frame_new(Mark_Draw)
			m.row, m.accent = row_box, d.accent
			m.check = mark_check_color(d.accent)
			m.ring = color("text")
			m.ring.a = MARK_RING_ALPHA
			m.ring = tuned(m.ring)
			m.size = em * 0.95
			d.mark = m
		}
		custom("track", toggle_draw, d)
		if lined { pop_parent() }
		spacer(px(em * 0.4))
	}
	return
}

////////////////////////////////
// Sliders

@(private = "file") SLIDER_RATE :: 60
@(private = "file") SLIDER_VALUE_ROOM_EM :: 4.6          // the value's text, right of the track
@(private = "file") SLIDER_VALUE_FONT_SCALE :: 0.88
@(private = "file") SLIDER_TRACK_MIN_PX :: 10
@(private = "file") SLIDER_TRACK_EM :: 0.34
@(private = "file") SLIDER_KNOB_EM :: 0.52               // its radius; what hover and a press add to it
@(private = "file") SLIDER_KNOB_HOT_EM :: 0.12
@(private = "file") SLIDER_KNOB_ACTIVE_EM :: 0.10
@(private = "file") SLIDER_KNOB_RING_PX :: 2
@(private = "file") SLIDER_KNOB_SHADOW_ALPHA :: 0.35
@(private = "file") SLIDER_KNOB_SHADOW_SOFT_PX :: 4
@(private = "file") SLIDER_KNOB_DOT_FRACTION :: 0.38
// machined: the slot is this much thicker than the flat track (an inner shadow needs the room)
@(private = "file") SLIDER_MACHINED_TRACK :: 1.5
// Without a step, the arrow keys move a hundredth of the range.
@(private = "file") SLIDER_FINE_DIVISIONS :: 100
@(private = "file") RANGE_SLIDER_SAME_EPS :: 0.001       // thumbs this close: the side of the press picks one

Slider_Draw :: struct {
	t0, t1:     f32,
	range:      bool,
	hot, active: f32,
	track, accent, text: Color,
	value_text: string,
	mono:       font.Font_Id,
	no_text:    bool,   // no value at the right end: the track runs to it (a number's value is its field)
}

@(private = "file") SLIDER_PAD_EM :: 0.75              // the track's room at each end, for the knob
@(private = "file") SLIDER_TRACK_LEAST_EM :: 4         // the track a slider keeps, whatever room it is given
@(private = "file") SLIDER_TRACK_LEAST_BARE_EM :: 2    // ...without a value (a number's track: its field says it, in a narrow row)
@(private = "file") SLIDER_PREFERRED_EM :: 12          // its width when nothing gives it one (a tool bar's control)

// A slider's width: never less than its pads, a track a hand can use and its value's room (a share of a narrow row, or
// a width given too small, left only the knob and the value); when nothing gives it a width (in a box as wide as what is
// in it: a tool bar's control, a menu's control row) its preferred width, as a field has one.
@(private = "file")
slider_width :: proc(b: ^Box, value_room: bool) {
	em := b.font_size
	track: f32 = value_room ? SLIDER_TRACK_LEAST_EM + SLIDER_VALUE_ROOM_EM : SLIDER_TRACK_LEAST_BARE_EM
	least := math.ceil(em * (2 * SLIDER_PAD_EM + track))
	p := &b.pref[.X]
	#partial switch p.kind {
	case .Pixels, .Percent, .Text: p.least = max(p.least, least)
	case: p^ = px(max(least, math.round(em * SLIDER_PREFERRED_EM)))
	}
}

@(private)
slider_geom :: proc(r: Rect, em: f32, value_room := true) -> (x0, x1: f32) {
	pad := em * SLIDER_PAD_EM
	x0 = r.min.x + pad
	x1 = r.max.x - (value_room ? em * SLIDER_VALUE_ROOM_EM : 0) - pad
	if x1 < x0 + SLIDER_TRACK_MIN_PX * scale() { x1 = x0 + SLIDER_TRACK_MIN_PX * scale() }
	return
}

// Knob_Form.Keys: the key's width and height (ems of the font size) and the well's height (logical pixels).
@(private = "file") SLIDER_KEY_WIDTH_EM :: 0.6
@(private = "file") SLIDER_KEY_HEIGHT_EM :: 1.1
@(private = "file") SLIDER_KEY_TRACK_PX :: 4

// The key of a Keys knob (Knob_Form.Keys) centred at `kx` on the track's line `cy`, `em` the slider's font size: on
// whole pixels, since a relief's rings are one pixel each and a fraction would blur them.
slider_key_rect :: proc(kx, cy, em: f32) -> Rect {
	w, h := math.round(em * SLIDER_KEY_WIDTH_EM), math.round(em * SLIDER_KEY_HEIGHT_EM)
	at := Vec2{math.round(kx - w * 0.5), math.round(cy - h * 0.5)}
	return {at, at + Vec2{w, h}}
}

// The well of a Keys slider from `x0` to `x1` (slider_geom's ends) on the line `cy`, on whole pixels.
slider_key_track :: proc(x0, x1, cy: f32) -> Rect {
	h := math.round(SLIDER_KEY_TRACK_PX * scale())
	y := math.round(cy - h * 0.5)
	return {{math.round(x0), y}, {math.round(x1), y + h}}
}

@(private)
slider_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Slider_Draw)(user)
	em := b.font_size
	r := b.rect
	x0, x1 := slider_geom(r, em, !d.no_text)
	cy := (r.min.y + r.max.y) * 0.5
	th := em * SLIDER_TRACK_EM
	fx0 := d.range ? math.lerp(x0, x1, d.t0) : x0
	fx1 := math.lerp(x0, x1, d.t1)
	// (its states read now, end_build having stepped them; held, the knob stays held wherever the pointer drags it)
	d.hot, d.active = b.hot_t, b.active_t
	kr := em * (SLIDER_KNOB_EM + SLIDER_KNOB_HOT_EM * d.hot + SLIDER_KNOB_ACTIVE_EM * d.active)
	knobs := [2]f32{math.lerp(x0, x1, d.t0), fx1}
	sc := scale()
	if knob_shown() == .Keys {
		// (a well and keys of the relief; no lit run: the key's place says the value. The key keeps its size and does
		// not sink, held or not: Windows' thumb did neither, nor does the scroll bar's Keys thumb)
		machined_well(dc, slider_key_track(x0, x1, cy), 0, color_from_tags(gs(), b.tags_key, "well"))
		for i in (d.range ? 0 : 1) ..< 2 {
			machined_bevel(dc, slider_key_rect(knobs[i], cy, em), 0, knob_face(b), 0, 0)
		}
		slider_value(dc, d, r, cy, em, sc)
		return
	}
	if machined() {   // a slot carved in the surface, its run lit with the accent; the knobs raised keys on it
		mth := math.round(th * SLIDER_MACHINED_TRACK)
		slot := Rect{{x0, math.round(cy - mth * 0.5)}, {x1, math.round(cy - mth * 0.5) + mth}}
		machined_well(dc, slot, shape_rad(mth * 0.5), color_from_tags(gs(), b.tags_key, "well"))
		if fx1 - fx0 > 1 { paint_rect(dc, {{fx0, slot.min.y + sc}, {fx1, slot.max.y - sc}}, d.accent, shape_rad(mth * 0.5)) }
		prev := draw.set_circular_corners(dc, true)
		for i in (d.range ? 0 : 1) ..< 2 {
			kx := knobs[i]
			machined_bevel(dc, {{kx - kr, cy - kr}, {kx + kr, cy + kr}}, kr, knob_face(b), d.hot, d.active)
			dot := kr * SLIDER_KNOB_DOT_FRACTION
			draw.rect(dc, {{kx - dot, cy - dot}, {kx + dot, cy + dot}}, d.accent, dot)
		}
		draw.set_circular_corners(dc, prev)
		slider_value(dc, d, r, cy, em, sc)
		return
	}
	draw.rect(dc, {{x0, cy - th * 0.5}, {x1, cy + th * 0.5}}, d.track, rad(th * 0.5))
	draw.rect(dc, {{fx0, cy - th * 0.5}, {fx1, cy + th * 0.5}}, d.accent, rad(th * 0.5))
	for i in (d.range ? 0 : 1) ..< 2 {
		kx := knobs[i]
		draw.rect(dc, {{kx - kr - sc, cy - kr + sc}, {kx + kr + sc, cy + kr + 3 * sc}}, {0, 0, 0, SLIDER_KNOB_SHADOW_ALPHA}, rad(kr), 0, SLIDER_KNOB_SHADOW_SOFT_PX * sc)
		draw.rect(dc, {{kx - kr, cy - kr}, {kx + kr, cy + kr}}, {1, 1, 1, 1}, rad(kr))
		draw.rect(dc, {{kx - kr, cy - kr}, {kx + kr, cy + kr}}, d.accent, rad(kr), SLIDER_KNOB_RING_PX * sc)
		draw.rect(dc, {{kx - kr * SLIDER_KNOB_DOT_FRACTION, cy - kr * SLIDER_KNOB_DOT_FRACTION}, {kx + kr * SLIDER_KNOB_DOT_FRACTION, cy + kr * SLIDER_KNOB_DOT_FRACTION}}, d.accent, rad(kr))
	}
	slider_value(dc, d, r, cy, em, sc)
}

// The slider's value, at its right end.
@(private = "file")
slider_value :: proc(dc: ^draw.Context, d: ^Slider_Draw, r: Rect, cy, em, sc: f32) {
	size := em * SLIDER_VALUE_FONT_SCALE
	m := font.metrics(gs().fonts, d.mono, size)
	w := font.text_width(gs().fonts, d.mono, size, d.value_text)
	draw.text(dc, d.mono, size, {math.round(r.max.x - w - 2 * sc), math.round(cy + (m.ascent - m.descent) * 0.5)}, d.text, d.value_text)
}

@(private)
slider_pct :: proc(b: ^Box, value_room := true) -> f32 {
	x0, x1 := slider_geom(b.rect, font_size(), value_room)
	if x1 - x0 < 1 { return 0 }
	return clamp((gs().mouse.x - x0) / (x1 - x0), 0, 1)
}

// `format` is a printf format for the value text, e.g. "%.0f" or "%.1f C"; text without a % is shown as is
// (pick it per value for labels such as "Off"); "": no value text, the track runs to the right end. step 0 = continuous.
// Keyboard (when focused): Left / Down and Right / Up step the value (`step`, or 1 % of the range), Home / End jump
// to the ends, Page Up / Page Down move by Feel.step_page steps. Shift multiplies a key's move by Feel.step_shift.
// Wheel (wheel_steps): a notch up is a step more, Shift Feel.step_shift; in a view that scrolls, once the slider has the
// keyboard.
// `default`: a double click on the track sets it (the value a person comes back to, as a splitter's size).
// True when `value` changed this frame.
slider :: proc(id: string, value: ^f32, lo, hi: f32, step: f32 = 0, format := "%.2f", default: Maybe(f32) = nil) -> (changed: bool) {
	before := value^
	b := build_box({.Clickable, .Focusable}, id)
	b.cursor = .Hand
	slider_width(b, format != "")
	sig := signal(b)
	k := slider_unit(lo, hi, step)
	set :: proc(value: ^f32, v, lo, hi, step: f32) { value^ = clamp(slider_snap(v, step), lo, hi) }
	if n := wheel_steps(b, sig.focused); n != 0 { set(value, value^ + n * k * shift_steps(gs().mods), lo, hi, step) }
	if sig.focused {
		if v, moved := slider_keys(value^, k, lo, hi); moved { set(value, v, lo, hi, step) }
	}
	if sig.pointer_pressed || sig.dragging { set(value, lo + slider_pct(b, format != "") * (hi - lo), lo, hi, step) }
	// (after the press: the double click's second press moved the knob there first; the default wins)
	if d, has := default.?; has && sig.double_clicked { set(value, d, lo, hi, step) }
	if v, ok := a11y_numeric_request(b.key, value^, k); ok { set(value, v, lo, hi, step) }
	t := clamp((value^ - lo) / (hi - lo), 0, 1)
	d := slider_draw_of(b, format)
	d.t1 = anim(key_from_string(b.key, "t"), t, SLIDER_RATE, t)
	d.value_text = slider_text(format, value^)
	a11y_default(b, {role = .Slider, numeric = f64(value^), min = f64(lo), max = f64(hi), step = step > 0 ? f64(step) : nil, value = d.value_text, orientation = .X})
	return value^ != before
}

// What the slider and the range slider share: one step (`step`, or a hundredth of the range), a value rounded to `step`
// (0: as it is), the value's text, the keys that move a thumb, the drawing's common part.
@(private = "file")
slider_unit :: proc(lo, hi, step: f32) -> f32 { return step > 0 ? step : (hi - lo) / SLIDER_FINE_DIVISIONS }

@(private = "file")
slider_snap :: proc(v, step: f32) -> f32 { return step > 0 ? math.round(v / step) * step : v }

// `format` a printf format of the value; without a %, shown as it is.
@(private = "file")
slider_text :: proc(format: string, v: f32) -> string {
	// (the decimal mark of the language in use: "0,50" in French)
	return strings.index_byte(format, '%') >= 0 ? i18n.decimal_marks(fmt.aprintf(format, v, allocator = frame_allocator()), frame_allocator()) : format
}

// The keys of a focused thumb at `v`: Left / Down and Right / Up a step `k`, Page Up / Page Down Feel.step_page steps
// (Shift: Feel.step_shift times as much), Home / End to `home` / `end`. `moved`: a key was one of those.
@(private = "file")
slider_keys :: proc(v, k, home, end: f32) -> (out: f32, moved: bool) {
	out = v
	page := f32(gs().feel.step_page)
	for sh in ([2]platform.Modifiers{{}, {.Shift}}) {
		by := k * shift_steps(sh)
		if key_press(.Left, sh) || key_press(.Down, sh) { out -= by; moved = true }
		if key_press(.Right, sh) || key_press(.Up, sh) { out += by; moved = true }
		if key_press(.Page_Down, sh) { out -= page * by; moved = true }
		if key_press(.Page_Up, sh) { out += page * by; moved = true }
	}
	if key_press(.Home) { out = home; moved = true }
	if key_press(.End) { out = end; moved = true }
	return
}

@(private = "file")
slider_draw_of :: proc(b: ^Box, format: string) -> ^Slider_Draw {
	d := frame_new(Slider_Draw)
	d.track, d.accent, d.text = off_track(), color("accent"), color("text")
	d.mono = mono_font()
	d.no_text = format == ""
	b.custom, b.custom_user = slider_draw, d
	return d
}

// What a step is multiplied by with these modifiers: Feel.step_shift with Shift, else 1. The step of a slider, a slider
// field, a number, by key, notch or button.
@(private)
shift_steps :: proc(mods: platform.Modifiers) -> f32 { return .Shift in mods ? f32(gs().feel.step_shift) : 1 }

// Whole notches of the wheel turned over `b` this frame, up positive: what a slider or a spin field moves by. `b` takes
// the wheel when the pointer is over it; in a view that scrolls (a page of settings), only once it has the keyboard
// (`focused`), so that the wheel over it scrolls the view as it passes. Fractions of a notch (a touchpad) add up.
wheel_steps :: proc(b: ^Box, focused: bool) -> f32 {
	scrolls := false
	for p := b.parent; p != nil; p = p.parent {
		if .View_Scroll_Y in p.flags || .View_Scroll_X in p.flags { scrolls = true; break }
	}
	if scrolls && !focused { b.flags -= {.Scroll_Self}; return 0 }
	return wheel_take(b)
}

// Whole notches of the wheel turned over `b` this frame, up positive, whatever is around it: `b` takes the wheel from
// now on. An instrument's field (drag_number) takes it so even in a view that scrolls (debug-panel.md).
@(private)
wheel_take :: proc(b: ^Box) -> f32 {
	s := gs()
	// (the flag is read by the next frame's hit test: taken from now on)
	b.flags += {.Scroll_Self}
	if s.scroll_key != b.key { return 0 }
	rest := s.wheel_rest[b.key] - (s.scroll_delta.y + s.scroll_delta.x)
	n := math.trunc(rest)
	rest -= n
	if abs(rest) < 1e-3 { delete_key(&s.wheel_rest, b.key) } else { s.wheel_rest[b.key] = rest }
	return n
}

// A number one sets: − and + around a field where its exact value is typed, then its unit (`unit`; "" none); with
// `slider` and both bounds, a slider before them. T: int, f32 or f64. `lo`, `hi`: its bounds (nil: none on
// that side). Every way it moves clamps it to them and rounds it to `step` (0: an integer's 1; a float's as it comes).
// One step of the keys, the wheel and the buttons is `step` (0: 1, or a hundredth of a float's bounded range).
// The field shows the value (its digits, a float's as many after the point as `step` has). While the field has the keyboard, what is typed applies at Enter or
// when the keyboard goes elsewhere; Escape, or text that is no number, gives the value back. Up / Down step it, Page Up / Page Down ten steps; Shift ten
// times as much, Ctrl a hundred, Alt a tenth (num_step_delta). The wheel over the field or the slider steps it (Shift:
// ten); in a view that scrolls, once it has the keyboard (wheel_steps). The buttons step it (Shift: ten), held they
// repeat (repeat_pressed); at a bound its button is disabled. A screen reader sees a spin button (and the slider).
// `disabled`: shown faded, not changed. `parse`: how the field reads what is typed when it takes more than a number
// ("1.5 s" for a field in ms: a setting's unit and its suffixes); zero, a number in either decimal mark. Its size:
// `next` (the slider takes the room the rest leaves; without one, as wide as what is in it). True when the value
// changed this frame.
//
//   ui.number("###width", &app.width, lo = 1, hi = 40, unit = "px", slider = true)
//   ui.number("###count", &app.count, lo = 0)
number :: proc{number_int, number_f32, number_f64}

// A number field's reader of typed text (ui.number's `parse`): the value in the number's unit, ok false when the text
// is none. `user` is given back to `fn`; it must hold until the build ends.
Number_Parse :: struct {
	fn:   proc(user: rawptr, text: string) -> (value: f64, ok: bool),
	user: rawptr,
}

number_int :: proc(id: string, value: ^int, lo: Maybe(int) = nil, hi: Maybe(int) = nil, step := 0, unit := "", slider := false, disabled := false, default: Maybe(int) = nil, parse := Number_Parse{}) -> (changed: bool) {
	return number_of(id, value, lo, hi, step, unit, slider, disabled, default, parse)
}
number_f32 :: proc(id: string, value: ^f32, lo: Maybe(f32) = nil, hi: Maybe(f32) = nil, step: f32 = 0, unit := "", slider := false, disabled := false, default: Maybe(f32) = nil, parse := Number_Parse{}) -> (changed: bool) {
	return number_of(id, value, lo, hi, step, unit, slider, disabled, default, parse)
}
number_f64 :: proc(id: string, value: ^f64, lo: Maybe(f64) = nil, hi: Maybe(f64) = nil, step: f64 = 0, unit := "", slider := false, disabled := false, default: Maybe(f64) = nil, parse := Number_Parse{}) -> (changed: bool) {
	return number_of(id, value, lo, hi, step, unit, slider, disabled, default, parse)
}

// (one body for every type: an Odin default of a parameter of a polymorphic type cannot be had, so the group above gives them)
@(private = "file")
number_of :: proc(id: string, value: ^$T, lo, hi: Maybe(T), step: T, unit: string, with_slider, disabled: bool, default: Maybe(T), parse: Number_Parse) -> (changed: bool) where intrinsics.type_is_integer(T) || intrinsics.type_is_float(T) {
	s := gs()
	em := font_size()
	low, has_lo := lo.?
	high, has_hi := hi.?
	track := with_slider && has_lo && has_hi && high > low
	k := f64(step)
	if k <= 0 {
		k = 1
		when intrinsics.type_is_float(T) { if has_lo && has_hi && high > low { k = (f64(high) - f64(low)) / SLIDER_FINE_DIVISIONS } }
	}
	before := value^
	moved := false   // by anything but what is typed: the text being typed shows it
	push_disabled(disabled)
	defer pop_disabled()
	if !track {
		if !s.has_next { s.next_mod, s.has_next = {}, true }
		if s.next_mod.width == nil { s.next_mod.width = children_sum() }
	}
	if row(.Center, {}, id) {
		fkey := key_from_string(parent_box().key, "###value")
		typing := !disabled && s.focus_key == fkey
		f := &s.number_edit
		// (the keyboard went elsewhere: what was typed applies)
		if s.number_key == fkey && !typing {
			number_parse(value, line_edit_string(f), lo, hi, step, parse)
			s.number_key = 0
		}
		came := false
		if typing && s.number_key != fkey {
			// the keyboard came: the field holds the value, all of it selected to be typed over (another number's text not
			// applied yet is first applied by its own build, unless it is gone)
			other := s.boxes[s.number_key] or_else nil
			if s.number_key == 0 || other == nil || other.last_build + 1 < s.build_index {
				line_edit_set(f, number_text(value^, step))
				s.number_key = fkey
				came = true
			}
		}
		editing := typing && s.number_key == fkey

		if track {
			v := f32(value^)
			// (an integer's slider moves by whole steps: a hundredth of a short range rounded back to where it was)
			slider_step := f32(step)
			when !intrinsics.type_is_float(T) { if slider_step <= 0 { slider_step = 1 } }
			next({width = fill(), height = pct(1)})
			// (no value text on the knob: the field says it; its keys and its wheel are its own)
			track_default: Maybe(f32)
			if d, has := default.?; has { track_default = f32(d) }
			slider("###slider", &v, f32(low), f32(high), slider_step, "", track_default)
			if v != f32(value^) { number_set(value, f64(v), lo, hi, step); moved = true }
			spacer(px(math.round(em * 0.4)))
		}
		side := math.round(em * 1.6)
		for dir in ([2]f64{-1, 1}) {
			if dir > 0 {
				text := number_text(value^, step)
				st := top_style()
				widest := text_width(st.font, st.font_size, text)
				if has_lo { widest = max(widest, text_width(st.font, st.font_size, number_text(low, step))) }
				if has_hi { widest = max(widest, text_width(st.font, st.font_size, number_text(high, step))) }
				info := A11y_Info{role = .Spin_Button, numeric = f64(value^), step = k, value = unit != "" ? fmt.tprintf("%s %s", text, unit) : text}
				if has_lo { info.min = f64(low) }
				if has_hi { info.max = f64(high) }
				if editing && !keys_held_by_dialog(s) {
					// (the step keys move the value from what is typed, when it is a number)
					for e, i in s.events.list {
						if s.events.consumed[i] || e.mods - {.Ctrl, .Shift, .Alt} != {} { continue }
						d := num_step_delta(e.key, e.mods) or_continue
						s.events.consumed[i] = true
						base := f64(value^)
						if v, ok := number_read(line_edit_string(f), parse); ok { base = v }
						number_set(value, base + d * k, lo, hi, step)
						moved = true
					}
				}
				if v, ok := a11y_numeric_request(fkey, f32(value^), f32(k)); ok && !disabled { number_set(value, f64(v), lo, hi, step); moved = true }
				next({width = px(math.ceil(max(em * NUMBER_FIELD_MIN_EM, widest + 2 * st.text_pad + em * 0.4))), height = pct(1)})
				a11y(info)
				fsig: Signal
				if editing {
					res := line_edit("###value", f, {own_menu = true})
					// (after the field's first build: the press that gave it the keyboard placed its caret there)
					if came { line_edit_select_all(f) }
					fsig = res.signal
					if res.committed { number_parse(value, line_edit_string(f), lo, hi, step, parse); moved = true }
					if res.cancelled { s.number_key = 0 }   // (and the keyboard goes: the value stays)
				} else {
					// (the field while nobody types in it: the value, as the field shows its text; the key is the field's, so
					// a press gives it the keyboard and the next build types in it)
					next_default({radius = em * shape_of(.Control)})   // (a button's corners)
					push_tags("input")
					fb := build_box({.Clickable, .Focusable, .Text_Input, .Clip, .Draw_Background, .Draw_Border, .Draw_Hot_Effects, .Draw_Focus_Ring, .Sunken, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###value", text_shown(text)))
					pop_tags()
					fb.cursor = .Text
					fsig = signal(fb)
				}
				// (a default: the field's menu sets it again; a right press while typing keeps the text's own menu out)
				if d, has := default.?; has && !disabled {
					menu_id := fmt.tprintf("###number_menu_%d", u64(fkey))
					if fsig.right_clicked { menu_open(menu_id, mouse_pos(), fkey) }
					if menu(menu_id) {
						if menu_item(fmt.tprintf(i18n.tr("Reset to %s"), number_text(d, step)), disabled = value^ == d).clicked {
							number_set(value, f64(d), lo, hi, step)
							moved = true
						}
					}
				}
				// (the wheel over the field moves the value as over the slider: it is one line, nothing in it scrolls)
				if n := wheel_steps(fsig.box, typing); n != 0 && !disabled {
					number_set(value, f64(value^) + f64(n) * k * f64(shift_steps(s.mods)), lo, hi, step)
					moved = true
				}
			}
			at_end := dir < 0 ? has_lo && value^ <= low : has_hi && value^ >= high
			next({width = px(side), height = px(side), font_size = math.round(em * 0.9)})
			sig: Signal
			// (one Tab stop, the field: the buttons are the pointer's)
			if tab_stops(false) { sig = button(dir < 0 ? "dec" : "inc", icon = dir < 0 ? ICON_MINUS : ICON_ADD, o = {icon_font = widget_icons(), disabled = at_end || disabled}) }
			if repeat_pressed(sig) {
				number_set(value, f64(value^) + dir * k * f64(shift_steps(sig.mods)), lo, hi, step)
				moved = true
			}
		}
		if editing && moved && s.number_key == fkey {
			line_edit_set(f, number_text(value^, step))
			line_edit_select_all(f)
		}
		if unit != "" {
			spacer(px(math.round(em * 0.3)))
			if tags("weak") {
				next({width = text_size(0), height = pct(1), text_pad = 0})
				label(fmt.tprintf("%s###unit", unit))
			}
		}
	}
	return value^ != before
}

// The least width of a number's field, in ems.
@(private = "file") NUMBER_FIELD_MIN_EM :: 3
// The most digits after the point a float's step asks for.
@(private = "file") NUMBER_DECIMALS_MAX :: 6

// `v` clamped to the bounds that are given and rounded to `step` (0: an integer's 1, a float as it is).
@(private = "file")
number_set :: proc(value: ^$T, v: f64, lo, hi: Maybe(T), step: T) {
	v := v
	if step > 0 { v = math.round(v / f64(step)) * f64(step) }
	when !intrinsics.type_is_float(T) { v = math.round(v) }
	if l, ok := lo.?; ok { v = max(v, f64(l)) }
	if h, ok := hi.?; ok { v = min(v, f64(h)) }
	when !intrinsics.type_is_float(T) { v = clamp(v, f64(min(T)), f64(max(T))) }
	value^ = T(v)
}

// What is typed, when it is a number, as the value (number_set); else the value stays.
@(private = "file")
number_parse :: proc(value: ^$T, text: string, lo, hi: Maybe(T), step: T, parse: Number_Parse) {
	if v, ok := number_read(text, parse); ok { number_set(value, v, lo, hi, step) }
}

// What is typed, read by the number's own reader, else as a number in either decimal mark ("7,8" as the language
// writes it, "7.8" as a person may type it).
@(private = "file")
number_read :: proc(text: string, parse: Number_Parse) -> (f64, bool) {
	if parse.fn != nil { return parse.fn(parse.user, text) }
	return i18n.parse_decimal(text)
}

// The text of a number: its digits, a float's as many after the language's decimal mark as its `step` has (step 0: as
// many as it needs).
@(private = "file")
number_text :: proc(v: $T, step: T) -> string {
	when intrinsics.type_is_float(T) {
		if step <= 0 { return i18n.decimal_marks(fmt.tprintf("%v", v)) }
		decimals := 0
		x := f64(step)
		for decimals < NUMBER_DECIMALS_MAX && abs(x - math.round(x)) > 1e-6 * max(1, abs(x)) {
			x *= 10
			decimals += 1
		}
		return i18n.decimal(f64(v), decimals)
	} else {
		return fmt.tprintf("%d", v)
	}
}

// A request of a screen reader for a numeric widget `key` this build (set the value, increment, decrement by `step`):
// the value it asks for.
a11y_numeric_request :: proc(key: Key, value, step: f32) -> (f32, bool) {
	if r, ok := a11y_request(key, .Set_Value); ok {
		if r.data == .Numeric_Value { return f32(r.num), true }
		if r.data == .Value {
			if v, vok := strconv.parse_f32(strings.trim_space(r.value)); vok { return v, true }
		}
	}
	if _, ok := a11y_request(key, .Increment); ok { return value + step, true }
	if _, ok := a11y_request(key, .Decrement); ok { return value - step, true }
	return value, false
}

// What a range slider's press keeps (press_data): the thumb it took.
@(private = "file")
Range_Press :: struct { high, taken: bool }

// Two thumbs on one track, `lo_v` at most `hi_v`: a press takes the thumb closest to the pointer, which then follows it.
// Each thumb is a Tab stop and a slider for a screen reader; the active thumb (the one a press took, or Tab reached)
// moves as ui.slider does: Left / Down and Right / Up a step (`step`, or 1 % of the range), Home / End to its ends (the
// other thumb is one), Page Up / Page Down ten steps. The wheel over the track moves the active thumb (none: the one
// nearest the pointer) a step a notch, Shift ten; in a view that scrolls, once a thumb has the keyboard. step 0 =
// continuous. `format`: a printf format of each value ("%.0f": "20-80"); "": no value text, the track runs to the right
// end. `default`: the range a double click on the track sets again, both thumbs (a range is one value).
// True when a value changed this frame.
range_slider :: proc(id: string, lo_v, hi_v: ^f32, lo, hi: f32, step: f32 = 0, format := "%.0f", default: Maybe([2]f32) = nil) -> (changed: bool) {
	s := gs()
	em := font_size()
	before := [2]f32{lo_v^, hi_v^}
	b := build_box({.Clickable}, id)
	b.cursor = .Hand
	// (the slider's rule: its track and its value's room are its least, never a knob alone)
	slider_width(b, format != "")
	sig := signal(b)
	room := format != ""
	k := slider_unit(lo, hi, step)
	thumbs := [2]Key{key_from_string(b.key, "###lo"), key_from_string(b.key, "###hi")}
	values := [2]^f32{lo_v, hi_v}
	active := -1
	for t, i in thumbs { if s.focus_key == t { active = i } }
	set :: proc(which: int, to: f32, lo_v, hi_v: ^f32, lo, hi, step: f32) {
		v := slider_snap(to, step)
		if which == 0 { lo_v^ = clamp(v, lo, hi_v^) } else { hi_v^ = clamp(v, lo_v^, hi) }
	}
	press := press_data(Range_Press, b.key)
	if press != nil && !press.taken {
		p := slider_pct(b, room)
		pl, ph := (lo_v^ - lo) / (hi - lo), (hi_v^ - lo) / (hi - lo)
		press^ = {high = abs(p - pl) >= abs(p - ph), taken = true}
		if abs(pl - ph) < RANGE_SLIDER_SAME_EPS { press.high = p >= pl }
		// (the thumb taken is the active one: the keys and the wheel move it next)
		active = press.high ? 1 : 0
		s.focus_key = thumbs[active]
	}
	if sig.dragging && press != nil {
		set(press.high ? 1 : 0, lo + slider_pct(b, room) * (hi - lo), lo_v, hi_v, lo, hi, step)
	}
	// (after the press that moved a thumb: the default wins, both ends of it)
	if d, has := default.?; has && sig.double_clicked {
		a, z := min(d[0], d[1]), max(d[0], d[1])
		lo_v^ = clamp(slider_snap(a, step), lo, hi)
		hi_v^ = clamp(slider_snap(z, step), lo_v^, hi)
	}
	if n := wheel_steps(b, active >= 0); n != 0 {
		which := active
		if which < 0 {
			p := slider_pct(b, room)
			which = abs(p - (lo_v^ - lo) / (hi - lo)) <= abs(p - (hi_v^ - lo) / (hi - lo)) ? 0 : 1
		}
		set(which, values[which]^ + n * k * shift_steps(s.mods), lo_v, hi_v, lo, hi, step)
	}
	// the thumbs: boxes over the knobs, where the keyboard's focus is (laid out from the last frame's track)
	x0, x1 := slider_geom(b.rect, em, room)
	kr := em * SLIDER_KNOB_EM
	cy := (b.rect.max.y - b.rect.min.y) * 0.5
	if parent(b) {
		for i in 0 ..< 2 {
			v := values[i]
			if s.focus_key == thumbs[i] {
				// (the other thumb is an end of this one)
				if w, moved := slider_keys(v^, k, i == 0 ? lo : lo_v^, i == 0 ? hi_v^ : hi); moved { set(i, w, lo_v, hi_v, lo, hi, step) }
			}
			if r, ok := a11y_numeric_request(thumbs[i], v^, k); ok { set(i, r, lo_v, hi_v, lo, hi, step) }
			t := clamp((v^ - lo) / (hi - lo), 0, 1)
			kx := math.lerp(x0, x1, t) - b.rect.min.x
			next({fixed_x = kx - kr, fixed_y = cy - kr, width = px(2 * kr), height = px(2 * kr), radius = kr})
			thumb := build_box({.Focusable}, i == 0 ? "###lo" : "###hi")
			info := A11y_Info{role = .Slider, numeric = f64(v^), min = f64(i == 0 ? lo : lo_v^), max = f64(i == 0 ? hi_v^ : hi), orientation = .X}
			if step > 0 { info.step = f64(step) }
			if room { info.value = slider_text(format, v^) }
			a11y_default(thumb, info)
		}
	}
	d := slider_draw_of(b, format)
	d.range = true
	t0, t1 := clamp((lo_v^ - lo) / (hi - lo), 0, 1), clamp((hi_v^ - lo) / (hi - lo), 0, 1)
	d.t0 = anim(key_from_string(b.key, "t0"), t0, SLIDER_RATE, t0)
	d.t1 = anim(key_from_string(b.key, "t1"), t1, SLIDER_RATE, t1)
	if room { d.value_text = fmt.aprintf("%s-%s", slider_text(format, lo_v^), slider_text(format, hi_v^), allocator = frame_allocator()) }
	a11y_default(b, {role = .Group, value = d.value_text})
	return lo_v^ != before[0] || hi_v^ != before[1]
}

////////////////////////////////
// Repeat, segmented control

// A button that repeats while it is held (a number's − and +): true at the press, then again every
// Feel.repeat_interval_ms after Feel.repeat_delay_ms while the pointer stays on it (off the button it waits). It wakes
// the loop at the next repeat, not at every refresh while the button is held. A scroll bar's arrow repeats by the same
// rule, with the times of its standard (scrollbar_repeat).
repeat_pressed :: proc(sig: Signal) -> bool { return repeat_fires(gs(), sig.box.key, sig.pressed, sig.dragging, sig.hovering) }

// The rule of repeat_pressed for any held thing named by `key`: `pressed` this frame, `held` since, `on` it (the pointer
// is over it). Its timer is the State's (s.timers): a held thing that is not a widget (a scroll bar's arrow) has one too.
@(private)
repeat_fires :: proc(s: ^State, key: Key, pressed, held, on: bool) -> bool {
	return repeat_fires_every(s, key, pressed, held, on, s.feel.repeat_delay_ms, s.feel.repeat_interval_ms)
}

// repeat_fires with its own times: the first repeat `delay_ms` after the press, then one every `interval_ms`.
@(private)
repeat_fires_every :: proc(s: ^State, key: Key, pressed, held, on: bool, delay_ms, interval_ms: int) -> bool {
	fire := false
	if pressed {
		fire = true
		s.timers[key] = Timer{next_ms = s.time_ms + f64(delay_ms), last_build = s.build_index}
	} else if held {
		if t, ok := s.timers[key]; ok {
			t.last_build = s.build_index
			if on && s.time_ms >= t.next_ms { fire = true; t.next_ms = s.time_ms + f64(max(interval_ms, 1)) }
			s.timers[key] = t
		}
	}
	// (off it, its next repeat waits for the pointer, whose move is an event: a wake then would come every millisecond)
	if held && on {
		if t, ok := s.timers[key]; ok { wake_within(s, max(1, int(t.next_ms - s.time_ms + WAKE_ROUND_UP_MS))) }
	}
	return fire
}

@(private = "file") SEGMENTED_RATE :: 40

// key_radius: the corners of the chosen segment's key, and of each segment's hover and focus, which have its place and shape
Seg_Draw :: struct { t: f32, n: int, accent, face, well: Color, pad, radius, key_radius: f32, none: bool }   // none: no key

// machined: the key's face toward the accent, its least radius
@(private = "file") SEG_KEY_ACCENT :: 0.1
@(private = "file") SEG_KEY_RADIUS_PX :: 3
// a groove between two segments: its share of the track's height, and how far from the key it shows in full
@(private = "file") SEG_GROOVE_HEIGHT :: 0.5

@(private)
seg_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Seg_Draw)(user)
	r := b.rect
	if d.n <= 0 { return }
	if machined() {
		// a slot carved in the surface, grooves between its segments, the chosen one a raised key
		r = draw.Rect{{math.round(r.min.x), math.round(r.min.y)}, {math.round(r.max.x), math.round(r.max.y)}}
		h := r.max.y - r.min.y
		pad := math.max(math.round(d.pad), px1())
		machined_well(dc, r, d.radius, d.well)
		iw := ((r.max.x - r.min.x) - 2 * pad) / f32(d.n)
		for i in 1 ..< d.n {
			// (none beside the key: it covers its edges)
			if !d.none && f32(i) > d.t - 0.5 && f32(i) < d.t + 1.5 { continue }
			gx := math.round(r.min.x + pad + f32(i) * iw)
			gh := math.round(h * SEG_GROOVE_HEIGHT * 0.5)
			cy := math.round((r.min.y + r.max.y) * 0.5)
			machined_groove(dc, {gx, cy - gh}, {gx, cy + gh}, vertical = true)
		}
		if d.none { return }
		x := math.round(r.min.x + pad + d.t * iw)
		key := Rect{{x, r.min.y + pad}, {math.round(x + iw), r.max.y - pad}}
		machined_bevel(dc, key, d.key_radius, draw.mix(d.face, d.accent, SEG_KEY_ACCENT), 0, 0, glow = d.accent)
		return
	}
	if d.none { return }
	iw := ((r.max.x - r.min.x) - 2 * d.pad) / f32(d.n)
	x := r.min.x + d.pad + d.t * iw
	pill := Rect{{x, r.min.y + d.pad}, {x + iw, r.max.y - d.pad}}
	paint_rect(dc, pill, d.accent, d.key_radius)
}

// The colour of a segmented control's key in the style in effect, opaque: the accent, or machined the page's face a
// step toward it (seg_draw). The chosen label is made to read on it.
segmented_key_color :: proc() -> Color {
	accent := color("accent")
	key := machined() ? draw.mix(color("background"), accent, SEG_KEY_ACCENT) : accent
	key.a = 1
	return key
}

// The corners of a segmented control's key (seg_draw), as drawn. Flat: concentric with the track's, `pad` inside it.
// Machined: a radius of its own, near the slot's curve: at 0 its lit rim and its edge met in a notch at the corners.
@(private = "file")
seg_key_radius :: proc(track_radius, slot_radius, pad: f32, mach: bool) -> f32 {
	if mach { return math.round(max(slot_radius - math.max(math.round(pad), px1()) * 0.5, SEG_KEY_RADIUS_PX * scale())) }
	return concentric_radius(radius_drawn(gs(), track_radius), pad)
}

// How a segmented control looks: a sliding pill in a track, or words in a line, the chosen one bold and underlined, a
// slash between them ("All / Active 2 / Done 1").
Segmented_Look :: enum u8 { Pills, Text }

// A segment's room beside its label's padding, in ems: the key's rounded ends never touch the words.
@(private = "file") SEGMENT_ROOM_EM :: 0.8
// The least contrast of the chosen label on its pill (WCAG AA for text).
@(private = "file") SEGMENT_TEXT_RATIO :: 4.5

// The width a pill segmented control takes with no width given, in the style in effect: every segment as wide as the
// widest label with its padding (the segments are equal: seg_draw divides the track), and the track's padding. A
// language's longer word widens the control instead of being cut. A layout that places the control (beside a field, or
// on a line of its own when the window is narrow) reads it before the control is built.
segmented_width :: proc(labels: []string) -> f32 {
	if len(labels) == 0 { return 0 }
	em := font_size()
	st := top_style()
	widest: f32
	for l in labels { widest = max(widest, text_width(st.font, em, l)) }
	segment := math.ceil(widest + 2 * st.text_pad + em * SEGMENT_ROOM_EM)
	return f32(len(labels)) * segment + 2 * math.round(em * 0.25)   // (seg_draw's pad on each side)
}

// Sliding-pill segmented control. Returns true when the selection changed. A choice outside the labels (-1) is none:
// no segment shows chosen until a click or the keys choose one. `tips`: a tooltip per segment, shown when the
// pointer rests on it ("" or a missing entry: none); a screen reader reads it as the segment's description. `look`
// .Text: words in a line, as wide as they are. With no width given (next), it is segmented_width wide: no label is cut,
// in any language; a width given is kept. With no width given, a row too narrow for its labels makes it a dropdown of the
// same choices, at the room the row has (never narrower than the dropdown's own width): its size asks for its labels and
// gives way to the dropdown's, the layout gives it the room there is, and the next build draws the form that room holds.
// The size asked is the same in both forms: it never goes from one to the other and back.
segmented :: proc(id: string, labels: []string, selected: ^int, tips: []string = nil, look := Segmented_Look.Pills) -> (changed: bool) {
	if look == .Text { return segmented_text(id, labels, selected, tips) }
	s := gs()
	if !s.has_next || s.next_mod.width == nil {
		natural := segmented_width(labels)
		s.next_mod.width = Size{kind = .Pixels, value = natural, strictness = 0, least = min(dropdown_width(labels), natural)}
		s.has_next = true
		// (the room of the last layout: narrower than the labels, the dropdown)
		if prev := prev_box(id); prev != nil && prev.last_build + 1 >= s.build_index && prev.rect.max.x - prev.rect.min.x + 0.5 < natural {
			return dropdown(id, labels, selected)
		}
	}
	em := font_size()
	// (a choice outside the labels is none: no key. Its slide stays on a segment, so a first choice slides from there,
	// not from past the control's edge, where the key was drawn over what stands before it)
	none := selected^ < 0 || selected^ >= len(labels)
	at := f32(clamp(selected^, 0, max(len(labels) - 1, 0)))
	t := anim(key_from_string(parent_box().key, fmt.tprintf("%s_t", id)), at, SEGMENTED_RATE, at)
	accent := color("accent")
	mach := machined()
	text_on, text_off: Color
	// (machined: the chosen label on a metal key, in the text's colour; the other finishes: on the accent, in the colour
	// the theme made to read on it)
	text_on = color("accent_text")
	if mach { text_on = color("text") } else if tags(intent_tag(.Primary)) { text_on = color("text") }
	// (on the pill the chosen label must read whatever the theme or the program set as accent_text: a light accent with
	// a light accent_text left the word unreadable. Below AA, the page's or the text's colour, made readable there)
	if ground := segmented_key_color(); contrast(text_on, ground) < SEGMENT_TEXT_RATIO { text_on = ink_on(ground) }
	if tags("weak") { text_off = color("text") }
	if tags("button") {
		set_next_axis(.X)
		// (machined: the box draws nothing of its own, seg_draw carves the slot)
		b := build_box(mach ? {} : {.Draw_Background, .Draw_Border, .Sunken}, id)
		d := frame_new(Seg_Draw)
		d.t, d.n, d.accent, d.pad, d.none = t, len(labels), accent, math.round(em * 0.25), none   // (whole pixels: the key and the labels share it)
		d.face, d.well = color("background"), color("well")
		d.radius = max(b.radius, rad(em * 0.4))
		d.key_radius = seg_key_radius(b.radius, d.radius, d.pad, mach)
		b.custom, b.custom_user = seg_draw, d
		a11y_default(b, {role = .Radio_Group, orientation = .X})
		if parent(b) {
			// (each segment is where the key stands on it: the track less its padding on every side, as seg_draw divides
			// it. Its hover, press and focus then take the key's place and shape: as tall as the track, they drew a box
			// with corners of their own over the rounded track)
			spacer(px(d.pad))
			next({width = fill(), height = pct(1), axis = .Y, radius = 0})
			lane := build_box({}, "###seg_lane")
			push_parent(lane)
			spacer(px(d.pad))
			next({width = pct(1), height = fill(), axis = .X, radius = 0})
			inner := build_box({}, "###seg_inner")
			push_parent(inner)
			defer { pop_parent(); spacer(px(d.pad)); pop_parent(); spacer(px(d.pad)) }
			items := make([]^Box, len(labels), frame_allocator())
			on_one := false
			chosen := clamp(selected^, 0, len(labels) - 1)
			// (a hovered segment's face stops this far from its cell's edges: full width, it touched the key beside it
			// and the two read as one wider choice)
			gap := d.pad
			for label, i in labels {
				fg := i == selected^ ? text_on : text_off
				next({width = pct(1 / f32(len(labels))), height = pct(1), axis = .X, radius = 0})
				cell := build_box({}, fmt.tprintf("###segc%d", i))
				push_parent(cell)
				spacer(px(gap))
				next({width = fill(), height = pct(1), text_align = .Center, fg = fg, radius = d.key_radius})
				push_tags("segment")
				// (Fixed_Radius: key_radius is as drawn, concentric with the track's drawn corners; one Tab stop, the chosen.
				// The chosen one has no face of its own: the key is its face, and a hover's face, opaque, hid the key)
				flags := Box_Flags{.Clickable, .Draw_Text, .Fixed_Radius}
				if i == chosen { flags += {.Focusable} } else { flags += {.Draw_Hot_Effects} }
				item := build_box(flags, fmt.tprintf("%s###seg%d", label, i))
				pop_tags()
				spacer(px(gap))
				pop_parent()
				items[i] = item
				isig := signal(item)
				if isig.focused { on_one = true }
				if isig.clicked && i != selected^ { selected^ = i; changed = true }
				tip := i < len(tips) ? tips[i] : ""
				if tip != "" && hovered_for(isig) { if tooltip() { tooltip_text(tip) } }
				a11y_default(item, {role = .Radio_Button, toggled = i == selected^ ? .True : .False, position = i + 1, set_size = len(labels), description = tip})
			}
			if to := choice_group_step(on_one, chosen, len(labels)); to >= 0 {
				selected^, changed = to, true
				items[chosen].flags -= {.Focusable}
				items[to].flags += {.Focusable}
				set_focus(items[to].key)
			}
			// (the wheel steps through the choices: in a scrolling view, only once focused, wheel_steps)
			if n := wheel_steps(b, on_one); n != 0 && len(labels) > 0 {
				to := clamp(chosen - int(n), 0, len(labels) - 1)
				if to != chosen {
					selected^, changed = to, true
					items[chosen].flags -= {.Focusable}
					items[to].flags += {.Focusable}
					if on_one { set_focus(items[to].key) }
				}
			}
			// (the item clicked this frame is the selected one: the earlier items said otherwise)
			if changed { for c in items { if c.a11y != nil && c.a11y.position > 0 { c.a11y.toggled = c.a11y.position == selected^ + 1 ? .True : .False } } }
		}
	}
	return
}

// A group of choices (a segmented control's segments, a row of tabs, radio buttons) is one Tab stop: the chosen one.
// While a choice of the group has the keyboard, the arrows move the choice, and the keyboard goes with it (the caller
// gives it the new choice's box): Left the one before, Right the next, and Up and Down as well where `vertical`; Home the
// first, End the last. No wrap: an end is an end. -1: no move. (src/md/features/widget-table.md, G1)
@(private)
choice_group_step :: proc(focused: bool, selected, count: int, vertical := true) -> int {
	if !focused || count <= 0 { return -1 }
	to := selected
	if key_press(.Left) || (vertical && key_press(.Up)) { to -= 1 }
	if key_press(.Right) || (vertical && key_press(.Down)) { to += 1 }
	if key_press(.Home) { to = 0 }
	if key_press(.End) { to = count - 1 }
	to = clamp(to, 0, count - 1)
	return to == selected ? -1 : to
}

// (on each side of a separator)
@(private = "file") SEGMENTED_TEXT_GAP_EM :: 0.45
@(private = "file") SEGMENTED_TEXT_SEPARATOR :: "/"

@(private = "file")
segmented_text :: proc(id: string, labels: []string, selected: ^int, tips: []string) -> (changed: bool) {
	s := gs()
	em := font_size()
	set_next_axis(.X, .Center)
	if !s.has_next || s.next_mod.width == nil { s.next_mod.width = children_sum(); s.has_next = true }
	b := build_box({}, id)
	a11y_default(b, {role = .Radio_Group, orientation = .X})
	if parent(b) {
		st := top_style()
		bold := styled_face(st.font, true, false)
		items := make([]^Box, len(labels), frame_allocator())
		on_one := false
		chosen := clamp(selected^, 0, len(labels) - 1)
		for label, i in labels {
			if i > 0 {
				spacer(px(math.round(em * SEGMENTED_TEXT_GAP_EM)))
				if tags("weak") {
					next({width = text_size(0, 0), height = pct(1), text_pad = 0})
					sep := build_box({.Draw_Text}, fmt.tprintf("%s###sep%d", SEGMENTED_TEXT_SEPARATOR, i))
					a11y_default(sep, {ignore = true})
				}
				spacer(px(math.round(em * SEGMENTED_TEXT_GAP_EM)))
			}
			on := i == selected^
			if !on { push_tags("weak") }   // (the chosen one in the text's own colour)
			next({width = text_size(0, 0), height = pct(1), text_pad = 0, font = on ? bold : st.font, cursor = .Hand})
			item := build_box(i == chosen ? {.Clickable, .Focusable, .Draw_Text} : {.Clickable, .Draw_Text}, fmt.tprintf("%s###seg%d", label, i))
			if !on { pop_tags() }
			items[i] = item
			isig := signal(item)
			if isig.focused { on_one = true }
			if !on && isig.hovering { item.text_color = color("text") }
			if on {
				d := frame_new(Underline_Draw)
				d.color = item.text_color
				item.custom, item.custom_user = underline_draw, d
			}
			if isig.clicked && !on { selected^ = i; changed = true }
			tip := i < len(tips) ? tips[i] : ""
			if tip != "" && hovered_for(isig) { if tooltip() { tooltip_text(tip) } }
			a11y_default(item, {role = .Radio_Button, toggled = on ? .True : .False, position = i + 1, set_size = len(labels), description = tip})
		}
		if to := choice_group_step(on_one, chosen, len(labels)); to >= 0 {
			selected^, changed = to, true
			items[chosen].flags -= {.Focusable}
			items[to].flags += {.Focusable}
			set_focus(items[to].key)
		}
		if n := wheel_steps(b, on_one); n != 0 && len(labels) > 0 {
			to := clamp(chosen - int(n), 0, len(labels) - 1)
			if to != chosen {
				selected^, changed = to, true
				items[chosen].flags -= {.Focusable}
				items[to].flags += {.Focusable}
				if on_one { set_focus(items[to].key) }
			}
		}
		if changed { for c := b.first; c != nil; c = c.next { if c.a11y != nil && c.a11y.position > 0 { c.a11y.toggled = c.a11y.position == selected^ + 1 ? .True : .False } } }
	}
	return
}

@(private = "file")
Underline_Draw :: struct { color: Color }

// A line under a box's text, where its face puts an underline.
@(private = "file")
underline_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	s := gs()
	d := (^Underline_Draw)(user)
	m := font.metrics(s.fonts, b.font, b.font_size)
	o := text_origin(s, b, b.text_dim)
	th := max(1, math.round(m.underline_thickness))
	y := math.round(o.y + m.underline_offset)
	draw.rect(dc, {{o.x, y}, {o.x + b.text_dim.x, y + th}}, d.color)
}

////////////////////////////////
// Progress

@(private = "file") PROGRESS_RATE :: 24
@(private = "file") PROGRESS_MIN_T :: 0.002                  // no fill below this
@(private = "file") PROGRESS_SWEEP_MS :: 1600                // the indeterminate bar's segment, across the bar
@(private = "file") PROGRESS_SWEEP_SEGMENT_FRACTION :: 0.32

Bar_Draw :: struct { t: f32, indeterminate: bool, phase: f32, track, fill: Color }

@(private)
bar_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar_Draw)(user)
	r := b.rect
	w := r.max.x - r.min.x
	radius := rad((r.max.y - r.min.y) * 0.5)
	// (machined: a slot carved in the surface, its fill a lit face in it)
	if machined() { machined_well(dc, r, radius, color_from_tags(gs(), b.tags_key, "well")) } else { draw.rect(dc, r, d.track, radius) }
	if d.indeterminate {
		seg := w * PROGRESS_SWEEP_SEGMENT_FRACTION
		e := d.phase * d.phase * (3 - 2 * d.phase)
		x := math.lerp(-seg, w, e)
		f := Rect{{r.min.x + max(0, x), r.min.y}, {r.min.x + min(w, x + seg), r.max.y}}
		if f.max.x > f.min.x { draw.rect(dc, f, d.fill, radius) }
	} else if d.t > PROGRESS_MIN_T {
		paint_rect(dc, {r.min, {r.min.x + max(radius * 2, w * d.t), r.max.y}}, d.fill, radius)
	}
}

// Determinate (t in 0..1) or indeterminate bar. Size from the style stack or `next`. `lively`: a determinate bar drawn
// as progress_fill draws it (a primary-green gradient in its border), for what the user watches come (a download).
progress :: proc(id: string, t: f32, indeterminate := false, lively := false) {
	s := gs()
	b := build_box({}, id)
	if lively && !indeterminate {
		progress_fill(b, t)
		a11y_default(b, {role = .Progress_Indicator, numeric = f64(clamp(t, 0, 1) * 100), min = 0, max = 100, read_only = true,
			value = i18n.percent(f64(clamp(t, 0, 1)), allocator = frame_allocator())})
		return
	}
	d := frame_new(Bar_Draw)
	d.t = anim(key_from_string(b.key, "t"), t, PROGRESS_RATE, t)
	d.indeterminate = indeterminate
	d.phase = s.anim_rate != 0 ? f32(math.mod(s.time_ms, PROGRESS_SWEEP_MS)) / PROGRESS_SWEEP_MS : 0.5   // animations off: a still bar
	d.track, d.fill = color("track"), color("accent")
	b.custom, b.custom_user = bar_draw, d
	if indeterminate && s.anim_rate != 0 { s.anim_busy = true }
	if indeterminate {
		a11y_default(b, {role = .Progress_Indicator, busy = true})
	} else {
		a11y_default(b, {role = .Progress_Indicator, numeric = f64(clamp(t, 0, 1) * 100), min = 0, max = 100, read_only = true,
			value = i18n.percent(f64(clamp(t, 0, 1)), allocator = frame_allocator())})
	}
}

@(private = "file") SPINNER_TURN_MS :: 900
@(private = "file") SPINNER_ARC :: 0.75               // of a turn
@(private = "file") SPINNER_SIZE_EM :: 1.2
@(private = "file") SPINNER_THICKNESS :: 0.13         // of its size

@(private = "file")
Spinner_Draw :: struct { phase: f32, color: Color }

// An arc drawn as round dots that overlap (there is no arc primitive; a polyline's thick segments showed their joins).
@(private = "file")
spinner_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Spinner_Draw)(user)
	r := b.rect
	size := min(r.max.x - r.min.x, r.max.y - r.min.y)
	c := draw.rect_center(r)
	th := max(size * SPINNER_THICKNESS, 1.5 * scale())
	arc_dots(dc, c, size * 0.5 - th * 0.5, th, d.phase, SPINNER_ARC, d.color)
}

// An arc of `sweep` turns from the angle `start` (turns, clockwise from +x), `th` thick, centred on a circle of
// `radius`: the spinner's, and an active step's (stepper.odin).
@(private)
arc_dots :: proc(dc: ^draw.Context, c: Vec2, radius, th, start, sweep: f32, color: Color) {
	// (the arc's length: a whole turn is the circumference)
	steps := max(int(radius * turn.to_radians(sweep) / max(th * 0.35, 0.5)), 12)
	for k in 0 ..= steps {
		sn, cs := turn.sincos(start + f32(k) / f32(steps) * sweep)
		p := c + Vec2{cs, sn} * radius
		draw.rect(dc, {p - th * 0.5, p + th * 0.5}, color, th * 0.5)
	}
}

// A busy mark: three quarters of a circle that turns, `size` across (0: a little more than the font size), in the
// accent. While it is shown it asks for the next frames itself (with animations off, a still arc that asks for none). A
// screen reader hears a busy progress indicator.
spinner :: proc(id: string, size: f32 = 0) {
	s := gs()
	side := size > 0 ? size : math.round(font_size() * SPINNER_SIZE_EM)
	next_default({width = px(side), height = px(side)})
	b := build_box({}, id)
	d := frame_new(Spinner_Draw)
	d.phase = s.anim_rate != 0 ? f32(math.mod(s.time_ms, SPINNER_TURN_MS) / SPINNER_TURN_MS) : 0
	d.color = color("accent")
	b.custom, b.custom_user = spinner_draw, d
	if s.anim_rate != 0 { s.anim_busy = true }
	a11y_default(b, {role = .Progress_Indicator, busy = true})
}

// A filled disc `size` across (0: half the font size): the icon fonts have no filled circle. Its colour: the hue of
// `intent` (a recording, a state); none, the text's where it stands, as a glyph beside it would be (a dot in a button's
// words). Its colour says nothing to a screen reader: give it a name with `a11y` when it means something.
dot :: proc(id: string, size: f32 = 0, intent: Maybe(Intent) = nil) {
	side := size > 0 ? size : math.round(font_size() * 0.5)
	next_default({width = px(side), height = px(side)})
	b := build_box({}, id)
	d := frame_new(Dot_Draw)
	if it, ok := intent.?; ok {
		d.color = hue_color(intent_hue(it))
		d.color.a = 1
		d.own = true
	}
	b.custom, b.custom_user = dot_draw, d
	if b.a11y == nil { a11y_default(b, {ignore = true}) }
}

// The colour of a dot: its intent's (own), else its box's text colour when it is drawn.
Dot_Draw :: struct { color: Color, own: bool }

// (a circle, not the rounded square of a box's corners)
@(private = "file")
dot_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	r := b.rect
	w := min(r.max.x - r.min.x, r.max.y - r.min.y)
	c := draw.rect_center(r)
	prev := draw.set_circular_corners(dc, true)
	d := (^Dot_Draw)(user)
	// (no intent: the text's colour, as the box's style resolved it for this frame)
	draw.rect(dc, {c - w * 0.5, c + w * 0.5}, d.own ? d.color : b.text_color, w * 0.5)
	draw.set_circular_corners(dc, prev)
}

////////////////////////////////
// Dropdown and tabs

// A dropdown's arrow's cell, in ems: the arrow close to the right edge, a small gap. Its words have their text's inset
// only (src/md/features/dropdown.md); a dense scope's cell is tighter still.
@(private = "file") DROPDOWN_ARROW_EM :: 1.25
@(private = "file") DROPDOWN_DENSE_ARROW_EM :: 1.0

// The width a dropdown of `items` takes with no width given, in the style in effect: its widest item, its padding, its
// arrow and its border.
dropdown_width :: proc(items: []string) -> f32 {
	em := font_size()
	st := top_style()
	widest: f32
	for it in items { widest = max(widest, text_width(st.font, st.font_size, display_part(it))) }
	room := em * (dense_shown() ? DROPDOWN_DENSE_ARROW_EM : DROPDOWN_ARROW_EM)
	return math.ceil(widest + 2 * st.text_pad + room + 2 * max(1, math.round(gs().scale)))
}

// Button showing the current item; opens a menu of `items`. Returns true when the selection changed. Without a width
// from `next`, it is as wide as its widest item, its padding and its arrow: the style's width (a share of its parent)
// left nothing in a row as wide as its children, a view's header tools, and it showed as an empty sliver.
dropdown :: proc(id: string, items: []string, selected: ^int) -> (changed: bool) {
	em := font_size()
	s := gs()
	if !s.has_next || s.next_mod.width == nil { next_default({width = px(dropdown_width(items))}) }
	menu_id := fmt.tprintf("###dropdown_menu_%x", u64(key_from_string(parent_box().key, id)))
	open := menu_is_open(menu_id)
	next_default({radius = em * shape_of(.Control)})   // (a button's corners)
	btn: ^Box
	sig: Signal
	if tags("button") {
		set_next_axis(.X, .Center)
		btn = build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, id)
		sig = signal(btn)
		cur := selected^ >= 0 && selected^ < len(items) ? items[selected^] : ""   // none chosen, or the list changed
		a11y_default(btn, {role = .Combo_Box, value = display_part(cur), expanded = open, popup = .Listbox, read_only = true})
		if parent(btn) {
			tight := dense_shown()
			next({width = fill(), height = pct(1)})
			build_box({.Draw_Text}, fmt.tprintf("%s###cur", cur))
			if tags("weak") { icon(open ? ICON_UP : ICON_DOWN, em * (tight ? DROPDOWN_DENSE_ARROW_EM : DROPDOWN_ARROW_EM), nil, widget_icons()) }
		}
	}
	// Down / Alt+Down on the focused button opens the list from the keyboard too
	kb := sig.focused && !open && (key_press(.Down, {.Alt}) || key_press(.Down) || key_press(.F4))
	if sig.clicked || kb {
		if open { menu_close() } else {
			menu_open(menu_id, btn.rect, btn.key, from_keyboard = kb)
			menu_select(selected^)   // keyboard starts from the current value
		}
	}
	// (the wheel over a closed dropdown steps to the previous or next item: in a scrolling view, only once focused)
	if !open && len(items) > 0 {
		if n := wheel_steps(btn, sig.focused); n != 0 {
			to := clamp(selected^ - int(n), 0, len(items) - 1)
			if to != selected^ { selected^ = to; changed = true }
		}
	}
	if menu(menu_id, dense_shown() ? btn.size.x : max(btn.size.x, em * MENU_MIN_WIDTH_EM)) {
		for item, i in items {
			if menu_item(item, "", i == selected^).clicked { selected^ = i; changed = true }
		}
	}
	return
}


// Row of tabs, the chosen one joined to what it shows (tab_box), on a strip (strip.odin): too many for the row, it scrolls with
// arrows, never a bar; the chosen tab is brought into view when it changes. With no width given (next), as wide as its tabs, and the first to give way in a short row; `strip_view(id)` is
// its tab list. `icons` may be nil. Returns true when the selection changed.
tabs :: proc(id: string, labels: []string, icons: []string, selected: ^int) -> (changed: bool) {
	return tabs_ex(id, labels, icons, selected).changed
}

// A tab's own content (Tabs_Options.content): built in its body, in place of its icon and words.
Tab_Content :: struct {
	index:   int,
	on:      bool,   // the chosen tab
	hot:     bool,   // under the pointer, or something in it
	box:     ^Box,   // the tab
	label:   string, // its label (its accessible name)
}

// What a row of tabs does beyond choosing (tabs_ex).
Tabs_Options :: struct {
	content: proc(user: rawptr, t: Tab_Content),   // a tab's own content (nil: its icon and its label)
	after:   proc(user: rawptr),                    // built after the last tab, on the strip (a "+")
	user:    rawptr,
	framed:  bool,   // the strip is a tab_panel's: the panel draws the line
}

// What happened to a row of tabs this frame.
Tabs_Result :: struct {
	changed: bool,
	menu:    int,    // the tab whose menu was asked (a right click, the Menu key, Shift+F10); -1: none
	menu_at: Vec2,   // where that menu opens
	closed:  int,    // the tab a middle click asked to close; -1: none
}

// ui.tabs with a tab's own content, a slot after the tabs, and the signals a program builds its menus on.
tabs_ex :: proc(id: string, labels: []string, icons: []string, selected: ^int, o := Tabs_Options{}) -> (res: Tabs_Result) {
	res.menu, res.closed = -1, -1
	changed := false
	defer res.changed = changed
	em := font_size()
	if strip(id) {
		a11y_default(parent_box(), {role = .Tab_List, orientation = .X})
		// (the row's bottom edge a line, out of which the chosen tab rises: tab_box; a tab_panel's frame draws its own)
		if outer := parent_box().parent; outer != nil && !o.framed {
			outer.custom = tab_line_draw
			if tab_style() != .Silhouette { outer.custom_user = tab_strip_look({}) }
		}
		tab_strip_start()
		first_tab: ^Box
		items := make([]^Box, len(labels), frame_allocator())
		on_one := false
		chosen := clamp(selected^, 0, len(labels) - 1)
		for label, i in labels {
			on := selected^ == i
			b := tab_box(fmt.tprintf("%s_%d", id, i), on)
			if on { strip_reveal(b) }
			// (one Tab stop, the chosen tab: the arrows move along the row, choice_group_step)
			if i != chosen { not_a_tab_stop(b) }
			items[i] = b
			if parent(b) { if tab_body() {
				if !on { push_tags("weak") }
				if o.content != nil {
					o.content(o.user, {index = i, on = on, hot = b.hot_t > 0.5 || hot_within(b.key), box = b, label = label})
				} else {
					spacer(px(em))
					if i < len(icons) { icon(icons[i], em * 1.6) }
					next({width = tab_title_width(label), height = pct(1)})
					build_box({.Draw_Text}, label)
					spacer(px(em))
				}
				if !on { pop_tags() }
			} }
			sig := signal(b)
			if sig.focused { on_one = true }
			if sig.clicked && !on { selected^ = i; changed = true }
			if sig.right_clicked { res.menu, res.menu_at = i, mouse_pos() }
			if sig.focused && (key_press(.Menu) || key_press(.F10, {.Shift})) { res.menu, res.menu_at = i, Vec2{b.rect.min.x, b.rect.max.y} }
			if sig.middle_clicked { res.closed = i }
			a11y_default(b, {role = .Tab, selected = on, position = i + 1, set_size = len(labels)})
			if first_tab == nil { first_tab = b }
		}
		if to := choice_group_step(on_one, chosen, len(labels), vertical = false); to >= 0 {
			selected^, changed = to, true
			items[chosen].flags -= {.Focusable}
			items[to].flags += {.Focusable}
			set_focus(items[to].key)
		}
		// (the tab clicked this frame is the selected one: the earlier tabs said otherwise)
		if changed {
			i := 0
			for c := first_tab; c != nil && i < len(labels); c = c.next {
				if c.a11y == nil || c.a11y.role != .Tab { continue }
				c.a11y.selected = i == selected^
				i += 1
			}
		}
		if o.after != nil {
			// (across the tabs' words: under the strip's ground above an outlined tab, tab_body)
			outlined := tab_style() == .Silhouette || tab_style() == .Folder
			next({width = children_sum(0), height = pct(1), axis = .Y})
			if column(id = "###tabs_after") {
				if outlined { spacer(pct(TAB_TOP_SHARE)) }
				next({width = children_sum(0), height = fill(), axis = .X})
				if row(.Center, id = "###tabs_after_row") { o.after(o.user) }
			}
		}
	}
	return
}

////////////////////////////////
// Key caps, cards, form rows

kbd :: proc(text: string) {
	em := font_size()
	if tags("kbd") {
		if style({font = mono_font(), font_size = em * 0.8, radius = em * 0.3, text_align = .Center}) {
			next({width = text_size(em * 0.5), height = px(dense(em * 1.5))})
			build_box({.Draw_Background, .Draw_Border, .Draw_Text, .No_Text_Trunc}, text)
		}
	}
}

// A card's own look (card, list_card), in every finish; zero fields are the theme's.
Card_Options :: struct {
	radius: f32,          // its corners, logical pixels (0: the theme's, 0.6 font size)
	look:   Plate_Look,   // its face, edge, rim and shadow (a permission card: a warm gradient, an accent edge)
}

// `if card("Title", ICON) { ... }`: a titled panel, full width, height from its content, CARD_PAD in from each of its
// four edges. It adds nothing after itself: the page puts GROUP_GAP or ITEM_GAP between two cards. Tags used: "card".
// `id`: its box's id ("": "###card_<title>"; cards without a title in one list need one each). `o`: its own look.
@(require_results, deferred_none = card_end)
card :: proc(title: string, icon := "", id := "", o := Card_Options{}) -> bool {
	em := font_size()
	card_open(id != "" ? id : fmt.tprintf("###card_%s", title), CARD_PAD, title, o)
	if title != "" {
		next({width = fill(), height = px(dense(em * 2.2))})
		if row(.Center) {
			if icon != "" {
				// (the icon procedure is hidden by the parameter: its cell, as icon builds it)
				next({width = px(em * 1.8), height = pct(1), font = gs().icon_font, text_align = .Center})
				if tags("weak") { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico%d", icon, parent_box().child_count)) }
			}
			next({width = fill(), height = pct(1)})
			if style({font_size = em * 1.1}) {
				// (the card's name: not read a second time)
				a11y({ignore = true})
				build_box({.Draw_Text}, fmt.tprintf("%s###card_title", title))
			}
		}
	}
	return true
}

@(private)
card_end :: proc() {
	card_close(CARD_PAD)
}

// `if form_row("Name") { widget }`: label on the left in the form's label column, the widget fills the rest; its top at
// the label's top. The rows of one parent box are one form: its column is as wide as its longest label and a gap
// (CONTROL_GAP), FORM_LABEL_MIN_EM at least, FORM_LABEL_CAP of the form's width at most (a longer label wraps). Widgets
// inside default to full width and one control's height (control_height). The intent: src/md/features/form-row.md.
@(require_results, deferred_none = form_row_end)
form_row :: proc(label_text: string) -> bool {
	em := font_size()
	line_h := control_height()
	// (a row a line and a half tall keeps the room between two controls of a form: its half above, its half below the line)
	room := max(0, math.round((dense(em * FORM_ROW_EM) - line_h) * 0.5))
	set_next_axis(.Y)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	r := build_box({}, fmt.tprintf("###frow_%s", label_text))
	push_parent(r)
	if room > 0 { spacer(px(room), exact = true) }
	// as tall as its widget (at least one line): a widget of several lines grows the row downward, its label on its first
	set_next_axis(.X)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	push_parent(build_box({}, "###frow_line"))
	if tags("weak") {
		lbl := build_box({.Draw_Text}, fmt.tprintf("%s###lbl", label_text))
		// (its own column until form_columns gives it the form's, after every row of the build: a dialog's measure
		// during the build counts its words whole)
		lbl.pref = {.X = px(form_label_need(lbl)), .Y = px(line_h)}
		append(&gs().form_labels, lbl)
	}
	push_style_copy()
	top_style().pref = {.X = fill(), .Y = px(line_h)}
	return true
}

// A form's label column: its least in font sizes, its most a share of the form's width. A form row's height with a
// widget of one line, in font sizes.
@(private = "file") FORM_LABEL_MIN_EM :: 3
@(private = "file") FORM_LABEL_CAP :: 0.4
@(private = "file") FORM_ROW_EM :: 2.5

// What a form row's label asks of the column: its inset, its words on one line, the gap before its field.
@(private = "file")
form_label_need :: proc(lbl: ^Box) -> f32 {
	return math.ceil(lbl.text_pad + lbl.text_dim.x) + math.round(lbl.font_size * CONTROL_GAP)
}

// Each form's label column, once its rows are built: the rows of one parent box share the widest need, so every field
// of the form starts at one x and no label leaves a void before its field. One pass over the labels built: the words
// were measured when their boxes were built. A label longer than the column wraps, its first line where a label of one
// line sits (a label a user must read is never cut).
//
// end_build settles every form left (within nil), before the layout; its cap is of the form's width in the last layout
// (none before its first). A panel that grows to what is in it (a dialog, a view's panel) settles its own forms first
// (within: the panel), before it measures them: its rows are built, and a short label beside a wide field must ask for
// the column, not for its own words. Its cap is of `room`, the most the panel can be, not of its last width: a width
// measured from the cap would move the cap at the next build.
@(private)
form_columns :: proc(s: ^State, within: ^Box = nil, room: f32 = 0) {
	if len(s.form_labels) == 0 { return }
	form_of :: proc(lbl: ^Box) -> ^Box { return lbl.parent.parent.parent }   // the label, its line, its row, the form
	inside :: proc(b, within: ^Box) -> bool {
		if within == nil { return true }
		for p := b; p != nil; p = p.parent { if p == within { return true } }
		return false
	}
	// (settled once: a wrapped label's height is no longer its line's)
	settled := make([dynamic]^Box, context.temp_allocator)
	kept := 0
	for l in s.form_labels {
		if inside(form_of(l), within) { append(&settled, l) } else { s.form_labels[kept] = l; kept += 1 }
	}
	resize(&s.form_labels, kept)
	widest := make(map[^Box]f32, 8, context.temp_allocator)
	for l in settled {
		f := form_of(l)
		widest[f] = max(widest[f], form_label_need(l))
	}
	for l in settled {
		f := form_of(l)
		col := max(widest[f], math.round(l.font_size * FORM_LABEL_MIN_EM))
		cap_room := room > 0 ? room : f.size.x - content_pad(f, .X)
		if cap_room > 0 { col = min(col, math.floor(cap_room * FORM_LABEL_CAP)) }
		line_h := l.pref[.Y].value
		l.pref[.X] = px(col)
		if form_label_need(l) > col {
			// (as tall as its lines, its first line where one line sits in a control's height)
			l.flags += {.Text_Wrap}
			l.pref[.Y] = text_size(max(0, (line_h - line_height_of(l)) * 0.5 - l.text_pad))
		}
	}
}

@(private)
form_row_end :: proc() {
	pop(&gs().style_stack)
	line := parent_box()
	if lbl := line.first; lbl != nil && lbl.next != nil {
		w := lbl.next
		// (a widget shorter than a line, a progress bar, sits centred on the label's line, not on its top)
		if h := w.pref[.Y]; h.kind == .Pixels && h.value < lbl.pref[.Y].value { line.cross = .Center }
		// the row's label names its widget (the first box after it) unless the app named it; a plain box that holds a
		// field and its note under it: the field, its first box
		for w.a11y == nil && (.Focusable not_in w.flags) && w.first != nil { w = w.first }
		if w.a11y == nil || (w.a11y.name == "" && w.a11y.labelled_by == 0) { a11y_set(w, {labelled_by = lbl.key}) }
	}
	pop_parent()
	r := parent_box()
	if first := r.first; first != nil && first != line { spacer(px(first.pref[.Y].value), exact = true) }
	pop_parent()
}

// `if well("###id") { ... }`: a sunken box, carved in the surface (code, a preview, a list of facts): the theme's well
// (its "well" colour; the machined finish carves it in, with a lit lower lip). Its size and corners from `next`; `axis`:
// how its children are laid out. `pad`: an inset of that many font sizes on its four sides (INNER_PAD for a text in it);
// `edge = false`: no border (a tinted area inside a card, where a second edge is one line too many). Tags used: "well".
@(require_results, deferred_in = well_end)
well :: proc(id: string, axis := Axis.Y, flags: Box_Flags = {}, pad: f32 = 0, edge := true) -> bool {
	set_next_axis(axis)
	push_tags("well")
	b := build_box({.Draw_Background, .Sunken} + (edge ? Box_Flags{.Draw_Border} : {}) + flags, id)
	pop_tags()
	push_parent(b)
	if pad > 0 {
		// (the inset: a line across `axis` between two gaps, then the body along `axis` in it, as card's; each as wide
		// and as tall as the well lets it: what it holds when the well grows to it, all of it when it is sized)
		fit :: proc(s: Size) -> Size { return s.kind == .Children_Sum ? children_sum() : fill() }
		space(pad)
		set_next_axis(axis == .Y ? .X : .Y)
		gs().next_mod.width, gs().next_mod.height = fit(b.pref[.X]), fit(b.pref[.Y])
		push_parent(build_box({}, "###well_pad"))
		space(pad)
		set_next_axis(axis)
		gs().next_mod.width, gs().next_mod.height = fit(b.pref[.X]), fit(b.pref[.Y])
		push_parent(build_box({}, "###well_body"))
	}
	return true
}

@(private)
well_end :: proc(id: string, axis := Axis.Y, flags: Box_Flags = {}, pad: f32 = 0, edge := true) {
	inset := pad
	if inset > 0 {
		pop_parent()   // body
		space(inset)
		pop_parent()   // padded line
		space(inset)
	}
	pop_parent()   // well
}

// A search field that opens a search elsewhere (the command palette): it looks like the fields one types in (sunken, an
// input's border and corners), its magnifying glass, `hint` in weak words, `keys` at its end (the shortcut that opens
// it too: the program's). It holds no text: a click, Enter or Space is its signal's `clicked`.
// Its size comes from `next` (default: 19 ems wide, a field's height).
search_launcher :: proc(id: string, hint: string, keys := "", tip := "") -> Signal {
	em := font_size()
	next_default({width = px(em * 19), height = px(control_height()), radius = em * shape_of(.Control)})
	set_next_axis(.X, .Center)
	push_tags("input")
	b := build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects, .Draw_Focus_Ring, .Sunken}, id)
	pop_tags()
	b.cursor = .Hand
	a11y_default(b, {role = .Button, name = hint})
	push_parent(b)
	if tags("weak") {
		next({width = px(em * 2), height = pct(1), font = lucide_icons(), text_align = .Center, text_pad = 0})
		build_box({.Draw_Text, .No_Text_Trunc}, lucide.SEARCH + "###sl_icon")
		next({width = fill(), height = pct(1), text_pad = 0})
		build_box({.Draw_Text}, fmt.tprintf("%s###sl_hint", hint))
	}
	if keys != "" {
		kbd(keys)
		spacer(px(em * 0.4))
	}
	pop_parent()
	sig := signal(b)
	button_tip(sig, tip)
	return sig
}
