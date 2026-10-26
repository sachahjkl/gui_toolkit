#+build windows
package font

import "base:runtime"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"

// The platform part of the package on Windows: DirectWrite opens every face (system collection, files, memory) and
// Direct2D draws color glyphs. The text backend (backend.odin) then works on the faces it opened.

@(private)
Platform_Face :: struct {
	dw:       ^IDWriteFontFace,
	dw2:      ^IDWriteFontFace2,     // nil before Windows 8.1
	dw4:      ^IDWriteFontFace4,     // nil before Windows 10 1607
	dw5:      ^IDWriteFontFace5,     // nil before Windows 10 1803
	dw7:      ^IDWriteFontFace7,     // nil before Windows 11 22H2 (COLR v1 paint reader)
	file:     ^IDWriteFontFile,      // files this package made (memory, path)
	memory:   ^Memory_Font,
	dm:       DWRITE_FONT_METRICS,
	weight:   DWRITE_FONT_WEIGHT,
	stretch:  DWRITE_FONT_STRETCH,
	style:    DWRITE_FONT_STYLE,
}

@(private)
Platform_State :: struct {
	factory:      ^IDWriteFactory,
	factory2:     ^IDWriteFactory2,    // system fallback, color glyphs, grayscale analysis
	factory4:     ^IDWriteFactory4,    // color glyph image formats
	factory8:     ^IDWriteFactory8,    // COLR v1 paint trees (Windows 11 22H2)
	system:       ^IDWriteFontCollection,
	fallback:     ^IDWriteFontFallback,
	analyzer:     ^IDWriteTextAnalyzer,
	color_raster: Color_Raster,        // Direct2D drawing of color glyphs (color.odin)
	color_queue:  Color_Queue,         // the color glyph thread (color_async.odin)
}

@(private)
loader_mu: sync.Mutex
@(private)
loader_users: int

// DirectWrite's factory, collection, analyzer and fallback. false: no DirectWrite (every face then fails to load).
@(private)
platform_init :: proc(s: ^State) -> bool {
	f: rawptr
	if DWriteCreateFactory(.SHARED, &IID_IDWriteFactory, &f) < 0 || f == nil { return false }
	s.factory = (^IDWriteFactory)(f)
	s.factory2 = com_query(s.factory, &IID_IDWriteFactory2, IDWriteFactory2)
	s.factory4 = com_query(s.factory, &IID_IDWriteFactory4, IDWriteFactory4)
	s.factory8 = com_query(s.factory, &IID_IDWriteFactory8, IDWriteFactory8)
	if s.factory->GetSystemFontCollection(&s.system, false) < 0 { s.system = nil }
	if s.factory->CreateTextAnalyzer(&s.analyzer) < 0 { s.analyzer = nil }
	if s.factory2 != nil {
		if s.factory2->GetSystemFontFallback(&s.fallback) < 0 { s.fallback = nil }
	}
	sync.mutex_lock(&loader_mu)
	if loader_users == 0 { s.factory->RegisterFontFileLoader(&memory_loader.iface) }
	loader_users += 1
	sync.mutex_unlock(&loader_mu)
	s.system_fonts = &dwrite_system
	return true
}

// What must stop before the faces are released: the color glyph thread, Direct2D.
@(private)
platform_stop :: proc(s: ^State) {
	color_queue_destroy(s)
	colr_thread_done()
	color_raster_destroy(&s.color_raster)
}

@(private)
platform_destroy :: proc(s: ^State) {
	if s.factory != nil {
		sync.mutex_lock(&loader_mu)
		loader_users -= 1
		if loader_users == 0 { s.factory->UnregisterFontFileLoader(&memory_loader.iface) }
		sync.mutex_unlock(&loader_mu)
	}
	com_release(s.fallback)
	com_release(s.analyzer)
	com_release(s.system)
	com_release(s.factory8)
	com_release(s.factory4)
	com_release(s.factory2)
	com_release(s.factory)
}

@(private)
platform_release_face :: proc(f: ^Font) {
	com_release(f.dw7); com_release(f.dw5); com_release(f.dw4); com_release(f.dw2); com_release(f.dw)
	com_release(f.file)
	if f.memory != nil { memory_font_release(f.memory) }
}

// Whether a face is one of the system's (not a file or bytes this package was given).
@(private)
platform_system_face :: proc(f: ^Font) -> bool { return f.file == nil && f.memory == nil }

// What unload forgets of a face besides the atlas: its color glyphs.
@(private)
platform_forget_face :: proc(s: ^State, id: Font_Id) { color_forget_face(s, id) }

// Adds a face built from `dw` (takes its reference, and those of `file` and `memory`). Shares an existing font made
// from the same `key`.
@(private)
add_face :: proc(s: ^State, key: string, dw: ^IDWriteFontFace, file: ^IDWriteFontFile, memory: ^Memory_Font, family: string,
	weight: DWRITE_FONT_WEIGHT, stretch: DWRITE_FONT_STRETCH, style: DWRITE_FONT_STYLE) -> Font_Id {
	f := Font{kind = .Face}
	f.dw, f.file, f.memory, f.weight, f.stretch, f.style = dw, file, memory, weight, stretch, style
	f.dw2 = com_query(dw, &IID_IDWriteFontFace2, IDWriteFontFace2)
	f.dw4 = com_query(dw, &IID_IDWriteFontFace4, IDWriteFontFace4)
	f.dw5 = com_query(dw, &IID_IDWriteFontFace5, IDWriteFontFace5)
	f.dw7 = com_query(dw, &IID_IDWriteFontFace7, IDWriteFontFace7)
	dw->GetMetrics(&f.dm)
	f.upem = f32(max(f.dm.designUnitsPerEm, 1))
	if f.dw4 != nil {
		formats := f.dw4->GetGlyphImageFormats()
		f.color = formats & COLOR_FORMATS != 0
	} else if f.dw2 != nil {
		f.color = bool(f.dw2->IsColorFont())
	}
	refused: bool
	f.colr, refused = face_colr_open(&f)
	if f.colr != nil { f.color = true }
	if refused { f.color = false }   // a COLR table that cannot be read is not given to Direct2D (colr_nests_glyph): outlines
	return publish_face(s, key, f, family)
}

////////////////////////////////
// Loading faces

// A face of a font file (TrueType, OpenType, collections: `index` picks the face).
load_from_file :: proc(s: ^State, path: string, index := 0) -> (id: Font_Id, ok: bool) {
	if s.factory == nil { return 0, false }
	key := strings.concatenate({"file:", path, "#", itoa(index)}, context.temp_allocator)
	if id, ok = find_key(s, key); ok { return id, id != 0 }
	if !os.exists(path) { return 0, false }
	wpath := to_wide(path, context.temp_allocator)
	file: ^IDWriteFontFile
	if s.factory->CreateFontFileReference(raw_data(wpath), nil, &file) < 0 || file == nil { return 0, false }
	return face_from_file(s, key, file, nil, index, 0, "", 400, 5, .NORMAL)
}

// A face from memory with what CSS knows of it: its family name and nominal weight / style (the base of the system
// fallback for characters the face lacks), and simulated bold / slant (CSS font-synthesis). Takes ownership of `data`
// when `owned`.
load_memory :: proc(s: ^State, data: []byte, owned: bool, index := 0, simulations: Simulations = {}, family := "",
	weight := 400, style := Font_Style.Normal) -> (id: Font_Id, ok: bool) {
	if s.factory == nil || len(data) == 0 {
		if owned { delete(data) }
		return 0, false
	}
	// DirectWrite may release its last stream on one of its own threads: the bytes it reads are freed from there, so
	// they must come from the (thread-safe) heap, not from the caller's allocator
	bytes := data
	if owned {
		bytes = make([]byte, len(data), runtime.heap_allocator())
		copy(bytes, data)
		delete(data)
	}
	m := memory_font_new(bytes, owned)
	key := m.key
	file: ^IDWriteFontFile
	if s.factory->CreateCustomFontFileReference(&key, size_of(u64), &memory_loader.iface, &file) < 0 || file == nil {
		memory_font_release(m)
		return 0, false
	}
	return face_from_file(s, "", file, m, index, dw_simulations(simulations), family, DWRITE_FONT_WEIGHT(clamp(weight, 1, 999)), 5, dw_style(style))
}

@(private)
dw_simulations :: proc(sims: Simulations) -> DWRITE_FONT_SIMULATIONS {
	out: DWRITE_FONT_SIMULATIONS
	if .Bold in sims { out |= DWRITE_FONT_SIMULATIONS_BOLD }
	if .Oblique in sims { out |= DWRITE_FONT_SIMULATIONS_OBLIQUE }
	return out
}

// Takes the references of `file` and `memory` (released on failure).
@(private)
face_from_file :: proc(s: ^State, key: string, file: ^IDWriteFontFile, memory: ^Memory_Font, index: int, sims: DWRITE_FONT_SIMULATIONS,
	family: string, weight: DWRITE_FONT_WEIGHT, stretch: DWRITE_FONT_STRETCH, style: DWRITE_FONT_STYLE) -> (Font_Id, bool) {
	supported: BOOL
	file_type: DWRITE_FONT_FILE_TYPE
	face_type: DWRITE_FONT_FACE_TYPE
	faces: u32
	fail :: proc(file: ^IDWriteFontFile, memory: ^Memory_Font) -> (Font_Id, bool) {
		com_release(file)
		if memory != nil { memory_font_release(memory) }
		return 0, false
	}
	if file->Analyze(&supported, &file_type, &face_type, &faces) < 0 || !supported || index < 0 || u32(index) >= faces {
		return fail(file, memory)
	}
	dw: ^IDWriteFontFace
	files := [1]^IDWriteFontFile{file}
	if s.factory->CreateFontFace(face_type, 1, &files[0], u32(index), sims, &dw) < 0 || dw == nil { return fail(file, memory) }
	id := add_face(s, key, dw, file, memory, family, weight, stretch, style)
	return id, id != 0
}

// A system font (DirectWrite's system collection, family names as in the Windows "font family" model: "Segoe UI",
// "Segoe UI Semibold", "Arial Black"...) nearest to weight / style / stretch (1..9, 5 = normal). When the family has no
// bold or no italic face, DirectWrite simulates them.
load_system :: proc(s: ^State, family: string, weight := 400, style := Font_Style.Normal, stretch := 5) -> (id: Font_Id, ok: bool) {
	if s.system == nil || family == "" { return 0, false }
	req := strings.concatenate({"sysreq:", strings.to_lower(family, context.temp_allocator), "|", itoa(weight), "|", itoa(int(style)), "|", itoa(stretch)}, context.temp_allocator)
	if id, ok = find_key(s, req); ok { return id, id != 0 }
	wname := to_wide(family, context.temp_allocator)
	index: u32
	exists: BOOL
	if s.system->FindFamilyName(raw_data(wname), &index, &exists) < 0 || !exists {
		remember_key(s, req, 0)
		return 0, false
	}
	fam: ^IDWriteFontFamily
	if s.system->GetFontFamily(index, &fam) < 0 || fam == nil { return 0, false }
	defer com_release(fam)
	dwf: ^IDWriteFont
	if fam->GetFirstMatchingFont(DWRITE_FONT_WEIGHT(clamp(weight, 1, 999)), DWRITE_FONT_STRETCH(clamp(stretch, 1, 9)), dw_style(style), &dwf) < 0 || dwf == nil {
		return 0, false
	}
	defer com_release(dwf)
	id = face_from_dwrite_font(s, dwf, family)
	remember_key(s, req, id)
	return id, id != 0
}

// Whether the system collection has a family of this name.
has_system_family :: proc(s: ^State, family: string) -> bool {
	if s.system == nil || family == "" { return false }
	wname := to_wide(family, context.temp_allocator)
	index: u32
	exists: BOOL
	return s.system->FindFamilyName(raw_data(wname), &index, &exists) >= 0 && bool(exists)
}

// A face for a font of the system collection (or of the fallback), shared by every request that resolves to it.
@(private)
face_from_dwrite_font :: proc(s: ^State, dwf: ^IDWriteFont, family_hint := "") -> Font_Id {
	family := family_hint
	fam: ^IDWriteFontFamily
	if dwf->GetFontFamily(&fam) >= 0 && fam != nil {
		names: ^IDWriteLocalizedStrings
		if fam->GetFamilyNames(&names) >= 0 && names != nil {
			family = localized_string(names, context.temp_allocator)
			com_release(names)
		}
		com_release(fam)
	}
	weight, stretch, style := dwf->GetWeight(), dwf->GetStretch(), dwf->GetStyle()
	sims := dwf->GetSimulations()
	key := strings.concatenate({"sys:", strings.to_lower(family, context.temp_allocator), "|", itoa(int(weight)), "|", itoa(int(stretch)),
		"|", itoa(int(style)), "|", itoa(int(sims))}, context.temp_allocator)
	if id, ok := find_key(s, key); ok { return id }
	dw: ^IDWriteFontFace
	if dwf->CreateFontFace(&dw) < 0 || dw == nil { return 0 }
	return add_face(s, key, dw, nil, nil, family, weight, stretch, style)
}

// The same face with simulated bold and / or slant added (CSS font-synthesis, for a web font family that lacks the
// bold or italic face). Returns `id` itself when nothing is to add.
with_simulations :: proc(s: ^State, id: Font_Id, bold, oblique: bool) -> Font_Id {
	f := face_ptr(s, id)
	if f == nil { return id }
	sims := f.dw->GetSimulations()
	want := sims
	if bold { want |= DWRITE_FONT_SIMULATIONS_BOLD }
	if oblique { want |= DWRITE_FONT_SIMULATIONS_OBLIQUE }
	if want == sims { return id }
	key := strings.concatenate({"sim:", itoa(int(id)), "|", itoa(int(want))}, context.temp_allocator)
	if nid, ok := find_key(s, key); ok { return nid }
	n: u32
	if f.dw->GetFiles(&n, nil) < 0 || n == 0 || n > 8 { return id }
	files: [8]^IDWriteFontFile
	if f.dw->GetFiles(&n, &files[0]) < 0 { return id }
	defer for i in 0 ..< n { com_release(files[i]) }
	dw: ^IDWriteFontFace
	if s.factory->CreateFontFace(f.dw->GetType(), n, &files[0], f.dw->GetIndex(), want, &dw) < 0 || dw == nil { return id }
	if f.memory != nil { memory_font_retain(f.memory) }
	family := from_wide(f.family, context.temp_allocator)
	nid := add_face(s, key, dw, nil, f.memory, family, f.weight, f.stretch, f.style)
	return nid != 0 ? nid : id
}

axes :: proc(s: ^State, id: Font_Id, allocator := context.allocator) -> []Axis {
	f := face_ptr(s, id)
	if f == nil || f.dw5 == nil { return nil }
	res: ^IDWriteFontResource
	if f.dw5->GetFontResource(&res) < 0 || res == nil { return nil }
	defer com_release(res)
	n := res->GetFontAxisCount()
	if n == 0 || n > 64 { return nil }
	ranges: [64]DWRITE_FONT_AXIS_RANGE
	defs: [64]DWRITE_FONT_AXIS_VALUE
	if res->GetFontAxisRanges(&ranges[0], n) < 0 || res->GetDefaultFontAxisValues(&defs[0], n) < 0 { return nil }
	out := make([]Axis, n, allocator)
	for i in 0 ..< int(n) {
		out[i] = {tag = transmute([4]u8)ranges[i].axisTag, min = ranges[i].minValue, max = ranges[i].maxValue, default = defs[i].value}
	}
	return out
}

// An instance of a variable face at the given axis values (CSS font-variation-settings, and font-weight / font-stretch /
// font-style on variable fonts). Axes the face lacks are ignored; values are clamped by DirectWrite. Returns `id` for a
// static face or when DirectWrite is too old (before Windows 10 1803).
with_variations :: proc(s: ^State, id: Font_Id, values: []Axis_Value) -> Font_Id {
	f := face_ptr(s, id)
	if f == nil || f.dw5 == nil || len(values) == 0 || !face_has_axes(f) { return id }
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "var:")
	strings.write_int(&sb, int(id))
	for v in values {
		tag := v.tag
		strings.write_byte(&sb, '|')
		strings.write_string(&sb, string(tag[:]))
		strings.write_byte(&sb, '=')
		strings.write_int(&sb, int(math.round(v.value * 1000)))
	}
	key := strings.to_string(sb)
	if nid, ok := find_key(s, key); ok { return nid }
	res: ^IDWriteFontResource
	if f.dw5->GetFontResource(&res) < 0 || res == nil { return id }
	defer com_release(res)
	dv := make([]DWRITE_FONT_AXIS_VALUE, len(values), context.temp_allocator)
	for v, i in values { dv[i] = {axisTag = transmute(u32)v.tag, value = v.value} }
	dw5: ^IDWriteFontFace5
	if res->CreateFontFace(f.dw->GetSimulations(), raw_data(dv), u32(len(dv)), &dw5) < 0 || dw5 == nil { return id }
	dw := com_query(dw5, &IID_IDWriteFontFace, IDWriteFontFace)
	com_release(dw5)
	if dw == nil { return id }
	if f.memory != nil { memory_font_retain(f.memory) }
	family := from_wide(f.family, context.temp_allocator)
	nid := add_face(s, key, dw, nil, f.memory, family, f.weight, f.stretch, f.style)
	return nid != 0 ? nid : id
}

@(private)
face_has_axes :: proc(f: ^Font) -> bool {
	res: ^IDWriteFontResource
	if f.dw5->GetFontResource(&res) < 0 || res == nil { return false }
	defer com_release(res)
	return res->GetFontAxisCount() > 0
}

@(private)
IID_IDWriteFontFace := IID{0x5f49804d, 0x7024, 0x4d43, {0xbf, 0xa9, 0xd2, 0x59, 0x84, 0xf5, 0x38, 0x49}}

@(private)
localized_string :: proc(names: ^IDWriteLocalizedStrings, allocator := context.allocator) -> string {
	if names->GetCount() == 0 { return "" }
	index: u32
	exists: BOOL
	en := [?]u16{'e', 'n', '-', 'u', 's', 0}
	if names->FindLocaleName(&en[0], &index, &exists) < 0 || !exists { index = 0 }
	n: u32
	if names->GetStringLength(index, &n) < 0 { return "" }
	buf := make([]u16, n + 1, context.temp_allocator)
	if names->GetString(index, raw_data(buf), n + 1) < 0 { return "" }
	return from_wide(buf, allocator)
}

@(private)
dw_style :: proc(st: Font_Style) -> DWRITE_FONT_STYLE {
	switch st {
	case .Normal: return .NORMAL
	case .Italic: return .ITALIC
	case .Oblique: return .OBLIQUE
	}
	return .NORMAL
}
