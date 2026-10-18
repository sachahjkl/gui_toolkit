// Tests of the draw layer's 2D affine helpers.   odin test tests/affine -vet
package affine_test

import "core:math"
import "core:testing"
import "../../draw"

EPS :: 1e-4

near :: proc(a, b: draw.Vec2) -> bool { return abs(a.x - b.x) < EPS && abs(a.y - b.y) < EPS }

near_m :: proc(m, n: draw.Affine) -> bool {
	return abs(m.a - n.a) < EPS && abs(m.b - n.b) < EPS && abs(m.c - n.c) < EPS && abs(m.d - n.d) < EPS && abs(m.e - n.e) < EPS && abs(m.f - n.f) < EPS
}

@(test)
convention_matches_css :: proc(t: ^testing.T) {
	// CSS matrix(a, b, c, d, e, f): x' = a*x + c*y + e, y' = b*x + d*y + f
	m := draw.Affine{1, 2, 3, 4, 5, 6}
	testing.expect(t, near(draw.affine_apply(m, {10, 100}), {1 * 10 + 3 * 100 + 5, 2 * 10 + 4 * 100 + 6}))
	testing.expect(t, near(draw.affine_apply_vector(m, {10, 100}), {1 * 10 + 3 * 100, 2 * 10 + 4 * 100}))
	// rotate(90deg) turns +x into +y (clockwise on a y-down screen), like CSS
	testing.expect(t, near(draw.affine_apply(draw.affine_rotate(math.PI / 2), {1, 0}), {0, 1}))
	// skew(45deg, 0): x' = x + y
	testing.expect(t, near(draw.affine_apply(draw.affine_skew(math.PI / 4), {0, 2}), {2, 2}))
}

@(test)
composition_order :: proc(t: ^testing.T) {
	tr := draw.affine_translate({10, 0})
	sc := draw.affine_scale({2, 3})
	p := draw.Vec2{1, 1}
	// affine_mul(m, n) applies n first
	testing.expect(t, near(draw.affine_apply(draw.affine_mul(tr, sc), p), draw.affine_apply(tr, draw.affine_apply(sc, p))))
	testing.expect(t, near(draw.affine_apply(draw.affine_mul(tr, sc), p), {12, 3}))
	testing.expect(t, near(draw.affine_apply(draw.affine_mul(sc, tr), p), {22, 3}))
	// associativity
	r := draw.affine_rotate(0.7)
	testing.expect(t, near_m(draw.affine_mul(draw.affine_mul(tr, sc), r), draw.affine_mul(tr, draw.affine_mul(sc, r))))
	// identity
	testing.expect(t, near_m(draw.affine_mul(draw.AFFINE_IDENTITY, r), r))
	testing.expect(t, draw.affine_is_identity(draw.AFFINE_IDENTITY))
}

@(test)
around_origin :: proc(t: ^testing.T) {
	m := draw.affine_around(draw.affine_rotate(1.234), {50, 70})
	testing.expect(t, near(draw.affine_apply(m, {50, 70}), {50, 70}))   // the origin stays put
	s := draw.affine_around(draw.affine_scale({2, 2}), {10, 10})
	testing.expect(t, near(draw.affine_apply(s, {20, 10}), {30, 10}))
}

@(test)
inverse :: proc(t: ^testing.T) {
	m := draw.affine_mul(draw.affine_translate({30, -7}), draw.affine_mul(draw.affine_rotate(0.4), draw.affine_mul(draw.affine_skew(0.3, -0.2), draw.affine_scale({2, 0.5}))))
	inv, ok := draw.affine_inverse(m)
	testing.expect(t, ok)
	testing.expect(t, near_m(draw.affine_mul(m, inv), draw.AFFINE_IDENTITY))
	testing.expect(t, near_m(draw.affine_mul(inv, m), draw.AFFINE_IDENTITY))
	p := draw.Vec2{12.5, -3}
	testing.expect(t, near(draw.affine_apply(inv, draw.affine_apply(m, p)), p))
	_, ok = draw.affine_inverse(draw.affine_scale({0, 1}))
	testing.expect(t, !ok)
}

@(test)
bounds :: proc(t: ^testing.T) {
	r := draw.Rect{{0, 0}, {10, 20}}
	b := draw.affine_bounds(draw.affine_translate({5, 5}), r)
	testing.expect(t, near(b.min, {5, 5}) && near(b.max, {15, 25}))
	// 90 degrees: (x, y) -> (-y, x)
	b = draw.affine_bounds(draw.affine_rotate(math.PI / 2), r)
	testing.expect(t, near(b.min, {-20, 0}) && near(b.max, {0, 10}))
	// 45 degrees around the center of a 10 x 10 square: the bounds grow to the diagonal
	sq := draw.Rect{{0, 0}, {10, 10}}
	b = draw.affine_bounds(draw.affine_around(draw.affine_rotate(math.PI / 4), {5, 5}), sq)
	h := f32(5 * math.SQRT_TWO)
	testing.expect(t, near(b.min, {5 - h, 5 - h}) && near(b.max, {5 + h, 5 + h}))
}

@(test)
scale_classification :: proc(t: ^testing.T) {
	testing.expect(t, draw.affine_is_scale_translate(draw.affine_mul(draw.affine_translate({3, 4}), draw.affine_scale({2, 2}))))
	testing.expect(t, !draw.affine_is_scale_translate(draw.affine_scale({2, 1})))
	testing.expect(t, !draw.affine_is_scale_translate(draw.affine_rotate(0.1)))
	testing.expect(t, abs(draw.affine_scale_factor(draw.affine_rotate(0.8)) - 1) < EPS)
	testing.expect(t, abs(draw.affine_scale_factor(draw.affine_scale({2, 8})) - 4) < EPS)
	// push_scale's legacy Xform maps the same way
	x := draw.Xform{scale = 1.5, offset = {10, 20}}
	testing.expect(t, near(draw.affine_apply(draw.affine_from_xform(x), {2, 2}), {2 * 1.5 + 10, 2 * 1.5 + 20}))
}
