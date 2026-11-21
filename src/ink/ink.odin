// Pen strokes turned into ink: the pointer's samples become the two edges of a line whose width follows the pen's
// speed or pressure, its nib and its tapers, as a signature written with a real pen. In the manner of perfect-freehand
// (Steve Ruiz), written anew. Pure geometry: no drawing, no platform code. See docs/ink.md and src/md/features/ink.md.
package tk_ink

import "core:math"

// One sample of the pointer.
Sample :: struct {
	at:       [2]f32, // the position, in the caller's units (the same as Pen.width)
	time:     f64,    // milliseconds, any origin, not decreasing along the stroke
	pressure: f32,    // 0..1; 0: unknown (a mouse, a touch pad): the width then follows the speed
}

Nib :: enum u8 {
	Round,  // a ballpoint or a felt pen: the width follows the speed (or the pressure)
	Chisel, // a fountain pen's broad nib: thin along nib_angle, full across it, as calligraphy
	Brush,  // a brush: the width answers the speed strongly; soft tapers
}

// How the ink is laid. Every length is in the caller's units; `scaled` multiplies them together.
Pen :: struct {
	nib:         Nib,
	width:       f32, // > 0: the full width of a slow stroke (or of a stroke at full pressure)
	thinning:    f32, // 0..1: how much speed (or a light pressure) thins the line; 0: a constant width
	smoothing:   f32, // 0..1: how much the pointer's path is smoothed; 0: the line passes through every sample
	taper_start: f32, // >= 0: the length over which the start narrows to a point; 0: a round start
	taper_end:   f32, // >= 0: the same at the end; 0: a round end
	nib_angle:   f32, // degrees (Chisel): the nib's edge, counter-clockwise from +x as seen with y down; 30 rises to the right
	min_width:   f32, // 0..1: a share of width under which the line never goes (before the tapers), so it never breaks
	ink:         Ink, // how the ink lies on the paper (`lay`); all zero: solid opaque ink
}

// How a pen's ink lies on the paper, read by `lay`. Every field is 0..1, and every length is a share of Pen.width, so
// `scaled` keeps the look. All zero: a solid opaque ink, the outline's.
Ink :: struct {
	opacity:  f32, // 0..1, 0 means 1: one layer's alpha; under 1 the ink is translucent and darkens where strokes cross
	dwell:    f32, // 0..1: how much a fast hand lightens the ink (the time spent per length: slow turns and stops darken)
	pool:     f32, // 0..1: blobs of ink where the nib rests (each end, long stops); 0: none
	skip:     f32, // 0..1: a ballpoint's starvation: faint passages, rare gaps, a ball that keeps one edge
	grain:    f32, // 0..1: the paper's grain: rough edges and streaks along the stroke
	pressure: f32, // 0..1: how much a light stylus pressure lightens the ink (no effect without pressure)
}

// The ink of one stroke: its two edges, the same count, from the start to the end. `left` is on the side of
// (-dy, dx) of the direction of travel. A round end is a half circle on the segment between its two edge points.
// The slices belong to the caller: `outline_destroy` frees them with the allocator that `outline` was given.
Outline :: struct {
	left, right:            [][2]f32,
	round_start, round_end: bool,
}

// The points of a round cap strictly between its two edge points (a half circle): `polygon` adds them per round end.
CAP_POINTS :: 7

// A ballpoint: a thin round line, a little thinner when fast, round ends; its ink skips where the hand is fast.
PEN_BALLPOINT :: Pen {
	nib = .Round, width = 2, thinning = 0.35, smoothing = 0.5, min_width = 0.35,
	ink = {skip = 0.8, dwell = 0.2, pressure = 0.4},
}
// A fountain pen: a broad nib at 30°, some speed thinning, tapered ends; a translucent ink that pools where the nib
// rests.
PEN_FOUNTAIN :: Pen {
	nib = .Chisel, width = 3, thinning = 0.3, smoothing = 0.5, taper_start = 3, taper_end = 8, nib_angle = 30, min_width = 0.08,
	ink = {opacity = 0.84, pool = 0.5, dwell = 0.3, pressure = 0.3},
}
// A felt pen: a round line of almost constant width, round ends; a translucent ink with a little grain.
PEN_FELT :: Pen {
	nib = .Round, width = 3, thinning = 0.1, smoothing = 0.5, min_width = 0.6,
	ink = {opacity = 0.85, grain = 0.5, dwell = 0.2},
}
// A brush: strong speed thinning, long soft tapers; a strong grain, pools, and a hand's pace in its ink.
PEN_BRUSH :: Pen {
	nib = .Brush, width = 6, thinning = 0.8, smoothing = 0.6, taper_start = 12, taper_end = 24, min_width = 0.05,
	ink = {opacity = 0.88, grain = 0.7, pool = 0.3, dwell = 0.4, pressure = 0.5},
}

// The speed, in widths per millisecond, at which a Round nib with thinning 1 draws half its width. A hand signs at
// about 0.1 to 1 px/ms; with a width of 2 to 3 px, this puts slow strokes near full width and flourishes well under.
SPEED_REFERENCE :: 0.2
// The time over which a speed is measured: one or two pointer events are too few (their intervals jitter).
SPEED_WINDOW_MS :: 16
// A broad nib's thickness, as a share of its width: the line along the nib's edge is never thinner.
CHISEL_EDGE :: 0.12

// `pen` with its lengths (width and tapers) multiplied by `k`: the presets at another scale.
scaled :: proc(pen: Pen, k: f32) -> Pen {
	p := pen
	p.width *= k
	p.taper_start *= k
	p.taper_end *= k
	return p
}

@(private)
Point :: struct {
	at:       [2]f32,
	pressure: f32,
	speed:    f32, // caller's units per millisecond; < 0: unknown
	s:        f32, // the arc length from the start
	factor:   f32, // the width's share from speed or pressure
}

// The ink of a stroke. No sample gives an empty outline; one sample (or samples all at one place) gives a dot.
// The result is allocated with `allocator` (and so are the intermediate arrays, freed before the return).
outline :: proc(samples: []Sample, pen: Pen, allocator := context.allocator) -> Outline {
	o, pts := trace(samples, pen, allocator)
	delete(pts, allocator)
	return o
}

// The outline and, for each of its points, what the ink model reads there: the arc length, the speed (< 0 unknown)
// and the pressure (0 unknown). Both are allocated with `allocator`.
@(private)
trace :: proc(samples: []Sample, pen: Pen, allocator := context.allocator) -> (Outline, []Point) {
	if len(samples) == 0 || !(pen.width > 0) { return {}, nil }
	width := pen.width
	thinning := clamp(pen.thinning, 0, 1)
	min_width := clamp(pen.min_width, 0, 1) * width
	has_pressure := false
	for s in samples { if s.pressure > 0 { has_pressure = true; break } }

	// Measured even under a stylus: the width follows the pressure, but the ink's dwell still follows the speed.
	speeds := make([]f32, len(samples), allocator)
	defer delete(speeds, allocator)
	measured := sample_speeds(samples, speeds, allocator)
	if !measured { for &v in speeds { v = -1 } }
	timed := !has_pressure && measured

	// Points closer than this are one: a zero-length segment has no direction.
	eps := max(width * 1e-3, 1e-6)

	// The streamline: an exponential moving average pulls each point toward its sample, so the hand's tremor and the
	// pointer's steps are smoothed. The last sample is kept as it is: the ink ends where the pen lifted.
	follow := 1 - 0.85 * clamp(pen.smoothing, 0, 1)
	line := make([dynamic]Point, 0, len(samples) + 1, allocator)
	defer delete(line)
	at := samples[0].at
	append(&line, Point{at = at, pressure = samples[0].pressure, speed = speeds[0]})
	for i in 1 ..< len(samples) {
		at += (samples[i].at - at) * follow
		keep(&line, Point{at = at, pressure = samples[i].pressure, speed = speeds[i]}, eps)
	}
	last := len(samples) - 1
	keep(&line, Point{at = samples[last].at, pressure = samples[last].pressure, speed = speeds[last]}, eps)

	if len(line) < 2 {
		f: f32 = has_pressure ? pressure_factor(line[0].pressure, thinning) : 1
		one := make([]Point, 1, allocator)
		one[0] = line[0]
		return dot(line[0].at, max(width * f, min_width), allocator), one
	}

	// Resampled along a spline at a fixed spacing: the width and the edges then change by even steps whatever the
	// pointer's rate, and a curve drawn with few samples stays round.
	spacing := width * 0.3
	pts := make([dynamic]Point, 0, 64, allocator)
	resample(line[:], spacing, &pts)
	n := len(pts)
	total := pts[n - 1].s

	for &p in pts {
		switch {
		case has_pressure: p.factor = pressure_factor(p.pressure, thinning)
		case timed:
			v := max(p.speed, 0) / (width * SPEED_REFERENCE)
			// A brush reacts to a smaller speed: its hairs spread as soon as it slows.
			g := pen.nib == .Brush ? v / (0.35 + v) : v / (1 + v)
			p.factor = 1 - thinning * g
		case: p.factor = 1
		}
	}
	// Smoothed both ways over the arc length: one way would shift the thinning after the speed that caused it; the
	// length (and not the index) keeps the result the same at any spacing.
	reach := width * 1.5
	for i in 1 ..< n {
		a := 1 - math.exp(-(pts[i].s - pts[i - 1].s) / reach)
		pts[i].factor = pts[i - 1].factor + (pts[i].factor - pts[i - 1].factor) * a
	}
	for i := n - 2; i >= 0; i -= 1 {
		a := 1 - math.exp(-(pts[i + 1].s - pts[i].s) / reach)
		pts[i].factor = pts[i + 1].factor + (pts[i].factor - pts[i + 1].factor) * a
	}

	// A stroke shorter than its two tapers keeps their ratio: a lens, never a taper cut short.
	taper_start := max(pen.taper_start, 0)
	taper_end := max(pen.taper_end, 0)
	if taper_start + taper_end > total {
		k := total / (taper_start + taper_end)
		taper_start *= k
		taper_end *= k
	}
	angle := pen.nib_angle * math.RAD_PER_DEG
	nib := [2]f32{math.cos(angle), -math.sin(angle)}

	o := Outline {
		left        = make([][2]f32, n, allocator),
		right       = make([][2]f32, n, allocator),
		round_start = taper_start <= 0,
		round_end   = taper_end <= 0,
	}
	dir := [2]f32{1, 0}
	for p, i in pts {
		dir = tangent(pts[:], i, dir)
		w := width * p.factor
		if pen.nib == .Chisel {
			w *= max(abs(dir.x * nib.y - dir.y * nib.x), CHISEL_EDGE)
		}
		w = max(w, min_width)
		if taper_start > 0 { w *= ease(p.s / taper_start, pen.nib) }
		if taper_end > 0 { w *= ease((total - p.s) / taper_end, pen.nib) }
		side := [2]f32{-dir.y, dir.x} * (w * 0.5)
		o.left[i] = p.at + side
		o.right[i] = p.at - side
	}
	return o, pts[:]
}

// Frees what `outline` allocated; give the same allocator.
outline_destroy :: proc(o: ^Outline, allocator := context.allocator) {
	delete(o.left, allocator)
	delete(o.right, allocator)
	o^ = {}
}

// The ink as one closed polygon (its last point joins its first): the left edge forward, the end cap, the right edge
// backward, the start cap. A round cap adds CAP_POINTS points; a tapered end adds none. Fill it with the non-zero rule.
// The slice belongs to the caller: free it with `delete(points, allocator)`.
polygon :: proc(o: Outline, allocator := context.allocator) -> [][2]f32 {
	n := len(o.left)
	if n == 0 || len(o.right) != n { return nil }
	count := 2 * n + (o.round_start ? CAP_POINTS : 0) + (o.round_end ? CAP_POINTS : 0)
	out := make([][2]f32, count, allocator)
	k := 0
	for p in o.left { out[k] = p; k += 1 }
	if o.round_end { k += arc(out[k:], o.left[n - 1], o.right[n - 1]) }
	for i := n - 1; i >= 0; i -= 1 { out[k] = o.right[i]; k += 1 }
	if o.round_start { k += arc(out[k:], o.right[0], o.left[0]) }
	return out
}

// The ink as triangles, all counter-clockwise in a y-up frame: two per segment of the strip, a fan of CAP_POINTS + 1
// per round end. Where the stroke crosses itself or turns tighter than its half width, triangles overlap: draw them
// opaque (or into a layer) so a translucent ink is not laid twice. Free with `delete(tris, allocator)`.
triangles :: proc(o: Outline, allocator := context.allocator) -> [][3][2]f32 {
	n := len(o.left)
	if n == 0 || len(o.right) != n { return nil }
	fan :: CAP_POINTS + 1
	count := 2 * (n - 1) + (o.round_start ? fan : 0) + (o.round_end ? fan : 0)
	out := make([][3][2]f32, count, allocator)
	k := 0
	for i in 0 ..< n - 1 {
		out[k] = {o.left[i], o.right[i], o.left[i + 1]}
		out[k + 1] = {o.left[i + 1], o.right[i], o.right[i + 1]}
		k += 2
	}
	if o.round_end { k += cap_fan(out[k:], o.left[n - 1], o.right[n - 1]) }
	if o.round_start { k += cap_fan(out[k:], o.right[0], o.left[0]) }
	return out
}

@(private)
pressure_factor :: proc(pressure: f32, thinning: f32) -> f32 {
	return 1 - thinning * (1 - clamp(pressure, 0, 1))
}

// The ease of a taper at `t` (0 at the tip, 1 where it ends). A pen's taper widens fast and then holds (a quadratic
// ease out); a brush's is a soft S, its tip longer and finer.
@(private)
ease :: proc(t: f32, nib: Nib) -> f32 {
	x := clamp(t, 0, 1)
	if nib == .Brush { return (1 - math.cos(x * math.PI)) * 0.5 }
	return x * (2 - x)
}

@(private)
keep :: proc(line: ^[dynamic]Point, p: Point, eps: f32) {
	if length(p.at - line[len(line) - 1].at) > eps { append(line, p) }
}

@(private)
length :: proc(v: [2]f32) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }

// The speed at each sample, over a window of about SPEED_WINDOW_MS centred on it. False when the samples carry no
// time (the last no later than the first): the width then does not follow the speed.
@(private)
sample_speeds :: proc(samples: []Sample, speeds: []f32, allocator := context.allocator) -> bool {
	n := len(samples)
	if n < 2 || !(samples[n - 1].time > samples[0].time) { return false }
	along := make([]f32, n, allocator)
	defer delete(along, allocator)
	for i in 1 ..< n { along[i] = along[i - 1] + length(samples[i].at - samples[i - 1].at) }
	for i in 0 ..< n {
		lo, hi := i, i
		for samples[hi].time - samples[lo].time < SPEED_WINDOW_MS && (lo > 0 || hi < n - 1) {
			if lo > 0 { lo -= 1 }
			if samples[hi].time - samples[lo].time < SPEED_WINDOW_MS && hi < n - 1 { hi += 1 }
		}
		// The whole stroke spans a positive time, so the window, at worst the whole stroke, has one.
		dt := samples[hi].time - samples[lo].time
		speeds[i] = dt > 0 ? (along[hi] - along[lo]) / f32(dt) : 0
	}
	return true
}

// Centripetal Catmull-Rom (alpha 0.5) between p1 and p2 at u in 0..1: unlike the uniform one it makes no loop nor cusp
// where the samples are unevenly spaced. Adjacent points must differ (the streamline drops duplicates).
@(private)
catmull_rom :: proc(p0, p1, p2, p3: [2]f32, u: f32) -> [2]f32 {
	t0: f32 = 0
	t1 := t0 + math.sqrt(length(p1 - p0))
	t2 := t1 + math.sqrt(length(p2 - p1))
	t3 := t2 + math.sqrt(length(p3 - p2))
	t := t1 + (t2 - t1) * u
	a1 := (p0 * (t1 - t) + p1 * (t - t0)) / (t1 - t0)
	a2 := (p1 * (t2 - t) + p2 * (t - t1)) / (t2 - t1)
	a3 := (p2 * (t3 - t) + p3 * (t - t2)) / (t3 - t2)
	b1 := (a1 * (t2 - t) + a2 * (t - t0)) / (t2 - t0)
	b2 := (a2 * (t3 - t) + a3 * (t - t1)) / (t3 - t1)
	return (b1 * (t2 - t) + b2 * (t - t1)) / (t2 - t1)
}

// Points every `spacing` of arc length along the spline through `line` (at least 2 distinct points), the first and the
// last included. The last is moved to the stroke's end rather than followed by a sliver of a segment.
@(private)
resample :: proc(line: []Point, spacing: f32, out: ^[dynamic]Point) {
	k := len(line)
	first := line[0]
	first.s = 0
	append(out, first)
	acc: f32 = 0
	next := spacing
	for i in 0 ..< k - 1 {
		p1, p2 := line[i].at, line[i + 1].at
		p0 := i > 0 ? line[i - 1].at : 2 * p1 - p2
		p3 := i + 2 < k ? line[i + 2].at : 2 * p2 - p1
		steps := clamp(int(math.ceil(length(p2 - p1) / (spacing * 0.25))), 1, 1024)
		prev := p1
		for j in 1 ..= steps {
			u := f32(j) / f32(steps)
			q := j == steps ? p2 : catmull_rom(p0, p1, p2, p3, u)
			d := length(q - prev)
			for d > 0 && next <= acc + d {
				f := (next - acc) / d
				w := (f32(j - 1) + f) / f32(steps)
				append(out, Point {
					at       = prev + (q - prev) * f,
					pressure = math.lerp(line[i].pressure, line[i + 1].pressure, w),
					speed    = math.lerp(line[i].speed, line[i + 1].speed, w),
					s        = next,
				})
				next += spacing
			}
			acc += d
			prev = q
		}
	}
	end := line[k - 1]
	end.s = acc
	if len(out) > 1 && acc - out[len(out) - 1].s < spacing * 0.25 {
		out[len(out) - 1] = end
	} else {
		append(out, end)
	}
}

// The unit direction of travel at point i; `fallback` (the previous one) where the neighbours coincide.
@(private)
tangent :: proc(pts: []Point, i: int, fallback: [2]f32) -> [2]f32 {
	n := len(pts)
	d := pts[min(i + 1, n - 1)].at - pts[max(i - 1, 0)].at
	if l := length(d); l > 1e-12 { return d / l }
	// A hairpin whose neighbours meet: the segment ahead still has a direction.
	d = pts[min(i + 1, n - 1)].at - pts[i].at
	if l := length(d); l > 1e-12 { return d / l }
	return fallback
}

@(private)
dot :: proc(at: [2]f32, w: f32, allocator := context.allocator) -> Outline {
	o := Outline {
		left        = make([][2]f32, 1, allocator),
		right       = make([][2]f32, 1, allocator),
		round_start = true,
		round_end   = true,
	}
	o.left[0] = at + [2]f32{0, w * 0.5}
	o.right[0] = at - [2]f32{0, w * 0.5}
	return o
}

// Writes the CAP_POINTS points strictly between `from` and `to` on the half circle of which they are the diameter,
// turning from `from` by decreasing angles: from the left edge that is through the direction of travel, so the end
// cap bulges forward and the start cap (from the right edge) backward.
@(private)
arc :: proc(out: [][2]f32, from, to: [2]f32) -> int {
	c := (from + to) * 0.5
	v := from - c
	r := length(v)
	a0 := math.atan2(v.y, v.x)
	for i in 1 ..= CAP_POINTS {
		a := a0 - math.PI * f32(i) / f32(CAP_POINTS + 1)
		out[i - 1] = c + [2]f32{math.cos(a), math.sin(a)} * r
	}
	return CAP_POINTS
}

@(private)
cap_fan :: proc(out: [][3][2]f32, from, to: [2]f32) -> int {
	ring: [CAP_POINTS + 2][2]f32
	ring[0] = from
	arc(ring[1:CAP_POINTS + 1], from, to)
	ring[CAP_POINTS + 1] = to
	c := (from + to) * 0.5
	// The arc turns clockwise (y up): each triangle is listed backward to stay counter-clockwise as the strip's.
	for i in 0 ..< CAP_POINTS + 1 { out[i] = {c, ring[i + 1], ring[i]} }
	return CAP_POINTS + 1
}
