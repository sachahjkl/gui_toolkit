package ui

import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../draw"
import "../font"

// Find in a view (src/md/features/find-in-view.md): one find per window, over one view, with its bar (find_bar.odin).
// The model is rows: a view that builds only part of its content gives them (`Text_Rows`, the selection's: a lazy column's
// `rows` does it), each with an identity, a stamp and its whole text (folded parts included); the matches are counted
// from that text in bounded slices at each frame, whatever is built, and found again in the built boxes to be lit. A view
// that builds all of its content gives no rows: its built boxes are searched after each layout (box mode).
//
//   ui.find_open(view.key)                 // Ctrl+F, the marks' magnifier: open, or focus the field when open there
//   res := ui.find_bar(view, {scopes = ...})   // at each build of the view: the bar while the find is open over it
//   ui.find_rows(view.key, rows)           // a view with rows and no lazy column (lazy_begin(rows = ...) does it)
//   ui.find_place_row(row, top)            // where a row starts in the content, for the ticks (a lazy column does it)
//   ui.find_count(), ui.find_index(), ui.find_pending(), ui.find_matches(), ui.find_row_matches(row)
//
// Painting: every match in the theme's "find_match background", the current one in "find_current background", their
// letters in "find_text"; a tick on the view's scroll bar for each match (scrollbar.odin).

Find_Match :: struct {
	box:   Key,
	rect:  Rect,   // window coordinates (a match broken over two lines has a rect per line: one Find_Match each, same index)
	index: int,    // which occurrence: rects of one occurrence share it (-1: lit, but not told apart: a row with a part folded)
}

// A subset of a view's rows the bar can restrict the find to ("Prompts"). keep(rows.user, row): searched; nil: every row.
Find_Scope :: struct {
	name: string,
	keep: proc(user: rawptr, row: int) -> bool,
}

// What the find's current match is, for a view that draws its own rows (a terminal): `moved` in the build after a step or
// a new needle chose it, the program brings it in. row -1: none, or the view is in box mode.
Find_Result :: struct {
	moved:      bool,
	row:        int,
	start, end: int,   // bytes of the row's whole text
}

// The way of the current match to the screen (find-in-view.md, "The current match's way to the screen").
@(private)
Find_Goal :: enum u8 { None, Seek, Reveal }

// A row's place in the order: what was known of it at its last visit.
@(private)
Find_Row :: struct {
	id, stamp: u64,
	n:         i32,    // its matches for the query `gen` (0 when the scope leaves it out)
	gen:       u32,    // the query it was counted for (0: never)
	kept:      bool,   // the scope searches it
}

// A row's text, cached by its identity while the find is open.
@(private)
Find_Text :: struct {
	text:  string,   // its whole text (owned)
	stamp: u64,
	n:     i32,
	gen:   u32,
	kept:  bool,
	read:  bool,
}

@(private)
Find_Built_Row :: struct { row: int, key: Key }

// What the ticks were merged for: merged again when it changes.
@(private)
Find_Ticks_Made :: struct {
	counted, placed: u64,
	track, content, gap: f32,
}

@(private)
Find_State :: struct {
	// the bar (find_bar.odin)
	open:        bool,
	view:        Key,            // the view it is open over
	field:       Line_Edit,
	focus_field: bool,           // the field takes the keyboard when it is next built
	back_focus:  Key,            // what had the keyboard when it opened: given back when it closes
	match_case, whole_word: bool,
	scope:       int,
	bar_build:   u64,            // the build that called find_bar for the open view (another: no needle in that build)
	bar_key:     Key,
	in_bar:      bool,           // the keyboard is in the bar (its field or its buttons), at the last build
	keep:        proc(user: rawptr, row: int) -> bool,   // the scope's (find_bar, this build)
	step:        int,            // a step asked in this build (+1, -1), made after the layout
	// the query
	needle:      string,         // the active needle (owned; "": none)
	gen:         u32,            // counts the changes of needle, options and scope
	// the rows (find_rows, this build)
	rows:        Text_Rows,
	rows_build:  u64,
	lazy_build:  u64,            // a lazy column fed them in that build (lazy_item builds want_row)
	version:     u64,            // rows.version at the last build
	order:       [dynamic]Find_Row,
	tree:        Fenwick(i32),   // over the rows' counts
	total:       int,
	cache:       map[u64]Find_Text,
	cursor, left, unknown: int,  // the pass: where it reads, rows still to visit, rows not known for `gen`
	by_rows:     bool,           // the last build searched rows (else boxes)
	built:       [dynamic]Find_Built_Row,   // the rows a lazy column built in this build, in order
	tops:        [dynamic]f32,   // where each row starts in the view's content (-1: not placed)
	placed, counted: u64,        // count the changes of the places, of the counts (the ticks)
	want_row:    int,            // the row the next build makes wherever it is (-1: none)
	// the current match
	has_cur:     bool,           // a current match is chosen (cur_row -1: its row's index is not known yet)
	cur_id:      u64,
	cur_row, cur_occ: int,       // -1: none
	cur_seen:    bool,           // the pass under way met its row
	cur_range:   [2]int,
	current:     int,            // its ordinal, painted (-1: none)
	goal:        Find_Goal,
	reveal_builds: int,
	picked:      bool,           // a first match was chosen for this needle
	moved:       bool,           // the current changed: find_bar's result says it once
	// what is lit, of the last layout
	matches:     [dynamic]Find_Match,
	count:       int,            // box mode: the occurrences found
	by_box:      map[Key][2]int, // box -> [first, end) in matches
	in_match:    bool,           // find_paint_text: painting the letters of a match (a rich paragraph: every run in b.text_color)
	lit:         bool,           // the last build lit the view: its ticks are drawn
	box_tops:    [dynamic]f32,   // box mode: each occurrence's top in the view's content
	ticks:       [dynamic]f32,   // merged ticks, from the track's top (pixels)
	ticks_made:  Find_Ticks_Made,
	waiting:     bool,           // this build asks for the next one: needs_frame
}

// One match's rect in a box, and whether it goes on with the occurrence before it (a match broken over two lines).
@(private)
Find_Hit :: struct { rect: Rect, same: bool }

FIND_ROWS_PER_FRAME  :: 2048      // rows a pass visits at each frame, at most
FIND_BYTES_PER_FRAME :: 1 << 18   // bytes a pass reads or matches at each frame (at least one row)
FIND_REVEAL_BUILDS   :: 4         // builds a revealed part has to show its match
@(private = "file") FIND_TOP_MARGIN_EM :: 1
@(private = "file") FIND_BOTTOM_MARGIN_EM :: 3
@(private = "file") FIND_LAND_AT :: 0.35   // where a match brought in lands, from the view's top

// The rows of `view`, for this build (inside the open find's view; lazy_begin(rows = ...) calls it). The last call of a
// build wins: one source of rows per view.
find_rows :: proc(view: Key, rows: Text_Rows) {
	s := gs()
	f := &s.find
	if !f.open || view != f.view || rows.text == nil { return }
	f.rows, f.rows_build = rows, s.build_index
}

// Where row `row` starts in the open find's view's content, at this build (a lazy column's `y` before its item).
find_place_row :: proc(row: int, top: f32) {
	f := &gs().find
	if row < 0 || row >= len(f.tops) || f.tops[row] == top { return }
	f.tops[row] = top
	f.placed += 1
}

// The matches counted (rows: of every row, built or not; box mode: of the last layout).
find_count :: proc() -> int {
	f := &gs().find
	if f.needle == "" { return 0 }
	return f.by_rows ? f.total : f.count
}

// The current match's ordinal (-1: none).
find_index :: proc() -> int { return gs().find.current }

// Some row is not counted for the needle yet: find_count is what is known so far.
find_pending :: proc() -> bool { f := &gs().find; return f.needle != "" && f.unknown > 0 }

// The matches lit by the last layout, in reading order.
find_matches :: proc() -> []Find_Match { return gs().find.matches[:] }

// The byte ranges of the needle in row `row`'s whole text (a view that paints its own rows). Temp memory unless `allocator`.
find_row_matches :: proc(row: int, allocator := context.temp_allocator) -> [][2]int {
	f := &gs().find
	if f.needle == "" || row < 0 || row >= len(f.order) { return nil }
	e := f.order[row]
	t, ok := f.cache[e.id]
	if !ok || !e.kept || e.gen != f.gen { return nil }
	out := make([dynamic][2]int, allocator)
	find_in(t.text, f.needle, f.match_case, f.whole_word, &out)
	return out[:]
}

@(private)
find_destroy :: proc(s: ^State) {
	find_rows_free(&s.find)
	f := &s.find
	delete(f.needle)
	line_edit_destroy(&f.field)
	delete(f.order)
	fenwick_destroy(&f.tree)
	delete(f.cache)
	delete(f.built)
	delete(f.tops)
	delete(f.matches)
	delete(f.by_box)
	delete(f.box_tops)
	delete(f.ticks)
}

// The cache and the order go (the find closed, or its view gives no rows).
@(private)
find_rows_free :: proc(f: ^Find_State) {
	for _, t in f.cache { delete(t.text) }
	clear(&f.cache)
	clear(&f.order)
	fenwick_clear(&f.tree)
	clear(&f.tops)
	f.total, f.cursor, f.left, f.unknown, f.rows_build, f.version = 0, 0, 0, 0, 0, 0
}

// The query changed (needle, options, scope): every row is counted again, from its cached text.
@(private)
find_query_changed :: proc(f: ^Find_State) {
	f.gen += 1
	for &e in f.order { e.n, e.kept = 0, false }
	fenwick_zero(&f.tree)
	f.total = 0
	f.unknown, f.left, f.cursor = len(f.order), len(f.order), 0
	find_drop_current(f)
	f.picked = false
	f.counted += 1
}

// ---- the Fenwick tree over the rows' counts (fenwick.odin)

@(private = "file")
fen_add :: proc(f: ^Find_State, i: int, d: i32) {
	if d == 0 { return }
	fenwick_add(&f.tree, i, d)
	f.total += int(d)
}

// The matches in rows [0, i).
@(private = "file")
fen_sum :: proc(f: ^Find_State, i: int) -> int {
	return int(fenwick_sum(&f.tree, i))
}

// The row that holds the k-th match (0-based; k < total).
@(private = "file")
fen_find :: proc(f: ^Find_State, k: int) -> int {
	// (the most rows whose matches are <= k: the next row, that number 0-based, holds match k)
	return fenwick_find(&f.tree, i32(k))
}

// ---- matching

@(private = "file")
find_word_rune :: proc(r: rune) -> bool { return unicode.is_letter(r) || unicode.is_digit(r) || r == '_' }

// Byte ranges of the occurrences of `needle` in `hay`: case folded rune by rune unless `match_case`; `whole_word`: the
// neighbours of a match are not letters, digits or '_'.
@(private)
find_in :: proc(hay, needle: string, match_case, whole_word: bool, out: ^[dynamic][2]int) {
	if needle == "" || len(hay) < 1 { return }
	fold :: proc(r: rune, match_case: bool) -> rune { return match_case ? r : unicode.to_lower(r) }
	n0, _ := utf8.decode_rune_in_string(needle)
	n0 = fold(n0, match_case)
	i := 0
	for i < len(hay) {
		r, w := utf8.decode_rune_in_string(hay[i:])
		if fold(r, match_case) == n0 {
			hi := i + w
			_, ni := utf8.decode_rune_in_string(needle)
			ok := true
			for ni < len(needle) {
				if hi >= len(hay) { ok = false; break }
				a, aw := utf8.decode_rune_in_string(hay[hi:])
				b, bw := utf8.decode_rune_in_string(needle[ni:])
				if fold(a, match_case) != fold(b, match_case) { ok = false; break }
				hi += aw
				ni += bw
			}
			if ok && whole_word {
				if i > 0 { p, _ := utf8.decode_last_rune_in_string(hay[:i]); if find_word_rune(p) { ok = false } }
				if hi < len(hay) { q, _ := utf8.decode_rune_in_string(hay[hi:]); if find_word_rune(q) { ok = false } }
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

@(private = "file")
find_count_in :: proc(f: ^Find_State, hay: string) -> i32 {
	hits := make([dynamic][2]int, context.temp_allocator)
	find_in(hay, f.needle, f.match_case, f.whole_word, &hits)
	return i32(len(hits))
}

// The matches of the needle in one box's text, in its layout (window coordinates). False: the box shows no text.
@(private)
find_box_hits :: proc(s: ^State, b: ^Box, hits: ^[dynamic][2]int, out: ^[dynamic]Find_Hit) -> (reads: bool) {
	f := &s.find
	clear(out)
	if b.custom == rich_draw {
		d := (^Rich_Draw)(b.custom_user)
		l := rich_layout_cached(d.runs, d.ctx, b.size.x - 2 * b.text_pad, d.max_lines, b.text_align, d.version)
		text := rich_text(d.runs)
		clear(hits)
		find_in(text, f.needle, f.match_case, f.whole_word, hits)
		o := b.rect.min + rich_inset(b, d, l)
		for h in hits {
			for r, k in rich_range_rects(l, s.fonts, d.runs, h[0], h[1]) { append(out, Find_Hit{{r.min + o, r.max + o}, k > 0}) }
		}
		return true
	}
	if .Draw_Text not_in b.flags || b.text == "" { return false }
	clear(hits)
	find_in(b.text, f.needle, f.match_case, f.whole_word, hits)
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

// ---- the rows: the pass

// Row `i` visited: its id and stamp asked; its text read when the stamp moved, counted when the query did. The bytes it cost.
@(private = "file")
find_visit :: proc(f: ^Find_State, i: int) -> (bytes: int) {
	r := f.rows
	id := r.id != nil ? r.id(r.user, i) : u64(i)
	stamp := r.stamp != nil ? r.stamp(r.user, i) : r.version
	e := &f.order[i]
	if f.has_cur && id == f.cur_id { f.cur_row, f.cur_seen = i, true }
	if e.gen == f.gen && e.id == id && e.stamp == stamp { return 0 }
	t, ok := &f.cache[id]
	if !ok {
		f.cache[id] = {}
		t = &f.cache[id]
	}
	if !t.read || t.stamp != stamp {
		delete(t.text)
		text, has := r.text(r.user, i, context.allocator, true)
		t.text = has ? text : ""
		if !has { delete(text) }
		t.stamp, t.read, t.gen = stamp, true, 0
		bytes += len(t.text) + 1
	}
	if t.gen != f.gen {
		t.kept = f.keep == nil || f.keep(r.user, i)
		t.n = t.kept ? find_count_in(f, t.text) : 0
		t.gen = f.gen
		bytes += len(t.text) + 1
	}
	if e.gen != f.gen { f.unknown -= 1 }
	if t.n != e.n { f.counted += 1 }
	fen_add(f, i, t.n - e.n)
	e^ = {id = id, stamp = stamp, n = t.n, gen = f.gen, kept = t.kept}
	return
}

// The order follows the rows' count and version; the built rows are visited, then a slice of the pass.
@(private = "file")
find_pass :: proc(s: ^State, f: ^Find_State) {
	count := max(f.rows.count, 0)
	if len(f.order) != count {
		// (rows came or went: by their identities again, from the cache)
		resize(&f.order, count)
		slice.zero(f.order[:])
		fenwick_reset(&f.tree, count)
		old := len(f.tops)
		resize(&f.tops, count)
		for i in old ..< count { f.tops[i] = -1 }
		f.total = 0
		f.unknown, f.left, f.cursor = count, count, 0
		f.cur_seen = false
		f.counted += 1
		f.placed += 1
	}
	if f.rows.version != f.version {
		f.version = f.rows.version
		if f.left == 0 { f.cur_seen = false }
		f.left = count
	}
	for b in f.built { if b.row >= 0 && b.row < count { find_visit(f, b.row) } }
	visits, bytes := 0, 0
	for f.left > 0 && visits < FIND_ROWS_PER_FRAME && (visits == 0 || bytes < FIND_BYTES_PER_FRAME) {
		if f.cursor >= count { f.cursor = 0 }
		bytes += find_visit(f, f.cursor)
		f.cursor += 1
		f.left -= 1
		visits += 1
	}
	if f.left == 0 && f.unknown == 0 {
		// (a pass ended: a current row it never met is gone)
		if f.has_cur && !f.cur_seen && !(f.cur_row >= 0 && f.cur_row < count && f.order[f.cur_row].id == f.cur_id) { find_drop_current(f) }
		f.cur_seen = true
		find_trim(f)
	}
	if f.left > 0 { f.waiting = true }
}

@(private = "file")
find_drop_current :: proc(f: ^Find_State) {
	f.has_cur = false
	f.cur_row, f.cur_occ, f.current, f.goal, f.want_row = -1, -1, -1, .None, -1
}

// Texts of rows no longer there (another session shown), once the cache holds many more than the rows: rare, so a set of
// the rows' identities is made then.
@(private = "file")
find_trim :: proc(f: ^Find_State) {
	if len(f.cache) <= 2 * len(f.order) + 64 { return }
	live := make(map[u64]bool, len(f.order), context.temp_allocator)
	for e in f.order { live[e.id] = true }
	dead := make([dynamic]u64, context.temp_allocator)
	for id in f.cache { if !live[id] { append(&dead, id) } }
	for id in dead {
		delete(f.cache[id].text)
		delete_key(&f.cache, id)
	}
}

// The k-th match (an ordinal over every row) made current.
@(private = "file")
find_make_current :: proc(f: ^Find_State, ordinal: int) {
	if f.total <= 0 { return }
	k := ((ordinal % f.total) + f.total) % f.total
	row := fen_find(f, k)
	f.cur_row, f.cur_occ, f.cur_id, f.has_cur = row, k - fen_sum(f, row), f.order[row].id, true
	f.goal, f.reveal_builds, f.moved = .Seek, 0, true
	f.cur_range = {}
	if t, ok := f.cache[f.cur_id]; ok {
		hits := make([dynamic][2]int, context.temp_allocator)
		find_in(t.text, f.needle, f.match_case, f.whole_word, &hits)
		if f.cur_occ < len(hits) { f.cur_range = hits[f.cur_occ] }
	}
}

// The view brings the content's band [y0, y1) in, when it is not already well inside.
@(private = "file")
find_bring_in :: proc(view: ^Box, y0, y1: f32) {
	h := view.size.y
	em := view.font_size
	off := view.view_target.y
	if y0 >= off + em * FIND_TOP_MARGIN_EM && y1 <= off + h - em * FIND_BOTTOM_MARGIN_EM { return }
	view.view_target.y = clamp(y0 - h * FIND_LAND_AT, 0, view_limit(view))
}

// After the layout: the rows counted (a slice), the built text lit, the current match brought in.
@(private)
find_collect :: proc(s: ^State) {
	f := &s.find
	defer clear(&f.built)
	clear(&f.matches)
	clear(&f.by_box)
	f.lit = false
	active := f.open && f.bar_build == s.build_index
	needle := active ? line_edit_string(&f.field) : ""
	if needle != f.needle {
		delete(f.needle)
		f.needle = strings.clone(needle)
		find_query_changed(f)
	}
	if !f.open { if len(f.cache) > 0 || len(f.order) > 0 { find_rows_free(f) }; return }
	if f.needle == "" { f.count = 0; return }
	view := s.boxes[f.view] or_else nil
	// (a view not built this build: its subtree points into freed frame memory)
	if view == nil || view.last_build != s.build_index { return }
	f.lit = true
	defer find_ticks_merge(s, view)
	hits := make([dynamic][2]int, context.temp_allocator)
	found := make([dynamic]Find_Hit, context.temp_allocator)
	content_y :: proc(view: ^Box, y: f32) -> f32 { return y - view.rect.min.y + view.view_off.y }

	if f.rows_build != s.build_index {
		// box mode: everything is built, this layout's matches are the answer
		if len(f.order) > 0 { find_rows_free(f) }
		f.count, f.by_rows = 0, false
		clear(&f.box_tops)
		for b := view; b != nil; b = find_next_box(b, view) {
			find_box_hits(s, b, &hits, &found)
			first := len(f.matches)
			for h in found {
				if !h.same {
					f.count += 1
					append(&f.box_tops, content_y(view, h.rect.min.y))
				}
				append(&f.matches, Find_Match{box = b.key, rect = h.rect, index = f.count - 1})
			}
			if len(f.matches) > first { f.by_box[b.key] = {first, len(f.matches)} }
		}
		f.counted += 1
		defer { f.step, f.picked = 0, true }
		if f.count == 0 { f.current, f.goal = -1, .None; return }
		if f.step != 0 || !f.picked {
			if f.current < 0 {
				// (the first at or below the view's top; none: the last above it)
				f.current = f.count - 1
				for m in f.matches { if m.rect.min.y >= view.rect.min.y { f.current = m.index; break } }
				if f.step < 0 { f.current = (f.current - 1 + f.count) % f.count }
			} else {
				f.current = (f.current + f.step + f.count) % f.count
			}
			f.goal, f.moved = .Seek, true
		}
		f.current = min(f.current, f.count - 1)
		if f.goal != .None {
			for m in f.matches {
				if m.index != f.current { continue }
				find_bring_in(view, content_y(view, m.rect.min.y), content_y(view, m.rect.max.y))
				break
			}
			f.goal = .None
		}
		return
	}

	// rows
	f.by_rows = true
	find_pass(s, f)
	if f.unknown > 0 { f.waiting = true }

	// the current match: chosen once the count is known, stepped, kept on its row; before the built rows are read, which
	// find it there. (Its index is found again by its identity when rows came before it: the pass meets it)
	if f.cur_row >= 0 && (f.cur_row >= len(f.order) || f.order[f.cur_row].id != f.cur_id) { f.cur_row = -1 }
	if f.has_cur && f.cur_row >= 0 && f.cur_occ >= int(f.order[f.cur_row].n) && f.order[f.cur_row].gen == f.gen { find_drop_current(f) }
	if f.step != 0 && f.total > 0 {
		if f.has_cur && f.cur_row >= 0 {
			find_make_current(f, fen_sum(f, f.cur_row) + f.cur_occ + f.step)
		} else {
			k := find_first_from_view(f, view)
			find_make_current(f, f.step > 0 ? k : k - 1)
		}
		f.picked = true
	} else if !f.picked && f.unknown == 0 {
		f.picked = true
		if f.total > 0 { find_make_current(f, find_first_from_view(f, view)) }
	}
	f.step = 0
	f.current = f.cur_row >= 0 ? fen_sum(f, f.cur_row) + f.cur_occ : -1

	cur_built := false
	cur_nb := -1
	cur_rects := make([dynamic]Find_Match, context.temp_allocator)
	for br in f.built {
		b := s.boxes[br.key] or_else nil
		if b == nil || b.last_build != s.build_index || br.row < 0 || br.row >= len(f.order) { continue }
		e := f.order[br.row]
		if br.row == f.cur_row { cur_built = true }
		if !e.kept && e.gen == f.gen { continue }
		first := len(f.matches)
		nb := 0
		for d := b; d != nil; d = find_next_box(d, b) {
			if .Selectable not_in d.flags { continue }
			if !find_box_hits(s, d, &hits, &found) || len(found) == 0 { continue }
			at := len(f.matches)
			for h in found {
				if !h.same { nb += 1 }
				append(&f.matches, Find_Match{box = d.key, rect = h.rect, index = nb - 1})
			}
			f.by_box[d.key] = {at, len(f.matches)}
		}
		// (the j-th in the boxes is the j-th in the row's text only when every part is open: then the ordinals)
		exact := e.gen == f.gen && int(e.n) == nb
		base := exact ? fen_sum(f, br.row) : 0
		for &m in f.matches[first:] {
			if br.row == f.cur_row && m.index == f.cur_occ { append(&cur_rects, m) }
			m.index = exact ? base + m.index : -1
		}
		if br.row == f.cur_row { cur_nb = exact ? nb : -1 }
	}

	// its way to the screen
	f.want_row = -1
	if f.goal != .None && f.cur_row >= 0 {
		switch {
		case !cur_built:
			if f.lazy_build == s.build_index {
				f.want_row = f.cur_row
				if f.cur_row < len(f.tops) && f.tops[f.cur_row] >= 0 { find_bring_in(view, f.tops[f.cur_row], f.tops[f.cur_row] + view.font_size) }
				f.waiting = true
			} else {
				f.goal = .None   // (a view that draws its rows: find_bar's result tells it)
			}
		case cur_nb >= 0 && len(cur_rects) > 0:
			y0, y1 := max(f32), min(f32)
			for m in cur_rects { y0, y1 = min(y0, m.rect.min.y), max(y1, m.rect.max.y) }
			find_bring_in(view, content_y(view, y0), content_y(view, y1))
			f.goal = .None
		case f.goal == .Seek && f.rows.reveal != nil:
			f.rows.reveal(f.rows.user, f.cur_row, f.cur_range[0])
			f.goal, f.reveal_builds = .Reveal, 0
			f.want_row = f.cur_row
			f.waiting = true
		case f.goal == .Reveal && f.reveal_builds < FIND_REVEAL_BUILDS:
			f.reveal_builds += 1
			f.want_row = f.cur_row
			f.waiting = true
		case:
			// (it could not be shown: the view goes to its row)
			if f.cur_row < len(f.tops) && f.tops[f.cur_row] >= 0 { find_bring_in(view, f.tops[f.cur_row], f.tops[f.cur_row] + view.font_size) }
			f.goal = .None
		}
	}
}

// The ordinal of the first match at or below the view's first built row in view (0 with none built).
@(private = "file")
find_first_from_view :: proc(f: ^Find_State, view: ^Box) -> int {
	for br in f.built {
		b := box_from_key(br.key)
		if b == nil || b.rect.max.y <= view.rect.min.y { continue }
		k := fen_sum(f, br.row)
		return k >= f.total ? f.total - 1 : k
	}
	return 0
}

// ---- the ticks on the view's scroll bar

@(private = "file") FIND_TICK_THICK_PX :: 2
@(private = "file") FIND_TICK_PITCH_PX :: 4
@(private = "file") FIND_TICK_INSET_PX :: 1

// The ticks merged after the layout, when the counts, the places, the track or the content changed: not at each frame.
@(private = "file")
find_ticks_merge :: proc(s: ^State, view: ^Box) {
	f := &s.find
	parts, ok := scrollbar_parts(view)
	content := view.view_bounds.y
	if !ok || content <= 0 { clear(&f.ticks); f.ticks_made = {}; return }
	h := parts.track.max.y - parts.track.min.y
	gap := math.round(FIND_TICK_PITCH_PX * s.scale)
	want := Find_Ticks_Made{counted = f.counted, placed = f.placed, track = h, content = content, gap = gap}
	if want == f.ticks_made { return }
	f.ticks_made = want
	clear(&f.ticks)
	add :: proc(f: ^Find_State, top, content, h, gap: f32) {
		if top < 0 { return }
		y := clamp(top / content, 0, 1) * h
		if n := len(f.ticks); n > 0 && y - f.ticks[n - 1] < gap { return }
		append(&f.ticks, y)
	}
	if f.by_rows {
		// (the rows with matches, by the tree: each a jump over the rows without)
		for k := 0; k < f.total; {
			r := fen_find(f, k)
			if r < len(f.tops) { add(f, f.tops[r], content, h, gap) }
			k = fen_sum(f, r) + int(f.order[r].n)
		}
	} else {
		for top in f.box_tops { add(f, top, content, h, gap) }
	}
}

// Where the find's ticks are on the vertical bar of `view`, window pixels down the track, by the last layout (none: the
// find is not open over it, or it has no bar). For tests and tools. Temp memory.
find_ticks :: proc(view: ^Box) -> []f32 {
	f := &gs().find
	if view == nil || !f.lit || view.key != f.view { return nil }
	parts, ok := scrollbar_parts(view)
	if !ok { return nil }
	out := make([]f32, len(f.ticks), context.temp_allocator)
	for y, i in f.ticks { out[i] = parts.track.min.y + y }
	return out
}

// The current match's place in the view's content, for its tick (-1: none).
@(private = "file")
find_current_top :: proc(f: ^Find_State) -> f32 {
	if f.by_rows { return f.has_cur && f.cur_row >= 0 && f.cur_row < len(f.tops) ? f.tops[f.cur_row] : -1 }
	return f.current >= 0 && f.current < len(f.box_tops) ? f.box_tops[f.current] : -1
}

// The matches' ticks on the vertical bar of `b`, over the thumb and the program's marks (scrollbar_paint).
@(private)
find_ticks_draw :: proc(s: ^State, dc: ^draw.Context, b: ^Box, track: Rect) {
	f := &s.find
	content := b.view_bounds.y
	if !f.lit || b.key != f.view || f.needle == "" || content <= 0 { return }
	h := track.max.y - track.min.y
	thick := max(1, math.round(FIND_TICK_THICK_PX * s.scale))
	inset := math.round(FIND_TICK_INSET_PX * s.scale)
	c := color_from_tags(s, b.tags_key, "find_match background")
	c.a = 1
	for y in f.ticks {
		yy := math.round(track.min.y + y - thick * 0.5)
		draw.rect(dc, {{track.min.x + inset, yy}, {track.max.x - inset, yy + thick}}, c)
	}
	// the current one, across the track, twice as tall
	if cur := find_current_top(f); cur >= 0 {
		k := color_from_tags(s, b.tags_key, "find_current background")
		k.a = 1
		big := thick * 2
		yy := math.round(track.min.y + clamp(cur / content, 0, 1) * h - big * 0.5)
		draw.rect(dc, {{track.min.x, yy}, {track.max.x, yy + big}}, k)
	}
}

// ---- painting

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
