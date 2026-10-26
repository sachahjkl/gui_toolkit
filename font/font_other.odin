#+build !windows
package font

import "base:runtime"
import "core:os"
import "core:strings"

// The platform part of the package off Windows. Faces come from files and memory, opened by the text backend itself
// (the native one: Fontations). The system's fonts come from the platform's font service: fontconfig on Linux
// (font_system_linux.odin), CoreText on macOS (font_system_darwin.odin), none elsewhere (system_other.odin): each gives
// a font file for a family / weight / style, the file of a font that has a character (the fallback) and the families.
// No bitmap rasterizer: text is drawn by Slug from the outlines.

@(private)
Platform_Face :: struct {
	data:    []byte,   // the face's bytes (memory fonts)
	owned:   bool,     // data is the package's (heap): freed with the face
	path:    string,   // a font file (heap)
	index:   u32,
	weight:  int,      // nominal weight and style: the base of the fallback
	style:   Font_Style,
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
	f.data, f.path = nil, ""
}

// A face of a font file (TrueType, OpenType, collections: `index` picks the face), opened by the backend.
load_from_file :: proc(s: ^State, path: string, index := 0) -> (id: Font_Id, ok: bool) {
	return load_file_face(s, path, index, "", 400, .Normal)
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
	weight := 400, style := Font_Style.Normal) -> (id: Font_Id, ok: bool) {
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
load_system :: proc(s: ^State, family: string, weight := 400, style := Font_Style.Normal, stretch := 5) -> (id: Font_Id, ok: bool) {
	if family == "" { return 0, false }
	req := strings.concatenate({"sysreq:", strings.to_lower(family, context.temp_allocator), "|", itoa(weight), "|", itoa(int(style)), "|", itoa(stretch)}, context.temp_allocator)
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
	base := face_ptr(s, first)
	family := base != nil ? from_wide(base.family, context.temp_allocator) : ""
	weight := base != nil && base.weight > 0 ? base.weight : 400
	style := base != nil ? base.style : Font_Style.Normal
	i := a
	for i < b {
		r, n := decode16(w, i)
		if faces[i] == 0 {
			key := strings.concatenate({"fb:", strings.to_lower(family, context.temp_allocator), "|", itoa(weight), "|", itoa(int(style)), "|", itoa(int(r))}, context.temp_allocator)
			id, known := find_key(s, key)
			if !known {
				if path, index, ok := sys_find_for_char(family, weight, style, r); ok {
					id, _ = load_from_file(s, path, index)
					if f := face_ptr(s, id); f == nil || !face_has(s, f, r) { id = 0 }
				}
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
	nid := publish_face(s, key, nf, from_wide(f.family, context.temp_allocator))
	return nid != 0 ? nid : id
}

// TODO: the axes and instances of variable faces through the native backend.
axes :: proc(s: ^State, id: Font_Id, allocator := context.allocator) -> []Axis { return nil }

with_variations :: proc(s: ^State, id: Font_Id, values: []Axis_Value) -> Font_Id { return id }

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
	src = {path = f.path, data = f.data, index = f.index}
	return src, f.path != "" || len(f.data) > 0
}

@(private) platform_system_face :: proc(f: ^Font) -> bool { return false }

// COLR tables of a face for the interpreter (colr_glyph.odin reads them through DirectWrite): none here yet.
@(private) Face_Colr :: struct {}
@(private) face_colr_close :: proc(f: ^Font) {}

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

// Color glyphs are drawn by the COLR interpreter only where there is no Direct2D: none here yet.
@(private)
platform_color_glyph :: proc(s: ^State, f: ^Font, gid: u16, size: f32) -> bool { return false }

// No bitmap rasterizer here: text is drawn by Slug from the backend's outlines.
@(private)
rasterize :: proc(s: ^State, face: Font_Id, gid: u16, size: f32, x: f32, fg: [3]u8, probe_fg: bool, key: u64) -> (Glyph_Image, bool) {
	return Glyph_Image{page = -1}, false
}
