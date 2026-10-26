package ui

import "base:runtime"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "../draw"
import "../font"

// Rich text: a paragraph of runs, each with its own face, size, colour, background, decorations, or a link. Lines break
// at the font backend's line break opportunities computed on the whole text (UAX #14 across runs: a word that changes
// style in the middle is not broken there), "\n" always breaks, a word wider than the line is cut between grapheme
// clusters. Each run's pieces are shaped with its face. The layout of a paragraph is kept by content (its runs, width,
// line limit): a paragraph of thousands of runs is laid out once, then looked up.
//
//   rich_paragraph(id, runs, max_lines = 0): the box (full width, as tall as its lines; `next` may say otherwise).
//   rich_layout / rich_index_at / rich_caret / rich_range_rects / rich_link_at: the layout and its geometry.
//   rich_set_faces(state, regular, bold, italic, bold_italic): the faces `bold` / `italic` runs of a family take (else the
//   regular face with simulated bold / slant).

Rich_Style :: struct {
	font:       font.Font_Id,   // 0: the box's
	size:       f32,            // 0: the box's
	bold:       bool,           // the bold face of `font`: rich_set_faces, else the family's (font.styled_face), else simulated
	italic:     bool,
	code:       bool,           // inline code: the mono font, the theme's "code_bg" behind
	color:      Color,          // alpha 0: the box's text colour (a link's: the theme's "link")
	background: Color,
	underline:  bool,
	strike:     bool,
	link:       string,         // a link: its target (the result says when it is hovered, clicked or chosen)
}

Rich_Run :: struct {
	text: string,
	using style: Rich_Style,
}

// A piece of a run on one line.
Rich_Frag :: struct {
	run:          int,
	start, end:   int,      // bytes of the run's text
	x, width:     f32,      // from the paragraph's left edge (alignment applied)
	face:         font.Font_Id,
	size:         f32,
}

Rich_Line :: struct {
	first, count: int,      // its fragments
	y, height:    f32,      // from the paragraph's top
	baseline:     f32,      // from the paragraph's top
	start, end:   int,      // bytes of the whole text (rich_text) the line shows (without a final "\n")
	width:        f32,      // without trailing spaces
	ellipsis_x:   f32,      // > 0: "…" drawn there (the text went on past max_lines)
	ellipsis_face: font.Font_Id,
	ellipsis_size: f32,
}

Rich_Layout :: struct {
	lines:     []Rich_Line,
	frags:     []Rich_Frag,
	run_start: []int,       // byte offset of each run in the whole text
	text_len:  int,
	size:      Vec2,
	truncated: bool,
	links:     []int,       // runs that are links, in order
	alloc:     runtime.Allocator,
}

rich_layout_destroy :: proc(l: ^Rich_Layout) {
	delete(l.lines, l.alloc); delete(l.frags, l.alloc); delete(l.run_start, l.alloc); delete(l.links, l.alloc)
	l^ = {}
}

// What a layout needs besides the runs.
Rich_Context :: struct {
	fonts:     ^font.State,
	base_font: font.Font_Id,
	base_size: f32,
	mono:      font.Font_Id,   // inline code (0: the base font)
	faces:     ^map[font.Font_Id][4]font.Font_Id,   // rich_set_faces (may be nil)
}

// The whole text of the runs, concatenated (what selection and copy see).
rich_text :: proc(runs: []Rich_Run, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for r in runs { strings.write_string(&sb, r.text) }
	return strings.to_string(sb)
}

// The face and size a run is drawn with.
rich_face :: proc(c: Rich_Context, r: Rich_Style) -> (font.Font_Id, f32) {
	base := r.font != 0 ? r.font : c.base_font
	if r.code { base = c.mono != 0 ? c.mono : base }
	size := r.size > 0 ? r.size : c.base_size
	if !r.bold && !r.italic { return base, size }
	k := (r.bold ? 1 : 0) + (r.italic ? 2 : 0)
	if c.faces != nil {
		if set, ok := c.faces[base]; ok && set[k] != 0 { return set[k], size }
	}
	return font.styled_face(c.fonts, base, r.bold, r.italic), size
}

// Lays the runs out at `width` (<= 0: no wrapping, only "\n" breaks), at most `max_lines` lines (0: no limit; the last
// one ends with "…" when the text goes on), aligned. Everything is in `allocator`.
rich_layout :: proc(c: Rich_Context, runs: []Rich_Run, width: f32, max_lines := 0, align := Text_Align.Left, allocator := context.allocator) -> Rich_Layout {
	l := Rich_Layout{alloc = allocator}
	run_start := make([]int, len(runs) + 1, allocator)
	faces := make([]font.Font_Id, len(runs), context.temp_allocator)
	sizes := make([]f32, len(runs), context.temp_allocator)
	links := make([dynamic]int, 0, 4, allocator)
	total := 0
	for r, i in runs {
		run_start[i] = total
		total += len(r.text)
		faces[i], sizes[i] = rich_face(c, r.style)
		if r.link != "" { append(&links, i) }
	}
	run_start[len(runs)] = total
	l.run_start, l.text_len, l.links = run_start, total, links[:]
	full := rich_text(runs, context.temp_allocator)
	run_of :: proc(run_start: []int, at: int) -> int {   // the run holding byte `at` (binary search)
		lo, hi := 0, len(run_start) - 2
		for lo < hi {
			mid := (lo + hi + 1) / 2
			if run_start[mid] <= at { lo = mid } else { hi = mid - 1 }
		}
		return lo
	}
	// width of the whole text [a, b): each run's piece shaped with its face ("\n" not drawn)
	measure :: proc(c: Rich_Context, runs: []Rich_Run, run_start: []int, faces: []font.Font_Id, sizes: []f32, a, b: int) -> f32 {
		if b <= a || len(runs) == 0 { return 0 }
		w: f32
		for i := run_of(run_start, a); i < len(runs) && run_start[i] < b; i += 1 {
			s, e := max(a, run_start[i]) - run_start[i], min(b, run_start[i + 1]) - run_start[i]
			if e <= s { continue }
			piece := runs[i].text[s:e]
			if strings.index_byte(piece, '\n') >= 0 { piece, _ = strings.remove_all(piece, "\n", context.temp_allocator) }
			w += font.measure(c.fonts, faces[i], sizes[i], piece)
		}
		return w
	}
	trim :: proc(full: string, a, b: int) -> int {
		e := b
		for e > a && (full[e - 1] == ' ' || full[e - 1] == '\n') { e -= 1 }
		return e
	}
	breaks := font.line_breaks(c.fonts, full, context.temp_allocator)
	lines := make([dynamic]Rich_Line, 0, 4, allocator)
	frags := make([dynamic]Rich_Frag, 0, len(runs) + 4, allocator)
	ls := 0
	bi := 0
	for {
		if max_lines > 0 && len(lines) >= max_lines { l.truncated = ls < total; break }
		for bi < len(breaks) && breaks[bi].at <= ls { bi += 1 }
		// the end of this line: the next mandatory break, or the farthest opportunity that fits
		hard := total
		for k := bi; k < len(breaks); k += 1 { if breaks[k].mandatory { hard = breaks[k].at; break } }
		le := hard
		if width > 0 && measure(c, runs, run_start, faces, sizes, ls, trim(full, ls, hard)) > width {
			cut := -1
			for k := bi; k < len(breaks) && breaks[k].at < hard; k += 1 {
				if measure(c, runs, run_start, faces, sizes, ls, trim(full, ls, breaks[k].at)) > width { break }
				cut = breaks[k].at
			}
			if cut < 0 {   // the first word alone is too wide: between grapheme clusters
				limit := bi < len(breaks) ? min(breaks[bi].at, hard) : hard
				cut = limit
				it := utf8.decode_grapheme_iterator_make(full[ls:limit])
				best := -1
				for {
					cl, gr, more := utf8.decode_grapheme_iterate(&it)
					if !more { break }
					e := ls + gr.byte_index + len(cl)
					if best >= 0 && measure(c, runs, run_start, faces, sizes, ls, e) > width { break }
					best = e
				}
				if best > ls { cut = best }
			}
			le = cut
		}
		// the line [ls, le): its pieces, its height and baseline
		shown := le
		if shown > ls && full[shown - 1] == '\n' { shown -= 1 }
		line := Rich_Line{first = len(frags), start = ls, end = shown}
		x: f32
		asc, desc, gap: f32
		for i := len(runs) > 0 ? run_of(run_start, ls) : 0; i < len(runs) && run_start[i] < max(shown, ls + 1); i += 1 {
			s, e := max(ls, run_start[i]) - run_start[i], min(shown, run_start[i + 1]) - run_start[i]
			m := font.metrics(c.fonts, faces[i], sizes[i])
			if e > s || (shown == ls && i == run_of(run_start, ls)) {
				asc, desc, gap = max(asc, m.ascent), max(desc, m.descent), max(gap, m.line_gap)
			}
			if e <= s { continue }
			w := font.measure(c.fonts, faces[i], sizes[i], runs[i].text[s:e])
			append(&frags, Rich_Frag{run = i, start = s, end = e, x = x, width = w, face = faces[i], size = sizes[i]})
			x += w
		}
		if asc == 0 && desc == 0 {
			m := font.metrics(c.fonts, c.base_font, c.base_size)
			asc, desc, gap = m.ascent, m.descent, m.line_gap
		}
		line.count = len(frags) - line.first
		line.width = measure(c, runs, run_start, faces, sizes, ls, trim(full, ls, shown))
		line.height = math.ceil(asc + desc + gap)
		line.y = len(lines) > 0 ? lines[len(lines) - 1].y + lines[len(lines) - 1].height : 0
		line.baseline = line.y + math.round(gap * 0.5 + asc)
		append(&lines, line)
		if le >= total { break }
		ls = le
	}
	if len(lines) == 0 {
		m := font.metrics(c.fonts, c.base_font, c.base_size)
		append(&lines, Rich_Line{height = math.ceil(m.line_height), baseline = math.round(m.line_gap * 0.5 + m.ascent)})
	}
	// "…" on the last line when the text went on: pieces cut back until it fits
	if l.truncated {
		li := &lines[len(lines) - 1]
		ef, es := c.base_font, c.base_size
		if li.count > 0 { lf := frags[li.first + li.count - 1]; ef, es = lf.face, lf.size }
		ell := "…"
		ew := font.measure(c.fonts, ef, es, ell)
		limit := width > 0 ? width - ew : max(f32)
		for li.count > 0 {
			f := &frags[li.first + li.count - 1]
			if f.x + f.width <= limit { break }
			if f.x >= limit { li.count -= 1; continue }
			// cut this piece between clusters
			t := runs[f.run].text
			e := f.start
			it := utf8.decode_grapheme_iterator_make(t[f.start:f.end])
			for {
				cl, gr, more := utf8.decode_grapheme_iterate(&it)
				if !more { break }
				ne := f.start + gr.byte_index + len(cl)
				if f.x + font.measure(c.fonts, f.face, f.size, t[f.start:ne]) > limit { break }
				e = ne
			}
			if e == f.start { li.count -= 1; continue }
			f.end = e
			f.width = font.measure(c.fonts, f.face, f.size, t[f.start:e])
			break
		}
		resize(&frags, li.first + li.count)
		last := li.count > 0 ? frags[li.first + li.count - 1] : Rich_Frag{}
		li.ellipsis_x = li.count > 0 ? last.x + last.width : 0
		li.end = li.count > 0 ? run_start[last.run] + last.end : li.start
		li.width = li.ellipsis_x + ew
		li.ellipsis_face, li.ellipsis_size = ef, es
		if li.ellipsis_x == 0 { li.ellipsis_x = 0.001 }   // > 0 marks the ellipsis
	}
	// size and alignment
	for &li in lines { l.size.x = max(l.size.x, li.width) }
	l.size.y = lines[len(lines) - 1].y + lines[len(lines) - 1].height
	if width > 0 && align != .Left {
		for &li in lines {
			d := (width - li.width) * (align == .Center ? 0.5 : 1)
			d = math.round(max(0, d))
			for k in li.first ..< li.first + li.count { frags[k].x += d }
			if li.ellipsis_x > 0 { li.ellipsis_x += d }
		}
	}
	l.lines, l.frags = lines[:], frags[:]
	return l
}

// The line under y (clamped).
rich_line_at :: proc(l: ^Rich_Layout, y: f32) -> int {
	for li, i in l.lines { if y < li.y + li.height { return i } }
	return len(l.lines) - 1
}

// The byte index of the whole text nearest to point `p` (paragraph coordinates): a grapheme boundary.
rich_index_at :: proc(l: ^Rich_Layout, fonts: ^font.State, runs: []Rich_Run, p: Vec2) -> int {
	if len(l.lines) == 0 { return 0 }
	li := l.lines[rich_line_at(l, p.y)]
	if li.count == 0 { return li.start }
	first := l.frags[li.first]
	if p.x <= first.x { return l.run_start[first.run] + first.start }
	for k in li.first ..< li.first + li.count {
		f := l.frags[k]
		if p.x < f.x + f.width || k == li.first + li.count - 1 {
			t := runs[f.run].text[f.start:f.end]
			return l.run_start[f.run] + f.start + font.index_from_x(fonts, f.face, f.size, t, p.x - f.x)
		}
	}
	return li.end
}

// The caret before byte `index` of the whole text: its line and x (at a line's end, that line; `upstream` at a
// boundary between two lines: the first one).
rich_caret :: proc(l: ^Rich_Layout, fonts: ^font.State, runs: []Rich_Run, index: int, upstream := false) -> (line: int, x: f32) {
	for li, i in l.lines {
		next_start := i + 1 < len(l.lines) ? l.lines[i + 1].start : max(int)
		if index >= next_start && !(upstream && index == li.end) { continue }
		if li.count == 0 { return i, 0 }
		for k in li.first ..< li.first + li.count {
			f := l.frags[k]
			a := l.run_start[f.run] + f.start
			b := l.run_start[f.run] + f.end
			if index <= b || k == li.first + li.count - 1 {
				t := runs[f.run].text[f.start:f.end]
				return i, f.x + font.x_from_index(fonts, f.face, f.size, t, clamp(index - a, 0, len(t)))
			}
		}
	}
	last := len(l.lines) - 1
	return last, l.lines[last].width
}

// The rectangles (paragraph coordinates) the bytes [lo, hi) of the whole text cover, line by line, piece by piece.
rich_range_rects :: proc(l: ^Rich_Layout, fonts: ^font.State, runs: []Rich_Run, lo, hi: int, allocator := context.temp_allocator) -> []Rect {
	out := make([dynamic]Rect, 0, 4, allocator)
	if hi <= lo { return out[:] }
	for li in l.lines {
		if li.end < lo || li.start >= hi { continue }
		for k in li.first ..< li.first + li.count {
			f := l.frags[k]
			a := l.run_start[f.run] + f.start
			b := l.run_start[f.run] + f.end
			s, e := max(lo, a), min(hi, b)
			if e <= s { continue }
			t := runs[f.run].text[f.start:f.end]
			for sp in font.x_spans_of_range(fonts, f.face, f.size, t, s - a, e - a) {
				append(&out, Rect{{f.x + sp[0], li.y}, {f.x + sp[1], li.y + li.height}})
			}
		}
	}
	return out[:]
}

// The link run under point `p` (paragraph coordinates), -1 for none.
rich_link_at :: proc(l: ^Rich_Layout, runs: []Rich_Run, p: Vec2) -> int {
	if len(l.links) == 0 { return -1 }
	for li in l.lines {
		if p.y < li.y || p.y >= li.y + li.height { continue }
		for k in li.first ..< li.first + li.count {
			f := l.frags[k]
			if runs[f.run].link != "" && p.x >= f.x && p.x < f.x + f.width { return f.run }
		}
	}
	return -1
}

// The faces of a family that bold / italic runs take: `regular` is the family's (the font a run names, or the box's).
rich_set_faces :: proc(s: ^State, regular, bold, italic, bold_italic: font.Font_Id) {
	s.rich_faces[regular] = {regular, bold, italic, bold_italic}
}

////////////////////////////////
// Layouts kept by content

RICH_CACHE_KEEP :: 120

@(private)
Rich_Cache_Entry :: struct {
	layout:     ^Rich_Layout,   // heap: stays where it is while the map grows
	last_build: u64,
}

@(private)
rich_hash :: proc(runs: []Rich_Run, c: Rich_Context, width: f32, max_lines: int, align: Text_Align) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: #force_inline proc(h: ^u64, bytes: []u8) { for b in bytes { h^ = (h^ ~ u64(b)) * 0x100000001b3 } }
	for r in runs {
		mix(&h, transmute([]u8)r.text)
		st := r.style
		st.link = ""
		mix(&h, ([^]u8)(&st)[:size_of(Rich_Style)])
		mix(&h, transmute([]u8)r.link)
		h = (h ~ 0xff) * 0x100000001b3   // run boundary
	}
	tail := struct { w: f32, n: int, a: Text_Align, f: font.Font_Id, s: f32, m: font.Font_Id }{width, max_lines, align, c.base_font, c.base_size, c.mono}
	mix(&h, ([^]u8)(&tail)[:size_of(tail)])
	return h
}

// The layout of `runs` from the cache (laid out and kept the first time). Valid until the cache drops it: unused for
// RICH_CACHE_KEEP builds.
rich_layout_cached :: proc(runs: []Rich_Run, c: Rich_Context, width: f32, max_lines := 0, align := Text_Align.Left) -> ^Rich_Layout {
	s := g
	k := rich_hash(runs, c, width, max_lines, align)
	if e, ok := &s.rich_cache[k]; ok {
		e.last_build = s.build_index
		return e.layout
	}
	l := new(Rich_Layout, runtime.heap_allocator())
	l^ = rich_layout(c, runs, width, max_lines, align, runtime.heap_allocator())
	s.rich_cache[k] = {layout = l, last_build = s.build_index}
	return l
}

@(private)
rich_cache_trim :: proc(s: ^State) {
	if s.build_index % 30 != 0 { return }
	dead := make([dynamic]u64, context.temp_allocator)
	for k, e in s.rich_cache { if e.last_build + RICH_CACHE_KEEP < s.build_index { append(&dead, k) } }
	for k in dead {
		e := s.rich_cache[k]
		rich_layout_destroy(e.layout)
		free(e.layout, runtime.heap_allocator())
		delete_key(&s.rich_cache, k)
	}
}

@(private)
rich_cache_destroy :: proc(s: ^State) {
	for _, e in s.rich_cache { rich_layout_destroy(e.layout); free(e.layout, runtime.heap_allocator()) }
	delete(s.rich_cache)
	delete(s.rich_faces)
	delete(s.rich_link)
}

// Layouts kept (tests, statistics).
rich_cache_len :: proc(s: ^State) -> int { return len(s.rich_cache) }

////////////////////////////////
// Widget

Rich_Result :: struct {
	using signal: Signal,
	link_hovered: int,      // the run of the link under the pointer, -1
	link_clicked: int,      // the run of the link clicked or chosen with Enter this build, -1
	link:         string,   // its target
	link_focused: int,      // the link the keyboard is on (Tab moves through the links), -1
}

@(private)
Rich_Draw :: struct {
	runs:     []Rich_Run,
	colors:   []Color,      // per run: the colour drawn
	ctx:      Rich_Context,
	max_lines: int,
	hovered, focused: int,
	link_color, code_bg: Color,
}

@(private)
rich_ctx :: proc(b: ^Box) -> Rich_Context {
	return {fonts = g.fonts, base_font = b.font, base_size = b.font_size, mono = g.mono_font, faces = &g.rich_faces}
}

@(private)
rich_measure_y :: proc(b: ^Box) -> f32 {
	d := (^Rich_Draw)(b.custom_user)
	l := rich_layout_cached(d.runs, d.ctx, b.size.x - 2 * b.text_pad, d.max_lines, b.text_align)
	return l.size.y
}

@(private)
rich_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Rich_Draw)(user)
	s := g
	l := rich_layout_cached(d.runs, d.ctx, b.size.x - 2 * b.text_pad, d.max_lines, b.text_align)
	o := Vec2{b.rect.min.x + b.text_pad, b.rect.min.y + b.text_pad}
	clip := draw.current_clip(dc)
	for li in l.lines {
		if o.y + li.y > clip.max.y { break }
		if o.y + li.y + li.height < clip.min.y { continue }
		for k in li.first ..< li.first + li.count {
			f := l.frags[k]
			r := d.runs[f.run]
			x0, x1 := o.x + f.x, o.x + f.x + f.width
			bg := r.background
			if r.code && bg.a == 0 { bg = d.code_bg }
			if bg.a > 0 { draw.rect(dc, {{x0, o.y + li.y}, {x1, o.y + li.y + li.height}}, bg, r.code ? 3 * s.scale : 0) }
			col := d.colors[f.run]
			if col.a == 0 { col = b.text_color }
			base := Vec2{math.round(x0), o.y + li.baseline}
			draw.text(dc, f.face, f.size, base, col, r.text[f.start:f.end])
			m := font.metrics(s.fonts, f.face, f.size)
			th := max(1, math.round(m.underline_thickness))
			if r.underline || r.link != "" {
				uy := math.round(base.y + m.underline_offset)
				draw.rect(dc, {{x0, uy}, {x1, uy + th}}, col)
			}
			if r.strike {
				sy := math.round(base.y - m.strike_offset)
				draw.rect(dc, {{x0, sy}, {x1, sy + max(1, math.round(m.strike_thickness))}}, col)
			}
			if f.run == d.focused {
				draw.rect(dc, {{x0 - 2, o.y + li.y}, {x1 + 2, o.y + li.y + li.height}}, color_from_tags(s, b.tags_key, "focus border"), 3 * s.scale, max(1, math.round(1.5 * s.scale)))
			}
		}
		if li.ellipsis_x > 0 {
			draw.text(dc, li.ellipsis_face, li.ellipsis_size, {math.round(o.x + li.ellipsis_x), o.y + li.baseline}, b.text_color, "…")
		}
	}
}

// A paragraph of rich text runs: full width (unless `next` says otherwise), as tall as its lines, at most `max_lines`
// (0: all; then "…"). Links answer hover and click (the pointer is a hand on them) and the keyboard: the paragraph is a
// Tab stop when it has links, Tab / Shift+Tab move through them before leaving it, Enter chooses one.
// `runs` (and their strings) need only live through the build: the box keeps a copy for drawing.
rich_paragraph :: proc(id: string, runs: []Rich_Run, max_lines := 0) -> (res: Rich_Result) {
	s := g
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = text_size() }
	s.next_mod = m
	s.has_next = true
	has_links := false
	for r in runs { if r.link != "" { has_links = true; break } }
	flags := Box_Flags{.No_Text_Trunc}
	if has_links { flags += {.Clickable, .Focusable} }
	b := build_box(flags, id)
	b.text = ""
	res.link_hovered, res.link_clicked, res.link_focused = -1, -1, -1

	// a copy of the runs for drawing (frame memory: thousands of runs cost one allocation each for runs and strings)
	d := frame_new(Rich_Draw)
	d.runs = make([]Rich_Run, len(runs), frame_allocator())
	sb := strings.builder_make(frame_allocator())
	strings.write_string(&sb, rich_text(runs, context.temp_allocator))
	all := strings.to_string(sb)
	off := 0
	for r, i in runs {
		d.runs[i] = r
		d.runs[i].text = all[off:off + len(r.text)]
		off += len(r.text)
		if r.link != "" { d.runs[i].link = strings.clone(r.link, frame_allocator()) }
	}
	d.ctx = rich_ctx(b)
	d.max_lines = max_lines
	d.link_color = color("link")
	d.code_bg = color("code_bg")
	d.colors = make([]Color, len(runs), frame_allocator())
	for r, i in runs {
		c := r.color
		if c.a == 0 && r.link != "" { c = d.link_color }
		d.colors[i] = c   // alpha 0: the box's text colour, when drawn
	}
	d.hovered, d.focused = -1, -1
	b.custom, b.custom_user, b.measure_y = rich_draw, d, rich_measure_y
	// width when sized to its text: the longest line without wrapping
	if b.pref[.X].kind == .Text {
		b.text_dim.x = rich_layout_cached(d.runs, d.ctx, 0, max_lines, .Left).size.x
	}

	res.signal = signal(b)
	if !has_links { return }
	// links: under the pointer (last frame's layout at the box's width), clicked, chosen with the keyboard
	l := rich_layout_cached(d.runs, d.ctx, b.size.x - 2 * b.text_pad, max_lines, b.text_align)
	if res.hovering {
		res.link_hovered = rich_link_at(l, d.runs, res.mouse - {b.text_pad, b.text_pad})
		if res.link_hovered >= 0 { s.cursor_request = .Hand }
	}
	cur, known := s.rich_link[b.key]
	if res.clicked {
		if k := rich_link_at(l, d.runs, res.mouse - {b.text_pad, b.text_pad}); k >= 0 {
			res.link_clicked = k
		} else if res.focused && known && !res.hovering {
			res.link_clicked = cur   // Enter / Space on the focused paragraph (the toolkit's keyboard click)
		}
	}
	if res.focused {
		pos := -1
		for r, i in l.links { if r == cur { pos = i } }
		if !known || pos < 0 {
			pos = s.tab_dir < 0 ? len(l.links) - 1 : 0
		} else if pos + 1 < len(l.links) && key_pressed_peek(.Tab) {
			key_press(.Tab); pos += 1
		} else if pos > 0 && key_pressed_peek(.Tab, {.Shift}) {
			key_press(.Tab, {.Shift}); pos -= 1
		}
		if len(l.links) > 0 {
			res.link_focused = l.links[pos]
			s.rich_link[b.key] = res.link_focused
			if key_press(.Return) || key_press(.Space) { res.link_clicked = res.link_focused }
		}
	} else if known {
		delete_key(&s.rich_link, b.key)
	}
	if res.link_clicked >= 0 { res.link = runs[res.link_clicked].link }
	d.hovered = res.link_hovered
	d.focused = s.focus_visible ? res.link_focused : -1
	return
}
