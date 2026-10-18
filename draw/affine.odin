package draw

import "core:math"

// A 2D affine transform. Column-vector convention, the same as CSS `matrix(a, b, c, d, e, f)`, canvas
// `setTransform(a, b, c, d, e, f)` and SVG:
//
//     x' = a*x + c*y + e        | a c e |   | x |
//     y' = b*x + d*y + f        | b d f | * | y |
//                               | 0 0 1 |   | 1 |
//
// Screen space is y-down, so a positive rotation turns clockwise on screen (as CSS `rotate()` does).
Affine :: struct { a, b, c, d, e, f: f32 }

AFFINE_IDENTITY :: Affine{a = 1, d = 1}

// `m` after `n`: affine_apply(affine_mul(m, n), p) == affine_apply(m, affine_apply(n, p)).
// CSS `transform: t1 t2` is affine_mul(t1, t2); a child's screen transform is affine_mul(parent, child).
affine_mul :: proc(m, n: Affine) -> Affine {
	return {
		a = m.a * n.a + m.c * n.b, b = m.b * n.a + m.d * n.b,
		c = m.a * n.c + m.c * n.d, d = m.b * n.c + m.d * n.d,
		e = m.a * n.e + m.c * n.f + m.e, f = m.b * n.e + m.d * n.f + m.f,
	}
}

affine_translate :: proc(t: Vec2) -> Affine { return {a = 1, d = 1, e = t.x, f = t.y} }
affine_scale :: proc(s: Vec2) -> Affine { return {a = s.x, d = s.y} }
// Clockwise on screen for a positive angle (radians), like CSS rotate().
affine_rotate :: proc(radians: f32) -> Affine {
	s, c := math.sin(radians), math.cos(radians)
	return {a = c, b = s, c = -s, d = c}
}
// CSS skew(ax, ay) (radians): x' = x + tan(ax)*y, y' = y + tan(ay)*x.
affine_skew :: proc(ax: f32, ay: f32 = 0) -> Affine { return {a = 1, b = math.tan(ay), c = math.tan(ax), d = 1} }

// `m` applied around `origin` instead of (0, 0) (CSS transform-origin): translate(origin) * m * translate(-origin).
affine_around :: proc(m: Affine, origin: Vec2) -> Affine {
	return affine_mul(affine_translate(origin), affine_mul(m, affine_translate(-origin)))
}

affine_apply :: proc(m: Affine, p: Vec2) -> Vec2 { return {m.a * p.x + m.c * p.y + m.e, m.b * p.x + m.d * p.y + m.f} }
// Directions and sizes: no translation.
affine_apply_vector :: proc(m: Affine, v: Vec2) -> Vec2 { return {m.a * v.x + m.c * v.y, m.b * v.x + m.d * v.y} }

affine_determinant :: proc(m: Affine) -> f32 { return m.a * m.d - m.b * m.c }

// Inverse (e.g. screen point -> local point for hit testing). ok = false for a singular matrix (a zero scale), then
// the identity is returned.
affine_inverse :: proc(m: Affine) -> (inv: Affine, ok: bool) {
	det := affine_determinant(m)
	if abs(det) < 1e-12 { return AFFINE_IDENTITY, false }
	k := 1 / det
	inv.a, inv.b, inv.c, inv.d = m.d * k, -m.b * k, -m.c * k, m.a * k
	inv.e = -(inv.a * m.e + inv.c * m.f)
	inv.f = -(inv.b * m.e + inv.d * m.f)
	return inv, true
}

// Axis-aligned bounds of the transformed rect.
affine_bounds :: proc(m: Affine, r: Rect) -> Rect {
	p0 := affine_apply(m, r.min)
	p1 := affine_apply(m, {r.max.x, r.min.y})
	p2 := affine_apply(m, {r.min.x, r.max.y})
	p3 := affine_apply(m, r.max)
	return {{min(p0.x, p1.x, p2.x, p3.x), min(p0.y, p1.y, p2.y, p3.y)}, {max(p0.x, p1.x, p2.x, p3.x), max(p0.y, p1.y, p2.y, p3.y)}}
}

affine_is_identity :: proc(m: Affine) -> bool { return m == AFFINE_IDENTITY }

// Average linear scale (square root of the area ratio): 2 for scale(2), 1 for any rotation.
affine_scale_factor :: proc(m: Affine) -> f32 { return math.sqrt(abs(affine_determinant(m))) }

// Uniform positive scale + translation only: what the draw layer bakes on the CPU (no GPU transform needed).
affine_is_scale_translate :: proc(m: Affine) -> bool { return m.b == 0 && m.c == 0 && m.a == m.d && m.a > 0 }

affine_from_xform :: proc(x: Xform) -> Affine { return {a = x.scale, d = x.scale, e = x.offset.x, f = x.offset.y} }
