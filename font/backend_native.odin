package font

// The native backend (-define:FONT_BACKEND=native): Fontations reads the faces, HarfRust shapes, ICU4X breaks lines
// and resolves bidi, in the static library of native/text (tools/build_text.ps1 builds build/text/gt_text.lib). Faces
// still come from the platform (native_source_*.odin says where their bytes are); the platform also keeps the system
// fallback. See docs/font-backend.md.

when NATIVE_TEXT {

when ODIN_OS == .Windows {
	foreign import gt_text {
		"../build/text/gt_text.lib",
		"system:ntdll.lib",
		"system:userenv.lib",
		"system:ws2_32.lib",
		"system:bcrypt.lib",
		"system:advapi32.lib",
		"system:kernel32.lib",
		"system:dbghelp.lib",
	}
} else {
	// TODO(linux, macos): tools/build_text builds the .lib on Windows only; elsewhere `cargo build --release` in
	// native/text gives libgt_text.a.
	foreign import gt_text {
		"../build/text/libgt_text.a",
		"system:dl",
		"system:pthread",
		"system:m",
	}
}

@(private) NATIVE_API :: 1

@(private) Gt_Face :: struct {}

@(private)
Gt_Glyph :: struct {
	id, cluster:          u32,
	x_advance, y_advance: f32,
	x_offset, y_offset:   f32,
}

@(private)
Gt_Metrics :: struct {
	upem, ascent, descent, line_gap, cap_height, x_height: i32,
	underline_position, underline_thickness, strike_position, strike_thickness: i32,
	hhea_ascent, hhea_descent, hhea_line_gap, typo_ascent, typo_descent, typo_line_gap, win_ascent, win_descent: i32,
	use_typo_metrics, num_glyphs: i32,
}

@(private)
Gt_Glyph_Box :: struct {
	advance, x_min, y_min, x_max, y_max: f32,
	empty: i32,
}

@(private)
Gt_Path_El :: struct {
	verb: u32,
	p:    [3][2]f32,
}

@(private)
Gt_Script_Run :: struct {
	start, end: u32,
	tag:        [4]u8,
}

@(private)
Gt_Axis :: struct {
	tag:   [4]u8,
	value: f32,
}

#assert(size_of(Gt_Axis) == 8)
#assert(size_of(Feature) == 8)   // passed as the library's GtFeature

@(default_calling_convention = "c", private)
foreign gt_text {
	gt_text_version     :: proc() -> u32 ---
	gt_face_open_memory :: proc(data: [^]u8, len: uint, index: u32, axes: [^]Gt_Axis, n_axes: uint) -> ^Gt_Face ---
	gt_face_open_file   :: proc(path: [^]u8, path_len: uint, index: u32, axes: [^]Gt_Axis, n_axes: uint) -> ^Gt_Face ---
	gt_face_close       :: proc(face: ^Gt_Face) ---
	gt_face_metrics     :: proc(face: ^Gt_Face, out: ^Gt_Metrics) -> i32 ---
	gt_face_glyphs      :: proc(face: ^Gt_Face, cps: [^]u32, count: uint, out: [^]u32) -> i32 ---
	gt_face_coverage    :: proc(face: ^Gt_Face, out: [^][2]u32, cap: uint) -> uint ---
	gt_glyph_box        :: proc(face: ^Gt_Face, gid: u32, out: ^Gt_Glyph_Box) -> i32 ---
	gt_glyph_outline    :: proc(face: ^Gt_Face, gid: u32, out: [^]Gt_Path_El, cap: uint) -> int ---
	gt_face_table       :: proc(face: ^Gt_Face, tag: ^[4]u8, data: ^[^]u8, len: ^uint) -> i32 ---
	gt_color_glyph      :: proc(face: ^Gt_Face, gid: u32) -> i32 ---
	gt_palette          :: proc(face: ^Gt_Face, palette: u32, out: [^][4]u8, cap: uint) -> uint ---
	gt_shape            :: proc(face: ^Gt_Face, text: [^]u8, text_len: uint, script: ^[4]u8, lang: [^]u8, lang_len: uint, rtl: i32,
	                            feats: [^]Feature, n_feats: uint, out: [^]Gt_Glyph, cap: uint) -> int ---
	gt_scripts          :: proc(text: [^]u8, text_len: uint, out: [^]Gt_Script_Run, cap: uint) -> uint ---
	gt_bidi_levels      :: proc(text: [^]u8, text_len: uint, base: u8, levels: [^]u8) -> i32 ---
	gt_line_breaks      :: proc(text: [^]u8, text_len: uint, out: [^]u32, cap: uint) -> uint ---
}

@(private)
native_backend := Text_Backend{
	name         = "native",
	start        = native_start,
	stop         = proc(s: ^State) {},
	face_open    = native_face_open,
	face_close   = native_face_release,
	has_glyph    = native_has_glyph,
	face_metrics = native_face_metrics,
	glyph_box    = native_glyph_box,
	scripts      = native_scripts,
	shape        = native_shape,
	bidi         = native_bidi,
	line_breaks  = native_line_breaks,
	outline      = native_outline_provider,
}

@(private)
native_start :: proc(s: ^State) -> bool {
	if gt_text_version() != NATIVE_API { return false }
	s.latin, s.latin_ok = Script_Item{tag = {'L', 'a', 't', 'n'}}, true
	return true
}

@(private)
native_face :: #force_inline proc "contextless" (f: ^Font) -> ^Gt_Face { return (^Gt_Face)(f.native) }

@(private)
native_face_open :: proc(s: ^State, f: ^Font) -> bool {
	src, ok := native_source(f)
	if !ok { return false }
	axes := transmute([]Gt_Axis)src.axes
	face: ^Gt_Face
	if src.path != "" {
		face = gt_face_open_file(raw_data(src.path), uint(len(src.path)), src.index, raw_data(axes), uint(len(axes)))
	} else {
		face = gt_face_open_memory(raw_data(src.data), uint(len(src.data)), src.index, raw_data(axes), uint(len(axes)))
	}
	f.native = face
	return face != nil
}

// Frees the native face of a font (release_font calls it whatever the backend: faces of a dwrite State have none).
@(private)
native_face_release :: proc(f: ^Font) {
	if f.native != nil { gt_face_close(native_face(f)) }
	f.native = nil
}

@(private)
native_has_glyph :: proc(s: ^State, f: ^Font, r: rune) -> bool {
	if f.native == nil { return false }
	cp := [1]u32{u32(r)}
	gid := [1]u32{}
	return gt_face_glyphs(native_face(f), &cp[0], 1, &gid[0]) != 0 && gid[0] != 0
}

@(private)
native_face_metrics :: proc(s: ^State, f: ^Font) -> Face_Metrics {
	m: Gt_Metrics
	if f.native == nil || gt_face_metrics(native_face(f), &m) == 0 { return {} }
	return {
		upem = m.upem, ascent = m.ascent, descent = m.descent, line_gap = m.line_gap, cap_height = m.cap_height, x_height = m.x_height,
		underline_position = m.underline_position, underline_thickness = m.underline_thickness,
		strike_position = m.strike_position, strike_thickness = m.strike_thickness,
	}
}

@(private)
native_glyph_box :: proc(s: ^State, f: ^Font, gid: u16) -> (Glyph_Box, bool) {
	b: Gt_Glyph_Box
	if f.native == nil || gt_glyph_box(native_face(f), u32(gid), &b) == 0 { return {}, false }
	return {advance = b.advance, x_min = b.x_min, y_min = b.y_min, x_max = b.x_max, y_max = b.y_max, empty = b.empty != 0}, true
}

@(private)
native_scripts :: proc(s: ^State, text: string, w: []u16, bytes: []i32, rtl: bool, out: ^[dynamic]Script_Item) -> bool {
	if len(text) == 0 { return false }
	runs := make([]Gt_Script_Run, 8, context.temp_allocator)
	n := gt_scripts(raw_data(text), uint(len(text)), raw_data(runs), uint(len(runs)))
	if int(n) > len(runs) {
		runs = make([]Gt_Script_Run, n, context.temp_allocator)
		n = gt_scripts(raw_data(text), uint(len(text)), raw_data(runs), uint(len(runs)))
	}
	if n == 0 { return false }
	// byte offsets (from the start of `text`) to UTF-16 units: `bytes` is relative to the word, text[0] is bytes[0]
	unit_of := make([]u32, len(text) + 1, context.temp_allocator)
	for k := len(w); k >= 0; k -= 1 {
		b := int(bytes[k] - bytes[0])
		if b >= 0 && b <= len(text) { unit_of[b] = u32(k) }
	}
	for r in runs[:n] {
		append(out, Script_Item{start = unit_of[min(int(r.start), len(text))], end = unit_of[min(int(r.end), len(text))], tag = r.tag})
	}
	return true
}

@(private)
native_bidi :: proc(s: ^State, text: string, rtl: bool, levels: []u8) -> bool {
	return gt_bidi_levels(raw_data(text), uint(len(text)), rtl ? 1 : 0, raw_data(levels)) != 0
}

@(private)
native_line_breaks :: proc(s: ^State, text: string, out: ^[dynamic]Break_Opportunity) -> bool {
	buf := make([]u32, len(text) / 2 + 8, context.temp_allocator)
	n := gt_line_breaks(raw_data(text), uint(len(text)), raw_data(buf), uint(len(buf)))
	if int(n) > len(buf) {
		buf = make([]u32, n, context.temp_allocator)
		n = gt_line_breaks(raw_data(text), uint(len(text)), raw_data(buf), uint(len(buf)))
	}
	for v in buf[:n] { append(out, Break_Opportunity{int(v & 0x7FFF_FFFF), v & 0x8000_0000 != 0}) }
	return true
}

// HarfRust's glyphs of the request, laid out as dwrite_shape does: glyphs left to right from `pen`, clusters (the
// glyphs sharing a cluster value: a character, a ligature, a grapheme) in logical order.
@(private)
native_shape :: proc(s: ^State, req: ^Shape_Request, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> f32 {
	f := req.face
	if f == nil || f.native == nil || len(req.text) == 0 { return pen }
	tag := req.script.tag
	cap := len(req.text) + 16
	out := make([]Gt_Glyph, cap, context.temp_allocator)
	call :: proc(f: ^Font, req: ^Shape_Request, tag: ^[4]u8, out: []Gt_Glyph) -> int {
		return gt_shape(native_face(f), raw_data(req.text), uint(len(req.text)), tag, nil, 0, req.rtl ? 1 : 0,
			raw_data(req.features), uint(len(req.features)), raw_data(out), uint(len(out)))
	}
	n := call(f, req, &tag, out)
	if n > cap {
		out = make([]Gt_Glyph, n, context.temp_allocator)
		n = call(f, req, &tag, out)
	}
	if n <= 0 { return pen }
	out = out[:n]
	k := req.size / f.upem
	off := req.bytes[0]
	text_len := u32(len(req.text))
	// the end of each cluster value: the next larger value, or the end of the text
	values := make([]u32, n, context.temp_allocator)
	for g, i in out { values[i] = g.cluster }
	sorted := make([]u32, n, context.temp_allocator)
	copy(sorted, values)
	for i in 1 ..< n {   // insertion sort: nearly sorted (reversed for right to left)
		v := sorted[i]
		j := i - 1
		for j >= 0 && sorted[j] > v { sorted[j + 1] = sorted[j]; j -= 1 }
		sorted[j + 1] = v
	}
	end_of :: proc(sorted: []u32, v, text_len: u32) -> u32 {
		for x in sorted { if x > v { return x } }
		return text_len
	}
	Ext :: struct { start, end: u32, x0, x1: f32 }
	exts := make([dynamic]Ext, 0, n, context.temp_allocator)
	x := pen
	for g in out {
		gx := x + g.x_offset * k
		adv := g.x_advance * k
		append(glyphs, Glyph_Pos{face = req.face_id, id = u16(g.id), rtl = req.rtl, x = gx, y = -g.y_offset * k, advance = adv, cluster = i32(g.cluster) + off})
		found := false
		for &e in exts {
			if e.start == g.cluster { e.x0 = min(e.x0, x); e.x1 = max(e.x1, x + adv); found = true; break }
		}
		if !found { append(&exts, Ext{start = g.cluster, end = end_of(sorted, g.cluster, text_len), x0 = x, x1 = x + adv}) }
		x += adv
	}
	// logical order
	for i in 1 ..< len(exts) {
		v := exts[i]
		j := i - 1
		for j >= 0 && exts[j].start > v.start { exts[j + 1] = exts[j]; j -= 1 }
		exts[j + 1] = v
	}
	for e in exts {
		append(clusters, Cluster{start = i32(e.start) + off, end = i32(e.end) + off, x0 = e.x0, x1 = e.x1, rtl = req.rtl})
	}
	return x
}

// Outline_Provider of the native backend: the face's outline in em units, y up.
native_outline_provider :: proc(s: ^State, face: Font_Id, gid: u16, tolerance: f32, out: ^Outline) -> bool {
	f := face_ptr(s, face)
	if f == nil || f.native == nil { return false }
	buf := make([]Gt_Path_El, 64, context.temp_allocator)
	n := gt_glyph_outline(native_face(f), u32(gid), raw_data(buf), uint(len(buf)))
	if n > len(buf) {
		buf = make([]Gt_Path_El, n, context.temp_allocator)
		n = gt_glyph_outline(native_face(f), u32(gid), raw_data(buf), uint(len(buf)))
	}
	if n < 0 { return false }
	sc := 1 / f.upem
	start, cur: [2]f32
	open := false
	for e in buf[:n] {
		switch e.verb {
		case 0:
			if open { outline_end(out, start, cur) }
			start = e.p[0] * sc
			cur = start
			open = true
		case 1:
			p := e.p[0] * sc
			outline_line(out, cur, p)
			cur = p
		case 2:
			c, p := e.p[0] * sc, e.p[1] * sc
			outline_quad(out, cur, c, p)
			cur = p
		case 3:
			c1, c2, p := e.p[0] * sc, e.p[1] * sc, e.p[2] * sc
			outline_cubic(out, cur, c1, c2, p, tolerance)
			cur = p
		case 4:
			if open { outline_end(out, start, cur) }
			open = false
		}
	}
	if open { outline_end(out, start, cur) }
	outline_bounds(out)
	return true
}

// The raw bytes of a table of a face the native backend opened (nil: none, or another backend).
native_table :: proc(s: ^State, face: Font_Id, tag: [4]u8) -> []byte {
	f := face_ptr(s, face)
	if f == nil || f.native == nil { return nil }
	t := tag
	data: [^]u8
	n: uint
	if gt_face_table(native_face(f), &t, &data, &n) == 0 { return nil }
	return data[:n]
}

// Code point coverage of a face (inclusive ranges) from the native backend.
native_coverage :: proc(s: ^State, face: Font_Id, allocator := context.allocator) -> []Range {
	f := face_ptr(s, face)
	if f == nil || f.native == nil { return nil }
	n := gt_face_coverage(native_face(f), nil, 0)
	raw := make([][2]u32, n, context.temp_allocator)
	n = gt_face_coverage(native_face(f), raw_data(raw), n)
	out := make([]Range, len(raw), allocator)
	for r, i in raw { out[i] = {rune(r[0]), rune(r[1])} }
	return out
}

}
