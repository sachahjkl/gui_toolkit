# Rich clipboard (`platform.clipboard_*`)

Plain text stays `get_clipboard` / `set_clipboard`. The rest (`src/platform/clipboard.odin`; Windows in
`clipboard_win32.odin`, Linux in `clipboard_linux.odin` (Wayland and X11), other systems in `clipboard_stub.odin`: nothing there, nothing written):

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
| `png_encode(img) -> []u8`, `png_decode(bytes) -> (Clipboard_Image, ok)` | PNG through the toolkit's codec ([png.md](png.md)), on every system; `png_encode` at `.Fast` |
| `clipboard_image_decode(mime, bytes) -> (Clipboard_Image, ok)` | an image file of `image/png`, `image/jpeg`, `image/bmp` or `image/x-bmp` as straight RGBA8 (pure) |
| `clipboard_pick_mime(offered, wanted) -> string` | the first of `wanted` that `offered` holds, the case ignored; "" when none (pure) |

## Windows formats

| Flavour | Written | Read, best first |
|---|---|---|
| text | `CF_UNICODETEXT`, CRLF line ends | (`get_clipboard`) |
| HTML | `HTML Format` (header with byte offsets, `SourceURL`) | `HTML Format` |
| image | `PNG` (alpha), `CF_DIBV5` (32 bits, alpha mask, straight alpha, sRGB), `CF_DIB` (opaque, over white, for programs that ignore alpha) | `PNG`, `image/png`, `CF_DIBV5`, `CF_DIB`, `CF_BITMAP` |
| files | `CF_HDROP` (UTF-16) + `Preferred DropEffect` = copy | `CF_HDROP` |

The clipboard is shared: opening it is retried for a few milliseconds when another program holds it.

## Linux types (Wayland and X11)

| Flavour | Offered | Read from another program, best first |
|---|---|---|
| text | `text/plain;charset=utf-8`, `text/plain` (X11: `UTF8_STRING`, `STRING`, `TEXT`) | (`get_clipboard`) |
| HTML | `text/html` | `text/html` |
| image | `image/png` | `image/png`, `image/jpeg`, `image/bmp`, `image/x-bmp` (a screenshot tool or a browser's Copy image offers PNG; some tools offer JPEG only) |
| files | `text/uri-list` | `text/uri-list`, `x-special/gnome-copied-files` (GNOME Files: a `copy` or `cut` line, then the URIs) |

`clipboard_formats` says `.Image` and `.Files` for these types (a file manager's offer is `.Files` and `.Text`: KDE's
`text/uri-list`, `application/x-kde-cutselection` and the paths as text). `image/webp` is not read: `core:image` has no
WebP decoder. On Wayland the compositor tells a window what the clipboard holds when the window has the keyboard focus
(and just before it gets it again): an unfocused window reads what was there when it last had the focus.

## Pure conversions (every system)

- `dib_to_rgba`: a packed device-independent bitmap with a `BITMAPCOREHEADER`, `BITMAPINFOHEADER`, V4 or V5 header;
  1, 4 or 8 bits with a palette, 16 bits (5-5-5 or masks), 24, 32 bits (masks, an alpha mask or none); bottom-up or
  top-down. A 32-bit bitmap without an alpha mask whose fourth bytes are all zero is opaque; otherwise they are its
  alpha. Masks repeated after a V5 header (some writers do it) are skipped. Compressed bitmaps are refused.
- `rgba_to_dib(img, .Alpha_V5 | .Opaque_Over_White)`.
- `hdrop_encode`, `hdrop_decode` (UTF-16, or an old program's single-byte list).
- `html_format_wrap`, `html_format_fragment`, `html_format_source_url`.

Tests: `tests/clipboard` (conversions only: the user's clipboard is never touched by the tests; the Linux types above,
`clipboard_pick_mime`, and a JPEG, a BMP and a PNG through `clipboard_image_decode`).
