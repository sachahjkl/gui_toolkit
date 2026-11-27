//! A fast JPEG decoder, a part of the toolkit's native library (native/gt, feature jpeg): the two calls
//! src/image/jpeg_native.odin makes. A picture at its size is zune-jpeg's (pure Rust, SIMD); at 1/2, 1/4 or 1/8 of it,
//! jpeg-decoder's scaled IDCT (a block of 8 x 8 coefficients becomes 4 x 4, 2 x 2 or one pixel), so a first view or a
//! thumbnail of a 24-megapixel photo never makes its 96 MB of RGBA. A file of four components (CMYK, YCCK) is
//! jpeg-decoder's at every scale (zune_reads). Every entry point catches panics: a damaged file is
//! a picture not shown, never a dead program.

use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use zune_core::bytestream::ZCursor;
use zune_core::colorspace::ColorSpace;
use zune_core::options::DecoderOptions;
use zune_jpeg::JpegDecoder;

/// The largest side read (a JPEG's sides are 16 bits): the caller bounds the pixels before it asks.
const MAX_SIDE: usize = 65535;

fn zune_options() -> DecoderOptions {
    DecoderOptions::default()
        .jpeg_set_out_colorspace(ColorSpace::RGBA)
        .set_max_width(MAX_SIDE)
        .set_max_height(MAX_SIDE)
        .set_strict_mode(false)
}

/// Whether zune-jpeg decodes the file: not one of four components (CMYK, Adobe's YCCK). zune-jpeg 0.5.15 gets their
/// colours wrong (its YCCK to RGBA conversion walks rows of width * 3 bytes, worker.rs); jpeg-decoder's match
/// ImageMagick's, so those files take its path at every scale.
fn zune_reads(data: &[u8]) -> bool {
    let mut d = jpeg_decoder::Decoder::new(data);
    match d.read_info().ok().and_then(|_| d.info()) {
        Some(info) => info.pixel_format != jpeg_decoder::PixelFormat::CMYK32,
        None => true,
    }
}

/// The size of the picture at 1/`scale` (1, 2, 4 or 8; another value is 1), as gt_jpeg_decode_rgba makes it. 0 when the
/// headers cannot be read.
fn scaled_size(data: &[u8], scale: usize) -> Option<(usize, usize)> {
    if scale <= 1 && zune_reads(data) {
        let mut d = JpegDecoder::new_with_options(ZCursor::new(data), zune_options());
        d.decode_headers().ok()?;
        return d.dimensions();
    }
    let mut d = jpeg_decoder::Decoder::new(data);
    d.read_info().ok()?;
    let info = d.info()?;
    let (w, h) = (info.width as usize, info.height as usize);
    let (sw, sh) = (w.div_ceil(scale), h.div_ceil(scale));
    let (gw, gh) = d.scale(sw as u16, sh as u16).ok()?;
    Some((gw as usize, gh as usize))
}

fn decode(data: &[u8], scale: usize, out: &mut [u8]) -> Option<(usize, usize)> {
    if scale <= 1 && zune_reads(data) {
        let mut d = JpegDecoder::new_with_options(ZCursor::new(data), zune_options());
        d.decode_headers().ok()?;
        let (w, h) = d.dimensions()?;
        if out.len() < w * h * 4 { return None }
        d.decode_into(&mut out[..w * h * 4]).ok()?;
        return Some((w, h));
    }
    let mut d = jpeg_decoder::Decoder::new(data);
    d.read_info().ok()?;
    let info = d.info()?;
    let (w, h) = (info.width as usize, info.height as usize);
    let (gw, gh) = d.scale(w.div_ceil(scale) as u16, h.div_ceil(scale) as u16).ok()?;
    let px = d.decode().ok()?;
    let info = d.info()?;
    let (gw, gh) = (gw as usize, gh as usize);
    let n = gw * gh;
    if out.len() < n * 4 { return None }
    let out = &mut out[..n * 4];
    match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => {
            if px.len() < n * 3 { return None }
            for (o, i) in out.chunks_exact_mut(4).zip(px.chunks_exact(3)) { o[0] = i[0]; o[1] = i[1]; o[2] = i[2]; o[3] = 255 }
        }
        jpeg_decoder::PixelFormat::L8 => {
            if px.len() < n { return None }
            for (o, &v) in out.chunks_exact_mut(4).zip(px.iter()) { o[0] = v; o[1] = v; o[2] = v; o[3] = 255 }
        }
        jpeg_decoder::PixelFormat::L16 => {
            if px.len() < n * 2 { return None }
            // (big-endian samples: the high byte first)
            for (o, v) in out.chunks_exact_mut(4).zip(px.chunks_exact(2)) { o[0] = v[0]; o[1] = v[0]; o[2] = v[0]; o[3] = 255 }
        }
        jpeg_decoder::PixelFormat::CMYK32 => {
            if px.len() < n * 4 { return None }
            // (jpeg-decoder gives the inks, the Adobe inversion undone (255 - stored): each colour is what its ink and K
            // leave. Read as stored, a CMYK photo came out dark and inverted at 1/2 to 1/8, and right whole)
            for (o, i) in out.chunks_exact_mut(4).zip(px.chunks_exact(4)) {
                let k = 255 - i[3] as u32;
                o[0] = ((255 - i[0] as u32) * k / 255) as u8;
                o[1] = ((255 - i[1] as u32) * k / 255) as u8;
                o[2] = ((255 - i[2] as u32) * k / 255) as u8;
                o[3] = 255;
            }
        }
    }
    Some((gw, gh))
}

/// The size of the JPEG at `data` decoded at 1/`scale` (1, 2, 4, 8) in `*width`, `*height`: 1, or 0 when its headers
/// cannot be read.
#[no_mangle]
pub unsafe extern "C" fn gt_jpeg_size(data: *const u8, size: usize, scale: c_int, width: *mut c_int, height: *mut c_int) -> c_int {
    if data.is_null() || width.is_null() || height.is_null() { return 0 }
    let bytes = std::slice::from_raw_parts(data, size);
    match catch_unwind(|| scaled_size(bytes, scale.max(1) as usize)) {
        Ok(Some((w, h))) => { *width = w as c_int; *height = h as c_int; 1 }
        _ => 0,
    }
}

/// The JPEG at `data` decoded at 1/`scale` (1, 2, 4, 8) as straight RGBA8 into `out` (`out_len` bytes: at least the
/// size gt_jpeg_size says, times 4), its size in `*width`, `*height`: 1, or 0 when it cannot be read or does not fit.
#[no_mangle]
pub unsafe extern "C" fn gt_jpeg_decode_rgba(data: *const u8, size: usize, scale: c_int, out: *mut u8, out_len: usize, width: *mut c_int, height: *mut c_int) -> c_int {
    if data.is_null() || out.is_null() || width.is_null() || height.is_null() { return 0 }
    let bytes = std::slice::from_raw_parts(data, size);
    let pixels = std::slice::from_raw_parts_mut(out, out_len);
    match catch_unwind(AssertUnwindSafe(|| decode(bytes, scale.max(1) as usize, pixels))) {
        Ok(Some((w, h))) => { *width = w as c_int; *height = h as c_int; 1 }
        _ => 0,
    }
}
