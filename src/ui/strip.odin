package ui

// A strip (docs/strip.md; its reasons: src/md/features/strip.md): a row, a column or a block of choices (tabs, chips,
// a sidebar's buttons) that scrolls when its choices do not fit. No scroll bar: on each side that hides choices an arrow
// button lies over the edge, and the content fades out beyond it.
//
//   `if ui.strip("###id", {axes = {.Y}}) { choices }`
//
// The implicit state machine of each side (left, right, up, down): choices hidden past it (by the view's offset and
// bounds) -> its arrow shows; none -> it is hidden. Every arrow is built at every build; which show is decided right
// after the layout, from the layout that is drawn (strips_place), so the first frame a strip is in is right, and checked
// again after the scroll step (strips_settle): a change asks for one more build. Its least size is the layout's too
// (strip_least, from the choices' sizes of that layout). One code path for both axes: every value along an axis is
// indexed by the axis.

import "core:fmt"
import "core:math"
import "../i18n"
import "../lucide"

// What a click on an arrow moves: the next hidden choice fully in view (Item), or the clear part of the view (Page: a
// long strip of small choices).
Strip_Step :: enum u8 { Item, Page }

Strip_Options :: struct {
	axes: bit_set[Axis],   // the axes it scrolls along: {.X} (also {}), {.Y}, or {.X, .Y} (a block of choices)
	step: Strip_Step,
	fade: f32,             // how far the content fades out beyond an arrow, ems (0: STRIP_FADE_EM)
}

// How far the content fades out beyond an arrow, ems: the choice that comes out from under it does not start hard.
STRIP_FADE_EM :: 1.0
@(private = "file") STRIP_ARROW_EM :: 1.6         // an arrow button's thickness along its axis
@(private = "file") STRIP_GLYPH_EM :: 0.9         // its chevron's size
@(private = "file") STRIP_ARROW_RADIUS_EM :: 0.3  // its plate's corners (its hover shows them)
// Between an arrow's plate and the first pixel of content, nothing but the strip's surface: a choice cut at the arrow
// (a raised plate's tail, its glyph) never looks glued to it, the fade only begins past this gap.
STRIP_GAP_EM :: 0.3
@(private = "file") STRIP_HIDDEN_PX :: 0.5        // an offset this close to an end is that end
// A choice cut by an arrow's band that shows less than this (ems) before it is held whole: its sliver would show its
// outline and none of its words.
STRIP_SLIVER_EM :: 1.5

// A strip in the build, from strip to strips_settle. A side is [axis][0]: its start (left, up), [axis][1]: its end.
@(private)
Strip_Build :: struct {
	outer, view: Key,
	axes:        bit_set[Axis],
	shown:       [Axis][2]bool,   // the arrows that show, by the layout drawn (strips_place)
	arrows:      [Axis][2]Key,    // their boxes, all built: strips_place puts each on its edge, or hides it
	arrow, gap, fade: f32,       // an arrow's thickness, the clear gap beyond it, the fade beyond that
	step:        Strip_Step,
	reveal:      Key,             // a choice to bring into view this build (strip_reveal)
}

// `if strip("###id", o) { choices }`: a strip. With no size given (next) along an axis it scrolls, as long as its
// choices and the first to give way in a parent that is short, never under its largest choice and an arrow; a size given
// is kept. Across, as large as its parent: give the row (the column) a size of its own. Its choices are the clickable
// boxes built in it, at any depth (a choice's own parts are not choices); none clickable: the boxes built directly in it.
@(require_results, deferred_none = strip_end)
strip :: proc(id: string, o := Strip_Options{}) -> bool {
	s := gs()
	em := font_size()
	axes := o.axes == bit_set[Axis]{} ? bit_set[Axis]{.X} : o.axes
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = .X in axes ? children_sum(0) : pct(1) }
	if m.height == nil { m.height = .Y in axes ? children_sum(0) : pct(1) }
	// (its choices in a row on X alone, else in a column: a block's rows one under the other)
	lay := m.axis.? or_else (axes == bit_set[Axis]{.X} ? Axis.X : Axis.Y)
	cross := m.cross.? or_else Cross_Align.Center
	m.axis = lay
	m.cross = cross
	s.next_mod, s.has_next = m, true
	// (its key only: a strip shows no words of its own, whatever the id says)
	outer := build_box({}, fmt.tprintf("###%s", hash_part(id)))
	push_parent(outer)
	// (the view takes the strip's size: its choices' when the strip hugs them, which it then gives up first)
	size :: proc(outer: ^Box, a: Axis, scrolled: bool) -> Size {
		return outer.pref[a].kind == .Children_Sum ? children_sum(scrolled ? 0 : 1) : pct(1)
	}
	flags := Box_Flags{.Clip, .Scrollbar_None, .Strip_Wheel}
	if .X in axes { flags += {.View_Scroll_X, .Allow_Overflow_X} }
	if .Y in axes { flags += {.View_Scroll_Y, .Allow_Overflow_Y} }
	next({width = size(outer, .X, .X in axes), height = size(outer, .Y, .Y in axes), axis = lay, cross = cross})
	view := build_box(flags, "###strip_view")
	_ = signal(view)
	sb := Strip_Build{outer = outer.key, view = view.key, axes = axes, step = o.step}
	sb.arrow = math.round(em * STRIP_ARROW_EM)
	sb.gap = math.round(em * STRIP_GAP_EM)
	sb.fade = math.round((o.fade > 0 ? o.fade : STRIP_FADE_EM) * em)
	view.strip_arrow = sb.arrow   // (the layout keeps its least: strip_least)
	append(&s.strip_stack, sb)
	push_parent(view)
	return true
}

// In a strip's block, at each build: `b` is the chosen choice (the tab shown). Each time the chosen one changes, and in
// the strip's first frame, it is in view along each axis the strip scrolls, clear of its arrows and fades, in that very
// frame (strips_place moves the view after the layout): a tab opened or picked elsewhere (a command, the "+") is not left
// hidden, and the first frame shows it. Not at every build: the person scrolls away from it freely.
// The keyboard's focus reveals its choice by itself.
strip_reveal :: proc(b: ^Box) {
	s := gs()
	if b == nil || len(s.strip_stack) == 0 { return }
	s.strip_stack[len(s.strip_stack) - 1].reveal = b.key
}

@(private)
strip_end :: proc() {
	s := gs()
	pop_parent()   // (the view)
	sb := pop(&s.strip_stack)
	view := s.boxes[sb.view]
	outer := s.boxes[sb.outer]
	choices := strip_choices_of(view)
	// (every arrow, every build: which show is the layout's to say, strips_place)
	for a in sb.axes {
		for end in 0 ..< 2 { strip_arrow(&sb, view, outer, choices, a, end) }
	}
	append(&s.strips, sb)
	pop_parent()   // (the strip)
}

// The choices of a strip's view: the clickable boxes in it, not those inside a choice, nor what floats; none clickable:
// the boxes built directly in it. In the frame's memory.
@(private = "file")
strip_choices_of :: proc(view: ^Box) -> []^Box {
	walk :: proc(b: ^Box, out: ^[dynamic]^Box) {
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, .X) || is_floating(c, .Y) { continue }
			if .Clickable in c.flags { append(out, c); continue }
			walk(c, out)
		}
	}
	choices := make([dynamic]^Box, 0, 16, context.temp_allocator)
	walk(view, &choices)
	if len(choices) == 0 {
		for c := view.first; c != nil; c = c.next { if !is_floating(c, .X) && !is_floating(c, .Y) { append(&choices, c) } }
	}
	return choices[:]
}

// The layout (layout_downward, once the view's choices have their sizes along `a`): a strip gives way first, but never
// under its largest choice and an arrow, nor over its choices: smaller, no choice shows whole and a press meant for one
// lands beside the strip. Its view and its strip keep that least in the very layout that first lays them out (the last
// layout's measures are none at a strip's first build: it gave way to nearly nothing for a frame). A size in pixels is
// the caller's.
// A choice that gives way (a tab's words cut down to their least, strip_give) counts at what it keeps.
@(private)
strip_least :: proc(view: ^Box, a: Axis) {
	outer := view.parent
	if outer == nil || outer.pref[a].kind == .Pixels { return }
	i := int(a)
	largest, content: f32
	for c in strip_choices_of(view) { largest = max(largest, c.size[i] - shrinkable(c, a)) }
	for c := view.first; c != nil; c = c.next {
		if is_floating(c, a) { continue }
		keep := c.size[i] - shrinkable(c, a)
		if view.layout_axis == a { content += keep } else { content = max(content, keep) }
	}
	least := min(content, largest + view.strip_arrow)
	for b in ([2]^Box{view, outer}) {
		b.pref[a].least = max(b.pref[a].least, least)
		b.size[i] = max(b.size[i], least)
	}
}

// The layout (layout_violations, along the view's own axis): choices too long for the view give way first, each by
// what it may give (shrinkable: a tab's words down to their least, cut with an ellipsis), in proportion to it; what
// is still too long scrolls. A strip of tabs then shows every tab, narrower, before an arrow hides any; a choice that
// keeps its size (a chip, a button's words) gives nothing.
@(private)
strip_give :: proc(view: ^Box, a: Axis) {
	i := int(a)
	avail := view.size[i] - content_pad(view, a) - stack_gaps(view, a)
	total, budget: f32
	for c := view.first; c != nil; c = c.next {
		if is_floating(c, a) { continue }
		total += c.size[i]
		budget += shrinkable(c, a)
	}
	violation := total - avail
	if violation <= STRIP_HIDDEN_PX || budget <= 0 { return }
	take := min(violation, budget)
	for c := view.first; c != nil; c = c.next {
		if is_floating(c, a) { continue }
		c.size[i] -= take * shrinkable(c, a) / budget
	}
}

// Whether the view hides choices before its start and after its end along `a` (by its offset and its last layout).
@(private = "file")
strip_hides :: proc(view: ^Box, a: Axis) -> (before, after: bool) {
	off, limit := view.view_off[int(a)], view_limit(view, a)
	return off > STRIP_HIDDEN_PX, off < limit - STRIP_HIDDEN_PX
}

// A side's chevron, its name for a screen reader and its box's name: `end` 0 is the start of axis `a`, 1 its end.
@(private = "file")
strip_side :: proc(a: Axis, end: int) -> (glyph, name, side: string) {
	switch {
	case a == .X && end == 0: return lucide.CHEVRON_LEFT, i18n.tr("Scroll left"), "left"
	case a == .X:             return lucide.CHEVRON_RIGHT, i18n.tr("Scroll right"), "right"
	case end == 0:            return lucide.CHEVRON_UP, i18n.tr("Scroll up"), "up"
	}
	return lucide.CHEVRON_DOWN, i18n.tr("Scroll down"), "down"
}

// Where a side's arrow is in the strip `r` (window pixels): across the whole strip, short of the other axis's arrows'
// corners when it scrolls both ways, as thick as an arrow along `a`.
@(private = "file")
strip_arrow_rect :: proc(sb: Strip_Build, r: Rect, a: Axis, end: int) -> (q: Rect) {
	i, j := int(a), 1 - int(a)
	inset := sb.axes == bit_set[Axis]{.X, .Y} ? sb.arrow : 0
	q.min[i] = end == 1 ? math.round(r.max[i] - sb.arrow) : r.min[i]
	q.max[i] = q.min[i] + sb.arrow
	q.min[j] = r.min[j] + inset
	q.max[j] = max(q.min[j], r.max[j] - inset)
	return
}

// An arrow over a side of the strip: a small button of the strip's surface, opaque, its chevron in the middle, a hover
// plate. Not a Tab stop (the choices are), a name for a screen reader and no tooltip; held, it repeats.
@(private = "file")
strip_arrow :: proc(sb: ^Strip_Build, view, outer: ^Box, choices: []^Box, a: Axis, end: int) {
	em := font_size()
	// (placed by the last layout: strips_place puts it on this layout's edge, or hides it)
	q := strip_arrow_rect(sb^, {{0, 0}, outer.size}, a, end)
	glyph, name, side := strip_side(a, end)
	// (one ink for every arrow, at rest and under the pointer: the text's of where the strip is, read before the
	// arrow's tags. The weak ink, lit as "hot text" under the pointer, made the arrow at rest look faint beside the one
	// just clicked; the hover says itself by its plate)
	ink := color("text")
	next({fixed_x = q.min.x, fixed_y = q.min.y, width = px(q.max.x - q.min.x), height = px(q.max.y - q.min.y), font = lucide_icons(),
		font_size = math.round(em * STRIP_GLYPH_EM), text_pad = 0, text_align = .Center, radius = math.round(em * STRIP_ARROW_RADIUS_EM), bg = box_under(outer), fg = ink})
	push_tags("ghost_button", "button")
	b := build_box({.Clickable, .Draw_Text, .Draw_Background, .Draw_Hot_Effects, .No_Text_Trunc}, fmt.tprintf("%s###strip_%s", glyph, side))
	pop_tags()
	a11y_default(b, {role = .Button, name = name})
	sb.arrows[a][end] = b.key
	if repeat_pressed(signal(b)) { strip_step(sb^, view, choices, a, end == 1 ? 1 : -1) }
}

// One step of an arrow along `a` toward `dir`, against the view's target (a click during a glide goes one choice
// further). Item: the nearest choice that the arrow covers or that lies past it lands wholly in the clear part of the
// view (the view less the arrow and the fade at each side), at its far end. Page: the clear part. A choice only in the
// fade counts as shown: taking it moved the view by a few pixels, and the click must show what the arrow hid.
@(private = "file")
strip_step :: proc(sb: Strip_Build, view: ^Box, choices: []^Box, a: Axis, dir: int) {
	s := gs()
	i := int(a)
	w := view.size[i]
	t := view.view_target[i]
	limit := view_limit(view, a)
	edge := sb.arrow + sb.gap + sb.fade
	room := w - 2 * edge   // (the clear part)
	to := dir > 0 ? limit : 0   // (nothing hidden past the arrow: the end)
	switch sb.step {
	case .Page:
		to = t + f32(dir) * max(room, w * 0.5)
	case .Item:
		found := false
		for c in choices {
			if c.first_build == s.build_index { continue }   // (no place yet)
			x0 := c.rect.min[i] - view.rect.min[i] + view.view_off[i]
			x1 := x0 + (c.rect.max[i] - c.rect.min[i])
			long := x1 - x0 > room   // (longer than the clear part: its start at the start of it)
			if dir > 0 {
				if x1 <= t + w - (sb.arrow + sb.gap) + STRIP_HIDDEN_PX { continue }   // (the arrow and its gap show nothing)
				at := long ? x0 - edge : x1 - (w - edge)
				if at > t + STRIP_HIDDEN_PX && (!found || at < to) { to, found = at, true }
			} else {
				if x0 >= t + sb.arrow + sb.gap - STRIP_HIDDEN_PX { continue }
				at := long ? x1 - (w - edge) : x0 - edge
				if at < t - STRIP_HIDDEN_PX && (!found || at > to) { to, found = at, true }
			}
		}
	}
	view.view_target[i] = clamp(to, 0, limit)
}

// strips_place, by this layout: when the strip is new or its chosen choice (strip_reveal) changed, the view moves to show
// that choice clear of the arrows and the fades, and the boxes in it move by as much, in this very layout: the first frame
// drawn shows the chosen tab. Done at the build, the rects were the last layout's, none at a first build: the strip
// showed its start for a frame, then jumped, and a click in that frame landed on another tab. A jump, no glide: what the
// person sees first, or a choice made elsewhere (a command, the "+"), is where it is.
@(private = "file")
strip_bring :: proc(s: ^State, sb: Strip_Build, view: ^Box) {
	// (a strip whose room changed, a window or a zone resized, shows its chosen choice again: narrowed, it was left
	// behind an arrow)
	if sb.reveal == 0 || (sb.reveal == view.strip_chosen && view.size == view.strip_room) { return }
	c := s.boxes[sb.reveal]
	if c == nil || c.last_build != s.build_index { return }
	inside := false
	for p := c.parent; p != nil; p = p.parent { if p == view { inside = true; break } }
	if !inside { return }   // (not a choice of this strip: nothing to show)
	view.strip_chosen, view.strip_room = sb.reveal, view.size
	for a in sb.axes {
		i := int(a)
		off := view.view_off[i]
		x0 := c.rect.min[i] - view.rect.min[i] + off
		x1 := x0 + (c.rect.max[i] - c.rect.min[i])
		to := clamp(view_reveal_offset(off, x0, x1, view.size[i], sb.arrow + sb.gap + sb.fade), 0, view_limit(view, a))
		d := math.round(to - off)   // (whole pixels: the boxes' rects are)
		if d == 0 { continue }
		view_jump(view, off + d, a)
		strip_shift(view, i, d)
	}
}

// The boxes under `b` laid out again `d` further along axis `i`: the view scrolled by `d` after the layout.
@(private = "file")
strip_shift :: proc(b: ^Box, i: int, d: f32) {
	for c := b.first; c != nil; c = c.next {
		c.rect.min[i] -= d
		c.rect.max[i] -= d
		strip_shift(c, i, d)
	}
}

// Right after the build's layout (end_build), before anything reads the rects or draws: by the layout that is drawn,
// each side that hides choices shows its arrow on its edge, nothing of the content under it (edge_hold) and the fade
// beyond it; an arrow of a side that hides nothing is hidden (no place, no press, nothing drawn, nothing read aloud).
// So the first frame a strip is in has its arrows, as every later one.
@(private)
strips_place :: proc(s: ^State) {
	for &sb in s.strips {
		view := s.boxes[sb.view]
		outer := s.boxes[sb.outer]
		if view == nil || outer == nil { continue }
		strip_bring(s, sb, view)   // (before the arrows: they follow the offset it gives)
		for a in sb.axes {
			i := int(a)
			sb.shown[a][0], sb.shown[a][1] = strip_hides(view, a)
			for end in 0 ..< 2 {
				side := i + 2 * end   // (edge_hold and edge_fade: left, top, right, bottom)
				view.edge_hold[side], view.edge_fade[side] = 0, 0
				// (the band held clear: the arrow and the gap beyond it; the fade begins past them)
				if sb.shown[a][end] {
					view.edge_hold[side], view.edge_fade[side] = sb.arrow + sb.gap, sb.fade
					if hold, cut := strip_sliver(view, sb, a, end); cut { view.edge_hold[side], view.edge_fade[side] = hold, 0 }
				}
				b := s.boxes[sb.arrows[a][end]] if sb.arrows[a][end] != 0 else nil
				if b == nil { continue }
				q := strip_arrow_rect(sb, outer.rect, a, end)
				if sb.shown[a][end] {
					b.rect = q
				} else {
					b.rect = {q.min, q.min}
					b.flags -= {.Clickable}
					b.transparency = 1
					if b.a11y != nil { b.a11y.ignore = true }
				}
			}
		}
	}
}

// The band a side holds clear when a choice cut by its arrow would show only a sliver before it (less than
// STRIP_SLIVER_EM): the band reaches over that choice whole, with no fade (its sliver, all in the fade, showed an
// empty outline: a tab's rim and none of its words).
@(private = "file")
strip_sliver :: proc(view: ^Box, sb: Strip_Build, a: Axis, end: int) -> (hold: f32, cut: bool) {
	i := int(a)
	band := sb.arrow + sb.gap
	least := math.round(font_size() * STRIP_SLIVER_EM)
	for c in strip_choices_of(view) {
		if end == 1 {
			at := view.rect.max[i] - band
			if c.rect.min[i] < at && c.rect.max[i] > at && at - c.rect.min[i] < least {
				return view.rect.max[i] - c.rect.min[i], true
			}
		} else {
			at := view.rect.min[i] + band
			if c.rect.min[i] < at && c.rect.max[i] > at && c.rect.max[i] - at < least {
				return c.rect.max[i] - view.rect.min[i], true
			}
		}
	}
	return
}

// After the scroll step: one more build when the offset the next build lays out makes a side's arrow come or go.
@(private)
strips_settle :: proc(s: ^State) {
	for sb in s.strips {
		view := s.boxes[sb.view]
		if view == nil { continue }
		for a in sb.axes {
			before, after := strip_hides(view, a)
			if before != sb.shown[a][0] || after != sb.shown[a][1] { s.anim_busy = true }
		}
	}
}

// The view of the strip built last in the current parent with `id` (nil: none): what a test or a tool reads, and where a
// program's role for its choices goes (a tab list's).
strip_view :: proc(id: string) -> ^Box {
	outer := prev_box(id)
	if outer == nil { return nil }
	return box_from_key(key_from_string(outer.key, "###strip_view"))
}
