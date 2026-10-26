//! The toolkit's native text backend: faces (read-fonts' font model: Fontations), shaping (HarfRust), line breaks
//! (ICU4X's segmenter, with its dictionaries for Thai, Lao, Khmer and Myanmar) and bidi levels (unicode-bidi on
//! ICU4X's property data), behind a C ABI called by font/backend_native.odin.
//!
//! Calls take whole runs (one shape call per run of one face, script and direction) and fill caller buffers; a call
//! whose buffer is too small returns the size it needs and writes nothing else. Every entry point catches panics: a
//! font the library cannot read gives no glyphs, never a dead application. Faces are immutable after `gt_face_open*`
//! and may be used from any number of threads at once.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use harfrust::{Buffer, BufferFlags, Direction, Feature, Language, Script, ShapeOptions, ShapePlan, ShapePlanKey, ShaperFont, Tag};
use read_fonts::model::glyph::outline::{DrawMemory, DrawOptions, PathSink};
use read_fonts::model::Font;
use read_fonts::types::GlyphId;
use read_fonts::{FontRef, TableProvider};

/// Bytes a face reads: a memory-mapped file or memory the caller keeps alive until gt_face_close.
struct Borrowed {
    ptr: *const u8,
    len: usize,
}
// The caller guarantees the bytes stay valid and unchanged while any face made from them lives.
unsafe impl Send for Borrowed {}
unsafe impl Sync for Borrowed {}
impl AsRef<[u8]> for Borrowed {
    fn as_ref(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

const MAX_PLANS: usize = 32;

pub struct Face {
    data: Arc<dyn AsRef<[u8]> + Send + Sync>,
    index: u32,
    font: Font,
    plans: Mutex<Vec<Arc<ShapePlan>>>,
}

#[repr(C)]
pub struct GtAxis {
    pub tag: [u8; 4],
    pub value: f32,
}

#[repr(C)]
pub struct GtFeature {
    pub tag: [u8; 4],
    pub value: u32,
}

/// One shaped glyph, font units. `cluster`: byte offset in the run's UTF-8 text of its cluster's first character.
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct GtGlyph {
    pub id: u32,
    pub cluster: u32,
    pub x_advance: f32,
    pub y_advance: f32,
    pub x_offset: f32,
    pub y_offset: f32,
    /// bit 0: the glyph has no ink (a space): asked for with `with_ink` (simulated bold widens inked glyphs only)
    pub flags: u32,
}

/// Font-wide metrics in font units (y up). `ascent` / `descent` / `line_gap` follow DirectWrite's rule (OS/2 typo
/// metrics when USE_TYPO_METRICS is set, else OS/2 win metrics with the line gap that keeps hhea's line height, else
/// hhea); the raw tables follow for callers that want another rule.
#[repr(C)]
#[derive(Default)]
pub struct GtMetrics {
    pub upem: i32,
    pub ascent: i32,
    pub descent: i32,
    pub line_gap: i32,
    pub cap_height: i32,
    pub x_height: i32,
    pub underline_position: i32,
    pub underline_thickness: i32,
    pub strike_position: i32,
    pub strike_thickness: i32,
    pub hhea_ascent: i32,
    pub hhea_descent: i32,
    pub hhea_line_gap: i32,
    pub typo_ascent: i32,
    pub typo_descent: i32,
    pub typo_line_gap: i32,
    pub win_ascent: i32,
    pub win_descent: i32,
    pub use_typo_metrics: i32,
    pub num_glyphs: i32,
}

#[repr(C)]
#[derive(Default)]
pub struct GtGlyphBox {
    pub advance: f32,
    pub x_min: f32,
    pub y_min: f32,
    pub x_max: f32,
    pub y_max: f32,
    pub empty: i32,
}

/// One path element of an outline, font units, y up. verb: 0 move, 1 line, 2 quad (p0 control, p1 end), 3 cubic (p0,
/// p1 controls, p2 end), 4 close.
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct GtPathEl {
    pub verb: u32,
    pub p: [[f32; 2]; 3],
}

/// A run of one script: UTF-8 bytes [start, end) and its ISO 15924 tag.
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct GtScriptRun {
    pub start: u32,
    pub end: u32,
    pub tag: [u8; 4],
}

fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 { &[] } else { std::slice::from_raw_parts(ptr, len) }
}

unsafe fn text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    std::str::from_utf8(bytes(ptr, len)).ok()
}

fn make_face(data: Arc<dyn AsRef<[u8]> + Send + Sync>, index: u32, axes: &[GtAxis]) -> Option<Box<Face>> {
    let blob: Arc<dyn AsRef<[u8]> + Send + Sync> = data.clone();
    let base = Font::new(blob, index)?;
    let font = if axes.is_empty() {
        base
    } else {
        let vars: Vec<(Tag, f32)> = axes.iter().map(|a| (Tag::new(&a.tag), a.value)).collect();
        base.instance_builder().variations(vars).build()
    };
    Some(Box::new(Face { data, index, font, plans: Mutex::new(Vec::new()) }))
}

/// A face of font data the caller keeps alive (and unchanged) until gt_face_close. `axes`: user-space variation
/// values (CSS font-variation-settings), none for the default instance. Null when the data holds no such face.
#[no_mangle]
pub unsafe extern "C" fn gt_face_open_memory(data: *const u8, len: usize, index: u32, axes: *const GtAxis, n_axes: usize) -> *mut Face {
    guard(std::ptr::null_mut(), || {
        if data.is_null() || len == 0 { return std::ptr::null_mut(); }
        let axes = if axes.is_null() { &[][..] } else { std::slice::from_raw_parts(axes, n_axes) };
        let src: Arc<dyn AsRef<[u8]> + Send + Sync> = Arc::new(Borrowed { ptr: data, len });
        make_face(src, index, axes).map_or(std::ptr::null_mut(), Box::into_raw)
    })
}

/// A face of a font file (UTF-8 path), memory-mapped for the life of the face.
#[no_mangle]
pub unsafe extern "C" fn gt_face_open_file(path: *const u8, path_len: usize, index: u32, axes: *const GtAxis, n_axes: usize) -> *mut Face {
    guard(std::ptr::null_mut(), || {
        let Some(path) = text(path, path_len) else { return std::ptr::null_mut() };
        let Ok(file) = std::fs::File::open(path) else { return std::ptr::null_mut() };
        // the file may change on disk while mapped (a font being replaced): what Fontations reads is checked as it goes
        let Ok(map) = (unsafe { memmap2::Mmap::map(&file) }) else { return std::ptr::null_mut() };
        let axes = if axes.is_null() { &[][..] } else { std::slice::from_raw_parts(axes, n_axes) };
        let src: Arc<dyn AsRef<[u8]> + Send + Sync> = Arc::new(map);
        make_face(src, index, axes).map_or(std::ptr::null_mut(), Box::into_raw)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gt_face_close(face: *mut Face) {
    if face.is_null() { return; }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(face))));
}

#[no_mangle]
pub unsafe extern "C" fn gt_face_metrics(face: *const Face, out: *mut GtMetrics) -> i32 {
    guard(0, || {
        let (Some(face), Some(out)) = (face.as_ref(), out.as_mut()) else { return 0 };
        let m = face.font.metrics();
        let sm = face.font.style_metrics();
        let r = |v: f64| v.round() as i32;
        let mut g = GtMetrics { upem: m.units_per_em as i32, num_glyphs: m.num_glyphs as i32, ..Default::default() };
        if let Some(h) = m.hhea_line {
            g.hhea_ascent = r(h.ascender.to_f64());
            g.hhea_descent = r(-h.descender.to_f64());
            g.hhea_line_gap = r(h.line_gap.to_f64());
        }
        if let Some(t) = m.typo_line {
            g.typo_ascent = r(t.ascender.to_f64());
            g.typo_descent = r(-t.descender.to_f64());
            g.typo_line_gap = r(t.line_gap.to_f64());
        }
        if let Some(w) = m.win_line {
            g.win_ascent = r(w.ascender.to_f64());
            g.win_descent = r(-w.descender.to_f64());
        }
        g.use_typo_metrics = m.use_typo_metrics as i32;
        if m.use_typo_metrics && m.typo_line.is_some() {
            (g.ascent, g.descent, g.line_gap) = (g.typo_ascent, g.typo_descent, g.typo_line_gap);
        } else if m.win_line.is_some() {
            g.ascent = g.win_ascent;
            g.descent = g.win_descent;
            g.line_gap = ((g.hhea_ascent + g.hhea_descent + g.hhea_line_gap) - (g.win_ascent + g.win_descent)).max(0);
        } else {
            (g.ascent, g.descent, g.line_gap) = (g.hhea_ascent, g.hhea_descent, g.hhea_line_gap);
        }
        g.cap_height = m.cap_height.map_or(0, |v| r(v.to_f64()));
        g.x_height = m.x_height.map_or(0, |v| r(v.to_f64()));
        if let Some(u) = sm.underline {
            g.underline_position = r(u.position.to_f64());
            g.underline_thickness = r(u.thickness.to_f64());
        }
        if let Some(s) = sm.strike_through {
            g.strike_position = r(s.position.to_f64());
            g.strike_thickness = r(s.thickness.to_f64());
        }
        *out = g;
        1
    })
}

/// The glyphs of `count` code points (0: none), into `out`. Returns 1.
#[no_mangle]
pub unsafe extern "C" fn gt_face_glyphs(face: *const Face, cps: *const u32, count: usize, out: *mut u32) -> i32 {
    guard(0, || {
        let Some(face) = face.as_ref() else { return 0 };
        if count == 0 { return 1; }
        if cps.is_null() || out.is_null() { return 0; }
        let cps = std::slice::from_raw_parts(cps, count);
        let out = std::slice::from_raw_parts_mut(out, count);
        let cmap = face.font.charmap();
        for (o, &c) in out.iter_mut().zip(cps) {
            *o = cmap.map_unicode(c).map_or(0, |g| g.to_u32());
        }
        1
    })
}

/// The face's coverage as inclusive code point ranges [first, last] into `out` (2 per range). Returns the number of
/// ranges (more than `cap`: nothing written past it, call again with that much room).
#[no_mangle]
pub unsafe extern "C" fn gt_face_coverage(face: *const Face, out: *mut [u32; 2], cap: usize) -> usize {
    guard(0, || {
        let Some(face) = face.as_ref() else { return 0 };
        let mut cps: Vec<u32> = face.font.charmap().unicodes().filter(|(_, g)| g.to_u32() != 0).map(|(c, _)| c).collect();
        cps.sort_unstable();
        cps.dedup();
        let mut ranges: Vec<[u32; 2]> = Vec::new();
        for c in cps {
            match ranges.last_mut() {
                Some(r) if r[1] + 1 == c => r[1] = c,
                _ => ranges.push([c, c]),
            }
        }
        if !out.is_null() && ranges.len() <= cap {
            std::ptr::copy_nonoverlapping(ranges.as_ptr(), out, ranges.len());
        }
        ranges.len()
    })
}

#[no_mangle]
pub unsafe extern "C" fn gt_glyph_box(face: *const Face, gid: u32, out: *mut GtGlyphBox) -> i32 {
    guard(0, || {
        let (Some(face), Some(out)) = (face.as_ref(), out.as_mut()) else { return 0 };
        let gm = face.font.glyph_metrics();
        let g = GlyphId::new(gid);
        let mut b = GtGlyphBox { advance: gm.h_advance(g), empty: 1, ..Default::default() };
        if let Some(e) = gm.extents(g) {
            if e.width != 0.0 && e.height != 0.0 {
                // extents: y_bearing is the top, height negative downwards (HarfBuzz's convention)
                b.x_min = e.x_bearing;
                b.x_max = e.x_bearing + e.width;
                b.y_max = e.y_bearing;
                b.y_min = e.y_bearing + e.height;
                if b.y_min > b.y_max { std::mem::swap(&mut b.y_min, &mut b.y_max); }
                b.empty = 0;
            }
        }
        *out = b;
        1
    })
}

struct PathOut {
    els: Vec<GtPathEl>,
}

impl PathSink for PathOut {
    fn move_to(&mut self, x: f32, y: f32) {
        self.els.push(GtPathEl { verb: 0, p: [[x, y], [0.0; 2], [0.0; 2]] });
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.els.push(GtPathEl { verb: 1, p: [[x, y], [0.0; 2], [0.0; 2]] });
    }
    fn quad_to(&mut self, cx0: f32, cy0: f32, x: f32, y: f32) {
        self.els.push(GtPathEl { verb: 2, p: [[cx0, cy0], [x, y], [0.0; 2]] });
    }
    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        self.els.push(GtPathEl { verb: 3, p: [[cx0, cy0], [cx1, cy1], [x, y]] });
    }
    fn close(&mut self) {
        self.els.push(GtPathEl { verb: 4, p: [[0.0; 2]; 3] });
    }
}

/// The unhinted outline of a glyph in font units (y up) into `out`. Returns the number of elements (more than `cap`:
/// call again with that much room), or -1 when the face has no outline for it.
#[no_mangle]
pub unsafe extern "C" fn gt_glyph_outline(face: *const Face, gid: u32, out: *mut GtPathEl, cap: usize) -> isize {
    guard(-1, || {
        let Some(face) = face.as_ref() else { return -1 };
        let glyphs = face.font.outline_glyphs();
        let Some(g) = glyphs.get(GlyphId::new(gid)) else { return -1 };
        let mut sink = PathOut { els: Vec::new() };
        if g.draw(&DrawOptions::default(), DrawMemory::Scratch, &mut sink).is_err() { return -1; }
        if !out.is_null() && sink.els.len() <= cap {
            std::ptr::copy_nonoverlapping(sink.els.as_ptr(), out, sink.els.len());
        }
        sink.els.len() as isize
    })
}

/// The raw bytes of a table of the face (`tag` as 4 bytes): the COLR / CPAL tables the toolkit's own COLR interpreter
/// reads, the same on every platform. 0: no such table. The pointer lives as long as the face.
#[no_mangle]
pub unsafe extern "C" fn gt_face_table(face: *const Face, tag: *const [u8; 4], data: *mut *const u8, len: *mut usize) -> i32 {
    guard(0, || {
        let (Some(face), Some(tag), Some(data), Some(len)) = (face.as_ref(), tag.as_ref(), data.as_mut(), len.as_mut()) else { return 0 };
        let bytes = (*face.data).as_ref();
        let Ok(fr) = FontRef::from_index(bytes, face.index) else { return 0 };
        let Some(t) = fr.table_data(Tag::new(tag)) else { return 0 };
        let b = t.as_bytes();
        *data = b.as_ptr();
        *len = b.len();
        1
    })
}

/// Color glyph format of a glyph: 0 none, 1 COLR v0 layers, 2 COLR v1 paint graph.
#[no_mangle]
pub unsafe extern "C" fn gt_color_glyph(face: *const Face, gid: u32) -> i32 {
    guard(0, || {
        let Some(face) = face.as_ref() else { return 0 };
        let Ok(fr) = face.font_ref() else { return 0 };
        let Ok(colr) = fr.colr() else { return 0 };
        let g = GlyphId::new(gid);
        if colr.v1_base_glyph(g).is_some() { return 2; }
        if colr.v0_base_glyph(g).is_some() { return 1; }
        0
    })
}

/// Colors of a CPAL palette as RGBA bytes into `out`. Returns the number of entries (more than `cap`: call again).
#[no_mangle]
pub unsafe extern "C" fn gt_palette(face: *const Face, palette: u32, out: *mut [u8; 4], cap: usize) -> usize {
    guard(0, || {
        let Some(face) = face.as_ref() else { return 0 };
        let Some(p) = face.font.palettes().get(palette) else { return 0 };
        let colors = p.colors();
        if !out.is_null() && colors.len() <= cap {
            for (i, c) in colors.iter().enumerate() {
                *out.add(i) = [c.red, c.green, c.blue, c.alpha];
            }
        }
        colors.len()
    })
}

impl Face {
    fn font_ref(&self) -> Result<FontRef<'_>, ()> {
        FontRef::from_index((*self.data).as_ref(), self.index).map_err(|_| ())
    }

    fn plan(&self, sf: &ShaperFont, dir: Direction, script: Option<Script>, lang: Option<&Language>, feats: &[Feature]) -> Arc<ShapePlan> {
        let key = ShapePlanKey::new(&self.font, script, dir).language(lang).features(feats);
        if let Ok(plans) = self.plans.lock() {
            if let Some(p) = plans.iter().find(|p| key.matches(p)) { return p.clone(); }
        }
        let _ = sf;
        let plan = Arc::new(ShapePlan::new(&self.font, dir, script, lang, feats));
        if let Ok(mut plans) = self.plans.lock() {
            if plans.len() >= MAX_PLANS { plans.remove(0); }
            plans.push(plan.clone());
        }
        plan
    }
}

thread_local! {
    static BUFFER: std::cell::RefCell<Option<Buffer>> = const { std::cell::RefCell::new(None) };
}

/// Shapes one run: UTF-8 `text`, one direction (`rtl`), one script (ISO 15924 tag; zero bytes: guessed from the text),
/// a BCP 47 `lang` (empty: none) and OpenType features (applied to the whole run). Glyphs come in visual order (left to
/// right), positions in font units. Returns the number of glyphs (more than `cap`: nothing written, call again with
/// that much room), or -1 on failure.
#[no_mangle]
pub unsafe extern "C" fn gt_shape(
    face: *const Face, text_ptr: *const u8, text_len: usize, script: *const [u8; 4], lang_ptr: *const u8, lang_len: usize,
    rtl: i32, feats: *const GtFeature, n_feats: usize, with_ink: i32, out: *mut GtGlyph, cap: usize,
) -> isize {
    guard(-1, || {
        let Some(face) = face.as_ref() else { return -1 };
        let Some(s) = text(text_ptr, text_len) else { return -1 };
        let dir = if rtl != 0 { Direction::RightToLeft } else { Direction::LeftToRight };
        let script = script.as_ref().filter(|t| **t != [0; 4]).and_then(|t| Script::from_iso15924_tag(Tag::new(t)));
        let lang = text(lang_ptr, lang_len).filter(|l| !l.is_empty()).and_then(Language::new);
        let feats: Vec<Feature> = if feats.is_null() { Vec::new() } else {
            std::slice::from_raw_parts(feats, n_feats).iter().map(|f| Feature::new(Tag::new(&f.tag), f.value, ..)).collect()
        };
        BUFFER.with(|cell| {
            let mut slot = cell.borrow_mut();
            let mut buf = slot.take().unwrap_or_default();
            buf.clear();
            buf.push_str(s);
            buf.set_direction(dir);
            buf.set_flags(BufferFlags::BEGINNING_OF_TEXT | BufferFlags::END_OF_TEXT);
            if script.is_some() { buf.set_script(script); }
            if let Some(l) = lang.clone() { buf.set_language(Some(l)); }
            buf.guess_segment_properties();
            let sf = ShaperFont::new(&face.font);
            let plan = face.plan(&sf, buf.direction(), buf.script(), buf.language(), &feats);
            let ok = harfrust::shape(&sf, &mut buf, ShapeOptions::new().plan(Some(&plan)).features(&feats)).is_ok();
            let n = buf.len();
            if ok && !out.is_null() && n <= cap {
                let out = std::slice::from_raw_parts_mut(out, n);
                let gm = (with_ink != 0).then(|| face.font.glyph_metrics());
                for ((o, i), p) in out.iter_mut().zip(buf.glyph_infos()).zip(buf.glyph_positions()) {
                    let empty = gm.as_ref().map_or(false, |m| {
                        m.extents(GlyphId::new(i.glyph_id)).map_or(true, |e| e.width == 0.0 || e.height == 0.0)
                    });
                    *o = GtGlyph {
                        id: i.glyph_id, cluster: i.cluster,
                        x_advance: p.x_advance as f32, y_advance: p.y_advance as f32,
                        x_offset: p.x_offset as f32, y_offset: p.y_offset as f32,
                        flags: empty as u32,
                    };
                }
            }
            *slot = Some(buf);
            if ok { n as isize } else { -1 }
        })
    })
}

/// Script runs of UTF-8 `text`: characters of the Common and Inherited scripts join the run around them (the one
/// before, else the one after). Returns the number of runs (more than `cap`: call again).
#[no_mangle]
pub unsafe extern "C" fn gt_scripts(text_ptr: *const u8, text_len: usize, out: *mut GtScriptRun, cap: usize) -> usize {
    guard(0, || {
        let Some(s) = text(text_ptr, text_len) else { return 0 };
        let mut runs: Vec<GtScriptRun> = Vec::new();
        let common = |t: Tag| t == Script::COMMON.tag() || t == Script::INHERITED.tag() || t == Script::UNKNOWN.tag();
        for (i, c) in s.char_indices() {
            let t = harfrust::unicode::script(c as u32).tag();
            let end = (i + c.len_utf8()) as u32;
            match runs.last_mut() {
                Some(r) if common(t) => r.end = end,
                Some(r) if Tag::new(&r.tag) == t => r.end = end,
                Some(r) if common(Tag::new(&r.tag)) => { r.tag = t.to_be_bytes(); r.end = end; }
                _ => runs.push(GtScriptRun { start: i as u32, end, tag: t.to_be_bytes() }),
            }
        }
        // a leading run of Common characters took its script from nothing: the run after it
        if runs.len() > 1 && common(Tag::new(&runs[0].tag)) {
            runs[1].start = 0;
            runs.remove(0);
        }
        if !out.is_null() && runs.len() <= cap {
            std::ptr::copy_nonoverlapping(runs.as_ptr(), out, runs.len());
        }
        runs.len()
    })
}

/// UAX #9 embedding levels of every byte of UTF-8 `text` (one paragraph or more: each takes `base`: 0 left to right,
/// 1 right to left, 255 from its first strong character) into `levels` (`text_len` bytes). Returns 1.
#[no_mangle]
pub unsafe extern "C" fn gt_bidi_levels(text_ptr: *const u8, text_len: usize, base: u8, levels: *mut u8) -> i32 {
    guard(0, || {
        let Some(s) = text(text_ptr, text_len) else { return 0 };
        if levels.is_null() { return 0; }
        let out = std::slice::from_raw_parts_mut(levels, text_len);
        let level = match base {
            0 => Some(unicode_bidi::Level::ltr()),
            1 => Some(unicode_bidi::Level::rtl()),
            _ => None,
        };
        let data = icu_properties::CodePointMapData::<icu_properties::props::BidiClass>::new();
        let info = unicode_bidi::BidiInfo::new_with_data_source(&data, s, level);
        for (o, l) in out.iter_mut().zip(info.levels.iter()) {
            *o = l.number();
        }
        1
    })
}

fn segmenter() -> &'static icu_segmenter::LineSegmenterBorrowed<'static> {
    static SEG: std::sync::OnceLock<icu_segmenter::LineSegmenterBorrowed<'static>> = std::sync::OnceLock::new();
    SEG.get_or_init(|| icu_segmenter::LineSegmenter::new_dictionary(Default::default()))
}

/// UAX #14 line break opportunities of UTF-8 `text` (dictionaries for Thai, Lao, Khmer, Myanmar): byte offsets
/// before which a line may break, without 0 and the end; bit 31 set for a mandatory break. Returns the count (more than
/// `cap`: call again).
#[no_mangle]
pub unsafe extern "C" fn gt_line_breaks(text_ptr: *const u8, text_len: usize, out: *mut u32, cap: usize) -> usize {
    guard(0, || {
        let Some(s) = text(text_ptr, text_len) else { return 0 };
        let mut v: Vec<u32> = Vec::new();
        for b in segmenter().segment_str(s) {
            if b == 0 || b >= s.len() { continue; }
            let prev = s[..b].chars().next_back().unwrap_or(' ');
            let hard = matches!(prev, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}');
            v.push(b as u32 | if hard { 1 << 31 } else { 0 });
        }
        if !out.is_null() && v.len() <= cap {
            std::ptr::copy_nonoverlapping(v.as_ptr(), out, v.len());
        }
        v.len()
    })
}

/// The PostScript name of a face (UTF-8) into `out`. Returns its length (more than `cap`: nothing written), 0: none.
/// Used where the system names a font by its PostScript name and a file holds several faces (macOS' .ttc files).
#[no_mangle]
pub unsafe extern "C" fn gt_face_postscript_name(face: *const Face, out: *mut u8, cap: usize) -> usize {
    guard(0, || {
        let Some(face) = face.as_ref() else { return 0 };
        let Ok(fr) = face.font_ref() else { return 0 };
        let Ok(name) = fr.name() else { return 0 };
        let data = name.string_data();
        for rec in name.name_record() {
            if rec.name_id() != read_fonts::types::NameId::POSTSCRIPT_NAME { continue; }
            let Ok(s) = rec.string(data) else { continue };
            let s: String = s.chars().collect();
            if s.is_empty() { continue; }
            if !out.is_null() && s.len() <= cap { std::ptr::copy_nonoverlapping(s.as_ptr(), out, s.len()); }
            return s.len();
        }
        0
    })
}

/// The number of faces in a font file (a collection: several; 0: not a font).
#[no_mangle]
pub unsafe extern "C" fn gt_file_face_count(path: *const u8, path_len: usize) -> u32 {
    guard(0, || {
        let Some(path) = text(path, path_len) else { return 0 };
        let Ok(file) = std::fs::File::open(path) else { return 0 };
        let Ok(map) = (unsafe { memmap2::Mmap::map(&file) }) else { return 0 };
        match read_fonts::FileRef::new(&map) {
            Ok(read_fonts::FileRef::Font(_)) => 1,
            Ok(read_fonts::FileRef::Collection(c)) => c.len(),
            Err(_) => 0,
        }
    })
}

/// Version of the library's API (the Odin side checks it at start).
#[no_mangle]
pub extern "C" fn gt_text_version() -> u32 {
    2
}
