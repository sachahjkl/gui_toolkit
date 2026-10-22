package font

// Ligature substitutions of a font's GSUB table (lookup type 4, directly or through an Extension lookup, type 7) of one
// feature, applied to a run of glyphs. Emoji fonts form their sequences (ZWJ families, flags, keycaps, tag sequences) with
// such ligatures under `ccmp`. DirectWrite forms all of them but the tag sequences (it takes the tag characters,
// U+E0020 .. U+E007F, for invisible and shapes without them): shape.odin falls back to this for those. Portable, bounds
// checked (the table comes from a web font), and nothing else of GSUB: it is not a shaping engine.

// The glyphs after applying every type 4 lookup of `feature` (a 4 byte tag, "ccmp") in lookup order. `out` is allocated
// with `allocator`. ok = false: the table has no such feature or cannot be read.
gsub_ligate :: proc(gsub: []u8, feature: [4]u8, glyphs: []u16, allocator := context.allocator) -> (out: []u16, ok: bool) {
	r := Rd{d = gsub}
	if len(gsub) < 10 || rd_u16(&r, 0) != 1 { return nil, false }
	flist, llist := rd_u16(&r, 6), rd_u16(&r, 8)
	nf := rd_u16(&r, flist)
	lookups := make([dynamic]int, 0, 8, context.temp_allocator)
	found := false
	for i in 0 ..< nf {
		rec := flist + 2 + i * 6
		if r.bad || rec + 6 > len(gsub) { return nil, false }
		tag := [4]u8{gsub[rec], gsub[rec + 1], gsub[rec + 2], gsub[rec + 3]}
		if tag != feature { continue }
		found = true
		ft := flist + rd_u16(&r, rec + 4)
		n := rd_u16(&r, ft + 2)
		for k in 0 ..< n { append(&lookups, rd_u16(&r, ft + 4 + k * 2)) }
	}
	if r.bad || !found { return nil, false }
	// lookups apply in lookup list order, once each
	for i in 1 ..< len(lookups) {
		v := lookups[i]
		j := i - 1
		for j >= 0 && lookups[j] > v { lookups[j + 1] = lookups[j]; j -= 1 }
		lookups[j + 1] = v
	}
	seq := make([dynamic]u16, 0, len(glyphs), context.temp_allocator)
	append(&seq, ..glyphs)
	nl := rd_u16(&r, llist)
	last := -1
	for li in lookups {
		if li == last { continue }
		last = li
		if li >= nl { continue }
		lk := llist + rd_u16(&r, llist + 2 + li * 2)
		typ, nsub := rd_u16(&r, lk), rd_u16(&r, lk + 4)
		for s in 0 ..< nsub {
			sub := lk + rd_u16(&r, lk + 6 + s * 2)
			st := typ
			if typ == 7 {
				if rd_u16(&r, sub) != 1 { continue }
				st = rd_u16(&r, sub + 2)
				sub += rd_u32(&r, sub + 4)
			}
			if r.bad { return nil, false }
			if st == 4 { apply_ligatures(&r, sub, &seq) }
		}
	}
	if r.bad { return nil, false }
	out = make([]u16, len(seq), allocator)
	copy(out, seq[:])
	return out, true
}

@(private)
apply_ligatures :: proc(r: ^Rd, sub: int, seq: ^[dynamic]u16) {
	if rd_u16(r, sub) != 1 { return }
	cov := sub + rd_u16(r, sub + 2)
	nsets := rd_u16(r, sub + 4)
	i := 0
	for i < len(seq) {
		ci := coverage_index(r, cov, seq[i])
		if ci < 0 || ci >= nsets { i += 1; continue }
		set := sub + rd_u16(r, sub + 6 + ci * 2)
		nlig := rd_u16(r, set)
		for l in 0 ..< nlig {
			lig := set + rd_u16(r, set + 2 + l * 2)
			glyph, n := u16(rd_u16(r, lig)), rd_u16(r, lig + 2)
			if r.bad { return }
			if n < 1 || i + n > len(seq) { continue }
			match := true
			for c in 1 ..< n {
				if rd_u16(r, lig + 4 + (c - 1) * 2) != int(seq[i + c]) { match = false; break }
			}
			if !match { continue }
			seq[i] = glyph
			for _ in 1 ..< n { ordered_remove(seq, i + 1) }
			break
		}
		if r.bad { return }
		i += 1
	}
}

// Index of `glyph` in a Coverage table (format 1: glyph array, format 2: ranges), -1 when it is not covered.
@(private)
coverage_index :: proc(r: ^Rd, cov: int, glyph: u16) -> int {
	switch rd_u16(r, cov) {
	case 1:
		n := rd_u16(r, cov + 2)
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			g := rd_u16(r, cov + 4 + mid * 2)
			switch {
			case g < int(glyph): lo = mid + 1
			case g > int(glyph): hi = mid
			case: return mid
			}
		}
	case 2:
		n := rd_u16(r, cov + 2)
		for k in 0 ..< n {
			o := cov + 4 + k * 6
			first, end, start_index := rd_u16(r, o), rd_u16(r, o + 2), rd_u16(r, o + 4)
			if r.bad { return -1 }
			if int(glyph) >= first && int(glyph) <= end { return start_index + int(glyph) - first }
		}
	}
	return -1
}
