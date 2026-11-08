#+build !windows
package font

import "base:runtime"
import "core:os"
import "core:strings"
import "../ascii"

// The platform part of the package off Windows. Faces come from files and memory, opened by the text backend itself
// (the native one: Fontations). The system's fonts come from the platform's font service: fontconfig on Linux
// (font_system_linux.odin), CoreText on macOS (font_system_darwin.odin), none elsewhere (system_other.odin): each gives
// a font file for a family / weight / style, the file of a font that has a character (the fallback) and the families.
// No bitmap rasterizer: text is drawn by Slug from the outlines.

// What the system does with text. No service says the stripes of a screen everywhere: the usual order on Linux, where text
// has them; macOS smooths in grey.
system_subpixel_text :: proc() -> Subpixel_Text { return ODIN_OS == .Linux ? .Rgb : .Off }

@(private)
Platform_Face :: struct {
	data:    []byte,   // the face's bytes (memory fonts)
	owned:   bool,     // data is the package's (heap): freed with the face
	path:    string,   // a font file (heap)
	index:   u32,
	weight:  int,      // nominal weight and style: the base of the fallback
	style:   Font_Style,
	variations: []Axis_Value,   // the instance of a variable face (with_variations): the native backend opens it there (heap)
}

@(private)
Platform_State :: struct {}

@(private)
other_system := System_Fonts{
	name     = SYSTEM_FONT_SERVICE,
	fallback = other_fallback,
	families = proc(s: ^State, allocator: runtime.Allocator) -> []string { return sys_families(allocator) },
}

@(private) platform_init :: proc(s: ^State) -> bool { s.system_fonts = &other_system; return true }
@(private) platform_stop :: proc(s: ^State) { colr_thread_done() }
@(private) platform_destroy :: proc(s: ^State) {}
@(private) platform_forget_face :: proc(s: ^State, id: Font_Id) {}

@(private)
platform_release_face :: proc(f: ^Font) {
	if f.owned { delete(f.data, runtime.heap_allocator()) }
	delete(f.path, runtime.heap_allocator())
	delete(f.variations, runtime.heap_allocator())
	f.data, f.path, f.variations = nil, "", nil
}

// A face of a font file (TrueType, OpenType, collections: `index` picks the face), opened by the backend.
load_from_file :: proc(s: ^State, path: string, index := 0) -> (id: Font_Id, ok: bool) {
	return load_file_face(s, path, index, "", FONT_WEIGHT_NORMAL, .Normal)
}

// A face of a file with what is known of it (a system font: its family, weight and style, the base of the fallback).
@(private)
load_file_face :: proc(s: ^State, path: string, index: int, family: string, weight: int, style: Font_Style) -> (id: Font_Id, ok: bool) {
	key := strings.concatenate({"file:", path, "#", itoa(index)}, context.temp_allocator)
	if id, ok = find_key(s, key); ok { return id, id != 0 }
	if !os.exists(path) { return 0, false }
	f := Font{kind = .Face}
	f.path = strings.clone(path, runtime.heap_allocator())
	f.index = u32(max(index, 0))
	f.weight, f.style = weight, style
	id = publish_face(s, key, f, family)
	return id, id != 0
}

// A face from memory (see the Windows version: the family, weight and style are what CSS knows of it; simulated bold
// and slant are kept but not drawn by the native backend). Takes ownership of `data` when `owned`.
load_memory :: proc(s: ^State, data: []byte, owned: bool, index := 0, simulations: Simulations = {}, family := "",
	weight := FONT_WEIGHT_NORMAL, style := Font_Style.Normal) -> (id: Font_Id, ok: bool) {
	if len(data) == 0 {
		if owned { delete(data) }
		return 0, false
	}
	f := Font{kind = .Face}
	f.data, f.owned, f.index = data, owned, u32(max(index, 0))
	f.sims, f.weight, f.style = simulations, weight, style
	if owned {
		f.data = make([]byte, len(data), runtime.heap_allocator())
		copy(f.data, data)
		delete(data)
	}
	id = publish_face(s, "", f, family)
	return id, id != 0
}

// A system font nearest to weight / style / stretch (1..9, 5 = normal), from the platform's font service.
load_system :: proc(s: ^State, family: string, weight := FONT_WEIGHT_NORMAL, style := Font_Style.Normal, stretch := FONT_STRETCH_NORMAL) -> (id: Font_Id, ok: bool) {
	if family == "" { return 0, false }
	req := strings.concatenate({"sysreq:", ascii.lower(family), "|", itoa(weight), "|", itoa(int(style)), "|", itoa(stretch)}, context.temp_allocator)
	if id, ok = find_key(s, req); ok { return id, id != 0 }
	path, index, found := sys_find(family, weight, style, stretch)
	if !found { remember_key(s, req, 0); return 0, false }
	id, ok = load_file_face(s, path, index, family, weight, style)
	remember_key(s, req, id)
	return id, ok
}

has_system_family :: proc(s: ^State, family: string) -> bool { return family != "" && sys_has_family(family) }

// The fallback: for each character of w[a:b] no face has, the font the service picks for it near the first face's
// family, weight and style (remembered per character and base family).
@(private)
other_fallback :: proc(s: ^State, first: Font_Id, w: []u16, a, b: int, faces: []Font_Id) {
	bf := face_ptr(s, first)
	family := bf != nil ? from_wide(bf.family, context.temp_allocator) : ""
	weight := bf != nil && bf.weight > 0 ? bf.weight : FONT_WEIGHT_NORMAL
	style := bf != nil ? bf.style : Font_Style.Normal
	i := a
	for i < b {
		r, n := decode16(w, i)
		if faces[i] == 0 {
			next: rune
			if i + n < b { next, _ = decode16(w, i + n) }
			emoji := emoji_wanted(r, next)
			key := strings.concatenate({emoji ? "fbe:" : "fb:", ascii.lower(family), "|", itoa(weight), "|", itoa(int(style)), "|", itoa(int(r))}, context.temp_allocator)
			id, known := find_key(s, key)
			if !known {
				try :: proc(s: ^State, family: string, weight: int, style: Font_Style, r: rune, emoji: bool) -> (id: Font_Id) {
					if path, index, ok := sys_find_for_char(family, weight, style, r, emoji); ok {
						id, _ = load_from_file(s, path, index)
						if f := face_ptr(s, id); f == nil || !face_has(s, f, r) { id = 0 }
					}
					return
				}
				id = emoji ? try(s, family, weight, style, r, true) : 0
				if id == 0 { id = try(s, family, weight, style, r, false) }
				remember_key(s, key, id)
			}
			if id != 0 { for k in 0 ..< n { faces[i + k] = id } }
		}
		i += n
	}
}

// The same face with simulated bold and / or slant (simulate.odin: the native backend draws and measures them).
with_simulations :: proc(s: ^State, id: Font_Id, bold, oblique: bool) -> Font_Id {
	f := face_ptr(s, id)
	if f == nil { return id }
	want := f.sims
	if bold { want += {.Bold} }
	if oblique { want += {.Oblique} }
	if want == f.sims { return id }
	key := strings.concatenate({"sim:", itoa(int(id)), "|", itoa(int(transmute(u32)want))}, context.temp_allocator)
	if nid, ok := find_key(s, key); ok { return nid }
	nf := Font{kind = .Face}
	nf.index, nf.sims = f.index, want
	if f.path != "" { nf.path = strings.clone(f.path, runtime.heap_allocator()) }
	if len(f.data) > 0 {   // a copy: the faces are unloaded independently
		nf.data = make([]byte, len(f.data), runtime.heap_allocator())
		copy(nf.data, f.data)
		nf.owned = true
	}
	if len(f.variations) > 0 {   // (a simulation of an instance keeps the instance)
		nf.variations = make([]Axis_Value, len(f.variations), runtime.heap_allocator())
		copy(nf.variations, f.variations)
	}
	nid := publish_face(s, key, nf, from_wide(f.family, context.temp_allocator))
	return nid != 0 ? nid : id
}

// The axes of a variable face, from its 'fvar' table (OpenType: a header, then one 20-byte record per axis: tag, minimum,
// default and maximum as 16.16 fixed). Empty for a static face.
axes :: proc(s: ^State, id: Font_Id, allocator := context.allocator) -> []Axis {
	f := face_ptr(s, id)
	if f == nil { return nil }
	data, ctx := face_table_read(f, "fvar")
	defer face_table_release(f, ctx)
	return fvar_axes(data, allocator)
}

@(private)
fvar_axes :: proc(t: []u8, allocator := context.allocator) -> []Axis {
	be16 :: proc(b: []u8, at: int) -> int { return int(b[at]) << 8 | int(b[at + 1]) }
	fixed :: proc(b: []u8, at: int) -> f32 { return f32(i32(u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]))) / 65536 }
	if len(t) < 16 || be16(t, 0) != 1 { return nil }
	first, count, size := be16(t, 4), be16(t, 8), be16(t, 10)
	if count == 0 || size < 20 || first + count * size > len(t) { return nil }
	out := make([]Axis, count, allocator)
	for i in 0 ..< count {
		at := first + i * size
		out[i] = {tag = {t[at], t[at + 1], t[at + 2], t[at + 3]}, min = fixed(t, at + 4), default = fixed(t, at + 8), max = fixed(t, at + 12)}
	}
	return out
}

// An instance of a variable face at the given axis values (CSS font-variation-settings, and font-weight / font-stretch /
// font-style on variable fonts): a face of its own, opened by the native backend at that location. Axes the face lacks
// are ignored by the backend. Returns `id` for a static face.
with_variations :: proc(s: ^State, id: Font_Id, values: []Axis_Value) -> Font_Id {
	f := face_ptr(s, id)
	if f == nil || len(values) == 0 || len(axes(s, id, context.temp_allocator)) == 0 { return id }
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "var:")
	strings.write_int(&sb, int(id))
	for v in values {
		tag := v.tag
		strings.write_byte(&sb, '|')
		strings.write_string(&sb, string(tag[:]))
		strings.write_byte(&sb, '=')
		strings.write_int(&sb, int(v.value * 1000))
	}
	key := strings.to_string(sb)
	if nid, ok := find_key(s, key); ok { return nid }
	nf := Font{kind = .Face}
	nf.index, nf.sims, nf.weight, nf.style = f.index, f.sims, f.weight, f.style
	if f.path != "" { nf.path = strings.clone(f.path, runtime.heap_allocator()) }
	if len(f.data) > 0 {   // a copy: the faces are unloaded independently
		nf.data = make([]byte, len(f.data), runtime.heap_allocator())
		copy(nf.data, f.data)
		nf.owned = true
	}
	nf.variations = make([]Axis_Value, len(values), runtime.heap_allocator())
	copy(nf.variations, values)
	nid := publish_face(s, key, nf, from_wide(f.family, context.temp_allocator))
	return nid != 0 ? nid : id
}

// Where the native backend reads a face: its bytes or its file.
@(private)
Native_Source :: struct {
	path:      string,
	data:      []byte,
	index:     u32,
	axes:      []Axis_Value,
}

@(private)
native_source :: proc(f: ^Font) -> (src: Native_Source, ok: bool) {
	if f == nil { return }
	src = {path = f.path, data = f.data, index = f.index, axes = f.variations}
	return src, f.path != "" || len(f.data) > 0
}

@(private) platform_system_face :: proc(f: ^Font) -> bool { return false }

// The tables of a face from the native backend: they live as long as the face.
@(private)
face_table_read :: proc(f: ^Font, tag: string) -> (data: []u8, ctx: rawptr) {
	when NATIVE_TEXT { return native_font_table(f, {tag[0], tag[1], tag[2], tag[3]}), nil } else { return nil, nil }
}
@(private) face_table_release :: proc(f: ^Font, ctx: rawptr) {}

// A face just opened: its color tables, for the COLR interpreter and the bitmap glyphs.
@(private)
platform_face_opened :: proc(s: ^State, f: ^Font) {
	fc, _ := face_colr_open(f)
	f.colr = fc
	f.color = fc != nil
}

// The color glyph thread is Windows' (color_async.odin): nothing is queued here.
@(private)
Color_Job :: struct {
	key:      u64,
	fg:       [3]u8,
	known_fg: bool,
	face:     Font_Id,
	gid:      u16,
	size:     f32,
	x:        f32,
	settings: u64,
}
@(private) color_enqueue :: proc(s: ^State, j: Color_Job) -> bool { return false }

// Nothing to make ahead: the COLR interpreter and the CBDT bitmaps need no device (color.odin has Windows' Direct2D).
color_prepare :: proc(s: ^State) {}

// Off Windows every color glyph is the COLR interpreter's or a bitmap of the CBDT table.
@(private)
platform_color_glyph :: proc(s: ^State, f: ^Font, gid: u16, size: f32) -> bool {
	return s.settings.color_glyphs && f.colr != nil && (colr_draws(s, f, gid) || cbdt_has(f.colr, gid))
}

// Only color glyphs here: other text is drawn by Slug from the backend's outlines.
@(private)
rasterize :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, x: f32, fg: [3]u8, probe_fg: bool, key: u64) -> (Glyph_Image, bool) {
	f := face_ptr(s, face)
	if f != nil && f.color && s.settings.color_glyphs && size > 0 {
		if colr_draws(s, f, gid) {
			if g, uses_fg, ok := rasterize_colr(s, face, f, gid, size, x, fg, key); ok { return g, uses_fg }
		} else if bm, ok := cbdt_draw(f.colr, gid, size); ok {
			return colr_put(s, bm), false
		}
	}
	return Glyph_Image{page = -1}, false
}
