package ui

// A strip (docs/strip.md; its reasons: src/md/features/strip.md): a row of choices (tabs, chips) that scrolls sideways
// when it is wider than its room. No scroll bar: the edge that hides items fades, and an arrow button lies over it.
//
//   `if ui.strip("###id") { items }`: the items are the boxes built directly in it, in one line.
//
// The implicit state machine of each side: hidden items (by the view's offset and bounds) -> its arrow shows; none ->
// it goes. It is decided at the build from the last layout, and checked again after this build's layout
// (strips_settle): a change asks for one more build, so an arrow never stays with nothing to show.

import "core:fmt"
import "core:math"
import "../draw"
import "../i18n"
import "../lucide"

// What a click on an arrow moves: the next hidden item fully in view (Item), or the clear part of the view (Page: a
// long strip of small items).
Strip_Step :: enum u8 { Item, Page }

Strip_Options :: struct {
	step: Strip_Step,
	fade: f32,   // the width each edge that hides items fades over, ems (0: STRIP_FADE_EM); never less than an arrow
}

// The fade of an edge that hides items, ems: an arrow and a little more, so that the words beside the arrow fade too.
STRIP_FADE_EM :: 2.4
@(private = "file") STRIP_ARROW_EM :: 1.6         // an arrow button's width
@(private = "file") STRIP_GLYPH_EM :: 0.9         // its chevron's size
@(private = "file") STRIP_SCRIM_SOLID :: 0.55     // the share of an arrow's width where its scrim is opaque
@(private = "file") STRIP_HIDDEN_PX :: 0.5        // an offset this close to an end is that end

// A strip in the build, from strip to strips_settle.
@(private)
Strip_Build :: struct {
	outer, view:        Key,
	right, right_scrim: Key,    // the right arrow and its scrim, when built (strips_settle puts them at the edge)
	before, after:      bool,   // the arrows built: the left one, the right one
	arrow_w, fade:      f32,
	step:               Strip_Step,
}

// `if strip("###id", o) { items }`: a row of choices. With no width given (next), as wide as its items, giving way first
// in a row that is short; a width given is kept. As tall as its parent by default: give the row a height of its own.
@(require_results, deferred_none = strip_end)
strip :: proc(id: string, o := Strip_Options{}) -> bool {
	s := gs()
	em := font_size()
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = children_sum(0) }
	if m.height == nil { m.height = pct(1) }
	cross := m.cross.? or_else Cross_Align.Center
	m.axis = Axis.X
	m.cross = cross
	s.next_mod, s.has_next = m, true
	// (its key only: a strip shows no words of its own, whatever the id says)
	outer := build_box({}, fmt.tprintf("###%s", hash_part(id)))
	push_parent(outer)
	// (the view takes the strip's width: its items' when the strip hugs them, which the strip then gives up first)
	hug := outer.pref[.X].kind == .Children_Sum
	next({width = hug ? children_sum(0) : pct(1), height = pct(1), axis = .X, cross = cross})
	view := build_box({.Clip, .View_Scroll_X, .Allow_Overflow_X, .Scrollbar_None, .Wheel_Sideways}, "###strip_view")
	_ = signal(view)
	arrow_w := math.round(em * STRIP_ARROW_EM)
	fade := max(arrow_w, math.round((o.fade > 0 ? o.fade : STRIP_FADE_EM) * em))
	scroll_fades(view, .X, fade)
	append(&s.strip_stack, Strip_Build{outer = outer.key, view = view.key, arrow_w = arrow_w, fade = fade, step = o.step})
	push_parent(view)
	return true
}

@(private)
strip_end :: proc() {
	s := gs()
	pop_parent()   // (the view)
	sb := pop(&s.strip_stack)
	view := s.boxes[sb.view]
	outer := s.boxes[sb.outer]
	sb.before, sb.after = strip_hides(view)
	if sb.before { strip_arrow(&sb, view, outer, -1) }
	if sb.after { strip_arrow(&sb, view, outer, 1) }
	append(&s.strips, sb)
	pop_parent()   // (the strip)
}

// Whether the view hides items before its start and after its end (by its offset and its last layout's bounds).
@(private = "file")
strip_hides :: proc(view: ^Box) -> (before, after: bool) {
	off, limit := view.view_off.x, view_limit(view, .X)
	return off > STRIP_HIDDEN_PX, off < limit - STRIP_HIDDEN_PX
}

// The scrim under an arrow: the surface under the strip, opaque at the strip's edge, clear at the arrow's inner side, so
// that the chevron reads over the faded items.
@(private = "file")
Strip_Scrim :: struct { under: Color, left: bool }

@(private = "file")
strip_scrim_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Strip_Scrim)(user)
	c := d.under
	clear := Color{c.r, c.g, c.b, 0}
	r := b.rect
	w := r.max.x - r.min.x
	if w <= 0 { return }
	stops := d.left ? [3]draw.Gradient_Stop{{color = c, pos = 0}, {color = c, pos = STRIP_SCRIM_SOLID}, {color = clear, pos = 1}} : [3]draw.Gradient_Stop{{color = clear, pos = 0}, {color = c, pos = 1 - STRIP_SCRIM_SOLID}, {color = c, pos = 1}}
	draw.gradient(dc, r, {kind = .Linear, start = {0, 0}, end = {w, 0}, stops = stops[:]})
}

// An arrow over an edge of the strip (`dir` -1: the left one, 1: the right one): not a Tab stop (the items are), a name
// for a screen reader and no tooltip; held, it repeats.
@(private = "file")
strip_arrow :: proc(sb: ^Strip_Build, view, outer: ^Box, dir: int) {
	em := font_size()
	left := dir < 0
	side := left ? "left" : "right"
	// (the right edge by the last layout; strips_settle puts it at this layout's)
	x := left ? f32(0) : max(0, outer.size.x - sb.arrow_w)
	next({fixed_x = x, fixed_y = 0, width = px(sb.arrow_w), height = pct(1)})
	scrim := build_box({}, fmt.tprintf("###strip_scrim_%s", side))
	d := frame_new(Strip_Scrim)
	d^ = {under = box_under(outer), left = left}
	scrim.custom, scrim.custom_user = strip_scrim_draw, d
	glyph := left ? lucide.CHEVRON_LEFT : lucide.CHEVRON_RIGHT
	next({fixed_x = x, fixed_y = 0, width = px(sb.arrow_w), height = pct(1), font = lucide_icons(), font_size = math.round(em * STRIP_GLYPH_EM), text_pad = 0, text_align = .Center})
	push_tags("ghost_button", "button", "weak")
	b := build_box({.Clickable, .Draw_Text, .Draw_Background, .Draw_Hot_Effects, .No_Text_Trunc}, fmt.tprintf("%s###strip_%s", glyph, side))
	pop_tags()
	a11y_default(b, {role = .Button, name = left ? i18n.tr("Scroll left") : i18n.tr("Scroll right")})
	if !left { sb.right, sb.right_scrim = b.key, scrim.key }
	if repeat_pressed(signal(b)) { strip_step(sb^, view, dir) }
}

// One step of an arrow toward `dir`, against the view's target (a click during a glide goes one item further). Item: the
// first item past the clear part of the view (the view less its fades) lands just inside it. Page: the clear part.
@(private = "file")
strip_step :: proc(sb: Strip_Build, view: ^Box, dir: int) {
	s := gs()
	w := view.size.x
	t := view.view_target.x
	limit := view_limit(view, .X)
	to := dir > 0 ? limit : 0   // (nothing hidden past the clear part: the end)
	switch sb.step {
	case .Page:
		to = t + f32(dir) * max(w - 2 * sb.fade, w * 0.5)
	case .Item:
		lo, hi := t + sb.fade, t + w - sb.fade
		// (the items as the last layout placed them, in the content's coordinates; one new in this build has no place yet)
		if dir > 0 {
			for c := view.first; c != nil; c = c.next {
				if is_floating(c, .X) || c.first_build == s.build_index { continue }
				x0 := c.rect.min.x - view.rect.min.x + view.view_off.x
				x1 := x0 + (c.rect.max.x - c.rect.min.x)
				if x1 > hi + STRIP_HIDDEN_PX { to = view_reveal_offset(t, x0, x1, w, sb.fade); break }
			}
		} else {
			for c := view.last; c != nil; c = c.prev {
				if is_floating(c, .X) || c.first_build == s.build_index { continue }
				x0 := c.rect.min.x - view.rect.min.x + view.view_off.x
				x1 := x0 + (c.rect.max.x - c.rect.min.x)
				if x0 < lo - STRIP_HIDDEN_PX { to = view_reveal_offset(t, x0, x1, w, sb.fade); break }
			}
		}
	}
	view.view_target.x = clamp(to, 0, limit)
}

// After the build's layout and its scroll step: the right arrow at the right edge of this layout (a strip that changed
// width has it there in this frame), and one more build when a side's arrow is not the one built.
@(private)
strips_settle :: proc(s: ^State) {
	for sb in s.strips {
		view := s.boxes[sb.view]
		outer := s.boxes[sb.outer]
		if view == nil || outer == nil { continue }
		before, after := strip_hides(view)
		if before != sb.before || after != sb.after { s.anim_busy = true }
		if !sb.after { continue }
		for k in ([2]Key{sb.right, sb.right_scrim}) {
			b := s.boxes[k]
			if b == nil { continue }
			d := math.round(outer.rect.max.x - sb.arrow_w) - b.rect.min.x
			b.rect.min.x += d
			b.rect.max.x += d
		}
	}
}

// The view of the strip built last in the current parent with `id` (nil: none): what a test or a tool reads, and where a
// program's role for its items goes (a tab list's).
strip_view :: proc(id: string) -> ^Box {
	outer := prev_box(id)
	if outer == nil { return nil }
	return box_from_key(key_from_string(outer.key, "###strip_view"))
}
