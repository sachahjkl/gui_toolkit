//! gt_mermaid: a Mermaid diagram's text to SVG, through mermaid-svg (its parser, its layout, its SVG). The toolkit's mermaid
//! package calls it and draws the SVG with its svg package.
//!
//! Every entry point catches panics: a diagram the library cannot draw is an error the program shows as the diagram's text.

use std::panic::{catch_unwind, AssertUnwindSafe};

pub const GT_MERMAID_ABI: u32 = 1;

/// The SVG is in `out`.
pub const GT_MERMAID_OK: i32 = 1;
/// The text is not a diagram the library knows: why is in `out`.
pub const GT_MERMAID_ERROR: i32 = 0;
/// The library failed: nothing is in `out`.
pub const GT_MERMAID_PANIC: i32 = -2;

#[no_mangle]
pub extern "C" fn gt_mermaid_abi() -> u32 {
    GT_MERMAID_ABI
}

/// Renders `src` (UTF-8, `src_len` bytes) with the theme named `theme` (mermaid's: "default", "dark", "neutral", "forest";
/// empty or unknown: "default") at `font_size` px (0: the theme's). `out` and `out_len` receive a buffer this library
/// owns: give it back with gt_mermaid_free.
///
/// # Safety
/// `src` and `theme` point to that many readable bytes (or are null with a length of 0); `out` and `out_len` are writable.
#[no_mangle]
pub unsafe extern "C" fn gt_mermaid_render(
    src: *const u8,
    src_len: usize,
    theme: *const u8,
    theme_len: usize,
    font_size: f64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return GT_MERMAID_PANIC;
    }
    *out = std::ptr::null_mut();
    *out_len = 0;
    let text = bytes(src, src_len);
    let name = bytes(theme, theme_len);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = String::from_utf8_lossy(text);
        let name = String::from_utf8_lossy(name);
        let mut t = mermaid_svg::Theme::by_name(&name).unwrap_or_default();
        if font_size > 0.0 {
            t = t.with_font_size(font_size);
        }
        mermaid_svg::render_with(&text, &t)
    }));
    let (code, body) = match result {
        Ok(Ok(svg)) => (GT_MERMAID_OK, svg),
        Ok(Err(e)) => (GT_MERMAID_ERROR, e.to_string()),
        Err(_) => return GT_MERMAID_PANIC,
    };
    let boxed = body.into_bytes().into_boxed_slice();
    *out_len = boxed.len();
    *out = Box::into_raw(boxed) as *mut u8;
    code
}

/// Gives back a buffer of gt_mermaid_render.
///
/// # Safety
/// `p` and `len` are what gt_mermaid_render gave (or null).
#[no_mangle]
pub unsafe extern "C" fn gt_mermaid_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)));
    }
}

unsafe fn bytes<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(src: &str, theme: &str) -> (i32, String) {
        let (mut out, mut len) = (std::ptr::null_mut(), 0usize);
        let code = unsafe { gt_mermaid_render(src.as_ptr(), src.len(), theme.as_ptr(), theme.len(), 0.0, &mut out, &mut len) };
        let s = unsafe { String::from_utf8_lossy(std::slice::from_raw_parts(out, len)).into_owned() };
        unsafe { gt_mermaid_free(out, len) };
        (code, s)
    }

    #[test]
    fn a_flowchart_is_svg_and_a_mistake_says_why() {
        let (code, svg) = render("flowchart LR\n A[Start] --> B[End]", "dark");
        assert_eq!(code, GT_MERMAID_OK);
        assert!(svg.starts_with("<svg") && svg.contains("Start"));
        let (code, why) = render("not a diagram at all", "");
        assert_eq!(code, GT_MERMAID_ERROR);
        assert!(!why.is_empty());
    }
}
