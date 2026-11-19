# ink: pen strokes as ink

`import tk_ink "gt:ink"` (or the relative path of the submodule). Pure Odin, any target: geometry only, no drawing. It
turns the pointer's samples of one stroke into ink whose width follows the speed (or a stylus's pressure), the nib and
the tapers, as a signature written with a pen. The design is in [src/md/features/ink.md](../src/md/features/ink.md).

```odin
samples: [dynamic]tk_ink.Sample          // one per pointer event while the button is down
append(&samples, tk_ink.Sample{at = pointer, time = now_ms, pressure = 0})   // 0: no pressure (a mouse)

pen := tk_ink.scaled(tk_ink.PEN_FOUNTAIN, zoom)
o := tk_ink.outline(samples[:], pen)      // context.allocator
defer tk_ink.outline_destroy(&o)

tris := tk_ink.triangles(o)               // for draw.triangle
defer delete(tris)
for t in tris { draw.triangle(dc, t[0], t[1], t[2], ink_colour) }

poly := tk_ink.polygon(o)                 // for a path filled with the non-zero rule (a PDF page, paint)
defer delete(poly)
```

## Types

`Sample` is `{at: [2]f32, time: f64, pressure: f32}`: the position in the caller's units, the time in milliseconds
(any origin, not decreasing), the pressure from 0 to 1 (0: unknown). If one sample has a pressure, the width follows
the pressure; else it follows the speed. Samples without time (all at the same time) give a constant width.

`Pen`:

| Field | Unit, range | |
|---|---|---|
| `nib` | `.Round`, `.Chisel`, `.Brush` | Round: a ballpoint or a felt pen. Chisel: a broad nib, thin along `nib_angle`, full across it. Brush: strong speed thinning, soft tapers. |
| `width` | caller's units, > 0 | the full width: at rest, or at full pressure |
| `thinning` | 0..1 | how much speed (or a light pressure) thins the line; 0: constant |
| `smoothing` | 0..1 | how much the path is smoothed; 0: through every sample |
| `taper_start`, `taper_end` | caller's units, >= 0 | the length over which an end narrows to a point; 0: a round end |
| `nib_angle` | degrees | Chisel: the nib's edge, counter-clockwise as seen with y down (30 rises to the right); in a y-up frame, pass the negative |
| `min_width` | 0..1 | a share of `width` under which the line never goes (before the tapers) |

At the speed of `SPEED_REFERENCE` widths per millisecond (0.2), a Round nib with thinning 1 draws half its width.

`Outline` is `{left, right: [][2]f32, round_start, round_end: bool}`: the two edges of the ink, the same count, from
the start to the end. `left` is on the side of `(-dy, dx)` of the direction of travel.

## Procedures

| Procedure | |
|---|---|
| `outline(samples, pen, allocator) -> Outline` | the ink of one stroke. No sample: an empty outline. One sample, or samples all at one place: a dot (one pair of points, two round ends). |
| `outline_destroy(&o, allocator)` | frees the edges; the same allocator as `outline`. |
| `polygon(o, allocator) -> [][2]f32` | one closed polygon (the last point joins the first): the left edge forward, the end cap, the right edge backward, the start cap. `2 * n` points plus `CAP_POINTS` (7) per round end. Fill it with the non-zero rule. Free with `delete`. |
| `triangles(o, allocator) -> [][3][2]f32` | the same ink as triangles, counter-clockwise in a y-up frame: 2 per segment, `CAP_POINTS + 1` per round end. Free with `delete`. |
| `scaled(pen, k) -> Pen` | `pen` with its width and tapers multiplied by `k`. |

## Presets

Their lengths suit a width of a few pixels at 1:1; `scaled` sets another scale.

| Preset | nib | width | thinning | tapers | min_width |
|---|---|---|---|---|---|
| `PEN_BALLPOINT` | Round | 2 | 0.35 | round | 0.35 |
| `PEN_FOUNTAIN` | Chisel, 30° | 3 | 0.3 | 3, 8 | 0.08 |
| `PEN_FELT` | Round | 3 | 0.1 | round | 0.6 |
| `PEN_BRUSH` | Brush | 6 | 0.8 | 12, 24 | 0.05 |

## Limits

- Where the stroke crosses itself or turns tighter than its half width, triangles overlap. Draw an opaque ink, or a
  translucent one into a layer (or as the polygon with the non-zero rule), so it is not laid twice.
- One stroke is one outline: a signature is a list of strokes, one per press of the button.
