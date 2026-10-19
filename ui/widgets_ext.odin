package ui

// The widget set beyond the basics: toggles, sliders, steppers, segmented controls, chips, rating, progress,
// dropdowns, tabs, key caps, cards and form rows. Every widget takes a stable `id` string (see key.odin) and keeps its
// state in the caller's variables; hover/press/animation state lives in the box tree.

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import "../font"

// The icon font (raddebugger's icons.ttf), compiled into every app that uses the toolkit: load it with
// `font.load_embedded(&fonts, ui.ICON_FONT_DATA)`.
ICON_FONT_DATA :: #load("icons.ttf")

// Characters of the icon font that the widgets use.
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

mono_font :: proc() -> font.Font_Id { return g.mono_font != 0 ? g.mono_font : top_style().font }

////////////////////////////////
// Small building blocks

// Fixed-width icon cell (icon font), full height of the parent.
icon :: proc(glyph: string, width: f32, fg: Maybe(Color) = nil) {
	next({width = px(width), height = pct(1), font = g.icon_font, text_align = .Center, fg = fg})
	build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico%d", glyph, parent_box().child_count))
}

hline :: proc(width: Size) {
	next({width = width, height = px(1), bg = color("border")})
	build_box({.Draw_Background}, "")
}

// Value stored at press time for the active drag (which thumb, column width at start, note position, ...).
drag_store :: proc(v: [4]f32) { g.drag_payload = v }
drag_load :: proc() -> [4]f32 { return g.drag_payload }

// Persistent timers (hold-to-repeat, delays). `timer_due` is true once `next_ms` has passed.
timer_set :: proc(key: Key, delay_ms: f64) { g.timers[key] = Timer{next_ms = g.time_ms + delay_ms, last_build = g.build_index} }
timer_due :: proc(key: Key) -> bool {
	t, ok := g.timers[key]
	if !ok { return false }
	t.last_build = g.build_index
	g.timers[key] = t
	return g.time_ms >= t.next_ms
}

// Last frame's box for an id under the current parent (its rect and size are valid, e.g. for scroll geometry).
prev_box :: proc(id: string) -> ^Box { return box_from_key(key_from_string(parent_box().key, id)) }

////////////////////////////////
// Check marks and radios

Mark_Draw :: struct { t: f32, accent, ring: Color, size: f32, radio: bool }

@(private)
mark_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Mark_Draw)(user)
	r := b.rect
	w := r.max.x - r.min.x
	if d.radio {
		draw.rect(dc, r, draw.mix(d.ring, d.accent, d.t), w * 0.5, 1.5)
		dot := w * 0.5 * d.t
		c := draw.rect_center(r)
		a := d.accent
		a.a *= d.t
		draw.rect(dc, {{c.x - dot * 0.5, c.y - dot * 0.5}, {c.x + dot * 0.5, c.y + dot * 0.5}}, a, dot * 0.5)
		return
	}
	inset := (1 - d.t) * w * 0.5
	fill := d.accent
	fill.a *= min(1, d.t * 1.6)
	paint_rect(dc, draw.rect_pad(r, -inset), fill, rad(w * 0.28), d.t)
	draw.rect(dc, r, draw.mix(d.ring, d.accent, d.t), rad(w * 0.28), 1.5)
	if d.t > 0.05 && g.icon_font != 0 {
		size := d.size * d.t
		m := font.metrics(g.fonts, g.icon_font, size)
		dim := font.text_width(g.fonts, g.icon_font, size, ICON_CHECK)
		c := draw.rect_center(r)
		draw.text(dc, g.icon_font, size, {math.round(c.x - dim * 0.5), math.round(c.y + (m.ascent - m.descent) * 0.5)}, {1, 1, 1, d.t}, ICON_CHECK)
	}
}

@(private)
mark_row :: proc(id, text: string, on, radio: bool) -> Signal {
	em := font_size()
	set_next_axis(.X, .Center)
	row_box := build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, id)
	sig := signal(row_box)
	if parent(row_box) {
		t := anim(key_from_string(row_box.key, "t"), on ? 1 : 0, 30)
		spacer(px(em * 0.4))
		next({width = px(em * 1.4), height = px(em * 1.4)})
		d := frame_new(Mark_Draw)
		d.t = t
		d.accent = color("accent")
		d.ring = color("text")
		d.ring.a = 0.5 + 0.25 * row_box.hot_t
		d.ring = tuned(d.ring)
		d.size = em * 0.95
		d.radio = radio
		custom("mark", mark_draw, d)
		spacer(px(em * 0.6))
		next({width = fill(), height = pct(1)})
		build_box({.Draw_Text}, text)
	}
	return sig
}

// Clickable row: animated check box + label. `value` is toggled on click.
checkbox :: proc(id: string, text: string, value: ^bool) -> Signal {
	sig := mark_row(id, text, value^, false)
	if sig.clicked { value^ = !value^ }
	return sig
}

radio :: proc(id: string, text: string, selected: ^int, index: int) -> Signal {
	sig := mark_row(id, text, selected^ == index, true)
	if sig.clicked { selected^ = index }
	return sig
}

////////////////////////////////
// Toggle switch

Toggle_Draw :: struct { t, hot, active: f32, track, accent: Color }

@(private)
toggle_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Toggle_Draw)(user)
	r := b.rect
	h := r.max.y - r.min.y
	paint_rect(dc, r, draw.mix(d.track, d.accent, d.t), rad(h * 0.5), d.t)
	pad := h * 0.14
	kd := h - 2 * pad
	kw := kd * (1 + 0.28 * d.active + 0.06 * d.hot)
	x := math.lerp(r.min.x + pad, r.max.x - pad - kw, d.t)
	draw.rect(dc, {{x - 1, r.min.y + pad + 1}, {x + kw + 1, r.max.y - pad + 2}}, {0, 0, 0, 0.30}, rad(kd * 0.5), 0, 3)
	draw.rect(dc, {{x, r.min.y + pad}, {x + kw, r.max.y - pad}}, {1, 1, 1, 1}, rad(kd * 0.5))
}

// Switch (named `toggle` because `switch` is an Odin keyword).
toggle :: proc(id: string, text: string, value: ^bool) -> Signal {
	em := font_size()
	set_next_axis(.X, .Center)
	row_box := build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, id)
	sig := signal(row_box)
	if sig.clicked { value^ = !value^ }
	if parent(row_box) {
		spacer(px(em * 0.4))
		next({width = fill(), height = pct(1)})
		build_box({.Draw_Text}, text)
		next({width = px(em * 2.6), height = px(em * 1.4)})
		d := frame_new(Toggle_Draw)
		d.t = anim(key_from_string(row_box.key, "t"), value^ ? 1 : 0, 34)
		d.hot, d.active = row_box.hot_t, row_box.active_t
		d.track = color("text")
		d.track.a = 0.28
		d.track = tuned(d.track)
		d.accent = color("accent")
		custom("track", toggle_draw, d)
		spacer(px(em * 0.4))
	}
	return sig
}

////////////////////////////////
// Sliders

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
	x1 = r.max.x - em * 4.6 - pad
	if x1 < x0 + 10 { x1 = x0 + 10 }
	return
}

@(private)
slider_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Slider_Draw)(user)
	em := b.font_size
	r := b.rect
	x0, x1 := slider_geom(r, em)
	cy := (r.min.y + r.max.y) * 0.5
	th := em * 0.34
	draw.rect(dc, {{x0, cy - th * 0.5}, {x1, cy + th * 0.5}}, d.track, rad(th * 0.5))
	fx0 := d.range ? math.lerp(x0, x1, d.t0) : x0
	fx1 := math.lerp(x0, x1, d.t1)
	draw.rect(dc, {{fx0, cy - th * 0.5}, {fx1, cy + th * 0.5}}, d.accent, rad(th * 0.5))
	kr := em * (0.52 + 0.12 * d.hot + 0.10 * d.active)
	knobs := [2]f32{math.lerp(x0, x1, d.t0), fx1}
	for i in (d.range ? 0 : 1) ..< 2 {
		kx := knobs[i]
		draw.rect(dc, {{kx - kr - 1, cy - kr + 1}, {kx + kr + 1, cy + kr + 3}}, {0, 0, 0, 0.35}, rad(kr), 0, 4)
		draw.rect(dc, {{kx - kr, cy - kr}, {kx + kr, cy + kr}}, {1, 1, 1, 1}, rad(kr))
		draw.rect(dc, {{kx - kr, cy - kr}, {kx + kr, cy + kr}}, d.accent, rad(kr), 2)
		draw.rect(dc, {{kx - kr * 0.38, cy - kr * 0.38}, {kx + kr * 0.38, cy + kr * 0.38}}, d.accent, rad(kr))
	}
	size := em * 0.88
	m := font.metrics(g.fonts, d.mono, size)
	w := font.text_width(g.fonts, d.mono, size, d.value_text)
	draw.text(dc, d.mono, size, {math.round(r.max.x - w - 2), math.round(cy + (m.ascent - m.descent) * 0.5)}, d.text, d.value_text)
}

@(private)
slider_pct :: proc(b: ^Box) -> f32 {
	x0, x1 := slider_geom(b.rect, font_size())
	if x1 - x0 < 1 { return 0 }
	return clamp((g.mouse.x - x0) / (x1 - x0), 0, 1)
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
		k := step > 0 ? step : (hi - lo) / 100
		v := value^
		if key_press(.Left) || key_press(.Down) { v -= k }
		if key_press(.Right) || key_press(.Up) { v += k }
		if key_press(.Page_Down) { v -= 10 * k }
		if key_press(.Page_Up) { v += 10 * k }
		if key_press(.Home) { v = lo }
		if key_press(.End) { v = hi }
		if step > 0 { v = math.round(v / step) * step }
		value^ = clamp(v, lo, hi)
	}
	if sig.pressed || sig.dragging {
		v := lo + slider_pct(b) * (hi - lo)
		if step > 0 { v = math.round(v / step) * step }
		value^ = clamp(v, lo, hi)
	}
	d := frame_new(Slider_Draw)
	t := clamp((value^ - lo) / (hi - lo), 0, 1)
	d.t1 = anim(key_from_string(b.key, "t"), t, 60, t)
	d.hot, d.active = b.hot_t, b.active_t
	d.track, d.accent, d.text = color("track"), color("accent"), color("text")
	d.value_text = strings.index_byte(format, '%') >= 0 ? fmt.aprintf(format, value^, allocator = frame_allocator()) : format
	d.mono = mono_font()
	b.custom, b.custom_user = slider_draw, d
	return
}

// Two thumbs on one track: the one closest to the pointer moves.
range_slider :: proc(id: string, lo_v, hi_v: ^f32, lo, hi: f32) -> (sig: Signal) {
	b := build_box({.Clickable}, id)
	b.cursor = .Hand
	sig = signal(b)
	if sig.pressed {
		p := slider_pct(b)
		pl, ph := (lo_v^ - lo) / (hi - lo), (hi_v^ - lo) / (hi - lo)
		which: f32 = abs(p - pl) < abs(p - ph) ? 0 : 1
		if abs(pl - ph) < 0.001 { which = p < pl ? 0 : 1 }
		drag_store({which, 0, 0, 0})
	}
	if sig.dragging {
		v := lo + slider_pct(b) * (hi - lo)
		if drag_load()[0] == 0 { lo_v^ = clamp(v, lo, hi_v^) } else { hi_v^ = clamp(v, lo_v^, hi) }
	}
	d := frame_new(Slider_Draw)
	d.range = true
	t0, t1 := clamp((lo_v^ - lo) / (hi - lo), 0, 1), clamp((hi_v^ - lo) / (hi - lo), 0, 1)
	d.t0 = anim(key_from_string(b.key, "t0"), t0, 60, t0)
	d.t1 = anim(key_from_string(b.key, "t1"), t1, 60, t1)
	d.hot, d.active = b.hot_t, b.active_t
	d.track, d.accent, d.text = color("track"), color("accent"), color("text")
	d.value_text = fmt.aprintf("%.0f-%.0f", lo_v^, hi_v^, allocator = frame_allocator())
	d.mono = mono_font()
	b.custom, b.custom_user = slider_draw, d
	return
}

////////////////////////////////
// Stepper, segmented control, chips, rating

// [-] value [+]: hold a button to repeat, Shift = x10. Returns true when the value changed.
stepper :: proc(id: string, value: ^int, lo, hi: int) -> (changed: bool) {
	em := font_size()
	set_next_axis(.X, .Center)
	row_box := build_box({}, id)
	if parent(row_box) {
		for dir in ([2]int{-1, 1}) {
			if dir == 1 {
				if style({font = mono_font(), text_align = .Center}) {
					next({width = px(em * 4.2), height = pct(1)})
					build_box({.Draw_Text}, fmt.tprintf("%d###val", value^))
				}
			}
			next({width = px(em * 2.2), height = px(em * 2.2)})
			sig := icon_button(dir < 0 ? "dec" : "inc", dir < 0 ? ICON_MINUS : ICON_ADD)
			amount := .Shift in sig.mods ? 10 : 1
			key := sig.box.key
			old := value^
			if sig.pressed { value^ += dir * amount; timer_set(key, 420) }
			else if sig.dragging && timer_due(key) { value^ += dir * amount; timer_set(key, 55) }
			if sig.dragging { g.anim_busy = true; g.wake_ms = 30 }
			value^ = clamp(value^, lo, hi)
			if value^ != old { changed = true }
		}
	}
	return
}

Seg_Draw :: struct { t: f32, n: int, accent: Color, pad: f32 }

@(private)
seg_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Seg_Draw)(user)
	r := b.rect
	iw := ((r.max.x - r.min.x) - 2 * d.pad) / f32(d.n)
	x := r.min.x + d.pad + d.t * iw
	paint_rect(dc, {{x, r.min.y + d.pad}, {x + iw, r.max.y - d.pad}}, d.accent, rad(max(0, b.radius - d.pad * 0.5)))
}

// Sliding-pill segmented control. Returns true when the selection changed.
segmented :: proc(id: string, labels: []string, selected: ^int) -> (changed: bool) {
	em := font_size()
	t := anim(key_from_string(parent_box().key, fmt.tprintf("%s_t", id)), f32(selected^), 40, f32(selected^))
	accent := color("accent")
	text_on, text_off: Color
	if tags("accent_button") { text_on = color("text") }
	if tags("weak") { text_off = color("text") }
	if tags("button") {
		set_next_axis(.X)
		b := build_box({.Draw_Background, .Draw_Border}, id)
		d := frame_new(Seg_Draw)
		d.t, d.n, d.accent, d.pad = t, len(labels), accent, em * 0.25
		b.custom, b.custom_user = seg_draw, d
		if parent(b) {
			spacer(px(em * 0.25))
			for label, i in labels {
				fg := i == selected^ ? text_on : text_off
				next({width = pct(1 / f32(len(labels))), height = pct(1), text_align = .Center, fg = fg})
				item := build_box({.Clickable, .Focusable, .Draw_Text}, fmt.tprintf("%s###seg%d", label, i))
				if signal(item).clicked && i != selected^ { selected^ = i; changed = true }
			}
		}
	}
	return
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
		}
	}
}

// Five icons; click the current value again to clear it.
rating :: proc(id: string, value: ^int) {
	em := font_size()
	set_next_axis(.X)
	box := build_box({}, id)
	if parent(box) {
		for i in 0 ..< 5 {
			cell_id := fmt.tprintf("%s_%d", id, i)
			prev := box_from_key(key_from_string(box.key, cell_id))
			grow := anim(key_from_string(box.key, fmt.tprintf("%s_g", cell_id)), prev != nil ? prev.hot_t : 0, 40)
			lit := i < value^
			if !lit { push_tags("weak") }
			next({width = px(em * 2), height = pct(1), font = g.icon_font, font_size = em * (1 + 0.35 * grow), text_align = .Center})
			b := build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###%s", lit ? ICON_RADIO_ON : ICON_RADIO, cell_id))
			if !lit { pop_tags() }
			if signal(b).clicked { value^ = value^ == i + 1 ? 0 : i + 1 }
		}
	}
}

////////////////////////////////
// Progress

Bar_Draw :: struct { t: f32, indeterminate: bool, phase: f32, track, fill: Color }

@(private)
bar_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar_Draw)(user)
	r := b.rect
	w := r.max.x - r.min.x
	radius := rad((r.max.y - r.min.y) * 0.5)
	draw.rect(dc, r, d.track, radius)
	if d.indeterminate {
		seg := w * 0.32
		e := d.phase * d.phase * (3 - 2 * d.phase)
		x := math.lerp(-seg, w, e)
		f := Rect{{r.min.x + max(0, x), r.min.y}, {r.min.x + min(w, x + seg), r.max.y}}
		if f.max.x > f.min.x { draw.rect(dc, f, d.fill, radius) }
	} else if d.t > 0.002 {
		paint_rect(dc, {r.min, {r.min.x + max(radius * 2, w * d.t), r.max.y}}, d.fill, radius)
	}
}

// Determinate (t in 0..1) or indeterminate bar. Size from the style stack or `next`.
progress :: proc(id: string, t: f32, indeterminate := false) {
	b := build_box({}, id)
	d := frame_new(Bar_Draw)
	d.t = anim(key_from_string(b.key, "t"), t, 24, t)
	d.indeterminate = indeterminate
	d.phase = g.anim_rate != 0 ? f32(math.mod(g.time_ms, 1600)) / 1600 : 0.5   // animations off: a still bar
	d.track, d.fill = color("track"), color("accent")
	b.custom, b.custom_user = bar_draw, d
	if indeterminate && g.anim_rate != 0 { g.anim_busy = true }
}

////////////////////////////////
// Dropdown and tabs

// Button showing the current item; opens a menu of `items`. Returns true when the selection changed.
dropdown :: proc(id: string, items: []string, selected: ^int) -> (changed: bool) {
	em := font_size()
	menu_key := key_from_u64(key_from_string(parent_box().key, id), 0xd0d0)
	open := ctx_menu_is_open(menu_key)
	btn: ^Box
	sig: Signal
	if tags("button") {
		set_next_axis(.X, .Center)
		btn = build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, id)
		sig = signal(btn)
		if parent(btn) {
			spacer(px(em * 0.8))
			next({width = fill(), height = pct(1)})
			build_box({.Draw_Text}, fmt.tprintf("%s###cur", items[selected^]))
			if tags("weak") { icon(open ? ICON_UP : ICON_DOWN, em * 1.8) }
		}
	}
	if sig.clicked {
		if open { ctx_menu_close() } else {
			ctx_menu_open(menu_key, {btn.rect.min.x, btn.rect.max.y + 4}, btn.key)
			g.menu_sel = selected^   // keyboard starts from the current value
		}
	}
	if ctx_menu(menu_key, max(btn.size.x, em * 10)) {
		for item, i in items {
			if menu_item(item, "", i == selected^).clicked { selected^ = i; changed = true }
		}
	}
	return
}

Tab_Draw :: struct { t: f32, accent: Color }

@(private)
tab_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tab_Draw)(user)
	if d.t < 0.01 { return }
	r := b.rect
	w := (r.max.x - r.min.x) * d.t
	cx := (r.min.x + r.max.x) * 0.5
	draw.rect(dc, {{cx - w * 0.5, r.max.y - 3}, {cx + w * 0.5, r.max.y}}, d.accent, 1.5)
}

// Row of tabs with a growing underline. `icons` may be nil. Returns true when the selection changed.
tabs :: proc(id: string, labels: []string, icons: []string, selected: ^int) -> (changed: bool) {
	em := font_size()
	for label, i in labels {
		on := selected^ == i
		tab_id := fmt.tprintf("%s_%d", id, i)
		key := key_from_string(parent_box().key, tab_id)
		t := anim(key_from_string(key, "t"), on ? 1 : 0, 34)
		if !on { push_tags("weak") }
		set_next_axis(.X, .Center)
		g.next_mod.width = children_sum()
		g.next_mod.height = pct(1)
		b := build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, tab_id)
		d := frame_new(Tab_Draw)
		d.t, d.accent = t, color("accent")
		b.custom, b.custom_user = tab_draw, d
		if parent(b) {
			spacer(px(em))
			if icons != nil { icon(icons[i], em * 1.6) }
			next({width = text_size(), height = pct(1)})
			build_box({.Draw_Text}, label)
			spacer(px(em))
		}
		if !on { pop_tags() }
		if signal(b).clicked && !on { selected^ = i; changed = true }
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
	g.next_mod.width = fill()
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.6
	c := build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###card_%s", title))
	push_parent(c)
	spacer(px(em * 0.9))
	set_next_axis(.X)
	g.next_mod.width = fill()
	g.next_mod.height = children_sum()
	push_parent(build_box({}, "###card_pad"))
	spacer(px(em * 1.1))
	set_next_axis(.Y)
	g.next_mod.width = fill()
	g.next_mod.height = children_sum()
	push_parent(build_box({}, "###card_body"))
	if title != "" {
		next({width = fill(), height = px(dense(em * 2.2))})
		if row(.Center) {
			if icon_glyph != "" { if tags("weak") { icon(icon_glyph, em * 1.8) } }
			next({width = fill(), height = pct(1)})
			if style({font_size = em * 1.1}) { build_box({.Draw_Text}, fmt.tprintf("%s###card_title", title)) }
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
	g.next_mod.width = fill()
	g.next_mod.height = children_sum()
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
	pop(&g.style_stack)
	pop_parent()
}


// Button with an icon-font glyph and a label. Push a kind tag first ("accent_button", "danger_button", "ghost_button").
button_icon :: proc(id: string, glyph, text: string, disabled := false) -> (sig: Signal) {
	em := font_size()
	// a disabled scope, so the label and icon inside go neutral too
	append(&g.disabled_stack, disabled)
	if disabled { g.disabled_depth += 1 }
	defer pop_disabled()
	if tags("button") {
		set_next_axis(.X, .Center)
		g.next_mod.width = children_sum()
		g.next_mod.height = px(dense(em * 2.2))
		g.next_mod.radius = em * 0.45
		flags := Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}
		b := build_box(flags, id)
		b.squish = anim(key_from_string(b.key, "squish"), g.active_key[.Left] == b.key && g.hot_key == b.key ? 0.04 : 0, 60)
		sig = signal(b)
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
