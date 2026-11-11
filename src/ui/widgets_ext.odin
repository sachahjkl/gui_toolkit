package ui

// The widget set beyond the basics: toggles, sliders, steppers, segmented controls, chips, rating, progress,
// dropdowns, tabs, key caps, cards and form rows. Every widget takes a stable `id` string (see key.odin) and keeps its
// state in the caller's variables; hover/press/animation state lives in the box tree.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../draw"
import "../font"
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
		machined_well(dc, r, rad(h * 0.5), draw.mix(well, d.accent, d.t * TOGGLE_MACHINED_LIT))
		machined_bevel(dc, {{x, r.min.y + pad}, {x + kw, r.max.y - pad}}, rad(kd * 0.5), TOGGLE_MACHINED_KNOB, d.hot, d.active)
		return
	}
	paint_rect(dc, r, draw.mix(d.track, d.accent, d.t), rad(h * 0.5), d.t)
	sc := scale()
	draw.rect(dc, {{x - sc, r.min.y + pad + sc}, {x + kw + sc, r.max.y - pad + 2 * sc}}, {0, 0, 0, TOGGLE_KNOB_SHADOW_ALPHA}, rad(kd * 0.5), 0, TOGGLE_KNOB_SHADOW_SOFT_PX * sc)
	draw.rect(dc, {{x, r.min.y + pad}, {x + kw, r.max.y - pad}}, {1, 1, 1, 1}, rad(kd * 0.5))
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
		d.track = color("text")
		d.track.a = TOGGLE_TRACK_ALPHA
		d.track = tuned(d.track)
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
// Without a step, the arrow keys move a hundredth of the range. Page keys: this many arrow moves.
@(private = "file") SLIDER_FINE_DIVISIONS :: 100
@(private = "file") SLIDER_PAGE_STEPS :: 10
@(private = "file") RANGE_SLIDER_SAME_EPS :: 0.001       // thumbs this close: the side of the press picks one

Slider_Draw :: struct {
	t0, t1:     f32,
	range:      bool,
	hot, active: f32,
	track, accent, text: Color,
	value_text: string,
	mono:       font.Font_Id,
}

@(private)
slider_geom :: proc(r: Rect, em: f32) -> (x0, x1: f32) {
	pad := em * 0.75
	x0 = r.min.x + pad
	x1 = r.max.x - em * SLIDER_VALUE_ROOM_EM - pad
	if x1 < x0 + SLIDER_TRACK_MIN_PX * scale() { x1 = x0 + SLIDER_TRACK_MIN_PX * scale() }
	return
}

@(private)
slider_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Slider_Draw)(user)
	em := b.font_size
	r := b.rect
	x0, x1 := slider_geom(r, em)
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
		machined_well(dc, slot, rad(mth * 0.5), color_from_tags(gs(), b.tags_key, "well"))
		if fx1 - fx0 > 1 { paint_rect(dc, {{fx0, slot.min.y + sc}, {fx1, slot.max.y - sc}}, d.accent, rad(mth * 0.5)) }
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
slider_pct :: proc(b: ^Box) -> f32 {
	x0, x1 := slider_geom(b.rect, font_size())
	if x1 - x0 < 1 { return 0 }
	return clamp((gs().mouse.x - x0) / (x1 - x0), 0, 1)
}

// `format` is a printf format for the value text, e.g. "%.0f" or "%.1f C"; text without a % is shown as is
// (pick it per value for labels such as "Off"). step 0 = continuous.
// Keyboard (when focused): Left / Down and Right / Up step the value (`step`, or 1 % of the range), Home / End jump
// to the ends, Page Up / Page Down move by 10 steps.
slider :: proc(id: string, value: ^f32, lo, hi: f32, step: f32 = 0, format := "%.2f") -> (sig: Signal) {
	b := build_box({.Clickable, .Focusable}, id)
	b.cursor = .Hand
	sig = signal(b)
	if sig.focused {
		k := step > 0 ? step : (hi - lo) / SLIDER_FINE_DIVISIONS
		v := value^
		if key_press(.Left) || key_press(.Down) { v -= k }
		if key_press(.Right) || key_press(.Up) { v += k }
		if key_press(.Page_Down) { v -= SLIDER_PAGE_STEPS * k }
		if key_press(.Page_Up) { v += SLIDER_PAGE_STEPS * k }
		if key_press(.Home) { v = lo }
		if key_press(.End) { v = hi }
		if step > 0 { v = math.round(v / step) * step }
		value^ = clamp(v, lo, hi)
	}
	if sig.pointer_pressed || sig.dragging {
		v := lo + slider_pct(b) * (hi - lo)
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
	d.track, d.accent, d.text = color("track"), color("accent"), color("text")
	d.value_text = strings.index_byte(format, '%') >= 0 ? fmt.aprintf(format, value^, allocator = frame_allocator()) : format
	d.mono = mono_font()
	b.custom, b.custom_user = slider_draw, d
	a11y_default(b, {role = .Slider, numeric = f64(value^), min = f64(lo), max = f64(hi), step = step > 0 ? f64(step) : nil, value = d.value_text, orientation = .X})
	return
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

// Two thumbs on one track: the one closest to the pointer moves.
range_slider :: proc(id: string, lo_v, hi_v: ^f32, lo, hi: f32) -> (sig: Signal) {
	b := build_box({.Clickable}, id)
	b.cursor = .Hand
	sig = signal(b)
	press := press_data(Range_Press, b.key)
	if press != nil && !press.taken {
		p := slider_pct(b)
		pl, ph := (lo_v^ - lo) / (hi - lo), (hi_v^ - lo) / (hi - lo)
		press^ = {high = abs(p - pl) >= abs(p - ph), taken = true}
		if abs(pl - ph) < RANGE_SLIDER_SAME_EPS { press.high = p >= pl }
	}
	if sig.dragging && press != nil {
		v := lo + slider_pct(b) * (hi - lo)
		if !press.high { lo_v^ = clamp(v, lo, hi_v^) } else { hi_v^ = clamp(v, lo_v^, hi) }
	}
	d := frame_new(Slider_Draw)
	d.range = true
	t0, t1 := clamp((lo_v^ - lo) / (hi - lo), 0, 1), clamp((hi_v^ - lo) / (hi - lo), 0, 1)
	d.t0 = anim(key_from_string(b.key, "t0"), t0, SLIDER_RATE, t0)
	d.t1 = anim(key_from_string(b.key, "t1"), t1, SLIDER_RATE, t1)
	d.hot, d.active = b.hot_t, b.active_t
	d.track, d.accent, d.text = color("track"), color("accent"), color("text")
	d.value_text = fmt.aprintf("%.0f-%.0f", lo_v^, hi_v^, allocator = frame_allocator())
	d.mono = mono_font()
	b.custom, b.custom_user = slider_draw, d
	a11y_default(b, {role = .Slider, value = d.value_text, min = f64(lo), max = f64(hi), orientation = .X})
	return
}

////////////////////////////////
// Stepper, segmented control, chips, rating

@(private = "file") STEPPER_SHIFT_AMOUNT :: 10
@(private = "file") STEPPER_REPEAT_DELAY_MS :: 420
@(private = "file") STEPPER_REPEAT_MS :: 55

// [-] value [+]: hold a button to repeat, Shift = x10. Returns true when the value changed.
stepper :: proc(id: string, value: ^int, lo, hi: int) -> (changed: bool) {
	s := gs()
	em := font_size()
	set_next_axis(.X, .Center)
	row_box := build_box({}, id)
	if v, ok := a11y_numeric_request(row_box.key, f32(value^), 1); ok {
		old := value^
		value^ = clamp(int(math.round(v)), lo, hi)
		changed = value^ != old
	}
	a11y_default(row_box, {role = .Spin_Button, numeric = f64(value^), min = f64(lo), max = f64(hi), step = 1})
	if parent(row_box) {
		for dir in ([2]int{-1, 1}) {
			if dir == 1 {
				if style({font = mono_font(), text_align = .Center}) {
					next({width = px(em * 4.2), height = pct(1)})
					build_box({.Draw_Text}, fmt.tprintf("%d###val", value^))
				}
			}
			next({width = px(em * 2.2), height = px(em * 2.2), font = widget_icons()})
			sig := icon_button(dir < 0 ? "dec" : "inc", dir < 0 ? ICON_MINUS : ICON_ADD)
			amount := .Shift in sig.mods ? STEPPER_SHIFT_AMOUNT : 1
			key := sig.box.key
			old := value^
			if sig.pressed { value^ += dir * amount; timer_set(key, STEPPER_REPEAT_DELAY_MS) }
			else if sig.dragging && sig.hovering && timer_due(key) { value^ += dir * amount; timer_set(key, STEPPER_REPEAT_MS) }   // (off the button it waits, as a scroll bar's arrow does)
			if sig.dragging {
				// a wake at the next repeat, not a frame at every refresh while the button is held
				if t, ok := s.timers[key]; ok {
					left := max(1, int(t.next_ms - s.time_ms + WAKE_ROUND_UP_MS))
					wake_within(s, left)
				}
			}
			value^ = clamp(value^, lo, hi)
			if value^ != old { changed = true }
		}
	}
	return
}

@(private = "file") SEGMENTED_RATE :: 40
@(private = "file") SEGMENT_TOOLTIP_DELAY_S :: 0.5

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
	if mach { text_on = color("text") } else if tags("accent_button") { text_on = color("text") }
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
				if tip != "" && hovered_for(isig, SEGMENT_TOOLTIP_DELAY_S) { if tooltip() { tooltip_text(tip) } }
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
		bold := font.styled_face(s.fonts, st.font, true, false)
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
			if tip != "" && hovered_for(isig, SEGMENT_TOOLTIP_DELAY_S) { if tooltip() { tooltip_text(tip) } }
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
			push_tags(on ? "accent_button" : "button")
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


// Button with an icon-font glyph and a label. Push a kind tag first ("accent_button", "danger_button", "ghost_button").
button_icon :: proc(id: string, glyph, text: string, disabled := false) -> (sig: Signal) {
	s := gs()
	em := font_size()
	// a disabled scope, so the label and icon inside go neutral too
	push_disabled(disabled)
	defer pop_disabled()
	if tags("button") {
		set_next_axis(.X, .Center)
		s.next_mod.width = children_sum()
		s.next_mod.height = px(dense(em * 2.2))
		s.next_mod.radius = em * 0.45
		flags := Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}
		b := build_box(flags, id)
		b.squish = press_squish(b)
		sig = signal(b)
		a11y_default(b, {role = .Button})
		if parent(b) {
			spacer(px(em * 0.95))
			if glyph != "" { icon(glyph, em * 1.5) }
			next({width = text_size(), height = pct(1)})
			build_box({.Draw_Text}, text)
			spacer(px(em * 0.95))
		}
	}
	return
}
