// The ink's widths against the pen's options, the polygon's and the triangles' shapes, and no NaN on degenerate input.
//   odin test src/ink -vet
package tk_ink

import "core:math"
import "core:testing"

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
	pen := Pen{nib = .Chisel, width = 4, nib_angle = 30}
	a: f32 = 30 * math.RAD_PER_DEG
	along := outline(straight(40, 2, 4, {math.cos(a), -math.sin(a)}), pen)   // rising to the right, with y down
	across := outline(straight(40, 2, 4, {math.sin(a), math.cos(a)}), pen)
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
		a := f32(i) / 59 * math.PI / 2
		s[i] = {at = {100 * math.cos(a), 100 * math.sin(a)}, time = time}
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

@(test)
no_sample_no_ink :: proc(t: ^testing.T) {
	o := outline(nil, PEN_BALLPOINT)
	testing.expect(t, o.left == nil && polygon(o) == nil && triangles(o) == nil)
}
