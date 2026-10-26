# Rich clipboard (`platform.clipboard_*`)

Plain text stays `get_clipboard` / `set_clipboard`. The rest (`platform/clipboard.odin`; Windows in
`clipboard_win32.odin`, other systems in `clipboard_stub.odin`: nothing there, nothing written):

```odin
// Copy a selection of a chat message: text and markup, one owner
platform.clipboard_set(app.win, {text = plain, html = markup, source_url = ""})

// Paste: what is there decides what the Paste item does
fmts := platform.clipboard_formats()
if .Image in fmts {
	if img, ok := platform.clipboard_get_image(app.win); ok {
		defer platform.clipboard_image_destroy(&img)
		attach_image(app, img.rgba, img.size)
	}
}
```

| Procedure | |
|---|---|
| `clipboard_set(w, Clipboard_Content) -> bool` | every flavour given, one owner: `text`, `html` (a fragment) + `source_url`, `image`, `files` |
| `clipboard_set_html`, `clipboard_set_image`, `clipboard_set_files` | shorthands |
| `clipboard_get_image(w) -> (Clipboard_Image, ok)` | straight RGBA8, top row first |
| `clipboard_get_html(w) -> (html, source_url, ok)` | the fragment between the offsets (or the comments), and the page it came from |
| `clipboard_get_files(w) -> ([]string, ok)` | absolute paths (copied in a file manager) |
| `clipboard_formats() -> Clipboard_Formats` | `{.Text, .Html, .Image, .Files}` that are there, without opening the clipboard |
| `clipboard_format_names(w)` | every format by name (diagnostics) |
| `clipboard_sequence() -> u32` | changes whenever a program (this one too) writes |
| `clipboard_watch(w, on)`, `clipboard_changed(w)` | the window wakes when the clipboard changes; `clipboard_changed` says so once (the first call says true) |
| `png_encode`, `png_decode` | PNG through stb_image (Windows build) |

## Windows formats

| Flavour | Written | Read, best first |
|---|---|---|
| text | `CF_UNICODETEXT`, CRLF line ends | (`get_clipboard`) |
| HTML | `HTML Format` (header with byte offsets, `SourceURL`) | `HTML Format` |
| image | `PNG` (alpha), `CF_DIBV5` (32 bits, alpha mask, straight alpha, sRGB), `CF_DIB` (opaque, over white, for programs that ignore alpha) | `PNG`, `image/png`, `CF_DIBV5`, `CF_DIB`, `CF_BITMAP` |
| files | `CF_HDROP` (UTF-16) + `Preferred DropEffect` = copy | `CF_HDROP` |

The clipboard is shared: opening it is retried for a few milliseconds when another program holds it.

## Pure conversions (every system)

- `dib_to_rgba`: a packed device-independent bitmap with a `BITMAPCOREHEADER`, `BITMAPINFOHEADER`, V4 or V5 header;
  1, 4 or 8 bits with a palette, 16 bits (5-5-5 or masks), 24, 32 bits (masks, an alpha mask or none); bottom-up or
  top-down. A 32-bit bitmap without an alpha mask whose fourth bytes are all zero is opaque; otherwise they are its
  alpha. Masks repeated after a V5 header (some writers do it) are skipped. Compressed bitmaps are refused.
- `rgba_to_dib(img, .Alpha_V5 | .Opaque_Over_White)`.
- `hdrop_encode`, `hdrop_decode` (UTF-16, or an old program's single-byte list).
- `html_format_wrap`, `html_format_fragment`, `html_format_source_url`.

Tests: `tests/clipboard` (conversions only: the user's clipboard is never touched by the tests).
