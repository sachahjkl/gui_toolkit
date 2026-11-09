# paint: vector pictures drawn on the CPU

`import paint "gt:paint"` (or the relative path of the submodule). The package is named `tk_paint`. Pure Odin, no platform
code, no GPU, any target. The same calls make the same bytes on every system.

The package draws pictures that a program makes ahead of time: a logo, the sizes of an icon, a check sheet. It does not
draw a window: `draw` and `render` do that. `tk make_logo` and `tk make_icon` use it, and so do the logo commands of Wren
(`wrentool logo`) and opencode native (`occtools logo`).

## A picture

```odin
c := paint.canvas_make(2048, 2048)               // transparent
defer paint.canvas_destroy(&c)
c.transform = paint.scale(paint.IDENTITY, 4, 4)  // path units to pixels

p: paint.Path
defer paint.path_destroy(&p)
paint.round_rect(&p, 56, 56, 400, 400, 100)
body := paint.linear({0, 56}, {0, 456}, paint.hex(0x2F6FD8), paint.hex(0x0B3F9C))
paint.fill(&c, p, body)                                   // non-zero by default; .Even_Odd as GDI+'s Alternate
paint.stroke(&c, p, {width = 10}, paint.solid(paint.hex(0x000000, 230)))

small := paint.resize(c, 512, 512)                       // cubic: good down to 16 px
paint.write_png(small, "logo.png")
```

A canvas holds premultiplied colours as `f32`. Layers and resampling therefore add no rounding. The 8 bits come only when a
file is written (`png_encode`, `dib_encode`, `to_rgba8`). Pixel `(i, j)` covers `[i, i+1) x [j, j+1)`.

## Paths

| Call | What it adds |
|---|---|
| `move_to`, `line_to`, `quad_to`, `cubic_to`, `close` | a figure, as in any vector API; `line_to` with no figure begun starts one |
| `start_figure` | ends the figure without closing it (GDI+'s `StartFigure`) |
| `arc(x, y, w, h, start, sweep)` | an arc of the ellipse in the box, angles in degrees, clockwise on a canvas; a begun figure gets a line to its start (GDI+'s `AddArc`) |
| `rect`, `round_rect`, `ellipse`, `polygon` | a closed figure of its own |
| `path_transform(&p, m)`, `path_clone` | every point through a `Matrix`; a copy |

Curves are cubic Béziers. Arcs and ellipses become cubics of a quarter turn at most. A fill flattens them into lines that
stray at most 0.05 pixels from the curve.

`Matrix` is affine. `translate`, `scale` and `rotate_at` put their step before the matrix they get, so a chain built from
`IDENTITY` reads in the order of GDI+'s `Matrix` calls. `multiply(first, then)`, `apply`, `invert`.

## Filling and stroking

- `fill(&c, path, paint, rule)` fills every figure, closed or not. The coverage is exact across a row and has 16 steps down a
  row.
- `stroke(&c, path, pen, paint)` fills the outline that `widen(path, pen)` makes. `Pen` has a `width`, a `join` (`.Miter`,
  the default, becomes a bevel past `miter_limit`, 10 by default; `.Bevel`; `.Round`) and a `cap` (`.Flat`, `.Square`,
  `.Round`).
- `widen(path, pen, flatness)` returns the outline as figures to fill with `.Non_Zero`. A coarse `flatness` makes the path's
  curves visible lines, as GDI+'s `Widen` does. The round joins and caps stay smooth.
- `Paint`: `solid(color)`, `linear(start, end, from, to, spread)`, `radial(center, radius, from, to, spread)`; more colours
  with `add_stop` or `set_stops`. `.Repeat` starts the gradient again past its ends, as GDI+'s `LinearGradientBrush`
  does by default; `.Pad` continues the end colours. Colours between stops are interpolated without premultiplying.
  `shade(paint, point)` gives the colour at a point.
- `set_clip(&c, path, rule, antialias)` limits drawing and `clear` to the inside of the path until `reset_clip`. Without
  antialiasing, a pixel is in when its centre is in, as GDI+'s clip regions are.
- `clear(&c, color)` sets every pixel that the clip reaches.

`hex(0xRRGGBB, alpha)` makes a `Color` (straight, 0 to 1).

## One canvas into another

`draw_canvas(&dst, src, to, from, filter)` draws the `from` rectangle of `src` into the `to` rectangle of `dst`, over what is
there. `resize(src, w, h)` makes a new canvas of the whole picture.

- `.Cubic`: Keys' cubic convolution (a = -0.75), widened by the reduction so that every source pixel counts. The source
  outside `from` counts as transparent. This is near GDI+'s `HighQualityBicubic` from 4 to 25 times smaller.
- `.Nearest`: each pixel takes the source pixel under its centre, for a magnified check of small sizes.

## Files

- `png_encode(c)`: 8-bit RGBA through `png.encode`'s `.Small` ([png.md](png.md)): each row takes the PNG filter whose
  bytes add up least, then `flate.deflate`. `png_decode(data)` reads any PNG that `png.decode` reads. `write_png(c, path)`.
- `ico_encode(entries)`: an .ico file of `Ico_Entry{size, data}` pictures in their order. A picture is a PNG file or a
  classic DIB from `dib_encode(c)` (BGRA rows from the bottom, an empty AND mask), which old readers of small icons expect.

## Matching GDI+

Pictures that GDI+ drew with antialiasing and its default pixel offset mode sit `GDIPLUS_OFFSET` (0.625) pixels lower and
to the right of this package's. A picture made to match one of them starts its transform with
`paint.translate(paint.IDENTITY, paint.GDIPLUS_OFFSET, paint.GDIPLUS_OFFSET)`. With that offset, the three logos that GDI+
used to draw (the toolkit's, Wren's, opencode native's) differ from their committed pictures by less than 1.5 of 255 per
channel on average, at every size from 16 to 512 pixels.
