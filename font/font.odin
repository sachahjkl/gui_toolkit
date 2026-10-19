// Package font: TrueType loading, glyph rasterization (stb_truetype) and a shelf-packed coverage atlas.
//
// The package knows nothing about the GPU: freshly rasterized glyphs are queued in `pending` and the draw layer
// uploads them to the atlas texture before submitting a frame. Glyphs are cached per (font, pixel size, codepoint).
package font

import "core:math"
import "core:os"
import stbtt "vendor:stb/truetype"

ATLAS_SIZE :: 2048

Font_Id :: distinct int

Font :: struct {
	info:  stbtt.fontinfo,
	data:  []byte,
	owned: bool,   // false for data embedded in the exe (load_embedded)
}

Metrics :: struct {
	ascent:      f32,   // pixels above the baseline (positive)
	descent:     f32,   // pixels below the baseline (positive)
	line_height: f32,
}

Glyph :: struct {
	uv:      [4]f32,    // atlas rect in texels: x0 y0 x1 y1
	offset:  [2]f32,    // top-left of the bitmap relative to the pen position on the baseline
	size:    [2]f32,
	advance: f32,
}

Glyph_Key :: struct {
	font: Font_Id,
	size: u16,
	r:    rune,
}

Upload :: struct {
	x, y, w, h: int,
	offset:     int,   // into `pending_pixels`
}

State :: struct {
	fonts:          [dynamic]Font,
	glyphs:         map[Glyph_Key]Glyph,
	shelf_x:        int,
	shelf_y:        int,
	shelf_h:        int,
	pending:        [dynamic]Upload,
	pending_pixels: [dynamic]u8,
	generation:     int,   // bumps when the atlas was full and got reset
}

init :: proc(s: ^State) {
	s.glyphs = make(map[Glyph_Key]Glyph)
	append(&s.fonts, Font{})   // slot 0 = invalid
}

destroy :: proc(s: ^State) {
	for f in s.fonts { if f.owned { delete(f.data) } }
	delete(s.fonts)
	delete(s.glyphs)
	delete(s.pending)
	delete(s.pending_pixels)
}

load_from_file :: proc(s: ^State, path: string) -> (id: Font_Id, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return 0, false }
	return load_from_memory(s, data)
}

// Takes ownership of `data`.
load_from_memory :: proc(s: ^State, data: []byte) -> (id: Font_Id, ok: bool) {
	f := Font{data = data, owned = true}
	if !stbtt.InitFont(&f.info, raw_data(data), stbtt.GetFontOffsetForIndex(raw_data(data), 0)) {
		delete(data)
		return 0, false
	}
	append(&s.fonts, f)
	return Font_Id(len(s.fonts) - 1), true
}

// Fallback fonts compiled into every exe that loads them (Odin's #load: no file next to the exe). Used when a system
// font is missing, e.g. under Wine. Roboto: Apache 2.0, Inconsolata: SIL OFL 1.1 (licences in font/data).
FALLBACK_UI_DATA   :: #load("data/Roboto-Regular.ttf")
FALLBACK_MONO_DATA :: #load("data/Inconsolata-Regular.ttf")

// Loads a system font file, or `fallback` (embedded data) when the file is missing or unreadable.
load_system_or_embedded :: proc(s: ^State, path: string, fallback: []byte) -> (id: Font_Id, ok: bool, from_system: bool) {
	if path != "" {
		if id, ok = load_from_file(s, path); ok { return id, true, true }
	}
	id, ok = load_embedded(s, fallback)
	return id, ok, false
}

// A font compiled into the exe (`#load("x.ttf")`): read in place, never freed.
load_embedded :: proc(s: ^State, data: []byte) -> (id: Font_Id, ok: bool) {
	f := Font{data = data}
	if !stbtt.InitFont(&f.info, raw_data(data), stbtt.GetFontOffsetForIndex(raw_data(data), 0)) { return 0, false }
	append(&s.fonts, f)
	return Font_Id(len(s.fonts) - 1), true
}

@(private)
scale_for :: proc(f: ^Font, size: f32) -> f32 {
	return stbtt.ScaleForMappingEmToPixels(&f.info, size)
}

metrics :: proc(s: ^State, id: Font_Id, size: f32) -> Metrics {
	f := &s.fonts[int(id)]
	asc, desc, gap: i32
	stbtt.GetFontVMetrics(&f.info, &asc, &desc, &gap)
	sc := scale_for(f, size)
	m := Metrics{ascent = f32(asc) * sc, descent = -f32(desc) * sc}
	m.line_height = math.round(m.ascent + m.descent + f32(gap) * sc)
	return m
}

@(private)
alloc_in_atlas :: proc(s: ^State, w, h: int) -> (x, y: int, ok: bool) {
	pad :: 1
	pw, ph := w + pad, h + pad
	if s.shelf_x + pw > ATLAS_SIZE { s.shelf_x = 0; s.shelf_y += s.shelf_h; s.shelf_h = 0 }
	if s.shelf_y + ph > ATLAS_SIZE { return 0, 0, false }
	x, y = s.shelf_x, s.shelf_y
	s.shelf_x += pw
	s.shelf_h = max(s.shelf_h, ph)
	return x, y, true
}

reset_atlas :: proc(s: ^State) {
	clear(&s.glyphs)
	clear(&s.pending)
	clear(&s.pending_pixels)
	s.shelf_x, s.shelf_y, s.shelf_h = 0, 0, 0
	s.generation += 1
}

glyph :: proc(s: ^State, id: Font_Id, size: f32, r: rune) -> Glyph {
	size_px := u16(clamp(math.round(size), 1, 512))
	key := Glyph_Key{id, size_px, r}
	if g, found := s.glyphs[key]; found { return g }

	f := &s.fonts[int(id)]
	sc := scale_for(f, f32(size_px))
	adv, lsb: i32
	stbtt.GetCodepointHMetrics(&f.info, r, &adv, &lsb)
	g := Glyph{advance = f32(adv) * sc}

	x0, y0, x1, y1: i32
	stbtt.GetCodepointBitmapBox(&f.info, r, sc, sc, &x0, &y0, &x1, &y1)
	w, h := int(x1 - x0), int(y1 - y0)
	if w > 0 && h > 0 {
		ax, ay, ok := alloc_in_atlas(s, w, h)
		if !ok {
			reset_atlas(s)
			ax, ay, ok = alloc_in_atlas(s, w, h)
			if !ok { s.glyphs[key] = g; return g }
		}
		off := len(s.pending_pixels)
		resize(&s.pending_pixels, off + w * h)
		px := s.pending_pixels[off:]
		// raw coverage: the renderer turns it into alpha for its blend space (render.Text_Rendering)
		stbtt.MakeCodepointBitmap(&f.info, raw_data(px), i32(w), i32(h), i32(w), sc, sc, r)
		append(&s.pending, Upload{ax, ay, w, h, off})
		g.uv = {f32(ax), f32(ay), f32(ax + w), f32(ay + h)}
		g.offset = {f32(x0), f32(y0)}
		g.size = {f32(w), f32(h)}
	}
	s.glyphs[key] = g
	return g
}

kern :: proc(s: ^State, id: Font_Id, size: f32, a, b: rune) -> f32 {
	f := &s.fonts[int(id)]
	k := stbtt.GetCodepointKernAdvance(&f.info, a, b)
	return f32(k) * scale_for(f, size)
}

// Width of a single line of text in pixels.
text_width :: proc(s: ^State, id: Font_Id, size: f32, text: string) -> f32 {
	x: f32
	prev: rune
	for r in text {
		if prev != 0 { x += kern(s, id, f32(u16(math.round(size))), prev, r) }
		x += glyph(s, id, size, r).advance
		prev = r
	}
	return x
}

// Byte index of the caret position closest to `x` (pixels from the start of `text`).
index_from_x :: proc(s: ^State, id: Font_Id, size: f32, text: string, x: f32) -> int {
	pen: f32
	prev: rune
	for r, i in text {
		if prev != 0 { pen += kern(s, id, f32(u16(math.round(size))), prev, r) }
		adv := glyph(s, id, size, r).advance
		if x < pen + adv * 0.5 { return i }
		pen += adv
		prev = r
	}
	return len(text)
}

// Pixels from the start of `text` to the byte index (caret x).
x_from_index :: proc(s: ^State, id: Font_Id, size: f32, text: string, index: int) -> f32 {
	return text_width(s, id, size, text[:clamp(index, 0, len(text))])
}
