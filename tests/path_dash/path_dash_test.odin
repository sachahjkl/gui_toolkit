// Tests of draw.path_dash: the dashes' ends along a line and around a corner, dots as contours of one point, a closed
// contour dashed across its last line, the offset, an odd pattern, a pattern of no length.   odin test tests/path_dash -vet
package path_dash_test

import "core:testing"
import "../../src/draw"

EPS :: 1e-4

@(private = "file")
near :: proc(a, b: draw.Vec2) -> bool { return abs(a.x - b.x) < EPS && abs(a.y - b.y) < EPS }

// The points of contour `i` of `p`.
@(private = "file")
contour :: proc(p: ^draw.Path, i: int) -> []draw.Vec2 {
	c := p.contours[i]
	return p.points[c.first:][:c.count]
}

@(private = "file")
line_path :: proc(points: ..draw.Vec2) -> draw.Path {
	p := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&p, points[0])
	for q in points[1:] { draw.path_line_to(&p, q) }
	return p
}

@(test)
dashes_along_a_line :: proc(t: ^testing.T) {
	p := line_path({0, 0}, {25, 0})
	d := draw.path_dash(&p, {4, 6}, allocator = context.temp_allocator)
	// (0-4, 10-14, 20-24: the last dash ends before the line does)
	testing.expect_value(t, len(d.contours), 3)
	for i in 0 ..< 3 {
		c := contour(&d, i)
		testing.expect_value(t, len(c), 2)
		testing.expect(t, near(c[0], {f32(i) * 10, 0}))
		testing.expect(t, near(c[1], {f32(i) * 10 + 4, 0}))
	}
	for c in d.contours { testing.expect(t, !c.closed) }
}

@(test)
a_dash_turns_a_corner :: proc(t: ^testing.T) {
	p := line_path({0, 0}, {3, 0}, {3, 10})
	d := draw.path_dash(&p, {5, 100}, allocator = context.temp_allocator)
	testing.expect_value(t, len(d.contours), 1)
	c := contour(&d, 0)
	testing.expect_value(t, len(c), 3)
	testing.expect(t, near(c[1], {3, 0}))
	testing.expect(t, near(c[2], {3, 2}))
}

@(test)
dots_are_single_points :: proc(t: ^testing.T) {
	p := line_path({0, 0}, {0, 20})
	d := draw.path_dash(&p, {0, 5}, allocator = context.temp_allocator)
	// (at 0, 5, 10 and 15: the gap after the last one ends with the line)
	testing.expect_value(t, len(d.contours), 4)
	for i in 0 ..< len(d.contours) {
		c := contour(&d, i)
		testing.expect_value(t, len(c), 1)
		testing.expect(t, near(c[0], {0, f32(i) * 5}))
	}
}

@(test)
a_closed_contour_is_dashed_back_to_its_start :: proc(t: ^testing.T) {
	p := draw.path_make(allocator = context.temp_allocator)
	draw.path_rounded_rect(&p, {{0, 0}, {10, 10}})
	d := draw.path_dash(&p, {5, 5}, allocator = context.temp_allocator)
	// (a perimeter of 40: four dashes, the last one on the left side, going up)
	testing.expect_value(t, len(d.contours), 4)
	last := contour(&d, 3)
	testing.expect(t, near(last[0], {0, 10}))
	testing.expect(t, near(last[len(last) - 1], {0, 5}))
}

@(test)
the_offset_shifts_the_pattern :: proc(t: ^testing.T) {
	p := line_path({0, 0}, {20, 0})
	d := draw.path_dash(&p, {4, 6}, offset = 7, allocator = context.temp_allocator)
	// (7 into the pattern is in a gap that ends at 10: the first dash starts at 3)
	c := contour(&d, 0)
	testing.expect(t, near(c[0], {3, 0}))
	testing.expect(t, near(c[1], {7, 0}))
}

@(test)
an_odd_pattern_is_read_twice :: proc(t: ^testing.T) {
	p := line_path({0, 0}, {12, 0})
	d := draw.path_dash(&p, {2}, allocator = context.temp_allocator)
	// (2 on, 2 off: 0, 4 and 8)
	testing.expect_value(t, len(d.contours), 3)
	testing.expect(t, near(contour(&d, 2)[0], {8, 0}))
}

@(test)
no_pattern_gives_a_copy :: proc(t: ^testing.T) {
	p := line_path({0, 0}, {5, 5}, {9, 1})
	d := draw.path_dash(&p, {}, allocator = context.temp_allocator)
	testing.expect_value(t, len(d.contours), 1)
	testing.expect_value(t, len(d.points), 3)
}
