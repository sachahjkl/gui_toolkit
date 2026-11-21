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
- **A centripetal Catmull-Rom spline, resampled every 0.3 width of arc length at most, closer in turns.** The spline
  passes through the streamlined points, so smoothing 0 keeps every sample. The centripetal form (alpha 0.5) makes no
  loop nor cusp where the samples are unevenly spaced (a fast flourish between slow points), which the uniform form
  does. A spacing bound to the arc length makes the width change by even steps whatever the pointer's rate (60 Hz
  mouse or 240 Hz stylus). The ends get a reflected point as their missing neighbour. The last resampled point moves
  to the stroke's end rather than leave a sliver of a segment, whose direction is noise.
- **A point wherever an edge has turned by `RESAMPLE_TURN` (8°).** At a fixed 0.3 width, a loop as tight as a
  signature's turned its outer edge by 30° or more at a point: a polygon's corner, read as a near right angle. A round
  nib hid it under a join's disc; a chisel showed it. The spline is walked in steps of a hundredth of a width, and at
  each step the walk lays the two edges as the nib would (half the width, a chisel's by its direction); a point is
  laid where an edge has turned too far since the last one, never closer than `RESAMPLE_MIN_STEP` (0.02 width) to it,
  so a cusp (the direction reversed in one step) adds one point, not thousands. Measured on the path alone, a
  chisel's edges still turned by 20 to 30°: its width follows the direction, so its edges turn about twice as much as
  its path, most where its hairline begins. The width's other causes (speed, tapers) change slowly and are left out.
  An edge that moves less than half the path (the inner edge of a turn tighter than the half width, folding back) is
  not followed: its turns are hidden under the ink, and it would lay a point at every minimum step.
- **Uneven steps change nothing downstream.** The width's smoothing, the tapers, the speed, the skip and the lanes go by
  the arc length, never by the index. Refused: a finer fixed spacing everywhere: many times the points on every
  straight run, to fix the turns alone. Each point keeps the spline's direction where the walk laid it, so the edges
  are the ones the walk checked; a direction from the neighbouring points weighs the longer segment more, and after a
  long straight step a turn's first point kept the old direction, a corner again.
- **The spline is evaluated about each segment's start.** Far from the origin, f32's rounding turned the walk's short
  steps by a degree or more, and the walk laid points for the noise.
- **A chisel's width has a smooth floor:** `sqrt(sin² (1 - E²) + E²)` of the sine to its edge, `E` = `CHISEL_EDGE`.
  `max(|sin|, E)` met its floor at an angle, and the edges turned there by 10° or more at once, at any spacing.
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
  `CHISEL_EDGE` (a real broad nib has a thickness; the floor is smooth, below). The edges stay perpendicular to the direction, as for a round
  nib. Refused for the outline: the nib's two corners as the edges (the true swept segment): the edges then cross
  wherever the direction crosses the nib's angle, the outline is a bow tie, and the strip's triangles turn over.
  `lay` lays the true sweep as pieces (below).
- **The nib's angle is counter-clockwise as seen with y down** (a screen, a page in pixels): 30° rises to the right,
  the classical italic hand, so `PEN_FOUNTAIN`'s upstrokes are thin. A program in a y-up frame passes the negative.
- **A stylus's tilt lays the side of the tip.** `Sample.tilt` is the pen's lean as `Pointer_Info` gives it (two
  angles in degrees, x towards the right, y towards the user); `Pen.tilt` (0..1) says how much it changes the mark.
  Each sample's tilt becomes the lean vector: the pen's axis projected on the paper, `(tan x, tan y)` normalised with
  the vertical, so its length is `sin` of the angle from upright and its direction is the azimuth, in the same frame as
  `at` (y down). The vector, not two angles, is resampled and smoothed (both ways, 1.5 widths, as the width): an
  azimuth's angle wraps at 180°, and a vector passing through upright fades instead of jumping. The two angles are
  clamped to ±89°: at 90 the tangent is infinite and two 90s have no vertical left to normalise by.
  - A Round or Brush nib lays its side: the width grows by `1 + 0.6 * tilt * lean` and `lay`'s density falls by
    `1 - 0.35 * tilt * lean` (the side of a felt or of hairs is broad and carries less ink). The growth applies before
    `min_width` and the tapers, so a tapered end still ends in a point.
  - A Chisel nib turns with the pen: a broad nib's edge is square to the shaft, so the edge from the azimuth `(a.y,
    -a.x)` blends with `nib_angle`'s by `tilt` times a certainty that rises from a lean of 6° to 20° (under it the
    azimuth is noise). A stroke along the azimuth (pulled towards the shaft) is full, a stroke across it is thin: a
    right hand's pen, its top to the lower right, gives the italic 30° by itself. The blend is on the doubled angle
    (an edge has no sign); where the two edges cancel there, `nib_angle` stays. A chisel's lean does not widen it nor
    lighten its ink: the nib's corners stay on the paper.
  - A tilt of {0, 0} (upright, or a device without tilt) changes nothing, to the bit: a lean of 0 gives factors of
    exactly 1 and leaves `nib_angle` alone. Refused: tilt as an `Ink` field, read by `lay` only: the width and the nib's angle are the
    outline's.
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
  it, a quarter of a round end, an eighth of a join; for a chisel, the nib's sweep: below) with a density 0..1, and
  blobs for the pools. `levels` quantizes
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
- **Joins at cusps.** The resampling keeps every turn between two points under `RESAMPLE_TURN`, except where its
  minimum step stops it: a cusp, or a turn tighter than a few hundredths of a width. There the path turns by more
  than `JOIN_TURN` at one point, its outer edge jumps and its inner edge folds. A round nib sweeps a disc there: `lay`
  adds a disc of the local width at each such point, so the cusp reads as a rounded bulge of ink. (Before the
  resampling followed the turns, every tight turn of a round nib had its joins; they are now rare, and kept for the
  cusps.)
- **A chisel's ink in `lay` is the nib's sweep; its outline is an approximation.** The outline offsets each point
  square to the path by the `|sin|` width. In a loop whose radius is under the nib's width, its lobes on either side
  of the hairline reached past anything the nib touches, and the loop's top showed a notch between them, with a
  pinhole of paper where its inside folded. `lay` lays what the nib touches instead: the nib is a rectangle (its
  width along its edge, `CHISEL_EDGE` of it thick, both with the speed or pressure, `min_width` and the tapers applied
  as to the outline's width), and a convex shape swept along a straight step is itself at both ends plus, between
  them, its chord between its two corners furthest out on either side of the step, swept along it. So each point
  lays its rectangle and each step the parallelogram of the rectangle's diagonal most square to the step. A loop's
  top is then the nib's flat side, as a broad pen writes it. `outline` and `polygon` keep the offset outline: a
  program draws the stroke under way with it, and a closed contour of the sweep would cross itself wherever the
  stroke runs along the nib.
  - Refused: the nib's two corners as the outline's edges: they cross wherever the direction crosses the nib's
    edge, a bow tie. As pieces it does not matter: `levels` turns each one positive and makes their union.
  - Refused: the nib's length swept alone, with its thickness swept along the path: the hairline rose as a bump over
    the loop's flat side, short of the nib's corners. The hull of the two rectangles cut in a fan: `levels` grows each
    piece about its own centre, the fans' quads pushed a shared corner two ways, and the edge showed ticks. The
    rectangle and the diagonal's parallelogram push a corner the same way from either side.
  - A grained chisel keeps its lanes on the nib's length swept (the rectangles at every point would cover them), its
    thickness swept along the path for the hairline, and its rectangle at the ends.
  - A chisel has no join and no round cap: its ends are the nib, and a dot is the nib alone.
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
- **A pool is a drop, not a disc.** A disc of `BLOB_POINTS` read as a stamp, too geometric beside a hand's line. A
  `Blob` carries where the nib rested, its radius, the direction into the stroke from that end (none for a stop or a
  dot) and its own seed (from the stroke's seed and the pool's index); `levels` draws the drop from them, so the same
  seed draws the same drop and each pool of a stroke is another one.
  - Its radius is modulated around it by the 2nd and 3rd harmonics, their amplitudes (0.08 to 0.14, 0.04 to 0.08) and
    phases from the seed: about ±15 to 20 % of the radius. The 1st harmonic would only move the drop. Above the
    3rd the edge wobbles like a gear. The worst sum lets a slight dent, never a pinch: the curve stays star-shaped
    about its centre, so it never crosses itself and stays counter-clockwise. At an end, the 2nd harmonic (itself an
    elongation) lies within 45° of the stroke: across it, it cancelled the teardrop and left a drop lying across the
    line.
  - At an end it is a teardrop drawn out into the stroke: the half toward the stroke stretched by 1.2 to 1.5 (from the
    seed), the half outside kept, both narrowed across so its area stays near the disc's; and its centre moves a fifth
    of the radius into the stroke. The ink the nib leaves as it lands or lifts runs along the line, so the drop reads
    as part of it. Refused: an ellipse centred on the end: symmetric, it bulged as far past the end as into the line.
  - The direction is read on the raw samples, from the end to the first sample more than half a width away, as the
    stops are: the outline's last points are the taper's, their direction the streamline's lag.

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
