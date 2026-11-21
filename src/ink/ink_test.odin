// The ink's widths against the pen's options, the polygon's and the triangles' shapes, and no NaN on degenerate input.
//   odin test src/ink -vet
package tk_ink

import "core:math"
import "core:testing"
import turn "../turn"

// A stroke along `dir` from the origin: `count` samples `step` apart, `dt` milliseconds apart.
@(private = "file")
straight :: proc(count: int, step: f32, dt: f64, dir: [2]f32 = {1, 0}, allocator := context.temp_allocator) -> []Sample {
	s := make([]Sample, count, allocator)
	for i in 0 ..< count { s[i] = {at = dir * (step * f32(i)), time = dt * f64(i)} }
	return s
}

@(private = "file")
width_at :: proc(o: Outline, i: int) -> f32 { return length(o.left[i] - o.right[i]) }

// The width in the middle half of the stroke: away from the ends and their smoothing.
@(private = "file")
middle_width :: proc(o: Outline) -> (lo, hi: f32) {
	n := len(o.left)
	lo, hi = max(f32), 0
	for i in n / 4 ..< 3 * n / 4 {
		w := width_at(o, i)
		lo = min(lo, w)
		hi = max(hi, w)
	}
	return
}

@(private = "file")
finite :: proc(p: [2]f32) -> bool {
	return !math.is_nan(p.x) && !math.is_nan(p.y) && !math.is_inf(p.x) && !math.is_inf(p.y)
}

@(test)
constant_width_without_thinning :: proc(t: ^testing.T) {
	pen := Pen{nib = .Round, width = 4}
	o := outline(straight(50, 2, 4), pen)
	defer outline_destroy(&o)
	testing.expect(t, len(o.left) > 10 && len(o.left) == len(o.right))
	for i in 0 ..< len(o.left) {
		testing.expectf(t, abs(width_at(o, i) - 4) < 0.01, "width %v at %d, want 4", width_at(o, i), i)
	}
}

@(test)
faster_is_thinner :: proc(t: ^testing.T) {
	pen := Pen{nib = .Round, width = 4, thinning = 0.7}
	slow := outline(straight(50, 2, 20), pen)   // 0.1 /ms: an eighth of the reference
	fast := outline(straight(50, 2, 1), pen)    // 2 /ms: 2.5 times the reference
	defer outline_destroy(&slow)
	defer outline_destroy(&fast)
	slow_lo, _ := middle_width(slow)
	_, fast_hi := middle_width(fast)
	testing.expectf(t, fast_hi < slow_lo * 0.75, "fast %v not under slow %v", fast_hi, slow_lo)
	testing.expectf(t, slow_lo > 3.4, "a slow stroke is near its full width: %v", slow_lo)
}

@(test)
chisel_follows_the_nib :: proc(t: ^testing.T) {
	pen := Pen{nib = .Chisel, width = 4, nib_angle = 1.0 / 12}
	s, c := turn.sincos(f32(1.0 / 12))
	along := outline(straight(40, 2, 4, {c, -s}), pen)   // rising to the right, with y down
	across := outline(straight(40, 2, 4, {s, c}), pen)
	defer outline_destroy(&along)
	defer outline_destroy(&across)
	_, along_hi := middle_width(along)
	across_lo, _ := middle_width(across)
	testing.expectf(t, along_hi < 4 * (CHISEL_EDGE + 0.01), "along the nib: %v", along_hi)
	testing.expectf(t, across_lo > 3.9, "across the nib: %v", across_lo)
}

@(test)
tapers_end_in_a_point :: proc(t: ^testing.T) {
	pen := Pen{nib = .Round, width = 4, taper_start = 10, taper_end = 10, min_width = 0.3}
	o := outline(straight(50, 2, 4), pen)
	defer outline_destroy(&o)
	n := len(o.left)
	testing.expectf(t, width_at(o, 0) < 0.2 && width_at(o, n - 1) < 0.2, "ends %v %v", width_at(o, 0), width_at(o, n - 1))
	_, hi := middle_width(o)
	testing.expectf(t, hi > 3.9, "the middle keeps its width: %v", hi)
	testing.expect(t, !o.round_start && !o.round_end)
}

// A quarter circle drawn at a varying speed: a simple stroke, no self-intersection.
@(private = "file")
arc_stroke :: proc(allocator := context.temp_allocator) -> []Sample {
	s := make([]Sample, 60, allocator)
	time: f64 = 0
	for i in 0 ..< 60 {
		sn, cs := turn.sincos(f32(i) / 59 * 0.25)
		s[i] = {at = {100 * cs, 100 * sn}, time = time}
		time += 2 + f64(i % 7)
	}
	return s
}

@(private = "file")
shoelace :: proc(p: [][2]f32) -> f32 {
	sum: f32 = 0
	for i in 0 ..< len(p) {
		q := p[(i + 1) % len(p)]
		sum += p[i].x * q.y - q.x * p[i].y
	}
	return abs(sum) * 0.5
}

@(test)
polygon_and_triangles_agree :: proc(t: ^testing.T) {
	for pen in ([]Pen{PEN_BALLPOINT, PEN_FOUNTAIN, PEN_FELT, PEN_BRUSH}) {
		o := outline(arc_stroke(), pen)
		defer outline_destroy(&o)
		n := len(o.left)
		poly := polygon(o)
		defer delete(poly)
		caps := (o.round_start ? CAP_POINTS : 0) + (o.round_end ? CAP_POINTS : 0)
		testing.expectf(t, len(poly) == 2 * n + caps, "%v: %d points, want %d", pen.nib, len(poly), 2 * n + caps)
		// Closed: the last point joins the first without a jump across the ink.
		testing.expectf(t, length(poly[len(poly) - 1] - poly[0]) <= pen.width, "%v: the polygon's closing edge is long", pen.nib)
		for p in poly { testing.expect(t, finite(p)) }

		tris := triangles(o)
		defer delete(tris)
		covered: f32 = 0
		for tri in tris {
			e1, e2 := tri[1] - tri[0], tri[2] - tri[0]
			covered += abs(e1.x * e2.y - e1.y * e2.x) * 0.5
		}
		area := shoelace(poly)
		testing.expectf(t, area > 0 && abs(covered - area) < area * 0.03, "%v: triangles %v, polygon %v", pen.nib, covered, area)
	}
}

@(test)
one_sample_is_a_dot :: proc(t: ^testing.T) {
	o := outline([]Sample{{at = {5, 7}, time = 3}}, Pen{width = 4})
	defer outline_destroy(&o)
	poly := polygon(o)
	defer delete(poly)
	testing.expect_value(t, len(poly), 2 + 2 * CAP_POINTS)
	for p in poly {
		testing.expectf(t, abs(length(p - [2]f32{5, 7}) - 2) < 1e-4, "%v is not on the dot's circle", p)
	}
}

@(test)
repeated_samples_make_no_nan :: proc(t: ^testing.T) {
	same := []Sample{{at = {1, 1}}, {at = {1, 1}}, {at = {1, 1}, time = 5}, {at = {1, 1}, time = 5}}
	stalls := []Sample {
		{at = {0, 0}}, {at = {0, 0}}, {at = {0, 0}, time = 4},
		{at = {3, 0}, time = 4}, {at = {3, 0}, time = 4}, {at = {3, 0}, time = 30},
		{at = {3, 4}, time = 31}, {at = {0, 0}, time = 31}, {at = {0, 0}, time = 31},
	}
	for samples in ([][]Sample{same, stalls}) {
		for pen in ([]Pen{PEN_BALLPOINT, PEN_FOUNTAIN, PEN_FELT, PEN_BRUSH}) {
			o := outline(samples, pen)
			defer outline_destroy(&o)
			testing.expect(t, len(o.left) > 0)
			poly := polygon(o)
			defer delete(poly)
			for p in poly { testing.expectf(t, finite(p), "%v: %v", pen.nib, p) }
			tris := triangles(o)
			defer delete(tris)
			for tri in tris { for p in tri { testing.expect(t, finite(p)) } }
		}
	}
}

// A signature's tight loops: a prolate cycloid, `loops` turns of radius about 2.5 times `scale`, drawn faster on the
// straights than in the turns.
@(private = "file")
loop_stroke :: proc(scale: f32, loops: int, allocator := context.temp_allocator) -> []Sample {
	count := 60 * loops
	s := make([]Sample, count + 1, allocator)
	time: f64 = 0
	for i in 0 ..= count {
		a := f32(i) / f32(count) * 2 * math.PI * f32(loops)
		s[i] = {at = scale * [2]f32{1.4 * a - 2.5 * math.sin(a), -2.5 * math.cos(a)}, time = time}
		time += 3 + 2 * f64(math.cos(a))
	}
	return s
}

// The largest turn, in degrees, of the outer edge of a turn between two consecutive segments, away from the ends and
// the tapers (whose edges close to a point by design).
@(private = "file")
outer_turn :: proc(o: Outline, pen: Pen) -> f32 {
	n := len(o.left)
	along := make([]f32, n, context.temp_allocator)
	for i in 1 ..< n { along[i] = along[i - 1] + length((o.left[i] + o.right[i] - o.left[i - 1] - o.right[i - 1]) * 0.5) }
	worst: f32 = 0
	for i in 2 ..< n - 2 {
		if along[i] < pen.taper_start || along[n - 1] - along[i] < pen.taper_end { continue }
		c0 := (o.left[i - 1] + o.right[i - 1]) * 0.5
		c1 := (o.left[i] + o.right[i]) * 0.5
		c2 := (o.left[i + 1] + o.right[i + 1]) * 0.5
		// The path turning toward the left edge leaves the right one outside.
		turn_left := cross(c1 - c0, c2 - c1) > 0
		e := turn_left ? o.right : o.left
		a, b := e[i] - e[i - 1], e[i + 1] - e[i]
		la, lb := length(a), length(b)
		if !(la > 1e-4 && lb > 1e-4) { continue }
		worst = max(worst, math.acos(clamp((a.x * b.x + a.y * b.y) / (la * lb), -1, 1)) * math.DEG_PER_RAD)
	}
	return worst
}

@(test)
tight_turns_have_no_corners :: proc(t: ^testing.T) {
	for preset in PRESETS {
		for k in ([]f32{1, 2.6}) {
			pen := scaled(preset, k)
			o := outline(loop_stroke(pen.width, 4), pen)
			defer outline_destroy(&o)
			for p in o.left { testing.expect(t, finite(p)) }
			for p in o.right { testing.expect(t, finite(p)) }
			// RESAMPLE_TURN (8°) and the walk's step make a little over it; 13°: a chisel's hairline in a loop tighter
			// than its width, where its width is least and changes fastest, reaches 12.9° on an edge 0.03 width long.
			worst := outer_turn(o, pen)
			testing.expectf(t, worst <= 13, "%v at %v: an outer edge turns by %v° at a point", preset.nib, k, worst)
		}
	}
	// A cusp (the hand goes and comes back on itself) adds one point, not one per step of the walk: the count stays
	// near the length over the largest spacing.
	back := make([]Sample, 41, context.temp_allocator)
	for i in 0 ..= 40 { back[i] = {at = {f32(20 - abs(i - 20)) * 2, 0}, time = f64(i) * 4} }
	pen := Pen{nib = .Round, width = 4}
	o := outline(back, pen)
	defer outline_destroy(&o)
	most := int(80 / (pen.width * 0.3)) + 20
	testing.expectf(t, len(o.left) <= most, "a cusp: %d points, want at most %d", len(o.left), most)
}

// The distance from `p` to the triangle abc (0 inside).
@(private = "file")
triangle_distance :: proc(p, a, b, c: [2]f32) -> f32 {
	s0, s1, s2 := cross(b - a, p - a), cross(c - b, p - b), cross(a - c, p - c)
	if (s0 >= 0 && s1 >= 0 && s2 >= 0) || (s0 <= 0 && s1 <= 0 && s2 <= 0) { return 0 }
	edge :: proc(p, a, b: [2]f32) -> f32 {
		d := b - a
		l := d.x * d.x + d.y * d.y
		u: f32 = l > 0 ? clamp(((p - a).x * d.x + (p - a).y * d.y) / l, 0, 1) : 0
		return length(p - (a + d * u))
	}
	return min(edge(p, a, b), edge(p, b, c), edge(p, c, a))
}

// How far `p` lies outside a broad nib's sweep along `pts`, computed here from the nib at each point and not from
// `lay`: per step, the nib's segment swept from one point to the next (two triangles, so a folded one counts too),
// grown by half the nib's thickness, and each nib's own rectangle.
@(private = "file")
outside_sweep :: proc(p: [2]f32, pts: []Point) -> f32 {
	best := max(f32)
	for i in 0 ..< len(pts) {
		a := pts[i]
		ha := a.edge * (a.span * 0.5)
		// The nib's rectangle at this point.
		x := (p - a.at).x * a.edge.x + (p - a.at).y * a.edge.y
		y := cross(a.edge, p - a.at)
		dx, dy := max(abs(x) - a.span * 0.5, 0), max(abs(y) - a.thick * 0.5, 0)
		best = min(best, length([2]f32{dx, dy}))
		if i + 1 == len(pts) { continue }
		b := pts[i + 1]
		hb := b.edge * (b.span * 0.5)
		grown := max(a.thick, b.thick) * 0.5
		d := min(triangle_distance(p, a.at + ha, b.at + hb, b.at - hb), triangle_distance(p, a.at + ha, b.at - hb, a.at - ha),
			triangle_distance(p, a.at + ha, b.at + hb, a.at - ha), triangle_distance(p, b.at + hb, b.at - hb, a.at - ha))
		best = min(best, max(d - grown, 0))
	}
	return best
}

// Whether `p` lies in one of `pieces` (as `levels` cuts them into positive contours), within `eps`.
@(private = "file")
in_pieces :: proc(p: [2]f32, pieces: []Piece, eps: f32) -> bool {
	for pc in pieces {
		buf: [2][4][2]f32
		lens: [2]int
		k := piece_contours(pc.quad, &buf, &lens)
		for j in 0 ..< k {
			c := buf[j][:lens[j]]
			inside := true
			for v in 0 ..< len(c) {
				e := c[(v + 1) % len(c)] - c[v]
				l := length(e)
				// Positive contours: inside is on the left of every edge.
				if l > 0 && cross(e, p - c[v]) / l < -eps { inside = false; break }
			}
			if inside { return true }
		}
	}
	return false
}

@(test)
a_chisel_lays_its_sweep :: proc(t: ^testing.T) {
	// Plain ink, loops whose radius at the top is under the nib's width: where the offset outline notched.
	pen := Pen{nib = .Chisel, width = 4, nib_angle = 1.0 / 12, taper_start = 3, taper_end = 3, thinning = 0.3}
	for k in ([]f32{1, 2.6}) {
		p := scaled(pen, k)
		tight := loop_stroke(k, 3)
		o, pts := trace(tight, p)
		defer outline_destroy(&o)
		defer delete(pts)
		laid := lay(tight, p, 1)
		defer laid_destroy(&laid)
		tol := p.width * 1e-3
		// Nothing past the nib: every corner of the ink lies in the nib's sweep.
		worst: f32 = 0
		for pc in laid.pieces { for q in pc.quad { worst = max(worst, outside_sweep(q, pts)) } }
		testing.expectf(t, worst <= tol, "at %v: the ink reaches %v past the nib's sweep", k, worst)
		// No gap: every nib on the way is covered, all its rectangle (its corners too: where the stroke runs along the
		// nib's edge, they make the hairline's flat side).
		gaps := 0
		for pt in pts {
			for j in 0 ..= 8 {
				u := f32(j) / 4 - 1
				for side in ([]f32{-0.45, 0, 0.45}) {
					q := pt.at + pt.edge * (u * pt.span * 0.5) + [2]f32{-pt.edge.y, pt.edge.x} * (side * pt.thick)
					if !in_pieces(q, laid.pieces, tol) { gaps += 1 }
				}
			}
		}
		testing.expectf(t, gaps == 0, "at %v: %d points of the nib's way uncovered", k, gaps)
		// The day-one test of the old ink: the offset outline's lobes reach past the nib at the loop tops (the notch
		// between them).
		poly := polygon(o)
		defer delete(poly)
		reach: f32 = 0
		for q in poly { reach = max(reach, outside_sweep(q, pts)) }
		testing.expectf(t, reach > p.width * 0.05, "at %v: the offset outline stays in the sweep (%v): the loop is not tight", k, reach)
	}
	// A dot is the nib itself.
	dot := lay([]Sample{{at = {5, 7}}}, pen, 1)
	defer laid_destroy(&dot)
	testing.expect_value(t, len(dot.pieces), 1)
	if len(dot.pieces) == 1 {
		q := dot.pieces[0].quad
		testing.expectf(t, abs(length(q[1] - q[0]) - 4) < 1e-3 && abs(length(q[3] - q[0]) - 4 * CHISEL_EDGE) < 1e-3, "a dot %v", q)
	}
}

@(test)
no_sample_no_ink :: proc(t: ^testing.T) {
	o := outline(nil, PEN_BALLPOINT)
	testing.expect(t, o.left == nil && polygon(o) == nil && triangles(o) == nil)
	laid := lay(nil, PEN_BALLPOINT, 1)
	testing.expect(t, laid.pieces == nil && laid.blobs == nil)
}

// The ink model (lay, levels).

@(private = "file")
PRESETS :: [4]Pen{PEN_BALLPOINT, PEN_FOUNTAIN, PEN_FELT, PEN_BRUSH}

@(private = "file")
level_area :: proc(ls: []Level) -> f32 {
	sum: f32 = 0
	for l in ls { for c in l.contours { sum += signed_area(c) } }
	return sum
}

@(test)
plain_ink_is_the_polygon :: proc(t: ^testing.T) {
	// Every Ink field zero, round ends and tapered ones: one opaque level, the polygon's area. Round and Brush only: a
	// chisel's ink is its sweep, of which its polygon is an approximation (a_chisel_lays_its_sweep).
	for pen in ([]Pen{{nib = .Round, width = 4, thinning = 0.5}, {nib = .Brush, width = 5, taper_start = 6, taper_end = 10}}) {
		o := outline(arc_stroke(), pen)
		defer outline_destroy(&o)
		poly := polygon(o)
		defer delete(poly)
		laid := lay(arc_stroke(), pen, 1)
		defer laid_destroy(&laid)
		testing.expect(t, len(laid.blobs) == 0)
		ls := levels(laid, 5)
		defer levels_destroy(ls)
		testing.expectf(t, len(ls) == 1 && ls[0].alpha == 1, "%v: %d levels", pen.nib, len(ls))
		// (each contour grown about its centre by LEVEL_OVERLAP: its area by the square)
		got, want := level_area(ls), shoelace(poly) * (1 + LEVEL_OVERLAP) * (1 + LEVEL_OVERLAP)
		testing.expectf(t, abs(got - want) < want * 0.03, "%v: levels %v, polygon %v", pen.nib, got, want)
	}
}

@(test)
a_seed_lays_the_same_ink :: proc(t: ^testing.T) {
	for pen in ([]Pen{scaled(PEN_BALLPOINT, 2.6), scaled(PEN_FELT, 2.6), scaled(PEN_BRUSH, 2.6)}) {
		s := straight(200, 3, 1)
		a := lay(s, pen, 7)
		b := lay(s, pen, 7)
		c := lay(s, pen, 8)
		defer laid_destroy(&a)
		defer laid_destroy(&b)
		defer laid_destroy(&c)
		same := len(a.pieces) == len(b.pieces)
		if same { for p, i in a.pieces { if p != b.pieces[i] { same = false; break } } }
		testing.expectf(t, same, "%v: the same seed laid other pieces", pen.nib)
		differs := len(a.pieces) != len(c.pieces)
		if !differs { for p, i in a.pieces { if p != c.pieces[i] { differs = true; break } } }
		testing.expectf(t, differs, "%v: another seed laid the same pieces", pen.nib)
	}
}

// Whether the pieces of a stroke along +x leave a stretch of it bare: the span between the first and the last piece,
// in bins of a quarter unit, each covered or not by a piece's extent in x.
@(private = "file")
has_gap :: proc(pieces: []Piece) -> bool {
	lo, hi := max(f32), min(f32)
	for p in pieces { for q in p.quad { lo = min(lo, q.x); hi = max(hi, q.x) } }
	bins := make([]bool, int((hi - lo) * 4) + 1, context.temp_allocator)
	for p in pieces {
		a, b := max(f32), min(f32)
		for q in p.quad { a = min(a, q.x); b = max(b, q.x) }
		for k in int((a - lo) * 4) ..= min(int((b - lo) * 4), len(bins) - 1) { bins[k] = true }
	}
	for covered in bins { if !covered { return true } }
	return false
}

@(test)
skip_thins_and_breaks_but_never_empties :: proc(t: ^testing.T) {
	pen := Pen{nib = .Round, width = 4, ink = {skip = 1}}
	gaps, faint := 0, 0
	for seed in u32(0) ..< 20 {
		laid := lay(straight(300, 3, 1), pen, seed)   // 3 units/ms: fast for a width of 4
		defer laid_destroy(&laid)
		testing.expect(t, len(laid.pieces) > 0)
		for p in laid.pieces { if p.density < 0.7 { faint += 1; break } }
		if has_gap(laid.pieces) { gaps += 1 }
	}
	testing.expectf(t, faint >= 15, "faint passages in %d strokes of 20", faint)
	testing.expectf(t, gaps >= 5, "gaps in %d strokes of 20", gaps)
	// Short, fast and all priming: still some ink.
	for seed in u32(0) ..< 200 {
		laid := lay(straight(6, 3, 1, {0, -1}), pen, seed)
		defer laid_destroy(&laid)
		testing.expectf(t, len(laid.pieces) > 0, "seed %d: an empty stroke", seed)
	}
}

@(test)
a_slow_hand_lays_more_ink :: proc(t: ^testing.T) {
	// 40 samples at 0.1 unit/ms, then 40 at 2 units/ms.
	s := make([]Sample, 80, context.temp_allocator)
	time: f64 = 0
	for i in 0 ..< 80 {
		s[i] = {at = {2 * f32(i), 0}, time = time}
		time += i < 40 ? 20 : 1
	}
	laid := lay(s, Pen{nib = .Round, width = 4, ink = {dwell = 1}}, 1)
	defer laid_destroy(&laid)
	slow, fast: f32
	ns, nf: int
	for p in laid.pieces {
		x := (p.quad[0].x + p.quad[2].x) * 0.5
		if x > 10 && x < 60 { slow += p.density; ns += 1 }
		if x > 100 && x < 150 { fast += p.density; nf += 1 }
	}
	testing.expect(t, ns > 0 && nf > 0)
	testing.expectf(t, slow / f32(ns) > fast / f32(nf) + 0.2, "slow %v, fast %v", slow / f32(ns), fast / f32(nf))
}

@(test)
the_nib_pools_where_it_rests :: proc(t: ^testing.T) {
	pen := Pen{nib = .Round, width = 4, ink = {pool = 1}}
	s := straight(40, 2, 4)
	laid := lay(s, pen, 1)
	defer laid_destroy(&laid)
	testing.expect_value(t, len(laid.blobs), 2)
	if len(laid.blobs) == 2 {
		testing.expect(t, length(laid.blobs[0].center - s[0].at) < 1e-3)
		testing.expect(t, length(laid.blobs[1].center - s[39].at) < 1e-3)
		for b in laid.blobs { testing.expect(t, b.density >= 0.9 && b.radius > 0) }
	}
	// The blobs come after the line, in levels of their own, so they lie over it.
	ls := levels(laid, 4)
	defer levels_destroy(ls)
	testing.expect(t, len(ls) == 2 && len(ls[1].contours) == 2 && len(ls[1].contours[0]) == BLOB_POINTS)

	// A stop in the middle, 300 ms in one place: a third blob there.
	stop := make([]Sample, 60, context.temp_allocator)
	time: f64 = 0
	for i in 0 ..< 60 {
		x := f32(min(i, 20) + max(i - 40, 0)) * 2
		stop[i] = {at = {x, 0}, time = time}
		time += 15
	}
	laid2 := lay(stop, pen, 1)
	defer laid_destroy(&laid2)
	testing.expect_value(t, len(laid2.blobs), 3)
	if len(laid2.blobs) == 3 { testing.expect(t, length(laid2.blobs[0].center - [2]f32{40, 0}) < 0.5) }
}

@(test)
a_pool_is_a_drop :: proc(t: ^testing.T) {
	pen := Pen{nib = .Round, width = 4, ink = {pool = 1}}
	laid := lay(straight(40, 2, 4), pen, 1)
	defer laid_destroy(&laid)
	testing.expect_value(t, len(laid.blobs), 2)
	if len(laid.blobs) != 2 { return }
	// Into the stroke from each end: +x from its start, -x from its end.
	testing.expectf(t, length(laid.blobs[0].direction - {1, 0}) < 1e-3, "start: %v", laid.blobs[0].direction)
	testing.expectf(t, length(laid.blobs[1].direction - {-1, 0}) < 1e-3, "end: %v", laid.blobs[1].direction)
	testing.expect(t, laid.blobs[0].seed != laid.blobs[1].seed)

	// The stroke's two drops, a stop's (no direction), and many seeds at one end: every shape the hash gives must hold.
	drops := make([dynamic]Blob, 0, 300, context.temp_allocator)
	append(&drops, laid.blobs[0], laid.blobs[1], Blob{center = {3, 4}, radius = 2, density = 1, seed = 5})
	r: f32 = 1 / math.SQRT_TWO
	for seed in u32(0) ..< 200 { append(&drops, Blob{center = {-7, 2}, radius = 1.5, density = 1, direction = {r, -r}, seed = seed}) }
	for b in drops {
		ring: [BLOB_POINTS][2]f32
		drop(b, ring[:])
		for p in ring { testing.expect(t, finite(p)) }
		testing.expectf(t, signed_area(ring[:]) > 0, "a drop of area %v", signed_area(ring[:]))
		// Not a circle: the distances from where the nib rested spread by a tenth or more.
		lo, hi := max(f32), f32(0)
		for p in ring {
			d := length(p - b.center)
			lo, hi = min(lo, d), max(hi, d)
		}
		testing.expectf(t, (hi - lo) / hi >= 0.1, "a drop's radius spreads %v..%v", lo, hi)
		if b.direction == {} { continue }
		// Drawn out along the stroke: longer along its direction than across it, and reaching further in than out.
		nrm := [2]f32{-b.direction.y, b.direction.x}
		along_lo, along_hi, across_lo, across_hi := max(f32), min(f32), max(f32), min(f32)
		for p in ring {
			x := (p.x - b.center.x) * b.direction.x + (p.y - b.center.y) * b.direction.y
			y := (p.x - b.center.x) * nrm.x + (p.y - b.center.y) * nrm.y
			along_lo, along_hi = min(along_lo, x), max(along_hi, x)
			across_lo, across_hi = min(across_lo, y), max(across_hi, y)
		}
		testing.expectf(t, along_hi - along_lo > across_hi - across_lo, "along %v, across %v", along_hi - along_lo, across_hi - across_lo)
		testing.expectf(t, along_hi > -along_lo, "into the stroke %v, out of it %v", along_hi, -along_lo)
	}

	// The same seed draws the same drop; another seed another.
	a, b, c: [BLOB_POINTS][2]f32
	drop(laid.blobs[0], a[:])
	drop(laid.blobs[0], b[:])
	other := laid.blobs[0]
	other.seed += 1
	drop(other, c[:])
	testing.expect(t, a == b)
	testing.expect(t, a != c)
	again := lay(straight(40, 2, 4), pen, 1)
	defer laid_destroy(&again)
	testing.expect(t, len(again.blobs) == 2 && again.blobs[0] == laid.blobs[0] && again.blobs[1] == laid.blobs[1])
	elsewhere := lay(straight(40, 2, 4), pen, 2)
	defer laid_destroy(&elsewhere)
	testing.expect(t, len(elsewhere.blobs) == 2 && elsewhere.blobs[0].seed != laid.blobs[0].seed)
}

@(test)
grain_roughens_the_edges_and_streaks :: proc(t: ^testing.T) {
	s := straight(60, 2, 4)
	plain := Pen{nib = .Round, width = 4}
	grained := plain
	grained.ink.grain = 1
	o := outline(s, plain)
	defer outline_destroy(&o)
	laid := lay(s, grained, 3)
	defer laid_destroy(&laid)
	segs := len(o.left) - 1
	testing.expectf(t, len(laid.pieces) > 2 * segs, "%d pieces for %d segments: no lanes", len(laid.pieces), segs)
	// A lane is a fifth of the width, not the whole.
	narrow := 0
	for p in laid.pieces { if length(p.quad[0] - p.quad[3]) < 4 * 0.3 { narrow += 1 } }
	testing.expect(t, narrow > segs)
	moved := 0
	for e in o.left {
		found := false
		for p in laid.pieces { for q in p.quad { if length(q - e) < 1e-4 { found = true } } }
		if !found { moved += 1 }
	}
	testing.expectf(t, moved > len(o.left) / 2, "%d of %d edge points moved", moved, len(o.left))
}

@(test)
levels_stack_to_the_density :: proc(t: ^testing.T) {
	// The first level is the whole ink: every piece with ink, in contours as piece_contours gives them.
	for pen in PRESETS {
		laid := lay(arc_stroke(), scaled(pen, 2.6), 4)
		defer laid_destroy(&laid)
		ls := levels(laid, 6)
		defer levels_destroy(ls)
		want := 0
		for p in laid.pieces {
			if !(p.density > 0) { continue }
			buf: [2][4][2]f32
			lens: [2]int
			want += piece_contours(p.quad, &buf, &lens)
		}
		testing.expectf(t, len(ls) > 0 && len(ls[0].contours) == want, "%v: level 0 holds %d contours, want %d", pen.nib, len(ls[0].contours), want)
	}
	// Disjoint pieces at a few densities: the levels that hold each one, stacked, give the opacity times its density.
	densities := []f32{1.0 / 6, 0.5, 4.0 / 6, 1}
	pieces := make([]Piece, len(densities), context.temp_allocator)
	for d, i in densities {
		x := f32(i) * 10
		pieces[i] = {{{x, 0}, {x + 4, 0}, {x + 4, 4}, {x, 4}}, d}
	}
	laid := Laid{pieces = pieces, opacity = 0.84}
	ls := levels(laid, 6)
	defer levels_destroy(ls)
	centre :: proc(c: [][2]f32) -> (m: [2]f32) {
		for q in c { m += q }
		return m / f32(len(c))
	}
	for &p in pieces {
		bare: f32 = 1
		mid := centre(p.quad[:])
		for l in ls {
			// (a piece's contour is grown about its centre: found by it)
			for c in l.contours { if len(c) == 4 && abs(centre(c).x - mid.x) < 1e-3 && abs(centre(c).y - mid.y) < 1e-3 { bare *= 1 - l.alpha } }
		}
		testing.expectf(t, abs((1 - bare) - 0.84 * p.density) < 0.02, "density %v: stacked %v, want %v", p.density, 1 - bare, 0.84 * p.density)
	}
}

@(test)
a_felt_streaks_but_never_bares_the_paper :: proc(t: ^testing.T) {
	pen := scaled(PEN_FELT, 2.6)
	s := straight(120, 3, 1)   // fast: the driest a felt gets
	o := outline(s, pen)
	defer outline_destroy(&o)
	laid := lay(s, pen, 11)
	defer laid_destroy(&laid)
	strip := 3 * (len(o.left) - 1)
	testing.expectf(t, len(laid.pieces) >= strip, "%d pieces, want every one of the %d lanes", len(laid.pieces), strip)
	light := 0
	for p in laid.pieces[:strip] {
		testing.expect(t, p.density >= GRAIN_LIGHT * (1 - DWELL_RANGE) - 1e-4)
		if p.density < 0.9 * (1 - DWELL_RANGE * pen.ink.dwell) { light += 1 }
	}
	testing.expectf(t, light > 0, "no light streak")
}

@(test)
every_contour_turns_counter_clockwise :: proc(t: ^testing.T) {
	strokes := [][]Sample{arc_stroke(), straight(120, 3, 1, {0.6, -0.8}), straight(50, 2, 8, {-1, 0})}
	for pen in PRESETS {
		for s, k in strokes {
			laid := lay(s, scaled(pen, 2.6), u32(k))
			defer laid_destroy(&laid)
			ls := levels(laid, 6)
			defer levels_destroy(ls)
			testing.expect(t, len(ls) > 0)
			for l in ls {
				testing.expect(t, l.alpha > 0 && l.alpha <= 1)
				for c in l.contours { testing.expectf(t, signed_area(c) > 0, "%v: a contour of area %v", pen.nib, signed_area(c)) }
			}
		}
	}
}

@(test)
the_ink_model_makes_no_nan :: proc(t: ^testing.T) {
	same := []Sample{{at = {1, 1}}, {at = {1, 1}}, {at = {1, 1}, time = 5}, {at = {1, 1}, time = 5}}
	one := []Sample{{at = {5, 7}, time = 3, pressure = 0.4}}
	stalls := []Sample {
		{at = {0, 0}}, {at = {0, 0}}, {at = {0, 0}, time = 4},
		{at = {3, 0}, time = 4}, {at = {3, 0}, time = 4}, {at = {3, 0}, time = 300},
		{at = {3, 4}, time = 301}, {at = {0, 0}, time = 301}, {at = {0, 0}, time = 301},
	}
	pressed := []Sample{{at = {0, 0}, time = 0, pressure = 0.2}, {at = {10, 0}, time = 8, pressure = 0.9}, {at = {20, 5}, time = 12, pressure = 0.5}}
	everything := Ink{opacity = 0.5, dwell = 1, pool = 1, skip = 1, grain = 1, pressure = 1}
	for samples in ([][]Sample{same, one, stalls, pressed}) {
		for preset in PRESETS {
			for pen in ([]Pen{preset, {nib = preset.nib, width = preset.width, ink = everything}}) {
				laid := lay(samples, pen, 9)
				defer laid_destroy(&laid)
				testing.expect(t, len(laid.pieces) > 0)
				for p in laid.pieces {
					testing.expect(t, !math.is_nan(p.density))
					for q in p.quad { testing.expectf(t, finite(q), "%v: %v", pen.nib, q) }
				}
				for b in laid.blobs { testing.expect(t, finite(b.center) && !math.is_nan(b.radius)) }
				ls := levels(laid, 6)
				defer levels_destroy(ls)
				for l in ls { for q in l.points { testing.expect(t, finite(q)) } }
			}
		}
	}
}

// `samples` with every tilt set to `tilt`.
@(private = "file")
tilted :: proc(samples: []Sample, tilt: [2]f32) -> []Sample {
	for &s in samples { s.tilt = tilt }
	return samples
}

@(test)
upright_tilt_changes_nothing :: proc(t: ^testing.T) {
	for preset in PRESETS {
		with, without := preset, preset
		with.tilt = 1
		without.tilt = 0
		a := outline(arc_stroke(), with)
		b := outline(arc_stroke(), without)
		defer outline_destroy(&a)
		defer outline_destroy(&b)
		testing.expect(t, len(a.left) == len(b.left))
		for i in 0 ..< min(len(a.left), len(b.left)) {
			testing.expectf(t, a.left[i] == b.left[i] && a.right[i] == b.right[i], "%v: point %d moved", preset.nib, i)
		}
		la := lay(arc_stroke(), with, 5)
		lb := lay(arc_stroke(), without, 5)
		defer laid_destroy(&la)
		defer laid_destroy(&lb)
		testing.expect(t, len(la.pieces) == len(lb.pieces) && len(la.blobs) == len(lb.blobs))
		for i in 0 ..< min(len(la.pieces), len(lb.pieces)) {
			testing.expectf(t, la.pieces[i] == lb.pieces[i], "%v: piece %d changed", preset.nib, i)
		}
	}
}

@(test)
a_leaned_felt_lays_broader_and_lighter :: proc(t: ^testing.T) {
	pen := PEN_FELT
	pen.ink.grain = 0   // one piece per segment: their densities compare directly
	up := straight(50, 2, 8)
	leaned := tilted(straight(50, 2, 8), {50.0 / 360, 40.0 / 360})   // a strong lean, to the lower right
	a := outline(up, pen)
	b := outline(leaned, pen)
	defer outline_destroy(&a)
	defer outline_destroy(&b)
	up_lo, _ := middle_width(a)
	lean_lo, lean_hi := middle_width(b)
	testing.expectf(t, lean_lo > up_lo * 1.3, "leaned %v, upright %v", lean_lo, up_lo)
	testing.expectf(t, lean_hi < up_lo * (1 + TILT_WIDEN), "leaned %v: wider than a pen on its side", lean_hi)

	mean :: proc(l: Laid) -> f32 {
		sum: f32 = 0
		for p in l.pieces { sum += p.density }
		return sum / f32(len(l.pieces))
	}
	la := lay(up, pen, 3)
	lb := lay(leaned, pen, 3)
	defer laid_destroy(&la)
	defer laid_destroy(&lb)
	testing.expectf(t, mean(lb) < mean(la) * 0.85, "leaned %v, upright %v", mean(lb), mean(la))
	testing.expectf(t, mean(lb) > mean(la) * (1 - TILT_LIGHT) - 0.01, "leaned %v: lighter than its side", mean(lb))
}

@(test)
a_chisel_turns_with_the_pen :: proc(t: ^testing.T) {
	// The fixed nib at 30° would lay both strokes below at about half and 0.87 of the width: only the lean decides here.
	pen := Pen{nib = .Chisel, width = 4, nib_angle = 1.0 / 12, tilt = 1}
	// Leaned to the right: the shaft lies along +x, the edge is square to it.
	along := outline(tilted(straight(40, 2, 4, {1, 0}), {60.0 / 360, 0}), pen)
	across := outline(tilted(straight(40, 2, 4, {0, 1}), {60.0 / 360, 0}), pen)
	defer outline_destroy(&along)
	defer outline_destroy(&across)
	along_lo, _ := middle_width(along)
	_, across_hi := middle_width(across)
	testing.expectf(t, along_lo > 3.9, "along the shaft: %v", along_lo)
	testing.expectf(t, across_hi < 4 * (CHISEL_EDGE + 0.01), "across the shaft: %v", across_hi)

	// Leaned to the lower right (a right hand's hold), the azimuth at 45° with y down.
	r: f32 = 1 / math.SQRT_TWO
	down := outline(tilted(straight(40, 2, 4, {r, r}), {40.0 / 360, 40.0 / 360}), pen)
	up := outline(tilted(straight(40, 2, 4, {r, -r}), {40.0 / 360, 40.0 / 360}), pen)
	defer outline_destroy(&down)
	defer outline_destroy(&up)
	down_lo, _ := middle_width(down)
	_, up_hi := middle_width(up)
	testing.expectf(t, down_lo > 3.9, "a downstroke along the shaft: %v", down_lo)
	testing.expectf(t, up_hi < 4 * (CHISEL_EDGE + 0.01), "an upstroke across it: %v", up_hi)

	// Half the tilt: the edge halfway (on the doubled angle) between the nib's 30° and the shaft's square, 90°.
	pen.tilt = 0.5
	half := outline(tilted(straight(40, 2, 4, {1, 0}), {60.0 / 360, 0}), pen)
	defer outline_destroy(&half)
	half_lo, half_hi := middle_width(half)
	want := 4 * turn.sin(f32(1.0 / 6))
	testing.expectf(t, abs(half_lo - want) < 0.1 && abs(half_hi - want) < 0.1, "half the turn: %v..%v, want %v", half_lo, half_hi, want)
}

@(test)
any_tilt_makes_no_nan :: proc(t: ^testing.T) {
	tilts := [][2]f32 {
		{0.25, 0.25}, {-0.25, -0.25}, {0.25, -0.25}, {0.25, 0}, {0, -0.25}, {0.24997, 0.24997}, {3, -3},
		{math.nan_f32(), 0}, {0, math.inf_f32(1)}, {3e-6, 0}, {0.125, -0.125},
	}
	for tilt in tilts {
		for preset in PRESETS {
			pen := preset
			pen.tilt = 1
			for samples in ([][]Sample{tilted(arc_stroke(), tilt), tilted(straight(1, 1, 1), tilt)}) {
				o := outline(samples, pen)
				for p in o.left { testing.expectf(t, finite(p), "%v at %v: %v", pen.nib, tilt, p) }
				for p in o.right { testing.expectf(t, finite(p), "%v at %v: %v", pen.nib, tilt, p) }
				outline_destroy(&o)
				laid := lay(samples, pen, 2)
				for p in laid.pieces {
					testing.expect(t, !math.is_nan(p.density))
					for q in p.quad { testing.expectf(t, finite(q), "%v at %v: %v", pen.nib, tilt, q) }
				}
				laid_destroy(&laid)
			}
		}
	}
}
