package tk_paint

import "core:math"

Join :: enum u8 {
	Miter,   // the outer edges met in a point; a bevel past the miter limit (GDI+'s LineJoin.Miter, its default)
	Bevel,
	Round,
}

Cap :: enum u8 {
	Flat,     // ends at the end point (GDI+'s default)
	Square,   // half the width past it
	Round,
}

// Two points of a figure nearer than this share of the tolerance are one.
@(private = "file")
SAME_POINT :: 0.01

// MITER_LIMIT: GDI+'s default, the longest miter as a multiple of the width.
MITER_LIMIT :: 10

// A line's width, centred on the path, and the shape of its corners and ends.
Pen :: struct {
	width:       f32,
	join:        Join,
	cap:         Cap,
	miter_limit: f32,   // 0: MITER_LIMIT
}

// The area the pen covers along the path, as figures to fill with .Non_Zero (GDI+'s GraphicsPath.Widen): a quadrilateral
// per segment, a join at each corner, a cap at each end of an open figure, all wound the same way so that they add up.
// `flatness`: what the segments of the path's curves may stray from them, in the path's units (a coarse one makes them
// visible lines, as GDI+'s Widen does); the round joins and caps stray at most TOLERANCE.
widen :: proc(p: Path, pen: Pen, flatness: f32 = TOLERANCE, allocator := context.allocator) -> Path {
	out := Path{verbs = make([dynamic]Verb, allocator), points = make([dynamic][2]f32, allocator)}
	if pen.width <= 0 { return out }
	points := make([dynamic][2]f32, context.temp_allocator)
	contours := make([dynamic]Contour, context.temp_allocator)
	flatten(p, IDENTITY, flatness, &points, &contours)
	tolerance := min(flatness, TOLERANCE)
	hw := pen.width / 2
	same := tolerance * SAME_POINT
	limit := pen.miter_limit > 0 ? pen.miter_limit : MITER_LIMIT
	for c in contours {
		// the figure's points without repeats (and without its first point again at the end): a point a rounding away from the
		// last one (an arc's start after a line to it) would make a segment of any direction, and a join on the wrong side
		pts := make([dynamic][2]f32, 0, c.count, context.temp_allocator)
		for q in points[c.start:][:c.count] {
			if len(pts) == 0 || length(q - pts[len(pts) - 1]) > same { append(&pts, q) }
		}
		if c.closed && len(pts) > 1 && length(pts[0] - pts[len(pts) - 1]) <= same { pop(&pts) }
		n := len(pts)
		if n < 2 { continue }
		segments := c.closed ? n : n - 1
		for i in 0 ..< segments {
			a, b := pts[i], pts[(i + 1) % n]
			o := normal(b - a) * hw
			piece(&out, {a + o, b + o, b - o, a - o})
		}
		corners_from, corners_to := c.closed ? 0 : 1, c.closed ? n : n - 1
		for i in corners_from ..< corners_to {
			v := pts[i]
			d0 := unit(v - pts[(i + n - 1) % n])
			d1 := unit(pts[(i + 1) % n] - v)
			join(&out, v, d0, d1, hw, pen.join, limit, tolerance)
		}
		if !c.closed {
			cap_end(&out, pts[0], unit(pts[0] - pts[1]), hw, pen.cap, tolerance)
			cap_end(&out, pts[n - 1], unit(pts[n - 1] - pts[n - 2]), hw, pen.cap, tolerance)
		}
	}
	return out
}

@(private = "file")
unit :: proc(v: [2]f32) -> [2]f32 {
	l := length(v)
	return l > 0 ? v / l : {}
}

// The left of a direction (on a canvas, whose y axis points down), of unit length.
@(private = "file")
normal :: proc(d: [2]f32) -> [2]f32 {
	u := unit(d)
	return {-u.y, u.x}
}

@(private = "file")
cross :: proc(a, b: [2]f32) -> f32 { return a.x * b.y - a.y * b.x }

// A convex polygon, wound positively so that every piece adds to the winding.
@(private = "file")
piece :: proc(out: ^Path, pts: [][2]f32) {
	area: f32
	for q, i in pts { area += cross(q, pts[(i + 1) % len(pts)]) }
	if area == 0 { return }
	start_figure(out)
	if area > 0 {
		for q in pts { line_to(out, q.x, q.y) }
	} else {
		#reverse for q in pts { line_to(out, q.x, q.y) }
	}
	close(out)
}

// The corner at v between the directions d0 (in) and d1 (out): what the two segments' quadrilaterals leave open outside.
@(private = "file")
join :: proc(out: ^Path, v, d0, d1: [2]f32, hw: f32, kind: Join, limit, tolerance: f32) {
	turn := cross(d0, d1)
	cos := d0.x * d1.x + d0.y * d1.y
	if abs(turn) < 1e-6 && cos > 0 { return }   // straight on
	if kind == .Round { disc(out, v, hw, tolerance); return }
	side: f32 = turn > 0 ? -1 : 1   // the outer side, away from the turn
	o0 := [2]f32{-d0.y, d0.x} * hw * side
	o1 := [2]f32{-d1.y, d1.x} * hw * side
	// the miter's length over the width: 1 / sin(half the angle between the segments)
	if kind == .Miter && 1 + cos > 1e-6 && math.sqrt(2 / (1 + cos)) <= limit {
		tip := v + (o0 + o1) / (1 + cos)
		piece(out, {v, v + o0, tip, v + o1})
		return
	}
	piece(out, {v, v + o0, v + o1})
}

// The end at p of an open figure, `d` pointing out of it.
@(private = "file")
cap_end :: proc(out: ^Path, p, d: [2]f32, hw: f32, kind: Cap, tolerance: f32) {
	switch kind {
	case .Flat:
	case .Round:
		disc(out, p, hw, tolerance)
	case .Square:
		o := [2]f32{-d.y, d.x} * hw
		piece(out, {p + o, p + o + d * hw, p - o + d * hw, p - o})
	}
}

@(private = "file")
disc :: proc(out: ^Path, c: [2]f32, r, tolerance: f32) {
	if r <= 0 { return }
	// the step whose chord strays `tolerance` from the circle
	step := 2 * math.acos(clamp(1 - tolerance / r, -1, 1))
	n := max(8, int(math.ceil(math.TAU / max(step, 1e-3))))
	pts := make([][2]f32, n, context.temp_allocator)
	for i in 0 ..< n {
		a := math.TAU * f32(i) / f32(n)
		pts[i] = c + [2]f32{math.cos(a), math.sin(a)} * r
	}
	piece(out, pts)
}
