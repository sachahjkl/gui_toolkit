# png: the PNG codec

`import png "gt:png"` (or the relative path of the submodule; the package is `tk_png`). Pure Odin: no platform code, no C
library, any target. It is the toolkit's only PNG codec: the clipboard and the tray (`platform`), `paint`, `devtools`,
`cdp`, `font` (the bitmaps of CBDT emoji), `testkit/session` and the examples use it.

```odin
file := png.encode(rgba, width, height)               // .Small: a file to keep
frame := png.encode(rgba, width, height, .Fast)       // a picture taken while the program runs
pixels, w, h, ok := png.decode(file)                  // straight RGBA8, rows from the top
```

| Procedure | |
|---|---|
| `encode(rgba, width, height, compression = .Small, allocator) -> []u8` | `width` x `height` straight RGBA8 pixels, rows from the top, as a PNG file: 8 bits, colour type 6, one `IDAT`. nil when the size is empty or `rgba` is shorter than the size says. |
| `decode(data, allocator) -> (rgba, width, height, ok)` | a PNG file as straight RGBA8, rows from the top. ok is false for anything that is not a whole, valid PNG. |
| `rgba8_of(^image.Image, allocator) -> (rgba, width, height, ok)` | any picture a `core:image` loader read (PNG, JPEG, BMP...: 1 to 4 channels, 8 or 16 bits) as straight RGBA8. `platform.clipboard_image_decode` reads another program's JPEG and BMP with it. |

## Encoding

`Compression` says how `encode` spends its time:

| | Filters | Compression | A 1400 x 925 screenshot (`docs/screenshots/controls.png`, `data.png`) |
|---|---|---|---|
| `.Small` | each row the filter (None, Sub, Up, Average, Paeth) whose bytes add up least as signed values | `flate.deflate` (LZ77, dynamic Huffman codes) | 177 KB in 28 ms, 245 KB in 34 ms |
| `.Fast` | Sub on every row: equal neighbouring pixels become runs of zeros | `flate.deflate_runs` (runs and the row above only) | 341 KB in 2.0 ms, 500 KB in 2.5 ms |

`.Small` is for a file that is kept: `paint.png_encode` (the logo and the icons of `tk make_logo` and `tk make_icon`),
`cdp.png_encode` (a timeline's pictures). `.Fast` is for a picture made while a program runs: the screenshots and the
screencast of `devtools`, `testkit/session`'s `save_png`, and the clipboard (`platform.png_encode`: a copy runs on the UI
thread, and the file only goes to another program on this machine). For the same pixels and level, the file is the same.

## Decoding

`decode` reads with `core:image/png`: every colour type (grey, grey and alpha, RGB, RGBA, a palette), every bit depth (1,
2, 4, 8, 16), and transparency from `tRNS`. Grey becomes R = G = B; a picture without alpha is opaque; 16 bits are
rounded to the nearest 8-bit value. Alpha stays straight (not premultiplied). The decoder's own picture is on the heap and
freed before `decode` returns, whatever the caller's allocator (a screenshot is tens of MB).

Tests: `odin test src/png -vet` (both levels read back pixel for pixel, at sizes either side of deflate's window; grey,
1-bit grey, grey and alpha, 16-bit RGB, a palette with `tRNS`; files cut short or not PNG are refused).
