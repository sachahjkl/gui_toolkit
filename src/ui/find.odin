package ui

import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../draw"
import "../font"

// Find in page: the occurrences of a needle in the text the interface shows (labels, wrapped paragraphs, rich text),
// found after each layout in tree order (reading order) with their rectangles, whether on screen or scrolled away, and
// painted behind the text: every match in the theme's "find_match background", the current one in
// "find_current background", and its letters in "find_text" (whatever colour the text around them has: amber code on a
// match does not read). The application owns the search field and the navigation:
//
//   find(needle, scope)       every build while searching ("" stops); scope: the box whose subtree is searched (0: all)
//   find_matches()            the matches of the last layout (window coordinates, the rects of that layout)
//   find_set_current(i)       the match painted as current (-1: none)
//
// Matching ignores case (simple case folding, rune by rune). A match may span the runs of a rich paragraph; it is not
// found across boxes. Text the build did not make (a part folded away) is not searched.
//
// In a lazy column (lazy.odin) what is not near the view is not built, so it cannot be read at every frame. Then the text is read
// by a sweep, once for a needle, a slice of the items at each frame from the top down (what is above a slice was built before
// it: its place is known), each frame staying a frame whatever the length of the column; the others stay lazy:
//
//   lz := lazy_begin(sweep = find_sweep())   // the items this build must make for the sweep ({}: none)
//   find_all()                               // every match of the last finished sweep, in the scope's content coordinates
//   find_pending()                           // a needle not swept to its end yet: find_count is what was read so far
//   find_progress()                          // how far the sweep under way is (0..1)
//   find_refresh()                           // the text changed where nothing is built: sweep again
//
// A sweep waits for the needle to rest (FIND_QUIET_MS: typing is not held up), and comes again when what is built no longer
// answers what it found (text that streams in, a part unfolded, another width), no sooner than FIND_SWEEP_GAP_MS; until it ends,
// what the last one found stands. Between two, find_matches is what the last layout built, with the indices of the sweep (-1: a
// match no finished sweep has counted).

Find_Match :: struct {
	box:  Key,
	rect: Rect,   // window coordinates (a match broken over two lines has a rect per line: one Find_Match each, same index)
	index: int,   // which occurrence: rects of one occurrence share it (-1: not counted yet)
}

// What the sweeps say of the needle. Unswept (none finished) -> Swept (one ended: `all` and `boxes` answer it) -> Stale (what is
// built differs from what it found, or the application says the text changed) -> Swept again once the next one ends; a new
// needle, or a build that makes all of its text: Unswept.
@(private)
Find_Sweep :: enum u8 { Unswept, Swept, Stale }

@(private)
Find_State :: struct {
	needle:  string,             // as given (owned)
	scope:   Key,
	current: int,
	matches: [dynamic]Find_Match,
	count:   int,                // occurrences (an occurrence may have several rects)
	by_box:  map[Key][2]int,     // box -> [first, end) in matches
	in_match: bool,              // find_paint_text: painting the letters of a match (a rich paragraph: every run in b.text_color)
	lazy:     bool,              // find_sweep was asked in this build: what is built may be a part of the text
	sweep:    Find_Sweep,
	waiting:  bool,              // this build asks for the next one (a sweep under way, or its answer): needs_frame
	changed_ms, swept_ms: f64,
	swept_w:  f32,               // the scope's width at the last finished sweep
	swept_n:  int,               // the occurrences it found
	all:      [dynamic]Find_Match,   // its matches, in the scope's content
	boxes:    map[Key][2]int,        // box -> its first occurrence, how many
	// the sweep under way: what it has read so far, all and boxes once it ends
	run:        bool,
	run_w:      f32,             // the scope's width it began at (another: it begins again)
	next_item:  int,             // the first item it has not read
	asked:      [2]int,          // the items this build makes for it (find_sweep)
	total:      int,             // the items of the column, at the last build (lazy_end)
	chunk:      [dynamic]Key,    // the items of the sweep this build made, in order (lazy_item)
	built:      [dynamic]Key,    // every item of the column this build made (the others' boxes there are not items)
	column:     Key,             // the lazy column they are in (the text of the scope around its items: read by the first slice and the last)
	next_all:   [dynamic]Find_Match,
	next_boxes: map[Key][2]int,
	next_n:     int,
}

// One match's rect in a box, and whether it goes on with the occurrence before it (a match broken over two lines).
@(private)
Find_Hit :: struct { rect: Rect, same: bool }

FIND_QUIET_MS     :: 80    // the needle rests this long before the text is swept
FIND_SWEEP_GAP_MS :: 500   // between two sweeps of one needle
FIND_SWEEP_ITEMS  :: 24    // items a sweep reads at each frame

find :: proc(needle: string, scope: Key = 0) {
	f := &gs().find
	f.scope = scope
	if needle == f.needle { return }
	delete(f.needle)
	f.needle = strings.clone(needle)
	f.changed_ms = build_now_ms()
	f.sweep, f.run, f.swept_n = .Unswept, false, 0
	clear(&f.all)   // (another needle's: its indices mean nothing for this one)
	clear(&f.boxes)
}

// In a build that may leave text out, before the lazy column: the items this build must make for the sweep, [first, end) in the
// column's order ({}: none). See above.
find_sweep :: proc() -> [2]int {
	s := gs()
	f := &s.find
	f.lazy = true
	f.asked = {}
	if f.needle == "" || (f.sweep == .Swept && !f.run) { return {} }
	if !f.run {
		// (a wake at the end of the wait, not a frame at every refresh)
		left := f.sweep == .Unswept ? f.changed_ms + FIND_QUIET_MS - s.time_ms : f.swept_ms + FIND_SWEEP_GAP_MS - s.time_ms
		if left > 0 { wake_within(s, int(left) + WAKE_MARGIN_MS); return {} }
		find_run_begin(f, -1)
	}
	f.asked = {f.next_item, f.next_item + FIND_SWEEP_ITEMS}
	return f.asked
}

@(private)
find_run_begin :: proc(f: ^Find_State, width: f32) {
	f.run, f.run_w, f.next_item, f.next_n = true, width, 0, 0
	clear(&f.next_all)
	clear(&f.next_boxes)
}

// The application knows the text changed where nothing is built (a page read above the view): a new sweep.
find_refresh :: proc() { f := &gs().find; if f.sweep == .Swept { f.sweep = .Stale } }

// No sweep of the needle has ended yet: find_count is what the one under way has read so far.
find_pending :: proc() -> bool {
	f := &gs().find
	return f.needle != "" && f.sweep == .Unswept
}

// How far the sweep under way is, 0..1 (1: none under way).
find_progress :: proc() -> f32 {
	f := &gs().find
	if !f.run || f.total <= 0 { return 1 }
	return clamp(f32(f.next_item) / f32(f.total), 0, 1)
}

// Every match of the last finished sweep, in reading order: rects in the scope's content (from its top, whatever the scroll).
find_all :: proc() -> []Find_Match { return gs().find.all[:] }

find_set_current :: proc(i: int) { gs().find.current = i }

// The matches of the last layout, in reading order; Find_Match.index counts occurrences (find_count of them).
find_matches :: proc() -> []Find_Match { return gs().find.matches[:] }
find_count :: proc() -> int { return gs().find.count }

@(private)
find_destroy :: proc(s: ^State) {
	delete(s.find.needle)
	delete(s.find.matches)
	delete(s.find.by_box)
	delete(s.find.all)
	delete(s.find.boxes)
	delete(s.find.chunk)
	delete(s.find.built)
	delete(s.find.next_all)
	delete(s.find.next_boxes)
}

// Byte offsets of the occurrences of `needle` in `hay`, ignoring case.
@(private)
find_in :: proc(hay, needle: string, out: ^[dynamic][2]int) {
	if needle == "" || len(hay) < 1 { return }
	n0, _ := utf8.decode_rune_in_string(needle)
	n0 = unicode.to_lower(n0)
	i := 0
	for i < len(hay) {
		r, w := utf8.decode_rune_in_string(hay[i:])
		if unicode.to_lower(r) == n0 {
			// the rest, rune by rune
			hi := i + w
			_, ni := utf8.decode_rune_in_string(needle)
			ok := true
			for ni < len(needle) {
				if hi >= len(hay) { ok = false; break }
				a, aw := utf8.decode_rune_in_string(hay[hi:])
				b, bw := utf8.decode_rune_in_string(needle[ni:])
				if unicode.to_lower(a) != unicode.to_lower(b) { ok = false; break }
				hi += aw
				ni += bw
			}
			if ok {
				append(out, [2]int{i, hi})
				i = hi
				continue
			}
		}
		i += w
	}
}

// The matches of the needle in one box's text, in its layout (window coordinates). False: the box shows no text.
@(private)
find_box_hits :: proc(s: ^State, b: ^Box, needle: string, hits: ^[dynamic][2]int, out: ^[dynamic]Find_Hit) -> (reads: bool) {
	clear(out)
	if b.custom == rich_draw {
		d := (^Rich_Draw)(b.custom_user)
		l := rich_layout_cached(d.runs, d.ctx, b.size.x - 2 * b.text_pad, d.max_lines, b.text_align, d.version)
		text := rich_text(d.runs)
		clear(hits)
		find_in(text, needle, hits)
		o := Vec2{b.rect.min.x + b.text_pad, b.rect.min.y + b.text_pad}
		for h in hits {
			for r, k in rich_range_rects(l, s.fonts, d.runs, h[0], h[1]) { append(out, Find_Hit{{r.min + o, r.max + o}, k > 0}) }
		}
		return true
	}
	if .Draw_Text not_in b.flags || b.text == "" { return false }
	clear(hits)
	find_in(b.text, needle, hits)
	if len(hits) == 0 { return true }
	m := font.metrics(s.fonts, b.font, b.font_size)
	if .Text_Wrap in b.flags {
		lh := math.ceil(m.line_height)
		lines := wrap_lines_cached(b.font, b.font_size, b.text, b.size.x - 2 * b.text_pad)
		y := (b.rect.min.y + b.rect.max.y) * 0.5 - f32(len(lines)) * lh * 0.5
		for l in lines {
			line := b.text[l[0]:l[1]]
			lw := font.text_width(s.fonts, b.font, b.font_size, line)
			x: f32
			switch b.text_align {
			case .Left:   x = b.rect.min.x + b.text_pad
			case .Center: x = (b.rect.min.x + b.rect.max.x - lw) * 0.5
			case .Right:  x = b.rect.max.x - b.text_pad - lw
			}
			for h in hits {
				lo, hi := max(h[0], l[0]), min(h[1], l[1])
				if hi <= lo { continue }
				x0 := font.text_width(s.fonts, b.font, b.font_size, b.text[l[0]:lo])
				x1 := font.text_width(s.fonts, b.font, b.font_size, b.text[l[0]:hi])
				append(out, Find_Hit{{{math.round(x) + x0, y}, {math.round(x) + x1, y + lh}}, lo > h[0]})
			}
			y += lh
		}
	} else {
		pos := text_origin(s, b, {b.text_dim.x, b.text_dim.y})
		for h in hits {
			x0 := font.text_width(s.fonts, b.font, b.font_size, b.text[:h[0]])
			x1 := font.text_width(s.fonts, b.font, b.font_size, b.text[:h[1]])
			append(out, Find_Hit{{{pos.x + x0, pos.y - m.ascent}, {pos.x + x1, pos.y + m.descent}}, false})
		}
	}
	return true
}

// The next box under `top` in depth-first order (nil: none left).
@(private = "file")
find_next_box :: proc(b, top: ^Box) -> ^Box {
	if b.first != nil { return b.first }
	n := b
	for n != nil && n != top && n.next == nil { n = n.parent }
	if n == nil || n == top { return nil }
	return n.next
}

// After the layout: the matches of what is built, under the scope, in tree order; and the sweep's slice of this build.
@(private)
find_collect :: proc(s: ^State) {
	f := &s.find
	lazy := f.lazy
	f.lazy = false
	defer { clear(&f.chunk); clear(&f.built) }
	clear(&f.matches)
	clear(&f.by_box)
	if f.needle == "" { f.count, f.sweep, f.run = 0, .Unswept, false; return }
	if !lazy { f.count = 0 }
	top := s.root
	if f.scope != 0 {
		top = s.boxes[f.scope] or_else nil
		// a scope not built this build (a page left while the needle stays): its subtree points into freed frame memory
		if top == nil || top.last_build != s.build_index { return }
	}
	hits := make([dynamic][2]int, context.temp_allocator)
	found := make([dynamic]Find_Hit, context.temp_allocator)

	if !lazy {
		// everything is built: this build's matches are the answer
		f.count, f.sweep, f.run = 0, .Unswept, false
		for b := top; b != nil; b = find_next_box(b, top) {
			find_box_hits(s, b, f.needle, &hits, &found)
			first := len(f.matches)
			for h in found {
				if !h.same { f.count += 1 }
				append(&f.matches, Find_Match{box = b.key, rect = h.rect, index = f.count - 1})
			}
			if len(f.matches) > first { f.by_box[b.key] = {first, len(f.matches)} }
		}
		return
	}

	// a part of the text is built: the indices are those of the last finished sweep, and what differs from it calls for another
	if f.sweep == .Swept && top.size.x != f.swept_w { f.sweep = .Stale }
	for b := top; b != nil; b = find_next_box(b, top) {
		if !find_box_hits(s, b, f.needle, &hits, &found) { continue }
		known, ok := f.boxes[b.key]
		n := 0
		for h in found { if !h.same { n += 1 } }
		if f.sweep == .Swept && (ok ? known[1] != n : n > 0) { f.sweep = .Stale }
		first := len(f.matches)
		k := -1
		for h in found {
			if !h.same { k += 1 }
			append(&f.matches, Find_Match{box = b.key, rect = h.rect, index = ok && k < known[1] ? known[0] + k : -1})
		}
		if len(f.matches) > first { f.by_box[b.key] = {first, len(f.matches)} }
	}

	// the sweep's slice: the items it asked for, read in order into what it has so far
	if f.run {
		if f.run_w < 0 { f.run_w = top.size.x }
		if top.size.x != f.run_w {
			find_run_begin(f, top.size.x)   // (another width: what it read is placed otherwise now)
		} else {
			o := top.rect.min - top.view_off
			read :: proc(s: ^State, f: ^Find_State, b: ^Box, o: Vec2, hits: ^[dynamic][2]int, found: ^[dynamic]Find_Hit) {
				find_box_hits(s, b, f.needle, hits, found)
				if len(found) == 0 { return }
				first := f.next_n
				for h in found {
					if !h.same { f.next_n += 1 }
					append(&f.next_all, Find_Match{box = b.key, rect = {h.rect.min - o, h.rect.max - o}, index = f.next_n - 1})
				}
				f.next_boxes[b.key] = {first, f.next_n - first}
			}
			// in reading order: the scope's text before the column (first slice), the slice's items, the text after it (last slice)
			opening, closing := f.asked[0] == 0, f.asked[1] >= f.total
			after := false
			for b := top; b != nil; {
				if b.key != f.column || b.last_build != s.build_index {
					if after ? closing : opening { read(s, f, b, o, &hits, &found) }
					b = find_next_box(b, top)
					continue
				}
				// its children: the items (those of the slice read), and what the application put there before them and after them
				items := make(map[Key]bool, len(f.built), context.temp_allocator)
				for k in f.built { items[k] = false }
				for k in f.chunk { items[k] = true }
				for c := b.first; c != nil; c = c.next {
					slice, item := items[c.key]
					if item { after = true }
					if item ? !slice : !(after ? closing : opening) { continue }
					for d := c; d != nil; d = find_next_box(d, c) { read(s, f, d, o, &hits, &found) }
				}
				after = true
				// past the column's subtree
				n := b
				for n != nil && n != top && n.next == nil { n = n.parent }
				b = n == nil || n == top ? nil : n.next
			}
			if f.asked[1] > f.asked[0] { f.next_item = f.asked[1] }
			if f.next_item >= f.total {
				// read to its end: what it found is the answer now
				f.all, f.next_all = f.next_all, f.all
				f.boxes, f.next_boxes = f.next_boxes, f.boxes
				clear(&f.next_all)
				clear(&f.next_boxes)
				f.swept_n, f.sweep, f.run = f.next_n, .Swept, false
				f.swept_ms, f.swept_w = s.time_ms, top.size.x
			}
		}
		f.waiting = true   // (the next slice, or the answer read by the application: the frame after)
	}
	f.count = f.sweep == .Unswept ? f.next_n : f.swept_n
}

@(private = "file") FIND_MATCH_RADIUS_PX :: 2

// What a match of a box covers (a pixel beyond its letters on each side).
@(private = "file")
find_match_rect :: proc(s: ^State, m: Find_Match) -> Rect {
	return {{m.rect.min.x - s.scale, m.rect.min.y}, {m.rect.max.x + s.scale, m.rect.max.y}}
}

// Behind the text of a box: its matches.
@(private)
find_draw :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	span, ok := s.find.by_box[b.key]
	if !ok { return }
	all := color_from_tags(s, b.tags_key, "find_match background")
	cur := color_from_tags(s, b.tags_key, "find_current background")
	rad := FIND_MATCH_RADIUS_PX * s.scale
	for m in s.find.matches[span[0]:span[1]] {
		draw.rect(dc, find_match_rect(s, m), m.index >= 0 && m.index == s.find.current ? cur : all, rad)
	}
}

// The text of a box (`paint`, with b.text_color) around its matches, then in their rects in "find_text". Never both in one
// place: the edges of light letters under dark ones would show as a halo.
@(private)
find_paint_text :: proc(s: ^State, dc: ^draw.Context, b: ^Box, paint: proc(s: ^State, dc: ^draw.Context, b: ^Box)) {
	span, ok := s.find.by_box[b.key]
	if !ok { paint(s, dc, b); return }
	clipped :: proc(s: ^State, dc: ^draw.Context, b: ^Box, r: Rect, paint: proc(s: ^State, dc: ^draw.Context, b: ^Box)) {
		if r.max.x <= r.min.x || r.max.y <= r.min.y { return }
		draw.push_clip(dc, r)
		paint(s, dc, b)
		draw.pop_clip(dc)
	}
	matches := s.find.matches[span[0]:span[1]]
	// around them: the bands between their rows, and on each row the pieces between them (reading order: rows top down)
	area := draw.current_clip(dc)
	y := area.min.y
	for i := 0; i < len(matches); {
		top, bottom := matches[i].rect.min.y, matches[i].rect.max.y
		j := i
		for j < len(matches) && matches[j].rect.min.y == top { j += 1 }
		clipped(s, dc, b, {{area.min.x, y}, {area.max.x, top}}, paint)
		row := make([]Rect, j - i, context.temp_allocator)
		for m, k in matches[i:j] { row[k] = find_match_rect(s, m) }
		slice.sort_by(row, proc(p, q: Rect) -> bool { return p.min.x < q.min.x })
		x := area.min.x
		for r in row {
			clipped(s, dc, b, {{x, top}, {r.min.x, bottom}}, paint)
			x = max(x, r.max.x)
		}
		clipped(s, dc, b, {{x, top}, {area.max.x, bottom}}, paint)
		y = max(y, bottom)
		i = j
	}
	clipped(s, dc, b, {{area.min.x, y}, area.max}, paint)
	// in them
	saved := b.text_color
	defer b.text_color = saved
	b.text_color = color_from_tags(s, b.tags_key, "find_text")
	s.find.in_match = true
	defer s.find.in_match = false
	for m in matches { clipped(s, dc, b, find_match_rect(s, m), paint) }
}
