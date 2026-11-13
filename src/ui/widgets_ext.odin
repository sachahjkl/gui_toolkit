package ui

// The widget set beyond the basics: toggles, sliders, numbers, segmented controls, chips, rating, progress,
// dropdowns, tabs, key caps, cards and form rows. Every widget takes a stable `id` string (see key.odin) and keeps its
// state in the caller's variables; hover/press/animation state lives in the box tree.

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../draw"
import "../font"
import "../platform"
import lucide "../lucide"

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

// A widget's mark (one of the ICON_ characters), `width` wide, in the toolkit's icon font.
@(private)
widget_icon :: proc(glyph: string, width: f32, fg: Maybe(Color) = nil) {
	next({width = px(width), height = pct(1), font = widget_icons(), text_align = .Center, fg = fg})
	build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico%d", glyph, parent_box().child_count))
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

mono_font :: proc() -> font.Font_Id { return gs().mono_font != 0 ? gs().mono_font : top_style().font }

////////////////////////////////
// Small building blocks

// Fixed-width icon cell (icon font), full height of the parent.
icon :: proc(glyph: string, width: f32, fg: Maybe(Color) = nil) {
	next({width = px(width), height = pct(1), font = gs().icon_font, text_align = .Center, fg = fg})
	build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico%d", glyph, parent_box().child_count))
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

// Last frame's box for an id under the current parent (its rect and size are valid, e.g. for scroll geometry).
prev_box :: proc(id: string) -> ^Box { return box_from_key(key_from_string(parent_box().key, id)) }

////////////////////////////////
// Check marks and radios

@(private = "file") MARK_RATE :: 30
@(private = "file") MARK_RING_PX :: 1.5
@(private = "file") MARK_BOX_RADIUS_FRACTION :: 0.28     // of the check box's width
@(private = "file") MARK_FILL_FADE_SPEED :: 1.6          // the fill is opaque before the mark has grown
@(private = "file") MARK_CHECK_MIN_T :: 0.05             // no check glyph this small
@(private = "file") MARK_RING_ALPHA :: 0.5
@(private = "file") MARK_RING_HOT_ALPHA :: 0.25

Mark_Draw :: struct { t: f32, accent, ring: Color, size: f32, radio: bool }

@(private)
mark_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	s := gs()
	d := (^Mark_Draw)(user)
	r := b.rect
	w := r.max.x - r.min.x
	if machined() {   // a hole in the surface; checked, a raised key of the accent in it (a radio: a lit bead)
		well := color_from_tags(s, b.tags_key, "well")
		prev := draw.set_circular_corners(dc, d.radio)
		machined_well(dc, r, d.radio ? w * 0.5 : rad(w * MARK_BOX_RADIUS_FRACTION), well)
		draw.set_circular_corners(dc, prev)
		if d.t <= MARK_CHECK_MIN_T { return }
		if d.radio {
			machined_lamp(dc, draw.rect_center(r), w * 0.55 * d.t, d.accent, 1, 0)
			return
		}
		inset := max(1, math.round(scale())) + (1 - d.t) * w * 0.5
		draw.push_alpha(dc, min(1, d.t * MARK_FILL_FADE_SPEED))
		machined_bevel(dc, draw.rect_pad(r, -inset), rad(w * MARK_BOX_RADIUS_FRACTION) - inset * 0.5, d.accent, 0, 0)
		draw.pop_alpha(dc)
		mark_check(s, dc, r, d)
		return
	}
	if d.radio {
		draw.rect(dc, r, draw.mix(d.ring, d.accent, d.t), w * 0.5, MARK_RING_PX * scale())
		dot := w * 0.5 * d.t
		c := draw.rect_center(r)
		a := d.accent
		a.a *= d.t
		draw.rect(dc, {{c.x - dot * 0.5, c.y - dot * 0.5}, {c.x + dot * 0.5, c.y + dot * 0.5}}, a, dot * 0.5)
		return
	}
	inset := (1 - d.t) * w * 0.5
	fill := d.accent
	fill.a *= min(1, d.t * MARK_FILL_FADE_SPEED)
	paint_rect(dc, draw.rect_pad(r, -inset), fill, rad(w * MARK_BOX_RADIUS_FRACTION), d.t)
	draw.rect(dc, r, draw.mix(d.ring, d.accent, d.t), rad(w * MARK_BOX_RADIUS_FRACTION), MARK_RING_PX * scale())
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
	draw.text(dc, marks, size, {math.round(c.x - dim * 0.5), math.round(c.y + (m.ascent - m.descent) * 0.5)}, {1, 1, 1, d.t}, ICON_CHECK)
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
	row_box := build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, id)
	a11y_default(row_box, {role = radio ? .Radio_Button : .Check_Box, toggled = on ? .True : .False})
	sig := signal(row_box)
	if parent(row_box) {
		t := anim(key_from_string(row_box.key, "t"), on ? 1 : 0, MARK_RATE)
		spacer(px(em * 0.4))
		// (wrapped, the mark stands on the first line: centered in that line's height, as the label's box lays it out)
		cell := em * 1.4
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
		d.ring = color("text")
		d.ring.a = MARK_RING_ALPHA + MARK_RING_HOT_ALPHA * row_box.hot_t
		d.ring = tuned(d.ring)
		d.size = em * 0.95
		d.radio = radio
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
// the next lines (the row as tall as they are, the mark on the first) instead of running past it.
checkbox :: proc(id: string, text: string, value: ^bool, wrap := false) -> Signal {
	sig := mark_row(id, text, value^, false, wrap)
	if sig.clicked { value^ = !value^; a11y_state_toggled(sig.box, value^) }
	return sig
}

radio :: proc(id: string, text: string, selected: ^int, index: int, wrap := false) -> Signal {
	sig := mark_row(id, text, selected^ == index, true, wrap)
	if sig.clicked { selected^ = index; a11y_state_toggled(sig.box, true) }
	return sig
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

Toggle_Draw :: struct { t, hot, active: f32, track, accent: Color }

@(private)
toggle_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Toggle_Draw)(user)
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
		machined_well(dc, r, shape_rad(h * 0.5), draw.mix(well, d.accent, d.t * TOGGLE_MACHINED_LIT))
		machined_bevel(dc, {{x, r.min.y + pad}, {x + kw, r.max.y - pad}}, shape_rad(kd * 0.5), TOGGLE_MACHINED_KNOB, d.hot, d.active)
		return
	}
	paint_rect(dc, r, draw.mix(d.track, d.accent, d.t), rad(h * 0.5), d.t)
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

// Switch (named `toggle` because `switch` is an Odin keyword).
toggle :: proc(id: string, text: string, value: ^bool) -> Signal {
	em := font_size()
	fit := fit_row_width()
	set_next_axis(.X, .Center)
	row_box := build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, id)
	sig := signal(row_box)
	if sig.clicked { value^ = !value^ }
	a11y_default(row_box, {role = .Switch, toggled = value^ ? .True : .False})
	if parent(row_box) {
		spacer(px(em * 0.4))
		next({width = fit ? text_size() : fill(), height = pct(1)})
		build_box({.Draw_Text}, text)
		next({width = px(em * 2.6), height = px(em * 1.4)})
		d := frame_new(Toggle_Draw)
		d.t = anim(key_from_string(row_box.key, "t"), value^ ? 1 : 0, TOGGLE_RATE)
		d.hot, d.active = row_box.hot_t, row_box.active_t
		d.track = off_track()
		d.accent = color("accent")
		custom("track", toggle_draw, d)
		spacer(px(em * 0.4))
	}
	return sig
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

@(private)
slider_geom :: proc(r: Rect, em: f32, value_room := true) -> (x0, x1: f32) {
	pad := em * 0.75
	x0 = r.min.x + pad
	x1 = r.max.x - (value_room ? em * SLIDER_VALUE_ROOM_EM : 0) - pad
	if x1 < x0 + SLIDER_TRACK_MIN_PX * scale() { x1 = x0 + SLIDER_TRACK_MIN_PX * scale() }
	return
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
	kr := em * (SLIDER_KNOB_EM + SLIDER_KNOB_HOT_EM * d.hot + SLIDER_KNOB_ACTIVE_EM * d.active)
	knobs := [2]f32{math.lerp(x0, x1, d.t0), fx1}
	sc := scale()
	if machined() {   // a slot carved in the surface, its run lit with the accent; the knobs raised keys on it
		mth := math.round(th * SLIDER_MACHINED_TRACK)
		slot := Rect{{x0, math.round(cy - mth * 0.5)}, {x1, math.round(cy - mth * 0.5) + mth}}
		machined_well(dc, slot, shape_rad(mth * 0.5), color_from_tags(gs(), b.tags_key, "well"))
		if fx1 - fx0 > 1 { paint_rect(dc, {{fx0, slot.min.y + sc}, {fx1, slot.max.y - sc}}, d.accent, shape_rad(mth * 0.5)) }
		prev := draw.set_circular_corners(dc, true)
		for i in (d.range ? 0 : 1) ..< 2 {
			kx := knobs[i]
			machined_bevel(dc, {{kx - kr, cy - kr}, {kx + kr, cy + kr}}, kr, TOGGLE_MACHINED_KNOB, d.hot, d.active)
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
slider :: proc(id: string, value: ^f32, lo, hi: f32, step: f32 = 0, format := "%.2f") -> (sig: Signal) {
	b := build_box({.Clickable, .Focusable}, id)
	b.cursor = .Hand
	sig = signal(b)
	if n := wheel_steps(b, sig.focused); n != 0 {
		k := step > 0 ? step : (hi - lo) / SLIDER_FINE_DIVISIONS
		v := value^ + n * k * shift_steps(gs().mods)
		if step > 0 { v = math.round(v / step) * step }
		value^ = clamp(v, lo, hi)
	}
	if sig.focused {
		k := step > 0 ? step : (hi - lo) / SLIDER_FINE_DIVISIONS
		page := f32(gs().feel.step_page)
		v := value^
		for sh in ([2]platform.Modifiers{{}, {.Shift}}) {
			by := k * shift_steps(sh)
			if key_press(.Left, sh) || key_press(.Down, sh) { v -= by }
			if key_press(.Right, sh) || key_press(.Up, sh) { v += by }
			if key_press(.Page_Down, sh) { v -= page * by }
			if key_press(.Page_Up, sh) { v += page * by }
		}
		if key_press(.Home) { v = lo }
		if key_press(.End) { v = hi }
		if step > 0 { v = math.round(v / step) * step }
		value^ = clamp(v, lo, hi)
	}
	if sig.pointer_pressed || sig.dragging {
		v := lo + slider_pct(b, format != "") * (hi - lo)
		if step > 0 { v = math.round(v / step) * step }
		value^ = clamp(v, lo, hi)
	}
	if v, ok := a11y_numeric_request(b.key, value^, step > 0 ? step : (hi - lo) / SLIDER_FINE_DIVISIONS); ok {
		if step > 0 { v = math.round(v / step) * step }
		value^ = clamp(v, lo, hi)
	}
	d := frame_new(Slider_Draw)
	t := clamp((value^ - lo) / (hi - lo), 0, 1)
	d.t1 = anim(key_from_string(b.key, "t"), t, SLIDER_RATE, t)
	d.hot, d.active = b.hot_t, b.active_t
	d.track, d.accent, d.text = off_track(), color("accent"), color("text")
	d.value_text = strings.index_byte(format, '%') >= 0 ? fmt.aprintf(format, value^, allocator = frame_allocator()) : format
	d.mono = mono_font()
	d.no_text = format == ""
	b.custom, b.custom_user = slider_draw, d
	a11y_default(b, {role = .Slider, numeric = f64(value^), min = f64(lo), max = f64(hi), step = step > 0 ? f64(step) : nil, value = d.value_text, orientation = .X})
	return
}

@(private = "file") NAV_ITEM_RADIUS_PX :: 6
@(private = "file") NAV_ITEM_HEIGHT_EM :: 2.1

@(private = "file")
Nav_Item_Draw :: struct { pressed: bool, face: Color, radius: f32 }

// A line of a navigation list (a settings page, a document of a side list): an icon (a glyph of `icon_font`; "" none)
// and `title`, from the left edge, as wide as its parent. A ghost under the pointer, pressed in while `pressed` (the
// one shown; machined: a bevel, flat in the other finishes). Its signal: a click shows it, a double click may rename it.
nav_item :: proc(id, title, icon: string, icon_font: font.Font_Id, pressed: bool, em: f32) -> Signal {
	next({width = fill(), height = px(math.round(em * NAV_ITEM_HEIGHT_EM)), axis = .X, cross = .Center, cursor = .Hand})
	a11y({role = .Button, name = title})
	b := build_box({.Clickable, .Focusable}, id)
	d := frame_new(Nav_Item_Draw)
	d^ = {pressed, color("track"), NAV_ITEM_RADIUS_PX * scale()}
	b.custom = proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
		d := (^Nav_Item_Draw)(user)
		if !d.pressed && b.hot_t < 0.01 { return }
		machined_bevel(dc, b.rect, d.radius, d.face, b.hot_t, d.pressed ? 1 : b.active_t * b.hot_t)
	}
	b.custom_user = d
	sig := signal(b)
	if parent(b) {
		spacer(px(em * 0.6))
		if icon != "" && icon_font != 0 {
			next({width = px(em * 1.4), height = pct(1), font = icon_font, text_align = .Center, text_pad = 0})
			if pressed { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ic", icon)) } else if tags("weak") { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ic", icon)) }
			if title != "" { spacer(px(em * 0.45)) }
		}
		if title != "" {
			next({width = fill(), height = pct(1), text_pad = 0})
			if pressed { label(fmt.tprintf("%s###t", title)) } else if tags("weak") { label(fmt.tprintf("%s###t", title)) }
		}
	}
	return sig
}

// What a step is multiplied by with these modifiers: Feel.step_shift with Shift, else 1. The step of a slider, a slider
// field, a number, by key, notch or button.
@(private)
shift_steps :: proc(mods: platform.Modifiers) -> f32 { return .Shift in mods ? f32(gs().feel.step_shift) : 1 }

// Whole notches of the wheel turned over `b` this frame, up positive: what a slider or a spin field moves by. `b` takes
// the wheel when the pointer is over it; in a view that scrolls (a page of settings), only once it has the keyboard
// (`focused`), so that the wheel over it scrolls the view as it passes. Fractions of a notch (a touchpad) add up.
wheel_steps :: proc(b: ^Box, focused: bool) -> f32 {
	s := gs()
	scrolls := false
	for p := b.parent; p != nil; p = p.parent {
		if .View_Scroll_Y in p.flags || .View_Scroll_X in p.flags { scrolls = true; break }
	}
	if scrolls && !focused { b.flags -= {.Scroll_Self}; return 0 }
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
// `track` and both bounds, a slider before them. T: int, f32 or f64. `lo`, `hi`: its bounds (nil: none on
// that side). Every way it moves clamps it to them and rounds it to `step` (0: an integer's 1; a float's as it comes).
// One step of the keys, the wheel and the buttons is `step` (0: 1, or a hundredth of a float's bounded range).
// The field shows the value (`format`: a printf format of T, "": its digits, a float's as many after the point as
// `step` has; text without a % is shown as it is). While the field has the keyboard, what is typed applies at Enter or
// when the keyboard goes elsewhere; Escape, or text that is no number, gives the value back. Up / Down step it, Page Up / Page Down ten steps; Shift ten
// times as much, Ctrl a hundred, Alt a tenth (num_step_delta). The wheel over the field or the slider steps it (Shift:
// ten); in a view that scrolls, once it has the keyboard (wheel_steps). The buttons step it (Shift: ten), held they
// repeat (repeat_pressed); at a bound its button is disabled. A screen reader sees a spin button (and the slider).
// `disabled`: shown faded, not changed. `tip`: the field's tooltip. Its size: `next` (the slider takes the room the rest
// leaves; without one, as wide as what is in it). True when the value changed this frame.
//
//   ui.number("###width", &app.width, lo = 1, hi = 40, unit = "px", track = true)
//   ui.number("###count", &app.count, lo = 0)
number :: proc{number_int, number_f32, number_f64}

number_int :: proc(id: string, value: ^int, lo: Maybe(int) = nil, hi: Maybe(int) = nil, step := 0, format := "", unit := "", track := false, disabled := false, tip := "") -> bool {
	return number_of(id, value, lo, hi, step, format, unit, track, disabled, tip)
}
number_f32 :: proc(id: string, value: ^f32, lo: Maybe(f32) = nil, hi: Maybe(f32) = nil, step: f32 = 0, format := "", unit := "", track := false, disabled := false, tip := "") -> bool {
	return number_of(id, value, lo, hi, step, format, unit, track, disabled, tip)
}
number_f64 :: proc(id: string, value: ^f64, lo: Maybe(f64) = nil, hi: Maybe(f64) = nil, step: f64 = 0, format := "", unit := "", track := false, disabled := false, tip := "") -> bool {
	return number_of(id, value, lo, hi, step, format, unit, track, disabled, tip)
}

// (one body for every type: an Odin default of a parameter of a polymorphic type cannot be had, so the group above gives them)
@(private = "file")
number_of :: proc(id: string, value: ^$T, lo, hi: Maybe(T), step: T, format, unit: string, slider, disabled: bool, tip: string) -> (changed: bool) where intrinsics.type_is_integer(T) || intrinsics.type_is_float(T) {
	s := gs()
	em := font_size()
	low, has_lo := lo.?
	high, has_hi := hi.?
	track := slider && has_lo && has_hi && high > low
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
			number_parse(value, field_string(f), lo, hi, step)
			s.number_key = 0
		}
		came := false
		if typing && s.number_key != fkey {
			// the keyboard came: the field holds the value, all of it selected to be typed over (another number's text not
			// applied yet is first applied by its own build, unless it is gone)
			other := s.boxes[s.number_key] or_else nil
			if s.number_key == 0 || other == nil || other.last_build + 1 < s.build_index {
				field_set(f, number_text(value^, format, step))
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
			slider_widget("###slider", &v, f32(low), f32(high), slider_step, "")
			if v != f32(value^) { number_set(value, f64(v), lo, hi, step); moved = true }
			spacer(px(math.round(em * 0.4)))
		}
		side := math.round(em * 1.6)
		for dir in ([2]f64{-1, 1}) {
			if dir > 0 {
				text := number_text(value^, format, step)
				st := top_style()
				widest := text_width(st.font, st.font_size, text)
				if has_lo { widest = max(widest, text_width(st.font, st.font_size, number_text(low, format, step))) }
				if has_hi { widest = max(widest, text_width(st.font, st.font_size, number_text(high, format, step))) }
				info := A11y_Info{role = .Spin_Button, numeric = f64(value^), step = k, value = unit != "" ? fmt.tprintf("%s %s", text, unit) : text, description = tip}
				if has_lo { info.min = f64(low) }
				if has_hi { info.max = f64(high) }
				if editing && !keys_held_by_dialog(s) {
					// (the step keys move the value from what is typed, when it is a number)
					for e, i in s.events.list {
						if s.events.consumed[i] || e.mods - {.Ctrl, .Shift, .Alt} != {} { continue }
						d := num_step_delta(e.key, e.mods) or_continue
						s.events.consumed[i] = true
						base := f64(value^)
						if v, ok := strconv.parse_f64(strings.trim_space(field_string(f))); ok { base = v }
						number_set(value, base + d * k, lo, hi, step)
						moved = true
					}
				}
				if v, ok := a11y_numeric_request(fkey, f32(value^), f32(k)); ok && !disabled { number_set(value, f64(v), lo, hi, step); moved = true }
				next({width = px(math.ceil(max(em * NUMBER_FIELD_MIN_EM, widest + 2 * st.text_pad + em * 0.4))), height = pct(1)})
				a11y(info)
				fsig: Signal
				if editing {
					res := line_edit("###value", f, "", menu = false)
					// (after the field's first build: the press that gave it the keyboard placed its caret there)
					if came { field_select_all(f) }
					fsig = res.signal
					if res.committed { number_parse(value, field_string(f), lo, hi, step); moved = true }
					if res.cancelled { s.number_key = 0 }   // (and the keyboard goes: the value stays)
				} else {
					// (the field while nobody types in it: the value, as the field shows its text; the key is the field's, so
					// a press gives it the keyboard and the next build types in it)
					push_tags("input")
					fb := build_box({.Clickable, .Focusable, .Text_Input, .Clip, .Draw_Background, .Draw_Border, .Draw_Focus_Ring, .Sunken, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###value", text_shown(text)))
					pop_tags()
					fb.cursor = .Text
					fsig = signal(fb)
				}
				// (the wheel over the field moves the value as over the slider: it is one line, nothing in it scrolls)
				if n := wheel_steps(fsig.box, typing); n != 0 && !disabled {
					number_set(value, f64(value^) + f64(n) * k * f64(shift_steps(s.mods)), lo, hi, step)
					moved = true
				}
				button_tip(fsig, tip)
			}
			at_end := dir < 0 ? has_lo && value^ <= low : has_hi && value^ >= high
			next({width = px(side), height = px(side), font_size = math.round(em * 0.9)})
			sig: Signal
			// (one Tab stop, the field: the buttons are the pointer's)
			if tab_stops(false) { sig = icon_button(dir < 0 ? "dec" : "inc", dir < 0 ? ICON_MINUS : ICON_ADD, icon_font = widget_icons(), disabled = at_end || disabled) }
			if repeat_pressed(sig) {
				number_set(value, f64(value^) + dir * k * f64(shift_steps(sig.mods)), lo, hi, step)
				moved = true
			}
		}
		if editing && moved && s.number_key == fkey {
			field_set(f, number_text(value^, format, step))
			field_select_all(f)
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

// (`number` has a parameter of this name)

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
number_parse :: proc(value: ^$T, text: string, lo, hi: Maybe(T), step: T) {
	if v, ok := strconv.parse_f64(strings.trim_space(text)); ok { number_set(value, v, lo, hi, step) }
}

// The text of a number: `format` (a printf format of T; without a %, as it is), else its digits: a float's, as many after
// the point as its `step` has (step 0: as many as it needs).
@(private = "file")
number_text :: proc(v: $T, format: string, step: T) -> string {
	if format != "" { return strings.index_byte(format, '%') >= 0 ? fmt.tprintf(format, v) : format }
	when intrinsics.type_is_float(T) {
		if step <= 0 { return fmt.tprintf("%v", v) }
		decimals := 0
		x := f64(step)
		for decimals < NUMBER_DECIMALS_MAX && abs(x - math.round(x)) > 1e-6 * max(1, abs(x)) {
			x *= 10
			decimals += 1
		}
		return fmt.tprintf(fmt.tprintf("%%.%df", decimals), v)
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
// end.
range_slider :: proc(id: string, lo_v, hi_v: ^f32, lo, hi: f32, step: f32 = 0, format := "%.0f") -> (sig: Signal) {
	s := gs()
	em := font_size()
	b := build_box({.Clickable}, id)
	b.cursor = .Hand
	sig = signal(b)
	room := format != ""
	k := step > 0 ? step : (hi - lo) / SLIDER_FINE_DIVISIONS
	thumbs := [2]Key{key_from_string(b.key, "###lo"), key_from_string(b.key, "###hi")}
	values := [2]^f32{lo_v, hi_v}
	active := -1
	for t, i in thumbs { if s.focus_key == t { active = i } }
	set :: proc(which: int, v: f32, lo_v, hi_v: ^f32, lo, hi, step: f32) {
		v := v
		if step > 0 { v = math.round(v / step) * step }
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
	if n := wheel_steps(b, active >= 0); n != 0 {
		which := active
		if which < 0 {
			p := slider_pct(b, room)
			which = abs(p - (lo_v^ - lo) / (hi - lo)) <= abs(p - (hi_v^ - lo) / (hi - lo)) ? 0 : 1
		}
		set(which, values[which]^ + n * k * shift_steps(s.mods), lo_v, hi_v, lo, hi, step)
	}
	text_of :: proc(format: string, v: f32) -> string {
		return strings.index_byte(format, '%') >= 0 ? fmt.aprintf(format, v, allocator = frame_allocator()) : format
	}
	// the thumbs: boxes over the knobs, where the keyboard's focus is (laid out from the last frame's track)
	x0, x1 := slider_geom(b.rect, em, room)
	kr := em * SLIDER_KNOB_EM
	cy := (b.rect.max.y - b.rect.min.y) * 0.5
	if parent(b) {
		for i in 0 ..< 2 {
			v := values[i]
			if s.focus_key == thumbs[i] {
				w := v^
				// (as slider's keys: Shift multiplies a move by Feel.step_shift, a page is Feel.step_page steps)
				by := k * shift_steps(s.mods)
				page := f32(s.feel.step_page)
				if key_press(.Left, s.mods) || key_press(.Down, s.mods) { w -= by }
				if key_press(.Right, s.mods) || key_press(.Up, s.mods) { w += by }
				if key_press(.Page_Down, s.mods) { w -= page * by }
				if key_press(.Page_Up, s.mods) { w += page * by }
				if key_press(.Home) { w = i == 0 ? lo : lo_v^ }
				if key_press(.End) { w = i == 0 ? hi_v^ : hi }
				if w != v^ { set(i, w, lo_v, hi_v, lo, hi, step) }
			}
			if r, ok := a11y_numeric_request(thumbs[i], v^, k); ok { set(i, r, lo_v, hi_v, lo, hi, step) }
			t := clamp((v^ - lo) / (hi - lo), 0, 1)
			kx := math.lerp(x0, x1, t) - b.rect.min.x
			next({fixed_x = kx - kr, fixed_y = cy - kr, width = px(2 * kr), height = px(2 * kr), radius = kr})
			thumb := build_box({.Focusable}, i == 0 ? "###lo" : "###hi")
			info := A11y_Info{role = .Slider, numeric = f64(v^), min = f64(i == 0 ? lo : lo_v^), max = f64(i == 0 ? hi_v^ : hi), orientation = .X}
			if step > 0 { info.step = f64(step) }
			if room { info.value = text_of(format, v^) }
			a11y_default(thumb, info)
		}
	}
	d := frame_new(Slider_Draw)
	d.range = true
	t0, t1 := clamp((lo_v^ - lo) / (hi - lo), 0, 1), clamp((hi_v^ - lo) / (hi - lo), 0, 1)
	d.t0 = anim(key_from_string(b.key, "t0"), t0, SLIDER_RATE, t0)
	d.t1 = anim(key_from_string(b.key, "t1"), t1, SLIDER_RATE, t1)
	d.hot, d.active = b.hot_t, b.active_t
	d.track, d.accent, d.text = off_track(), color("accent"), color("text")
	if room { d.value_text = fmt.aprintf("%s-%s", text_of(format, lo_v^), text_of(format, hi_v^), allocator = frame_allocator()) }
	d.mono = mono_font()
	d.no_text = !room
	b.custom, b.custom_user = slider_draw, d
	a11y_default(b, {role = .Group, value = d.value_text})
	return
}

////////////////////////////////
// Repeat, segmented control, chips, rating

// A button that repeats while it is held (a number's − and +): true at the press, then again every
// Feel.repeat_interval_ms after Feel.repeat_delay_ms while the pointer stays on it (off the button it waits). It wakes
// the loop at the next repeat, not at every refresh while the button is held. A scroll bar's arrow repeats by the same rule.
repeat_pressed :: proc(sig: Signal) -> bool { return repeat_fires(gs(), sig.box.key, sig.pressed, sig.dragging, sig.hovering) }

// The rule of repeat_pressed for any held thing named by `key`: `pressed` this frame, `held` since, `on` it (the pointer
// is over it). Its timer is the State's (s.timers): a held thing that is not a widget (a scroll bar's arrow) has one too.
@(private)
repeat_fires :: proc(s: ^State, key: Key, pressed, held, on: bool) -> bool {
	fire := false
	if pressed {
		fire = true
		s.timers[key] = Timer{next_ms = s.time_ms + f64(s.feel.repeat_delay_ms), last_build = s.build_index}
	} else if held {
		if t, ok := s.timers[key]; ok {
			t.last_build = s.build_index
			if on && s.time_ms >= t.next_ms { fire = true; t.next_ms = s.time_ms + f64(s.feel.repeat_interval_ms) }
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

Seg_Draw :: struct { t: f32, n: int, accent, face, well: Color, pad, radius: f32 }

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
			if f32(i) > d.t - 0.5 && f32(i) < d.t + 1.5 { continue }
			gx := math.round(r.min.x + pad + f32(i) * iw)
			gh := math.round(h * SEG_GROOVE_HEIGHT * 0.5)
			cy := math.round((r.min.y + r.max.y) * 0.5)
			machined_groove(dc, {gx, cy - gh}, {gx, cy + gh}, vertical = true)
		}
		x := math.round(r.min.x + pad + d.t * iw)
		key := Rect{{x, r.min.y + pad}, {math.round(x + iw), r.max.y - pad}}
		// (a radius of its own, near the slot's curve: at 0 its lit rim and its edge met in a notch at the corners)
		key_radius := math.round(max(d.radius - pad * 0.5, SEG_KEY_RADIUS_PX * scale()))
		machined_bevel(dc, key, key_radius, draw.mix(d.face, d.accent, SEG_KEY_ACCENT), 0, 0, glow = d.accent)
		return
	}
	iw := ((r.max.x - r.min.x) - 2 * d.pad) / f32(d.n)
	x := r.min.x + d.pad + d.t * iw
	pill := Rect{{x, r.min.y + d.pad}, {x + iw, r.max.y - d.pad}}
	paint_rect(dc, pill, d.accent, rad(max(0, b.radius - d.pad * 0.5)))
}

// How a segmented control looks: a sliding pill in a track, or words in a line, the chosen one bold and underlined,
// `separator` between them ("All / Active 2 / Done 1").
Segmented_Look :: enum u8 { Pills, Text }

// Sliding-pill segmented control. Returns true when the selection changed. `tips`: a tooltip per segment, shown when the
// pointer rests on it ("" or a missing entry: none); a screen reader reads it as the segment's description. `look`
// .Text: words in a line, as wide as they are (`separator` between them).
segmented :: proc(id: string, labels: []string, selected: ^int, tips: []string = nil, look := Segmented_Look.Pills, separator := "/") -> (changed: bool) {
	if look == .Text { return segmented_text(id, labels, selected, tips, separator) }
	em := font_size()
	t := anim(key_from_string(parent_box().key, fmt.tprintf("%s_t", id)), f32(selected^), SEGMENTED_RATE, f32(selected^))
	accent := color("accent")
	mach := machined()
	text_on, text_off: Color
	// (machined: the chosen label on a metal key, in the text's colour; flat: on the accent)
	if mach { text_on = color("text") } else if tags(intent_tag(.Primary)) { text_on = color("text") }
	if tags("weak") { text_off = color("text") }
	if tags("button") {
		set_next_axis(.X)
		// (machined: the box draws nothing of its own, seg_draw carves the slot)
		b := build_box(mach ? {} : {.Draw_Background, .Draw_Border, .Sunken}, id)
		d := frame_new(Seg_Draw)
		d.t, d.n, d.accent, d.pad = t, len(labels), accent, math.round(em * 0.25)   // (whole pixels: the key and the labels share it)
		d.face, d.well = color("background"), color("well")
		d.radius = max(b.radius, rad(em * 0.4))
		b.custom, b.custom_user = seg_draw, d
		a11y_default(b, {role = .Radio_Group, orientation = .X})
		if parent(b) {
			// (the labels on the width the key slides on: the track less its padding on each side, as seg_draw divides
			// it; on the whole width each label sat further right of its key than the one before)
			spacer(px(d.pad))
			next({width = fill(), height = pct(1), axis = .X})
			inner := build_box({}, "###seg_inner")
			push_parent(inner)
			defer { pop_parent(); spacer(px(d.pad)) }
			for label, i in labels {
				fg := i == selected^ ? text_on : text_off
				next({width = pct(1 / f32(len(labels))), height = pct(1), text_align = .Center, fg = fg, radius = max(0, b.radius - em * 0.125)})
				push_tags("segment")
				item := build_box({.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects}, fmt.tprintf("%s###seg%d", label, i))
				pop_tags()
				isig := signal(item)
				if isig.clicked && i != selected^ { selected^ = i; changed = true }
				tip := i < len(tips) ? tips[i] : ""
				if tip != "" && hovered_for(isig) { if tooltip() { tooltip_text(tip) } }
				a11y_default(item, {role = .Radio_Button, toggled = i == selected^ ? .True : .False, position = i + 1, set_size = len(labels), description = tip})
			}
			// (the item clicked this frame is the selected one: the earlier items said otherwise)
			if changed { for c := inner.first; c != nil; c = c.next { if c.a11y != nil && c.a11y.position > 0 { c.a11y.toggled = c.a11y.position == selected^ + 1 ? .True : .False } } }
		}
	}
	return
}

// (on each side of a separator)
@(private = "file") SEGMENTED_TEXT_GAP_EM :: 0.45

@(private = "file")
segmented_text :: proc(id: string, labels: []string, selected: ^int, tips: []string, separator: string) -> (changed: bool) {
	s := gs()
	em := font_size()
	set_next_axis(.X, .Center)
	if !s.has_next || s.next_mod.width == nil { s.next_mod.width = children_sum(); s.has_next = true }
	b := build_box({}, id)
	a11y_default(b, {role = .Radio_Group, orientation = .X})
	if parent(b) {
		st := top_style()
		bold := styled_face(st.font, true, false)
		for label, i in labels {
			if i > 0 {
				spacer(px(math.round(em * SEGMENTED_TEXT_GAP_EM)))
				if tags("weak") {
					next({width = text_size(0, 0), height = pct(1), text_pad = 0})
					sep := build_box({.Draw_Text}, fmt.tprintf("%s###sep%d", separator, i))
					a11y_default(sep, {ignore = true})
				}
				spacer(px(math.round(em * SEGMENTED_TEXT_GAP_EM)))
			}
			on := i == selected^
			if !on { push_tags("weak") }   // (the chosen one in the text's own colour)
			next({width = text_size(0, 0), height = pct(1), text_pad = 0, font = on ? bold : st.font, cursor = .Hand})
			item := build_box({.Clickable, .Focusable, .Draw_Text}, fmt.tprintf("%s###seg%d", label, i))
			if !on { pop_tags() }
			isig := signal(item)
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

// Toggle chips: bit i of `mask` is chip i. They wrap onto more lines when there is not enough room.
chips :: proc(id: string, labels: []string, mask: ^u32) {
	em := font_size()
	next({width = fill(), height = children_sum()})
	if flow({em * 0.45, em * 0.45}) {
		for label, i in labels {
			on := mask^ & (1 << u32(i)) != 0
			push_button_tags(on ? .Primary : .Neutral, .Raised)
			next({width = text_size(em * 0.5, 0.6), height = px(dense(em * 1.9)), radius = em * 0.95, text_align = .Center})
			b := build_box({.Clickable, .Focusable, .Draw_Text, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, fmt.tprintf("%s###%s_%d", label, id, i))
			pop_tags()
			if signal(b).clicked { mask^ ~= (1 << u32(i)) }
			a11y_default(b, {role = .Button, toggled = mask^ & (1 << u32(i)) != 0 ? .True : .False})
		}
	}
}

@(private = "file") RATING_MAX :: 5
@(private = "file") RATING_GROW_RATE :: 40
@(private = "file") RATING_GROW_SCALE :: 0.35

// Five icons; click the current value again to clear it.
rating :: proc(id: string, value: ^int) {
	em := font_size()
	set_next_axis(.X)
	box := build_box({}, id)
	if v, ok := a11y_numeric_request(box.key, f32(value^), 1); ok { value^ = clamp(int(math.round(v)), 0, RATING_MAX) }
	defer a11y_default(box, {role = .Slider, numeric = f64(value^), min = 0, max = RATING_MAX, step = 1, value = fmt.aprintf("%d / %d", value^, RATING_MAX, allocator = frame_allocator())})
	if parent(box) {
		for i in 0 ..< RATING_MAX {
			cell_id := fmt.tprintf("%s_%d", id, i)
			prev := box_from_key(key_from_string(box.key, cell_id))
			grow := anim(key_from_string(box.key, fmt.tprintf("%s_g", cell_id)), prev != nil ? prev.hot_t : 0, RATING_GROW_RATE)
			lit := i < value^
			if !lit { push_tags("weak") }
			next({width = px(em * 2), height = pct(1), font = widget_icons(), font_size = em * (1 + RATING_GROW_SCALE * grow), text_align = .Center})
			b := build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###%s", lit ? ICON_RADIO_ON : ICON_RADIO, cell_id))
			if !lit { pop_tags() }
			if signal(b).clicked { value^ = value^ == i + 1 ? 0 : i + 1 }
		}
	}
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

// Determinate (t in 0..1) or indeterminate bar. Size from the style stack or `next`.
progress :: proc(id: string, t: f32, indeterminate := false) {
	s := gs()
	b := build_box({}, id)
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
			value = fmt.aprintf("%.0f %%", clamp(t, 0, 1) * 100, allocator = frame_allocator())})
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
	radius := size * 0.5 - th * 0.5
	steps := max(int(radius * math.TAU * SPINNER_ARC / max(th * 0.35, 0.5)), 12)
	start := d.phase * math.TAU
	for k in 0 ..= steps {
		a := start + f32(k) / f32(steps) * math.TAU * SPINNER_ARC
		p := c + Vec2{math.cos(a), math.sin(a)} * radius
		draw.rect(dc, {p - th * 0.5, p + th * 0.5}, d.color, th * 0.5)
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

// A filled disc `size` across (0: half the font size), of the hue of `intent` (a recording, a state): the icon fonts
// have no filled circle. Its colour says nothing to a screen reader: give it a name with `a11y` when it means something.
dot :: proc(id: string, size: f32 = 0, intent := Intent.Primary) {
	side := size > 0 ? size : math.round(font_size() * 0.5)
	c := hue_color(intent_hue(intent))
	c.a = 1
	next_default({width = px(side), height = px(side)})
	b := build_box({}, id)
	d := frame_new(Color)
	d^ = c
	b.custom, b.custom_user = dot_draw, d
	if b.a11y == nil { a11y_default(b, {ignore = true}) }
}

// (a circle, not the rounded square of a box's corners)
@(private = "file")
dot_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	r := b.rect
	w := min(r.max.x - r.min.x, r.max.y - r.min.y)
	c := draw.rect_center(r)
	prev := draw.set_circular_corners(dc, true)
	draw.rect(dc, {c - w * 0.5, c + w * 0.5}, (^Color)(user)^, w * 0.5)
	draw.set_circular_corners(dc, prev)
}

////////////////////////////////
// Dropdown and tabs

@(private = "file") DROPDOWN_MENU_KEY_SALT :: 0xd0d0

// Button showing the current item; opens a menu of `items`. Returns true when the selection changed.
dropdown :: proc(id: string, items: []string, selected: ^int) -> (changed: bool) {
	em := font_size()
	menu_key := key_from_u64(key_from_string(parent_box().key, id), DROPDOWN_MENU_KEY_SALT)
	open := ctx_menu_is_open(menu_key)
	btn: ^Box
	sig: Signal
	if tags("button") {
		set_next_axis(.X, .Center)
		btn = build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, id)
		sig = signal(btn)
		cur := selected^ >= 0 && selected^ < len(items) ? items[selected^] : ""   // none chosen, or the list changed
		a11y_default(btn, {role = .Combo_Box, value = display_part(cur), expanded = open, popup = .Listbox, read_only = true})
		if parent(btn) {
			spacer(px(em * 0.8))
			next({width = fill(), height = pct(1)})
			build_box({.Draw_Text}, fmt.tprintf("%s###cur", cur))
			if tags("weak") { widget_icon(open ? ICON_UP : ICON_DOWN, em * 1.8) }
		}
	}
	// Down / Alt+Down on the focused button opens the list from the keyboard too
	kb := sig.focused && !open && (key_press(.Down, {.Alt}) || key_press(.Down) || key_press(.F4))
	if sig.clicked || kb {
		if open { ctx_menu_close() } else {
			ctx_menu_open_rect(menu_key, btn.rect, btn.key, from_keyboard = kb)
			menu_select(selected^)   // keyboard starts from the current value
		}
	}
	if ctx_menu(menu_key, max(btn.size.x, em * MENU_MIN_WIDTH_EM)) {
		for item, i in items {
			if menu_item(item, "", i == selected^).clicked { selected^ = i; changed = true }
		}
	}
	return
}

@(private = "file") TAB_RATE :: 34
@(private = "file") TAB_UNDERLINE_MIN_T :: 0.01
@(private = "file") TAB_UNDERLINE_PX :: 3
@(private = "file") TAB_UNDERLINE_RADIUS_PX :: 1.5

Tab_Draw :: struct { t: f32, accent: Color }

@(private)
tab_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tab_Draw)(user)
	if d.t < TAB_UNDERLINE_MIN_T { return }
	r := b.rect
	w := (r.max.x - r.min.x) * d.t
	cx := (r.min.x + r.max.x) * 0.5
	draw.rect(dc, {{cx - w * 0.5, r.max.y - math.round(TAB_UNDERLINE_PX * scale())}, {cx + w * 0.5, r.max.y}}, d.accent, TAB_UNDERLINE_RADIUS_PX * scale())
}

// Row of tabs with a growing underline. `icons` may be nil. Returns true when the selection changed.
// `right_clicked` / `middle_clicked` (optional) receive the index of a tab clicked with that button this frame (else -1).
tabs :: proc(id: string, labels: []string, icons: []string, selected: ^int, right_clicked: ^int = nil, middle_clicked: ^int = nil) -> (changed: bool) {
	s := gs()
	if right_clicked != nil { right_clicked^ = -1 }
	if middle_clicked != nil { middle_clicked^ = -1 }
	em := font_size()
	a11y_default(parent_box(), {role = .Tab_List, orientation = .X})
	first_tab: ^Box
	for label, i in labels {
		on := selected^ == i
		tab_id := fmt.tprintf("%s_%d", id, i)
		key := key_from_string(parent_box().key, tab_id)
		t := anim(key_from_string(key, "t"), on ? 1 : 0, TAB_RATE)
		if !on { push_tags("weak") }
		set_next_axis(.X, .Center)
		s.next_mod.width = children_sum()
		s.next_mod.height = pct(1)
		push_tags("tab")
		b := build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, tab_id)
		pop_tags()
		d := frame_new(Tab_Draw)
		d.t, d.accent = t, color("accent")
		b.custom, b.custom_user = tab_draw, d
		if parent(b) {
			spacer(px(em))
			if i < len(icons) { icon(icons[i], em * 1.6) }
			next({width = text_size(), height = pct(1)})
			build_box({.Draw_Text}, label)
			spacer(px(em))
		}
		if !on { pop_tags() }
		sig := signal(b)
		if sig.clicked && !on { selected^ = i; changed = true }
		if sig.right_clicked && right_clicked != nil { right_clicked^ = i }
		if sig.middle_clicked && middle_clicked != nil { middle_clicked^ = i }
		a11y_default(b, {role = .Tab, selected = on, position = i + 1, set_size = len(labels)})
		if first_tab == nil { first_tab = b }
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

// `if card("Title", ICON) { ... }`: a titled panel, full width, height from its content. Tags used: "card".
@(deferred_none = card_end)
card :: proc(title: string, icon_glyph: string = "") -> bool {
	em := font_size()
	push_tags("card")
	set_next_axis(.Y)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	gs().next_mod.radius = em * 0.6
	c := build_box({.Draw_Background, .Draw_Border, .Plate}, fmt.tprintf("###card_%s", title))
	a11y_default(c, {role = .Group, name = title})
	push_parent(c)
	spacer(px(em * 0.9))
	set_next_axis(.X)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	push_parent(build_box({}, "###card_pad"))
	spacer(px(em * 1.1))
	set_next_axis(.Y)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	push_parent(build_box({}, "###card_body"))
	if title != "" {
		next({width = fill(), height = px(dense(em * 2.2))})
		if row(.Center) {
			if icon_glyph != "" { if tags("weak") { icon(icon_glyph, em * 1.8) } }
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
	em := font_size()
	pop_parent()   // body
	spacer(px(em * 1.1))
	pop_parent()   // padded row
	spacer(px(em * 0.9))
	pop_parent()   // card
	pop_tags()
	spacer(px(em))
}

// `if form_row("Name") { widget }`: label on the left (34 %), the widget fills the rest. Widgets inside default to
// full width and 2.3 em height.
@(deferred_none = form_row_end)
form_row :: proc(label_text: string) -> bool {
	em := font_size()
	// as tall as its widget (at least one line): wrapped content such as chips grows the row
	set_next_axis(.X, .Center)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	r := build_box({}, fmt.tprintf("###frow_%s", label_text))
	push_parent(r)
	if tags("weak") {
		next({width = pct(0.34), height = px(dense(em * 2.5))})
		build_box({.Draw_Text}, fmt.tprintf("%s###lbl", label_text))
	}
	push_style_copy()
	top_style().pref = {.X = fill(), .Y = px(dense(em * 2.3))}
	return true
}

@(private)
form_row_end :: proc() {
	pop(&gs().style_stack)
	// the row's label names its widget (the first box after it) unless the app named it
	r := parent_box()
	if lbl := r.first; lbl != nil && lbl.next != nil {
		w := lbl.next
		if w.a11y == nil || (w.a11y.name == "" && w.a11y.labelled_by == 0) { a11y_set(w, {labelled_by = lbl.key}) }
	}
	pop_parent()
}


// A labelled button: a glyph of an icon font ("" none) and its words. `intent`: what the act means, and so its colour
// (its soft pair: a tinted fill, its words of the same hue). `face`: how it sits (a ghost has no face until the pointer
// is over it; an intent then colours its words; Toggled: held down, the option chosen). `width`: {} as wide as what is
// in it; fill() a share of the row, as flex: 1 (two buttons side by side, or one across the whole width), px(...) a width
// of its own: what is in it stays centred, or at its left with `left`. `height`: of one line, in pixels (0: the
// toolkit's). `icon_font`: the glyph's font (0: State.icon_font; lucide_icons() for Lucide's); `icon_color`: the glyph's
// own colour (a state it says; the words stay the button's). `hue`: filled with one of the theme's hues (hue()), its
// words in it: a colour by meaning that every theme has; prefer `intent` when the act has one. Both are soft unless
// `solid`: the hue itself, its words dark or light, whichever reads (ink_on). `quiet`: a secondary act, smaller; a
// Neutral one's words are weak until the pointer is over it. `lit`: drawn as under the pointer (while its menu is open).
// `wrap`: words longer than the button's width go on more lines and the button grows to hold them (with a `width`; none:
// fill()). `tip`: a tooltip when the pointer rests on it. Drawn by the theme's finish (bevelled in the machined one).
button_icon :: proc(id: string, glyph, text: string, intent := Intent.Neutral, face := Button_Face.Raised, disabled := false,
	width: Size = {}, height: f32 = 0, icon_font: font.Font_Id = 0, icon_color: Maybe(Color) = nil, hue: Maybe(Hue) = nil,
	solid := false, quiet := false, lit := false, wrap := false, left := false, tip := "") -> (sig: Signal) {
	s := gs()
	em := font_size()
	// a disabled scope, so the label and icon inside go neutral too
	push_disabled(disabled)
	defer pop_disabled()
	// (soft, an intent is its theme's button; solid, its hue as any hue)
	h := hue
	if solid && intent != .Neutral && h == nil { h = intent_hue(intent) }
	push_button_tags(solid ? .Neutral : intent, face)
	defer pop_tags()
	w := width
	if wrap && w == {} { w = fill() }
	set_next_axis(.X, .Center)
	s.next_mod.width = w == {} ? children_sum() : w
	line := height > 0 ? height : dense(em * 2.2)
	s.next_mod.height = wrap ? children_sum() : px(line)
	if s.next_mod.radius == nil { s.next_mod.radius = em * 0.45 }
	ink: Maybe(Color)
	if hh, tinted := h.?; tinted {
		base := hue_color(hh)
		base.a = 1
		fill_c, words := soft_pair(base)
		if solid { fill_c, words = base, ink_on(base) }
		s.next_mod.bg, s.next_mod.border = fill_c, fill_c
		ink = words
	} else if face == .Ghost {
		ink = button_ink(intent)
	}
	flags := Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}
	if face == .Toggled { flags += {.Held} }
	if lit { flags += {.Lit} }
	b := build_box(flags, id)
	b.squish = press_squish(b)
	sig = signal(b)
	button_a11y(b, face, text == "" ? tip : "", tip)
	button_tip(sig, tip)
	// (a secondary act's words: weak until the pointer is over it, unless they say an intent)
	weak := quiet && intent == .Neutral && h == nil && !sig.hovering && !lit
	fs := quiet ? math.round(em * BUTTON_QUIET_SCALE) : em
	if parent(b) {
		if weak { push_tags("weak") }
		defer if weak { pop_tags() }
		pad := text != "" ? em * 0.95 : em * 0.55
		centred := w != {} && !left
		spacer(px(pad))
		if centred && !wrap { spacer(fill()) }   // (wider than what is in it: that stays in the middle)
		if glyph != "" {
			face_font := icon_font != 0 ? icon_font : s.icon_font
			next({width = px(em * 1.5), height = pct(1), font = face_font, text_align = .Center, fg = icon_color != nil ? icon_color : ink})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", glyph))
		}
		label: ^Box
		if text != "" && wrap {
			// (between margins that make one line `line` tall)
			st := top_style()
			lh := math.ceil(font.metrics(s.fonts, st.font, fs).line_height)
			margin := max(math.round((line - lh) * 0.5), 0)
			next({width = fill(), height = children_sum(), axis = .Y})
			if column() {
				spacer(px(margin), exact = true)
				next({width = fill(), fg = ink, font_size = fs})
				paragraph(text)
				spacer(px(margin), exact = true)
			}
		} else if text != "" {
			next({width = text_size(), height = pct(1), fg = ink, font_size = fs})
			label = build_box({.Draw_Text}, text)
		}
		if centred && !wrap { spacer(fill()) }
		spacer(px(pad))
		// (a share of the row is never narrower than what is in it, its padding on both sides included: the label,
		// measured as the layout will (its text and text_pad), is never cut nor drawn against an edge)
		if w != {} && w.least == 0 && label != nil {
			b.pref[.X].least = math.ceil(2 * pad + (glyph != "" ? em * 1.5 : 0) + label.text_dim.x + 2 * label.text_pad)
		}
	}
	return
}

// A quiet button's words, of the font size.
@(private = "file") BUTTON_QUIET_SCALE :: 0.9

// `if well("###id") { ... }`: a sunken box, carved in the surface (code, a preview, a list of facts): the theme's well
// (its "well" colour; the machined finish carves it in, with a lit lower lip). Its size and corners from `next`; `axis`:
// how its children are laid out. Tags used: "well".
@(deferred_none = pop_parent)
well :: proc(id: string, axis := Axis.Y, flags: Box_Flags = {}) -> bool {
	set_next_axis(axis)
	push_tags("well")
	b := build_box({.Draw_Background, .Draw_Border, .Sunken} + flags, id)
	pop_tags()
	push_parent(b)
	return true
}

// A hint's words that say an act, away from the pointer: this much of their colour.
@(private = "file") HINT_ACTION_REST_ALPHA :: 0.75

// Words that say what can be done and do it, as a link does: weak like a hint, lit under the pointer. `icon`: a glyph of
// `icon_font` (0: State.icon_font) before them ("" none). `intent`: their colour (its soft pair's words, which read on
// the page), a little quieter away from the pointer. As wide as they are, unless `next` says otherwise.
hint_action :: proc(id, text: string, icon := "", icon_font: font.Font_Id = 0, intent := Intent.Neutral) -> Signal {
	s := gs()
	em := font_size()
	set_next_axis(.X, .Center)
	if s.next_mod.width == nil { s.next_mod.width = children_sum() }
	if s.next_mod.height == nil { s.next_mod.height = px(math.round(em * 1.4)) }
	if s.next_mod.cursor == nil { s.next_mod.cursor = .Hand }
	b := build_box({.Clickable, .Focusable}, id)
	sig := signal(b)
	a11y_default(b, {role = .Button, name = text})
	col := button_ink(intent)
	if c, ok := col.?; ok && !sig.hovering {
		c.a *= HINT_ACTION_REST_ALPHA
		col = c
	}
	weak := intent == .Neutral && !sig.hovering
	if parent(b) {
		if weak { push_tags("weak") }
		defer if weak { pop_tags() }
		if icon != "" {
			next({width = px(math.round(em * 1.2)), height = pct(1), font = icon_font != 0 ? icon_font : s.icon_font, text_align = .Center, text_pad = 0, fg = col})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", icon))
			spacer(px(math.round(em * 0.3)))
		}
		next({width = text_size(0), height = pct(1), text_pad = 0, fg = col})
		build_box({.Draw_Text}, fmt.tprintf("%s###t", text_shown(text)))
	}
	return sig
}

////////////////////////////////
// A strip that opens into a grid

// The fade at a side of a strip whose line is cut, where it hides cells (scroll_fades).
STRIP_FADE_EM :: 2.5

// `if strip_grid("###themes", &open, {gap, gap}) { cells... }`: its cells (each its own width) on one line that scrolls
// sideways; "Show all" under it lays them out as a grid, wrapped to the width, and "Show fewer" folds them back. The button
// is there only when the line does not hold them all (or when open). `open` is the program's to keep.
@(deferred_in = strip_grid_end)
strip_grid :: proc(id: string, open: ^bool, gap: Vec2 = {}, show_all := "Show all", show_fewer := "Show fewer") -> bool {
	next({width = fill(), height = children_sum(), axis = .Y})
	push_parent(build_box({}, id))
	if !open^ {
		// (a line as wide as its cells, in a view that scrolls it: the wheel, turned either way, and the bar under it. A
		// mouse's wheel turns only one way: over a line that is cut, it scrolls the line, not the page around it)
		key := key_from_string(parent_box().key, "###strip_view")
		last := box_from_key(key)
		cut := last != nil && last.first != nil && last.first.size.x > last.size.x + 0.5
		set_next_axis(.X)
		next({width = fill(), height = children_sum()})
		view := build_box(cut ? {.Clip, .View_Scroll_X, .View_Clamp_X, .Allow_Overflow_X, .Scroll_Self} : {.Clip, .View_Scroll_X, .View_Clamp_X, .Allow_Overflow_X}, "###strip_view")
		sig := signal(view)
		if cut && sig.scrolled.y != 0 && sig.scrolled.x == 0 {
			view.view_target.x = clamp(view.view_target.x + sig.scrolled.y * wheel_step(view, .X), 0, view_limit(view, .X))
		}
		// (a fade at a side that hides cells: the line goes on there)
		if cut { scroll_fades(view, .X, math.round(font_size() * STRIP_FADE_EM)) }
		push_parent(view)
		// (the cells, and under them the room of the bar when the line is cut: the bar is drawn under the cells, not over them)
		next({width = children_sum(), height = children_sum(), axis = .Y})
		push_parent(build_box({}, "###strip_column"))
	}
	// (the cells: a flow, wrapped to the width when open; as wide as they are on one line when folded. Built here, not with
	// `flow`, whose own end would close it at this procedure's end)
	next({width = open^ ? fill() : children_sum(), height = children_sum(), axis = .X, gap = gap})
	push_parent(build_box({.Wrap}, "###strip_cells"))
	return true
}

@(private)
strip_grid_end :: proc(id: string, open: ^bool, gap: Vec2, show_all, show_fewer: string) {
	pop_parent()   // the cells
	// what the last layout said: the line wider than its view
	outer := parent_box()
	if !open^ { outer = outer.parent.parent }   // (the column, then the view, are between)
	view := box_from_key(key_from_string(outer.key, "###strip_view"))
	cut := view != nil && view.first != nil && view.first.size.x > view.size.x + 0.5
	if !open^ {
		if cut { spacer(px(scrollbar_gutter())) }
		pop_parent()   // the column
		pop_parent()   // the view
	}
	if cut || open^ {
		em := font_size()
		spacer(px(em * 0.3))
		next({width = fill(), height = children_sum(), axis = .X})
		if row(id = "###strip_more") {
			spacer(fill())
			next({width = text_size(em * 0.6), height = px(dense(em * 1.8)), font_size = math.round(em * 0.9)})
			if button(fmt.tprintf("%s###strip_toggle", open^ ? show_fewer : show_all), face = .Ghost).clicked { open^ = !open^ }
		}
	}
	pop_parent()   // the strip
}

// (number_of's parameter `slider` hides the widget)
@(private = "file")
slider_widget :: proc(id: string, v: ^f32, lo, hi, step: f32, format: string) { slider(id, v, lo, hi, step, format) }
