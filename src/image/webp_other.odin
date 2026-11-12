#+build !linux
#+build !windows
package tk_image

// (no libwebp is looked for here: WebP is not available)
@(private)
webp_load :: proc() {}
