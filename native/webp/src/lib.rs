//! libwebp's simple API, a part of the toolkit's native library (native/gt, feature webp): the four calls
//! src/image/webp.odin makes, under names of their own (gt_webp_*), so that they never clash with another libwebp's names
//! linked into the same program.

use libwebp_sys as w;
use std::os::raw::c_int;

/// A lossy WebP of `width` x `height` RGBA pixels (`stride` bytes a row) at `quality` (0 to 100), in `*output`
/// (gt_webp_free): its size, 0 when refused.
#[no_mangle]
pub unsafe extern "C" fn gt_webp_encode_rgba(rgba: *const u8, width: c_int, height: c_int, stride: c_int, quality: f32, output: *mut *mut u8) -> usize {
    w::WebPEncodeRGBA(rgba, width, height, stride, quality, output)
}

/// A lossless WebP, as gt_webp_encode_rgba.
#[no_mangle]
pub unsafe extern "C" fn gt_webp_encode_lossless_rgba(rgba: *const u8, width: c_int, height: c_int, stride: c_int, output: *mut *mut u8) -> usize {
    w::WebPEncodeLosslessRGBA(rgba, width, height, stride, output)
}

/// The RGBA pixels of a WebP file (lossy or lossless, with or without alpha), its size in `*width`, `*height`; null when
/// it is not one. gt_webp_free frees them.
#[no_mangle]
pub unsafe extern "C" fn gt_webp_decode_rgba(data: *const u8, size: usize, width: *mut c_int, height: *mut c_int) -> *mut u8 {
    w::WebPDecodeRGBA(data, size, width, height)
}

/// What the calls above gave.
#[no_mangle]
pub unsafe extern "C" fn gt_webp_free(ptr: *mut std::ffi::c_void) {
    w::WebPFree(ptr)
}

#[cfg(test)]
mod tests {
    use super::*;

    // A picture through each encoder and back: its size, and its pixels exactly when lossless.
    #[test]
    fn a_picture_goes_through_and_back() {
        let (wd, ht) = (16, 8);
        let px: Vec<u8> = (0..wd * ht).flat_map(|i| [(i * 7) as u8, (i * 3) as u8, 200, 255]).collect();
        unsafe {
            for lossless in [false, true] {
                let mut out: *mut u8 = std::ptr::null_mut();
                let n = if lossless {
                    gt_webp_encode_lossless_rgba(px.as_ptr(), wd, ht, wd * 4, &mut out)
                } else {
                    gt_webp_encode_rgba(px.as_ptr(), wd, ht, wd * 4, 85.0, &mut out)
                };
                assert!(n > 0 && !out.is_null(), "encoded");
                let (mut w2, mut h2) = (0, 0);
                let back = gt_webp_decode_rgba(out, n, &mut w2, &mut h2);
                assert!(!back.is_null() && w2 == wd && h2 == ht, "decoded at its size");
                if lossless { assert_eq!(std::slice::from_raw_parts(back, px.len()), &px[..]) }
                gt_webp_free(back.cast());
                gt_webp_free(out.cast());
            }
        }
    }
}
