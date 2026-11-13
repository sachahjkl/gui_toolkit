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
@(require_results, deferred_none = pop_parent)
row :: proc(cross := Cross_Align.Start, flags: Box_Flags = {}, id: string = "") -> bool {
	set_next_axis(.X, cross)
	push_parent(build_box(flags, id))
	return true
}

// `if field_frame(id) { ... }`: one surface for a field and what goes with it (a search icon, the field, a count), laid
// out left to right. It has an input's background, border and corners (radius from `next` or the style), and one focus
// ring around all of it while a box inside has the keyboard focus (.Focus_Within). Build the field inside under the tag
// "bare": the field then draws no background, border or focus ring of its own.
@(require_results, deferred_none = pop_parent)
field_frame :: proc(id: string, cross := Cross_Align.Center) -> bool {
	set_next_axis(.X, cross)
	push_tags("input")
	b := build_box({.Draw_Background, .Draw_Border, .Draw_Focus_Ring, .Focus_Within, .Sunken}, id)
	pop_tags()
	push_parent(b)
	return true
}

// `if column() { ... }`: children are laid out top to bottom.
@(require_results, deferred_none = pop_parent)
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
// Feel.tooltip_delay_ms. `text` follows the id-string rules, as label's. It takes no press: what is under it (a row) keeps its own.
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
	if _, waiting := s.timers[key]; !waiting { timer_set(key, f64(s.feel.tooltip_delay_ms)) }
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
	Link,      // no face at all: words that say an act and do it, as a link: weak like a hint, lit under the pointer
}

// How a button looks and is laid out, apart from its id, its words and its glyph (button).
Button_Options :: struct {
	intent:    Intent,               // what the act means, and so its colour (its soft pair: a tinted fill, its words of the same hue)
	face:      Maybe(Button_Face),   // how it sits (nil: Raised, a glyph alone a Ghost)
	width:     Size,                 // over `next`'s: {} as wide as what is in it; fill() a share of the row; px(...) its own
	height:    f32,                  // over `next`'s, in pixels (0: `next`'s, else the toolkit's line)
	quiet:     bool,                 // a secondary act: smaller words, a Neutral one's weak until the pointer is over it
	wrap:      bool,                 // words longer than the width go on more lines; the button grows to hold them
	left:      bool,                 // what is in it at its left, whatever the style's text_align
	lit:       bool,                 // drawn as under the pointer (while its menu is open)
	disabled:  bool,                 // shown faded, not clickable
	tip:       string,               // a tooltip when the pointer rests on it ("" none), its description for a screen reader
	icon_font: font.Font_Id,         // the glyph's font (0: State.icon_font; lucide_icons() for Lucide's)
}

// A button: `text`, its words ("" none), beside `icon`, a glyph of `o.icon_font` ("" none). `id` is its id (key.odin:
// "save", or "###save"); what it shows is `text` and `icon`, so changing them keeps its state. How it is laid out:
//   - words (a glyph before them or not): one row. Its size: `o.width`, `o.height`, else `next`'s, else as wide as
//     what is in it and a line of the toolkit's height. A text_size(pad) width is its words' and `pad` on each side; a
//     text_pad given by `next` is the padding beside its words, else the toolkit's. A fill() share is never narrower
//     than what is in it; in a width of pixels too small, the padding gives way first. What is in a wider row is centred,
//     or where a style or `next` aligns text (`o.left`: at its left). Its words take the style's font and size, and
//     what `next` says of them (font, font_size, fg, text_pad). Its corners rounded unless `next` says otherwise. Tags
//     used: "button", its intent's (intent_tag) or "ghost_button" (+ any tag you pushed). Drawn by the theme's finish
//     (bevelled in the machined one).
//   - a glyph alone (`text` ""): one box (a tool of a bar, a close cross), a Ghost unless `o.face` says otherwise, its
//     size the style's or `next`'s (or `o.width`, `o.height`), the glyph centred unless a style or `next` aligns it. A
//     screen reader calls it by its `o.tip` (else its id: a glyph says nothing). Tags used: "icon_button" (a ghost),
//     else "button" and the intent's.
//   - the Link face: its words (and glyph before them) and no face, weak until the pointer is over it; an intent
//     colours them, a little quieter away from the pointer. As wide as they are and of a short line, unless `next` or
//     `o.width`, `o.height` say otherwise.
//
//   if ui.button("save", "Save", lucide.SAVE, {intent = .Success, icon_font = ui.lucide_icons()}).clicked { save(app) }
//   if ui.button("close", icon = ui.ICON_X, o = {tip = "Close"}).clicked { app.open = false }
button :: proc(id: string, text := "", icon := "", o := Button_Options{}) -> Signal {
	face := o.face.? or_else (text == "" && icon != "" ? Button_Face.Ghost : .Raised)
	push_disabled(o.disabled)
	defer pop_disabled()
	if face == .Link { return button_link(id, text, icon, o) }
	if text == "" { return button_glyph(id, icon, face, o) }
	return button_row(id, text, icon, face, o)
}

// How a button sits, as its id: "###id" whether the caller wrote "id" or "###id".
@(private = "file")
button_key :: proc(shown, id: string) -> string { return fmt.tprintf("%s###%s", shown, hash_part(id)) }

// The size the options give the next box, over what `next` said (a box that takes its size from the style or `next`).
@(private = "file")
next_size :: proc(width: Size, height: f32) {
	s := gs()
	if width == {} && height <= 0 { return }
	if !s.has_next { s.next_mod, s.has_next = {}, true }
	if width != {} { s.next_mod.width = width }
	if height > 0 { s.next_mod.height = px(height) }
}

// (a glyph alone: the box's text is the glyph, its id alone decides the key)
@(private = "file")
button_glyph :: proc(id, icon: string, face: Button_Face, o: Button_Options) -> Signal {
	s := gs()
	push_button_tags(o.intent, face, face == .Ghost ? "icon_button" : "button")
	defer pop_tags()
	if face == .Ghost { if ink, ok := button_ink(o.intent).?; ok { next_default({fg = ink}) } }
	next_size(o.width, o.height)
	if style({font = o.icon_font != 0 ? o.icon_font : s.icon_font}) {
		aligned := text_align_given()
		flags := Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .No_Text_Trunc}
		if face != .Ghost { flags += {.Draw_Border} }
		if face == .Toggled { flags += {.Held} }
		if o.lit { flags += {.Lit} }
		b := build_box(flags, button_key(icon, id))
		if !aligned { b.text_align = .Center }
		if face != .Ghost { b.squish = press_squish(b) }
		button_a11y(b, face, o.tip != "" ? o.tip : hash_part(id), o.tip)
		sig := signal(b)
		button_tip(sig, o.tip)
		return sig
	}
	return {}
}

// The toolkit's room beside a button's words (with their own text_pad), its line, its glyph's cell and its corners, in
// font sizes.
@(private = "file") BUTTON_PAD_EM :: 0.95
@(private = "file") BUTTON_LINE_EM :: 2.2
@(private = "file") BUTTON_GLYPH_EM :: 1.5
@(private = "file") BUTTON_RADIUS_EM :: 0.45
// A quiet button's words, of the font size.
@(private = "file") BUTTON_QUIET_SCALE :: 0.9

@(private = "file")
button_row :: proc(id, text, icon: string, face: Button_Face, o: Button_Options) -> (sig: Signal) {
	s := gs()
	em := font_size()
	// (what the caller's `next` says of the words: they are a box in the row, which `next` does not reach)
	m := s.has_next ? s.next_mod : Style_Mod{}
	pad := em * BUTTON_PAD_EM
	if _, given := m.text_pad.?; given { pad = 0 }
	w := o.width != {} ? o.width : m.width.? or_else {}
	if w.kind == .Text {   // its words' width and this much on each side: the padding, the row as wide as what is in it
		// (the row's border is inside that much: a row as wide as its children counts it on each side)
		pad = max(0, w.value - max(1, math.round(s.scale)))
		w = {}
	}
	if w.kind == .Children_Sum { w = {} }
	if o.wrap && w == {} { w = fill() }
	line := dense(em * BUTTON_LINE_EM)
	h := px(line)
	words_h := pct(1)
	if o.height > 0 {
		line = o.height
		h = px(line)
	} else if mh, given := m.height.?; given && mh.kind != .Children_Sum && mh.kind != .None {
		h = mh
		if mh.kind == .Pixels { line = mh.value }
		if mh.kind == .Text {   // (its words' line and that padding, the row's border inside it)
			h, words_h = children_sum(), text_size(mh.value - max(1, math.round(s.scale)), mh.strictness)
		}
	}
	if o.wrap { h = children_sum() }
	align := Text_Align.Center
	if o.left { align = .Left } else if a, given := m.text_align.?; given { align = a } else if top_style().text_aligned { align = top_style().text_align }
	words_size := m.font_size.? or_else em
	if o.quiet { words_size = math.round(words_size * BUTTON_QUIET_SCALE) }

	push_button_tags(o.intent, face)
	defer pop_tags()
	set_next_axis(.X, .Center)
	s.next_mod.width = w == {} ? children_sum() : w
	s.next_mod.height = h
	if s.next_mod.radius == nil { s.next_mod.radius = em * BUTTON_RADIUS_EM }
	ink := face == .Ghost ? button_ink(o.intent) : nil
	fg := m.fg
	if fg == nil { fg = ink }
	flags := Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}
	if face == .Toggled { flags += {.Held} }
	if o.lit { flags += {.Lit} }
	b := build_box(flags, button_key("", id))
	b.text_align = align
	b.squish = press_squish(b)
	sig = signal(b)
	button_a11y(b, face, "", o.tip)
	button_tip(sig, o.tip)
	// (a secondary act's words: weak until the pointer is over it, unless they say an intent)
	weak := o.quiet && o.intent == .Neutral && !sig.hovering && !o.lit
	if parent(b) {
		if weak { push_tags("weak") }
		defer if weak { pop_tags() }
		wide := w != {} && !o.wrap   // (wider than what is in it: that goes where it is aligned)
		// (the padding gives way first in a width too small for it: the words keep theirs)
		if pad > 0 { spacer(px(pad, 0)) }
		if wide && align != .Left { spacer(fill()) }
		glyph_w: f32 = 0
		if icon != "" {
			glyph_w = em * BUTTON_GLYPH_EM
			next({width = px(glyph_w), height = pct(1), font = o.icon_font != 0 ? o.icon_font : s.icon_font, text_align = .Center, fg = ink})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", icon))
		}
		words := Style_Mod{fg = fg, font = m.font, font_size = words_size, text_pad = m.text_pad, text_align = align}
		label: ^Box
		if o.wrap {
			// (between margins that make one line `line` tall)
			lh := math.ceil(font.metrics(s.fonts, m.font.? or_else top_style().font, words_size).line_height)
			margin := max(math.round((line - lh) * 0.5), 0)
			next({width = fill(), height = children_sum(), axis = .Y})
			if column() {
				spacer(px(margin), exact = true)
				words.width = fill()
				next(words)
				paragraph(fmt.tprintf("%s###t", text_shown(text)))
				spacer(px(margin), exact = true)
			}
		} else {
			words.width, words.height = text_size(), words_h
			next(words)
			label = build_box({.Draw_Text}, fmt.tprintf("%s###t", text_shown(text)))
		}
		if wide && align != .Right { spacer(fill()) }
		if pad > 0 { spacer(px(pad, 0)) }
		// (a share of the row is never narrower than what is in it, its padding on both sides included: the label,
		// measured as the layout will (its text and text_pad), is never cut nor drawn against an edge. A width in
		// pixels is the caller's)
		if w.kind == .Percent && w.least == 0 && label != nil {
			b.pref[.X].least = math.ceil(2 * pad + glyph_w + label.text_dim.x + 2 * label.text_pad)
		}
	}
	return
}

// A link's words, away from the pointer: this much of their colour.
@(private = "file") LINK_REST_ALPHA :: 0.75

@(private = "file")
button_link :: proc(id, text, icon: string, o: Button_Options) -> Signal {
	s := gs()
	em := font_size()
	set_next_axis(.X, .Center)
	if o.width != {} { s.next_mod.width = o.width } else if s.next_mod.width == nil { s.next_mod.width = children_sum() }
	if o.height > 0 { s.next_mod.height = px(o.height) } else if s.next_mod.height == nil { s.next_mod.height = px(math.round(em * 1.4)) }
	if s.next_mod.cursor == nil { s.next_mod.cursor = .Hand }
	b := build_box({.Clickable, .Focusable}, button_key("", id))
	sig := signal(b)
	button_a11y(b, .Link, text != "" ? text : o.tip, o.tip)
	button_tip(sig, o.tip)
	hot := sig.hovering || o.lit
	col := button_ink(o.intent)
	if c, ok := col.?; ok && !hot {
		c.a *= LINK_REST_ALPHA
		col = c
	}
	weak := o.intent == .Neutral && !hot
	if parent(b) {
		if weak { push_tags("weak") }
		defer if weak { pop_tags() }
		if icon != "" {
			next({width = px(math.round(em * 1.2)), height = pct(1), font = o.icon_font != 0 ? o.icon_font : s.icon_font, text_align = .Center, text_pad = 0, fg = col})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", icon))
			if text != "" { spacer(px(math.round(em * 0.3))) }
		}
		if text != "" {
			next({width = text_size(0), height = pct(1), text_pad = 0, fg = col})
			build_box({.Draw_Text}, fmt.tprintf("%s###t", text_shown(text)))
		}
	}
	return sig
}

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

// The tooltip of a button (`tip`, "" none), once the pointer has rested on it for Feel.tooltip_delay_ms.
@(private)
button_tip :: proc(sig: Signal, tip: string) {
	if tip != "" && hovered_for(sig) { if tooltip() { tooltip_text(tip) } }
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

////////////////////////////////
// Scrolling

// Vertical scroll region: children are laid out in a column and clipped; the mouse wheel scrolls it.
@(require_results, deferred_none = pop_parent)
scroll_y :: proc(id: string) -> bool {
	set_next_axis(.Y)
	b := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, id)
	_ = signal(b)
	push_parent(b)
	return true
}

// `if flow({em * 0.5, em * 0.5}) { ... }`: children flow left to right and wrap onto new lines when the row is too
// narrow, instead of overflowing. Full width and as tall as its lines unless `next` says otherwise.
@(require_results, deferred_none = pop_parent)
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