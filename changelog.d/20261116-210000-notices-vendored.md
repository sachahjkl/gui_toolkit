type: Fixed

**Notices of a crate that wraps a C library.** `notices` takes the licence files one folder down when a crate has none at its root (libwebp-sys keeps libwebp's COPYING and PATENTS in `vendor/`), and reads a PATENTS file as a notice: a program that links WebP writes its notices again.
