package font

import "base:runtime"
import "core:slice"
import "core:sync"
import "core:unicode"

// Shaping: UTF-8 text to positioned glyphs.
//
// A line is first split into directional runs (UAX #9, DirectWrite's bidi analysis, unless the caller says the text is
// one run), then each run into words at U+0020; each word is shaped on its own (as Blink's word cache does) and cached:
// a page measures the same words over and over, on several threads. A word is split by script (DirectWrite's script
// analysis) and by face: each character comes from the first entry of the cascade that has it (combining marks,
// variation selectors, joiners and emoji modifiers stay with their base), then from the system fallback
// (IDWriteFontFallback::MapCharacters), then from the first face (its .notdef). Each piece goes through GetGlyphs /
// GetGlyphPlacements with the cascade's OpenType features.
//
// Limits: no kerning or ligature across a space (words are shaped apart), no vertical text.

Glyph_Pos :: struct {
	face:    Font_Id,   // the face the glyph is from (after fallback)
	id:      u16,       // glyph index in that face
	rtl:     bool,      // part of a right-to-left run
	x, y:    f32,       // origin of the glyph from the origin of the text (pen on the baseline), y down
	advance: f32,       // its share of the line (letter / word spacing included)
	cluster: i32,       // byte index of the first character of its cluster in the text
}

// A cluster: the characters [start, end) shaped together (one or more glyphs, a ligature or a single character),
// the unit of caret positions and selection. Its extent includes its letter / word spacing.
Cluster :: struct {
	start, end: i32,    // bytes, logical order
	x0, x1:     f32,    // visual extent from the origin of the text
	rtl:        bool,
}

// Text shaped for one line. Glyphs are in visual order (left to right), clusters in logical order.
Shaped :: struct {
	glyphs:   []Glyph_Pos,
	clusters: []Cluster,
	width:    f32,
}

Direction :: enum u8 { Auto, Ltr, Rtl }

Shape_Options :: struct {
	direction:      Direction,  // paragraph direction for UAX #9 (Auto: the first strong character, else left to right)
	one_run:        bool,       // the text is a single directional run already (bidi resolved by the caller): it is
	                            // not reordered; `direction` is its direction (Auto: from its first strong character)
	letter_spacing: f32,        // added after each character (CSS letter-spacing; disables optional ligatures)
	word_spacing:   f32,        // added after each space (U+0020, U+00A0): CSS word-spacing
	justify:        f32,        // added after each U+0020: the share of a justified line's free space
}

shaped_destroy :: proc(sh: ^Shaped, allocator := context.allocator) {
	delete(sh.glyphs, allocator)
	delete(sh.clusters, allocator)
	sh^ = {}
}

// Shapes one line of text.
shape :: proc(s: ^State, id: Font_Id, size: f32, text: string, opts: Shape_Options = {}, allocator := context.allocator) -> Shaped {
	if len(text) == 0 || size <= 0 { return {} }
	glyphs := make([dynamic]Glyph_Pos, 0, len(text), allocator)
	clusters := make([dynamic]Cluster, 0, len(text), allocator)
	pen: f32
	if opts.one_run || (opts.direction != .Rtl && !maybe_rtl(text)) {
		rtl := opts.direction == .Rtl || (opts.direction == .Auto && opts.one_run && first_strong_rtl(text))
		pen = shape_run(s, id, size, text, 0, len(text), rtl, opts, &glyphs, &clusters, pen)
		// a right-to-left run places its words from the last one: clusters back to logical order
		if rtl { sort_clusters(clusters[:]) }
	} else {
		runs := bidi_runs(s, text, opts.direction, context.temp_allocator)
		order := visual_order(runs, context.temp_allocator)
		for k in order {
			r := runs[k]
			pen = shape_run(s, id, size, text, r.start, r.end, r.level & 1 == 1, opts, &glyphs, &clusters, pen)
		}
		// clusters back to logical order (runs were visited in visual order)
		sort_clusters(clusters[:])
	}
	return Shaped{glyphs = glyphs[:], clusters = clusters[:], width = pen}
}

// Advance width of one line of text (as `shape(...).width`, without making the glyph list): what layout measures.
measure :: proc(s: ^State, id: Font_Id, size: f32, text: string, opts: Shape_Options = {}) -> f32 {
	if len(text) == 0 || size <= 0 { return 0 }
	no_liga := opts.letter_spacing != 0
	if !no_liga && opts.word_spacing == 0 && opts.justify == 0 {
		// one word (what layout asks for): one pass over the bytes
		hi: u8
		single := true
		for i in 0 ..< len(text) {
			b := text[i]
			if b == ' ' && len(text) > 1 { single = false; break }
			hi = max(hi, b)
		}
		if single {
			rtl := opts.one_run && opts.direction != .Auto ? opts.direction == .Rtl : (hi >= 0xD6 && first_strong_rtl(text))
			return word_width(s, id, size, text, rtl, false)
		}
	}
	w: f32
	i := 0
	for i < len(text) {
		j := i
		if text[i] == ' ' { j = i + 1 } else { for j < len(text) && text[j] != ' ' { j += 1 } }
		piece := text[i:j]
		rtl := opts.one_run && opts.direction != .Auto ? opts.direction == .Rtl : piece_rtl(piece)
		w += word_width(s, id, size, piece, rtl, no_liga)
		i = j
	}
	if opts.letter_spacing != 0 || opts.word_spacing != 0 || opts.justify != 0 {
		for k := 0; k < len(text); k += 1 {
			b := text[k]
			if b & 0xC0 != 0x80 { w += opts.letter_spacing }
			if b == ' ' { w += opts.word_spacing + opts.justify }
			if b == 0xC2 && k + 1 < len(text) && text[k + 1] == 0xA0 { w += opts.word_spacing }
		}
	}
	return w
}

// Width of a single line of text in pixels.
text_width :: proc(s: ^State, id: Font_Id, size: f32, text: string) -> f32 {
	return measure(s, id, size, text)
}

// Byte index of the caret position closest to `x` (pixels from the start of `text`).
index_from_x :: proc(s: ^State, id: Font_Id, size: f32, text: string, x: f32) -> int {
	sh := shape(s, id, size, text, {}, context.temp_allocator)
	return hit_index(sh, text, x)
}

// Pixels from the start of `text` to the caret before byte `index`.
x_from_index :: proc(s: ^State, id: Font_Id, size: f32, text: string, index: int) -> f32 {
	sh := shape(s, id, size, text, {}, context.temp_allocator)
	return caret_x(sh, text, index)
}

// Caret x before byte `index` of the shaped `text` (`len(text)`: after the last character, logical end). Inside a
// cluster of several characters (a ligature) the cluster is shared out evenly between its graphemes (a ZWJ emoji
// sequence is one grapheme: its caret positions are its two edges).
caret_x :: proc(sh: Shaped, text: string, index: int) -> f32 {
	if len(sh.clusters) == 0 { return 0 }
	i := i32(clamp(index, 0, len(text)))
	if i >= i32(len(text)) {
		// logical end: after the last cluster in logical order
		c := sh.clusters[len(sh.clusters) - 1]
		return c.rtl ? c.x0 : c.x1
	}
	for c in sh.clusters {
		if i < c.start || i >= c.end { continue }
		if i == c.start { return c.rtl ? c.x1 : c.x0 }
		n, k := 0, 0
		piece := text[c.start:min(int(c.end), len(text))]
		marks := grapheme_marks(piece)
		for j in 0 ..< len(piece) {
			if !marks[j] { continue }
			if int(c.start) + j < int(i) { k += 1 }
			n += 1
		}
		t := n > 0 ? f32(k) / f32(n) : 0
		return c.rtl ? c.x1 - (c.x1 - c.x0) * t : c.x0 + (c.x1 - c.x0) * t
	}
	return 0
}

// Byte index of the caret position nearest to `x`: a grapheme boundary, which is a cluster boundary or the boundary
// between the graphemes of a ligature ("fi"); never inside an emoji sequence, a flag or a letter with its marks.
hit_index :: proc(sh: Shaped, text: string, x: f32) -> int {
	if len(sh.clusters) == 0 { return 0 }
	best, best_d := 0, max(f32)
	marks := grapheme_marks(text)
	try :: proc(best: ^int, best_d: ^f32, marks: []bool, idx: int, cx, x: f32) {
		if idx < 0 || idx >= len(marks) || !marks[idx] { return }
		if d := abs(cx - x); d < best_d^ { best^, best_d^ = idx, d }
	}
	for c in sh.clusters {
		if x >= c.x0 && x < c.x1 {
			// inside: the nearer side, or a grapheme boundary in a multi-grapheme cluster
			for j := int(c.start); j <= int(c.end); j += 1 {
				try(&best, &best_d, marks, j, caret_x(sh, text, j) if j < len(text) else (c.rtl ? c.x0 : c.x1), x)
			}
			if best_d < max(f32) { return best }
			// no boundary in the cluster (it starts and ends inside a grapheme): the nearer boundary outside
			break
		}
	}
	for c in sh.clusters {
		try(&best, &best_d, marks, int(c.start), c.rtl ? c.x1 : c.x0, x)
		try(&best, &best_d, marks, int(c.end), c.rtl ? c.x0 : c.x1, x)
	}
	return best
}

////////////////////////////////
// Runs and words

// One directional run [start, end) of `text`: words shaped (cached) and laid out from `pen`, right to left when `rtl`.
@(private)
shape_run :: proc(s: ^State, id: Font_Id, size: f32, text: string, start, end: int, rtl: bool, opts: Shape_Options,
	glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> f32 {
	no_liga := opts.letter_spacing != 0
	// words in logical order
	Piece :: struct { a, b: int }
	pieces := make([dynamic]Piece, 0, 16, context.temp_allocator)
	i := start
	for i < end {
		j := i
		if text[i] == ' ' { j = i + 1 } else { for j < end && text[j] != ' ' { j += 1 } }
		append(&pieces, Piece{i, j})
		i = j
	}
	x := pen
	for k in 0 ..< len(pieces) {
		p := pieces[rtl ? len(pieces) - 1 - k : k]
		x = place_word(s, id, size, text, p.a, p.b, rtl, no_liga, opts, glyphs, clusters, x)
	}
	return x
}

// Copies the shaped word text[a:b] at `x`, adding letter / word spacing per cluster. Returns the pen after it.
@(private)
place_word :: proc(s: ^State, id: Font_Id, size: f32, text: string, a, b: int, rtl, no_liga: bool, opts: Shape_Options,
	glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, x: f32) -> f32 {
	piece := text[a:b]
	g0, c0 := len(glyphs), len(clusters)
	w := word_copy(s, id, size, piece, rtl, no_liga, glyphs, clusters)
	ng, nc := len(glyphs) - g0, len(clusters) - c0
	spacing := opts.letter_spacing != 0 || opts.word_spacing != 0 || opts.justify != 0
	if !spacing {
		for gi in g0 ..< g0 + ng { glyphs[gi].x += x; glyphs[gi].cluster += i32(a) }
		for ci in c0 ..< c0 + nc { clusters[ci].x0 += x; clusters[ci].x1 += x; clusters[ci].start += i32(a); clusters[ci].end += i32(a) }
		return x + w
	}
	// spacing of each cluster (logical order), and the offset of each cluster: what is visually left of it
	sp := make([]f32, nc, context.temp_allocator)
	total: f32
	for ci in 0 ..< nc {
		c := clusters[c0 + ci]
		for j in c.start ..< c.end {
			ch := piece[j]
			if ch & 0xC0 != 0x80 { sp[ci] += opts.letter_spacing }
			if ch == ' ' { sp[ci] += opts.word_spacing + opts.justify }
			if ch == 0xC2 && int(j) + 1 < len(piece) && piece[j + 1] == 0xA0 { sp[ci] += opts.word_spacing }
		}
		total += sp[ci]
	}
	off := make([]f32, nc, context.temp_allocator)
	acc: f32
	if rtl {
		for ci := nc - 1; ci >= 0; ci -= 1 { acc += sp[ci]; off[ci] = acc }   // spacing goes to the left of each cluster
	} else {
		for ci in 0 ..< nc { off[ci] = acc; acc += sp[ci] }
	}
	for gi in g0 ..< g0 + ng {
		g := &glyphs[gi]
		ci := cluster_of(clusters[c0:c0 + nc], g.cluster)
		g.x += x + (ci >= 0 ? off[ci] : 0)
		g.cluster += i32(a)
	}
	// each cluster's spacing goes to its last glyph in logical order (visually: right in LTR, left in RTL)
	for ci in 0 ..< nc {
		c := &clusters[c0 + ci]
		if rtl {
			c.x0 += x + off[ci] - sp[ci]
			c.x1 += x + off[ci]
		} else {
			c.x0 += x + off[ci]
			c.x1 += x + off[ci] + sp[ci]
		}
		if sp[ci] != 0 {
			// the advance of the cluster's visually last glyph carries the spacing
			for gi := g0 + ng - 1; gi >= g0; gi -= 1 {
				gc := glyphs[gi].cluster - i32(a)
				if gc == c.start { glyphs[gi].advance += sp[ci]; break }
			}
		}
		c.start += i32(a); c.end += i32(a)
	}
	return x + w + total
}

@(private)
cluster_of :: proc(cs: []Cluster, start: i32) -> int {
	for c, i in cs { if c.start == start { return i } }
	return -1
}

@(private)
sort_clusters :: proc(cs: []Cluster) {
	// starts are distinct: no stability needed (a right-to-left line comes in reversed blocks, not nearly sorted)
	slice.sort_by(cs, proc(a, b: Cluster) -> bool { return a.start < b.start })
}

////////////////////////////////
// Word cache

@(private) SHARDS :: 64

@(private)
Word :: struct {
	next:     ^Word,
	hash:     u64,
	font:     Font_Id,
	size:     f32,
	rtl:      bool,
	no_liga:  bool,
	text:     string,
	width:    f32,
	glyphs:   []Glyph_Pos,   // x from the word's origin, cluster from the word's start
	clusters: []Cluster,
}

@(private)
Word_Shard :: struct {
	mu:       sync.Mutex,
	cur, old: map[u64]^Word,
	cur_n:    int,
	_:        [32]u8,        // keeps shards on separate cache lines
}

@(private)
Word_Cache :: struct {
	shards: [SHARDS]Word_Shard,
	cap:    int,             // words per shard generation (0: no cache)
	epoch:  u32,             // bumps when the cache is cleared (the threads' own caches then miss)
}

@(private)
words_init :: proc(c: ^Word_Cache, total: int) {
	c.cap = total > 0 ? max(total / SHARDS, 16) : 0
	c.epoch = sync.atomic_add(&words_epochs, 1) + 1
}

@(private)
words_resize :: proc(c: ^Word_Cache, total: int) {
	words_clear(c)
	c.cap = total > 0 ? max(total / SHARDS, 16) : 0
}

@(private)
free_words :: proc(m: ^map[u64]^Word) {
	context.allocator = runtime.heap_allocator()
	for _, w in m {
		n := w
		for n != nil { nx := n.next; free(n); n = nx }
	}
	clear(m)
}

// Epochs are unique in the process (a state made where a destroyed one was gets new ones).
@(private) words_epochs: u32

@(private)
words_clear :: proc(c: ^Word_Cache) {
	sync.atomic_store(&c.epoch, sync.atomic_add(&words_epochs, 1) + 1)
	for &sh in c.shards {
		sync.mutex_lock(&sh.mu)
		free_words(&sh.cur); free_words(&sh.old)
		sh.cur_n = 0
		sync.mutex_unlock(&sh.mu)
	}
}

@(private)
words_destroy :: proc(c: ^Word_Cache) {
	context.allocator = runtime.heap_allocator()
	for &sh in c.shards {
		free_words(&sh.cur); free_words(&sh.old)
		delete(sh.cur); delete(sh.old)
	}
}

// Drops every shaped word (memory pressure, settings changes).
clear_word_cache :: proc(s: ^State) { words_clear(&s.words) }

@(private)
word_hash :: proc(id: Font_Id, size: f32, rtl, no_liga: bool, text: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(text) { h = (h ~ u64(text[i])) * 0x100000001b3 }
	h ~= u64(id) * 0x9E3779B97F4A7C15
	h ~= u64(transmute(u32)size) << 17
	h ~= (u64(rtl) | u64(no_liga) << 1) << 61
	h ~= h >> 31
	return h
}

@(private)
word_find :: proc(sh: ^Word_Shard, h: u64, id: Font_Id, size: f32, rtl, no_liga: bool, text: string) -> ^Word {
	match :: proc(w: ^Word, h: u64, id: Font_Id, size: f32, rtl, no_liga: bool, text: string) -> ^Word {
		for n := w; n != nil; n = n.next {
			if n.hash == h && n.font == id && n.size == size && n.rtl == rtl && n.no_liga == no_liga && n.text == text { return n }
		}
		return nil
	}
	if w, ok := sh.cur[h]; ok { if m := match(w, h, id, size, rtl, no_liga, text); m != nil { return m } }
	if w, ok := sh.old[h]; ok {
		if m := match(w, h, id, size, rtl, no_liga, text); m != nil {
			// still in use: back to the current generation
			unlink(&sh.old, h, m)
			link(sh, h, m)
			return m
		}
	}
	return nil
}

@(private)
unlink :: proc(m: ^map[u64]^Word, h: u64, w: ^Word) {
	head := m[h]
	if head == w {
		if w.next == nil { delete_key(m, h) } else { m[h] = w.next }
	} else {
		for n := head; n != nil; n = n.next {
			if n.next == w { n.next = w.next; break }
		}
	}
	w.next = nil
}

@(private)
link :: proc(sh: ^Word_Shard, h: u64, w: ^Word) {
	if head, ok := sh.cur[h]; ok { w.next = head } else { w.next = nil }
	sh.cur[h] = w
	sh.cur_n += 1
}

@(private)
word_insert :: proc(c: ^Word_Cache, sh: ^Word_Shard, h: u64, w: ^Word) {
	if sh.cur_n >= c.cap {
		free_words(&sh.old)
		sh.old, sh.cur = sh.cur, sh.old
		sh.cur_n = 0
	}
	link(sh, h, w)
}

// Widths of short words a thread measured last: layout threads hit the same few hundred words all the time, and this
// answers them without touching the shared cache (no lock, no shared cache line). Entries hold their own copy of the
// text; the shared cache's epoch tells them apart from what was measured before a clear.
@(private) L1_SIZE :: 1024
@(private) L1_TEXT :: 30

@(private)
L1_Entry :: struct {
	state:   ^State,
	hash:    u64,
	font:    Font_Id,
	size:    f32,
	width:   f32,
	epoch:   u32,
	flags:   u8,
	n:       u8,
	text:    [L1_TEXT]u8,
}

@(private, thread_local)
l1_words: [L1_SIZE]L1_Entry

// Width of one word (text without U+0020, or a single space).
@(private)
word_width :: proc(s: ^State, id: Font_Id, size: f32, text: string, rtl, no_liga: bool) -> f32 {
	context.allocator = runtime.heap_allocator()
	if s.words.cap == 0 {
		w := shape_word(s, id, size, text, rtl, no_liga, context.temp_allocator)
		return w.width
	}
	h := word_hash(id, size, rtl, no_liga, text)
	flags := u8(rtl) | u8(no_liga) << 1
	epoch := sync.atomic_load_explicit(&s.words.epoch, .Relaxed)
	e: ^L1_Entry
	if len(text) <= L1_TEXT {
		e = &l1_words[h & (L1_SIZE - 1)]
		if e.hash == h && e.state == s && e.epoch == epoch && e.font == id && e.size == size && e.flags == flags &&
		   int(e.n) == len(text) && string(e.text[:e.n]) == text {
			return e.width
		}
	}
	sh := &s.words.shards[h % SHARDS]
	width: f32
	sync.mutex_lock(&sh.mu)
	if w := word_find(sh, h, id, size, rtl, no_liga, text); w != nil {
		width = w.width
		sync.mutex_unlock(&sh.mu)
	} else {
		sync.mutex_unlock(&sh.mu)
		nw := shape_word(s, id, size, text, rtl, no_liga, context.allocator)
		width = nw.width
		sync.mutex_lock(&sh.mu)
		if word_find(sh, h, id, size, rtl, no_liga, text) == nil { word_insert(&s.words, sh, h, nw) } else { free(nw) }
		sync.mutex_unlock(&sh.mu)
	}
	if e != nil {
		e^ = L1_Entry{state = s, hash = h, font = id, size = size, width = width, epoch = epoch, flags = flags, n = u8(len(text))}
		copy(e.text[:], text)
	}
	return width
}

// Appends the shaped word (glyph x from the word origin, clusters from the word start). Returns its width.
@(private)
word_copy :: proc(s: ^State, id: Font_Id, size: f32, text: string, rtl, no_liga: bool, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster) -> f32 {
	context.allocator = runtime.heap_allocator()
	if s.words.cap == 0 {
		w := shape_word(s, id, size, text, rtl, no_liga, context.temp_allocator)
		append(glyphs, ..w.glyphs)
		append(clusters, ..w.clusters)
		return w.width
	}
	h := word_hash(id, size, rtl, no_liga, text)
	sh := &s.words.shards[h % SHARDS]
	sync.mutex_lock(&sh.mu)
	w := word_find(sh, h, id, size, rtl, no_liga, text)
	if w == nil {
		sync.mutex_unlock(&sh.mu)
		nw := shape_word(s, id, size, text, rtl, no_liga, context.allocator)
		sync.mutex_lock(&sh.mu)
		w = word_find(sh, h, id, size, rtl, no_liga, text)
		if w == nil { word_insert(&s.words, sh, h, nw); w = nw } else { free(nw) }
	}
	append(glyphs, ..w.glyphs)
	append(clusters, ..w.clusters)
	width := w.width
	sync.mutex_unlock(&sh.mu)
	return width
}

////////////////////////////////
// Shaping one word

// Shapes `text` as one directional run into a Word allocated in one block (free(w) frees everything).
@(private)
shape_word :: proc(s: ^State, id: Font_Id, size: f32, text: string, rtl, no_liga: bool, allocator: runtime.Allocator) -> ^Word {
	glyphs := make([dynamic]Glyph_Pos, 0, len(text) + 4, context.temp_allocator)
	clusters := make([dynamic]Cluster, 0, len(text) + 4, context.temp_allocator)
	width := shape_text(s, id, size, text, rtl, no_liga, &glyphs, &clusters)
	ng, nc := len(glyphs), len(clusters)
	block, _ := runtime.mem_alloc(size_of(Word) + ng * size_of(Glyph_Pos) + nc * size_of(Cluster) + len(text), align_of(Word), allocator)
	base := uintptr(raw_data(block))
	w := (^Word)(base)
	gp := ([^]Glyph_Pos)(rawptr(base + size_of(Word)))
	cp := ([^]Cluster)(rawptr(base + size_of(Word) + uintptr(ng * size_of(Glyph_Pos))))
	tp := ([^]u8)(rawptr(base + size_of(Word) + uintptr(ng * size_of(Glyph_Pos)) + uintptr(nc * size_of(Cluster))))
	copy(gp[:ng], glyphs[:])
	copy(cp[:nc], clusters[:])
	copy(tp[:len(text)], text)
	w^ = Word{font = id, size = size, rtl = rtl, no_liga = no_liga, text = string(tp[:len(text)]), width = width, glyphs = gp[:ng], clusters = cp[:nc]}
	w.hash = word_hash(id, size, rtl, no_liga, text)
	return w
}

// Characters that belong to the cluster of the character before them, whatever the faces have.
@(private)
sticks :: proc(r: rune, prev: rune) -> bool {
	if prev == 0x200D { return true }   // after a zero width joiner (emoji ZWJ sequences)
	return r == 0x200D || r == 0x200C || (r >= 0xFE00 && r <= 0xFE0F) || (r >= 0xE0100 && r <= 0xE01EF) ||
		(r >= 0xE0020 && r <= 0xE007F) || unicode.is_emoji_modifier(r) || unicode.is_grapheme_extend(r) || r == 0x20E3
}

// Whether a face has a glyph for `r` (BMP answers cached in the face).
@(private)
face_has :: proc(f: ^Font, r: rune) -> bool {
	if r < 0x10000 && len(f.cmap) > 0 {
		word := &f.cmap[int(r) * 2 / 32]
		bit := u32(int(r) * 2 % 32)
		v := sync.atomic_load_explicit(word, .Relaxed)
		if v & (1 << bit) != 0 { return v & (2 << bit) != 0 }
		cp := [1]u32{u32(r)}
		gi := [1]u16{}
		has := f.dw->GetGlyphIndices(&cp[0], 1, &gi[0]) >= 0 && gi[0] != 0
		sync.atomic_or_explicit(word, (1 << bit) | (has ? 2 << bit : 0), .Relaxed)
		return has
	}
	cp := [1]u32{u32(r)}
	gi := [1]u16{}
	return f.dw->GetGlyphIndices(&cp[0], 1, &gi[0]) >= 0 && gi[0] != 0
}

@(private)
in_ranges :: proc(ranges: []Range, r: rune) -> bool {
	if len(ranges) == 0 { return true }
	for rg in ranges { if r >= rg[0] && r <= rg[1] { return true } }
	return false
}

// UTF-16 copy of `text` and, per UTF-16 unit (+ 1), the byte index it starts at.
@(private)
utf16_of :: proc(text: string, allocator := context.temp_allocator) -> (w: []u16, bytes: []i32) {
	n := 0
	for r in text { n += r >= 0x10000 ? 2 : 1 }
	w = make([]u16, n, allocator)
	bytes = make([]i32, n + 1, allocator)
	k := 0
	for r, i in text {
		bytes[k] = i32(i)
		if r >= 0x10000 {
			v := u32(r) - 0x10000
			w[k], w[k + 1] = u16(0xD800 + (v >> 10)), u16(0xDC00 + (v & 0x3FF))
			bytes[k + 1] = i32(i)
			k += 2
		} else {
			w[k] = u16(r)
			k += 1
		}
	}
	bytes[n] = i32(len(text))
	return
}

@(private)
decode16 :: #force_inline proc(w: []u16, i: int) -> (r: rune, n: int) {
	c := rune(w[i])
	if c >= 0xD800 && c < 0xDC00 && i + 1 < len(w) && w[i + 1] >= 0xDC00 && w[i + 1] < 0xE000 {
		return 0x10000 + (c - 0xD800) << 10 + (rune(w[i + 1]) - 0xDC00), 2
	}
	return c, 1
}

// Chooses the face of each UTF-16 unit of `w`: cascade entries in order, then the system fallback, then the first face.
@(private)
itemize_faces :: proc(s: ^State, id: Font_Id, w: []u16) -> []Font_Id {
	faces := make([]Font_Id, len(w), context.temp_allocator)
	top := font_ptr(s, id)
	if top == nil || top.dead { return faces }
	entries := top.entries
	first := primary_face(s, id)
	prev_r: rune
	i := 0
	for i < len(w) {
		r, n := decode16(w, i)
		chosen: Font_Id
		search := true
		if i > 0 && sticks(r, prev_r) {
			if faces[i - 1] == 0 {
				// the base goes to the system fallback: so does the rest of its cluster (emoji ZWJ sequences, modifiers)
				search = false
			} else if pf := face_ptr(s, faces[i - 1]); pf != nil && (face_has(pf, r) || r == 0x200D || r == 0x200C ||
				(r >= 0xFE00 && r <= 0xFE0F) || prev_r == 0x200D || (r >= 0xE0100 && r <= 0xE01EF) || (r >= 0xE0020 && r <= 0xE007F)) {
				// a mark the base's face lacks may still come from elsewhere; joiners and selectors always stay
				chosen = faces[i - 1]
			}
		}
		// the built-in emoji font (emoji.odin): first when U+FE0F asks for the emoji presentation, else after the cascade's
		// faces of the page (web fonts, files); it also replaces the system's own emoji font a font-family list names
		want, explicit := false, false
		if chosen == 0 && search && emoji_may(r) {
			next: rune
			if i + n < len(w) { next, _ = decode16(w, i + n) }
			want = emoji_wanted(r, next)
			explicit = want && (next == 0xFE0F || next == 0x20E3)
			if explicit { chosen = emoji_pick(s, r) }
		}
		if chosen == 0 && search {
			for e in entries {
				if !in_ranges(e.ranges, r) { continue }
				f := face_ptr(s, e.font)
				if f != nil && face_has(f, r) {
					chosen = e.font
					if want && f.color && f.file == nil && f.memory == nil {
						if p := emoji_pick(s, r); p != 0 { chosen = p }   // "Segoe UI Emoji" in a font stack: the built-in emoji font instead
					}
					break
				}
			}
		}
		if chosen == 0 && want && !explicit { chosen = emoji_pick(s, r) }
		for k in 0 ..< n { faces[i + k] = chosen }
		prev_r = r
		i += n
	}
	// what is left: the system fallback, span by span
	use_system := s.fallback != nil && s.system != nil && s.settings.system_fallback && !top.no_system_fallback
	i = 0
	for i < len(w) {
		if faces[i] != 0 { i += 1; continue }
		j := i
		for j < len(w) && faces[j] == 0 { j += 1 }
		if use_system { system_fallback(s, first, w, i, j, faces) }
		for k := i; k < j; {
			if faces[k] != 0 { k += 1; continue }
			// nothing has it: the emoji font if it does (a text-presentation emoji no other face draws), else the first face
			r, n := decode16(w, k)
			pick := first
			if emoji_possible(r) { if p := emoji_pick(s, r); p != 0 { pick = p } }
			for m in 0 ..< n { faces[k + m] = pick }
			k += n
		}
		i = j
	}
	return faces
}

// Maps w[a:b] through IDWriteFontFallback::MapCharacters, based on the first face's family, weight and style.
@(private)
system_fallback :: proc(s: ^State, first: Font_Id, w: []u16, a, b: int, faces: []Font_Id) {
	base := face_ptr(s, first)
	family: [^]u16 = raw_data(EMPTY_LOCALE[:])
	weight: DWRITE_FONT_WEIGHT = 400
	stretch: DWRITE_FONT_STRETCH = 5
	style := DWRITE_FONT_STYLE.NORMAL
	if base != nil {
		if len(base.family) > 0 { family = raw_data(base.family) }
		weight, stretch, style = base.weight, base.stretch, base.style
	}
	an: Analysis
	analysis_init(&an, w, false)
	pos := a
	for pos < b {
		mapped: u32
		dwf: ^IDWriteFont
		scale: f32 = 1
		hr := s.fallback->MapCharacters(&an.source, u32(pos), u32(b - pos), s.system, family, weight, style, stretch, &mapped, &dwf, &scale)
		if hr < 0 || mapped == 0 { return }
		if dwf != nil {
			fid := face_from_dwrite_font(s, dwf)
			com_release(dwf)
			for k in pos ..< min(pos + int(mapped), b) { faces[k] = fid }
		}
		pos += int(mapped)
	}
}

// Shapes `text` (one directional run) into glyphs in visual order, laid out from x = 0. Returns the width.
@(private)
shape_text :: proc(s: ^State, id: Font_Id, size: f32, text: string, rtl, no_liga: bool, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster) -> f32 {
	if !s.ok { return 0 }
	top := font_ptr(s, id)
	if top == nil || top.dead { return 0 }
	w, bytes := utf16_of(text)
	if len(w) == 0 { return 0 }
	faces := itemize_faces(s, id, w)
	scripts := make([dynamic]Script_Run, 0, 4, context.temp_allocator)
	an: Analysis
	analysis_init(&an, w, rtl)
	an.scripts = &scripts
	ascii := s.latin_ok
	if ascii { for u in w { if u >= 0x80 { ascii = false; break } } }
	if ascii {
		append(&scripts, Script_Run{0, u32(len(w)), s.latin})
	} else if s.analyzer->AnalyzeScript(&an.source, 0, u32(len(w)), &an.sink) < 0 || len(scripts) == 0 {
		clear(&scripts)
		append(&scripts, Script_Run{0, u32(len(w)), {}})
	}
	// pieces: same script and same face, in logical order
	Piece :: struct { a, b: int, face: Font_Id, sa: DWRITE_SCRIPT_ANALYSIS }
	pieces := make([dynamic]Piece, 0, 4, context.temp_allocator)
	for sr in scripts {
		i := int(sr.start)
		for i < int(sr.end) {
			j := i + 1
			for j < int(sr.end) && faces[j] == faces[i] { j += 1 }
			append(&pieces, Piece{i, j, faces[i], sr.sa})
			i = j
		}
	}
	// the tag characters of a tag sequence (subdivision flags) belong to the piece of their flag, whatever the script analysis says
	for i := len(pieces) - 1; i > 0; i -= 1 {
		if pieces[i].face == pieces[i - 1].face && w[pieces[i].a] == 0xDB40 {
			pieces[i - 1].b = pieces[i].b
			ordered_remove(&pieces, i)
		}
	}
	// features: the cascade's, minus optional ligatures under letter-spacing
	feats := make([dynamic]DWRITE_FONT_FEATURE, 0, len(top.features) + 4, context.temp_allocator)
	append(&feats, ..top.features)
	if no_liga {
		for t in ([]string{"liga", "clig", "dlig", "hlig"}) { append(&feats, DWRITE_FONT_FEATURE{nameTag = ot_tag(t), parameter = 0}) }
	}
	tf := DWRITE_TYPOGRAPHIC_FEATURES{features = raw_data(feats), featureCount = u32(len(feats))}

	pen: f32
	outs := make([dynamic]Piece_Out, 0, len(pieces), context.temp_allocator)
	for p in pieces {
		g0, c0 := len(glyphs), len(clusters)
		start := pen
		pen = shape_piece(s, p.face, size, w[p.a:p.b], bytes[p.a:p.b + 1], rtl, p.sa, len(feats) > 0 ? &tf : nil, glyphs, clusters, pen)
		append(&outs, Piece_Out{g0, len(glyphs), c0, len(clusters), start, pen - start})
	}
	if rtl && len(outs) > 1 { mirror_pieces(glyphs, clusters[:], outs[:], pen) }
	return pen
}

@(private)
Piece_Out :: struct { g0, g1, c0, c1: int, start, width: f32 }

// Pieces were laid out left to right in logical order (each from the end of the one before); a right-to-left run
// wants its first piece rightmost: each piece moves to its mirrored place and the glyph list to visual order.
@(private)
mirror_pieces :: proc(glyphs: ^[dynamic]Glyph_Pos, clusters: []Cluster, outs: []Piece_Out, total: f32) {
	g_base := outs[0].g0
	tmp := make([]Glyph_Pos, len(glyphs) - g_base, context.temp_allocator)
	k := 0
	for oi := len(outs) - 1; oi >= 0; oi -= 1 {
		o := outs[oi]
		d := (total - o.start - o.width) - o.start
		for gi in o.g0 ..< o.g1 {
			g := glyphs[gi]
			g.x += d
			tmp[k] = g
			k += 1
		}
		for ci in o.c0 ..< o.c1 { clusters[ci].x0 += d; clusters[ci].x1 += d }
	}
	copy(glyphs[g_base:], tmp)
}

// GetGlyphs + GetGlyphPlacements of w (one face, one script, one direction), appended from `pen`, glyphs in visual
// order. `bytes`: the byte index of each unit of `w`, plus one past the end.
@(private)
shape_piece :: proc(s: ^State, face_id: Font_Id, size: f32, w: []u16, bytes: []i32, rtl: bool, sa: DWRITE_SCRIPT_ANALYSIS,
	tf: ^DWRITE_TYPOGRAPHIC_FEATURES, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> f32 {
	sa := sa
	f := face_ptr(s, face_id)
	n := len(w)
	if f == nil || n == 0 { return pen }
	if f.colr != nil && has_tag_chars(w) && !rtl {
		// cluster offsets of a piece are relative to its first character (the end of shape_piece makes them relative to the word)
		g0, c0 := len(glyphs), len(clusters)
		if np, ok := shape_tag_sequence(s, f, face_id, size, w, bytes, glyphs, clusters, pen); ok {
			off := bytes[0]
			for gi in g0 ..< len(glyphs) { glyphs[gi].cluster += off }
			for ci in c0 ..< len(clusters) { clusters[ci].start += off; clusters[ci].end += off }
			return np
		}
	}
	cmap := make([]u16, n, context.temp_allocator)
	tprops := make([]DWRITE_SHAPING_TEXT_PROPERTIES, n, context.temp_allocator)
	maxg := 3 * n / 2 + 16
	gids: []u16
	gprops: []DWRITE_SHAPING_GLYPH_PROPERTIES
	count: u32
	tfs := [1]^DWRITE_TYPOGRAPHIC_FEATURES{tf}
	range_len := [1]u32{u32(n)}
	nfr := u32(tf != nil ? 1 : 0)
	hr: HRESULT
	for attempt in 0 ..< 4 {
		gids = make([]u16, maxg, context.temp_allocator)
		gprops = make([]DWRITE_SHAPING_GLYPH_PROPERTIES, maxg, context.temp_allocator)
		hr = s.analyzer->GetGlyphs(raw_data(w), u32(n), f.dw, false, BOOL(rtl), &sa, nil, nil,
			tf != nil ? &tfs[0] : nil, tf != nil ? &range_len[0] : nil, nfr, u32(maxg), raw_data(cmap), raw_data(tprops),
			raw_data(gids), raw_data(gprops), &count)
		if hr != E_NOT_SUFFICIENT_BUFFER { break }
		maxg *= 2
		_ = attempt
	}
	if hr < 0 || count == 0 { return pen }
	adv := make([]f32, count, context.temp_allocator)
	offs := make([]DWRITE_GLYPH_OFFSET, count, context.temp_allocator)
	if s.analyzer->GetGlyphPlacements(raw_data(w), raw_data(cmap), raw_data(tprops), u32(n), raw_data(gids), raw_data(gprops), count, f.dw,
		size, false, BOOL(rtl), &sa, nil, tf != nil ? &tfs[0] : nil, tf != nil ? &range_len[0] : nil, nfr, raw_data(adv), raw_data(offs)) < 0 {
		// no placements: nominal advances
		gm := make([]DWRITE_GLYPH_METRICS, count, context.temp_allocator)
		f.dw->GetDesignGlyphMetrics(raw_data(gids), count, raw_data(gm), false)
		for i in 0 ..< int(count) { adv[i] = f32(gm[i].advanceWidth) * size / f.upem; offs[i] = {} }
	}
	// clusters: runs of text units sharing a first glyph
	total: f32
	for a in adv { total += a }
	Cl :: struct { t0, t1, g0, g1: int }
	cls := make([dynamic]Cl, 0, n, context.temp_allocator)
	t := 0
	for t < n {
		t1 := t + 1
		for t1 < n && cmap[t1] == cmap[t] { t1 += 1 }
		g0 := int(cmap[t])
		g1 := t1 < n ? int(cmap[t1]) : int(count)
		if g1 < g0 { g1 = g0 }   // defensive: cluster maps never go back for one direction
		append(&cls, Cl{t, t1, g0, g1})
		t = t1
	}
	// glyphs of a cluster with no glyph of its own (g0 == g1) share the previous cluster's
	base_g := len(glyphs)
	resize(glyphs, base_g + int(count))
	if !rtl {
		x := pen
		for c in cls {
			cx0 := x
			for gi in c.g0 ..< c.g1 {
				glyphs[base_g + gi] = Glyph_Pos{face = face_id, id = gids[gi], x = x + offs[gi].advanceOffset, y = -offs[gi].ascenderOffset, advance = adv[gi], cluster = bytes[c.t0] - bytes[0]}
				x += adv[gi]
			}
			append(clusters, Cluster{start = bytes[c.t0] - bytes[0], end = bytes[c.t1] - bytes[0], x0 = cx0, x1 = x})
		}
	} else {
		// glyph 0 is the rightmost: walk from the right edge, then store the glyphs left to right
		x := pen + total
		for c in cls {
			cx1 := x
			for gi in c.g0 ..< c.g1 {
				x -= adv[gi]
				glyphs[base_g + int(count) - 1 - gi] = Glyph_Pos{face = face_id, id = gids[gi], rtl = true, x = x - offs[gi].advanceOffset, y = -offs[gi].ascenderOffset, advance = adv[gi], cluster = bytes[c.t0] - bytes[0]}
			}
			append(clusters, Cluster{start = bytes[c.t0] - bytes[0], end = bytes[c.t1] - bytes[0], x0 = x, x1 = cx1, rtl = true})
		}
	}
	// cluster byte offsets are relative to this piece: make them relative to the word
	off := bytes[0]
	for gi in base_g ..< len(glyphs) { glyphs[gi].cluster += off }
	for ci := len(clusters) - len(cls); ci < len(clusters); ci += 1 { clusters[ci].start += off; clusters[ci].end += off }
	return pen + total
}

////////////////////////////////
// Directions

// Whether `text` may need the bidi algorithm: right-to-left letters or bidi controls (U+0590..U+08FF, U+FB1D..U+FDFF,
// U+FE70..U+FEFF, U+10800..U+10FFF, U+1E800..U+1EFFF, RLM, RLE, RLO, RLI, ALM).
maybe_rtl :: proc(text: string) -> bool {
	for i := 0; i < len(text); i += 1 {
		b := text[i]
		if b < 0xD6 { continue }
		if b & 0xC0 == 0x80 { continue }
		r := decode_at(text, i)
		if is_rtl_char(r) || r == 0x200F || r == 0x202B || r == 0x202E || r == 0x2067 || r == 0x061C { return true }
	}
	return false
}

@(private)
decode_at :: proc(text: string, i: int) -> rune {
	b := text[i]
	switch {
	case b < 0x80: return rune(b)
	case b < 0xE0 && i + 1 < len(text): return rune(b & 0x1F) << 6 | rune(text[i + 1] & 0x3F)
	case b < 0xF0 && i + 2 < len(text): return rune(b & 0x0F) << 12 | rune(text[i + 1] & 0x3F) << 6 | rune(text[i + 2] & 0x3F)
	case i + 3 < len(text): return rune(b & 0x07) << 18 | rune(text[i + 1] & 0x3F) << 12 | rune(text[i + 2] & 0x3F) << 6 | rune(text[i + 3] & 0x3F)
	}
	return 0xFFFD
}

@(private)
is_rtl_char :: proc(r: rune) -> bool {
	return (r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF) ||
		(r >= 0x10800 && r <= 0x10FFF) || (r >= 0x1E800 && r <= 0x1EFFF)
}

// first_strong_rtl, answering ASCII text without decoding it.
@(private)
piece_rtl :: #force_inline proc(text: string) -> bool {
	for i in 0 ..< len(text) { if text[i] >= 0xD6 { return first_strong_rtl(text) } }
	return false
}

// Whether the first strong character of `text` is right-to-left (UAX #9 P2, without isolates).
first_strong_rtl :: proc(text: string) -> bool {
	for r in text {
		if is_rtl_char(r) { return true }
		if unicode.is_letter(r) { return false }
	}
	return false
}
