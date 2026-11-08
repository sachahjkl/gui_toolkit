#+build windows
package font

// The tables of a face from DirectWrite (TryGetFontTable: system fonts, files and memory fonts alike).
@(private)
face_table_read :: proc(f: ^Font, tag: string) -> (data: []u8, ctx: rawptr) {
	p: rawptr
	n: u32
	exists: BOOL
	if f.dw->TryGetFontTable(ot_tag(tag), &p, &n, &ctx, &exists) < 0 || !exists || p == nil || n == 0 { return nil, nil }
	return ([^]u8)(p)[:n], ctx
}

@(private)
face_table_release :: proc(f: ^Font, ctx: rawptr) {
	if f.dw != nil && ctx != nil { f.dw->ReleaseFontTable(ctx) }
}

// A face made here already knows its color tables (font_windows.odin).
@(private) platform_face_opened :: proc(s: ^State, f: ^Font) {}

// Tag sequences (a flag emoji followed by tag characters U+E0020 .. U+E007F: England, Scotland, Wales): DirectWrite shapes
// them as separate glyphs. For a face with COLR the sequence is looked up in its GSUB ccmp ligatures instead. Appends
// the one glyph and its cluster and returns the new pen; ok = false when the sequence does not collapse into one glyph
// (the caller then shapes it as usual).
@(private)
shape_tag_sequence :: proc(s: ^State, f: ^Font, face_id: Font_Id, size: f32, w: []u16, bytes: []i32, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> (new_pen: f32, ok: bool) {
	fc := f.colr
	if fc == nil || len(fc.gsub) == 0 { return pen, false }
	cps := make([dynamic]u32, 0, len(w), context.temp_allocator)
	for i := 0; i < len(w); {
		r, n := decode16(w, i)
		append(&cps, u32(r))
		i += n
	}
	gids := make([]u16, len(cps), context.temp_allocator)
	if f.dw->GetGlyphIndices(raw_data(cps), u32(len(cps)), raw_data(gids)) < 0 { return pen, false }
	for g in gids { if g == 0 { return pen, false } }
	out, found := gsub_ligate(fc.gsub, {'c', 'c', 'm', 'p'}, gids, context.temp_allocator)
	if !found || len(out) != 1 { return pen, false }
	gm: DWRITE_GLYPH_METRICS
	if f.dw->GetDesignGlyphMetrics(&out[0], 1, &gm, false) < 0 { return pen, false }
	adv := f32(gm.advanceWidth) * size / f.upem
	append(glyphs, Glyph_Pos{face = face_id, id = out[0], x = pen, advance = adv, cluster = 0})
	append(clusters, Cluster{start = 0, end = bytes[len(w)] - bytes[0], x0 = pen, x1 = pen + adv})
	return pen + adv, true
}

@(private)
has_tag_chars :: proc(w: []u16) -> bool {
	for u in w { if u == TAG_HIGH_SURROGATE { return true } }
	return false
}