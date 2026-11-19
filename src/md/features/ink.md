# Pen strokes turned into ink (`gt:ink`, package `tk_ink`)

## Purpose

A signature drawn with a mouse or a stylus is a list of pointer samples. Stroked as a polyline of constant width it
looks like a plotter's line: no thick and thin, no pointed ends, the pointer's steps visible on every curve. A
signature written with a pen thins where the hand goes fast and thickens where it slows (the corners, the starts), and
a fountain pen's broad nib is thin along its edge and full across it. `gt:ink` turns the samples into that ink, as
geometry: two edges, a polygon or triangles. Drawing it is the program's (feuille's signature pad first; any program
with freehand marks next).

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

## Subtle points

- The polygon's fill is the ink only with the non-zero rule: where the stroke crosses itself the polygon does too.
- Where the stroke turns tighter than its half width, the inner edge folds back: those triangles overlap and the
  polygon there has a small loop. Opaque ink hides both; a translucent ink must be drawn into a layer (or as the
  polygon with the non-zero rule) so it is not laid twice.
- The presets' lengths suit a width of a few pixels at 1:1. `scaled` multiplies the width and the tapers together;
  scaling only the width changes the look of the tapers.

## Refused

- **A stroke of constant width with round joins** (the old way): it is the plotter's line this package replaces.
- **Variable width from the distance between samples alone** (perfect-freehand's simulated pressure): it depends on the
  pointer's event rate; a time measures the hand.
