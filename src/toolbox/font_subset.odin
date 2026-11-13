package tk_toolbox

// A TrueType font cut down to the glyphs of some characters: what a program embeds of an icon font is then what it
// draws (Lucide: about 90 of its 1900 icons, 30 KB of its 900 KB).

import "core:fmt"
import "core:slice"

// The tables a subset keeps; every other one (GSUB's ligatures by name, kerning, hinting) goes.
@(private = "file")
SUBSET_TABLES :: [?]string{"OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"}
@(private = "file")
SFNT_TRUETYPE :: 0x00010000
// head.checkSumAdjustment is this minus the sum of the whole font.
@(private = "file")
SFNT_CHECKSUM_MAGIC :: 0xB1B0AFBA
@(private = "file")
POST_NO_NAMES :: 0x00030000
// A composite glyph's component flags.
@(private = "file")
COMPONENT_WORDS :: 0x0001
@(private = "file")
COMPONENT_SCALE :: 0x0008
@(private = "file")
COMPONENT_MORE :: 0x0020
@(private = "file")
COMPONENT_XY_SCALE :: 0x0040
@(private = "file")
COMPONENT_TWO_BY_TWO :: 0x0080
@(private = "file")
BMP_LAST :: 0xffff

// A TrueType font's table, by tag.
Sfnt_Table :: struct { tag: string, data: []u8 }

// The tables of a TrueType font (a single face, not a collection). why: it is not one.
sfnt_tables :: proc(data: []u8, allocator := context.temp_allocator) -> (tables: []Sfnt_Table, why: string) {
	if len(data) < 12 { return nil, "not a font: too short" }
	if be32(data, 0) != SFNT_TRUETYPE { return nil, "not a TrueType font (CFF outlines and collections are not read)" }
	n := be16(data, 4)
	out := make([dynamic]Sfnt_Table, allocator)
	for i in 0 ..< n {
		at := 12 + 16 * i
		if at + 16 > len(data) { return nil, "a truncated table directory" }
		off, length := be32(data, at + 8), be32(data, at + 12)
		if off + length > len(data) { return nil, fmt.tprintf("the table %s ends past the file", string(data[at:at + 4])) }
		append(&out, Sfnt_Table{string(data[at:at + 4]), data[off:off + length]})
	}
	return out[:], ""
}

// A table of `tables` (nil when it has none).
sfnt_table :: proc(tables: []Sfnt_Table, tag: string) -> []u8 {
	for t in tables { if t.tag == tag { return t.data } }
	return nil
}

// The glyph of each character the font's character map has (format 12, else format 4), in no order.
sfnt_cmap :: proc(cmap: []u8, allocator := context.temp_allocator) -> (glyphs: map[rune]int, why: string) {
	if len(cmap) < 4 { return nil, "no character map" }
	sub, format := -1, 0
	for i in 0 ..< be16(cmap, 2) {
		at := 4 + 8 * i
		if at + 8 > len(cmap) { return nil, "a truncated character map" }
		off := be32(cmap, at + 4)
		if off + 2 > len(cmap) { continue }
		f := be16(cmap, off)
		if f == 12 || (f == 4 && format != 12) { sub, format = off, f }
	}
	if sub < 0 { return nil, "no format 4 or 12 character map" }
	out := make(map[rune]int, allocator)
	if format == 12 {
		for g in 0 ..< be32(cmap, sub + 12) {
			at := sub + 16 + 12 * g
			if at + 12 > len(cmap) { return nil, "a truncated character map" }
			first, last, gid := be32(cmap, at), be32(cmap, at + 4), be32(cmap, at + 8)
			for c in first ..= last { out[rune(c)] = gid + (c - first) }
		}
		return out, ""
	}
	segs := be16(cmap, sub + 6) / 2
	ends := sub + 14
	starts := ends + 2 * segs + 2
	deltas := starts + 2 * segs
	ranges := deltas + 2 * segs
	if ranges + 2 * segs > len(cmap) { return nil, "a truncated character map" }
	for s in 0 ..< segs {
		first, last := be16(cmap, starts + 2 * s), be16(cmap, ends + 2 * s)
		delta, range := be16(cmap, deltas + 2 * s), be16(cmap, ranges + 2 * s)
		if first == BMP_LAST || first > last { continue }
		for c in first ..= last {
			gid: int
			if range == 0 {
				gid = (c + delta) & 0xffff
			} else {
				at := ranges + 2 * s + range + 2 * (c - first)
				if at + 2 > len(cmap) { continue }
				gid = be16(cmap, at)
				if gid != 0 { gid = (gid + delta) & 0xffff }
			}
			if gid != 0 { out[rune(c)] = gid }
		}
	}
	return out, ""
}

// The bytes of glyph `gid` in 'glyf' (empty for a glyph with no outline: a space), by 'loca' of `long` offsets
// (head.indexToLocFormat 1) or short ones.
sfnt_glyph :: proc(glyf, loca: []u8, long: bool, gid: int) -> []u8 {
	a, b: int
	if long {
		if 4 * gid + 8 > len(loca) { return nil }
		a, b = be32(loca, 4 * gid), be32(loca, 4 * gid + 4)
	} else {
		if 2 * gid + 4 > len(loca) { return nil }
		a, b = 2 * be16(loca, 2 * gid), 2 * be16(loca, 2 * gid + 2)
	}
	if a > b || b > len(glyf) { return nil }
	return glyf[a:b]
}

// The font with only the glyphs of `codes` (the characters the font has none for are left out), .notdef and the glyphs
// a kept composite glyph is made of: its outlines, advances and metrics as they were, its character map only `codes`,
// its glyphs numbered anew in their old order, its glyph names gone (post 3.0) and only SUBSET_TABLES kept.
font_subset :: proc(data: []u8, codes: []rune, allocator := context.allocator) -> (out: []u8, why: string) {
	tables: []Sfnt_Table
	if tables, why = sfnt_tables(data); why != "" { return nil, why }
	head, hhea, maxp := sfnt_table(tables, "head"), sfnt_table(tables, "hhea"), sfnt_table(tables, "maxp")
	loca, glyf, hmtx, cmap := sfnt_table(tables, "loca"), sfnt_table(tables, "glyf"), sfnt_table(tables, "hmtx"), sfnt_table(tables, "cmap")
	if len(head) < 54 || len(hhea) < 36 || len(maxp) < 6 || loca == nil || glyf == nil || hmtx == nil || cmap == nil {
		return nil, "not a TrueType font with outlines (head, hhea, maxp, loca, glyf, hmtx, cmap)"
	}
	long := be16(head, 50) == 1
	glyphs := be16(maxp, 4)
	metrics := be16(hhea, 34)
	if metrics == 0 || 4 * metrics > len(hmtx) { return nil, "hhea.numberOfHMetrics does not fit hmtx" }
	char_map, cwhy := sfnt_cmap(cmap)
	if cwhy != "" { return nil, cwhy }

	// the glyphs kept, and the composite glyphs' parts
	keep := make(map[int]bool, context.temp_allocator)
	keep[0] = true
	mapped := make([dynamic][2]int, context.temp_allocator)   // a character and its old glyph
	for c in codes {
		gid, ok := char_map[c]
		if !ok || gid >= glyphs { continue }
		append(&mapped, [2]int{int(c), gid})
		keep[gid] = true
	}
	todo := make([dynamic]int, context.temp_allocator)
	for g in keep { append(&todo, g) }
	for len(todo) > 0 {
		g := pop(&todo)
		for part in composite_parts(sfnt_glyph(glyf, loca, long, g)) {
			if part < glyphs && !keep[part] { keep[part] = true; append(&todo, part) }
		}
	}
	old := make([dynamic]int, context.temp_allocator)
	for g in keep { append(&old, g) }
	slice.sort(old[:])
	new_of := make(map[int]int, context.temp_allocator)
	for g, i in old { new_of[g] = i }

	// glyf, loca (long), hmtx (a metric per glyph)
	new_glyf := make([dynamic]u8, context.temp_allocator)
	new_loca := make([dynamic]u8, context.temp_allocator)
	new_hmtx := make([dynamic]u8, context.temp_allocator)
	for g in old {
		put32(&new_loca, len(new_glyf))
		start := len(new_glyf)
		append(&new_glyf, ..sfnt_glyph(glyf, loca, long, g))
		composite_renumber(new_glyf[start:], new_of)
		for len(new_glyf) % 4 != 0 { append(&new_glyf, 0) }
		advance, lsb: int
		if g < metrics {
			advance, lsb = be16(hmtx, 4 * g), be16(hmtx, 4 * g + 2)
		} else {
			advance = be16(hmtx, 4 * (metrics - 1))
			at := 4 * metrics + 2 * (g - metrics)
			lsb = at + 2 <= len(hmtx) ? be16(hmtx, at) : 0
		}
		put16(&new_hmtx, advance)
		put16(&new_hmtx, lsb)
	}
	put32(&new_loca, len(new_glyf))

	// cmap: format 4 when every character is in the BMP, else format 12; runs of characters whose glyphs follow are one segment
	slice.sort_by(mapped[:], proc(a, b: [2]int) -> bool { return a[0] < b[0] })
	runs := make([dynamic][3]int, context.temp_allocator)   // first character, last, first glyph (new)
	for m in mapped {
		g := new_of[m[1]]
		if n := len(runs); n > 0 && runs[n - 1][1] + 1 == m[0] && runs[n - 1][2] + (m[0] - runs[n - 1][0]) == g {
			runs[n - 1][1] = m[0]
		} else {
			append(&runs, [3]int{m[0], m[0], g})
		}
	}
	new_cmap := cmap_table(runs[:])

	new_head := slice.clone(head, context.temp_allocator)
	set16(new_head, 50, 1)
	set32(new_head, 8, 0)
	new_hhea := slice.clone(hhea, context.temp_allocator)
	set16(new_hhea, 34, len(old))
	new_maxp := slice.clone(maxp, context.temp_allocator)
	set16(new_maxp, 4, len(old))

	out_tables := make([dynamic]Sfnt_Table, context.temp_allocator)
	for tag in SUBSET_TABLES {
		t: []u8
		switch tag {
		case "cmap": t = new_cmap
		case "glyf": t = new_glyf[:]
		case "head": t = new_head
		case "hhea": t = new_hhea
		case "hmtx": t = new_hmtx[:]
		case "loca": t = new_loca[:]
		case "maxp": t = new_maxp
		case "post":
			post := sfnt_table(tables, "post")
			if len(post) < 32 { continue }
			t = slice.clone(post[:32], context.temp_allocator)
			set32(t, 0, POST_NO_NAMES)
		case "OS/2":
			os2 := sfnt_table(tables, "OS/2")
			if len(os2) < 68 { continue }
			t = slice.clone(os2, context.temp_allocator)
			if len(mapped) > 0 {
				set16(t, 64, min(mapped[0][0], BMP_LAST))
				set16(t, 66, min(mapped[len(mapped) - 1][0], BMP_LAST))
			}
		case:
			t = sfnt_table(tables, tag)
			if t == nil { continue }
		}
		append(&out_tables, Sfnt_Table{tag, t})
	}
	return sfnt_write(out_tables[:], allocator), ""
}

// The glyphs a composite glyph is made of (none for a simple one).
@(private)
composite_parts :: proc(g: []u8) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	at := 10
	if len(g) < at || i16(be16(g, 0)) >= 0 { return nil }
	for at + 4 <= len(g) {
		flags := be16(g, at)
		append(&out, be16(g, at + 2))
		at += component_size(flags)
		if flags & COMPONENT_MORE == 0 { break }
	}
	return out[:]
}

// A composite glyph's parts numbered by `new_of`, in place.
@(private = "file")
composite_renumber :: proc(g: []u8, new_of: map[int]int) {
	at := 10
	if len(g) < at || i16(be16(g, 0)) >= 0 { return }
	for at + 4 <= len(g) {
		flags := be16(g, at)
		set16(g, at + 2, new_of[be16(g, at + 2)])
		at += component_size(flags)
		if flags & COMPONENT_MORE == 0 { break }
	}
}

// A component's bytes: flags, glyph, its two arguments, its transform.
@(private = "file")
component_size :: proc(flags: int) -> int {
	n := 4 + (flags & COMPONENT_WORDS != 0 ? 4 : 2)
	if flags & COMPONENT_SCALE != 0 { n += 2 } else if flags & COMPONENT_XY_SCALE != 0 { n += 4 } else if flags & COMPONENT_TWO_BY_TWO != 0 { n += 8 }
	return n
}

// A character map of one subtable for Windows: format 4 (Unicode BMP) when every run is in it, else format 12 (all of
// Unicode). runs: first character, last, first glyph, sorted.
@(private = "file")
cmap_table :: proc(runs: [][3]int) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	bmp := len(runs) == 0 || runs[len(runs) - 1][1] < BMP_LAST
	put16(&b, 0)
	put16(&b, 1)
	put16(&b, 3)
	put16(&b, bmp ? 1 : 10)
	put32(&b, 12)
	if !bmp {
		put16(&b, 12)
		put16(&b, 0)
		put32(&b, 16 + 12 * len(runs))
		put32(&b, 0)
		put32(&b, len(runs))
		for r in runs { put32(&b, r[0]); put32(&b, r[1]); put32(&b, r[2]) }
		return b[:]
	}
	segs := len(runs) + 1   // (the last one: 0xFFFF, which the format requires)
	search, selector := 2, 0
	for search * 2 <= 2 * segs { search *= 2; selector += 1 }
	put16(&b, 4)
	put16(&b, 16 + 8 * segs)
	put16(&b, 0)
	put16(&b, 2 * segs)
	put16(&b, search)
	put16(&b, selector)
	put16(&b, 2 * segs - search)
	for r in runs { put16(&b, r[1]) }
	put16(&b, BMP_LAST)
	put16(&b, 0)
	for r in runs { put16(&b, r[0]) }
	put16(&b, BMP_LAST)
	for r in runs { put16(&b, (r[2] - r[0]) & 0xffff) }
	put16(&b, 1)
	for _ in 0 ..< segs { put16(&b, 0) }
	return b[:]
}

// A TrueType font of `tables` (sorted by tag here): the directory, each table on 4 bytes with its checksum, and the
// head's checksum adjustment.
@(private = "file")
sfnt_write :: proc(tables: []Sfnt_Table, allocator := context.allocator) -> []u8 {
	sorted := slice.clone(tables, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Sfnt_Table) -> bool { return a.tag < b.tag })
	n := len(sorted)
	search, selector := 1, 0
	for search * 2 <= n { search *= 2; selector += 1 }
	out := make([dynamic]u8, allocator)
	put32(&out, SFNT_TRUETYPE)
	put16(&out, n)
	put16(&out, 16 * search)
	put16(&out, selector)
	put16(&out, 16 * (n - search))
	offset := 12 + 16 * n
	for t in sorted {
		append(&out, ..transmute([]u8)t.tag)
		put32(&out, int(sfnt_checksum(t.data)))
		put32(&out, offset)
		put32(&out, len(t.data))
		offset += (len(t.data) + 3) &~ 3
	}
	head_at := -1
	for t in sorted {
		if t.tag == "head" { head_at = len(out) }
		append(&out, ..t.data)
		for len(out) % 4 != 0 { append(&out, 0) }
	}
	if head_at >= 0 { set32(out[:], head_at + 8, int(u32(SFNT_CHECKSUM_MAGIC) - sfnt_checksum(out[:]))) }
	return out[:]
}

// The sum of a table's big-endian 32-bit words (the last one padded with zeros), modulo 2^32.
@(private = "file")
sfnt_checksum :: proc(d: []u8) -> u32 {
	sum: u32
	for i := 0; i < len(d); i += 4 {
		w: u32
		for k in 0 ..< 4 { w = w << 8 | (i + k < len(d) ? u32(d[i + k]) : 0) }
		sum += w
	}
	return sum
}

@(private = "file")
be16 :: proc(d: []u8, at: int) -> int { return int(d[at]) << 8 | int(d[at + 1]) }
@(private = "file")
be32 :: proc(d: []u8, at: int) -> int { return be16(d, at) << 16 | be16(d, at + 2) }
@(private = "file")
set16 :: proc(d: []u8, at, v: int) { d[at], d[at + 1] = u8(v >> 8), u8(v) }
@(private = "file")
set32 :: proc(d: []u8, at, v: int) { set16(d, at, v >> 16 & 0xffff); set16(d, at + 2, v & 0xffff) }
@(private = "file")
put16 :: proc(b: ^[dynamic]u8, v: int) { append(b, u8(v >> 8), u8(v)) }
@(private = "file")
put32 :: proc(b: ^[dynamic]u8, v: int) { put16(b, v >> 16 & 0xffff); put16(b, v & 0xffff) }
