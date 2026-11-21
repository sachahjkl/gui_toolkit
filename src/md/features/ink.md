# Pen strokes turned into ink (`gt:ink`, package `tk_ink`)

## Purpose

A signature drawn with a mouse or a stylus is a list of pointer samples. Stroked as a polyline of constant width it
looks like a plotter's line: no thick and thin, no pointed ends, the pointer's steps visible on every curve. A
signature written with a pen thins where the hand goes fast and thickens where it slows (the corners, the starts), and
a fountain pen's broad nib is thin along its edge and full across it. `gt:ink` turns the samples into that ink, as
geometry: two edges, a polygon or triangles, and the pen's ink as pieces of varying density (below). Drawing it is the
program's (feuille's signature pad first; any program with freehand marks next).

## Decisions

- **Geometry only.** The package returns points; it draws nothing and knows no renderer. A polygon for a path filler
  (PDF content, `paint`), triangles for a renderer that draws triangles (`draw.triangle`). The same outline gives both.
- **The pipeline of perfect-freehand, written anew.** The samples are smoothed (streamline), resampled along a spline,
  given a width per point, then offset on both sides. No dependency: the algorithm is a page of code and a port would
  bring its JavaScript's units (a size in pixels, pressure simulated from distance, not time).
- **The streamline is an exponential moving average** of the samples, `1 - 0.85 * smoothing` toward each new one. It
  lags behind the pointer, so the last sample is appended as it is: the ink ends where the pen lifted. Points closer
  than a thousandth of the width are dropped: a zero-length segment has no direction, and every later step (the
  spline's knots, the tangents) would divide by zero.
- **A centripetal Catmull-Rom spline, resampled every 0.3 width of arc length.** The spline passes through the
  streamlined points, so smoothing 0 keeps every sample. The centripetal form (alpha 0.5) makes no loop nor cusp where
  the samples are unevenly spaced (a fast flourish between slow points), which the uniform form does. A fixed spacing
  makes the width change by even steps whatever the pointer's rate (60 Hz mouse or 240 Hz stylus). The ends get a
  reflected point as their missing neighbour. The last resampled point moves to the stroke's end rather than leave a
  sliver of a segment, whose direction is noise.
- **Pressure when the samples have it, else the speed.** One sample with a pressure above 0 means a stylus: the width
  follows the pressure (`1 - thinning * (1 - pressure)`). Else the speed is measured on the raw samples over a window
  of about 16 ms centred on each one (one interval between two events jitters too much), and normalised by
  `SPEED_REFERENCE` widths per millisecond, so the response is the same at any zoom when the samples and the width are
  in the same units. A stroke whose samples carry no time (the last no later than the first) has a constant width.
- **The speed's response is `n / (1 + n)`** of the normalised speed `n`: 0 at rest, a half at the reference speed, 1
  only at infinity, so a fast flourish thins without vanishing. A brush uses `n / (0.35 + n)`: its hairs spread as soon
  as it slows. The width is the full width at rest: slow strokes and corners (where a hand always slows) are the
  thickest, as with ink on paper.
- **The width is smoothed both ways over the arc length**, with a reach of 1.5 widths. One forward average shifts the
  thinning after the speed that caused it; the arc length, and not the point index, keeps the result independent of
  the spacing. The pressure's and the speed's widths are smoothed alike: a stylus's pressure jitters too.
- **A chisel nib multiplies the width by `|sin|` of the angle between the direction and the nib's edge**, never under
  `CHISEL_EDGE` (a real broad nib has a thickness). The edges stay perpendicular to the direction, as for a round
  nib. Refused: the nib's two corners as the edges (the true swept segment): the edges then cross wherever the
  direction crosses the nib's angle, the outline is a bow tie, and the strip's triangles turn over.
- **The nib's angle is counter-clockwise as seen with y down** (a screen, a page in pixels): 30° rises to the right,
  the classical italic hand, so `PEN_FOUNTAIN`'s upstrokes are thin. A program in a y-up frame passes the negative.
- **`min_width` applies before the tapers.** It keeps a fast line from breaking; the tapers then narrow the ends to 0
  as they must. A stroke shorter than its two tapers scales them by the same factor: a lens, not a taper cut short.
- **The taper's ease.** A pen widens fast and holds (`t (2 - t)`); a brush's tip is a soft S (half a cosine), longer
  and finer.
- **The ends as data, not as points.** `Outline` keeps its edges and two flags (a round start, a round end). `polygon`
  and `triangles` add the caps: a half circle of `CAP_POINTS` points on the segment between the two edge points, so the
  cap's radius is the end's half width. A tapered end adds nothing: its two edge points meet. One sample (or samples
  all at one place) is a dot: one pair of edge points and two round caps, a circle.
- **The result's ownership.** Every procedure takes an allocator for its result. `outline`'s intermediate arrays come
  from the same allocator and are freed before it returns, not from `context.temp_allocator`: a temporary guard would
  free a result allocated with that same allocator.

## The ink model (`lay`, `levels`)

The outline gives the ink's shape; real ink is not one flat colour. A fountain pen's ink is translucent and darkens
where strokes cross and where the nib rests; a ballpoint starves and skips; a felt or a brush streaks on grained paper;
a slow hand leaves more ink than a fast one. The person who signs wants their pen's ink, not a plotter's fill.

- **Pieces with a density, drawn as a few fills.** `lay` cuts the outline into pieces (a quad per segment, a lane of
  it, a quarter of a round end, an eighth of a join) with a density 0..1, and blobs for the pools. `levels` quantizes
  the densities into a few fills, each one path of one alpha. Refused: a gradient or a per-vertex alpha: a PDF path
  has one colour, and a renderer of triangles with vertex colours is not what every program has. A handful of fills
  is what a PDF page and `draw.path_fill` both draw, and six levels read as continuous at a signature's size.
- **The levels are stacked, not a partition.** Level k holds every piece at step k or above: the first level is the
  stroke's whole ink as one union, each next one darkens over it. Its alpha is `1 - (1 - T_k) / (1 - T_prev)`, with
  `T` the opacity times the step: stacked source over, the levels give each piece its target. Refused: a partition
  (each piece in the level of its step only): two neighbours of different density sit in two fills, and their shared
  edge, antialiased in each at half coverage, leaves a light seam of paper. Stacked, an upper level's edge lies over
  ink and only darkens. A step that holds no piece gives no level, so a solid ink is one level of alpha 1.
- **Stacked for source over; a PDF multiplies.** A PDF page lays an alpha under 1 with multiply blending, which
  composes darker than source over (with a blue ink of (29, 64, 175) and six levels, a felt's full ink comes out about
  a fifth darker in each channel). A program that wants the exact shade lays a stroke's levels normally (in a
  transparency group it then multiplies as a whole). The top level of an opaque ink has alpha 1 and is laid normally, so an opaque ink is exact.
- **Within a level nothing cancels.** Every contour is turned positive (counter-clockwise in a y-up frame), so the
  non-zero rule makes their union: neighbours sharing an edge leave no seam, a fold laid twice in one level is laid
  once. A quad whose corners turn both ways (a fold at a tight turn) is cut into the two triangles `triangles` uses:
  turned as a whole, its negative lobe would cut a hole in its neighbours.
- **Joins at tight turns.** The outline's points are 0.3 width apart along the path; where it turns by more than
  `JOIN_TURN`, its outer edge jumps by a large angle and reads as a polygon's corner, and its inner edge folds. A round
  nib sweeps a disc there: `lay` adds a disc of the local width at each such point, so a slow tight turn (dark from the
  dwell) reads as a rounded bulge of ink. A chisel sweeps a line, not a disc: it keeps its outline.
- **Blobs in levels of their own, after the line.** A pool is ink on ink: its fill must lie over the line's to darken
  it. In the line's level it would merge into it and add nothing.
- **One stroke, its own fills.** Two strokes in one path would merge where they cross; a translucent ink must darken
  there. The program fills each stroke's levels in turn (a PDF with multiply blending).
- **Every Ink field zero is the outline.** One level, alpha 1, the polygon's area: a program that adopts `lay` changes
  nothing until a pen has ink. The fields are shares of the width and of the reference speed, never lengths, so
  `scaled` keeps the look.
- **A seed per stroke, no randomness.** The noises are value noise from a hash of an integer and the seed: the same
  samples and seed lay the same pieces at every render, on every machine. Value noise has no period (every step has its
  own value); the skip's octaves have wavelengths whose ratios are not whole and run along a length warped by a slower
  noise, so the lengths of good and bad runs vary.
- **Dwell from the time per length.** The density is `1 - 0.6 * dwell * v / (1 + v)` of the normalised speed `v`: the
  width's own response, so a slow turn is both wider and darker. Measured even under a stylus, whose width follows
  the pressure.
- **The skip comes in bursts.** A risk (a fast hand, an upstroke with y down: a lighter hand, the first 4.5 widths: the
  ball priming, and a slow noise) decides where the ball starves; under a threshold the line is solid. The burst is
  computed per point and smoothed over the arc length (1.2 widths), so it eases in and out. Inside a burst a flicker
  of a width or so decides each piece: faint (never under `SKIP_FAINT`), or a gap where it falls under `SKIP_HOLE`; a
  flicker at the pieces' own spacing stepped at every piece and read as blocks. The bench's first models thinned
  evenly (a grey line, not a ballpoint) or cut holes by width alone (periodic dashes).
- **The scratch is continuous.** Where starved, the ball keeps one edge: each outline point's edges move in by
  `SKIP_SCRATCH` times the smoothed burst, shared between the sides by a smooth function of the arc length (through a
  centred thin line when it changes side). Both pieces at a point see the same edges, so a scratch tapers into the full
  line. Refused: narrowing each piece on its own, which drew a row of small rectangles.
- **Grain: lanes that wander, lighter ink, rarely paper.** Each piece is cut into lanes along the stroke: 3 for a grain
  up to 0.5 (a felt's broad streaks), 5 above (a brush's hairs). Each boundary between lanes wanders across the width
  by its own smooth noise of the arc length, so the streaks are never parallel rails. A streak is lighter ink, never
  under `GRAIN_LIGHT` (0.55) of the piece: a felt never bares the paper. Streaks fall in the inner lanes; a long light
  outer lane read as a second line beside the stroke. Only a grain above 0.5 leaves the paper bare, and only in the
  outer lanes where the brush runs fast or near its end: a dry brush's tail. The stacked levels make a lane's
  continuous shade safe: its steps lie over ink. The edges move by a noise of about a width, a share of the local
  width, so a taper still ends in a point and the edges never cross; a finer noise turned the edge into kinks.
- **Pools from the samples.** An end is where the pen touched or lifted; a stop is samples within half a width for
  150 ms or more. Both are read on the raw samples (the outline has dropped the repeated points and their time).

## Subtle points

- The polygon's fill is the ink only with the non-zero rule: where the stroke crosses itself the polygon does too.
- Where a translucent stroke folds, the pieces of one level make a union: the fold is not laid twice. A join's disc
  covers the fold of a round nib.
- Where the stroke turns tighter than its half width, the inner edge folds back: those triangles overlap and the
  polygon there has a small loop. Opaque ink hides both; a translucent ink must be drawn into a layer (or as the
  polygon with the non-zero rule) so it is not laid twice.
- `levels` grows each contour by `LEVEL_OVERLAP` about its centre, so two neighbouring pieces of a level overlap
  instead of sharing an edge. A renderer that smooths each edge near a pixel (gt:draw's polygon fill) sees two
  opposite edges on one line as two boundaries, and the stroke showed a hatching. The union grows by a few per cent of
  a piece: nothing seen. The levels of a grained or skipping ink hold hundreds of contours: draw them with a renderer
  made for many shapes (a PDF's, a canvas), not gt:draw's polygon fill, which keeps 4096 points a fill.
- The presets' lengths suit a width of a few pixels at 1:1. `scaled` multiplies the width and the tapers together;
  scaling only the width changes the look of the tapers.

## Refused

- **A stroke of constant width with round joins** (the old way): it is the plotter's line this package replaces.
- **Variable width from the distance between samples alone** (perfect-freehand's simulated pressure): it depends on the
  pointer's event rate; a time measures the hand.
