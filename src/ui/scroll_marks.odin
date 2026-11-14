package ui

// Marks on the vertical scroll bar of a view, as the overview ruler at the side of a code editor: a short bar across the
// track for each item that counts (a prompt in a conversation, a heading in a document, a day in a journal), at the height
// where the item stands in the content. The marks within the thumb's span are drawn over it, a little brighter: where the view
// is among them. Marks closer than a pitch (6 px) are drawn as one.
//
// The bar is wider than a plain one, and widens more under the pointer. The pointer over a mark makes it larger and shows
// its card: the item's name ("#12"), when it was made ("today 14:32") and its first lines; a merged mark's card has a line
// for each of its items (its name, its first line, its time); a press on a mark puts its item at the view's top at once (no glide:
// a long glide over a long content is a wait). A mark under the thumb is the thumb's: a press there drags it, as a press
// on the track away from any mark does what it does on every bar. The keyboard (once a mark was pressed, or Tab to the
// marks' button): Up and Down go from mark to mark (Home, End: the first, the last), Enter or Space jumps. A button above
// the bar (a magnifier), or a character typed while the marks have the keyboard, opens a filter: only the marks whose text
// holds every word typed stay.
//
//   marks: ui.Scroll_Marks                                    // the program's, kept between builds
//   if ui.scroll_marks_stale(&marks, version) {               // the items changed: a version of the program's
//       ui.scroll_marks_set(&marks, version, items)           // copied (texts and ids)
//   }
//   if i := ui.scroll_marks("###marks", &marks, ui.prev_box("###doc")); i >= 0 { focus(ui.scroll_marks_id(&marks, i)) }
//   if ui.scroll_y("###doc") {
//       lz := ui.lazy_begin()
//       k := 0
//       for item in items {
//           if item.marked { ui.scroll_marks_place(&marks, k, lz.y); k += 1 }   // where it starts in the content
//           if ui.lazy_item(lz, item.id) { ... }
//       }
//   }
//
// What it costs: the marks are copied and filtered only when they or the filter change; they are merged only when they,
// their places, the filter, the content's height or the bar's length change. A build reads only the marks near the pointer
// (a binary search). The drawing reads each merged mark once: no more than the bar has room for.
//
// Give them before the view's content (before the view, with prev_box, or first in it): a jump then builds the content at
// its new place in the same build.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import "../font"
import i18n "../i18n"
import "../timefmt"

// A mark given to the bar.
Scroll_Mark :: struct {
	id:      string,   // what the program calls its item (scroll_marks_id gives it back); copied
	text:    string,   // what the item says: its first lines show under the pointer, the filter reads all of it; copied
	label:   string,   // its short name, first on its card ("#12"; "": none); copied
	time_ms: f64,      // when the item was made, ms since 1970 (UTC): on its card, as timefmt.moment says it (0: none)
	weak:    bool,     // a lesser mark: shorter and fainter
}

// A mark as it is kept: its texts owned, and its place in the content at the last build that gave one (-1: none yet).
@(private)
Scroll_Mark_Kept :: struct {
	id, text, line, label: string,   // (line: the first line of text that says something, a slice of it)
	time_ms: f64,
	weak: bool,
	top:  f32,
}

// Marks shown that would overlap on the bar, drawn as one: `first` ..= `last` of `shown`, from `y0` to `y1` down the
// track (pixels from its top).
@(private)
Scroll_Mark_Group :: struct {
	first, last: int,
	y0, y1:      f32,
	weak:        bool,   // all of them weak
}

// What the groups were made for: made again when it changes.
@(private)
Scroll_Marks_Merged :: struct {
	placed, filtered: u64,
	track, content, gap: f32,
}

// The marks' state, the program's to keep (zero is no marks). scroll_marks_destroy frees it. Keep it while its view is built.
Scroll_Marks :: struct {
	marks:       [dynamic]Scroll_Mark_Kept,
	version:     u64,
	made:        bool,
	filter:      Line_Edit,
	filtering:   bool,           // the filter's field is open
	query:       string,         // the filter `shown` was made for (owned)
	shown:       [dynamic]int,   // the marks the filter keeps, in their order
	current:     int,            // the mark of the keyboard, and the last one jumped to (-1: none; at first the first)
	hot:         int,            // the mark under the pointer at this build (-1: none)
	focus_field: bool,           // the field takes the keyboard when it is next built
	head:        f32,            // the room above the bar for the filter's button, pixels (scrollbar_parts)
	head_key:    Key,            // the button: the marks' keyboard stop
	field_key:   Key,
	groups:      [dynamic]Scroll_Mark_Group,
	merged:      Scroll_Marks_Merged,
	placed:      u64,            // counts the changes of places (scroll_marks_place)
	filtered:    u64,            // counts the changes of `shown`
}

Scroll_Marks_Options :: struct {
	name:   string,   // what a screen reader calls the marks ("": "Marks")
	margin: f32,      // pixels left above an item the view jumps to (0: half a line)
	// The clock the marks' times are read on (timefmt.moment, on timefmt.local_offset_minutes): now (ms since 1970, UTC;
	// 0: their dates shown whole), on 12 hours.
	now_ms:  f64,
	hours12: bool,
}

// The bar with marks: its width at rest, and under the pointer or with the keyboard.
@(private = "file") SCROLL_MARKS_BAR_EM :: 0.7
@(private = "file") SCROLL_MARKS_BAR_WIDE_EM :: 1.05
@(private = "file") SCROLL_MARKS_HEAD_EM :: 1.05      // the filter's button, square, above the bar
// A mark: thin, short of the track's sides, so that many of them read as ticks and not as a striped column
@(private = "file") SCROLL_MARKS_THICK_PX :: 2
@(private = "file") SCROLL_MARKS_INSET_PX :: 2        // from each side of the track
@(private = "file") SCROLL_MARKS_WEAK_INSET :: 0.3    // a weak mark: this much of the track's width left out on each side
@(private = "file") SCROLL_MARKS_PITCH_PX :: 6        // marks closer than this are one: at most one a pitch
@(private = "file") SCROLL_MARKS_HOT_THICK :: 2       // the mark under the pointer or the keyboard's: this many times as tall, across the whole track
@(private = "file") SCROLL_MARKS_REACH_EM :: 0.5      // a press this near a mark is on it
@(private = "file") SCROLL_MARKS_ALPHA :: 0.45        // of the accent: muted, the window has other things to say
@(private = "file") SCROLL_MARKS_WEAK_ALPHA :: 0.25
@(private = "file") SCROLL_MARKS_IN_VIEW_ALPHA :: 0.7 // the marks within the thumb's span: where the view is reads among them
@(private) SCROLL_MARKS_TRACK_REST :: 0.6             // the track at rest, of its look under the pointer
@(private = "file") SCROLL_MARKS_TIP_LINES :: 5       // a merged mark's card: a line for this many of its items
@(private = "file") SCROLL_MARKS_CARD_LINES :: 3      // a mark's card: the first lines of its text
@(private = "file") SCROLL_MARKS_CARD_EM :: 22        // a card's text, at most
@(private = "file") SCROLL_MARKS_CARD_PAD_EM :: 0.7   // around it
@(private = "file") SCROLL_MARKS_CARD_SMALL :: 0.85   // its name and its time, of the font size
@(private = "file") SCROLL_MARKS_FILTER_EM :: 16      // the filter's field
@(private = "file") SCROLL_MARKS_GAP_EM :: 0.5        // between the bar and its tooltip or field
@(private = "file") SCROLL_MARKS_MARGIN_EM :: 0.5
@(private = "file") SCROLL_MARKS_HEAD_RADIUS_EM :: 0.25

scroll_marks_destroy :: proc(k: ^Scroll_Marks) {
	marks_free(k)
	delete(k.marks)
	delete(k.shown)
	delete(k.groups)
	delete(k.query)
	line_edit_destroy(&k.filter)
	k^ = {}
}

// The marks kept are not those of `version`: give them with scroll_marks_set.
scroll_marks_stale :: proc(k: ^Scroll_Marks, version: u64) -> bool { return !k.made || k.version != version }

// The marks of `version`, in the order of their items in the content (copied). Their places come with scroll_marks_place.
scroll_marks_set :: proc(k: ^Scroll_Marks, version: u64, marks: []Scroll_Mark) {
	marks_free(k)
	clear(&k.marks)
	for m in marks {
		text := strings.clone(m.text)
		append(&k.marks, Scroll_Mark_Kept{id = strings.clone(m.id), text = text, line = marks_first_line(text), label = strings.clone(m.label), time_ms = m.time_ms, weak = m.weak, top = -1})
	}
	k.version, k.made = version, true
	k.current = min(k.current, len(k.marks) - 1)
	k.hot = -1
	k.placed += 1
	marks_filter(k)
}

// Where mark `i` starts in the content of the view, at this build (a lazy column's `y` before its item, a box's top in
// the content). A mark out of range is passed over (the marks of an older version).
scroll_marks_place :: proc(k: ^Scroll_Marks, i: int, top: f32) {
	if i < 0 || i >= len(k.marks) || k.marks[i].top == top { return }
	k.marks[i].top = top
	k.placed += 1
}

// The id the program gave mark `i` ("" out of range).
scroll_marks_id :: proc(k: ^Scroll_Marks, i: int) -> string { return i >= 0 && i < len(k.marks) ? k.marks[i].id : "" }

// The marks the filter keeps, by their index, in order.
scroll_marks_shown :: proc(k: ^Scroll_Marks) -> []int { return k.shown[:] }

// The filter's text.
scroll_marks_query :: proc(k: ^Scroll_Marks) -> string { return line_edit_string(&k.filter) }

// Where mark `i` is on the bar of `view`, in window pixels, by the last layout (ok = false: the mark is not shown, has no
// place yet, or the view's bar does not show these marks). For tests and tools: a press there is on it, unless the thumb is
// over it.
scroll_marks_at :: proc(k: ^Scroll_Marks, view: ^Box, i: int) -> (at: Vec2, ok: bool) {
	if view == nil || scroll_marks_of(view) != k || view.view_bounds.y <= 0 || i < 0 || i >= len(k.marks) || k.marks[i].top < 0 || marks_shown_at(k, i) < 0 { return }
	_, track, _, _, has := scrollbar_parts(view)
	if !has { return }
	return {(track.min.x + track.max.x) * 0.5, marks_y(track, k.marks[i].top, view.view_bounds.y)}, true
}

// The marks `k` on the vertical bar of the scroll box `view` (the last build's, prev_box, or the one being built), and
// their filter's button above it, `id`. The index of the mark the view jumped to in this build, -1 none: the program
// gives its item the keyboard if it wants. Tags used: "scroll_marks"; its field "input".
scroll_marks :: proc(id: string, k: ^Scroll_Marks, view: ^Box, o := Scroll_Marks_Options{}) -> (jumped: int) {
	s := gs()
	jumped = -1
	k.hot = -1
	if line_edit_string(&k.filter) != k.query { marks_filter(k) }
	k.current = min(k.current, len(k.marks) - 1)   // (a zero Scroll_Marks has none, its current 0)
	if view == nil || .View_Scroll_Y not_in view.flags { return }
	em := view.font_size
	_, m := scrollbar_size(em)
	head_w := math.round(em * SCROLL_MARKS_HEAD_EM)
	k.head = head_w + m
	view.bar_marks, view.bar_marks_build = k, s.build_index
	bar, track, _, _, ok := scrollbar_parts(view)
	if !ok {
		// (all of it in view: no bar, no marks)
		k.head_key, k.field_key = 0, 0
		return
	}
	content := view.view_bounds.y
	margin := o.margin > 0 ? o.margin : math.round(em * SCROLL_MARKS_MARGIN_EM)
	left := .Scrollbar_Left in view.flags
	sbk := scrollbar_key(view)

	// the filter's button above the bar, built at the root (over the view, which it is not part of): the marks' own box, the
	// keyboard's stop and what a screen reader reads. (Scroll_Self: the wheel over it is the view's)
	head := Rect{{left ? bar.min.x : bar.max.x - head_w, view.rect.min.y + m}, {}}
	head.max = head.min + head_w
	push_parent(s.root)
	push_tags("scroll_marks")
	next({fixed_x = head.min.x, fixed_y = head.min.y, width = px(head_w), height = px(head_w), radius = em * SCROLL_MARKS_HEAD_RADIUS_EM})
	hb := build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Scroll_Self}, id)
	pop_tags()
	pop_parent()
	k.head_key = hb.key
	field_key := key_from_string(marks_field_parent_key(hb), "###field")
	k.field_key = field_key
	sig := signal(hb)
	held := s.active_key[.Left] == hb.key
	if sig.scrolled.y != 0 {
		view.view_target.y = clamp(view.view_target.y + scroll_view_delta(s).y * wheel_step(view, .Y), 0, view_limit(view))
	}
	toggled := false
	if sig.pointer_clicked {
		toggled = true
		k.filtering = !k.filtering
		if k.filtering { k.focus_field = true } else { line_edit_clear(&k.filter); s.focus_key = hb.key }
	}

	// the pointer on the bar: the mark under it; a press on one goes there (the bar left that press to it: scrollbar_press)
	if s.hot_key == sbk { k.hot = scroll_marks_hit(k, view, s.mouse) }
	if s.pressed_key[.Left] == sbk && s.sb_on_mark && k.hot >= 0 {
		jumped = k.hot
		k.current = k.hot
		marks_jump(view, k.marks[k.hot].top, margin)
		s.focus_key = hb.key   // (the keyboard goes on from there)
	}

	// the keyboard, on the button or in the field
	in_field := s.focus_key == field_key && k.filtering
	if sig.focused || in_field {
		if step := marks_key_step(); step != 0 { k.current = marks_step(k, step) }
		if key_press(.Home) && sig.focused && len(k.shown) > 0 { k.current = k.shown[0] }
		if key_press(.End) && sig.focused && len(k.shown) > 0 { k.current = k.shown[len(k.shown) - 1] }
	}
	if sig.focused && sig.pressed && !sig.pointer_pressed && k.current >= 0 {
		jumped = k.current
		marks_jump(view, k.marks[k.current].top, margin)
	}
	if sig.focused && !k.filtering {
		// a character typed on the marks opens their filter, which takes it
		for c in s.typed {
			if c >= ' ' && c != 0x7f && .Ctrl not_in s.typed_mods && .Alt not_in s.typed_mods { k.filtering, k.focus_field = true, true; break }
		}
	}
	if sig.focused && key_press(.Escape) && marks_query_text(k) != "" { line_edit_clear(&k.filter) }

	// the filter's field, over the content beside the button
	if k.filtering {
		w := math.round(em * SCROLL_MARKS_FILTER_EM)
		gap := math.round(em * SCROLL_MARKS_GAP_EM * 0.5)
		push_parent(s.root)
		next({fixed_x = left ? head.max.x + gap : head.min.x - gap - w, fixed_y = head.min.y, width = px(w), height = children_sum(), axis = .Y})
		frame := build_box({}, marks_field_id(hb))
		if parent(frame) {
			if k.focus_field { s.focus_key = field_key; k.focus_field = false }
			next({width = fill()})
			res := line_edit("###field", &k.filter, {placeholder = i18n.tr("Filter"), clearable = true})
			if res.committed && k.current >= 0 {
				jumped = k.current
				marks_jump(view, k.marks[k.current].top, margin)
			}
			if res.cancelled {
				line_edit_clear(&k.filter)
				k.filtering = false
				s.focus_key = hb.key
			}
			// (left with nothing in it, it closes; with a query it stays, for what it keeps. Not while its button is held:
			// the press took the keyboard, and the click that follows closes it)
			if k.filtering && s.focus_key != field_key && !toggled && !held && marks_query_text(k) == "" {
				k.filtering = false
			}
		}
		pop_parent()
	}
	if line_edit_string(&k.filter) != k.query { marks_filter(k) }
	if k.current >= 0 && marks_shown_at(k, k.current) < 0 { k.current = len(k.shown) > 0 ? marks_step_from(k, k.current, 1) : -1 }

	// the card of the mark under the pointer (a line for each item of a merged one), else of the keyboard's
	tip, merged := k.hot, k.hot >= 0
	if tip < 0 && (sig.focused && s.focus_visible || in_field) { tip = k.current }
	if tip >= 0 && content > 0 && k.marks[tip].top >= 0 {
		group := merged ? marks_group(k, tip) : nil
		if len(group) > 1 || k.marks[tip].line != "" {
			y := marks_y(track, k.marks[tip].top, content)
			gap := em * SCROLL_MARKS_GAP_EM
			size := tooltip_last_size(em)
			pos := Vec2{left ? bar.max.x + gap : bar.min.x - gap - size.x, y - size.y * 0.5}
			tooltip_open(clamp_popup(pos, size, s.window_size), em)
			if len(group) > 1 { marks_card_lines(k, group, o, em) } else { marks_card(k, tip, o, em) }
			tooltip_end()
		}
	}

	d := frame_new(Color)
	// (weak at rest, as the bar's other greys; the accent under the pointer, and while a filter keeps some marks out)
	d^ = color(sig.hovering || marks_query_text(k) != "" ? "accent" : "weak text")
	hb.custom, hb.custom_user = marks_magnifier_draw, d
	name := o.name != "" ? o.name : i18n.tr("Marks")
	info := A11y_Info{role = .Slider, name = name, orientation = .Y, min = 1, max = f64(max(len(k.shown), 1))}
	if k.current >= 0 {
		info.value = k.marks[k.current].line
		if at := marks_shown_at(k, k.current); at >= 0 { info.numeric = f64(at + 1) }
	}
	a11y_default(hb, info)
	return
}

// The marks a box's vertical bar carries: those given to it at its last build (nil: none).
@(private)
scroll_marks_of :: proc(b: ^Box) -> ^Scroll_Marks {
	if b.bar_marks == nil || b.bar_marks_build < b.last_build { return nil }
	return b.bar_marks
}

// The width of a bar with marks, as wide as it has widened.
@(private)
scroll_marks_bar_width :: proc(b: ^Box) -> f32 {
	w, _ := scrollbar_size(b.font_size)
	rest := max(w, math.round(b.font_size * SCROLL_MARKS_BAR_EM))
	wide := max(rest, math.round(b.font_size * SCROLL_MARKS_BAR_WIDE_EM))
	return math.round(math.lerp(rest, wide, clamp(b.bar_wide_t, 0, 1)))
}

// The bar widens under the pointer, held, and while its marks have the keyboard: its marks are then the thing looked at.
@(private)
scroll_marks_wide :: proc(s: ^State, b: ^Box, k: ^Scroll_Marks) -> bool {
	sbk := scrollbar_key(b)
	if s.hot_key == sbk || s.active_key[.Left] == sbk { return true }
	if k.head_key != 0 && (s.hot_key == k.head_key || s.focus_key == k.head_key) { return true }
	return k.filtering && k.field_key != 0 && s.focus_key == k.field_key
}

// The mark a press at `p` on the bar of `b` is on (-1: none, or the thumb is there: the press is the thumb's).
@(private)
scroll_marks_hit :: proc(k: ^Scroll_Marks, b: ^Box, p: Vec2) -> int {
	_, track, thumb, _, ok := scrollbar_parts(b)
	if !ok || b.view_bounds.y <= 0 || (p.y >= thumb.min.y && p.y < thumb.max.y) { return -1 }
	return marks_nearest(k, track, b.view_bounds.y, p.y, b.font_size * SCROLL_MARKS_REACH_EM)
}

// The marks on the track: `over` false, before the thumb, those out of its span, muted; `over` true, after it, those within
// its span a little brighter (where the view is), then the one under the pointer and the keyboard's in the full accent.
// A merged mark is drawn as one mark: its place is its first's.
@(private)
scroll_marks_draw :: proc(s: ^State, dc: ^draw.Context, b: ^Box, k: ^Scroll_Marks, track, thumb: Rect, shows: f32, over: bool) {
	content := b.view_bounds.y
	if content <= 0 || len(k.shown) == 0 { return }
	thick := max(1, math.round(SCROLL_MARKS_THICK_PX * s.scale))
	inset := math.round(SCROLL_MARKS_INSET_PX * s.scale)
	marks_merge(k, track, content, math.round(SCROLL_MARKS_PITCH_PX * s.scale))
	accent := color_from_tags(s, b.tags_key, "accent")
	w := track.max.x - track.min.x
	for g in k.groups {
		y := math.round(track.min.y + g.y0 - thick * 0.5)
		in_view := y + thick > thumb.min.y && y < thumb.max.y
		if in_view != over { continue }
		c := accent
		lit: f32 = in_view ? SCROLL_MARKS_IN_VIEW_ALPHA : SCROLL_MARKS_ALPHA
		if g.weak { lit *= SCROLL_MARKS_WEAK_ALPHA / SCROLL_MARKS_ALPHA }
		c.a *= lit * shows
		side := g.weak ? max(inset, math.round(w * SCROLL_MARKS_WEAK_INSET)) : inset
		draw.rect(dc, {{track.min.x + side, y}, {track.max.x - side, y + thick}}, tuned(c), shape_rad(thick * 0.5))
	}
	if !over { return }
	big := thick * SCROLL_MARKS_HOT_THICK
	keyboard := s.focus_key == k.head_key || (k.filtering && s.focus_key == k.field_key)
	for i in ([2]int{keyboard ? k.current : -1, k.hot}) {
		if i < 0 || i >= len(k.marks) || k.marks[i].top < 0 || marks_shown_at(k, i) < 0 { continue }
		c := accent
		c.a *= shows
		y := math.round(marks_y(track, k.marks[i].top, content) - big * 0.5)
		draw.rect(dc, {{track.min.x, y}, {track.max.x, y + big}}, tuned(c), shape_rad(big * 0.5))
	}
}

// Where a place of the content stands on the track.
@(private = "file")
marks_y :: proc(track: Rect, top, content: f32) -> f32 {
	return track.min.y + clamp(top / content, 0, 1) * (track.max.y - track.min.y)
}

// The marks shown, merged where they would be closer than `gap` on a track as long as `track` for a content as tall as
// `content`. Only when one of these, the places or the filter changed: not at each frame.
@(private = "file")
marks_merge :: proc(k: ^Scroll_Marks, track: Rect, content, gap: f32) {
	want := Scroll_Marks_Merged{placed = k.placed, filtered = k.filtered, track = track.max.y - track.min.y, content = content, gap = gap}
	if want == k.merged { return }
	k.merged = want
	clear(&k.groups)
	for i, at in k.shown {
		m := k.marks[i]
		if m.top < 0 { continue }
		y := clamp(m.top / content, 0, 1) * want.track
		if n := len(k.groups); n > 0 && y - k.groups[n - 1].y0 < gap {
			g := &k.groups[n - 1]
			g.last, g.y1 = at, y
			g.weak = g.weak && m.weak
			continue
		}
		append(&k.groups, Scroll_Mark_Group{first = at, last = at, y0 = y, y1 = y, weak = m.weak})
	}
}

// The marks of the merged mark that holds mark `i`, as indexes of `shown` (`i`'s alone when it is not merged; none when the
// filter leaves it out). Temp memory.
@(private = "file")
marks_group :: proc(k: ^Scroll_Marks, i: int) -> []int {
	at := marks_shown_at(k, i)
	if at < 0 { return nil }
	// (the groups of the last drawing: what is on the screen)
	lo, hi := 0, len(k.groups)
	for lo < hi {
		mid := (lo + hi) / 2
		if k.groups[mid].last < at { lo = mid + 1 } else { hi = mid }
	}
	if lo >= len(k.groups) || k.groups[lo].first > at || k.groups[lo].first == k.groups[lo].last {
		one := make([]int, 1, context.temp_allocator)
		one[0] = i
		return one
	}
	g := k.groups[lo]
	out := make([]int, g.last - g.first + 1, context.temp_allocator)
	for j in g.first ..= g.last { out[j - g.first] = k.shown[j] }
	return out
}

// A mark's card: its name ("#12") and when it was made on a line, then the first lines of its text (SCROLL_MARKS_CARD_LINES,
// wrapped; the last one ends in "…" when there is more). As wide as its text, SCROLL_MARKS_CARD_EM at most.
@(private = "file")
marks_card :: proc(k: ^Scroll_Marks, i: int, o: Scroll_Marks_Options, em: f32) {
	m := k.marks[i]
	st := top_style()
	pad := math.round(em * SCROLL_MARKS_CARD_PAD_EM)
	most := math.round(em * SCROLL_MARKS_CARD_EM)
	small := math.round(em * SCROLL_MARKS_CARD_SMALL)
	when_ := m.time_ms > 0 ? timefmt.moment(m.time_ms, o.now_ms, timefmt.local_offset_minutes(), {hours12 = o.hours12}) : ""
	// (from its first line that says something: the blank lines before it are no part of what it says)
	body := m.text
	if m.line != "" { body = strings.trim_right_space(m.text[int(uintptr(raw_data(m.line)) - uintptr(raw_data(m.text))):]) }
	lines := wrap_lines(st.font, st.font_size, body, most)
	shown := make([dynamic]string, 0, SCROLL_MARKS_CARD_LINES, context.temp_allocator)
	for l, n in lines {
		if n == SCROLL_MARKS_CARD_LINES { break }
		line := body[l[0]:l[1]]
		if n == SCROLL_MARKS_CARD_LINES - 1 && n + 1 < len(lines) { line = marks_elide(st.font, st.font_size, line, most) }
		append(&shown, line)
	}
	head_w := text_width(st.font, small, m.label) + text_width(st.font, small, when_) + em * 1.5
	w := head_w
	for l in shown { w = max(w, text_width(st.font, st.font_size, l)) }
	w = math.ceil(min(w, most))
	next({width = children_sum(), height = children_sum(), axis = .X})
	if row(id = "###marks_card") {
		spacer(px(pad))
		next({width = px(w), height = children_sum(), axis = .Y})
		if column(id = "###col") {
			spacer(px(math.round(pad * 0.7)))
			if m.label != "" || when_ != "" {
				next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
				if row(id = "###head") {
					next({width = text_size(), height = text_size(), font_size = small, text_pad = 0, fg = color("accent")})
					build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###label", text_shown(m.label)))
					spacer(fill())
					if tags("weak") {
						next({width = text_size(), height = text_size(), font_size = small, text_pad = 0})
						build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###when", when_))
					}
				}
				spacer(px(math.round(pad * 0.4)))
			}
			for l, n in shown {
				next({width = fill(), height = text_size(), text_pad = 0})
				build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###l%d", text_shown(l), n))
			}
			spacer(px(math.round(pad * 0.7)))
		}
		spacer(px(pad))
	}
}

// The card of a merged mark: a line for each of its items (SCROLL_MARKS_TIP_LINES at most, then how many more), its name,
// its first line (cut with "…": a list of them), when it was made.
@(private = "file")
marks_card_lines :: proc(k: ^Scroll_Marks, group: []int, o: Scroll_Marks_Options, em: f32) {
	st := top_style()
	pad := math.round(em * SCROLL_MARKS_CARD_PAD_EM)
	small := math.round(em * SCROLL_MARKS_CARD_SMALL)
	w := math.round(em * SCROLL_MARKS_CARD_EM)
	label_w, when_w: f32
	for i, n in group {
		if n == SCROLL_MARKS_TIP_LINES { break }
		m := k.marks[i]
		label_w = max(label_w, math.ceil(text_width(st.font, small, m.label)))
		if m.time_ms > 0 { when_w = max(when_w, math.ceil(text_width(st.font, small, timefmt.moment(m.time_ms, o.now_ms, timefmt.local_offset_minutes(), {hours12 = o.hours12}, short = true)))) }
	}
	line_h := math.round(em * 1.5)
	next({width = children_sum(), height = children_sum(), axis = .X})
	if row(id = "###marks_card") {
		spacer(px(pad))
		next({width = px(w), height = children_sum(), axis = .Y})
		if column(id = "###col") {
			spacer(px(math.round(pad * 0.5)))
			for i, n in group {
				if n == SCROLL_MARKS_TIP_LINES {
					if tags("weak") {
						next({width = fill(), height = px(line_h), text_pad = 0, font_size = small})
						build_box({.Draw_Text}, fmt.tprintf("%s###more", fmt.tprintf(i18n.tr(len(group) - n, "and %d more", "and %d more"), len(group) - n)))
					}
					break
				}
				m := k.marks[i]
				next({width = fill(), height = px(line_h), axis = .X, cross = .Center})
				if row(id = fmt.tprintf("###r%d", n)) {
					if label_w > 0 {
						next({width = px(label_w), height = pct(1), font_size = small, text_pad = 0, fg = color("accent")})
						build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###label", text_shown(m.label)))
						spacer(px(math.round(em * 0.6)))
					}
					// (a line of a list: cut, its whole text is the mark's own card)
					next({width = fill(), height = pct(1), text_pad = 0})
					build_box({.Draw_Text}, fmt.tprintf("%s###t", text_shown(m.line)))
					if when_w > 0 {
						spacer(px(math.round(em * 0.6)))
						if tags("weak") {
							when_ := m.time_ms > 0 ? timefmt.moment(m.time_ms, o.now_ms, timefmt.local_offset_minutes(), {hours12 = o.hours12}, short = true) : ""
							next({width = px(when_w), height = pct(1), font_size = small, text_pad = 0, text_align = .Right})
							build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###when", when_))
						}
					}
				}
			}
			spacer(px(math.round(pad * 0.5)))
		}
		spacer(px(pad))
	}
}

// `line` with "…" at its end, cut so that both fit in `width` (whole when it already does with it).
@(private = "file")
marks_elide :: proc(f: font.Font_Id, size: f32, line: string, width: f32) -> string {
	dots :: "…"
	t := strings.trim_right_space(line)
	for len(t) > 0 && text_width(f, size, t) + text_width(f, size, dots) > width {
		_, n := utf8.decode_last_rune_in_string(t)
		t = strings.trim_right_space(t[:len(t) - n])
	}
	return fmt.tprintf("%s%s", t, dots)
}

// The view goes to the item at `top`, `margin` above it, at once.
@(private = "file")
marks_jump :: proc(view: ^Box, top, margin: f32) {
	if top < 0 { return }
	view_jump(view, clamp(top - margin, 0, view_limit(view)))
}

// The mark shown nearest `y` on the track, within `reach` (-1: none). The marks are in the content's order, so their
// places only go down: a binary search.
@(private = "file")
marks_nearest :: proc(k: ^Scroll_Marks, track: Rect, content, y, reach: f32) -> int {
	n := len(k.shown)
	if n == 0 { return -1 }
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if marks_y(track, k.marks[k.shown[mid]].top, content) < y { lo = mid + 1 } else { hi = mid }
	}
	best, best_d := -1, reach
	for j in max(lo - 1, 0) ..< min(lo + 1, n) {
		m := k.marks[k.shown[j]]
		if m.top < 0 { continue }
		if dist := abs(marks_y(track, m.top, content) - y); dist <= best_d { best, best_d = k.shown[j], dist }
	}
	return best
}

// Up or Down this build: -1, 1 (0: neither).
@(private = "file")
marks_key_step :: proc() -> int {
	if key_press(.Up) { return -1 }
	if key_press(.Down) { return 1 }
	return 0
}

// The mark `dir` steps from the keyboard's among those shown (none yet: the first going down, the last going up).
@(private = "file")
marks_step :: proc(k: ^Scroll_Marks, dir: int) -> int {
	if len(k.shown) == 0 { return -1 }
	if k.current < 0 { return dir > 0 ? k.shown[0] : k.shown[len(k.shown) - 1] }
	return marks_step_from(k, k.current, dir)
}

// The mark shown after (`dir` 1) or before (-1) mark `from`, which may not be shown; at an end, the one at that end.
@(private = "file")
marks_step_from :: proc(k: ^Scroll_Marks, from, dir: int) -> int {
	n := len(k.shown)
	if n == 0 { return -1 }
	// (the first shown at or after `from`)
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if k.shown[mid] < from { lo = mid + 1 } else { hi = mid }
	}
	at := lo
	if at < n && k.shown[at] == from { at += dir } else if dir < 0 { at -= 1 }
	return k.shown[clamp(at, 0, n - 1)]
}

// Where mark `i` is among those shown (-1: not shown).
@(private = "file")
marks_shown_at :: proc(k: ^Scroll_Marks, i: int) -> int {
	lo, hi := 0, len(k.shown)
	for lo < hi {
		mid := (lo + hi) / 2
		if k.shown[mid] < i { lo = mid + 1 } else { hi = mid }
	}
	return lo < len(k.shown) && k.shown[lo] == i ? lo : -1
}

@(private = "file")
marks_query_text :: proc(k: ^Scroll_Marks) -> string { return strings.trim_space(line_edit_string(&k.filter)) }

// The marks that hold every word of the filter, in any case (all of them with no filter). When the marks or the filter
// change, not at each build.
@(private = "file")
marks_filter :: proc(k: ^Scroll_Marks) {
	delete(k.query)
	k.query = strings.clone(line_edit_string(&k.filter))
	clear(&k.shown)
	k.filtered += 1
	q := fold_lower(strings.trim_space(k.query))
	words := strings.fields(q, context.temp_allocator)
	for &m, i in k.marks {
		if len(words) > 0 {
			low := fold_lower(m.text)
			all := true
			for w in words { if !strings.contains(low, w) { all = false; break } }
			if !all { continue }
		}
		append(&k.shown, i)
	}
}

@(private = "file")
marks_free :: proc(k: ^Scroll_Marks) {
	for m in k.marks { delete(m.id); delete(m.text); delete(m.label) }
}

// The first line of `text` that says something, trimmed (a slice of it).
@(private = "file")
marks_first_line :: proc(text: string) -> string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if t := strings.trim_space(line); t != "" { return t }
	}
	return ""
}

// The filter's field is built at the window's root, above what is built after the marks: its ids come from the button's key.
@(private = "file")
marks_field_id :: proc(b: ^Box) -> string { return fmt.tprintf("###scroll_marks_filter_%x", u64(b.key)) }

@(private = "file")
marks_field_parent_key :: proc(b: ^Box) -> Key { return key_from_string(gs().root.key, marks_field_id(b)) }

@(private = "file")
marks_magnifier_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	r := b.rect
	h := min(r.max.y - r.min.y, r.max.x - r.min.x)
	k := h * 0.2
	c := Vec2{(r.min.x + r.max.x) * 0.5 - k * 0.3, (r.min.y + r.max.y) * 0.5 - k * 0.3}
	stroke := max(1, h * 0.065)
	p := draw.path_make(allocator = context.temp_allocator)
	draw.path_arc(&p, c, {k, k}, 0, 2 * math.PI)
	ink := (^Color)(user)^
	draw.path_stroke(dc, &p, stroke, ink)
	d := k * 0.7071
	draw.line(dc, c + {d, d}, c + {d, d} * 2.1, stroke, ink)
}
