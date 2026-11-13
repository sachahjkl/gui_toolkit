package ui

// A rail of marks beside a view that scrolls, as the small map at the side of a code editor: a narrow track as tall as the
// rail, a dot for each item that counts (a prompt in a conversation, a heading in a document, a day in a journal) at the
// height where the item stands in the view's content, and a band over the part the view shows. The pointer over a dot shows
// the item's first line; a press on a dot puts its item at the view's top at once (no glide: a long glide over a long
// content is a wait), a press elsewhere puts that part of the content in the middle of the view, and a drag goes along.
// The wheel over the rail scrolls the view. The keyboard: Up and Down go from mark to mark (Home, End: the first, the last), Enter or Space jumps. A filter at the
// rail's top (a magnifier, or a character typed on the rail) keeps only the marks whose text holds every word typed.
//
//   rail: ui.Mark_Rail                                       // the program's, kept between builds
//   if ui.mark_rail_stale(&rail, version) {                  // the items changed: a version of the program's
//       ui.mark_rail_set(&rail, version, marks)              // copied (texts and ids)
//   }
//   if i := ui.mark_rail("###rail", &rail, ui.prev_box("###doc")); i >= 0 { focus(ui.mark_rail_id(&rail, i)) }
//   if ui.scroll_y("###doc") {
//       lz := ui.lazy_begin()
//       k := 0
//       for item in items {
//           if item.marked { ui.mark_rail_place(&rail, k, lz.y); k += 1 }   // where it starts in the content
//           if ui.lazy_item(lz, item.id) { ... }
//       }
//   }
//
// What it costs: the marks are copied and filtered only when they or the filter change. A build reads only the marks
// near the pointer (a binary search), and the drawing reads each mark shown once. A mark's place is the program's,
// given at each build where it already goes over its items (a lazy column's `y`, a box's top). The dots follow the
// layout of the build they are drawn with.
//
// Build it before the view when it can be (a floating rail): a jump then builds the content at its new place in the same
// build. After it, the content shows its new place one build later.

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import i18n "../i18n"

// A mark given to the rail.
Rail_Mark :: struct {
	id:   string,   // what the program calls its item (mark_rail_id gives it back); copied
	text: string,   // what the item says: its first line shows under the pointer, the filter reads all of it; copied
	weak: bool,     // a lesser mark: a smaller, fainter dot
}

// A mark as the rail keeps it: its texts owned, and its place in the content at the last build that gave one (-1: none yet).
@(private)
Rail_Kept :: struct {
	id, text, line: string,   // (line: the first line of text that says something, a slice of it)
	weak: bool,
	top:  f32,
}

// The rail's state, the program's to keep (zero is a rail with no marks). mark_rail_destroy frees it.
Mark_Rail :: struct {
	marks:     [dynamic]Rail_Kept,
	version:   u64,
	made:      bool,
	filter:    Line_Edit,
	filtering: bool,           // the filter's field is open
	query:     string,         // the filter `shown` was made for (owned)
	shown:     [dynamic]int,   // the marks the filter keeps, in their order
	current:   int,            // the mark of the keyboard, and the last one jumped to (-1: none; at first the first)
	hot:       int,            // the mark under the pointer at this build (-1: none)
	focus_field: bool,         // the field takes the keyboard when it is next built
	track:     Rect,           // where the marks were placed at the last build (window pixels)
}

Mark_Rail_Options :: struct {
	name:      string,   // what a screen reader calls it ("" : "Marks")
	margin:    f32,      // pixels left above an item the view jumps to (0: half a line)
	no_filter: bool,     // no filter at its top
	filter_w:  f32,      // the filter's field, pixels (0: 16 lines' height)
}

@(private = "file") MARK_RAIL_DOT_EM :: 0.2          // a dot's radius
@(private = "file") MARK_RAIL_WEAK_DOT_EM :: 0.13
@(private = "file") MARK_RAIL_HOT_DOT_EM :: 0.3      // under the pointer, or the keyboard's
@(private = "file") MARK_RAIL_HIT_EM :: 0.6          // a press this near a dot is on it
@(private = "file") MARK_RAIL_BAND_ALPHA :: 0.08     // the band over what the view shows, of the text's colour
@(private = "file") MARK_RAIL_BAND_BORDER_ALPHA :: 0.14
@(private = "file") MARK_RAIL_WEAK_ALPHA :: 0.6
@(private = "file") MARK_RAIL_FILTER_EM :: 16
@(private = "file") MARK_RAIL_TIP_GAP_EM :: 0.5      // between the rail and a mark's text
@(private = "file") MARK_RAIL_MARGIN_EM :: 0.5

mark_rail_destroy :: proc(r: ^Mark_Rail) {
	rail_marks_free(r)
	delete(r.marks)
	delete(r.shown)
	delete(r.query)
	line_edit_destroy(&r.filter)
	r^ = {}
}

// The marks the rail keeps are not those of `version`: give them with mark_rail_set.
mark_rail_stale :: proc(r: ^Mark_Rail, version: u64) -> bool { return !r.made || r.version != version }

// The marks of `version`, in the order of their items in the content (copied). Their places come with mark_rail_place.
mark_rail_set :: proc(r: ^Mark_Rail, version: u64, marks: []Rail_Mark) {
	rail_marks_free(r)
	clear(&r.marks)
	for m in marks {
		text := strings.clone(m.text)
		append(&r.marks, Rail_Kept{id = strings.clone(m.id), text = text, line = rail_first_line(text), weak = m.weak, top = -1})
	}
	r.version, r.made = version, true
	r.current = min(r.current, len(r.marks) - 1)
	r.hot = -1
	rail_filter(r)
}

// Where mark `i` starts in the content of the view, at this build (a lazy column's `y` before its item, a box's top in
// the content). A mark out of the rail's range is passed over (the marks of an older version).
mark_rail_place :: proc(r: ^Mark_Rail, i: int, top: f32) {
	if i < 0 || i >= len(r.marks) { return }
	r.marks[i].top = top
}

// The id the program gave mark `i` ("" out of range).
mark_rail_id :: proc(r: ^Mark_Rail, i: int) -> string { return i >= 0 && i < len(r.marks) ? r.marks[i].id : "" }

// The marks the filter keeps, by their index, in order.
mark_rail_shown :: proc(r: ^Mark_Rail) -> []int { return r.shown[:] }

// Where mark `i`'s dot is on the rail, in window pixels, by the last build and the layout of `view` (ok = false: the mark
// is not shown, or has no place yet). For tests and tools.
mark_rail_dot :: proc(r: ^Mark_Rail, view: ^Box, i: int) -> (at: Vec2, ok: bool) {
	if view == nil || view.view_bounds.y <= 0 || i < 0 || i >= len(r.marks) || r.marks[i].top < 0 || !rail_is_shown(r, i) { return }
	return {(r.track.min.x + r.track.max.x) * 0.5, rail_y(r.track, r.marks[i].top, view.view_bounds.y)}, true
}

// The filter's text.
mark_rail_query :: proc(r: ^Mark_Rail) -> string { return line_edit_string(&r.filter) }

// The rail of `r` beside the scroll box `view` (the last build's: prev_box), in a box of the size `next` gives it. The
// index of the mark the view jumped to in this build, -1 none: the program gives its item the keyboard if it wants.
// Tags used: "mark_rail"; its field "input".
mark_rail :: proc(id: string, r: ^Mark_Rail, view: ^Box, o := Mark_Rail_Options{}) -> (jumped: int) {
	s := gs()
	jumped = -1
	em := font_size()
	if line_edit_string(&r.filter) != r.query { rail_filter(r) }
	push_tags("mark_rail")
	defer pop_tags()
	// (Scroll_Self: the wheel over the rail is the view's, which it is not inside)
	b := build_box({.Clickable, .Focusable, .Scroll_Self}, id)
	b.cursor = .Hand
	head := o.no_filter ? 0 : rail_head(b)
	track := rail_track(b, head, em)
	r.track = track
	content := view != nil ? view.view_bounds.y : 0
	margin := o.margin > 0 ? o.margin : em * MARK_RAIL_MARGIN_EM

	// the filter's magnifier, at the top (a box of its own: its press is not the track's)
	toggled, toggle_held := false, false
	if !o.no_filter {
		if parent(b) {
			next({width = fill(), height = px(head)})
			mb := build_box({.Clickable}, "###filter_toggle")
			toggle_held = s.active_key[.Left] == mb.key
			mb.cursor = .Hand
			ms := signal(mb)
			ink := frame_new(Color)
			ink^ = color(rail_query_text(r) != "" ? "accent" : (ms.hovering || r.filtering ? "text" : "weak text"))
			mb.custom, mb.custom_user = rail_magnifier_draw, ink
			if ms.clicked {
				toggled = true
				r.filtering = !r.filtering
				if r.filtering { r.focus_field = true } else { line_edit_clear(&r.filter); s.focus_key = b.key }
			}
		}
	}
	sig := signal(b)

	if sig.scrolled.y != 0 && view != nil && .View_Scroll_Y in view.flags {
		view.view_target.y = clamp(view.view_target.y + scroll_view_delta(s).y * wheel_step(view, .Y), 0, view_limit(view))
	}

	// the pointer: the mark under it, a press or a drag on the track
	r.hot = -1
	if view != nil && content > 0 {
		on_track := s.mouse.y >= track.min.y - em && s.mouse.y < track.max.y + em
		if (sig.hovering && on_track) || sig.dragging { r.hot = rail_nearest(r, track, content, s.mouse.y, em * MARK_RAIL_HIT_EM) }
		if sig.pointer_pressed || (sig.dragging && s.mouse_moved) {
			if r.hot >= 0 {
				if r.hot != r.current || sig.pointer_pressed { jumped = r.hot }
				r.current = r.hot
				rail_jump(view, r.marks[r.hot].top, margin)
			} else if track.max.y > track.min.y {
				// (a place with no mark: that part of the content in the middle of the view)
				at := clamp((s.mouse.y - track.min.y) / (track.max.y - track.min.y), 0, 1) * content
				view_jump(view, clamp(at - view.size.y * 0.5, 0, view_limit(view)))
			}
		}
	}

	// the keyboard, on the rail or in its field
	field_key := key_from_string(rail_field_parent_key(b), "###field")
	in_field := s.focus_key == field_key && r.filtering
	if sig.focused || in_field {
		if step := rail_key_step(); step != 0 { r.current = rail_step(r, step) }
		if key_press(.Home) && sig.focused && len(r.shown) > 0 { r.current = r.shown[0] }
		if key_press(.End) && sig.focused && len(r.shown) > 0 { r.current = r.shown[len(r.shown) - 1] }
	}
	if sig.focused && !sig.pointer_pressed && sig.pressed && r.current >= 0 && view != nil {
		jumped = r.current
		rail_jump(view, r.marks[r.current].top, margin)
	}
	if sig.focused && !o.no_filter && !r.filtering {
		// a character typed on the rail opens its filter, which takes it
		for c in s.typed {
			if c >= ' ' && c != 0x7f && .Ctrl not_in s.typed_mods && .Alt not_in s.typed_mods { r.filtering, r.focus_field = true, true; break }
		}
	}
	if sig.focused && key_press(.Escape) && rail_query_text(r) != "" { line_edit_clear(&r.filter) }

	// the filter's field, over the content at the rail's left (above the view, which is built after a rail built first)
	if r.filtering && !o.no_filter {
		w := o.filter_w > 0 ? o.filter_w : math.round(em * MARK_RAIL_FILTER_EM)
		push_parent(s.root)
		next({fixed_x = b.rect.min.x - w, fixed_y = b.rect.min.y, width = px(w), height = children_sum(), axis = .Y})
		frame := build_box({}, rail_field_id(b))
		if parent(frame) {
			if r.focus_field { s.focus_key = field_key; r.focus_field = false }
			next({width = fill()})
			res := line_edit("###field", &r.filter, {placeholder = i18n.tr("Filter"), clearable = true})
			if res.committed && r.current >= 0 && view != nil {
				jumped = r.current
				rail_jump(view, r.marks[r.current].top, margin)
			}
			if res.cancelled {
				line_edit_clear(&r.filter)
				r.filtering = false
				s.focus_key = b.key
			}
			// (left with nothing in it, it closes; with a query it stays, for what it keeps. Not while its magnifier is
			// held: the press took the keyboard, and the click that follows closes it)
			if r.filtering && s.focus_key != field_key && !toggled && !toggle_held && rail_query_text(r) == "" {
				r.filtering = false
			}
		}
		pop_parent()
	}
	if line_edit_string(&r.filter) != r.query { rail_filter(r) }
	if r.current >= 0 && !rail_is_shown(r, r.current) { r.current = len(r.shown) > 0 ? rail_step_from(r, r.current, 1) : -1 }

	// the text of the mark under the pointer, else of the keyboard's
	tip := r.hot
	if tip < 0 && (sig.focused && s.focus_visible || in_field) { tip = r.current }
	if tip >= 0 && view != nil && content > 0 && r.marks[tip].top >= 0 && r.marks[tip].line != "" {
		y := rail_y(track, r.marks[tip].top, content)
		size := tooltip_last_size(em)
		pos := Vec2{b.rect.min.x - em * MARK_RAIL_TIP_GAP_EM - size.x, y - size.y * 0.5}
		tooltip_open(clamp_popup(pos, size, s.window_size), em)
		tooltip_text(r.marks[tip].line)
		tooltip_end()
	}

	d := frame_new(Rail_Draw)
	d^ = {r = r, view = view, head = head, em = em, scale = s.scale, focused = sig.focused,
		dot = color("weak text"), hot = color("text"), accent = color("accent"), line = color("border"), band = color("text")}
	b.custom, b.custom_user = rail_draw, d
	name := o.name != "" ? o.name : i18n.tr("Marks")
	info := A11y_Info{role = .Slider, name = name, orientation = .Y, min = 1, max = f64(max(len(r.shown), 1))}
	if r.current >= 0 {
		info.value = r.marks[r.current].line
		for k, i in r.shown { if k == r.current { info.numeric = f64(i + 1); break } }
	}
	a11y_default(b, info)
	return
}

@(private = "file")
Rail_Draw :: struct {
	r:       ^Mark_Rail,   // (the program's: read at the draw, where this build's places are)
	view:    ^Box,
	head:    f32,
	em, scale: f32,
	focused: bool,
	dot, hot, accent, line, band: Color,
}

// The height of the filter's magnifier at the rail's top: as tall as the rail is wide.
@(private = "file")
rail_head :: proc(b: ^Box) -> f32 {
	w := b.size.x > 0 ? b.size.x : font_size() * 1.5
	return math.round(w)
}

// The track the marks are placed on: the rail less its head, and the room of a dot at each end.
@(private = "file")
rail_track :: proc(b: ^Box, head, em: f32) -> Rect {
	pad := math.round(em * MARK_RAIL_HOT_DOT_EM) + 1
	return {{b.rect.min.x, b.rect.min.y + head + pad}, {b.rect.max.x, max(b.rect.min.y + head + pad, b.rect.max.y - pad)}}
}

// Where a place of the content stands on the track.
@(private = "file")
rail_y :: proc(track: Rect, top, content: f32) -> f32 {
	return track.min.y + clamp(top / content, 0, 1) * (track.max.y - track.min.y)
}

// The view goes to the item at `top`, `margin` above it, at once.
@(private = "file")
rail_jump :: proc(view: ^Box, top, margin: f32) {
	if top < 0 { return }
	view_jump(view, clamp(top - margin, 0, view_limit(view)))
}

// The mark shown nearest `y` on the track, within `reach` (-1: none). The marks are in the content's order, so their
// places only go down: a binary search.
@(private = "file")
rail_nearest :: proc(r: ^Mark_Rail, track: Rect, content, y, reach: f32) -> int {
	n := len(r.shown)
	if n == 0 { return -1 }
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if rail_y(track, r.marks[r.shown[mid]].top, content) < y { lo = mid + 1 } else { hi = mid }
	}
	best, best_d := -1, reach
	for k in max(lo - 1, 0) ..< min(lo + 1, n) {
		m := r.marks[r.shown[k]]
		if m.top < 0 { continue }
		if dist := abs(rail_y(track, m.top, content) - y); dist <= best_d { best, best_d = r.shown[k], dist }
	}
	return best
}

// Up or Down this build: -1, 1 (0: neither).
@(private = "file")
rail_key_step :: proc() -> int {
	if key_press(.Up) { return -1 }
	if key_press(.Down) { return 1 }
	return 0
}

// The mark `dir` steps from the keyboard's among those shown (none yet: the first going down, the last going up).
@(private = "file")
rail_step :: proc(r: ^Mark_Rail, dir: int) -> int {
	if len(r.shown) == 0 { return -1 }
	if r.current < 0 { return dir > 0 ? r.shown[0] : r.shown[len(r.shown) - 1] }
	return rail_step_from(r, r.current, dir)
}

// The mark shown after (`dir` 1) or before (-1) mark `from`, which may not be shown; at an end, the one at that end.
@(private = "file")
rail_step_from :: proc(r: ^Mark_Rail, from, dir: int) -> int {
	n := len(r.shown)
	if n == 0 { return -1 }
	// (the first shown at or after `from`)
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if r.shown[mid] < from { lo = mid + 1 } else { hi = mid }
	}
	at := lo
	if at < n && r.shown[at] == from { at += dir } else if dir < 0 { at -= 1 }
	return r.shown[clamp(at, 0, n - 1)]
}

@(private = "file")
rail_is_shown :: proc(r: ^Mark_Rail, i: int) -> bool {
	lo, hi := 0, len(r.shown)
	for lo < hi {
		mid := (lo + hi) / 2
		if r.shown[mid] < i { lo = mid + 1 } else { hi = mid }
	}
	return lo < len(r.shown) && r.shown[lo] == i
}

@(private = "file")
rail_query_text :: proc(r: ^Mark_Rail) -> string { return strings.trim_space(line_edit_string(&r.filter)) }

// The marks that hold every word of the filter, in any case (all of them with no filter). When the marks or the filter
// change, not at each build.
@(private = "file")
rail_filter :: proc(r: ^Mark_Rail) {
	delete(r.query)
	r.query = strings.clone(line_edit_string(&r.filter))
	clear(&r.shown)
	q := fold_lower(strings.trim_space(r.query))
	words := strings.fields(q, context.temp_allocator)
	for &m, i in r.marks {
		if len(words) > 0 {
			low := fold_lower(m.text)
			all := true
			for w in words { if !strings.contains(low, w) { all = false; break } }
			if !all { continue }
		}
		append(&r.shown, i)
	}
}

@(private = "file")
rail_marks_free :: proc(r: ^Mark_Rail) {
	for m in r.marks { delete(m.id); delete(m.text) }
}

// The first line of `text` that says something, trimmed (a slice of it).
@(private = "file")
rail_first_line :: proc(text: string) -> string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if t := strings.trim_space(line); t != "" { return t }
	}
	return ""
}

// The filter's field is built at the window's root, above what is built after the rail: its ids come from the rail's key.
@(private = "file")
rail_field_id :: proc(b: ^Box) -> string { return fmt.tprintf("###mark_rail_filter_%x", u64(b.key)) }

@(private = "file")
rail_field_parent_key :: proc(b: ^Box) -> Key { return key_from_string(gs().root.key, rail_field_id(b)) }

@(private = "file")
rail_magnifier_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
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

@(private = "file")
rail_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Rail_Draw)(user)
	r, view := d.r, d.view
	track := rail_track(b, d.head, d.em)
	px := max(1, math.round(d.scale))
	mid := math.round((b.rect.min.x + b.rect.max.x) * 0.5)
	line := d.line
	draw.rect(dc, {{mid - px * 0.5, track.min.y}, {mid + px * 0.5, track.max.y}}, tuned(line))
	if view == nil || view.view_bounds.y <= 0 { return }
	content := view.view_bounds.y
	// the band over what the view shows
	y0 := rail_y(track, view.view_off.y, content)
	y1 := rail_y(track, view.view_off.y + view.size.y, content)
	if y1 - y0 < px * 2 { y1 = y0 + px * 2 }
	band := Rect{{b.rect.min.x + px, y0}, {b.rect.max.x - px, y1}}
	fill, edge := d.band, d.band
	fill.a *= MARK_RAIL_BAND_ALPHA
	edge.a *= MARK_RAIL_BAND_BORDER_ALPHA
	radius := rad(d.em * 0.25)
	draw.rect(dc, band, tuned(fill), radius)
	draw.rect(dc, band, tuned(edge), radius, px)
	// the dots: the lesser first, the keyboard's and the pointer's last (on top)
	for weak_pass in ([2]bool{true, false}) {
		for i in r.shown {
			m := r.marks[i]
			if m.weak != weak_pass || m.top < 0 || i == r.hot || i == r.current { continue }
			c := d.dot
			k := d.em * MARK_RAIL_DOT_EM
			if m.weak { c.a *= MARK_RAIL_WEAK_ALPHA; k = d.em * MARK_RAIL_WEAK_DOT_EM }
			y := rail_y(track, m.top, content)
			draw.rect(dc, {{mid - k, y - k}, {mid + k, y + k}}, tuned(c), k)
		}
	}
	for i in ([2]int{r.current, r.hot}) {
		if i < 0 || i >= len(r.marks) || r.marks[i].top < 0 || !rail_is_shown(r, i) { continue }
		c := i == r.hot ? d.hot : (d.focused ? d.accent : d.dot)
		k := d.em * (i == r.hot || d.focused ? MARK_RAIL_HOT_DOT_EM : MARK_RAIL_DOT_EM)
		y := rail_y(track, r.marks[i].top, content)
		draw.rect(dc, {{mid - k, y - k}, {mid + k, y + k}}, tuned(c), k)
	}
}
