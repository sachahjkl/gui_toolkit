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
| `place(dst, src, x, y)` | in place: `src` copied into `dst` at (x, y), alpha too (no blend: `draw_over` blends); what falls outside `dst` is cut (a canvas larger or smaller than the picture) |
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

## Tables

A `Lut` (`[256][4]u8`) is a table per channel: entry i is what each channel's value i becomes, red, green, blue,
alpha. The same table previews on the GPU (`draw.filter_lut` with `draw.lut_texture`, [draw.md](draw.md)) and is
written into the file here: what the person sees is what the file gets.

| Call | What it gives |
|---|---|
| `lut_identity()` | every value as it is |
| `lut_levels(black, white, gamma, channels)` | `black` and `white` (0..1) stretched to the whole range, then `gamma` (above 1: lighter mid-tones) |
| `lut_exposure(stops, channels)` | each colour times 2^stops in linear light |
| `lut_curve(points, channels)` | a smooth curve through the points (input, output, 0..1), monotone between them (no overshoot), flat past the ends |
| `lut_then(a, b)` | `a`, then `b`, as one table |
| `lut_apply(img, &l)` | in place: each channel through its table |

`channels` is `LUT_COLORS` (red, green, blue) by default; the alpha is a channel too (`.Alpha`).

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
| `decode(data, allocator, options) -> (img, format, ok)` | the picture of a PNG, JPEG (baseline or progressive), WebP, BMP or GIF file, as RGBA8 in the allocator; a GIF's first frame; the format is read from the first bytes, not from a name. ok is false for another format, a damaged file, a picture past the options' limits, or a WebP in a program built without WebP |
| `file_format(data)` | `Png`, `Jpeg`, `Webp`, `Bmp`, `Gif` or `Unknown`, from the signature alone (nothing decoded) |
| `file_dimensions(data) -> (size, ok)` | the size the header says, as stored (before an orientation), nothing decoded: PNG's IHDR, a JPEG's frame header, WebP's VP8, VP8L or VP8X header, BMP's header, a GIF's canvas (its screen grown to its first frame: `gif.canvas_size`) |
| `orient(img, o)` | a new picture as the EXIF orientation `o` (1 to 8, `exif.orientation`) says it was held: mirrored, then turned |
| `decode_bytes(data, scale = 1, turned = false)` | the bytes a decode of that file holds at its peak, from its header (0: no header read): the RGBA, the decoder's own planes, a progressive JPEG's coefficients of the whole picture (2 bytes a sample, whatever the scale), the copies of a turn. What the gate admits and `max_bytes` bounds |
| `jpeg_native_available()` | whether JPEG is decoded by the native library (`IMAGE_JPEG`) |

A PNG is `gt:png`'s `png.encode`. `decode` reads a PNG with `png.decode`, a BMP with the Odin core's `core:image/bmp`
(the same decoder as the clipboard's), a WebP with libwebp, a GIF with `gt:gif`'s `gif.decode` (pure Odin: its first
frame on its logical screen, the rest transparent; [gif.md](gif.md) has every frame). A JPEG is the native library's
(below) when the program has it, else the Odin core's `core:image/jpeg`. To show a picture smaller, `resize` it after
(`.Bilinear` for a thumbnail).

### Decode_Options

The zero value is the picture as stored, whole, within `DECODE_MAX_PIXELS`, admitted by the process's gate.

| Field | What it does |
|---|---|
| `orient` | the EXIF orientation applied ([exif.md](exif.md)): a phone's photo stored lying comes upright |
| `need_side` | the longest side the caller shows (0: the whole picture). A JPEG decoded by the native library comes at 1/2, 1/4 or 1/8 of its size when that still covers it (`jpeg_scale_for`); the other formats come whole. The caller still resizes to its exact size |
| `max_pixels` | more pixels (as stored) is refused before any allocation; 0: `DECODE_MAX_PIXELS` |
| `max_bytes` | more bytes held by the decode (`decode_bytes`) is refused before any allocation; 0: no bound |
| `gate` | where a large decode waits for its bytes (nil: `decode_gate()`, the process's) |

```odin
// a viewer's first view of a photo: upright, at the screen's size, the camera's own small JPEG shown meanwhile
if small := exif.thumbnail(file); small != nil { show_soon(image.decode(small, o = {orient = true})) }
pic, _, ok := image.decode(file, o = {orient = true, need_side = screen_side})
```

### Large pictures

`DECODE_MAX_PIXELS` is the Odin core's `MAX_DIMENSIONS` (8192 x 8192, 256 MiB of RGBA): its PNG, JPEG and BMP decoders
refuse a larger picture whatever the caller asks. A program that shows larger pictures raises both with a define,
then passes `max_pixels` where it wants more than the default:

```odin
// the program's tool (toolbox.Project): every odin command of the program gets it, build, test and check
project.defines = {"-define:MAX_DIMENSIONS=268435456"}   // 16384 x 16384
```

The native JPEG decoder has no such cap (a JPEG's sides are 16 bits); `max_pixels` and `max_bytes` bound it. A file
whose native decoder reads another size than its first frame header says (`file_dimensions`) is refused before its
pixels are allocated.

**The gate.** A process with several decode threads (a cache's decoders, a viewer's, the chores) must not hold several
large pictures at once: a 200-megapixel photo is 0.8 GB of RGBA. `decode` acquires the bytes it will hold
(`decode_bytes`) at a `Decode_Gate` before it decodes and gives them back after; a decode waits while the budget is
taken. Under `GATE_FROM_BYTES` (4 MiB) it never waits: a thumbnail does not queue behind a giant. One decode larger
than the whole budget is admitted alone, when nothing else is held (`max_bytes` refuses it).

| Call | What it does |
|---|---|
| `decode_gate()` | the process's gate (budget `GATE_BUDGET_DEFAULT`, 1 GiB) |
| `gate_set_budget(g, bytes)` | its budget (0: the default); the decodes that wait look again |
| `gate_acquire(g, bytes)`, `gate_release(g, bytes)` | what a decoder of its own does around its work (blocks: a worker's call) |
| `gate_counts(g) -> (held, waiting)` | the bytes held and the decodes waiting |

### Fast JPEG

With `-define:IMAGE_JPEG=true` (`toolbox.Feature.Jpeg`: the define and the part `jpeg` of `tk build_native`), a JPEG
is decoded by the toolkit's native library (`native/jpeg`): zune-jpeg for a picture at its size, jpeg-decoder's scaled
IDCT at 1/2, 1/4 or 1/8 of it. Both are pure Rust: no C compiler, no system library. A 24-megapixel photo (6000 x
4000, 4:2:0, 6.5 MB) at `-o:speed` on one core:

| Decode | Odin core | native |
|---|---|---|
| whole (6000 x 4000) | 356 ms | 138 ms |
| 1/2 (3000 x 2000) | 356 ms, then a resize | 89 ms |
| 1/4 (1500 x 1000) | 356 ms, then a resize | 79 ms |
| 1/8 (750 x 500) | 356 ms, then a resize | 78 ms |
| the camera's own thumbnail (`exif.thumbnail`) | a slice of the file, then a 160 x 120 decode | the same |

A scaled decode never makes the whole picture: 1/8 of 24 MP is 1.5 MB of RGBA, not 96 MB. Without the define, nothing
is linked and `decode` reads JPEG with the core's decoder, whole. A program with a Rust library of its own carries
`native/jpeg` in it and passes `-define:IMAGE_JPEG_NATIVE_LINK=false`, as with WebP.

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
takes the smallest move on a page whose rows all repeat. `decode_options_test.odin`: each of the eight orientations
puts every pixel where the tag says, each format's header gives its size, a picture one pixel past `max_pixels` or
past `max_bytes` is refused, the gate holds a third decode until one of two gives its bytes back, and the native JPEG
decoder (`IMAGE_JPEG=true`) reads whole and at 1/2, 1/4, 1/8, each block's colour kept, every cut of a file refused
or read.
