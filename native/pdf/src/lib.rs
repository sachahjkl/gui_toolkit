//! The toolkit's PDF engine (src/pdf, src/md/features/pdf.md): open a file as a source, render a page, write a new
//! file from a list of pages. hayro reads and renders, pdf-writer writes. The C API below is all `gt_pdf_*`; every
//! entry point catches panics, so a page that fails is a page not drawn, never a dead program.

mod afm;
mod face;
mod render;
mod shape;
mod stamp;
mod write;

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use afm::Font;
use face::Face;
use hayro::hayro_syntax::{DecryptionError, LoadPdfError, Pdf};
use shape::{Kind, Shape};
use stamp::Stamp;
use write::PageSpec;

// The open sources by id (0 is never one: a blank page's). A source is shared by the threads that render from it.
struct Sources {
    next: u32,
    open: HashMap<u32, Arc<Pdf>>,
}

fn sources() -> &'static Mutex<Sources> {
    static SOURCES: OnceLock<Mutex<Sources>> = OnceLock::new();
    SOURCES.get_or_init(|| Mutex::new(Sources { next: 1, open: HashMap::new() }))
}

fn source(id: u32) -> Option<Arc<Pdf>> {
    sources().lock().ok()?.open.get(&id).cloned()
}

/// What `gt_pdf_open` says: 0 opened, 1 not a PDF or damaged, 2 a password is needed or wrong, 3 an encryption hayro
/// does not know, 4 the engine failed.
pub const OPENED: i32 = 0;
pub const FORMAT: i32 = 1;
pub const PASSWORD: i32 = 2;
pub const SECURITY: i32 = 3;
pub const FAILED: i32 = 4;

/// A stamp as the C API gives it (src/pdf/pdf.odin's Stamp).
#[repr(C)]
pub struct GtPdfStamp {
    pub x: f32,
    pub y: f32,
    pub size: f32,
    pub turns: u32,
    /// The family (0 sans, 1 serif, 2 mono), plus 4 bold, plus 8 italic.
    pub font: u32,
    /// 0xRRGGBB.
    pub color: u32,
    /// 0xRRGGBBAA; alpha 0: none.
    pub background: u32,
    pub text: *const u8,
    pub text_len: usize,
    /// A font `gt_pdf_font_add` gave (0: the standard `font`).
    pub face: u32,
    /// Degrees the text rises to the right.
    pub tilt: f32,
    /// The pen's weight, in thousandths of the size.
    pub weight: f32,
    /// 1: a flourish under the text.
    pub flags: u32,
    /// A line under it, in Helvetica, smaller (UTF-8; empty: none).
    pub caption: *const u8,
    pub caption_len: usize,
}

/// A page as the C API gives it: a page of source `source` (0: a blank page of `width` by `height` points).
#[repr(C)]
pub struct GtPdfPage {
    pub source: u32,
    pub index: u32,
    pub turns: u32,
    pub width: f32,
    pub height: f32,
    pub stamps: *const GtPdfStamp,
    pub stamp_count: usize,
    pub shapes: *const GtPdfShape,
    pub shape_count: usize,
}

/// A shape as the C API gives it (src/pdf/pdf.odin's Shape).
#[repr(C)]
pub struct GtPdfShape {
    /// 0 rectangle, 1 ellipse, 2 line, 3 arrow, 4 free line, 5 filled outlines (NaN x: the next one).
    pub kind: u32,
    /// 0xRRGGBBAA; alpha 0: none.
    pub stroke: u32,
    pub fill: u32,
    pub width: f32,
    /// x, y pairs.
    pub points: *const f32,
    pub point_count: usize,
}

// A page's data read from the C API, its source still to be found.
struct Page_ {
    source: u32,
    index: usize,
    turns: u8,
    size: (f32, f32),
    stamps: Vec<Stamp>,
    shapes: Vec<Shape>,
}

unsafe fn shape_of(s: &GtPdfShape) -> Option<Shape> {
    let rgba = |v: u32| [(v >> 24) as u8, (v >> 16) as u8, (v >> 8) as u8, v as u8];
    let kind = Kind::from_code(s.kind)?;
    let flat = if s.points.is_null() || s.point_count == 0 { &[][..] } else { std::slice::from_raw_parts(s.points, s.point_count * 2) };
    let points: Vec<(f32, f32)> = flat.chunks_exact(2).map(|c| (c[0], c[1])).collect();
    if points.is_empty() {
        return None;
    }
    Some(Shape { kind, points, stroke: rgba(s.stroke), fill: rgba(s.fill), width: s.width })
}

unsafe fn bytes<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if p.is_null() || n == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, n)
    }
}

unsafe fn stamp_of(s: &GtPdfStamp) -> Stamp {
    let rgb = |v: u32| [(v >> 16) as u8, (v >> 8) as u8, v as u8];
    Stamp {
        x: s.x,
        y: s.y,
        turns: (s.turns % 4) as u8,
        font: Font::from_code(s.font),
        size: s.size,
        color: rgb(s.color),
        background: if s.background & 0xFF == 0 { None } else { Some(rgb(s.background >> 8)) },
        text: String::from_utf8_lossy(bytes(s.text, s.text_len)).into_owned(),
        face: if s.face == 0 { None } else { face(s.face).map(|f| (s.face, f)) },
        tilt: if s.tilt.is_finite() { s.tilt.clamp(-45.0, 45.0) } else { 0.0 },
        weight: if s.weight.is_finite() { s.weight.clamp(0.0, 200.0) } else { 0.0 },
        underline: s.flags & 1 != 0,
        caption: String::from_utf8_lossy(bytes(s.caption, s.caption_len)).into_owned(),
    }
}

// The fonts the program gave, by id (0 is never one: the standard fonts). Kept for the process's life: a font is a
// program's few files, given once.
fn faces() -> &'static Mutex<HashMap<u32, Arc<Face>>> {
    static FACES: OnceLock<Mutex<HashMap<u32, Arc<Face>>>> = OnceLock::new();
    FACES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn face(id: u32) -> Option<Arc<Face>> {
    faces().lock().ok()?.get(&id).cloned()
}

/// Reads a TrueType or OpenType font in `data` (copied) for stamps to use; its id in `out`. False: not a font.
#[no_mangle]
pub unsafe extern "C" fn gt_pdf_font_add(data: *const u8, len: usize, out: *mut u32) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(f) = Face::new(bytes(data, len).to_vec()) else { return false };
        let Ok(mut all) = faces().lock() else { return false };
        let id = all.len() as u32 + 1;
        all.insert(id, Arc::new(f));
        if !out.is_null() {
            *out = id;
        }
        true
    }))
    .unwrap_or(false)
}

// The C pages with their sources held for as long as the work lasts.
unsafe fn pages_of(pages: *const GtPdfPage, count: usize) -> Option<(Vec<Arc<Pdf>>, Vec<Page_>)> {
    if pages.is_null() && count > 0 {
        return None;
    }
    let list = if count == 0 { &[][..] } else { std::slice::from_raw_parts(pages, count) };
    let mut held = Vec::new();
    let mut out = Vec::with_capacity(list.len());
    for p in list {
        if p.source != 0 {
            held.push(source(p.source)?);
        }
        let stamps = if p.stamps.is_null() || p.stamp_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(p.stamps, p.stamp_count).iter().map(|s| stamp_of(s)).collect()
        };
        let shapes = if p.shapes.is_null() || p.shape_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(p.shapes, p.shape_count).iter().filter_map(|s| shape_of(s)).collect()
        };
        out.push(Page_ { source: p.source, index: p.index as usize, turns: (p.turns % 4) as u8, size: (p.width, p.height), stamps, shapes });
    }
    Some((held, out))
}

fn specs<'a>(held: &'a [Arc<Pdf>], pages: Vec<Page_>) -> Vec<PageSpec<'a>> {
    let mut next = 0;
    pages
        .into_iter()
        .map(|p| {
            let source = if p.source != 0 {
                let pdf = &*held[next];
                next += 1;
                Some((p.source, pdf))
            } else {
                None
            };
            PageSpec { source, index: p.index, turns: p.turns, size: p.size, stamps: p.stamps, shapes: p.shapes }
        })
        .collect()
}

/// Opens the PDF in `data` (copied) with `password` (UTF-8, may be empty); its id in `out`.
#[no_mangle]
pub unsafe extern "C" fn gt_pdf_open(data: *const u8, len: usize, password: *const u8, password_len: usize, out: *mut u32) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let data = bytes(data, len).to_vec();
        let password = String::from_utf8_lossy(bytes(password, password_len)).into_owned();
        match Pdf::new_with_password(data, &password) {
            Ok(pdf) => {
                if pdf.pages().is_empty() {
                    return FORMAT;
                }
                let Ok(mut s) = sources().lock() else { return FAILED };
                let id = s.next;
                s.next = s.next.wrapping_add(1).max(1);
                s.open.insert(id, Arc::new(pdf));
                if !out.is_null() {
                    *out = id;
                }
                OPENED
            }
            Err(LoadPdfError::Decryption(DecryptionError::PasswordProtected)) => PASSWORD,
            Err(LoadPdfError::Decryption(DecryptionError::UnsupportedAlgorithm)) => SECURITY,
            Err(_) => FORMAT,
        }
    }))
    .unwrap_or(FAILED)
}

/// Closes a source; a render or a write that holds it finishes first (it holds its own reference).
#[no_mangle]
pub extern "C" fn gt_pdf_close(id: u32) {
    let _ = catch_unwind(|| {
        if let Ok(mut s) = sources().lock() {
            s.open.remove(&id);
        }
    });
}

/// The pages of a source; -1 when it is not open.
#[no_mangle]
pub extern "C" fn gt_pdf_page_count(id: u32) -> i32 {
    catch_unwind(|| source(id).map(|p| p.pages().len() as i32).unwrap_or(-1)).unwrap_or(-1)
}

/// A page's size in points as its source shows it (its own rotation applied, before turns).
#[no_mangle]
pub unsafe extern "C" fn gt_pdf_page_size(id: u32, index: u32, width: *mut f32, height: *mut f32) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(pdf) = source(id) else { return false };
        let Some(page) = pdf.pages().get(index as usize) else { return false };
        let (w, h) = render::page_size(page);
        if !width.is_null() {
            *width = w;
        }
        if !height.is_null() {
            *height = h;
        }
        true
    }))
    .unwrap_or(false)
}

/// Renders `page` into `out` (`width` * `height` * 4 bytes, RGBA), its annotations drawn when `layer`.
#[no_mangle]
pub unsafe extern "C" fn gt_pdf_render(page: *const GtPdfPage, width: u32, height: u32, layer: bool, out: *mut u8) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        if page.is_null() || out.is_null() {
            return false;
        }
        let Some((held, pages)) = pages_of(page, 1) else { return false };
        let specs = specs(&held, pages);
        let buf = std::slice::from_raw_parts_mut(out, (width as usize) * (height as usize) * 4);
        render::render(&specs[0], width, height, layer, buf)
    }))
    .unwrap_or(false)
}

/// Writes the pages as a new PDF; with `base` (a source's id; 0: none) its catalog is kept. The bytes in `out` and
/// their count returned (0: failed); free them with `gt_pdf_free`.
#[no_mangle]
pub unsafe extern "C" fn gt_pdf_write(pages: *const GtPdfPage, count: usize, base: u32, out: *mut *mut u8) -> usize {
    catch_unwind(AssertUnwindSafe(|| {
        if out.is_null() || count == 0 {
            return 0;
        }
        let Some((held, list)) = pages_of(pages, count) else { return 0 };
        let base_pdf = if base != 0 {
            match source(base) {
                Some(p) => Some(p),
                None => return 0,
            }
        } else {
            None
        };
        let specs = specs(&held, list);
        let bytes = write::write(&specs, base_pdf.as_deref().map(|p| (base, p)));
        let boxed = bytes.into_boxed_slice();
        let n = boxed.len();
        *out = Box::into_raw(boxed) as *mut u8;
        n
    }))
    .unwrap_or(0)
}

/// Frees what `gt_pdf_write` gave.
#[no_mangle]
pub unsafe extern "C" fn gt_pdf_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }));
}

/// A stamp's box before its turns, in points.
#[no_mangle]
pub unsafe extern "C" fn gt_pdf_stamp_measure(stamp: *const GtPdfStamp, width: *mut f32, height: *mut f32) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if stamp.is_null() {
            return;
        }
        let (w, h) = stamp_of(&*stamp).measure();
        if !width.is_null() {
            *width = w;
        }
        if !height.is_null() {
            *height = h;
        }
    }));
}

#[cfg(test)]
mod tests;
