package ui

import "core:fmt"
import "core:math"
import "../font"


////////////////////////////////
// Layout helpers

// The child axis of the next box, and its cross alignment. A `cross` left at its default (.Start) does not replace one
// that a `next` gave first: `next({cross = .Center}); if row() {...}` centres its children, as it reads.
@(private)
set_next_axis :: proc(a: Axis, cross := Cross_Align.Start) {
	s := gs()
	if !s.has_next { s.next_mod = {} }
	s.next_mod.axis = a
	if _, given := s.next_mod.cross.?; !given || cross != .Start { s.next_mod.cross = cross }
	s.has_next = true
}

// Manual parent scope (prefer if parent(box) { ... }; pair with pop_parent).
push_parent :: proc(b: ^Box) { append(&gs().parent_stack, b) }

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

// `if field_frame(id) { ... }`: one surface for a field and what goes with it (a search icon, the field, a count), laid
// out left to right. It has an input's background, border and corners (radius from `next` or the style), and one focus
// ring around all of it while a box inside has the keyboard focus (.Focus_Within). Build the field inside under the tag
// "bare": the field then draws no background, border or focus ring of its own.
@(deferred_none = pop_parent)
field_frame :: proc(id: string, cross := Cross_Align.Center) -> bool {
	set_next_axis(.X, cross)
	push_tags("input")
	b := build_box({.Draw_Background, .Draw_Border, .Draw_Focus_Ring, .Focus_Within, .Sunken}, id)
	pop_tags()
	push_parent(b)
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
// Vertical pixel gaps follow the density setting unless `exact` (e.g. the stand-ins for virtualized rows).
spacer :: proc(size: Size, exact := false) {
	s := gs()
	p := parent_box()
	size := size
	if !exact && p.layout_axis == .Y && size.kind == .Pixels { size.value = math.round(size.value * s.density) }
	m: Style_Mod
	if p.layout_axis == .X { m.width = size; m.height = Size{} } else { m.height = size; m.width = Size{} }
	if s.has_next { m = merge_mod(s.next_mod, m) }
	next(m)
	build_box({})
}

// `a` with what it leaves unset taken from `b` (every field; flags are added together).
merge_mod :: proc(a, b: Style_Mod) -> Style_Mod {
	r := a
	if r.width == nil { r.width = b.width }
	if r.height == nil { r.height = b.height }
	if r.font == nil { r.font = b.font }
	if r.font_size == nil { r.font_size = b.font_size }
	if r.text_pad == nil { r.text_pad = b.text_pad }
	if r.text_align == nil { r.text_align = b.text_align }
	if r.radius == nil { r.radius = b.radius }
	if r.transparency == nil { r.transparency = b.transparency }
	if r.squish == nil { r.squish = b.squish }
	if r.cursor == nil { r.cursor = b.cursor }
	if r.axis == nil { r.axis = b.axis }
	if r.cross == nil { r.cross = b.cross }
	if r.gap == nil { r.gap = b.gap }
	if r.fixed_x == nil { r.fixed_x = b.fixed_x }
	if r.fixed_y == nil { r.fixed_y = b.fixed_y }
	if r.fixed_w == nil { r.fixed_w = b.fixed_w }
	if r.fixed_h == nil { r.fixed_h = b.fixed_h }
	if r.bg == nil { r.bg = b.bg }
	if r.border == nil { r.border = b.border }
	if r.fg == nil { r.fg = b.fg }
	r.flags += b.flags
	return r
}

// Like `next`, but on top of a `next` already given for the same box: what `m` sets wins, what it leaves unset keeps the
// earlier value. For a helper that sizes its own box while its caller placed it (`next({fixed_x = ...})`, then the helper).
next_merge :: proc(m: Style_Mod) {
	if gs().has_next { next(merge_mod(m, gs().next_mod)) } else { next(m) }
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

// A label whose whole text shows in a tooltip when its box cuts it ("...") and the pointer has rested on it for
// TIP_DELAY_S. `text` follows the id-string rules, as label's. It takes no press: what is under it (a row) keeps its own.
label_tip :: proc(text: string) -> Signal {
	s := gs()
	b := build_box({.Draw_Text}, text)
	sig := signal(b)
	key := key_from_u64(b.key, LABEL_TIP_SALT)
	if b.text == "" || !text_cut_under_mouse(b, b.text, b.text_pad) {
		delete_key(&s.timers, key)
		return sig
	}
	// (a timer of its own: a label is never the box under the pointer, hovered_for does not see it)
	if _, waiting := s.timers[key]; !waiting { timer_set(key, TIP_DELAY_S * 1000) }
	if timer_due(key) {
		if tooltip() { tooltip_text(b.text) }
	} else if t, ok := s.timers[key]; ok {
		wake_within(s, max(1, int(t.next_ms - s.time_ms) + WAKE_MARGIN_MS))
	}
	return sig
}

@(private = "file") LABEL_TIP_SALT :: 0x7175

// How a button sits, apart from its colour (its colour is what it does: Intent).
Button_Face :: enum u8 {
	Raised,    // a face of its own: the theme's button, or its intent's soft pair
	Ghost,     // no face until the pointer is over it (a tool among many); an intent colours its words
	Toggled,   // held down: the option chosen (Box_Flag .Held)
}

// The pointer rests this long on a button before its tooltip shows.
TIP_DELAY_S :: 0.5

// Pushes the tags of a button's box, one group (pop_tags once): `base` ("button", "icon_button"), and the intent's
// (intent_tag) or, for a ghost, "ghost_button": a ghost has no face at rest, whatever its intent (button_ink colours its
// words).
@(private)
push_button_tags :: proc(intent: Intent, face: Button_Face, base := "button") {
	tag := face == .Ghost ? (base == "button" ? "ghost_button" : "") : intent_tag(intent)
	if tag != "" { push_tags(base, tag) } else { push_tags(base) }
}

// The words of a ghost button of `intent`, which stand on the page: its soft pair's ink (nil: Neutral, the theme's).
@(private)
button_ink :: proc(intent: Intent) -> Maybe(Color) {
	if intent == .Neutral { return nil }
	c := hue_color(intent_hue(intent))
	c.a = 1
	_, ink := soft_pair(c)
	return ink
}

// What `m` sets for the next box, under what the caller's `next` said (that wins).
@(private)
next_default :: proc(m: Style_Mod) {
	if gs().has_next { next(merge_mod(gs().next_mod, m)) } else { next(m) }
}

// Whether a style or the `next` of the box about to be built set text_align.
@(private)
text_align_given :: proc() -> bool {
	s := gs()
	return top_style().text_aligned || (s.has_next && s.next_mod.text_align != nil)
}

// The tooltip of a button (`tip`, "" none), once the pointer has rested on it for TIP_DELAY_S.
@(private)
button_tip :: proc(sig: Signal, tip: string) {
	if tip != "" && hovered_for(sig, TIP_DELAY_S) { if tooltip() { tooltip_text(tip) } }
}

// A button of words, its size from the style or `next`; its text centred unless a style or `next` aligns it. Tags used:
// "button", its intent's (intent_tag) or "ghost_button" (+ any tag you pushed). `id` follows the id-string rules:
// "Add###add_btn". `intent`: what it does, and so its colour. `face`: how it sits. `disabled`: shown faded, not
// clickable. `lit`: drawn as under the pointer (while its menu is open). `tip`: a tooltip when the pointer rests on it ("" none),
// its description for a screen reader.
button :: proc(id: string, intent := Intent.Neutral, face := Button_Face.Raised, disabled := false, lit := false, tip := "") -> Signal {
	push_disabled(disabled)
	defer pop_disabled()
	push_button_tags(intent, face)
	defer pop_tags()
	aligned := text_align_given()
	if face == .Ghost { if ink, ok := button_ink(intent).?; ok { next_default({fg = ink}) } }
	flags := Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Text, .Draw_Hot_Effects}
	if face == .Toggled { flags += {.Held} }
	if lit { flags += {.Lit} }
	b := build_box(flags, id)
	if !aligned { b.text_align = .Center }
	b.squish = press_squish(b)
	button_a11y(b, face, "", tip)
	sig := signal(b)
	button_tip(sig, tip)
	return sig
}

// A button's node for a screen reader: `name` ("" its words), `tip` its description, pressed while Toggled.
@(private)
button_a11y :: proc(b: ^Box, face: Button_Face, name, tip: string) {
	info := A11y_Info{role = .Button, name = name, description = tip != name ? tip : ""}
	if face == .Toggled { info.toggled = .True }
	a11y_default(b, info)
}

// How much a pressed button shrinks: the theme's press_squish while the left button is held on it (at once), else 0.
press_squish :: proc(b: ^Box) -> f32 {
	s := gs()
	if s.theme == nil || s.theme.press_squish <= 0 { return 0 }
	return s.active_key[.Left] == b.key && s.hot_key == b.key ? s.theme.press_squish : 0
}

// A button that is a glyph and no words (a tool of a bar, a close cross), its size from the style or `next`; the glyph
// centred unless a style or `next` aligns it. `icon_font`: the glyph's font (0: State.icon_font; a `next` font wins).
// `tip`: a tooltip when the pointer rests on it. `name`: what a screen reader calls it ("": `tip`, else `id`: a glyph says
// nothing). `intent`, `face` (a ghost by default: no face until the pointer is over it), `disabled` and `lit` (drawn as
// under the pointer: while its menu is open) as for button_icon. Tags used: "icon_button" (a ghost), else "button" and
// the intent's. A labelled button, a glyph beside its words, is button_icon.
icon_button :: proc(id: string, icon: string, tip := "", name := "", icon_font: font.Font_Id = 0, intent := Intent.Neutral, face := Button_Face.Ghost, disabled := false, lit := false) -> Signal {
	s := gs()
	push_disabled(disabled)
	defer pop_disabled()
	push_button_tags(intent, face, face == .Ghost ? "icon_button" : "button")
	defer pop_tags()
	if face == .Ghost { if ink, ok := button_ink(intent).?; ok { next_default({fg = ink}) } }
	if style({font = icon_font != 0 ? icon_font : s.icon_font}) {
		aligned := text_align_given()
		flags := Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .No_Text_Trunc}
		if face != .Ghost { flags += {.Draw_Border} }
		if face == .Toggled { flags += {.Held} }
		if lit { flags += {.Lit} }
		// the glyph is the displayed text, `id` alone decides the key (so changing the icon keeps the state)
		b := build_box(flags, fmt.tprintf("%s###%s", icon, id))
		if !aligned { b.text_align = .Center }
		if face != .Ghost { b.squish = press_squish(b) }
		button_a11y(b, face, name != "" ? name : (tip != "" ? tip : b.name), tip)
		sig := signal(b)
		button_tip(sig, tip)
		return sig
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

// `if flow({em * 0.5, em * 0.5}) { ... }`: children flow left to right and wrap onto new lines when the row is too
// narrow, instead of overflowing. Full width and as tall as its lines unless `next` says otherwise.
@(deferred_none = pop_parent)
flow :: proc(gap: Vec2 = {}, id: string = "") -> bool {
	s := gs()
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = children_sum() }
	m.axis = .X
	m.gap = gap
	s.next_mod = m
	s.has_next = true
	push_parent(build_box({.Wrap}, id))
	return true
}