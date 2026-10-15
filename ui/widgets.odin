package ui

import "core:fmt"


////////////////////////////////
// Layout helpers

@(private)
set_next_axis :: proc(a: Axis, cross := Cross_Align.Start) {
	if !g.has_next { g.next_mod = {} }
	g.next_mod.axis = a
	g.next_mod.cross = cross
	g.has_next = true
}

// Manual parent scope (prefer if parent(box) { ... }; pair with pop_parent).
push_parent :: proc(b: ^Box) { append(&g.parent_stack, b) }

// A box whose children lay out left to right, centered (no scope; pair with `if parent(b)`).
row_box :: proc(flags: Box_Flags, id: string = "") -> ^Box {
	set_next_axis(.X, .Center)
	return build_box(flags, id)
}

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

// Empty space along the parent's layout axis. The off-axis size is None (0): a spacer must never drive the
// cross-axis size of a children_sum parent (pct would resolve against a distant ancestor and explode it).
spacer :: proc(size: Size) {
	p := parent_box()
	m: Style_Mod
	if p.layout_axis == .X { m.width = size; m.height = Size{} } else { m.height = size; m.width = Size{} }
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
		b := build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Text, .Draw_Hot_Effects}, id)
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
			// the glyph is the displayed text, `id` alone decides the key (so changing the icon keeps the state)
			b := build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .No_Text_Trunc}, fmt.tprintf("%s###%s", icon, id))
			b.text_align = .Center
			return signal(b)
		}
	}
	return {}
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
