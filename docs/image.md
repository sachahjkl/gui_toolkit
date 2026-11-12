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
pretty := image.background(framed, 48, {from = image.hex(0x6A5ACD), to = image.hex(0xF08080), angle = 135})
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
| `rotate(img, quarter_turns)` | turned clockwise by quarters (negative: counterclockwise) |
| `flip(img, horizontal)` | mirrored left to right, or top to bottom |
| `pad(img, left, top, right, bottom, color)` | a margin around it |

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

`Fill` is two colours and an angle: a linear gradient as CSS draws it (0 upward, 90 to the right, its ends at the two
corners farthest along it). `solid(color)` is a flat fill.

## Colour

All in place; alpha stays.

| Call | What it does |
|---|---|
| `grayscale(img)` | each pixel its luma: (77 r + 150 g + 29 b + 128) / 256 |
| `invert(img)` | each colour 255 minus itself |
| `brightness_contrast(img, b, c)` | `b` from -1 to 1 added; `c` from -1 (flat grey) to 1 spreads from the middle grey |
| `saturation(img, amount)` | 0 grey, 1 unchanged, more is more vivid (CSS's `saturate()`) |
| `hue_rotate(img, degrees)` | hues turned, luminance kept (CSS's `hue-rotate()`) |
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

```odin
fonts: font.State
font.init(&fonts)
face, _ := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
image.watermark_text(shot, &fonts, face, "example.com", 18, image.WHITE, .Bottom_Right, 16, 0.6)
```

On Linux, text needs the native text backend (`-define:FONT_BACKEND=native`), as everything that shapes text does
([font-backend.md](font-backend.md)). Without it, no glyph is drawn.

## How it stays fast

The procedures run on 4K pictures on a worker. Each one is a few passes, with no allocation per pixel:

- Whole pixels move as 32-bit words (`rotate` by tiles of 64 x 64, `flip`, `fill_rect`).
- `resize` is separable. The rows resized across are kept in a ring as tall as the filter, so the memory is a few rows.
- `blur` is three box blurs across, then three down, on 16-bit premultiplied values. A box is a running sum, so its cost
  does not depend on the radius. The pass down keeps one sum per column and reads the rows in order.
- The colour adjustments are a table of 256 values or a 3 x 3 matrix in fixed point.

## Tests

`tests/image`: exact pixels for crop, flip, rotate, pad, border, invert, grayscale, threshold, sepia, draw_over, pixelate
and the anchors; properties for the rest (blur keeps the sum, resize, blur and sharpen keep a flat colour, round corners
clear the corners, a shadow grows the picture and keeps it whole, a gradient runs its way); text drawn from the embedded
face lands at its anchor.
