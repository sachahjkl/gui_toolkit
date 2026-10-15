package ui

import "core:math"
import "../draw"
import "../font"

////////////////////////////////
// Layout helpers

@(private)
set_next_axis :: proc(a: Axis, cross := Cross_Align.Start) {
	if !g.has_next { g.next_mod = {} }
	g.next_mod.axis = a
	g.next_mod.cross = cross
	g.has_next = true
}

@(private)
push_parent :: proc(b: ^Box) { append(&g.parent_stack, b) }

// `if row() { ... }`: children are laid out left to right. Size comes from the style stack (or a preceding `next`).
// Pass `flags` (e.g. {.Draw_Background}) and a stable `id` to make it a visible, persistent container.
@(deferred_none = pop_parent)
row :: proc(cross := Cross_Align.Start, flags: Box_Flags = {}, id: string = "") -> bool {
	set_next_axis(.X, cross)
	push_parent(build_box(flags, id))
	return true
}

// `if column() { ... }`: children are laid out top to bottom.
@(deferred_none = pop_parent)
column :: proc(cross := Cross_Align.Start, flags: Box_Flags = {}, id: string = "") -> bool {
	set_next_axis(.Y, cross)
	push_parent(build_box(flags, id))
	return true
}

// Empty space along the parent's layout axis.
spacer :: proc(size: Size) {
	p := parent_box()
	m: Style_Mod
	if p.layout_axis == .X { m.width = size; m.height = fill() } else { m.height = size; m.width = fill() }
	if g.has_next { m = merge_mod(g.next_mod, m) }
	next(m)
	build_box({})
}

@(private)
merge_mod :: proc(a, b: Style_Mod) -> Style_Mod {
	r := a
	if r.width == nil  { r.width = b.width }
	if r.height == nil { r.height = b.height }
	return r
}

// A box that draws itself via `draw_fn` (user data must live in the frame arena: see `frame_new`).
custom :: proc(id: string, draw_fn: Custom_Draw, user: rawptr, flags: Box_Flags = {}) -> ^Box {
	b := build_box(flags, id)
	b.custom = draw_fn
	b.custom_user = user
	return b
}

// Allocates a value that stays valid until the end of this frame's draw.
frame_new :: proc($T: typeid) -> ^T { return new(T, frame_allocator()) }

////////////////////////////////
// Basic widgets

label :: proc(text: string) -> Signal {
	b := build_box({.Draw_Text}, text)
	return signal(b)
}

// Tags used: "button" (+ any tag you pushed, e.g. "accent"). `id` follows the id-string rules: "Add###add_btn".
button :: proc(id: string) -> Signal {
	if tags("button") {
		b := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Text, .Draw_Hot_Effects}, id)
		b.text_align = .Center
		b.squish = anim(key_from_string(b.key, "squish"), g.active_key[.Left] == b.key && g.hot_key == b.key ? 0.04 : 0, 60)
		return signal(b)
	}
	return {}
}

// Icon-font glyph as a clickable button without frame.
icon_button :: proc(id: string, icon: string) -> Signal {
	if tags("icon_button") {
		if style({font = g.icon_font}) {
			b := build_box({.Clickable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .No_Text_Trunc}, icon)
			// the icon is the text; the id decides the key
			b.key = key_from_string(parent_box().key, id)
			b.text_align = .Center
			return signal(b)
		}
	}
	return {}
}

Mark_Draw :: struct { t: f32, accent, ring: Color, size: f32 }

@(private)
mark_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Mark_Draw)(user)
	r := b.rect
	w := r.max.x - r.min.x
	inset := (1 - d.t) * w * 0.5
	fill := d.accent
	fill.a *= min(1, d.t * 1.6)
	draw.rect(dc, draw.rect_pad(r, -inset), fill, w * 0.28)
	draw.rect(dc, r, draw.mix(d.ring, d.accent, d.t), w * 0.28, 1.5)
	if d.t > 0.05 {
		// check mark: two strokes drawn as thin rects would alias; use the icon font glyph when available
		size := d.size * d.t
		if g.icon_font != 0 {
			m := font.metrics(g.fonts, g.icon_font, size)
			dim := font.text_width(g.fonts, g.icon_font, size, "V")
			c := draw.rect_center(r)
			draw.text(dc, g.icon_font, size, {math.round(c.x - dim * 0.5), math.round(c.y + (m.ascent - m.descent) * 0.5)}, {1, 1, 1, d.t}, "V")
		}
	}
}

// Clickable row: animated box + label. Returns the signal; `value` is toggled on click.
checkbox :: proc(id: string, text: string, value: ^bool) -> Signal {
	em := font_size()
	set_next_axis(.X, .Center)
	row_box := build_box({.Clickable, .Draw_Hot_Effects}, id)
	sig := signal(row_box)
	if sig.clicked { value^ = !value^ }
	if parent(row_box) {
		t := anim(key_from_string(row_box.key, "t"), value^ ? 1 : 0, 30)
		next({width = px(em * 1.4), height = px(em * 1.4)})
		d := frame_new(Mark_Draw)
		d.t = t
		d.accent = color("accent")
		d.ring = color("text")
		d.ring.a = 0.5 + 0.25 * row_box.hot_t
		d.size = em * 0.95
		custom("mark", mark_draw, d)
		spacer(px(em * 0.6))
		next({width = text_size(), height = px(em * 1.6)})
		build_box({.Draw_Text}, text)
	}
	return sig
}

////////////////////////////////
// Scrolling

// Vertical scroll region: children are laid out in a column and clipped; the mouse wheel scrolls it.
@(deferred_none = pop_parent)
scroll_y :: proc(id: string) -> bool {
	set_next_axis(.Y)
	b := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, id)
	_ = signal(b)
	push_parent(b)
	return true
}
