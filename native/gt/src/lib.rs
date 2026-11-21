//! The toolkit's native library: each part's `gt_*` functions, exported from this one static library (their crates
//! mark them `#[no_mangle] pub extern "C"`: linking the crate in keeps them). The parts: text, mermaid, a11y, webp, pdf.

#[cfg(feature = "text")]
pub extern crate gt_text;
#[cfg(feature = "mermaid")]
pub extern crate gt_mermaid;
#[cfg(feature = "a11y")]
pub extern crate gt_a11y;
#[cfg(feature = "webp")]
pub extern crate gt_webp;
#[cfg(feature = "pdf")]
pub extern crate gt_pdf;
#[cfg(feature = "filesearch")]
pub extern crate gt_filesearch;
