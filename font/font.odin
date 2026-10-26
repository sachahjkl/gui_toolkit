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
	page_size:       int,       // texels on a side of an atlas page (init only; set_settings keeps the first)
	max_gray_pages:  int,       // coverage pages kept before the least recently used one is reused
	max_color_pages: int,
	word_cache:      int,       // shaped words kept (the measure cache), 0: no cache
	text_renderer:   Text_Renderer,   // how glyph outlines reach the screen (slug_cache.odin for Slug)
	slug_pages:      int,       // Slug glyph pages (rows of the two textures, 4096 texels each) kept before the least recently used one is reused
	slug_tolerance:  f32,       // largest distance (em) between a cubic outline and the quadratics Slug draws instead
	color_engine:    Color_Engine,   // who draws COLR / CPAL color glyphs (colr.odin, or Direct2D)
	colr_samples:    int,       // vertical samples per pixel row of the interpreter's scan conversion
	colr_cache_kb:   int,       // glyph outlines the interpreter keeps per face (KiB) before it drops them all
	backend:         Backend,   // who shapes and analyses text (backend.odin; init only: set_settings keeps the first)
}

// Who draws the COLR glyphs (v0 layers and v1 paint graphs) of a face: this package's interpreter, the same on every
// platform and for every face whose tables it can read, or Direct2D (what Windows draws: system emoji, and no paint
// graphs before Windows 11). Color glyphs of other formats (sbix, CBDT, SVG) are Direct2D's with both.
Color_Engine :: enum u8 { System, Builtin }

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
	color_engine = .System, colr_samples = 8, colr_cache_kb = 8192,
	backend = BUILD_BACKEND,
}

// Fonts live in slots of chunks; an id is the slot's index (low 20 bits) and the slot's generation (above): the slot of
// an unloaded font is reused, and the id of the font that was there no longer reaches the new one.
@(private) CHUNK :: 256
@(private) MAX_CHUNKS :: 4096
@(private) FONT_INDEX_BITS :: 20
@(private) FONT_INDEX_MASK :: 1 << FONT_INDEX_BITS - 1
#assert(CHUNK * MAX_CHUNKS == 1 << FONT_INDEX_BITS)

@(private)
Font_Kind :: enum u8 { None, Face, Cascade }

@(private)
Font :: struct {
	kind:     Font_Kind,
	dead:     bool,
	gen:      int,                   // generation of the slot (atomic): the high part of the ids it has had
	// Face
	using platform: Platform_Face,   // what the platform opened the face with (font_windows.odin, font_other.odin)
	upem:     f32,
	family:   []u16,                 // NUL-terminated: the base family of system fallback
	color:    bool,                  // has color glyphs (COLR, sbix, CBDT, SVG)
	cmap:     []u32,                 // BMP coverage, 2 bits per code point (known, present), filled lazily
	colr:     ^Face_Colr,            // the COLR / CPAL tables of the face the interpreter reads (nil: none)
	fm:       Face_Metrics,          // design metrics, from the backend
	native:   rawptr,                // the native backend's face (backend_native.odin), nil with another backend
	// Cascade (a face is its own one-entry cascade)
	entries:  []Cascade_Entry,
	features: []Feature,
	no_system_fallback: bool,
}

State :: struct {
	settings:   Settings,
	using platform: Platform_State,  // the platform's font system (font_windows.odin: DirectWrite, Direct2D)
	ok:         bool,                // the backend is usable
	backend:    Backend,
	tb:         ^Text_Backend,       // its procedures (backend.odin)
	system_fonts: ^System_Fonts,     // the platform's fonts: lists, fallback
	native:     rawptr,              // what the native backend keeps per State
	latin:      Script_Item,         // the script analysis of ASCII text (reused: no analysis per word)
	latin_ok:   bool,
	mu:         sync.Mutex,          // adding / removing fonts
	chunks:     [MAX_CHUNKS]^[CHUNK]Font,
	count:      int,                 // slots published (atomic)
	free_slots: [dynamic]int,        // slots of unloaded fonts, to reuse (under mu)
	keys:       map[string]Font_Id,  // what made each font, for sharing
	words:      Word_Cache,
	atlas:      Atlas,
	generation: int,                 // bumps when faces are unloaded
	emoji:        Emoji_Source,      // the built-in emoji font (emoji.odin)
	colr_drawn:   int,               // glyphs the COLR interpreter drew (atomic), and those it refused (a graph it cannot read)
	colr_refused: int,
}

// Starts the platform's font system and the backend. Without them (a failure, a platform with neither) every face
// fails to load and text measures 0.
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
	s.tb = &none_backend
	s.backend = s.settings.backend
	if !platform_init(s) { return }
	b := s.settings.backend
	if !backend_available(b) { b = BUILD_BACKEND }
	s.backend = b
	s.tb = backend_table(b)
	s.ok = s.tb.start(s)
	s.atlas.slug.provider = s.tb.outline
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
	st.colr_samples = clamp(st.colr_samples, 1, 64)
	st.colr_cache_kb = clamp(st.colr_cache_kb, 64, 1 << 20)
}

// Changes the settings. New rendering settings (subpixel steps, rendering mode, grid fitting, color glyphs) apply to
// every glyph looked up from now on: cached bitmaps are forgotten (their pages are reused as usual, never under a
// frame drawing from them) and the atlas' settings generation bumps (recorded text made with the old ones is stale).
// `page_size` is read by `init` only: the draw layer gives every page the same texture size.
set_settings :: proc(s: ^State, settings: Settings) {
	st := settings
	sanitize_settings(&st)
	atlas_lock(&s.atlas)
	old := s.settings
	if st.subpixel_steps != old.subpixel_steps || st.rendering != old.rendering || st.grid_fit != old.grid_fit || st.color_glyphs != old.color_glyphs ||
	   st.color_engine != old.color_engine || st.colr_samples != old.colr_samples {
		clear(&s.atlas.glyphs)
		clear(&s.atlas.fg_glyphs)
		s.atlas.settings_generation += 1
	}
	s.settings.subpixel_steps, s.settings.rendering, s.settings.grid_fit = st.subpixel_steps, st.rendering, st.grid_fit
	s.settings.color_glyphs, s.settings.max_gray_pages, s.settings.max_color_pages = st.color_glyphs, st.max_gray_pages, st.max_color_pages
	s.settings.color_async = st.color_async
	s.settings.color_engine, s.settings.colr_samples, s.settings.colr_cache_kb = st.color_engine, st.colr_samples, st.colr_cache_kb
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
	if s.tb != nil { s.tb.stop(s) }
	platform_stop(s)
	atlas_destroy(&s.atlas)
	n := sync.atomic_load(&s.count)
	for i in 1 ..< n { release_font(slot_ptr(s, i)) }
	for c in s.chunks { if c != nil { free(c) } }
	delete(s.free_slots)
	for k in s.keys { delete(k) }
	delete(s.keys)
	delete(s.emoji.path)
	platform_destroy(s)
	s^ = {}
}

@(private)
release_font :: proc(f: ^Font) {
	context.allocator = runtime.heap_allocator()
	if f == nil || f.kind == .None { return }
	face_colr_close(f)   // before the face: its tables belong to it
	when NATIVE_TEXT { native_face_release(f) }
	platform_release_face(f)
	delete(f.family)
	delete(f.cmap)
	for e in f.entries { delete(e.ranges) }
	delete(f.entries)
	delete(f.features)
	f^ = Font{kind = .None, dead = true, gen = f.gen}
}

@(private)
slot_ptr :: #force_inline proc "contextless" (s: ^State, i: int) -> ^Font {
	return &s.chunks[i / CHUNK][i % CHUNK]
}

// The slot of `id`, nil for an id that no font has (0, one out of range, one of a slot since given to another font).
@(private)
font_ptr :: #force_inline proc "contextless" (s: ^State, id: Font_Id) -> ^Font {
	i := int(id) & FONT_INDEX_MASK
	if i <= 0 || i >= sync.atomic_load(&s.count) { return nil }
	f := slot_ptr(s, i)
	if sync.atomic_load(&f.gen) != int(id) >> FONT_INDEX_BITS { return nil }
	return f
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
	if len(s.free_slots) > 0 {
		// the slot of an unloaded font: its generation moves first, so that the old ids stop reaching it before it is written
		i := pop(&s.free_slots)
		slot := slot_ptr(s, i)
		gen := slot.gen + 1
		sync.atomic_store(&slot.gen, gen)
		nf := f
		nf.gen = gen
		slot^ = nf
		return Font_Id(gen << FONT_INDEX_BITS | i)
	}
	n := s.count
	if n >= CHUNK * MAX_CHUNKS { return 0 }
	if s.chunks[n / CHUNK] == nil { s.chunks[n / CHUNK] = new([CHUNK]Font) }
	s.chunks[n / CHUNK][n % CHUNK] = f
	sync.atomic_store(&s.count, n + 1)
	return Font_Id(n)
}

// Publishes a face the platform made (`f.platform` filled, `f.upem` / `f.color` / `f.colr` as it knows them; takes
// what `f` holds, released on failure): the backend opens its side, then the face gets a slot. Shares an existing font
// made from the same `key`.
@(private)
publish_face :: proc(s: ^State, key: string, f: Font, family: string) -> Font_Id {
	context.allocator = runtime.heap_allocator()
	f := f
	f.kind = .Face
	f.family = to_wide(family)
	f.cmap = make([]u32, 65536 * 2 / 32)
	if !s.tb.face_open(s, &f) { release_font(&f); return 0 }
	f.fm = s.tb.face_metrics(s, &f)
	if f.fm.upem > 0 { f.upem = f32(f.fm.upem) }
	if f.upem <= 0 { f.upem = 1000 }   // neither the platform nor the backend said: no division by zero downstream
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
	fp := font_ptr(s, id)
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

// load_from_file, load_memory, load_system, has_system_family, with_simulations, axes and with_variations are the
// platform's (font_windows.odin, font_other.odin).

// Simulated styles of a face the font lacks (CSS font-synthesis): DirectWrite draws them; the native backend shapes
// with the regular face's advances.
Simulation :: enum u8 { Bold, Oblique }
Simulations :: bit_set[Simulation; u32]

// The axes of a variable face: tag, minimum, maximum and default value. Empty for a static face.
Axis :: struct { tag: [4]u8, min, max, default: f32 }

// Takes ownership of `data` (freed when the face is unloaded, or with the state).
load_from_memory :: proc(s: ^State, data: []byte, index := 0) -> (id: Font_Id, ok: bool) {
	return load_memory(s, data, true, index)
}

// A font compiled into the exe (`#load("x.ttf")`): read in place, never freed.
load_embedded :: proc(s: ^State, data: []byte) -> (id: Font_Id, ok: bool) {
	return load_memory(s, data, false)
}

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
		f.features = make([]Feature, len(features))
		copy(f.features, features)
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
		platform_forget_face(s, id)
		atlas_forget_face(&s.atlas, id)
	}
	sync.mutex_lock(&s.mu)
	dead := make([dynamic]string, context.temp_allocator)
	for k, v in s.keys { if v == id { append(&dead, k) } }
	for k in dead { delete_key(&s.keys, k); delete(k) }
	release_font(f)
	append(&s.free_slots, int(id) & FONT_INDEX_MASK)
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
	fm := f.fm
	m := Metrics{
		ascent = f32(fm.ascent) * k, descent = f32(fm.descent) * k,
		x_height = f32(fm.x_height) * k, cap_height = f32(fm.cap_height) * k,
		underline_offset = -f32(fm.underline_position) * k, underline_thickness = f32(fm.underline_thickness) * k,
		strike_offset = f32(fm.strike_position) * k, strike_thickness = f32(fm.strike_thickness) * k,
	}
	m.line_gap = f32(fm.line_gap) * k
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
	box, ok := s.tb.glyph_box(s, f, gp.id)
	if !ok { return g }
	k := size / f.upem
	left, right := box.x_min * k, box.x_max * k
	top, bottom := box.y_max * k, box.y_min * k
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
