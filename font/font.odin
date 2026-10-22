// Package font: text on DirectWrite. Faces come from the system font collection, from files or from memory (web fonts);
// text is shaped (OpenType features, ligatures, kerning, complex scripts) with characters a face lacks taken from the
// next face of a cascade (CSS font-family lists, unicode-range) and then from the system fallback; bidirectional text is
// resolved (UAX #9) and line break opportunities found (UAX #14) by DirectWrite's analyzers. Glyphs are rasterized
// (grayscale coverage, horizontal subpixel positions; color glyphs as RGBA) into atlas pages the draw layer uploads.
//
// Threads: loading faces, shaping, measuring and the analyses may run on any thread at once (DirectWrite's factory,
// faces and analyzer are free-threaded; the package's own tables are locked or published atomically). Rasterization
// and the atlas belong to whoever draws (one lock; see raster.odin). `unload` and `destroy` must not overlap any other
// call that uses what they free.
package font

import "base:runtime"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"

// Default size of an atlas page (texels on a side); Settings.page_size overrides it.
ATLAS_SIZE :: 2048

Font_Id :: distinct int

Metrics :: struct {
	ascent:      f32,   // pixels above the baseline (positive)
	descent:     f32,   // pixels below the baseline (positive)
	line_height: f32,   // ascent + descent + line gap, rounded
	line_gap:    f32,   // the face's line gap (DirectWrite's lineGap: OS/2 typo or hhea as the face asks), not rounded
	x_height:    f32,
	cap_height:  f32,
	underline_offset:    f32,   // below the baseline (positive down)
	underline_thickness: f32,
	strike_offset:       f32,   // above the baseline (positive up)
	strike_thickness:    f32,
}

// A glyph's box from its outline metrics (no rasterization): kept for callers of the stb_truetype era.
Glyph :: struct {
	uv:      [4]f32,    // unused (atlas placement is per raster size, see glyph_image)
	offset:  [2]f32,    // top-left of the ink box relative to the pen position on the baseline
	size:    [2]f32,
	advance: f32,
}

// An OpenType feature setting (CSS font-feature-settings: "liga" 0, "ss01" 1, "salt" 3...).
Feature :: struct {
	tag:   [4]u8,
	value: u32,
}

// A variation axis value (CSS font-variation-settings: "wght" 650, "wdth" 87.5...).
Axis_Value :: struct {
	tag:   [4]u8,
	value: f32,
}

// Inclusive range of code points (CSS unicode-range).
Range :: [2]rune

Font_Style :: enum u8 { Normal, Italic, Oblique }

// One face of a cascade: the characters it covers are taken from it (all of them when `ranges` is empty).
Cascade_Entry :: struct {
	font:   Font_Id,
	ranges: []Range,
}

Rendering :: enum u8 { Natural_Symmetric, Natural, Gdi_Classic, Aliased }
Grid_Fit :: enum u8 { Default, Enabled, Disabled }

Settings :: struct {
	subpixel_steps:  int,       // horizontal glyph positions per pixel (1: whole pixels, up to 4)
	rendering:       Rendering, // DirectWrite rendering mode of the glyph bitmaps
	grid_fit:        Grid_Fit,
	color_glyphs:    bool,      // color glyphs (emoji: COLR, sbix, CBDT, SVG) in color; else their outline in the text color
	color_async:     bool,      // color glyphs are drawn on a thread of their own: pending until ready (color_async.odin;
	                            // the application asks for a frame from set_color_ready_callback)
	system_fallback: bool,      // characters no face of a cascade has come from the system fallback fonts
	page_size:       int,       // texels on a side of an atlas page
	max_gray_pages:  int,       // coverage pages kept before the least recently used one is reused
	max_color_pages: int,
	word_cache:      int,       // shaped words kept (the measure cache), 0: no cache
	text_renderer:   Text_Renderer,   // how glyph outlines reach the screen (slug_cache.odin for Slug)
	slug_pages:      int,       // Slug glyph pages (rows of the two textures, 4096 texels each) kept before the least recently used one is reused
	slug_tolerance:  f32,       // largest distance (em) between a cubic outline and the quadratics Slug draws instead
}

// What draws the glyph outlines: coverage bitmaps in the atlas (rasterized by DirectWrite, hinted, cached per size and
// subpixel position), or the Slug algorithm (the curves on the GPU: sharp at any scale, rotation or perspective; no bitmaps).
// Color glyphs (emoji) are always atlas images.
Text_Renderer :: enum u8 { Atlas, Slug }

// -define:FONT_TEXT_RENDERER=slug makes Slug the default renderer of a build (to run the pixel tests of the other
// packages with it: `odin test tests/retained -define:FONT_TEXT_RENDERER=slug`).
DEFAULT_TEXT_RENDERER :: #config(FONT_TEXT_RENDERER, "atlas")
#assert(DEFAULT_TEXT_RENDERER == "atlas" || DEFAULT_TEXT_RENDERER == "slug", "FONT_TEXT_RENDERER is atlas or slug")
when DEFAULT_TEXT_RENDERER == "slug" {
	@(private) BUILD_TEXT_RENDERER :: Text_Renderer.Slug
} else {
	@(private) BUILD_TEXT_RENDERER :: Text_Renderer.Atlas
}

DEFAULT_SETTINGS :: Settings{
	subpixel_steps = 4, rendering = .Natural_Symmetric, grid_fit = .Default, color_glyphs = true, color_async = false, system_fallback = true,
	page_size = ATLAS_SIZE, max_gray_pages = 4, max_color_pages = 2, word_cache = 32768,
	text_renderer = BUILD_TEXT_RENDERER, slug_pages = 128, slug_tolerance = 1.0 / 4096,
}

@(private) CHUNK :: 256
@(private) MAX_CHUNKS :: 256

@(private)
Font_Kind :: enum u8 { None, Face, Cascade }

@(private)
Font :: struct {
	kind:     Font_Kind,
	dead:     bool,
	// Face
	dw:       ^IDWriteFontFace,
	dw2:      ^IDWriteFontFace2,     // nil before Windows 8.1
	dw4:      ^IDWriteFontFace4,     // nil before Windows 10 1607
	dw5:      ^IDWriteFontFace5,     // nil before Windows 10 1803
	dw7:      ^IDWriteFontFace7,     // nil before Windows 11 22H2 (COLR v1 paint reader)
	file:     ^IDWriteFontFile,      // files this package made (memory, path)
	memory:   ^Memory_Font,
	dm:       DWRITE_FONT_METRICS,
	upem:     f32,
	family:   []u16,                 // NUL-terminated: the base family of system fallback
	weight:   DWRITE_FONT_WEIGHT,
	stretch:  DWRITE_FONT_STRETCH,
	style:    DWRITE_FONT_STYLE,
	color:    bool,                  // has color glyphs (COLR, sbix, CBDT, SVG)
	cmap:     []u32,                 // BMP coverage, 2 bits per code point (known, present), filled lazily
	// Cascade (a face is its own one-entry cascade)
	entries:  []Cascade_Entry,
	features: []DWRITE_FONT_FEATURE,
	no_system_fallback: bool,
}

State :: struct {
	settings:   Settings,
	factory:    ^IDWriteFactory,
	factory2:   ^IDWriteFactory2,    // system fallback, color glyphs, grayscale analysis
	factory4:   ^IDWriteFactory4,    // color glyph image formats
	factory8:   ^IDWriteFactory8,    // COLR v1 paint trees (Windows 11 22H2)
	system:     ^IDWriteFontCollection,
	fallback:   ^IDWriteFontFallback,
	analyzer:   ^IDWriteTextAnalyzer,
	ok:         bool,                // DirectWrite is usable
	latin:      DWRITE_SCRIPT_ANALYSIS,   // the script analysis of ASCII text (reused: no analysis per word)
	latin_ok:   bool,
	mu:         sync.Mutex,          // adding / removing fonts
	chunks:     [MAX_CHUNKS]^[CHUNK]Font,
	count:      int,                 // fonts published (atomic)
	keys:       map[string]Font_Id,  // what made each font, for sharing
	words:      Word_Cache,
	atlas:      Atlas,
	color_raster: Color_Raster,      // Direct2D drawing of color glyphs (color.odin)
	color_queue:  Color_Queue,       // the color glyph thread (color_async.odin)
	generation: int,                 // bumps when faces are unloaded
}

@(private)
loader_mu: sync.Mutex
@(private)
loader_users: int

// Starts DirectWrite. Without it (not Windows, or a failure) every face fails to load and text measures 0.
init :: proc(s: ^State, settings := DEFAULT_SETTINGS) {
	context.allocator = runtime.heap_allocator()
	s.settings = settings
	sanitize_settings(&s.settings)
	s.keys = make(map[string]Font_Id)
	sync.mutex_lock(&s.mu)
	add_font_locked(s, Font{})   // id 0 = invalid
	sync.mutex_unlock(&s.mu)
	words_init(&s.words, s.settings.word_cache)
	atlas_init(&s.atlas)

	f: rawptr
	if DWriteCreateFactory(.SHARED, &IID_IDWriteFactory, &f) < 0 || f == nil { return }
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
	s.ok = s.analyzer != nil
	if s.ok {
		a := [1]u16{'a'}
		scripts := make([dynamic]Script_Run, 0, 1, context.temp_allocator)
		an: Analysis
		analysis_init(&an, a[:], false)
		an.scripts = &scripts
		if s.analyzer->AnalyzeScript(&an.source, 0, 1, &an.sink) >= 0 && len(scripts) == 1 { s.latin, s.latin_ok = scripts[0].sa, true }
	}
}

@(private)
sanitize_settings :: proc(st: ^Settings) {
	st.subpixel_steps = clamp(st.subpixel_steps, 1, 4)
	if st.page_size <= 0 { st.page_size = ATLAS_SIZE }
	st.page_size = clamp(st.page_size, 256, 8192)
	st.max_gray_pages = clamp(st.max_gray_pages, 1, 64)
	st.max_color_pages = clamp(st.max_color_pages, 1, 64)
	st.word_cache = max(st.word_cache, 0)
	st.slug_pages = clamp(st.slug_pages, 1, SLUG_MAX_PAGES)
	st.slug_tolerance = clamp(st.slug_tolerance, 1.0 / 65536, 1.0 / 64)
}

// Changes the settings. New rendering settings (subpixel steps, rendering mode, grid fitting, color glyphs) apply to
// every glyph looked up from now on: cached bitmaps are forgotten (their pages are reused as usual, never under a
// frame drawing from them) and the atlas' settings generation bumps (recorded text made with the old ones is stale).
set_settings :: proc(s: ^State, settings: Settings) {
	st := settings
	sanitize_settings(&st)
	atlas_lock(&s.atlas)
	old := s.settings
	if st.subpixel_steps != old.subpixel_steps || st.rendering != old.rendering || st.grid_fit != old.grid_fit || st.color_glyphs != old.color_glyphs {
		clear(&s.atlas.glyphs)
		clear(&s.atlas.fg_glyphs)
		s.atlas.settings_generation += 1
	}
	s.settings.subpixel_steps, s.settings.rendering, s.settings.grid_fit = st.subpixel_steps, st.rendering, st.grid_fit
	s.settings.color_glyphs, s.settings.max_gray_pages, s.settings.max_color_pages = st.color_glyphs, st.max_gray_pages, st.max_color_pages
	s.settings.color_async = st.color_async
	// the renderer decides which glyphs are bitmaps: what was recorded with the other one is stale. A new tolerance
	// changes the data itself.
	if st.text_renderer != old.text_renderer { s.atlas.settings_generation += 1 }
	if st.slug_tolerance != old.slug_tolerance {
		slug_clear(&s.atlas.slug)
		s.atlas.settings_generation += 1
	}
	s.settings.text_renderer, s.settings.slug_pages, s.settings.slug_tolerance = st.text_renderer, st.slug_pages, st.slug_tolerance
	atlas_unlock(&s.atlas)
	if st.system_fallback != s.settings.system_fallback {
		s.settings.system_fallback = st.system_fallback
		words_clear(&s.words)   // what text measures changes
	}
	if st.word_cache != s.settings.word_cache {
		s.settings.word_cache = st.word_cache
		words_resize(&s.words, st.word_cache)
	}
}

destroy :: proc(s: ^State) {
	context.allocator = runtime.heap_allocator()
	words_destroy(&s.words)
	color_queue_destroy(s)
	color_raster_destroy(&s.color_raster)
	atlas_destroy(&s.atlas)
	n := sync.atomic_load(&s.count)
	for i in 1 ..< n { release_font(font_ptr(s, Font_Id(i))) }
	for c in s.chunks { if c != nil { free(c) } }
	for k in s.keys { delete(k) }
	delete(s.keys)
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
	s^ = {}
}

@(private)
release_font :: proc(f: ^Font) {
	context.allocator = runtime.heap_allocator()
	if f == nil || f.kind == .None { return }
	com_release(f.dw7); com_release(f.dw5); com_release(f.dw4); com_release(f.dw2); com_release(f.dw)
	com_release(f.file)
	if f.memory != nil { memory_font_release(f.memory) }
	delete(f.family)
	delete(f.cmap)
	for e in f.entries { delete(e.ranges) }
	delete(f.entries)
	delete(f.features)
	f^ = Font{kind = .None, dead = true}
}

@(private)
font_ptr :: #force_inline proc "contextless" (s: ^State, id: Font_Id) -> ^Font {
	i := int(id)
	if i <= 0 || i >= sync.atomic_load(&s.count) { return nil }
	return &s.chunks[i / CHUNK][i % CHUNK]
}

// The font, if it is a live face.
@(private)
face_ptr :: #force_inline proc "contextless" (s: ^State, id: Font_Id) -> ^Font {
	f := font_ptr(s, id)
	if f == nil || f.kind != .Face || f.dead { return nil }
	return f
}

// Caller holds s.mu. Publishes `f` (written completely before the count moves).
@(private)
add_font_locked :: proc(s: ^State, f: Font) -> Font_Id {
	context.allocator = runtime.heap_allocator()
	n := s.count
	if n >= CHUNK * MAX_CHUNKS { return 0 }
	if s.chunks[n / CHUNK] == nil { s.chunks[n / CHUNK] = new([CHUNK]Font) }
	s.chunks[n / CHUNK][n % CHUNK] = f
	sync.atomic_store(&s.count, n + 1)
	return Font_Id(n)
}

// Adds a face built from `dw` (takes its reference, and those of `file` and `memory`). Shares an existing font made
// from the same `key`.
@(private)
add_face :: proc(s: ^State, key: string, dw: ^IDWriteFontFace, file: ^IDWriteFontFile, memory: ^Memory_Font, family: string,
	weight: DWRITE_FONT_WEIGHT, stretch: DWRITE_FONT_STRETCH, style: DWRITE_FONT_STYLE) -> Font_Id {
	context.allocator = runtime.heap_allocator()
	f := Font{kind = .Face, dw = dw, file = file, memory = memory, weight = weight, stretch = stretch, style = style}
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
	f.family = to_wide(family)
	f.cmap = make([]u32, 65536 * 2 / 32)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if key != "" {
		if id, ok := s.keys[key]; ok {
			release_font(&f)
			return id
		}
	}
	id := add_font_locked(s, f)
	if id == 0 { release_font(&f); return 0 }
	fp := &s.chunks[int(id) / CHUNK][int(id) % CHUNK]
	fp.entries = make([]Cascade_Entry, 1)
	fp.entries[0] = {font = id}
	if key != "" { s.keys[strings.clone(key)] = id }
	return id
}

@(private)
find_key :: proc(s: ^State, key: string) -> (Font_Id, bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	id, ok := s.keys[key]
	return id, ok
}

@(private)
remember_key :: proc(s: ^State, key: string, id: Font_Id) {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if key not_in s.keys { s.keys[strings.clone(key)] = id }
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

// Takes ownership of `data` (freed when the face is unloaded, or with the state).
load_from_memory :: proc(s: ^State, data: []byte, index := 0) -> (id: Font_Id, ok: bool) {
	return load_memory(s, data, true, index)
}

// A font compiled into the exe (`#load("x.ttf")`): read in place, never freed.
load_embedded :: proc(s: ^State, data: []byte) -> (id: Font_Id, ok: bool) {
	return load_memory(s, data, false)
}

// A face from memory with what CSS knows of it: its family name and nominal weight / style (the base of the system
// fallback for characters the face lacks), and simulated bold / slant (CSS font-synthesis). Takes ownership of `data`
// when `owned`.
load_memory :: proc(s: ^State, data: []byte, owned: bool, index := 0, simulations: DWRITE_FONT_SIMULATIONS = 0, family := "",
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
	return face_from_file(s, "", file, m, index, simulations, family, DWRITE_FONT_WEIGHT(clamp(weight, 1, 999)), 5, dw_style(style))
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

// The axes of a variable face: tag, minimum, maximum and default value. Empty for a static face.
Axis :: struct { tag: [4]u8, min, max, default: f32 }

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

// A cascade: characters are taken from the first entry whose ranges include them and whose face has them, then from
// the system fallback (unless `no_system_fallback`). `features` apply to every face (CSS font-feature-settings,
// font-variant-*, font-kerning). Shared with an identical cascade made before. A cascade's metrics are its first
// live entry's.
cascade :: proc(s: ^State, entries: []Cascade_Entry, features: []Feature = nil, no_system_fallback := false) -> Font_Id {
	if len(entries) == 0 { return 0 }
	if len(entries) == 1 && len(entries[0].ranges) == 0 && len(features) == 0 && !no_system_fallback { return entries[0].font }
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "cas:")
	for e in entries {
		strings.write_int(&sb, int(e.font))
		for r in e.ranges { strings.write_byte(&sb, '/'); strings.write_int(&sb, int(r[0])); strings.write_byte(&sb, '-'); strings.write_int(&sb, int(r[1])) }
		strings.write_byte(&sb, ',')
	}
	for f in features { tag := f.tag; strings.write_byte(&sb, '|'); strings.write_string(&sb, string(tag[:])); strings.write_int(&sb, int(f.value)) }
	if no_system_fallback { strings.write_string(&sb, "|nosys") }
	key := strings.to_string(sb)
	if id, ok := find_key(s, key); ok { return id }
	context.allocator = runtime.heap_allocator()
	f := Font{kind = .Cascade, no_system_fallback = no_system_fallback}
	f.entries = make([]Cascade_Entry, len(entries))
	for e, i in entries {
		f.entries[i].font = e.font
		if len(e.ranges) > 0 {
			f.entries[i].ranges = make([]Range, len(e.ranges))
			copy(f.entries[i].ranges, e.ranges)
		}
	}
	if len(features) > 0 {
		f.features = make([]DWRITE_FONT_FEATURE, len(features))
		for ft, i in features { f.features[i] = {nameTag = transmute(u32)ft.tag, parameter = ft.value} }
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if id, ok := s.keys[key]; ok { release_font(&f); return id }
	id := add_font_locked(s, f)
	if id == 0 { release_font(&f); return 0 }
	s.keys[strings.clone(key)] = id
	return id
}

// Frees a font: its face (and data), the shaped words and glyph bitmaps that use it. Cascades that list it skip it
// from then on. Nothing may use the font meanwhile (no shaping, measuring or drawing on any thread).
unload :: proc(s: ^State, id: Font_Id) {
	context.allocator = runtime.heap_allocator()
	f := font_ptr(s, id)
	if f == nil || f.dead { return }
	words_clear(&s.words)
	if f.kind == .Face {
		color_forget_face(s, id)
		atlas_forget_face(&s.atlas, id)
	}
	sync.mutex_lock(&s.mu)
	dead := make([dynamic]string, context.temp_allocator)
	for k, v in s.keys { if v == id { append(&dead, k) } }
	for k in dead { delete_key(&s.keys, k); delete(k) }
	release_font(f)
	s.generation += 1
	sync.mutex_unlock(&s.mu)
}

// Whether `id` is a live font.
valid :: proc(s: ^State, id: Font_Id) -> bool {
	f := font_ptr(s, id)
	return f != nil && !f.dead && f.kind != .None
}

// The face whose metrics a font uses (itself for a face, the first live entry of a cascade).
primary_face :: proc(s: ^State, id: Font_Id) -> Font_Id {
	f := font_ptr(s, id)
	if f == nil || f.dead { return 0 }
	if f.kind == .Face { return id }
	for e in f.entries { if face_ptr(s, e.font) != nil { return e.font } }
	return 0
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

////////////////////////////////
// Metrics

metrics :: proc(s: ^State, id: Font_Id, size: f32) -> Metrics {
	f := face_ptr(s, primary_face(s, id))
	if f == nil {
		t := max(size / 15, 1)
		return {ascent = size * 0.8, descent = size * 0.2, line_height = math.round(size * 1.2), line_gap = size * 0.2, x_height = size * 0.5, cap_height = size * 0.7,
			underline_offset = size * 0.1, underline_thickness = t, strike_offset = size * 0.25, strike_thickness = t}
	}
	k := size / f.upem
	dm := f.dm
	m := Metrics{
		ascent = f32(dm.ascent) * k, descent = f32(dm.descent) * k,
		x_height = f32(dm.xHeight) * k, cap_height = f32(dm.capHeight) * k,
		underline_offset = -f32(dm.underlinePosition) * k, underline_thickness = f32(dm.underlineThickness) * k,
		strike_offset = f32(dm.strikethroughPosition) * k, strike_thickness = f32(dm.strikethroughThickness) * k,
	}
	m.line_gap = f32(dm.lineGap) * k
	m.line_height = math.round(m.ascent + m.descent + m.line_gap)
	if m.x_height <= 0 { m.x_height = size * 0.5 }
	if m.cap_height <= 0 { m.cap_height = m.ascent * 0.7 }
	if m.underline_thickness <= 0 { m.underline_thickness = size / 15 }
	if m.strike_thickness <= 0 { m.strike_thickness = m.underline_thickness }
	if m.strike_offset <= 0 { m.strike_offset = m.x_height * 0.5 }
	return m
}

// The nominal glyph of `r` (through the cascade and the system fallback): advance and ink box at `size`.
glyph :: proc(s: ^State, id: Font_Id, size: f32, r: rune) -> Glyph {
	buf: [4]u8
	n := encode_utf8(buf[:], r)
	sh := shape(s, id, size, string(buf[:n]), {}, context.temp_allocator)
	g := Glyph{advance = sh.width}
	if len(sh.glyphs) == 0 { return g }
	gp := sh.glyphs[0]
	f := face_ptr(s, gp.face)
	if f == nil { return g }
	gid := [1]u16{gp.id}
	gm: DWRITE_GLYPH_METRICS
	if f.dw->GetDesignGlyphMetrics(&gid[0], 1, &gm, false) < 0 { return g }
	k := size / f.upem
	left := f32(gm.leftSideBearing) * k
	right := (f32(gm.advanceWidth) - f32(gm.rightSideBearing)) * k
	top := (f32(gm.verticalOriginY) - f32(gm.topSideBearing)) * k
	bottom := (f32(gm.verticalOriginY) - (f32(gm.advanceHeight) - f32(gm.bottomSideBearing))) * k
	if right > left && top > bottom {
		g.offset = {math.floor(left), -math.ceil(top)}
		g.size = {math.ceil(right) - math.floor(left), math.ceil(top) - math.floor(bottom)}
	}
	return g
}

// Kerning is part of shaping now: the difference between a pair shaped together and apart.
kern :: proc(s: ^State, id: Font_Id, size: f32, a, b: rune) -> f32 {
	buf: [8]u8
	n := encode_utf8(buf[:], a)
	n += encode_utf8(buf[n:], b)
	return text_width(s, id, size, string(buf[:n])) - glyph(s, id, size, a).advance - glyph(s, id, size, b).advance
}

////////////////////////////////
// Strings

@(private)
to_wide :: proc(s: string, allocator := context.allocator) -> []u16 {
	n := 0
	for r in s { n += r >= 0x10000 ? 2 : 1 }
	out := make([]u16, n + 1, allocator)
	i := 0
	for r in s {
		if r >= 0x10000 {
			v := u32(r) - 0x10000
			out[i], out[i + 1] = u16(0xD800 + (v >> 10)), u16(0xDC00 + (v & 0x3FF))
			i += 2
		} else {
			out[i] = u16(r)
			i += 1
		}
	}
	return out
}

@(private)
from_wide :: proc(w: []u16, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	i := 0
	for i < len(w) && w[i] != 0 {
		c := rune(w[i])
		if c >= 0xD800 && c < 0xDC00 && i + 1 < len(w) && w[i + 1] >= 0xDC00 && w[i + 1] < 0xE000 {
			c = 0x10000 + (c - 0xD800) << 10 + (rune(w[i + 1]) - 0xDC00)
			i += 1
		}
		strings.write_rune(&sb, c)
		i += 1
	}
	return strings.to_string(sb)
}

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
encode_utf8 :: proc(buf: []u8, r: rune) -> int {
	c := u32(r)
	switch {
	case c < 0x80: buf[0] = u8(c); return 1
	case c < 0x800: buf[0] = u8(0xC0 | c >> 6); buf[1] = u8(0x80 | c & 0x3F); return 2
	case c < 0x10000: buf[0] = u8(0xE0 | c >> 12); buf[1] = u8(0x80 | (c >> 6) & 0x3F); buf[2] = u8(0x80 | c & 0x3F); return 3
	}
	buf[0] = u8(0xF0 | c >> 18); buf[1] = u8(0x80 | (c >> 12) & 0x3F); buf[2] = u8(0x80 | (c >> 6) & 0x3F); buf[3] = u8(0x80 | c & 0x3F)
	return 4
}

@(private)
itoa :: proc(v: int) -> string {
	buf: [24]u8
	i := len(buf)
	n := v < 0 ? -v : v
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 { break }
	}
	if v < 0 { i -= 1; buf[i] = '-' }
	return strings.clone(string(buf[i:]), context.temp_allocator)
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
