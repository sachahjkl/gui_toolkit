// The ink model: the outline cut into pieces, each with how much ink it carries, so a pen's ink can look like ink
// (translucent layers, a slow hand's dark turns, pools, a ballpoint's skips, the paper's grain). Pure geometry, as the
// outline. See docs/ink.md and src/md/features/ink.md.
package tk_ink

import "core:math"

// A piece of the ink: four corners and its density (0..1, multiplying the ink's opacity). A segment's piece runs along
// the left edge, then back along the right edge: {left i, left i+1, right i+1, right i}; a cap's or a join's: its
// centre, then three points of its arc; a broad nib's footprint: its rectangle. Its turn is not fixed: `levels`
// orients it.
Piece :: struct {
	quad:    [4][2]f32,
	density: f32,
}

// A pool of ink where the nib rested: a drop about `center`, laid over the line (its density adds to the line's where
// they overlap). `levels` draws its shape: the radius modulated around it, and at an end drawn out into the stroke.
Blob :: struct {
	center:    [2]f32, // where the nib rested
	radius:    f32,
	density:   f32,
	direction: [2]f32, // a unit vector into the stroke from this end; {0, 0}: none (a stop, a dot), no stretch
	seed:      u32,    // the drop's shape: the same seed, the same drop
}

// One stroke's ink. `opacity` is the pen's (Ink.opacity, 0 read as 1). The slices belong to the caller: free them with
// `laid_destroy` and the allocator that `lay` was given.
Laid :: struct {
	pieces:  []Piece,
	blobs:   []Blob,
	opacity: f32,
}

// One fill of the ink: every contour in it is filled with the same alpha (the non-zero rule), one path. Each contour is
// counter-clockwise in a y-up frame (a positive shoelace area), so within a level nothing cancels. `points` holds every
// contour's points (the contours are slices of it): `levels_destroy` frees it.
Level :: struct {
	alpha:    f32,
	contours: [][][2]f32,
	points:   [][2]f32,
}

// Where the skip's flicker thins the ink to nothing: a true gap. Under it the piece is dropped; above it, faint ink.
@(private)
SKIP_HOLE :: 0.12
// The faintest a starved ballpoint lays, where it still lays something.
@(private)
SKIP_FAINT :: 0.35
// The length, in widths, over which a ballpoint primes: the ink not yet on the ball at a stroke's start.
@(private)
SKIP_PRIMING :: 4.5
// The share of the width a fully starved ball leaves bare beside the edge it keeps: the scratch.
@(private)
SKIP_SCRATCH :: 0.6
// How much a fast hand lightens the ink at Ink.dwell 1: the density at an infinite speed.
@(private)
DWELL_RANGE :: 0.6
// How much the lightest stylus pressure lightens the ink at Ink.pressure 1.
@(private)
PRESSURE_RANGE :: 0.6
// The edges' roughness at Ink.grain 1, as a share of the local width, on each side.
@(private)
GRAIN_EDGE :: 0.14
// The lightest a streak makes a lane: a felt's streaks are lighter ink, never paper.
@(private)
GRAIN_LIGHT :: 0.55
// Over this grain the outer lanes may run bare: a dry brush's tail.
@(private)
GRAIN_DRY :: 0.5
// A turn sharper than this (radians, between consecutive pieces) gets a join: the outline's outer edge would show a
// corner there.
@(private)
JOIN_TURN :: 0.3
// The points of a join's circle (a multiple of 2, for its quads).
@(private)
JOIN_POINTS :: 16
// A stop: the samples stay within half a width for this long (milliseconds), and the nib leaves a pool.
@(private)
POOL_STOP_MS :: 150
// A contour of less area than this (in the caller's units squared) is a point or a line: `levels` leaves it out.
@(private)
AREA_EPSILON :: 1e-6
// The points of a blob's outline in `levels`: more than a disc's, for the harmonics and the teardrop's tip.
@(private)
BLOB_POINTS :: 32

// The ink of one stroke, as pieces and blobs. `seed` picks the noises (skip, grain): the same seed lays the same ink,
// so a drawing looks the same at every render. All Ink fields zero: the pieces cover the outline's polygon, density 1;
// a Chisel's cover the nib's sweep, of which its polygon is an approximation.
lay :: proc(samples: []Sample, pen: Pen, seed: u32, allocator := context.allocator) -> Laid {
	o, pts := trace(samples, pen, allocator)
	defer outline_destroy(&o, allocator)
	defer delete(pts, allocator)
	n := len(o.left)
	if n == 0 { return {} }
	ink := pen.ink
	width := pen.width
	opacity := ink.opacity > 0 ? clamp(ink.opacity, 0, 1) : 1
	skip := clamp(ink.skip, 0, 1)
	grain := clamp(ink.grain, 0, 1)
	dwell := clamp(ink.dwell, 0, 1)
	press := clamp(ink.pressure, 0, 1)
	total := pts[n - 1].s

	left := make([][2]f32, n, allocator)
	right := make([][2]f32, n, allocator)
	defer delete(left, allocator)
	defer delete(right, allocator)
	copy(left, o.left)
	copy(right, o.right)
	// A broad nib's ink is its sweep: the nib's two corners at each point, not the outline's offset square to the path,
	// whose lobes reach past the nib in a turn tighter than it and leave a notch between them. Each segment's piece is
	// then the nib swept from one point to the next; where the stroke runs along the nib's edge the two corners' paths
	// meet or cross, and `levels` turns or splits the piece. The grain and the skip below act on these edges as on any.
	chisel := pen.nib == .Chisel
	if chisel {
		for p, i in pts {
			h := p.edge * (p.span * 0.5)
			left[i] = p.at + h
			right[i] = p.at - h
		}
	}

	// The ink a point carries from the hand's pace and pressure; the skip and the grain then act per piece.
	ink_at := make([]f32, n, allocator)
	defer delete(ink_at, allocator)
	for p, i in pts {
		d: f32 = 1
		if p.speed >= 0 {
			// A nib leaves ink for the time it spends on a length: full at rest, half the range lost at the reference
			// speed, the width's own response, so a slow turn is both wider and darker.
			d *= 1 - dwell * DWELL_RANGE * pace(p.speed, width)
		}
		if p.pressure > 0 { d *= 1 - press * PRESSURE_RANGE * (1 - clamp(p.pressure, 0, 1)) }
		// A leaned felt or brush lays its side, broader (the outline) and lighter. A chisel's corners stay on the paper.
		if pen.nib != .Chisel { d *= 1 - TILT_LIGHT * clamp(pen.tilt, 0, 1) * length(p.lean) }
		ink_at[i] = d
	}

	// The paper's grain moves the edges by a smooth noise along the stroke, as a share of the local width: a taper
	// still ends in a point, and the edges never cross (each moves less than a quarter of the width).
	if grain > 0 {
		for i in 0 ..< n {
			across := left[i] - right[i]
			w := length(across)
			if !(w > 1e-6) { continue }
			u := pts[i].s / width
			nrm := across / w
			left[i] += nrm * (w * grain * GRAIN_EDGE * (fine_noise(u, seed + 101) * 2 - 1))
			right[i] -= nrm * (w * grain * GRAIN_EDGE * (fine_noise(u, seed + 211) * 2 - 1))
		}
	}

	// The skip's bursts, per point and smoothed over the arc length, so a burst eases in and out over a width or two:
	// the scratch then tapers into the full line instead of stepping by whole pieces.
	burst := make([]f32, n, allocator)
	defer delete(burst, allocator)
	if skip > 0 {
		for i in 0 ..< n { burst[i] = skip_burst(pts, i, width, skip, seed) }
		smooth(pts, burst, width * 1.2)
		for i in 0 ..< n {
			// The scratch: a starved ball keeps one edge and leaves the other side bare. The side is a smooth share,
			// so it moves across the line, through a centred thin line, rather than jump.
			inset := SKIP_SCRATCH * burst[i]
			if inset <= 0 { continue }
			l := smoothstep(0.3, 0.7, vnoise(pts[i].s / width / 2.7, seed + 307))
			a, b := left[i], right[i]
			left[i] = a + (b - a) * (inset * l)
			right[i] = b + (a - b) * (inset * (1 - l))
		}
	}

	pieces := make([dynamic]Piece, 0, 2 * n + 8, allocator)
	blobs := make([dynamic]Blob, 0, 4, allocator)

	// The skip's amount per segment first: a stroke never vanishes entirely, so a stroke whose every segment starved
	// is laid faint instead.
	segs := max(n - 1, 0)
	amount := make([]f32, segs, allocator)
	defer delete(amount, allocator)
	any_ink := false
	for i in 0 ..< segs {
		amount[i] = skip_amount((burst[i] + burst[i + 1]) * 0.5, (pts[i].s + pts[i + 1].s) * 0.5 / width, seed)
		if amount[i] > 0 { any_ink = true }
	}
	if !any_ink { for &a in amount { a = SKIP_FAINT } }

	// A felt streaks in a few broad lanes, a brush in more and finer: its hairs.
	lane_count := grain > GRAIN_DRY ? 5 : 3
	for i in 0 ..< segs {
		a := amount[i]
		if a <= 0 { continue }
		q := [4][2]f32{left[i], left[i + 1], right[i + 1], right[i]}
		d := (ink_at[i] + ink_at[i + 1]) * 0.5 * a
		if chisel {
			m0, m1 := thickness(pts[i]), thickness(pts[i + 1])
			if grain <= 0 {
				// The nib is a rectangle, and a convex shape swept along a step is itself at both ends and, between
				// them, its chord between the two corners furthest out on either side of the step swept along it: here
				// the diagonal most square to the step. The rectangles are laid at each point below. Refused: the
				// nib's length swept alone, with its thickness swept along the path (the hairline then rose as a bump
				// over its flat side, short of the nib's corners); the hull of the two rectangles cut in a fan (each
				// fan's quads grown about their own centres by `levels` pushed a shared corner two ways, and the edge
				// showed ticks).
				step := pts[i + 1].at - pts[i].at
				h0 := (left[i] - right[i]) * 0.5
				sh: f32 = cross(step, h0) >= 0 ? 1 : -1
				sm: f32 = cross(step, m0) >= 0 ? 1 : -1
				c0, c1 := (left[i] + right[i]) * 0.5, (left[i + 1] + right[i + 1]) * 0.5
				v0 := sh * h0 + sm * m0
				v1 := sh * (left[i + 1] - right[i + 1]) * 0.5 + sm * m1
				append(&pieces, Piece{{c0 + v0, c1 + v1, c1 - v1, c0 - v0}, d})
				continue
			}
			// Grained: the lanes below need the length's quad; the thickness swept along the path gives the hairline.
			append(&pieces, Piece{{pts[i].at + m0, pts[i + 1].at + m1, pts[i + 1].at - m1, pts[i].at - m0}, d})
		}
		if grain <= 0 {
			append(&pieces, Piece{q, d})
			continue
		}
		// The paper shows through where the pen runs dry: where the hand is fast and toward the stroke's end.
		s := (pts[i].s + pts[i + 1].s) * 0.5
		fast: f32 = pts[i].speed >= 0 ? pace(pts[i].speed, width) : 0
		progress := s / max(total, 1e-6)
		// A minority of the lanes at once: when most inner lanes went light together, the dark outer ones drew a
		// stroke's outline, rails again.
		streak := grain * (0.3 + 0.2 * fast + 0.15 * progress)
		bare: f32 = 0
		if grain > GRAIN_DRY {
			tail := max(clamp((fast - 0.5) / 0.35, 0, 1), clamp((progress - 0.7) / 0.3, 0, 1))
			bare = (grain - GRAIN_DRY) * 2 * tail * 0.6
		}
		lanes(&pieces, q, d, pts[i].s / width, pts[i + 1].s / width, lane_count, streak, bare, seed)
	}

	// The round ends, as the polygon's caps: a fan cut into quads (the centre and three points of the arc each).
	// A cap carries its segment's ink; a skipped segment leaves its cap out too. A broad nib has no round end: its
	// sweep ends with the nib itself. Its rectangle is laid at every point (the sweep's other part, above), at the
	// ends only when grained (the lanes would be covered), and a dot is the nib alone.
	if chisel {
		for i in 0 ..< n {
			if grain > 0 && i != 0 && i != n - 1 { continue }
			a: f32 = 1
			if segs > 0 { a = max(amount[max(i - 1, 0)], amount[min(i, segs - 1)]) }
			if a > 0 { footprint(&pieces, left[i], right[i], thickness(pts[i]), ink_at[i] * a) }
		}
	} else if o.round_end {
		a: f32 = segs > 0 ? amount[segs - 1] : 1
		if a > 0 { cap_pieces(&pieces, left[n - 1], right[n - 1], ink_at[n - 1] * a) }
	}
	if !chisel && o.round_start {
		a: f32 = segs > 0 ? amount[0] : 1
		if a > 0 { cap_pieces(&pieces, right[0], left[0], ink_at[0] * a) }
	}

	// A round nib at a cusp: the resampling keeps turns under RESAMPLE_TURN but for its minimum step, so where the path
	// turns sharper than that at one point its outer edge jumps and shows a corner (and its inner edge folds). A disc
	// of the local width at each such point is what a round nib sweeps there: the cusp reads as a rounded bulge. A broad
	// nib's ink is already its sweep.
	if pen.nib != .Chisel {
		for i in 1 ..< n - 1 {
			d0 := pts[i].at - pts[i - 1].at
			d1 := pts[i + 1].at - pts[i].at
			l0, l1 := length(d0), length(d1)
			if !(l0 > 1e-6 && l1 > 1e-6) { continue }
			turn := math.acos(clamp((d0.x * d1.x + d0.y * d1.y) / (l0 * l1), -1, 1))
			if turn < JOIN_TURN { continue }
			a := max(amount[i - 1], amount[i])
			if a <= 0 { continue }
			// The width as laid (a scratch's narrowing included): the disc must not fill what the skip left bare.
			r := length(left[i] - right[i]) * 0.5
			join_pieces(&pieces, (left[i] + right[i]) * 0.5, r, ink_at[i] * a)
		}
	}

	if ink.pool > 0 { pools(&blobs, samples, pen, n == 1, seed) }

	return Laid{pieces = pieces[:], blobs = blobs[:], opacity = opacity}
}

// Frees what `lay` allocated; give the same allocator.
laid_destroy :: proc(l: ^Laid, allocator := context.allocator) {
	delete(l.pieces, allocator)
	delete(l.blobs, allocator)
	l^ = {}
}

// The ink as a few fills, stacked. The pieces' densities are quantized to `count` steps; each step that holds a piece
// gives a level that holds every piece at that step or above, so the first level is the stroke's whole ink as one
// union and each next one darkens over it. A level's alpha is chosen so the levels stacked over each other (source
// over) give each piece the opacity times its step. Then the blobs, grouped the same way into levels of their own (not
// stacked: each is ink laid on the line), so a blob lies over the line and darkens it. Fill each level as one path with
// the non-zero rule, in order, the ink's colour at the level's alpha. Free with `levels_destroy`.
levels :: proc(laid: Laid, level_count: int, allocator := context.allocator) -> []Level {
	// (each contour grown a little about its centre, `overlap`: two neighbouring pieces of a level overlap instead of
	// meeting on an edge. A renderer that smooths every edge it is near, as gt:draw's path fill, measures distance to
	// edges where the fill changes; two pieces that only touch put two opposite edges on one line, each of which looks
	// like a boundary on its own, and the seam showed as a hatching across the stroke. Overlapping, each such edge lies
	// inside the other piece. The union, the PDF's fill, grows by LEVEL_OVERLAP of a piece: nothing seen.)
	count := max(level_count, 1)
	out := make([dynamic]Level, 0, 2 * count, allocator)
	sizes := make([]int, 2 * count, allocator)
	shapes := make([]int, 2 * count, allocator)
	held := make([]bool, 2 * count, allocator)
	defer delete(sizes, allocator)
	defer delete(shapes, allocator)
	defer delete(held, allocator)

	// Counted first, so each level's points are one allocation.
	for p in laid.pieces {
		b := bucket(p.density, count)
		if b < 0 { continue }
		buf: [2][4][2]f32
		lens: [2]int
		k := piece_contours(p.quad, &buf, &lens)
		if k == 0 { continue }
		held[b] = true
		// Stacked: a piece is in every level up to its own.
		for lv in 0 ..= b {
			shapes[lv] += k
			for j in 0 ..< k { sizes[lv] += lens[j] }
		}
	}
	for bl in laid.blobs {
		b := bucket(bl.density, count)
		if b < 0 || !(bl.radius > 0) { continue }
		held[count + b] = true
		shapes[count + b] += 1
		sizes[count + b] += BLOB_POINTS
	}

	below: f32 = 0   // the coverage the levels laid so far give
	for b in 0 ..< 2 * count {
		if !held[b] { continue }
		target := laid.opacity * f32(b % count + 1) / f32(count)
		alpha := target
		if b < count {
			// Source over: 1 - (1 - below) (1 - alpha) = target.
			alpha = below < 1 ? clamp(1 - (1 - target) / (1 - below), 0, 1) : 0
			below = target
		}
		lv := Level {
			alpha    = alpha,
			contours = make([][][2]f32, shapes[b], allocator),
			points   = make([][2]f32, sizes[b], allocator),
		}
		at, c := 0, 0
		if b < count {
			for p in laid.pieces {
				if bucket(p.density, count) < b { continue }
				buf: [2][4][2]f32
				lens: [2]int
				k := piece_contours(p.quad, &buf, &lens)
				for j in 0 ..< k {
					overlap(buf[j][:lens[j]])
					copy(lv.points[at:], buf[j][:lens[j]])
					lv.contours[c] = lv.points[at:at + lens[j]]
					at += lens[j]
					c += 1
				}
			}
		} else {
			for bl in laid.blobs {
				if bucket(bl.density, count) != b - count || !(bl.radius > 0) { continue }
				ring := lv.points[at:at + BLOB_POINTS]
				drop(bl, ring)
				lv.contours[c] = ring
				at += BLOB_POINTS
				c += 1
			}
		}
		append(&out, lv)
	}
	return out[:]
}

// Frees what `levels` allocated; give the same allocator.
// How much `levels` grows each contour about its centre: a share of its size.
@(private)
LEVEL_OVERLAP :: 0.06

@(private)
overlap :: proc(c: [][2]f32) {
	if len(c) == 0 { return }
	mid: [2]f32
	for q in c { mid += q }
	mid /= f32(len(c))
	for &q in c { q = mid + (q - mid) * (1 + LEVEL_OVERLAP) }
}

levels_destroy :: proc(ls: []Level, allocator := context.allocator) {
	for l in ls {
		delete(l.points, allocator)
		delete(l.contours, allocator)
	}
	delete(ls, allocator)
}

// The step of a density: 0 for (0, 1/count], count - 1 for the full ink; -1 for none.
@(private)
bucket :: proc(density: f32, count: int) -> int {
	if !(density > 0) { return -1 }
	return clamp(int(math.ceil(min(density, 1) * f32(count))) - 1, 0, count - 1)
}

// A piece as positive contours, written to `buf` with their point counts in `lens`: the quad itself when convex, else
// its two triangles split as `triangles` splits a segment (a quad that folds at a tight turn would have a lobe of each
// turn, and the negative lobe would cut a hole in its neighbours under the non-zero rule). A contour without area (a
// taper's tip) is left out: it has no turn to give. Returns the contour count.
@(private)
piece_contours :: proc(q: [4][2]f32, buf: ^[2][4][2]f32, lens: ^[2]int) -> int {
	pos, neg := false, false
	for i in 0 ..< 4 {
		a, b, c := q[i], q[(i + 1) % 4], q[(i + 2) % 4]
		z := cross(b - a, c - b)
		if z > 0 { pos = true }
		if z < 0 { neg = true }
	}
	k := 0
	if !(pos && neg) {
		buf[0] = q
		area := signed_area(buf[0][:])
		if area < 0 { buf[0][1], buf[0][3] = q[3], q[1] }
		if abs(area) > AREA_EPSILON { lens[0] = 4; k = 1 }
		return k
	}
	tris := [2][3][2]f32{{q[0], q[3], q[1]}, {q[1], q[3], q[2]}}
	for t in tris {
		buf[k][0], buf[k][1], buf[k][2] = t[0], t[1], t[2]
		area := signed_area(buf[k][:3])
		if area < 0 { buf[k][1], buf[k][2] = t[2], t[1] }
		if abs(area) > AREA_EPSILON { lens[k] = 3; k += 1 }
	}
	return k
}

@(private)
cross :: proc(a, b: [2]f32) -> f32 { return a.x * b.y - a.y * b.x }

// The shoelace area: positive when counter-clockwise in a y-up frame.
@(private)
signed_area :: proc(p: [][2]f32) -> f32 {
	if len(p) == 0 { return 0 }
	// (about the first point: far from the origin, f32's products would lose a small piece's area)
	o := p[0]
	sum: f32 = 0
	for i in 0 ..< len(p) { sum += cross(p[i] - o, p[(i + 1) % len(p)] - o) }
	return sum * 0.5
}

// The speed's share, 0 at rest, a half at the reference speed, 1 only at infinity: the width's own response.
@(private)
pace :: proc(speed, width: f32) -> f32 {
	v := max(speed, 0) / (width * SPEED_REFERENCE)
	return v / (1 + v)
}

@(private)
smoothstep :: proc(lo, hi, x: f32) -> f32 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}

// `v`, one value per point, smoothed both ways over the arc length with `reach`: as the width is, so the result does
// not depend on the spacing and is not shifted along the stroke.
@(private)
smooth :: proc(pts: []Point, v: []f32, reach: f32) {
	n := len(pts)
	for i in 1 ..< n {
		a := 1 - math.exp(-(pts[i].s - pts[i - 1].s) / reach)
		v[i] = v[i - 1] + (v[i] - v[i - 1]) * a
	}
	for i := n - 2; i >= 0; i -= 1 {
		a := 1 - math.exp(-(pts[i + 1].s - pts[i].s) / reach)
		v[i] = v[i + 1] + (v[i] - v[i + 1]) * a
	}
}

// How starved a ballpoint is at point i, 0..1: 0 is a solid line. A risk (the hand's speed, an upstroke: a lighter
// hand with y down, the priming at the start, a slow noise) decides where; under a threshold the line is solid, so
// the starvation comes in bursts, not as an even thinning.
@(private)
skip_burst :: proc(pts: []Point, i: int, width, skip: f32, seed: u32) -> f32 {
	n := len(pts)
	u := pts[i].s / width
	fast: f32 = pts[i].speed >= 0 ? clamp((pts[i].speed / (width * SPEED_REFERENCE) - 0.5) / 1.5, 0, 1) : 0
	d := pts[min(i + 1, n - 1)].at - pts[max(i - 1, 0)].at
	l := length(d)
	up: f32 = l > 1e-6 ? clamp(-d.y / l, 0, 1) : 0
	prime := clamp(1 - u / SKIP_PRIMING, 0, 1)
	risk := fast * 0.5 + up * 0.3 + prime * 0.6 + (skip_noise(u, seed) - 0.5) * 1.3
	return clamp((risk * skip - 0.2) / 0.35, 0, 1)
}

// How much ink a piece in a burst lays (0: a gap; else SKIP_FAINT..1): inside a burst the ball catches and slips at a
// short scale, faint dashes and, where the flicker falls low, true gaps. `u` is in widths.
@(private)
skip_amount :: proc(burst, u: f32, seed: u32) -> f32 {
	if burst <= 0 { return 1 }
	// Over a width or more: at the pieces' own spacing the shade would step at every piece and read as blocks.
	flicker := 0.6 * vnoise(u / 1.4, seed + 503) + 0.4 * vnoise(u / 0.6, seed + 509)
	a := clamp(1 - burst * (0.35 + 0.9 * flicker), 0, 1)
	if a < SKIP_HOLE { return 0 }
	return SKIP_FAINT + (1 - SKIP_FAINT) * a
}

// A piece split into `count` lanes along the stroke: the streaks a felt or a brush leaves on grained paper. The lanes'
// boundaries wander across the width, each by its own smooth noise of the arc length (`u0`, `u1`: the piece's ends, in
// widths, so neighbouring pieces meet), so the streaks never run as parallel rails. A lane's streak is lighter ink, at
// worst GRAIN_LIGHT; `bare` (a dry brush's tail) lets the outer lanes leave the paper bare.
@(private)
lanes :: proc(out: ^[dynamic]Piece, q: [4][2]f32, density, u0, u1: f32, count: int, streak, bare: f32, seed: u32) {
	edge :: proc(j, count: int, u: f32, seed: u32) -> f32 {
		if j == 0 { return 0 }
		if j == count { return 1 }
		// At most 0.4 of a lane each way: two boundaries never cross.
		jitter := (vnoise(u / 1.8 + f32(j) * 13.1, seed + 601 + u32(j) * 37) * 2 - 1) * 0.4 / f32(count)
		return f32(j) / f32(count) + jitter
	}
	u := (u0 + u1) * 0.5
	for k in 0 ..< count {
		a0, b0 := edge(k, count, u0, seed), edge(k + 1, count, u0, seed)
		a1, b1 := edge(k, count, u1, seed), edge(k + 1, count, u1, seed)
		lane := [4][2]f32 {
			q[0] + (q[3] - q[0]) * a0,
			q[1] + (q[2] - q[1]) * a1,
			q[1] + (q[2] - q[1]) * b1,
			q[0] + (q[3] - q[0]) * b0,
		}
		// The streaks are long (several widths, their lengths varied by a warp) and each lane has its own.
		s := u32(k) * 59
		w := u + 2 * vnoise(u / 4.3, seed + 433 + s)
		nz := vnoise(w / 2.6, seed + 401 + s)
		outer := k == 0 || k == count - 1
		if outer && nz > 1 - bare { continue }
		// A light outer lane over a long stretch reads as a border, a second line beside the stroke: the outer lanes
		// streak less often than the inner ones.
		reach := outer ? streak * 0.6 : streak
		light := smoothstep(1 - reach, 1 - reach + 0.3, nz)
		append(out, Piece{lane, density * (1 - (1 - GRAIN_LIGHT) * light)})
	}
}

// A round end as four quads: the centre, then three consecutive points of its arc from `from` to `to`.
@(private)
cap_pieces :: proc(out: ^[dynamic]Piece, from, to: [2]f32, density: f32) {
	if !(density > 0) { return }
	ring: [CAP_POINTS + 2][2]f32
	ring[0] = from
	arc(ring[1:CAP_POINTS + 1], from, to)
	ring[CAP_POINTS + 1] = to
	c := (from + to) * 0.5
	for j := 0; j + 2 < len(ring); j += 2 {
		append(out, Piece{{c, ring[j], ring[j + 1], ring[j + 2]}, density})
	}
}

// A disc at a tight turn, as quads: the centre, then three consecutive points of its circle.
@(private)
join_pieces :: proc(out: ^[dynamic]Piece, c: [2]f32, r, density: f32) {
	if !(density > 0) || !(r > 1e-6) { return }
	ring: [JOIN_POINTS + 1][2]f32
	for j in 0 ..= JOIN_POINTS {
		a := 2 * math.PI * f32(j) / JOIN_POINTS
		ring[j] = c + [2]f32{math.cos(a), math.sin(a)} * r
	}
	for j := 0; j + 2 <= JOIN_POINTS; j += 2 {
		append(out, Piece{{c, ring[j], ring[j + 1], ring[j + 2]}, density})
	}
}

// Half a broad nib's thickness at a point, square to its edge.
@(private)
thickness :: proc(p: Point) -> [2]f32 { return [2]f32{-p.edge.y, p.edge.x} * (p.thick * 0.5) }

// A broad nib's footprint as one piece: its rectangle, from its corner `l` to its corner `r` along its edge and `m`
// each way across.
@(private)
footprint :: proc(out: ^[dynamic]Piece, l, r, m: [2]f32, density: f32) {
	if !(density > 0) || !(length(l - r) > 1e-6) { return }
	append(out, Piece{{l - m, r - m, r + m, l + m}, density})
}

// The pools: a blob at each end of the stroke (one for a dot) and at each stop inside it, larger the longer the nib
// rested. Each has its own seed, from the stroke's and its index: every drop of a stroke is another shape.
@(private)
pools :: proc(out: ^[dynamic]Blob, samples: []Sample, pen: Pen, dot: bool, seed: u32) {
	pool := clamp(pen.ink.pool, 0, 1)
	radius := pen.width * (0.22 + 0.25 * pool)
	density := 0.55 + 0.45 * pool
	grow :: proc(ms: f64) -> f32 { return 1 + 0.5 * f32(clamp(ms / 600, 0, 1)) }
	n := len(samples)
	reach := pen.width * 0.5
	count := 0
	blob :: proc(out: ^[dynamic]Blob, count: ^int, at: [2]f32, radius, density: f32, direction: [2]f32, seed: u32) {
		append(out, Blob{at, radius, density, direction, seed * 2654435761 + u32(count^) * 40503 + 17})
		count^ += 1
	}
	// From an end into the stroke: toward the first sample more than `reach` away (the last one if none is).
	into :: proc(samples: []Sample, from, step: int, reach, eps: f32) -> [2]f32 {
		far: [2]f32
		for j := from + step; j >= 0 && j < len(samples); j += step {
			far = samples[j].at - samples[from].at
			if length(far) > reach { break }
		}
		l := length(far)
		return l > eps ? far / l : {}
	}
	eps := pen.width * 1e-3
	start_ms, end_ms: f64
	a := 0
	for a < n {
		b := a + 1
		sum := samples[a].at
		for b < n && length(samples[b].at - samples[a].at) <= reach {
			sum += samples[b].at
			b += 1
		}
		ms := samples[b - 1].time - samples[a].time
		switch {
		case a == 0: start_ms = ms
		case b == n: end_ms = ms
		case ms >= POOL_STOP_MS:
			blob(out, &count, sum / f32(b - a), radius * grow(ms), density, {}, seed)
		}
		if a == 0 && b == n { end_ms = ms }
		a = b
	}
	start_dir: [2]f32 = dot ? {} : into(samples, 0, 1, reach, eps)
	blob(out, &count, samples[0].at, radius * grow(start_ms), density, start_dir, seed)
	if !dot { blob(out, &count, samples[n - 1].at, radius * grow(end_ms), density, into(samples, n - 1, -1, reach, eps), seed) }
}

// A pool's outline in `ring`, counter-clockwise in a y-up frame: a circle whose radius is modulated by its 2nd and 3rd
// harmonics, and with a direction a teardrop drawn out into the stroke, its centre moved a fifth of the radius in.
// Star-shaped about its centre (the radius stays above 0.7 of it), so it never crosses itself.
@(private)
drop :: proc(b: Blob, ring: [][2]f32) {
	a2 := 0.08 + 0.06 * hash(1, b.seed)
	a3 := 0.04 + 0.04 * hash(2, b.seed)
	p2 := 2 * math.PI * hash(3, b.seed)
	p3 := 2 * math.PI * hash(4, b.seed)
	t := [2]f32{1, 0}
	stretch: f32 = 1
	c := b.center
	if l := length(b.direction); l > 1e-6 {
		t = b.direction / l
		stretch = 1.2 + 0.3 * hash(5, b.seed)
		c += t * (b.radius * 0.2)
		// The 2nd harmonic is an elongation of its own: within ±45° of the stroke, never across it, where it would
		// cancel the teardrop and leave a drop lying across the line.
		p2 = (hash(3, b.seed) - 0.5) * math.PI
	}
	// Narrowed across so the teardrop's area stays near the disc's: its two halves average (1 + stretch) / 2 along.
	across := 1 / math.sqrt((1 + stretch) * 0.5)
	nrm := [2]f32{-t.y, t.x}   // (t, nrm) keeps the frame's turn: the ring stays counter-clockwise
	for j in 0 ..< len(ring) {
		phi := 2 * math.PI * f32(j) / f32(len(ring))
		r := b.radius * (1 + a2 * math.cos(2 * phi + p2) + a3 * math.cos(3 * phi + p3))
		x := r * math.cos(phi)
		y := r * math.sin(phi) * across
		// Only the half toward the stroke is drawn out: at phi = ±90° x is 0, so the two halves meet smoothly.
		if x > 0 { x *= stretch }
		ring[j] = c + t * x + nrm * y
	}
}

// Smooth value noise, 0..1: a cosine between hashed values at whole steps. Not periodic: every step has its own value.
@(private)
vnoise :: proc(x: f32, seed: u32) -> f32 {
	fl := math.floor(x)
	i := i32(fl)
	f := x - fl
	k := (1 - math.cos(f * math.PI)) * 0.5
	return hash(i, seed) * (1 - k) + hash(i + 1, seed) * k
}

@(private)
hash :: proc(i: i32, seed: u32) -> f32 {
	h := u32(i) * 374761393 + seed * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	return f32((h ~ (h >> 16)) & 0xFFFF) / 65535
}

// The skip's noise along the stroke, `u` in widths: three octaves at wavelengths whose ratios are not whole (a run of
// good ink and a run of bad never repeat in step), along a length itself warped by a slower noise, so the skips' and
// the gaps' lengths vary.
@(private)
skip_noise :: proc(u: f32, seed: u32) -> f32 {
	w := u + 4 * vnoise(u / 9.7, seed + 13)
	return 0.5 * vnoise(w / 11, seed) + 0.33 * vnoise(w / 4.3, seed + 7) + 0.17 * vnoise(w / 1.7, seed + 29)
}

// The edges' roughness along the stroke, `u` in widths: about a width, with a slower swell. Not finer: the points are
// 0.3 width apart, and a finer noise turns the edge into a line of kinks.
@(private)
fine_noise :: proc(u: f32, seed: u32) -> f32 {
	return 0.6 * vnoise(u / 1.1, seed) + 0.4 * vnoise(u / 3.1, seed + 3)
}
