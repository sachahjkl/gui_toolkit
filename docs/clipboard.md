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

## Reading without waiting

Another program owns what it copied: a read asks it, and it may be slow or hung. `get_clipboard` and the
`clipboard_get_*` procedures wait for it (on Linux up to 0.5 s for the text, 2 to 3 s for the other flavours: the window
does not move meanwhile). A paste reads with `clipboard_request`, which returns at once; the answer comes in a later
`poll_events`, as a `Clipboard_Data` event:

```odin
// Ctrl+V: ask, and remember where the files go
app.paste = {id = platform.clipboard_request(app.win, .Files), dir = strings.clone(dir)}

// later, among the window's events
for e in events {
	if e.kind != .Clipboard_Data || e.clipboard.id != app.paste.id { continue }
	r := e.clipboard
	if r.ok { start_job(r.cut ? .Move : .Copy, r.files, app.paste.dir) }   // (job_add clones the paths)
}
```

| | |
|---|---|
| `clipboard_request(w, format) -> u64` | `.Text` or `.Files`; the request's id (never 0; 0: no window). `.Html` and `.Image` are answered not ok |
| `Event.clipboard: Clipboard_Reply` | `id`, `format`, `ok` (it was there), `text`, `files` (absolute paths), `cut` (a paste moves them) |

- One answer per request, in a later `poll_events`, never in the call. The text and the paths belong to the window: they
  live until the next `poll_events`. A program clones what it keeps.
- `ok` is false when the clipboard holds no such thing, or when its owner said nothing for 2 s (Linux): the read gives up.
- The process's store answers at once (for the next poll): an offscreen window, or the clipboard this process owns.
- Linux, another program's clipboard: the window's loop reads it. Wayland: `wl_data_offer.receive` into a pipe that
  does not block, watched by the loop's `poll` with the connection. X11: `ConvertSelection` into a property of the
  request's own, the answer (and an INCR transfer) taken with the connection's other events. A wait of the loop is
  shortened while a read runs, so that a silent owner is given up in time. The requests of a window run one after
  the other.
- Windows: the system keeps what was copied, the read is done in the call and its answer queued.
- `inject_event` of a `Clipboard_Data` (a test playing another program's clipboard): its strings are copied.

### The toolkit's fields

`ui.line_edit` and `ui.text_edit` paste this way (`src/ui/paste.odin`). Ctrl+V, Shift+Insert or a field menu's Paste asks
with `ui.paste_request(key)`; `begin_build` finds the answer among the events it is given, and the widget `key` inserts it
in that build (`ui.paste_answer(key)`) over its selection, in one undo step, if it is built and has the focus. Otherwise the
answer is dropped. One paste waits at a time: a second request replaces the first.

- The ui takes the answers whose id it asked for and leaves the others to the program. A program that reads the events
  before the ui (its own requests) passes every `Clipboard_Data` event on to `begin_build`, and checks each id against its
  own requests.
- `Build_Params.window` is the clipboard asked. `Build_Params.clipboard_get` (a program's own clipboard in memory, a test
  without a window) is read at the request instead, and its text is given in the next build.
- A test's offscreen window: the process's store answers at the next poll, so the frame after the key has the text
  (`session.key` makes two).

## The procedures

| Procedure | |
|---|---|
| `clipboard_set(w, Clipboard_Content) -> bool` | every flavour given, one owner: `text`, `html` (a fragment) + `source_url`, `image`, `files` + `files_cut` |
| `clipboard_set_html`, `clipboard_set_image`, `clipboard_set_files` | shorthands |
| `clipboard_get_image(w) -> (Clipboard_Image, ok)` | straight RGBA8, top row first |
| `clipboard_get_html(w) -> (html, source_url, ok)` | the fragment between the offsets (or the comments), and the page it came from |
| `clipboard_get_files(w) -> ([]string, ok)` | absolute paths (copied in a file manager); waits for the owner: a paste uses `clipboard_request` |
| `clipboard_files_cut(w) -> bool` | true when the files on the clipboard were cut: a paste moves them |
| `clipboard_formats() -> Clipboard_Formats` | `{.Text, .Html, .Image, .Files}` that are there, without opening the clipboard |
| `clipboard_format_names(w)` | every format by name (diagnostics) |
| `clipboard_sequence() -> u32` | changes whenever a program (this one too) writes |
| `clipboard_watch(w, on)`, `clipboard_changed(w)` | the window wakes when the clipboard changes; `clipboard_changed` says so once (the first call says true) |
| `png_encode(img) -> []u8`, `png_decode(bytes) -> (Clipboard_Image, ok)` | PNG through the toolkit's codec ([png.md](png.md)), on every system; `png_encode` at `.Fast` |
| `clipboard_image_decode(mime, bytes) -> (Clipboard_Image, ok)` | an image file of `image/png`, `image/jpeg`, `image/bmp` or `image/x-bmp` as straight RGBA8 (pure) |
| `clipboard_pick_mime(offered, wanted) -> string` | the first of `wanted` that `offered` holds, the case ignored; "" when none (pure) |
| `gnome_copied_files_encode(paths, cut) -> string` | the text of `x-special/gnome-copied-files` (pure) |
| `clipboard_files_cut_decode(mime, bytes) -> bool` | whether `x-special/gnome-copied-files` or `application/x-kde-cutselection` says cut (pure) |

## Cut files

A file manager's Cut and Copy put the same files on the clipboard. A flag tells the paste to move or to copy them:

```odin
// Cut: the program that pastes moves the files
platform.clipboard_set(app.win, {files = selected, files_cut = true})

// Paste: move or copy, as the program that put the files there asked
if paths, ok := platform.clipboard_get_files(app.win); ok {
	if platform.clipboard_files_cut(app.win) { move(paths) } else { copy(paths) }
}
```

`files_cut` without `files` writes no flag. Other programs see the flag as follows:

| System | Written | Read |
|---|---|---|
| Windows | `Preferred DropEffect` = `DROPEFFECT_MOVE` (2) for a cut, `DROPEFFECT_COPY` (1) else | the `DROPEFFECT_MOVE` bit of `Preferred DropEffect` |
| Linux | `x-special/gnome-copied-files` starts with `cut` or `copy`; `application/x-kde-cutselection` = `1`, offered for a cut only | the store's flag when this process owns the clipboard; else `application/x-kde-cutselection` = `1`, or `cut` as the first line of `x-special/gnome-copied-files` |
| other | nothing | false |

An offscreen window keeps the flag in the process's store, as it keeps the files.

## Windows formats

| Flavour | Written | Read, best first |
|---|---|---|
| text | `CF_UNICODETEXT`, CRLF line ends | (`get_clipboard`) |
| HTML | `HTML Format` (header with byte offsets, `SourceURL`) | `HTML Format` |
| image | `PNG` (alpha), `CF_DIBV5` (32 bits, alpha mask, straight alpha, sRGB), `CF_DIB` (opaque, over white, for programs that ignore alpha) | `PNG`, `image/png`, `CF_DIBV5`, `CF_DIB`, `CF_BITMAP` |
| files | `CF_HDROP` (UTF-16) + `Preferred DropEffect` = copy, or move for a cut | `CF_HDROP`; `Preferred DropEffect` for `clipboard_files_cut` |

The clipboard is shared: opening it is retried for a few milliseconds when another program holds it.

## Linux types (Wayland and X11)

| Flavour | Offered | Read from another program, best first |
|---|---|---|
| text | `text/plain;charset=utf-8`, `text/plain` (X11: `UTF8_STRING`, `STRING`, `TEXT`) | (`get_clipboard`) |
| HTML | `text/html` | `text/html` |
| image | `image/png` | `image/png`, `image/jpeg`, `image/bmp`, `image/x-bmp` (a screenshot tool or a browser's Copy image offers PNG; some tools offer JPEG only) |
| files | `text/uri-list` (CRLF line ends), `x-special/gnome-copied-files` (a `copy` or `cut` line, then one URI per line, no last line end), `application/x-kde-cutselection` (`1`, for a cut only) | `text/uri-list`, `x-special/gnome-copied-files` (GNOME Files: a `copy` or `cut` line, then the URIs) |

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
`clipboard_pick_mime`, a JPEG, a BMP and a PNG through `clipboard_image_decode`, the GNOME list and the cut flags).
`tests/scenarios` sets files, cut and copied, on an offscreen window and reads `clipboard_files_cut` back, and asks with
`clipboard_request`: no answer in the call, one per request at the next poll, none after. `tests/scenarios`
(`text_edit_test.odin`) pastes into a line edit and an editor (nothing in the build of Ctrl+V, the text after the answer,
one undo step) and drops an answer for a field that lost the focus; `tests/keyboard` pastes from a `clipboard_get`.
