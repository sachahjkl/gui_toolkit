package tk_paint

import "core:encoding/endian"
import "core:math"
import "core:slice"
import "core:testing"

@(private = "file")
alpha_at :: proc(c: Canvas, x, y: int) -> f32 { return c.pixels[y * c.width + x].a }

@(private = "file")
total_alpha :: proc(c: Canvas) -> (sum: f32) {
	for p in c.pixels { sum += p.a }
	return
}

@(private = "file")
near :: proc(a, b, within: f32) -> bool { return abs(a - b) <= within }

@(test)
a_rectangle_on_whole_pixels_is_exact :: proc(t: ^testing.T) {
	c := canvas_make(8, 8)
	defer canvas_destroy(&c)
	p: Path
	defer path_destroy(&p)
	rect(&p, 2, 2, 3, 4)
	fill(&c, p, solid(hex(0xFF0000)))
	testing.expect_value(t, alpha_at(c, 2, 2), 1)
	testing.expect_value(t, alpha_at(c, 4, 5), 1)
	testing.expect_value(t, alpha_at(c, 5, 2), 0)
	testing.expect_value(t, alpha_at(c, 2, 6), 0)
	testing.expect_value(t, total_alpha(c), 12)
	testing.expect_value(t, c.pixels[2 * 8 + 2], [4]f32{1, 0, 0, 1})
}

@(test)
an_edge_inside_a_pixel_covers_its_share :: proc(t: ^testing.T) {
	c := canvas_make(8, 8)
	defer canvas_destroy(&c)
	p: Path
	defer path_destroy(&p)
	rect(&p, 1.25, 1.5, 2.5, 2)
	fill(&c, p, solid(hex(0)))
	testing.expect(t, near(alpha_at(c, 1, 2), 0.75, 1e-4), "three quarters of a column")
	testing.expect(t, near(alpha_at(c, 3, 2), 0.75, 1e-4), "three quarters of a column")
	testing.expect(t, near(alpha_at(c, 2, 1), 0.5, 1e-4), "half a row")
	testing.expect(t, near(total_alpha(c), 5, 1e-3), "the area")
}

@(test)
a_circle_covers_its_area :: proc(t: ^testing.T) {
	c := canvas_make(64, 64)
	defer canvas_destroy(&c)
	p: Path
	defer path_destroy(&p)
	ellipse(&p, 12, 12, 40, 40)
	fill(&c, p, solid(hex(0)))
	// (the chords of the flattened curve lose a little: TOLERANCE along the perimeter)
	testing.expectf(t, near(total_alpha(c), math.PI * 400, 5), "pi r squared: %v", total_alpha(c))
	testing.expect_value(t, alpha_at(c, 32, 32), 1)
	testing.expect_value(t, alpha_at(c, 12, 12), 0)
}

// Two squares, one in the other, wound the same way: the inner one is a hole only by the even-odd rule.
@(test)
the_fill_rules_differ_on_nested_figures :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	rect(&p, 0, 0, 10, 10)
	rect(&p, 3, 3, 4, 4)
	for rule in Fill_Rule {
		c := canvas_make(10, 10)
		fill(&c, p, solid(hex(0)), rule)
		testing.expect_value(t, alpha_at(c, 5, 5), rule == .Non_Zero ? 1 : 0)
		testing.expect_value(t, alpha_at(c, 1, 1), 1)
		canvas_destroy(&c)
	}
}

@(test)
a_transform_moves_paths_and_gradients :: proc(t: ^testing.T) {
	c := canvas_make(16, 16)
	defer canvas_destroy(&c)
	c.transform = scale(translate(IDENTITY, 4, 0), 2, 2)   // points scaled, then moved
	p: Path
	defer path_destroy(&p)
	rect(&p, 0, 0, 2, 8)
	fill(&c, p, linear({0, 0}, {0, 8}, hex(0x000000), hex(0xFFFFFF)))
	testing.expect_value(t, alpha_at(c, 3, 0), 0)
	testing.expect_value(t, alpha_at(c, 4, 0), 1)
	testing.expect_value(t, alpha_at(c, 7, 15), 1)
	testing.expect_value(t, alpha_at(c, 8, 15), 0)
	// the gradient runs over the 16 rows: row 8's centre is at 8.5 of 16
	testing.expect(t, near(c.pixels[8 * 16 + 5].r, 8.5 / 16, 1e-4), "the gradient through the transform")
}

@(test)
matrices_compose_in_the_order_of_the_calls :: proc(t: ^testing.T) {
	m := translate(scale(translate(IDENTITY, 10, 0), 2, 2), 1, 0)   // +1, then x2, then +10
	testing.expect_value(t, apply(m, {0, 0}), [2]f32{12, 0})
	r := rotate_at(IDENTITY, 90, 5, 5)
	testing.expect(t, length(apply(r, {5, 5}) - {5, 5}) < 1e-5, "the centre stays")
	testing.expect(t, length(apply(r, {6, 5}) - {5, 6}) < 1e-5, "clockwise on a canvas: right goes down")
	i := invert(m)
	testing.expect(t, length(apply(i, apply(m, {3, 4})) - {3, 4}) < 1e-5, "the inverse undoes")
}

@(test)
gradients_pad_and_repeat :: proc(t: ^testing.T) {
	g := linear({0, 0}, {10, 0}, hex(0x000000), hex(0xFFFFFF))
	testing.expect(t, near(shade(g, {5, 3}).r, 0.5, 1e-5), "the middle")
	testing.expect_value(t, shade(g, {-5, 0}).r, 0)
	testing.expect_value(t, shade(g, {15, 0}).r, 1)
	g.spread = .Repeat
	testing.expect(t, near(shade(g, {12.5, 0}).r, 0.25, 1e-5), "again from the start")
	set_stops(&g, {{0, hex(0x000000)}, {0.5, hex(0xFF0000)}, {1, hex(0xFFFFFF)}})
	testing.expect(t, near(shade(g, {2.5, 0}).r, 0.5, 1e-5), "between the first two stops")
	testing.expect(t, near(shade(g, {7.5, 0}).g, 0.5, 1e-5), "between the last two")
	r := radial({0, 0}, 10, hex(0xFFFFFF), hex(0x000000, 0))
	testing.expect(t, near(shade(r, {0, 5}).a, 0.5, 1e-5), "half way out")
	testing.expect_value(t, shade(r, {20, 0}).a, 0)
}

@(test)
a_stroke_covers_its_width_and_its_corners :: proc(t: ^testing.T) {
	c := canvas_make(20, 20)
	defer canvas_destroy(&c)
	p: Path
	defer path_destroy(&p)
	rect(&p, 5, 5, 10, 10)
	stroke(&c, p, {width = 2}, solid(hex(0)))
	testing.expect_value(t, alpha_at(c, 4, 4), 1)    // a mitred corner
	testing.expect_value(t, alpha_at(c, 10, 5), 1)
	testing.expect_value(t, alpha_at(c, 10, 3), 0)
	testing.expect_value(t, alpha_at(c, 10, 10), 0)
	testing.expect(t, near(total_alpha(c), 12 * 12 - 8 * 8, 1e-2), "the ring's area")
}

// A line, then an arc that starts a rounding away from where the line ended (as GDI+-style figures do): the join is still
// the corner's, outside.
@(test)
a_join_after_a_rounding_is_on_the_outside :: proc(t: ^testing.T) {
	c := canvas_make(40, 40)
	defer canvas_destroy(&c)
	p: Path
	defer path_destroy(&p)
	move_to(&p, 0, 20)
	line_to(&p, 20, 20)
	line_to(&p, 20, 19.999996)
	arc(&p, 20, 10, 20, 20, 180, -180)
	stroke(&c, p, {width = 4}, solid(hex(0)))
	testing.expect_value(t, alpha_at(c, 20, 18), 1)
	testing.expect(t, alpha_at(c, 21, 19) > 0.9, "the corner")   // (the arc's first segment leans a little)
}

@(test)
a_miter_past_its_limit_is_a_bevel :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	move_to(&p, 0, 0)
	line_to(&p, 40, 4)
	line_to(&p, 0, 8)   // a turn of nearly 180 degrees: a miter of some 10 widths
	sharp, limited: Canvas
	for c, i in ([2]^Canvas{&sharp, &limited}) {
		c^ = canvas_make(80, 16)
		stroke(c, p, {width = 2, miter_limit = i == 0 ? 100 : 2}, solid(hex(0)))
	}
	defer { canvas_destroy(&sharp); canvas_destroy(&limited) }
	testing.expect(t, alpha_at(sharp, 43, 4) > 0.5, "the long miter, 10 half widths out")
	testing.expect_value(t, alpha_at(limited, 43, 4), 0)
}

@(test)
round_caps_end_in_half_discs :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	move_to(&p, 10, 10)
	line_to(&p, 30, 10)
	flat, round: Canvas
	for c, i in ([2]^Canvas{&flat, &round}) {
		c^ = canvas_make(40, 20)
		stroke(c, p, {width = 8, cap = i == 0 ? .Flat : .Round}, solid(hex(0)))
	}
	defer { canvas_destroy(&flat); canvas_destroy(&round) }
	testing.expect(t, near(total_alpha(flat), 20 * 8, 1e-2), "the line alone")
	testing.expectf(t, near(total_alpha(round), 20 * 8 + math.PI * 16, 1.5), "and a disc: %v", total_alpha(round))
	testing.expect_value(t, alpha_at(round, 7, 10), 1)
}

@(test)
widen_with_a_coarse_flatness_makes_lines :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	move_to(&p, 0, 0)
	cubic_to(&p, 30, 40, 70, 40, 100, 0)
	fine := widen(p, {width = 4}, TOLERANCE, context.temp_allocator)
	coarse := widen(p, {width = 4}, 2, context.temp_allocator)
	testing.expect(t, len(coarse.verbs) < len(fine.verbs) / 2, "fewer segments")
}

@(test)
the_clip_bounds_drawing_and_clearing :: proc(t: ^testing.T) {
	c := canvas_make(10, 10)
	defer canvas_destroy(&c)
	all, half: Path
	defer { path_destroy(&all); path_destroy(&half) }
	rect(&all, 0, 0, 10, 10)
	rect(&half, 0, 0, 5, 10)
	set_clip(&c, half)
	fill(&c, all, solid(hex(0)))
	testing.expect_value(t, total_alpha(c), 50)
	reset_clip(&c)
	fill(&c, all, solid(hex(0)))
	set_clip(&c, half)
	clear(&c)
	testing.expect_value(t, alpha_at(c, 2, 2), 0)
	testing.expect_value(t, alpha_at(c, 7, 2), 1)
	reset_clip(&c)
	// a clip without antialiasing takes the pixels whose centre is inside
	slice.zero(c.pixels)
	set_clip(&c, path_of_rect(4.4, 0, 2, 10), antialias = false)
	fill(&c, all, solid(hex(0)))
	testing.expect_value(t, alpha_at(c, 4, 0), 1)   // centre 4.5 in [4.4, 6.4)
	testing.expect_value(t, alpha_at(c, 6, 0), 0)   // centre 6.5 not
	testing.expect_value(t, total_alpha(c), 20)
}

@(private = "file")
path_of_rect :: proc(x, y, w, h: f32) -> Path {
	p := Path{verbs = make([dynamic]Verb, context.temp_allocator), points = make([dynamic][2]f32, context.temp_allocator)}
	rect(&p, x, y, w, h)
	return p
}

@(test)
a_resize_keeps_a_flat_colour_and_averages_detail :: proc(t: ^testing.T) {
	src := canvas_make(64, 64)
	defer canvas_destroy(&src)
	for &p, i in src.pixels { p = ((i % 64) + (i / 64)) % 2 == 0 ? {1, 1, 1, 1} : {0, 0, 0, 1} }
	small := resize(src, 8, 8)
	defer canvas_destroy(&small)
	// a checkerboard 8 times smaller: grey, opaque inside, its edge fading (the outside counts as transparent)
	testing.expect(t, near(small.pixels[3 * 8 + 3].r, 0.5, 0.02), "grey")
	testing.expect(t, near(small.pixels[3 * 8 + 3].a, 1, 1e-4), "opaque")
	testing.expect(t, small.pixels[0].a < 1, "the edge fades")
	flat := canvas_make(40, 40)
	defer canvas_destroy(&flat)
	for &p in flat.pixels { p = {0.2, 0.4, 0.6, 1} }
	part := canvas_make(5, 5)
	defer canvas_destroy(&part)
	draw_canvas(&part, flat, {0, 0, 5, 5}, {10, 10, 20, 20})
	testing.expect(t, length(part.pixels[12].rg - {0.2, 0.4}) < 1e-4, "the colour kept")
}

@(test)
nearest_magnifies_pixels :: proc(t: ^testing.T) {
	src := canvas_make(2, 2)
	defer canvas_destroy(&src)
	src.pixels[1] = {1, 0, 0, 1}
	big := canvas_make(10, 10)
	defer canvas_destroy(&big)
	draw_canvas(&big, src, {2, 2, 8, 8}, {0, 0, 2, 2}, .Nearest)
	testing.expect_value(t, big.pixels[2 * 10 + 6], [4]f32{1, 0, 0, 1})
	testing.expect_value(t, big.pixels[2 * 10 + 5].a, 0)
	testing.expect_value(t, big.pixels[5 * 10 + 9], [4]f32{1, 0, 0, 1})
	testing.expect_value(t, big.pixels[6 * 10 + 9].a, 0)
}

@(test)
a_png_reads_back_as_written :: proc(t: ^testing.T) {
	c := canvas_make(13, 7)
	defer canvas_destroy(&c)
	p: Path
	defer path_destroy(&p)
	ellipse(&p, 1, 1, 11, 5)
	fill(&c, p, linear({0, 0}, {13, 0}, hex(0xFF8000), hex(0x0080FF, 128)))
	data := png_encode(c, context.temp_allocator)
	back, ok := png_decode(data)
	defer canvas_destroy(&back)
	testing.expect(t, ok, "a PNG")
	testing.expect(t, slice.equal(to_rgba8(back, context.temp_allocator), to_rgba8(c, context.temp_allocator)), "the same bytes")
	testing.expect(t, slice.equal(png_encode(c, context.temp_allocator), data), "the same file again")
}

@(test)
an_icon_of_pictures :: proc(t: ^testing.T) {
	ico := ico_encode({{16, {1, 2, 3}}, {256, {4, 5}}}, context.temp_allocator)
	u16_at :: proc(b: []byte, o: int) -> int { v, _ := endian.get_u16(b[o:], .Little); return int(v) }
	u32_at :: proc(b: []byte, o: int) -> int { v, _ := endian.get_u32(b[o:], .Little); return int(v) }
	testing.expect_value(t, len(ico), 6 + 2 * 16 + 5)
	testing.expect_value(t, u16_at(ico, 2), 1)   // an icon
	testing.expect_value(t, u16_at(ico, 4), 2)
	testing.expect_value(t, ico[6], 16)
	testing.expect_value(t, ico[22], 0)          // 256 is said 0
	testing.expect_value(t, u16_at(ico, 6 + 6), 32)
	testing.expect_value(t, u32_at(ico, 6 + 8), 3)
	testing.expect_value(t, u32_at(ico, 6 + 12), 38)
	testing.expect_value(t, u32_at(ico, 22 + 12), 41)
	testing.expect(t, slice.equal(ico[41:], []byte{4, 5}), "the second picture last")
}

@(test)
a_dib_is_bottom_up_bgra_with_a_mask :: proc(t: ^testing.T) {
	c := canvas_make(3, 2)
	defer canvas_destroy(&c)
	c.pixels[0] = {1, 0, 0, 1}   // top left: red
	dib := dib_encode(c, context.temp_allocator)
	testing.expect_value(t, len(dib), 40 + 3 * 2 * 4 + 4 * 2)
	h, _ := endian.get_i32(dib[8:], .Little)
	testing.expect_value(t, h, 4)                                    // the height doubled
	testing.expect(t, slice.equal(dib[40 + 12:][:4], []u8{0, 0, 255, 255}), "the top row last, blue first")
	testing.expect(t, slice.equal(dib[40:][:4], []u8{0, 0, 0, 0}), "transparent")
}
