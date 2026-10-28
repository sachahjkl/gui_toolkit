package font

import "base:runtime"

// Text backends: who shapes, analyses (scripts, bidi, line breaks) and reads the faces (coverage, metrics, outlines).
// The rest of the package (cascades, the word cache, clusters and carets, the atlas, Slug, the COLR interpreter) only
// talks to a backend through `Text_Backend`, and to the system's fonts through `System_Fonts`:
//
//   dwrite  DirectWrite (backend_dwrite.odin): Windows' shaper and analyzers. The default.
//   native  Fontations (skrifa, read-fonts), HarfRust and ICU4X in a static Rust library (native/text, backend_native.odin):
//           the same code on every platform. Linked only by builds with -define:FONT_BACKEND=native, which then make it
//           the default (Settings.backend still picks either for one State: the text_backends test compares them).
//
// Finding and listing the system's fonts and the fallback font of a character stay the platform's own whatever the
// backend (DirectWrite on Windows; fontconfig and CoreText to come): `System_Fonts`. Faces are always opened by the
// platform first (DirectWrite's face is what the atlas rasterizes and Direct2D draws in color); the native backend then
// opens the same file or bytes in Fontations. See docs/font-backend.md.

Backend :: enum u8 { Dwrite, Native }

FONT_BACKEND :: #config(FONT_BACKEND, "dwrite")
#assert(FONT_BACKEND == "dwrite" || FONT_BACKEND == "native", "FONT_BACKEND is dwrite or native")

// Whether the native library is linked into this build.
NATIVE_TEXT :: FONT_BACKEND == "native"

when NATIVE_TEXT {
	@(private) BUILD_BACKEND :: Backend.Native
} else {
	@(private) BUILD_BACKEND :: Backend.Dwrite
}

// Whether `b` can serve in this build (Native: only with -define:FONT_BACKEND=native).
backend_available :: proc(b: Backend) -> bool {
	switch b {
	case .Dwrite: return ODIN_OS == .Windows
	case .Native: return NATIVE_TEXT
	}
	return false
}

// The backend a State uses (Settings.backend, or the first available one when that one is not).
backend :: proc(s: ^State) -> Backend { return s.backend }

// A run of one script inside the text being shaped: UTF-16 units [start, end) of it, the script's ISO 15924 tag
// ("Latn", "Arab", "Zyyy" when unknown) and what the backend keeps for it (DirectWrite: its DWRITE_SCRIPT_ANALYSIS).
Script_Item :: struct {
	start, end: u32,
	tag:        [4]u8,
	data:       u64,
}

// Design metrics of a face (font units, y up; descent positive below the baseline), as a backend reads them.
Face_Metrics :: struct {
	upem:                 i32,
	ascent, descent:      i32,
	line_gap:             i32,
	cap_height, x_height: i32,
	underline_position:   i32,   // above the baseline (negative: below)
	underline_thickness:  i32,
	strike_position:      i32,
	strike_thickness:     i32,
}

// The design box of one glyph (font units, y up from the baseline) and its advance.
Glyph_Box :: struct {
	advance:                f32,
	x_min, y_min, x_max, y_max: f32,
	empty:                  bool,
}

// What one call of `Text_Backend.shape` shapes: one face, one script, one direction.
Shape_Request :: struct {
	face_id:  Font_Id,
	face:     ^Font,
	size:     f32,
	text:     string,    // the piece, UTF-8
	w:        []u16,     // the piece, UTF-16
	bytes:    []i32,     // byte index in `text` of each unit of `w` (from the word's start), plus one past the end
	rtl:      bool,
	script:   Script_Item,
	features: []Feature, // the cascade's, then liga / clig / dlig / hlig off under letter-spacing
	lang:     string,    // BCP 47 language of the cascade (locale forms, `locl`), "" none
}

// The procedures of a backend. Every one may run on any thread at once.
Text_Backend :: struct {
	name:         string,
	// Starts / stops what the backend keeps per State (false: not usable; the State then has no text).
	start:        proc(s: ^State) -> bool,
	stop:         proc(s: ^State),
	// Opens the backend's side of a face the platform just made (`f` is not published yet); false: unusable face.
	face_open:    proc(s: ^State, f: ^Font) -> bool,
	face_close:   proc(f: ^Font),
	// Whether the face maps `r` to a glyph other than .notdef.
	has_glyph:    proc(s: ^State, f: ^Font, r: rune) -> bool,
	face_metrics: proc(s: ^State, f: ^Font) -> Face_Metrics,
	glyph_box:    proc(s: ^State, f: ^Font, gid: u16) -> (Glyph_Box, bool),
	// Script runs of `w` (UTF-16 of `text`, `bytes` as in Shape_Request; `rtl`: the run's direction). false: no
	// analysis (one unknown run).
	scripts:      proc(s: ^State, text: string, w: []u16, bytes: []i32, rtl: bool, out: ^[dynamic]Script_Item) -> bool,
	// Appends the glyphs of the request in visual order from `pen` (cluster bytes relative to the word, x from the
	// line's origin) and its clusters in logical order. Returns the pen after it.
	shape:        proc(s: ^State, req: ^Shape_Request, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> f32,
	// UAX #9 levels of each byte of `text` (one paragraph, base direction `rtl`), into `levels` (filled with the base
	// level on entry). false: no analysis.
	bidi:         proc(s: ^State, text: string, rtl: bool, levels: []u8) -> bool,
	// UAX #14 opportunities inside `text`, in order, without the start of the text.
	line_breaks:  proc(s: ^State, text: string, out: ^[dynamic]Break_Opportunity) -> bool,
	// Glyph outlines for Slug (Outline_Provider).
	outline:      Outline_Provider,
}

// The system's fonts: what the platform finds, whatever the backend.
System_Fonts :: struct {
	name:      string,
	// Faces for the characters of w[a:b] that `faces` leaves at 0, from the system fallback, based on `first`'s family,
	// weight and style.
	fallback:  proc(s: ^State, first: Font_Id, w: []u16, a, b: int, faces: []Font_Id),
	// Family names of the installed fonts.
	families:  proc(s: ^State, allocator: runtime.Allocator) -> []string,
}

// Families of the system's installed fonts (sorted, no duplicates; empty when the platform has none to give).
system_families :: proc(s: ^State, allocator := context.allocator) -> []string {
	if s.system_fonts == nil || s.system_fonts.families == nil { return nil }
	return s.system_fonts.families(s, allocator)
}

// The outline of glyph `gid` of face `face` (the backend's provider, DirectWrite or the native Fontations backend),
// filled into `out` in font units up to `tolerance`; false when the backend has none (an application that draws glyph
// paths, such as a 2D canvas, calls this instead of a backend's own provider). The same shape on every system.
glyph_outline :: proc(s: ^State, face: Font_Id, gid: u16, tolerance: f32, out: ^Outline) -> bool {
	if s == nil || s.tb.outline == nil { return false }
	return s.tb.outline(s, face, gid, tolerance, out)
}

// The design metrics a face's backend reads (zero for an id that is not a live face).
face_metrics :: proc(s: ^State, id: Font_Id) -> Face_Metrics {
	f := face_ptr(s, primary_face(s, id))
	if f == nil { return {} }
	return f.fm
}

// Backend procedures that do nothing: the table of a platform without a backend (and the base of partial ones).
@(private)
none_backend := Text_Backend{
	name = "none",
	start = proc(s: ^State) -> bool { return false },
	stop = proc(s: ^State) {},
	face_open = proc(s: ^State, f: ^Font) -> bool { return false },
	face_close = proc(f: ^Font) {},
	has_glyph = proc(s: ^State, f: ^Font, r: rune) -> bool { return false },
	face_metrics = proc(s: ^State, f: ^Font) -> Face_Metrics { return {} },
	glyph_box = proc(s: ^State, f: ^Font, gid: u16) -> (Glyph_Box, bool) { return {}, false },
	scripts = proc(s: ^State, text: string, w: []u16, bytes: []i32, rtl: bool, out: ^[dynamic]Script_Item) -> bool { return false },
	shape = proc(s: ^State, req: ^Shape_Request, glyphs: ^[dynamic]Glyph_Pos, clusters: ^[dynamic]Cluster, pen: f32) -> f32 { return pen },
	bidi = proc(s: ^State, text: string, rtl: bool, levels: []u8) -> bool { return false },
	line_breaks = proc(s: ^State, text: string, out: ^[dynamic]Break_Opportunity) -> bool { return false },
	outline = nil,
}

// The procedure table of `b` in this build (none_backend when it is not available).
@(private)
backend_table :: proc(b: Backend) -> ^Text_Backend {
	switch b {
	case .Dwrite: when ODIN_OS == .Windows { return &dwrite_backend }
	case .Native: when NATIVE_TEXT { return &native_backend }
	}
	return &none_backend
}
