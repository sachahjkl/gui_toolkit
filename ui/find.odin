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
// In a lazy column (lazy.odin) what is not near the view is not built, so it cannot be read at every frame. Then the build
// that reads everything is a sweep, made once for a needle, and the others stay lazy:
//
//   lz := lazy_begin(all = find_sweep())   // true when this build must make every item
//   find_all()                             // every match of the sweep, in the scope's content coordinates
//   find_pending()                         // a needle not swept yet: find_count says nothing about it
//   find_refresh()                         // the text changed where nothing is built: sweep again
//
// A sweep waits for the needle to rest (FIND_QUIET_MS: typing is not held up), and comes again when what is built no longer
// answers what it found (text that streams in, a part unfolded, another width), no sooner than FIND_SWEEP_GAP_MS. Between two,
// find_matches is what the last layout built, with the indices of the sweep.

Find_Match :: struct {
	box:  Key,
	rect: Rect,   // window coordinates (a match broken over two lines has a rect per line: one Find_Match each, same index)
	index: int,   // which occurrence: rects of one occurrence share it
}

// What the last sweep says of the needle. Unswept -> Swept (a sweep ran: `all` and `boxes` answer it) -> Stale (what is built
// differs from what it found, or the application says the text changed) -> Swept; a new needle, or a build that makes
// all of its text: Unswept.
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
	sweeping: bool,              // this build makes everything
	waiting:  bool,              // this build asks for the next one (the answer of a sweep): needs_frame
	changed_ms, swept_ms: f64,
	swept_w:  f32,               // the scope's width at the sweep
	swept_n:  int,               // occurrences found
	all:      [dynamic]Find_Match,   // the sweep's, in the scope's content
	boxes:    map[Key][2]int,        // box -> its first occurrence, how many
}

FIND_QUIET_MS     :: 80    // the needle rests this long before the text is swept
FIND_SWEEP_GAP_MS :: 500   // between two sweeps of one needle

find :: proc(needle: string, scope: Key = 0) {
	f := &gs().find
	f.scope = scope
	if needle == f.needle { return }
	delete(f.needle)
	f.needle = strings.clone(needle)
	f.changed_ms = build_now_ms()
	f.sweep = .Unswept
}

// In a build that may leave text out, before the lazy column: whether this build must make all of it (see above).
find_sweep :: proc() -> bool {
	s := gs()
	f := &s.find
	f.lazy = true
	if f.needle == "" || f.sweep == .Swept { return false }
	// (a wake at the end of the wait, not a frame at every refresh)
	left := f.sweep == .Unswept ? f.changed_ms + FIND_QUIET_MS - s.time_ms : f.swept_ms + FIND_SWEEP_GAP_MS - s.time_ms
	f.sweeping = left <= 0
	if !f.sweeping { wake_within(s, int(left) + WAKE_MARGIN_MS) }
	return f.sweeping
}

// The application knows the text changed where nothing is built (a page read above the view): a new sweep.
find_refresh :: proc() { f := &gs().find; if f.sweep == .Swept { f.sweep = .Stale } }

// The needle has not been swept yet: find_count is not its answer.
find_pending :: proc() -> bool {
	f := &gs().find
	return f.needle != "" && f.sweep == .Unswept
}

// Every match of the last sweep, in reading order: rects in the scope's content (from its top, whatever the scroll).
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

// After the layout: every match under the scope, in tree order.
@(private)
find_collect :: proc(s: ^State) {
	f := &s.find
	sweep := f.sweeping
	part := f.lazy && !sweep   // what is built is a part of the text: the indices are the sweep's
	f.lazy, f.sweeping = false, false
	clear(&f.matches)
	clear(&f.by_box)
	if !part { f.count = 0 }
	if !part && !sweep { f.sweep = .Unswept }
	if f.needle == "" { f.count, f.sweep = 0, .Unswept; return }
	if part && f.sweep == .Unswept { f.count = 0; return }
	top := s.root
	if f.scope != 0 {
		top = s.boxes[f.scope] or_else nil
		// a scope not built this build (a page left while the needle stays): its subtree points into freed frame memory
		if top == nil || top.last_build != s.build_index { return }
	}
	if part && top.size.x != f.swept_w { f.sweep = .Stale }
	if sweep { clear(&f.boxes) }
	hits := make([dynamic][2]int, context.temp_allocator)
	add :: proc(f: ^Find_State, b: ^Box, r: Rect, same: bool) {
		if !same { f.count += 1 }
		append(&f.matches, Find_Match{box = b.key, rect = r, index = f.count - 1})
	}
	// depth first, in order, without recursion
	b := top
	for b != nil {
		first := len(f.matches)
		reads := b.custom == rich_draw || (.Draw_Text in b.flags && b.text != "")
		found: [2]int
		known := false
		if reads && part {
			found, known = f.boxes[b.key]
			f.count = known ? found[0] : f.swept_n
		}
		before := f.count
		if b.custom == rich_draw {
			d := (^Rich_Draw)(b.custom_user)
			l := rich_layout_cached(d.runs, d.ctx, b.size.x - 2 * b.text_pad, d.max_lines, b.text_align, d.version)
			text := rich_text(d.runs)
			clear(&hits)
			find_in(text, f.needle, &hits)
			o := Vec2{b.rect.min.x + b.text_pad, b.rect.min.y + b.text_pad}
			for h in hits {
				for r, k in rich_range_rects(l, s.fonts, d.runs, h[0], h[1]) {
					add(f, b, {r.min + o, r.max + o}, k > 0)
				}
			}
		} else if .Draw_Text in b.flags && b.text != "" {
			clear(&hits)
			find_in(b.text, f.needle, &hits)
			if len(hits) > 0 {
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
							add(f, b, {{math.round(x) + x0, y}, {math.round(x) + x1, y + lh}}, lo > h[0])
						}
						y += lh
					}
				} else {
					pos := text_origin(s, b, {b.text_dim.x, b.text_dim.y})
					for h in hits {
						x0 := font.text_width(s.fonts, b.font, b.font_size, b.text[:h[0]])
						x1 := font.text_width(s.fonts, b.font, b.font_size, b.text[:h[1]])
						add(f, b, {{pos.x + x0, pos.y - m.ascent}, {pos.x + x1, pos.y + m.descent}}, false)
					}
				}
			}
		}
		if len(f.matches) > first { f.by_box[b.key] = {first, len(f.matches)} }
		if reads && part && (known ? f.count - before != found[1] : f.count != before) { f.sweep = .Stale }
		if sweep && f.count > before { f.boxes[b.key] = {before, f.count - before} }
		// next in depth-first order, staying under `top`
		if b.first != nil { b = b.first; continue }
		for b != nil && b != top && b.next == nil { b = b.parent }
		if b == nil || b == top { break }
		b = b.next
	}
	if part { f.count = f.swept_n }
	if sweep {
		f.sweep = .Swept
		f.swept_ms, f.swept_w, f.swept_n = s.time_ms, top.size.x, f.count
		f.waiting = true   // (one more frame: the application reads the answer, says the count, goes to the first match)
		clear(&f.all)
		for m in f.matches {
			c := m
			o := top.rect.min - top.view_off
			c.rect = {m.rect.min - o, m.rect.max - o}
			append(&f.all, c)
		}
	}
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
		draw.rect(dc, find_match_rect(s, m), m.index == s.find.current ? cur : all, rad)
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
