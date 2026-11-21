# ink: pen strokes as ink

`import tk_ink "gt:ink"` (or the relative path of the submodule). Pure Odin, any target: geometry only, no drawing. It
turns the pointer's samples of one stroke into ink whose width follows the speed (or a stylus's pressure), the nib and
the tapers, as a signature written with a pen. The design is in [src/md/features/ink.md](../src/md/features/ink.md).

```odin
samples: [dynamic]tk_ink.Sample          // one per build while the button is down
append(&samples, tk_ink.Sample{at = pointer, time = now_ms, pressure = ui.pointer_pressure(), tilt = ui.pointer_device().tilt})   // 0: a mouse's

pen := tk_ink.scaled(tk_ink.PEN_FOUNTAIN, zoom)
o := tk_ink.outline(samples[:], pen)      // context.allocator
defer tk_ink.outline_destroy(&o)

tris := tk_ink.triangles(o)               // for draw.triangle
defer delete(tris)
for t in tris { draw.triangle(dc, t[0], t[1], t[2], ink_colour) }

poly := tk_ink.polygon(o)                 // for a path filled with the non-zero rule (a PDF page, paint)
defer delete(poly)
```

The pen's ink (`pen.ink`: translucency, a slow hand's darker turns, pools, a ballpoint's skips, the paper's grain) is
laid by `lay` and drawn as a few fills:

```odin
laid := tk_ink.lay(samples[:], pen, stroke_seed)   // the same seed lays the same ink at every render
defer tk_ink.laid_destroy(&laid)
ls := tk_ink.levels(laid, 6)
defer tk_ink.levels_destroy(ls)
for l in ls {
	// One path per level, its contours filled together with the non-zero rule, the ink's colour at l.alpha.
	path := draw.path_make(allocator = context.temp_allocator)
	for c in l.contours {
		draw.path_move_to(&path, c[0])
		for p in c[1:] { draw.path_line_to(&path, p) }
		draw.path_close(&path)
	}
	draw.path_fill(dc, &path, {ink.r, ink.g, ink.b, u8(l.alpha * 255 + 0.5)})
}
```

Draw each stroke as its own fills, the levels in order: two strokes in one path would merge and not darken where they
cross. The levels are stacked (each holds the ones above it), their alphas chosen for source over, as
`draw.path_fill` lays them. gt:pdf lays an Outline's alpha the same way (normal blending), so a PDF's ink is the
program's; a renderer that multiplies would make a translucent ink about a fifth darker.

## Types

`Sample` is `{at: [2]f32, time: f64, pressure: f32}`: the position in the caller's units, the time in milliseconds
(any origin, not decreasing), the pressure from 0 to 1 (0: unknown). If one sample has a pressure, the width follows
the pressure; else it follows the speed. Samples without time (all at the same time) give a constant width.
A program in `gt:ui` takes the pressure from `ui.pointer_pressure()`: a pen's on Windows and on Wayland, 0 for a mouse,
on X11, and for a device that measures none ([dragdrop.md](dragdrop.md), "Fingers and pens").
`Sample.tilt` is the pen's lean in degrees, as `platform.Pointer_Info.tilt` gives it (-90..90, x towards the right, y
towards the user); {0, 0}, a mouse's, is upright and changes nothing. It acts by `Pen.tilt`.

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
| `tilt` | 0..1 | how much a stylus's lean changes the mark (below); 0: none |
| `ink` | `Ink` | how the ink lies on the paper, read by `lay`; all zero: solid opaque ink |

At the speed of `SPEED_REFERENCE` widths per millisecond (0.2), a Round nib with thinning 1 draws half its width.

The tilt's effect, with `lean` the sine of the angle from upright (0 upright, 1 on its side), smoothed along the
stroke over 1.5 widths as the width is:

- Round and Brush lay the side of the tip: the width is multiplied by `1 + TILT_WIDEN * tilt * lean` (0.6, before
  `min_width` and the tapers), and `lay`'s density by `1 - TILT_LIGHT * tilt * lean` (0.35).
- Chisel turns with the pen: its edge, square to the shaft, blends from `nib_angle` toward the azimuth's by `tilt`
  (fully once the lean passes about 20°; under 6° the azimuth is not read). A stroke along the shaft is full, across it
  thin. Its width and ink do not change.

`Ink`: every field is 0..1; its lengths are shares of `Pen.width`, so `scaled` keeps the look.

| Field | |
|---|---|
| `opacity` | one layer's alpha (0 means 1). Under 1 the ink is translucent: it darkens where strokes cross and under its blobs. |
| `dwell` | how much a fast hand lightens the ink: the density follows the time spent per length, full at rest, `1 - 0.6 * dwell` at an infinite speed. Slow turns and stops are the darkest. |
| `pool` | blobs where the nib rests: at each end and at each stop of 150 ms or more inside the stroke (samples within half a width). Radius `width * (0.22 + 0.25 * pool)`, up to 1.5 times larger after a long rest; density `0.55 + 0.45 * pool`. |
| `skip` | a ballpoint's starvation: bursts of faint ink and short gaps, more where the hand is fast, on upstrokes (y down) and in the first 4.5 widths (priming). Where starved, the ball keeps one edge: the line narrows from the other side, easing in and out. A stroke is never laid empty. |
| `grain` | the paper's grain: the edges move by up to `0.14 * grain` of the local width, and each piece is cut into lanes along the stroke (3 up to 0.5, 5 above), their boundaries wandering across the width. Inner lanes streak lighter where the pen runs dry (fast passages, toward the stroke's end), never under 0.55 of the ink. Above 0.5, the outer lanes may bare the paper where the brush is fast or near its end. |
| `pressure` | how much a light stylus pressure lightens the ink: `1 - 0.6 * pressure * (1 - sample pressure)`. No effect without pressure. |

`Piece` is `{quad: [4][2]f32, density: f32}`: the ink between two outline points (or a lane of it, a quarter of a
round end, or an eighth of a join: the disc a round nib sweeps at a tight turn), its density 0..1 multiplying the
opacity. `Blob` is `{center, radius, density}`: a pool. `Laid` is
`{pieces: []Piece, blobs: []Blob, opacity: f32}`. `Level` is `{alpha: f32, contours: [][][2]f32, points: [][2]f32}`:
one fill; `points` holds the contours' points.

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
| `lay(samples, pen, seed, allocator) -> Laid` | the stroke's ink as pieces and blobs. The same seed gives the same pieces; give each stroke its own seed and keep it with the drawing. All `Ink` fields zero: the pieces cover the polygon, density 1, no blob. |
| `laid_destroy(&laid, allocator)` | frees the pieces and blobs; the same allocator as `lay`. |
| `levels(laid, count, allocator) -> []Level` | the ink as stacked fills. The densities are quantized to `count` steps; each step that holds a piece gives a level holding every piece at that step or above (the first: the whole ink). Alphas: `T_k = opacity * (k + 1) / count` is the coverage wanted, the first level's alpha is its `T`, each next one's `1 - (1 - T_k) / (1 - T_prev)`, so the stack gives each piece its density. Then the blobs in levels of their own, alpha `T`, so they lie over the line. Every contour is counter-clockwise in a y-up frame (a positive shoelace area): within a level nothing cancels under the non-zero rule. A solid ink is one level of alpha 1. |
| `levels_destroy(levels, allocator)` | frees what `levels` allocated. |

## Presets

Their lengths suit a width of a few pixels at 1:1; `scaled` sets another scale.

| Preset | nib | width | thinning | tapers | min_width | tilt | ink |
|---|---|---|---|---|---|---|---|
| `PEN_BALLPOINT` | Round | 2 | 0.35 | round | 0.35 | 0 | skip 0.8, dwell 0.2, pressure 0.4 |
| `PEN_FOUNTAIN` | Chisel, 30° | 3 | 0.3 | 3, 8 | 0.08 | 0.7 | opacity 0.84, pool 0.5, dwell 0.3, pressure 0.3 |
| `PEN_FELT` | Round | 3 | 0.1 | round | 0.6 | 0.8 | opacity 0.85, grain 0.5, dwell 0.2 |
| `PEN_BRUSH` | Brush | 6 | 0.8 | 12, 24 | 0.05 | 1 | opacity 0.88, grain 0.7, pool 0.3, dwell 0.4, pressure 0.5 |

The tilts: a ball rolls the same at any lean (0). A felt's side at a 60° lean lays about +42% width and -24% ink (0.8);
a brush's hairs lie down, +52% and -30% (1). A fountain pen's nib mostly follows the hold, a little of the 30° kept
(0.7).

## Limits

- Where the stroke crosses itself or turns tighter than its half width, triangles overlap. Draw an opaque ink, or a
  translucent one into a layer (or as the polygon with the non-zero rule), so it is not laid twice.
- One stroke is one outline: a signature is a list of strokes, one per press of the button.
- `lay` adds a disc (a join) where a round nib's path turns sharply, so its pieces cover a little more than the
  polygon there: the polygon shows a corner where a round nib sweeps a curve.
