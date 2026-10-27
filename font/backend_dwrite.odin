#+build windows
package font

import "base:runtime"
import "core:slice"
import "core:strings"

// The DirectWrite backend: IDWriteTextAnalyzer shapes (GetGlyphs / GetGlyphPlacements) and analyses (scripts, bidi,
// line breaks with Windows' dictionaries), IDWriteFontFace answers coverage, metrics and outlines. And the system's
// fonts on Windows whatever the backend: the system collection and IDWriteFontFallback.

@(private)
dwrite_backend := Text_Backend{
	name         = "dwrite",
	start        = dwrite_start,
	stop         = proc(s: ^State) {},
	face_open    = proc(s: ^State, f: ^Font) -> bool { return true },
	face_close   = proc(f: ^Font) {},
	has_glyph    = dwrite_has_glyph,
	face_metrics = dwrite_face_metrics,
	glyph_box    = dwrite_glyph_box,
	scripts      = dwrite_scripts,
	shape        = dwrite_shape,
	bidi         = dwrite_bidi,
	line_breaks  = dwrite_line_breaks,
	outline      = dwrite_outline_provider,
}

@(private)
dwrite_system := System_Fonts{
	name     = "dwrite",
	fallback = dwrite_fallback,
	families = dwrite_families,
}

#assert(size_of(Feature) == size_of(DWRITE_FONT_FEATURE))

// The horizontal features DirectWrite (and HarfBuzz) turn on by default, which an explicit feature list would drop.
@(private)
DWRITE_DEFAULT_FEATURES := [?][4]u8{{'k', 'e', 'r', 'n'}, {'l', 'i', 'g', 'a'}, {'c', 'l', 'i', 'g'}, {'c', 'a', 'l', 't'}, {'r', 'c', 'l', 't'}}

@(private)
dwrite_start :: proc(s: ^State) -> bool {
	if s.analyzer == nil { return false }
	a := [1]u16{'a'}
	scripts := make([dynamic]Script_Item, 0, 1, context.temp_allocator)
	bytes := [2]i32{0, 1}
	if dwrite_scripts(s, "a", a[:], bytes[:], false, &scripts) && len(scripts) == 1 { s.latin, s.latin_ok = scripts[0], true }
	return true
}

@(private)
script_item_of :: proc(start, end: u32, sa: DWRITE_SCRIPT_ANALYSIS) -> Script_Item {
	return {start = start, end = end, data = u64(sa.script) | u64(sa.shapes) << 32}
}

@(private)
script_analysis_of :: proc(it: Script_Item) -> DWRITE_SCRIPT_ANALYSIS {
	return {script = u16(it.data), shapes = DWRITE_SCRIPT_SHAPES(it.data >> 32)}
}

@(private)
dwrite_has_glyph :: proc(s: ^State, f: ^Font, r: rune) -> bool {
	cp := [1]u32{u32(r)}
	gi := [1]u16{}
	return f.dw->GetGlyphIndices(&cp[0], 1, &gi[0]) >= 0 && gi[0] != 0
}

@(private)
dwrite_face_metrics :: proc(s: ^State, f: ^Font) -> Face_Metrics {
	dm := f.dm
	return {
		upem = i32(dm.designUnitsPerEm), ascent = i32(dm.ascent), descent = i32(dm.descent), line_gap = i32(dm.lineGap),
		cap_height = i32(dm.capHeight), x_height = i32(dm.xHeight),
		underline_position = i32(dm.underlinePosition), underline_thickness = i32(dm.underlineThickness),
		strike_position = i32(dm.strikethroughPosition), strike_thickness = i32(dm.strikethroughThickness),
	}
}

@(private)
dwrite_glyph_box :: proc(s: ^State, f: ^Font, gid: u16) -> (Glyph_Box, bool) {
	ids := [1]u16{gid}
	gm: DWRITE_GLYPH_METRICS
	if f.dw->GetDesignGlyphMetrics(&ids[0], 1, &gm, false) < 0 { return {}, false }
	b := Glyph_Box{
		advance = f32(gm.advanceWidth),
		x_min = f32(gm.leftSideBearing), x_max = f32(gm.advanceWidth) - f32(gm.rightSideBearing),
		y_max = f32(gm.verticalOriginY) - f32(gm.topSideBearing),
		y_min = f32(gm.verticalOriginY) - (f32(gm.advanceHeight) - f32(gm.bottomSideBearing)),
	}
	b.empty = !(b.x_max > b.x_min && b.y_max > b.y_min)
	return b, true
}

@(private)
dwrite_scripts :: proc(s: ^State, text: string, w: []u16, bytes: []i32, rtl: bool, out: ^[dynamic]Script_Item) -> bool {
	if s.analyzer == nil { return false }
	runs := make([dynamic]Script_Run, 0, 4, context.temp_allocator)
	an: Analysis
	analysis_init(&an, w, rtl)
	an.scripts = &runs
	if s.analyzer->AnalyzeScript(&an.source, 0, u32(len(w)), &an.sink) < 0 { return false }
	for r in runs { append(out, script_item_of(r.start, r.end, r.sa)) }
	return true
}

@(private)
dwrite_bidi :: proc(s: ^State, text: string, rtl: bool, levels: []u8) -> bool {
	if s.analyzer == nil { return false }
	w, bytes := utf16_of(text)
	an: Analysis
	analysis_init(&an, w, rtl)
	lv := make([]u8, len(w), context.temp_allocator)
	base := u8(rtl ? 1 : 0)
	for &l in lv { l = base }
	an.levels = lv
	s.analyzer->AnalyzeBidi(&an.source, 0, u32(len(w)), &an.sink)
	for i in 0 ..< len(w) {
		for b in bytes[i] ..< bytes[i + 1] { levels[b] = lv[i] }
	}
	return true
}

@(private)
dwrite_line_breaks :: proc(s: ^State, text: string, out: ^[dynamic]Break_Opportunity) -> bool {
	if s.analyzer == nil { return false }
	w, bytes := utf16_of(text)
	an: Analysis
	analysis_init(&an, w, false)
	bp := make([]DWRITE_LINE_BREAKPOINT, len(w), context.temp_allocator)
	an.breaks = bp
	if s.analyzer->AnalyzeLineBreakpoints(&an.source, 0, u32(len(w)), &an.sink) < 0 { return false }
	for i in 1 ..< len(w) {
		if bytes[i] == bytes[i - 1] { continue }   // second unit of a surrogate pair
		after := DWRITE_BREAK_CONDITION(u8(bp[i - 1]) >> 2 & 3)
		before := DWRITE_BREAK_CONDITION(u8(bp[i]) & 3)
		switch {
		case after == .MUST_BREAK || before == .MUST_BREAK: append(out, Break_Opportunity{int(bytes[i]), true})
		case after == .MAY_NOT_BREAK || before == .MAY_NOT_BREAK:
		case after == .CAN_BREAK || before == .CAN_BREAK: append(out, Break_Opportunity{int(bytes[i]), false})
		}
	}
	return true
}

// Maps w[a:b] through IDWriteFontFallback::MapCharacters, based on the first face's family, weight and style.
@(private)
dwrite_fallback :: proc(s: ^State, first: Font_Id, w: []u16, a, b: int, faces: []Font_Id) {
	if s.fallback == nil || s.system == nil { return }
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

@(private)
dwrite_families :: proc(s: ^State, allocator: runtime.Allocator) -> []string {
	if s.system == nil { return nil }
	out := make([dynamic]string, 0, 64, allocator)
	n := s.system->GetFontFamilyCount()
	for i in 0 ..< n {
		fam: ^IDWriteFontFamily
		if s.system->GetFontFamily(i, &fam) < 0 || fam == nil { continue }
		names: ^IDWriteLocalizedStrings
		if fam->GetFamilyNames(&names) >= 0 && names != nil {
			name := localized_string(names, allocator)
			if name != "" { append(&out, name) } else { delete(name, allocator) }
			com_release(names)
		}
		com_release(fam)
	}
	slice.sort_by(out[:], proc(a, b: string) -> bool { return strings.compare(a, b) < 0 })
	// a family a font set lists twice (rare): once
	k := 0
	for i in 0 ..< len(out) {
		if k > 0 && out[k - 1] == out[i] { delete(out[i], allocator); continue }
		out[k] = out[i]
		k += 1
	}
	resize(&out, k)
	return out[:]
}

// GetGlyphs + GetGlyphPlacements of the request (one face, one script, one direction), appended from `pen`, glyphs in
// visual order.
@(private)
dwrite_shape :: proc(s: ^State, req: ^Shape_Request, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> f32 {
	sa := script_analysis_of(req.script)
	f := req.face
	face_id, size, w, bytes, rtl := req.face_id, req.size, req.w, req.bytes, req.rtl
	n := len(w)
	if f == nil || n == 0 { return pen }
	// a feature list replaces DirectWrite's defaults: they go first (kerning stays under letter-spacing and
	// font-feature-settings, as CSS wants and as HarfBuzz does), each one the list does not set itself
	feats := req.features
	if len(feats) > 0 {
		all := make([dynamic]Feature, 0, len(feats) + len(DWRITE_DEFAULT_FEATURES), context.temp_allocator)
		outer: for d in DWRITE_DEFAULT_FEATURES {
			for f in feats { if f.tag == d { continue outer } }
			append(&all, Feature{tag = d, value = 1})
		}
		append(&all, ..feats)
		feats = all[:]
	}
	tf_value := DWRITE_TYPOGRAPHIC_FEATURES{features = (^DWRITE_FONT_FEATURE)(raw_data(feats)), featureCount = u32(len(feats))}
	tf: ^DWRITE_TYPOGRAPHIC_FEATURES = len(req.features) > 0 ? &tf_value : nil
	// locale name for the `locl` feature (BCP 47, ASCII): a NUL-terminated UTF-16 string, nil when none
	locale: [^]u16
	if len(req.lang) > 0 && len(req.lang) < 96 {
		buf := make([]u16, len(req.lang) + 1, context.temp_allocator)
		for i in 0 ..< len(req.lang) { buf[i] = u16(req.lang[i]) }
		buf[len(req.lang)] = 0
		locale = raw_data(buf)
	}
	if f.colr != nil && has_tag_chars(w) && !rtl {
		// cluster offsets of a piece are relative to its first character (the end of this proc makes them relative to the word)
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
		hr = s.analyzer->GetGlyphs(raw_data(w), u32(n), f.dw, false, BOOL(rtl), &sa, locale, nil,
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
		size, false, BOOL(rtl), &sa, locale, tf != nil ? &tfs[0] : nil, tf != nil ? &range_len[0] : nil, nfr, raw_data(adv), raw_data(offs)) < 0 {
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
