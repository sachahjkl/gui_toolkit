# image: transformations of pictures

`import image "gt:image"` (or the relative path of the submodule). Pure Odin, no platform code, no GPU, any target. The
same calls make the same bytes on every system.

The package changes a picture on the CPU before a program saves or sends it: a screenshot cut, scaled, framed, put on a
background, adjusted, blurred or marked. Every procedure blocks for one or a few passes over the pixels. A program calls
them on a worker, not on its interface's thread.

```odin
shot := image.Image{pixels = rgba, width = w, height = h}       // RGBA8, straight alpha (png.decode, capture)
small := image.resize(shot, w / 2, h / 2)                        // Lanczos3 by default
defer image.destroy(&small)
round := image.round_corners(small, 12)
defer image.destroy(&round)
framed := image.drop_shadow(round, {0, 8}, 24, {0, 0, 0, 120})
defer image.destroy(&framed)
pretty := image.background(framed, 48, {from = image.hex(0x6A5ACD), to = image.hex(0xF08080), angle = 0.375})
```

## Pictures

`Image` is `pixels`, `width` and `height`: packed RGBA8, straight alpha, row after row, no padding. A `Color` is
`[4]u8` (red, green, blue, alpha). `TRANSPARENT`, `BLACK` and `WHITE` are named; `hex(0xRRGGBB, alpha)` makes one.

- A procedure that returns an `Image` makes a new one in its `allocator` (`context.allocator` by default). It never
  frees or changes its input.
- A procedure that returns nothing changes its input in place.
- A picture whose size does not match its pixels gives an empty `Image` (or nothing is changed).

| Call | What it does |
|---|---|
| `create(w, h, color)` | a picture of one colour (transparent by default) |
| `clone(img)`, `destroy(&img)` | a copy; free the pixels |
| `fill_rect(img, rect, color)` | in place: a rectangle of one colour |

## Geometry

| Call | What it gives |
|---|---|
| `crop(img, x, y, w, h)` | the part in the rectangle, cut to the picture |
| `resize(img, w, h, filter)` | the picture at another size |
| `scale(img, factor, filter)` | `resize` by a factor, rounded to whole pixels |
| `rotate(img, quarters)` | turned clockwise by quarters (negative: counterclockwise) |
| `flip(img, horizontal)` | mirrored left to right, or top to bottom |
| `pad(img, left, top, right, bottom, color)` | a margin around it |
| `cut_out(img, at, size, columns)` | without a band of columns (or rows), the two sides joined |
| `trim_bounds(img, tolerance)` | the `Rect` left once the edges of the top-left corner's colour are trimmed (auto crop) |
| `edge_mean(img, r)` | the mean colour of the pixels on the edge of `r`: what surrounds it, to fill it with |

`Filter`:

- `.Lanczos3` (the default): the sharpest. A screenshot's small text stays readable at half size.
- `.Bilinear`: softer, half the taps.
- `.Box`: the mean of the source pixels each pixel covers. The fastest downscale. An upscale shows the pixels.

Each filter widens with the reduction, so every source pixel counts on a downscale. Colours are weighed by alpha: a
transparent pixel gives no colour, and a half transparent flat picture keeps its colour. The edges repeat.

## Look

| Call | What it gives |
|---|---|
| `border(img, width, color, inside)` | a frame around it (the picture grows), or over its outer pixels |
| `round_corners(img, radius)` | its corners cut round and antialiased, transparent outside |
| `drop_shadow(img, offset, radius, color)` | the picture over its blurred shadow; it grows to hold the shadow |
| `background(img, margin, fill)` | the picture on a margin of a colour or a gradient |

`Fill` is two colours and an angle in turns: a linear gradient as CSS draws it (0 upward, 0.25 to the right, its ends at the two
corners farthest along it). `solid(color)` is a flat fill.

## Colour

All in place; alpha stays.

| Call | What it does |
|---|---|
| `grayscale(img)` | each pixel its luma: (77 r + 150 g + 29 b + 128) / 256 |
| `invert(img)` | each colour 255 minus itself |
| `brightness_contrast(img, b, c)` | `b` from -1 to 1 added; `c` from -1 (flat grey) to 1 spreads from the middle grey |
| `saturation(img, amount)` | 0 grey, 1 unchanged, more is more vivid (CSS's `saturate()`) |
| `hue_rotate(img, turns)` | hues turned (0.5: the opposite hue), luminance kept (CSS's `hue-rotate()`) |
| `sepia(img)` | CSS's `sepia(1)` |
| `threshold(img, level)` | white where the luma is `level` or more, else black |

## Filters

- `blur(img, radius)`: a gaussian whose standard deviation is half of `radius`, as a CSS shadow's blur radius. It fades
  out about `radius` pixels away. `drop_shadow`'s `radius` is the same.
- `sharpen(img, amount)`: in place, an unsharp mask. Each colour moves away from its neighbourhood's by `amount` (1: as
  far again as it differs).
- `pixelate(img, cell, rect)`: in place, squares of `cell` pixels, each the mean of its pixels. `rect` is the whole picture
  by default. The squares start at its top-left corner.

## Composition

- `draw_over(dst, src, x, y, opacity)`: in place, `src` over `dst` with its alpha times `opacity`.
- `watermark(img, mark, anchor, margin, opacity)`: in place, `mark` at an `Anchor` (a corner, the middle of a side, the
  centre), `margin` pixels in from the sides it touches. `anchor_point` gives the place.
- `text_image(fonts, face, text, size, color)`: text as a picture, from the outlines of a `font.State`'s faces (as
  `svg.raster` draws its texts). A glyph without an outline, a colour emoji, is left out.
- `watermark_text(img, fonts, face, text, size, color, anchor, margin, opacity)`: in place, `text_image` then `watermark`.
- `combine(images, vertical, gap, background)`: a new picture with the pictures side by side, left to right (top to
  bottom when `vertical`), `gap` pixels apart on `background`. Each is centred across. An empty picture takes no room.

```odin
fonts: font.State
font.init(&fonts)
face, _ := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
image.watermark_text(shot, &fonts, face, "example.com", 18, image.WHITE, .Bottom_Right, 16, 0.6)
```

On Linux, text is shaped by the native text backend, the default there, as everything that shapes text is
([font-backend.md](font-backend.md)).

## Stitching

A scrolling capture's screens joined into one tall picture of the page. The frames have one size. The rows that do
not move between two frames that differ are the header (at the top) and the footer (at the bottom): the picture keeps
the first frame's header and the last frame's footer once. The middle of each frame is joined where its first rows
match the last rows of the middle before: equal row hashes, then the bytes, the largest such overlap. The intent:
[src/md/features/stitch.md](../src/md/features/stitch.md).

A capture loop adds each frame as it comes and stops when a frame adds nothing:

```odin
s := image.stitch_begin({min_overlap = 16, max_height = 20000})   // a zero field takes its default
for {
	frame := capture_the_window()                                  // the program's own capture
	_, result := image.stitch_add(&s, frame)
	image.destroy(&frame)
	if result != .Added { break }   // .No_Overlap: or scroll less and add again
	scroll_down()
}
page, ok := image.stitch_end(&s)
defer image.destroy(&page)
```

| Call | What it does |
|---|---|
| `stitch_begin(options, allocator)` | a `Stitcher`; its memory and the picture are in `allocator` |
| `stitch_add(&s, frame) -> (moved, result)` | adds a frame (read, not kept); `moved` is the rows it appended |
| `stitch_end(&s) -> (img, ok)` | the picture; frees the rest; ok is false when no frame was added |
| `stitch(frames, options, allocator) -> (img, used, ok)` | the same over frames already taken; it stops at the first `.Same` or `.Full`; `used` is the frames that gave rows; a `.No_Overlap` or `.Refused` frame gives ok = false and no picture |

`Stitch_Options`:

- `min_overlap` (`STITCH_MIN_OVERLAP`, 16): the least overlap in rows that joins two frames. Under it, the frames do not
  overlap.
- `max_height` (`STITCH_MAX_HEIGHT`, 32768): the picture's height is never more. At 1920 columns it is 240 MiB.
- `ignore_right` (0): columns at the right edge left out of the comparison, still in the picture. A window's scroll bar
  goes there: its thumb moves with every step, so with it no row of one frame is a row of the next.

`Stitch_Result`:

- `.Added`: the frame's new rows were appended (the first frame: all its rows).
- `.Same`: the frame shows what the frame before showed. The page did not move: its end.
- `.No_Overlap`: no overlap of `min_overlap` rows. The frame is refused and nothing changes. A step of more than a
  screen gives it.
- `.Full`: `max_height` is reached. The rows past it are cut, the footer still ends the picture, later frames add
  nothing.
- `.Refused`: the frame's size is not the first frame's, or its pixels do not match its size.

Rules a caller can count on:

- The first two frames that differ fix the header and the footer for the rest of the stitch.
- On rows that repeat (a page of equal lines), two moves can match. The largest overlap, the smallest move, is taken.
- Matches are exact: a row that changed (a caret that blinks in the middle) breaks the overlap.
- Each frame costs one hash per row and a search of rows times candidate overlaps. Add frames on a worker.

## Files

| Procedure | What it makes |
| --- | --- |
| `jpeg_encode(img, quality = 90)` | a baseline JPEG, written here in Odin: the colours not subsampled (4:4:4), so a screenshot's text keeps its edges; alpha laid over white |
| `webp_encode(img, quality = 85, lossless = false)` | a WebP file by libwebp; `lossless` keeps every pixel. nil in a program built without WebP |
| `webp_decode(data) -> (img, ok)` | the picture of a WebP file (lossy or lossless, alpha kept) by libwebp, in the allocator; ok is false in a program built without WebP or when the bytes are not WebP |
| `webp_available()` | whether the program has WebP: `IMAGE_WEBP`. With `-define:IMAGE_WEBP=true`, `gt:image` links the native library (`build/native/gt_native.lib`, `libgt_native.a` elsewhere) built with the part `webp` (`tk build_native -features:...,webp`): libwebp is inside the program on every system, no DLL beside it and no system libwebp. `toolbox.Feature.Webp` does both. A program with a Rust library of its own builds the crate `native/webp` into it and passes `-define:IMAGE_WEBP_NATIVE_LINK=false`: its `gt_webp_*` functions come from there, as with `FONT_NATIVE_LINK` and `MERMAID_NATIVE_LINK` |
| `decode(data) -> (img, format, ok)` | the picture of a PNG, JPEG (baseline or progressive), WebP, BMP or GIF file, as RGBA8 in the allocator; a GIF's first frame; the format is read from the first bytes, not from a name. ok is false for another format, a damaged file, or a WebP in a program built without WebP |
| `file_format(data)` | `Png`, `Jpeg`, `Webp`, `Bmp`, `Gif` or `Unknown`, from the signature alone (nothing decoded) |

A PNG is `gt:png`'s `png.encode`. `decode` reads a PNG with `png.decode`, a JPEG and a BMP with the Odin core's
`core:image/jpeg` and `core:image/bmp` (the same decoders as the clipboard's), a WebP with libwebp, a GIF with
`gt:gif`'s `gif.decode` (pure Odin: its first frame on its logical screen, the rest transparent; a canvas past
`gif.MAX_DECODE_PIXELS` is refused, see [gif.md](gif.md)). A JPEG's EXIF orientation is not applied: the picture comes
as its pixels are stored. To show a picture smaller, `resize` it after (`.Bilinear` for a thumbnail).

## How it stays fast

The procedures run on 4K pictures on a worker. Each one is a few passes, with no allocation per pixel:

- Whole pixels move as 32-bit words (`rotate` by tiles of 64 x 64, `flip`, `fill_rect`).
- `resize` is separable. The rows resized across are kept in a ring as tall as the filter, so the memory is a few rows.
- `blur` is three box blurs across, then three down, on 16-bit premultiplied values. A box is a running sum, so its cost
  does not depend on the radius. The pass down keeps one sum per column and reads the rows in order.
- The colour adjustments are a table of 256 values or a 3 x 3 matrix in fixed point.

## Tests

`tests/image`: exact pixels for crop, flip, rotate, pad, cut_out, trim_bounds, edge_mean, border, invert, grayscale, threshold, sepia, draw_over, combine,
pixelate and the anchors; properties for the rest (blur keeps the sum, resize, blur and sharpen keep a flat colour, round corners
clear the corners, a shadow grows the picture and keeps it whole, a gradient runs its way); text drawn from the embedded
face lands at its anchor; a JPEG reads back (core:image/jpeg) close to its picture, a lower quality makes a smaller
file; WebP is available (`tools/run_tests` builds the tests with `-define:IMAGE_WEBP=true`), a WebP file is a RIFF WEBP
file, and a lossless one reads back pixel for pixel. `decode`
reads each format by its signature (a PNG, a BMP and a GIF pixel for pixel, a JPEG close to its picture) and refuses an
unknown format and a file cut short. The stitcher (`stitch_test.odin`) rebuilds a synthetic page (a sticky header, a
footer, 770 rows that scroll) exactly from screens at irregular steps, refuses a screen that overlaps too little and
goes on, reports a repeated screen as the end, stops at `max_height`, aligns a page with blocks of equal rows, and
takes the smallest move on a page whose rows all repeat.
