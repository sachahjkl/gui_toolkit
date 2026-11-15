//! The toolkit's native library: each part's `gt_*` functions, exported from this one static library (their crates
//! mark them `#[no_mangle] pub extern "C"`: linking the crate in keeps them).

#[cfg(feature = "text")]
pub extern crate gt_text;
#[cfg(feature = "mermaid")]
pub extern crate gt_mermaid;
#[cfg(feature = "a11y")]
pub extern crate gt_a11y;
