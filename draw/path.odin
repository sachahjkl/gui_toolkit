package draw

import "core:math"
import "../render"

// Paths: lines, Bézier curves and arcs, flattened as they are added, then filled or stroked with antialiased edges.
//
//	p := path_make()
//	defer path_destroy(&p)
//	path_move_to(&p, {20, 80})
//	path_cubic_to(&p, {60, 0}, {100, 160}, {140, 80})
//	path_stroke(dc, &p, 2, color)
//
// A path holds points in the space it is drawn in: a transform pushed around path_fill and path_stroke moves it, and one that enlarges it a lot wants a smaller `tolerance`.

// How far a flattened curve may stray from the real one, by default.
PATH_TOLERANCE :: 0.1
// Most pieces of one curve.
PATH_CURVE_PIECES_MOST :: 256
// The kappa of a quarter of a circle in a cubic.
PATH_KAPPA :: 0.5522847498

Path_Contour :: struct {
	first, count: int,    // of Path.points
	closed:       bool,
}

Path :: struct {
	points:    [dynamic]Vec2,
	contours:  [dynamic]Path_Contour,
	tolerance: f32,
}

path_make :: proc(tolerance: f32 = PATH_TOLERANCE, allocator := context.allocator) -> Path {
	return Path{points = make([dynamic]Vec2, allocator), contours = make([dynamic]Path_Contour, allocator), tolerance = tolerance}
}

path_destroy :: proc(p: ^Path) {
	delete(p.points)
	delete(p.contours)
	p^ = {}
}

// Empties it, and keeps its memory.
path_clear :: proc(p: ^Path) {
	clear(&p.points)
	clear(&p.contours)
}

@(private = "file")
path_contour :: proc(p: ^Path) -> ^Path_Contour {
	n := len(p.contours)
	return n > 0 && !p.contours[n - 1].closed ? &p.contours[n - 1] : nil
}

@(private = "file")
path_add :: proc(p: ^Path, at: Vec2) {
	append(&p.points, at)
	path_contour(p).count += 1
}

// The point the next segment starts from: a contour that was closed goes on from its start.
@(private = "file")
path_from :: proc(p: ^Path, fallback: Vec2) -> Vec2 {
	if path_contour(p) != nil { return p.points[len(p.points) - 1] }
	at := len(p.contours) > 0 ? p.points[p.contours[len(p.contours) - 1].first] : fallback
	path_move_to(p, at)
	return at
}

// Starts a contour at `at`.
path_move_to :: proc(p: ^Path, at: Vec2) {
	append(&p.contours, Path_Contour{first = len(p.points)})
	path_add(p, at)
}

path_line_to :: proc(p: ^Path, at: Vec2) {
	path_from(p, at)
	path_add(p, at)
}

// A quadratic Bézier curve to `at`.
path_quad_to :: proc(p: ^Path, control, at: Vec2) {
	from := path_from(p, control)
	bend := from - 2 * control + at
	pieces := path_pieces(math.sqrt(math.sqrt(bend.x * bend.x + bend.y * bend.y) / (4 * path_tolerance(p))))
	for i in 1 ..= pieces { path_add(p, bezier_quad_at(from, control, at, f32(i) / f32(pieces))) }
}

// A cubic Bézier curve to `at`.
path_cubic_to :: proc(p: ^Path, control_a, control_b, at: Vec2) {
	from := path_from(p, control_a)
	d0, d1 := from - 2 * control_a + control_b, control_a - 2 * control_b + at
	bend := max(d0.x * d0.x + d0.y * d0.y, d1.x * d1.x + d1.y * d1.y)
	pieces := path_pieces(math.sqrt(0.75 * math.sqrt(bend) / path_tolerance(p)))
	for i in 1 ..= pieces { path_add(p, bezier_cubic_at(from, control_a, control_b, at, f32(i) / f32(pieces))) }
}

// An arc of the ellipse around `center`, from angle `from` to `to` (radians, clockwise on screen when `to` is greater), a line first from where the path stands.
path_arc :: proc(p: ^Path, center, radii: Vec2, from, to: f32) {
	at :: proc(center, radii: Vec2, a: f32) -> Vec2 { return center + radii * Vec2{math.cos(a), math.sin(a)} }
	start := at(center, radii, from)
	if path_contour(p) == nil { path_move_to(p, start) } else { path_add(p, start) }
	r := max(radii.x, radii.y)
	step := 2 * math.acos(max(1 - path_tolerance(p) / max(r, path_tolerance(p)), -1))
	pieces := clamp(int(math.ceil(abs(to - from) / max(step, 1e-3))), 1, PATH_CURVE_PIECES_MOST)
	for i in 1 ..= pieces { path_add(p, at(center, radii, from + (to - from) * f32(i) / f32(pieces))) }
}

// A straight line back to the contour's start, joined to it.
path_close :: proc(p: ^Path) {
	if c := path_contour(p); c != nil { c.closed = true }
}

// A closed rectangle with rounded corners.
path_rounded_rect :: proc(p: ^Path, r: Rect, radius: f32 = 0) {
	k := min(radius, (r.max.x - r.min.x) * 0.5, (r.max.y - r.min.y) * 0.5)
	c := k * (1 - PATH_KAPPA)
	path_move_to(p, {r.min.x + k, r.min.y})
	path_line_to(p, {r.max.x - k, r.min.y})
	if k > 0 { path_cubic_to(p, {r.max.x - c, r.min.y}, {r.max.x, r.min.y + c}, {r.max.x, r.min.y + k}) }
	path_line_to(p, {r.max.x, r.max.y - k})
	if k > 0 { path_cubic_to(p, {r.max.x, r.max.y - c}, {r.max.x - c, r.max.y}, {r.max.x - k, r.max.y}) }
	path_line_to(p, {r.min.x + k, r.max.y})
	if k > 0 { path_cubic_to(p, {r.min.x + c, r.max.y}, {r.min.x, r.max.y - c}, {r.min.x, r.max.y - k}) }
	path_line_to(p, {r.min.x, r.min.y + k})
	if k > 0 { path_cubic_to(p, {r.min.x, r.min.y + c}, {r.min.x + c, r.min.y}, {r.min.x + k, r.min.y}) }
	path_close(p)
}

// What it covers (strokes reach half their width past it).
path_bounds :: proc(p: ^Path) -> Rect {
	if len(p.points) == 0 { return {} }
	b := Rect{p.points[0], p.points[0]}
	for at in p.points { b = Rect{{min(b.min.x, at.x), min(b.min.y, at.y)}, {max(b.max.x, at.x), max(b.max.y, at.y)}} }
	return b
}

// Whether `at` is inside it, by the rule path_fill uses: for hit tests.
path_contains :: proc(p: ^Path, at: Vec2, evenodd := false) -> bool {
	winding := 0
	for c in p.contours {
		pts := p.points[c.first:][:c.count]
		for b, i in pts {
			a := pts[(i + len(pts) - 1) % len(pts)]
			side := (b.x - a.x) * (at.y - a.y) - (b.y - a.y) * (at.x - a.x)
			if a.y <= at.y {
				if b.y > at.y && side > 0 { winding += 1 }
			} else if b.y <= at.y && side < 0 {
				winding -= 1
			}
		}
	}
	return evenodd ? winding & 1 != 0 : winding != 0
}

// Fills it: every contour closed, holes by the winding of their contours, or `evenodd`. The cost of a pixel grows with the points of the path, as for push_clip_polygon.
path_fill :: proc(c: ^Context, p: ^Path, color: Color, evenodd := false) {
	if len(p.points) < 3 { return }
	outline := make([dynamic]Vec2, 0, len(p.points) + 2 * len(p.contours), context.temp_allocator)
	for k in p.contours {
		if k.count < 3 { continue }
		append(&outline, ..p.points[k.first:][:k.count])
		append(&outline, p.points[k.first], Vec2{render.POLYGON_BREAK * 2, 0})
	}
	push_clip_polygon(c, outline[:], evenodd)
	rect(c, path_bounds(p), color)
	pop_clip(c)
}

// Strokes it, `width` across, with round ends and joins. A translucent color goes through a layer: the pieces would show where they overlap.
path_stroke :: proc(c: ^Context, p: ^Path, width: f32, color: Color) {
	layered := color.a < 1
	solid := color
	if layered {
		solid.a = 1
		if !push_effects(c, rect_pad(path_bounds(p), width), Layer_Effects{alpha = color.a}) {
			pop_layer(c)
			return
		}
	}
	for k in p.contours {
		pts := p.points[k.first:][:k.count]
		polyline(c, pts, width, solid)
		if k.closed && k.count > 1 { line(c, pts[k.count - 1], pts[0], width, solid) }
		if k.count == 1 { line(c, pts[0], pts[0], width, solid) }
	}
	if layered { pop_layer(c) }
}

// A point of a quadratic Bézier curve, `t` from 0 to 1.
bezier_quad_at :: proc(a, control, b: Vec2, t: f32) -> Vec2 {
	u := 1 - t
	return a * (u * u) + control * (2 * u * t) + b * (t * t)
}

// A point of a cubic Bézier curve, `t` from 0 to 1.
bezier_cubic_at :: proc(a, control_a, control_b, b: Vec2, t: f32) -> Vec2 {
	u := 1 - t
	return a * (u * u * u) + control_a * (3 * u * u * t) + control_b * (3 * u * t * t) + b * (t * t * t)
}

// A cubic Bézier curve stroked, in one call.
bezier :: proc(c: ^Context, a, control_a, control_b, b: Vec2, width: f32, color: Color) {
	p := path_make(allocator = context.temp_allocator)
	path_move_to(&p, a)
	path_cubic_to(&p, control_a, control_b, b)
	path_stroke(c, &p, width, color)
}

@(private = "file")
path_tolerance :: proc(p: ^Path) -> f32 { return p.tolerance > 0 ? p.tolerance : PATH_TOLERANCE }

@(private = "file")
path_pieces :: proc(n: f32) -> int { return clamp(int(math.ceil(n)), 1, PATH_CURVE_PIECES_MOST) }
