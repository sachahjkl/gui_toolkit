package ui

import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../draw"
import "../font"

// Find in page: the occurrences of a needle in the text the interface shows (labels, wrapped paragraphs, rich text),
// found after each layout in tree order (reading order) with their rectangles, whether on screen or scrolled away, and
// painted behind the text: every match in the theme's "find_match background", the current one in
// "find_current background". The application owns the search field and the navigation:
//
//   find(needle, scope)       every build while searching ("" stops); scope: the box whose subtree is searched (0: all)
//   find_matches()            the matches of the last layout (window coordinates, the rects of that layout)
//   find_set_current(i)       the match painted as current (-1: none)
//
// Matching ignores case (simple case folding, rune by rune). A match may span the runs of a rich paragraph; it is not
// found across boxes. Text the build did not make (a part folded away) is not searched.

Find_Match :: struct {
	box:  Key,
	rect: Rect,   // window coordinates (a match broken over two lines has a rect per line: one Find_Match each, same index)
	index: int,   // which occurrence: rects of one occurrence share it
}

@(private)
Find_State :: struct {
	needle:  string,             // as given (owned)
	scope:   Key,
	current: int,
	matches: [dynamic]Find_Match,
	count:   int,                // occurrences (an occurrence may have several rects)
	by_box:  map[Key][2]int,     // box -> [first, end) in matches
}

find :: proc(needle: string, scope: Key = 0) {
	f := &g.find
	f.scope = scope
	if needle == f.needle { return }
	delete(f.needle)
	f.needle = strings.clone(needle)
}

find_set_current :: proc(i: int) { g.find.current = i }

// The matches of the last layout, in reading order; Find_Match.index counts occurrences (find_count of them).
find_matches :: proc() -> []Find_Match { return g.find.matches[:] }
find_count :: proc() -> int { return g.find.count }

@(private)
find_destroy :: proc(s: ^State) {
	delete(s.find.needle)
	delete(s.find.matches)
	delete(s.find.by_box)
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
	clear(&f.matches)
	clear(&f.by_box)
	f.count = 0
	if f.needle == "" { return }
	top := s.root
	if f.scope != 0 {
		top = s.boxes[f.scope] or_else nil
		if top == nil { return }
	}
	hits := make([dynamic][2]int, context.temp_allocator)
	add :: proc(f: ^Find_State, b: ^Box, r: Rect, same: bool) {
		if !same { f.count += 1 }
		append(&f.matches, Find_Match{box = b.key, rect = r, index = f.count - 1})
	}
	// depth first, in order, without recursion
	b := top
	for b != nil {
		first := len(f.matches)
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
		// next in depth-first order, staying under `top`
		if b.first != nil { b = b.first; continue }
		for b != nil && b != top && b.next == nil { b = b.parent }
		if b == nil || b == top { break }
		b = b.next
	}
}

// Behind the text of a box: its matches.
@(private)
find_draw :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	span, ok := s.find.by_box[b.key]
	if !ok { return }
	all := color_from_tags(s, b.tags_key, "find_match background")
	cur := color_from_tags(s, b.tags_key, "find_current background")
	rad := 2 * s.scale
	for m in s.find.matches[span[0]:span[1]] {
		r := Rect{{m.rect.min.x - 1, m.rect.min.y}, {m.rect.max.x + 1, m.rect.max.y}}
		draw.rect(dc, r, m.index == s.find.current ? cur : all, rad)
	}
}
