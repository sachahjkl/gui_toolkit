package ui

import "base:runtime"
import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../draw"
import "../font"
import "../platform"

// Selecting text outside text fields: labels, paragraphs and rich paragraphs built with .Selectable (`next({flags =
// {.Selectable}})`, or a `style` scope around a whole reply). One selection for the whole window, which may run across
// several boxes in build order (a chat reply made of many paragraphs):
//   press and drag: select; Shift+click: extend; double click: a word; triple click: the box's paragraph;
//   Shift+arrows / Shift+Home / Shift+End: move its moving end (when no field has the keyboard); Ctrl+C: copy (boxes
//   joined by new lines); Ctrl+A on a selectable box: all of it; a press on nothing clickable: no selection (a press on
//   a button keeps it).
// The pointer is the text cursor over selectable text (not over a link or a clickable box above it). The selection is
// drawn with the theme's "selection" colour. Apps read it with `selected_text`, and know it changed from
// `selection_serial` (it moves with every change) or `selection_changed` (this build).

Sel_Pos :: struct {
	box:   Key,
	index: int,     // byte index in the box's selectable text
}

@(private)
Selection :: struct {
	anchor, focus: Sel_Pos,
	active:        bool,
	dragging:      bool,
	granularity:   int,           // 1 characters, 2 words, 3 paragraphs (the drag extends by that much)
	word_lo, word_hi: Sel_Pos,    // what the double / triple click selected (the drag keeps it)
	serial:        u64,
	changed_build: u64,
	clicks:        int,
	click_ms:      f64,
	click_pos:     Vec2,
	order:         [dynamic]Key,  // selectable boxes of the build, in order
	pos_of:        map[Key]int,
}

// The selected text (boxes joined by "\n"), "" for none.
selected_text :: proc(s: ^State, allocator := context.allocator) -> string {
	sel := &s.sel
	if !sel.active { return "" }
	a, b := sel_ordered(s)
	if a.box == 0 { return "" }
	sb := strings.builder_make(allocator)
	ia, ib := sel.pos_of[a.box], sel.pos_of[b.box]
	for i in ia ..= ib {
		box := s.boxes[sel.order[i]]
		text := sel_text(s, box, context.temp_allocator)
		lo := i == ia ? a.index : 0
		hi := i == ib ? b.index : len(text)
		lo, hi = clamp(lo, 0, len(text)), clamp(hi, 0, len(text))
		if i > ia { strings.write_byte(&sb, '\n') }
		if hi > lo { strings.write_string(&sb, text[lo:hi]) }
	}
	return strings.to_string(sb)
}

// Moves with every change of the selection (compare it with the value of the last build).
selection_serial :: proc(s: ^State) -> u64 { return s.sel.serial }

// Whether the selection changed in the last build.
selection_changed :: proc(s: ^State) -> bool { return s.sel.changed_build == s.build_index }

// Whether there is a selection (a non-empty one).
has_selection :: proc(s: ^State) -> bool { return s.sel.active && s.sel.anchor != s.sel.focus }

clear_selection :: proc(s: ^State) {
	if s.sel.active { s.sel.active = false; sel_bump(s) }
}

// Selects all the text of a selectable box.
select_box :: proc(s: ^State, key: Key) {
	b := s.boxes[key] if key != 0 else nil
	if b == nil || .Selectable not_in b.flags { return }
	s.sel.anchor = {key, 0}
	s.sel.focus = {key, len(sel_text(s, b, context.temp_allocator))}
	s.sel.active = true
	sel_bump(s)
}

@(private)
sel_bump :: proc(s: ^State) { s.sel.serial += 1; s.sel.changed_build = s.build_index }

@(private)
selection_destroy :: proc(s: ^State) { delete(s.sel.order); delete(s.sel.pos_of) }

// begin_build: last build's list goes.
@(private)
selection_begin :: proc(s: ^State) {
	clear(&s.sel.order)
	clear(&s.sel.pos_of)
}

// build_box: a selectable box takes its place in the order.
@(private)
selection_note :: proc(s: ^State, b: ^Box) {
	if .Selectable not_in b.flags { return }
	s.sel.pos_of[b.key] = len(s.sel.order)
	append(&s.sel.order, b.key)
}

// The anchor and the focus in document order.
@(private)
sel_ordered :: proc(s: ^State) -> (a, b: Sel_Pos) {
	sel := &s.sel
	pa, oka := sel.pos_of[sel.anchor.box]
	pb, okb := sel.pos_of[sel.focus.box]
	if !oka || !okb { return }
	if pa < pb || (pa == pb && sel.anchor.index <= sel.focus.index) { return sel.anchor, sel.focus }
	return sel.focus, sel.anchor
}

// The bytes of a box's text in the selection ([0, 0) for none).
@(private)
sel_range_of :: proc(s: ^State, key: Key, text_len: int) -> (lo, hi: int) {
	if !s.sel.active { return }
	i, ok := s.sel.pos_of[key]
	if !ok { return }
	a, b := sel_ordered(s)
	if a.box == 0 { return }
	ia, ib := s.sel.pos_of[a.box], s.sel.pos_of[b.box]
	if i < ia || i > ib { return }
	lo = i == ia ? a.index : 0
	hi = i == ib ? b.index : text_len
	return clamp(lo, 0, text_len), clamp(hi, 0, text_len)
}

////////////////////////////////
// What a selectable box shows: its text, where a point falls in it, the rectangles of a range (window coordinates)

@(private)
Sel_Kind :: enum u8 { None, Label, Wrapped, Rich }

@(private)
sel_kind :: proc(b: ^Box) -> Sel_Kind {
	if b.custom == rich_draw && b.custom_user != nil { return .Rich }
	if .Clickable in b.flags { return .None }   // a button's label is not text to select (a style scope may mark it)
	if .Draw_Text in b.flags && b.text != "" { return .Text_Wrap in b.flags ? .Wrapped : .Label }
	return .None
}

@(private)
sel_text :: proc(s: ^State, b: ^Box, allocator: runtime.Allocator) -> string {
	switch sel_kind(b) {
	case .Rich: return rich_text((^Rich_Draw)(b.custom_user).runs, allocator)
	case .Label, .Wrapped: return b.text
	case .None:
	}
	return ""
}

@(private)
Sel_Line :: struct { start, end: int, x, top, height: f32 }   // a line of plain text: bytes, its left x and box

@(private)
plain_lines :: proc(s: ^State, b: ^Box, allocator := context.temp_allocator) -> []Sel_Line {
	m := font.metrics(s.fonts, b.font, b.font_size)
	out := make([dynamic]Sel_Line, 0, 4, allocator)
	if sel_kind(b) == .Label {
		o := text_origin(s, b, {b.text_dim.x, b.text_dim.y})
		append(&out, Sel_Line{0, len(b.text), o.x, o.y - m.ascent, m.ascent + m.descent})
		return out[:]
	}
	lh := math.ceil(m.line_height)
	lines := wrap_lines_cached(b.font, b.font_size, b.text, b.size.x - 2 * b.text_pad)
	y := (b.rect.min.y + b.rect.max.y) * 0.5 - f32(len(lines)) * lh * 0.5
	for l in lines {
		lw := font.text_width(s.fonts, b.font, b.font_size, b.text[l[0]:l[1]])
		x: f32
		switch b.text_align {
		case .Left:   x = b.rect.min.x + b.text_pad
		case .Center: x = (b.rect.min.x + b.rect.max.x - lw) * 0.5
		case .Right:  x = b.rect.max.x - b.text_pad - lw
		}
		append(&out, Sel_Line{l[0], l[1], math.round(x), y, lh})
		y += lh
	}
	return out[:]
}

@(private)
rich_of :: proc(b: ^Box) -> (^Rich_Draw, ^Rich_Layout, Vec2) {
	d := (^Rich_Draw)(b.custom_user)
	l := rich_layout_cached(d.runs, d.ctx, b.size.x - 2 * b.text_pad, d.max_lines, b.text_align)
	return d, l, b.rect.min + {b.text_pad, b.text_pad}
}

// The byte index nearest to window point `p` (clamped into the box).
@(private)
sel_index_at :: proc(s: ^State, b: ^Box, p: Vec2) -> int {
	switch sel_kind(b) {
	case .Rich:
		d, l, o := rich_of(b)
		return rich_index_at(l, s.fonts, d.runs, p - o)
	case .Label, .Wrapped:
		lines := plain_lines(s, b)
		if len(lines) == 0 { return 0 }
		li := len(lines) - 1
		for l, i in lines { if p.y < l.top + l.height { li = i; break } }
		l := lines[li]
		return l.start + font.index_from_x(s.fonts, b.font, b.font_size, b.text[l.start:l.end], p.x - l.x)
	case .None:
	}
	return 0
}

// The window rectangles of the bytes [lo, hi) of the box's text.
@(private)
sel_rects :: proc(s: ^State, b: ^Box, lo, hi: int, allocator := context.temp_allocator) -> []Rect {
	out := make([dynamic]Rect, 0, 4, allocator)
	if hi <= lo { return out[:] }
	switch sel_kind(b) {
	case .Rich:
		d, l, o := rich_of(b)
		for r in rich_range_rects(l, s.fonts, d.runs, lo, hi) { append(&out, Rect{r.min + o, r.max + o}) }
	case .Label, .Wrapped:
		for l in plain_lines(s, b) {
			a, z := max(lo, l.start), min(hi, l.end)
			if z <= a { continue }
			for sp in font.x_spans_of_range(s.fonts, b.font, b.font_size, b.text[l.start:l.end], a - l.start, z - l.start) {
				append(&out, Rect{{l.x + sp[0], l.top}, {l.x + sp[1], l.top + l.height}})
			}
		}
	case .None:
	}
	return out[:]
}

// The caret of byte `index`: its window rectangle (a line tall).
@(private)
sel_caret :: proc(s: ^State, b: ^Box, index: int) -> Rect {
	switch sel_kind(b) {
	case .Rich:
		d, l, o := rich_of(b)
		li, x := rich_caret(l, s.fonts, d.runs, index)
		ln := l.lines[li]
		return {o + {x, ln.y}, o + {x + 1, ln.y + ln.height}}
	case .Label, .Wrapped:
		lines := plain_lines(s, b)
		for l, i in lines {
			if index > l.end && i + 1 < len(lines) { continue }
			x := l.x + font.x_from_index(s.fonts, b.font, b.font_size, b.text[l.start:l.end], clamp(index - l.start, 0, l.end - l.start))
			return {{x, l.top}, {x + 1, l.top + l.height}}
		}
	case .None:
	}
	return {b.rect.min, b.rect.min}
}

// The part of the box that is on screen (inside every clipping ancestor).
@(private)
visible_rect :: proc(b: ^Box) -> Rect {
	r := b.rect
	for p := b.parent; p != nil; p = p.parent {
		if .Clip not_in p.flags { continue }
		r = {{max(r.min.x, p.rect.min.x), max(r.min.y, p.rect.min.y)}, {min(r.max.x, p.rect.max.x), min(r.max.y, p.rect.max.y)}}
	}
	return r
}

// The selectable box at window point `p` (the last built, which draws on top), 0 for none.
@(private)
sel_box_at :: proc(s: ^State, p: Vec2) -> Key {
	for i := len(s.sel.order) - 1; i >= 0; i -= 1 {
		b := s.boxes[s.sel.order[i]]
		if b != nil && sel_kind(b) != .None && contains(visible_rect(b), p) { return b.key }
	}
	return 0
}

// The selectable box nearest to `p` (a drag that left the text), and the point clamped into it.
@(private)
sel_nearest :: proc(s: ^State, p: Vec2) -> (Key, Vec2) {
	best: Key
	best_d := max(f32)
	q := p
	for k in s.sel.order {
		b := s.boxes[k]
		if b == nil || sel_kind(b) == .None { continue }
		r := visible_rect(b)
		c := Vec2{clamp(p.x, r.min.x, r.max.x - 0.5), clamp(p.y, r.min.y, r.max.y - 0.5)}
		d := (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y) * 4   // rows first
		if d < best_d { best, best_d, q = k, d, c }
	}
	// above a box: its start; below it: its end (what dragging past a paragraph means)
	if best != 0 {
		r := visible_rect(s.boxes[best])
		if p.y < r.min.y { q = {r.min.x - 1000, r.min.y} }
		if p.y >= r.max.y { q = {r.max.x + 1000, r.max.y - 0.5} }
	}
	return best, q
}

// Word bounds around byte `i`: a run of letters / digits, of spaces, or one grapheme of anything else.
@(private)
word_at :: proc(text: string, at: int) -> (lo, hi: int) {
	if len(text) == 0 { return 0, 0 }
	i := clamp(at, 0, len(text) - 1)
	for i > 0 && text[i] & 0xC0 == 0x80 { i -= 1 }
	kind :: proc(r: rune) -> int {
		if unicode.is_letter(r) || unicode.is_digit(r) || r == '_' || r == '\'' { return 1 }
		if unicode.is_space(r) { return 2 }
		return 3
	}
	r0, _ := utf8.decode_rune_in_string(text[i:])
	k := kind(r0)
	lo, hi = i, i
	for lo > 0 {
		r, n := utf8.decode_last_rune_in_string(text[:lo])
		if kind(r) != k || k == 3 { break }
		lo -= n
	}
	for hi < len(text) {
		r, n := utf8.decode_rune_in_string(text[hi:])
		if hi > i && (kind(r) != k || k == 3) { break }
		hi += n
		if k == 3 { hi = font.grapheme_next(text, i); break }
	}
	return
}

// The paragraph ("\n"-separated) around byte `i`.
@(private)
para_at :: proc(text: string, at: int) -> (lo, hi: int) {
	i := clamp(at, 0, len(text))
	lo = strings.last_index_byte(text[:i], '\n') + 1
	e := strings.index_byte(text[i:], '\n')
	hi = e < 0 ? len(text) : i + e
	return
}

// end_build, after layout: the pointer and the keys act on the selection of this build's tree.
@(private)
selection_update :: proc(s: ^State) {
	sel := &s.sel
	before := [3]Sel_Pos{sel.anchor, sel.focus, {Key(u64(sel.active)), 0}}
	// a selection whose boxes are gone
	if sel.active {
		_, oka := sel.pos_of[sel.anchor.box]
		_, okb := sel.pos_of[sel.focus.box]
		if !oka || !okb { sel.active = false }
	}
	for e in s.mouse_events {
		#partial switch e.kind {
		case .Mouse_Press:
			if e.button != .Left { continue }
			k := sel_box_at(s, e.pos)
			b := s.boxes[k] if k != 0 else nil
			// a clickable box over the text (or a link in it) keeps its press
			pressed := s.pressed_key[.Left]
			if b != nil && pressed != 0 && pressed != k { b = nil }
			if b != nil && sel_kind(b) == .Rich {
				d, l, o := rich_of(b)
				if rich_link_at(l, d.runs, e.pos - o) >= 0 { b = nil }
			}
			if b == nil {
				if pressed == 0 { sel.active = false }   // a press on a button keeps it (a Copy button reads it on release)
				sel.dragging = false
				continue
			}
			now := now_ms()
			if now - sel.click_ms < 450 && abs(e.pos.x - sel.click_pos.x) < 4 && abs(e.pos.y - sel.click_pos.y) < 4 {
				sel.clicks = sel.clicks % 3 + 1
			} else {
				sel.clicks = 1
			}
			sel.click_ms, sel.click_pos = now, e.pos
			idx := sel_index_at(s, b, e.pos)
			text := sel_text(s, b, context.temp_allocator)
			switch {
			case .Shift in e.mods && sel.active:
				sel.focus = {k, idx}
				sel.granularity = 1
			case sel.clicks == 2:
				lo, hi := word_at(text, idx)
				sel.anchor, sel.focus = {k, lo}, {k, hi}
				sel.word_lo, sel.word_hi = sel.anchor, sel.focus
				sel.granularity = 2
			case sel.clicks == 3:
				lo, hi := para_at(text, idx)
				sel.anchor, sel.focus = {k, lo}, {k, hi}
				sel.word_lo, sel.word_hi = sel.anchor, sel.focus
				sel.granularity = 3
			case:
				sel.anchor, sel.focus = {k, idx}, {k, idx}
				sel.granularity = 1
			}
			sel.active = true
			sel.dragging = true
		case .Mouse_Release:
			if e.button == .Left { sel.dragging = false }
		}
	}
	// dragging: the moving end follows the pointer, into the nearest selectable box
	if sel.dragging && s.mouse_valid {
		k, q := sel_nearest(s, s.mouse)
		if k != 0 {
			b := s.boxes[k]
			idx := sel_index_at(s, b, q)
			if sel.granularity == 1 {
				sel.focus = {k, idx}
			} else {
				// by words / paragraphs: the clicked unit stays selected, the other end snaps to a unit's edge
				text := sel_text(s, b, context.temp_allocator)
				lo, hi := word_at(text, idx)
				if sel.granularity == 3 { lo, hi = para_at(text, idx) }
				p := Sel_Pos{k, idx}
				if sel_before(s, p, sel.word_lo) {
					sel.anchor, sel.focus = sel.word_hi, {k, lo}
				} else {
					sel.anchor, sel.focus = sel.word_lo, {k, hi}
				}
			}
		}
	}
	// keys: when no field has the keyboard
	field := s.focus_key != 0 && s.boxes[s.focus_key] != nil && .Text_Input in s.boxes[s.focus_key].flags
	if !field {
		if sel.active && sel.anchor != sel.focus && key_press(.C, {.Ctrl}) {
			if s.clipboard_set != nil { s.clipboard_set(selected_text(s, context.temp_allocator)) }
		}
		if sel.active {
			fb := s.boxes[sel.focus.box]
			if fb != nil {
				text := sel_text(s, fb, context.temp_allocator)
				shift := platform.Modifiers{.Shift}
				switch {
				case key_press(.Left, shift):  sel_step(s, -1)
				case key_press(.Right, shift): sel_step(s, 1)
				case key_press(.Home, shift):  sel.focus.index = para_lo(text, sel.focus.index)
				case key_press(.End, shift):   sel.focus.index = para_hi(text, sel.focus.index)
				case key_press(.Up, shift):    sel_vertical(s, -1)
				case key_press(.Down, shift):  sel_vertical(s, 1)
				}
			}
		}
		if s.mouse_valid {
			if k := sel_box_at(s, s.mouse); k != 0 && key_press(.A, {.Ctrl}) { select_box(s, k) }
		}
	}
	// the text cursor over selectable text (a clickable box or a link over it keeps its own)
	if s.mouse_valid {
		k := sel_box_at(s, s.mouse)
		over := k != 0 && (s.hot_key == 0 || s.hot_key == k)
		if over && sel_kind(s.boxes[k]) == .Rich {
			d, l, o := rich_of(s.boxes[k])
			if rich_link_at(l, d.runs, s.mouse - o) >= 0 { over = false }
		}
		if over || sel.dragging { s.cursor_request = .Text }
	}
	after := [3]Sel_Pos{sel.anchor, sel.focus, {Key(u64(sel.active)), 0}}
	if after != before { sel_bump(s) }
	if sel.dragging { s.anim_busy = true }   // keep frames coming while the pointer drags
}

@(private) para_lo :: proc(text: string, i: int) -> int { lo, _ := para_at(text, i); return lo }
@(private) para_hi :: proc(text: string, i: int) -> int { _, hi := para_at(text, i); return hi }

// Whether p comes before q in the document.
@(private)
sel_before :: proc(s: ^State, p, q: Sel_Pos) -> bool {
	pp, qq := s.sel.pos_of[p.box], s.sel.pos_of[q.box]
	return pp < qq || (pp == qq && p.index < q.index)
}

// Shift+Left / Right: the moving end steps by a grapheme, into the box before / after at an edge.
@(private)
sel_step :: proc(s: ^State, dir: int) {
	sel := &s.sel
	b := s.boxes[sel.focus.box]
	text := sel_text(s, b, context.temp_allocator)
	i := sel.focus.index
	if dir > 0 {
		if i < len(text) { sel.focus.index = font.grapheme_next(text, i); return }
		p := sel.pos_of[sel.focus.box]
		if p + 1 < len(sel.order) { sel.focus = {sel.order[p + 1], 0} }
	} else {
		if i > 0 { sel.focus.index = font.grapheme_prev(text, i); return }
		p := sel.pos_of[sel.focus.box]
		if p > 0 {
			k := sel.order[p - 1]
			sel.focus = {k, len(sel_text(s, s.boxes[k], context.temp_allocator))}
		}
	}
}

// Shift+Up / Down: the moving end goes a line up / down at the same x (into the box above / below).
@(private)
sel_vertical :: proc(s: ^State, dir: int) {
	sel := &s.sel
	b := s.boxes[sel.focus.box]
	c := sel_caret(s, b, sel.focus.index)
	h := c.max.y - c.min.y
	p := Vec2{c.min.x, dir < 0 ? c.min.y - h * 0.5 : c.max.y + h * 0.5}
	k := sel_box_at(s, p)
	if k == 0 {
		// past the box: the next / previous selectable box, at the same x
		i := sel.pos_of[sel.focus.box] + dir
		if i < 0 || i >= len(sel.order) {
			text := sel_text(s, b, context.temp_allocator)
			sel.focus.index = dir < 0 ? 0 : len(text)
			return
		}
		k = sel.order[i]
		r := s.boxes[k].rect
		p.y = dir < 0 ? r.max.y - 1 : r.min.y + 1
	}
	sel.focus = {k, sel_index_at(s, s.boxes[k], p)}
}

// draw_box: the selection behind a selectable box's text.
@(private)
draw_selection :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	if !s.sel.active || s.sel.anchor == s.sel.focus { return }
	text := sel_text(s, b, context.temp_allocator)
	lo, hi := sel_range_of(s, b.key, len(text))
	if hi <= lo { return }
	col := tuned(color_from_tags(s, b.tags_key, "selection"))
	for r in sel_rects(s, b, lo, hi) { draw.rect(dc, r, col) }
}
