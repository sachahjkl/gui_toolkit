// Box shadows (draw.box_shadow, draw.inset_shadow) against a numeric reference: the coverage of the rounded rect,
// supersampled, convolved with the gaussian. Offscreen renderer (WARP), sRGB blending (a black shadow over white is
// 255 * (1 - coverage)).   odin test tests/shadows -vet
package shadows_test

import "core:log"
import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

N :: 96
SIZE :: [2]int{N, N}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = .Srgb) { return false }
	font.init(&f.fonts)
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); font.destroy(&f.fonts); render.destroy(&f.r) }

Shape :: struct { r: draw.Rect, radii: [4]f32 }   // radii: top-left, bottom-left, top-right, bottom-right

// Is p inside the rounded rect (circular corners)?
@(private = "file")
inside :: proc(s: Shape, p: [2]f64) -> bool {
	x0, y0, x1, y1 := f64(s.r.min.x), f64(s.r.min.y), f64(s.r.max.x), f64(s.r.max.y)
	if p.x < x0 || p.x > x1 || p.y < y0 || p.y > y1 { return false }
	corner :: proc(p: [2]f64, cx, cy, r: f64, left, top: bool) -> bool {
		if r <= 0 { return true }
		inx := left ? p.x < cx : p.x > cx
		iny := top ? p.y < cy : p.y > cy
		if !(inx && iny) { return true }
		dx, dy := p.x - cx, p.y - cy
		return dx * dx + dy * dy <= r * r
	}
	r := s.radii
	return corner(p, x0 + f64(r[0]), y0 + f64(r[0]), f64(r[0]), true, true) &&
		corner(p, x0 + f64(r[1]), y1 - f64(r[1]), f64(r[1]), true, false) &&
		corner(p, x1 - f64(r[2]), y0 + f64(r[2]), f64(r[2]), false, true) &&
		corner(p, x1 - f64(r[3]), y1 - f64(r[3]), f64(r[3]), false, false)
}

// The shape's coverage on a grid of `step` px cells (4 x 4 samples per cell), over [-pad, N + pad).
Grid :: struct { step, pad: f64, n: int, cov: []f64 }

@(private = "file")
grid_make :: proc(s: Shape, step, pad: f64) -> Grid {
	g := Grid{step = step, pad = pad}
	g.n = int(math.ceil((f64(N) + 2 * pad) / step))
	g.cov = make([]f64, g.n * g.n, context.temp_allocator)
	for j in 0 ..< g.n {
		for i in 0 ..< g.n {
			c := 0
			for sy in 0 ..< 4 {
				for sx in 0 ..< 4 {
					p := [2]f64{-pad + (f64(i) + (f64(sx) + 0.5) / 4) * step, -pad + (f64(j) + (f64(sy) + 0.5) / 4) * step}
					if inside(s, p) { c += 1 }
				}
			}
			g.cov[j * g.n + i] = f64(c) / 16
		}
	}
	return g
}

// The convolution of the grid with a gaussian at a pixel center (separable: rows, then the column).
@(private = "file")
blurred :: proc(g: ^Grid, x, y: f64, sigma: f64) -> f64 {
	if sigma <= 0 { return 0 }
	w :: proc(d, s: f64) -> f64 { return math.exp(-d * d / (2 * s * s)) / (s * math.sqrt(2 * math.PI)) }
	cx, cy := x + 0.5, y + 0.5
	reach := 4 * sigma
	j0 := max(int((cy - reach + g.pad) / g.step), 0)
	j1 := min(int((cy + reach + g.pad) / g.step) + 1, g.n)
	i0 := max(int((cx - reach + g.pad) / g.step), 0)
	i1 := min(int((cx + reach + g.pad) / g.step) + 1, g.n)
	total := 0.0
	for j in j0 ..< j1 {
		yy := -g.pad + (f64(j) + 0.5) * g.step
		row := 0.0
		for i in i0 ..< i1 {
			c := g.cov[j * g.n + i]
			if c == 0 { continue }
			xx := -g.pad + (f64(i) + 0.5) * g.step
			row += c * w(cx - xx, sigma)
		}
		total += row * w(cy - yy, sigma)
	}
	return total * g.step * g.step
}

@(private = "file")
shoot :: proc(f: ^Fx, body: proc(dc: ^draw.Context, data: rawptr), data: rawptr) -> []u8 {
	draw.begin_frame(&f.dc, {N, N})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	body(&f.dc, data)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
level :: proc(img: []u8, x, y: int) -> f64 { return 1 - f64(img[(y * N + x) * 4]) / 255 }

Case :: struct { s: Shape, sigma: f32, hole: Shape, inset: bool }

@(test)
outer_shadows_match_the_convolution :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	cases := []Case{
		{s = {{{28, 28}, {68, 68}}, {}}, sigma = 4},                         // square corners: erf both ways
		{s = {{{24, 30}, {72, 66}}, {12, 12, 12, 12}}, sigma = 4},           // rounded
		{s = {{{24, 24}, {72, 72}}, {20, 2, 8, 0}}, sigma = 3},              // a different radius at every corner
		{s = {{{30, 30}, {66, 66}}, {18, 18, 18, 18}}, sigma = 10},          // blur larger than the corners
		{s = {{{30, 30}, {66, 66}}, {10, 10, 10, 10}}, sigma = 0.8},         // nearly hard
		{s = {{{40, 20}, {56, 76}}, {8, 8, 8, 8}}, sigma = 6},               // a capsule
	}
	for cs, k in cases {
		cc := cs
		img := shoot(&f, proc(dc: ^draw.Context, data: rawptr) {
			c := (^Case)(data)
			draw.box_shadow(dc, c.s.r, c.s.radii, c.sigma, {0, 0, 0, 1})
		}, &cc)
		g := grid_make(cs.s, 0.25, 4 * f64(cs.sigma) + 2)
		worst := 0.0
		wx, wy := 0, 0
		for y := 0; y < N; y += 1 {
			for x := 0; x < N; x += 1 {
				d := abs(level(img, x, y) - blurred(&g, f64(x), f64(y), f64(cs.sigma)))
				if d > worst { worst, wx, wy = d, x, y }
			}
		}
		log.infof("case %d (sigma %v): worst difference %.2f levels (8 bits) at (%d, %d)", k, cs.sigma, worst * 255, wx, wy)
		testing.expectf(t, worst * 255 <= 2, "case %d (sigma %v): worst difference %.2f levels at (%d, %d)", k, cs.sigma, worst * 255, wx, wy)
	}
}

@(test)
holes_and_inset :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	// outer with the box clipped out: nothing inside the hole
	c := Case{s = {{{30, 30}, {70, 70}}, {10, 10, 10, 10}}, sigma = 5, hole = {{{26, 26}, {66, 66}}, {10, 10, 10, 10}}}
	img := shoot(&f, proc(dc: ^draw.Context, data: rawptr) {
		c := (^Case)(data)
		draw.box_shadow(dc, c.s.r, c.s.radii, c.sigma, {0, 0, 0, 1}, c.hole.r, c.hole.radii)
	}, &c)
	testing.expectf(t, level(img, 46, 46) == 0, "inside the hole: nothing (%v)", level(img, 46, 46))
	g := grid_make(c.s, 0.25, 22)
	testing.expectf(t, abs(level(img, 69, 69) - blurred(&g, 69, 69, 5)) * 255 <= 3, "outside the hole: the shadow")

	// inset: inside the padding box, the outside of the hole blurred: 1 - blur(hole)
	in_c := Case{s = {{{30, 34}, {66, 62}}, {6, 6, 6, 6}}, sigma = 4, hole = {{{20, 20}, {76, 76}}, {14, 14, 14, 14}}, inset = true}
	img2 := shoot(&f, proc(dc: ^draw.Context, data: rawptr) {
		c := (^Case)(data)
		draw.inset_shadow(dc, c.hole.r, c.hole.radii, c.s.r, c.s.radii, c.sigma, {0, 0, 0, 1})
	}, &in_c)
	g2 := grid_make(in_c.s, 0.25, 18)
	worst := 0.0
	for y in 24 ..< 72 {
		for x in 24 ..< 72 {
			if !inside(in_c.hole, {f64(x) - 1, f64(y) - 1}) || !inside(in_c.hole, {f64(x) + 2, f64(y) + 2}) { continue }   // away from the antialiased edge
			worst = max(worst, abs(level(img2, x, y) - (1 - blurred(&g2, f64(x), f64(y), 4))))
		}
	}
	testing.expectf(t, worst * 255 <= 3, "inset: worst difference %.2f levels", worst * 255)
	testing.expectf(t, level(img2, 5, 5) == 0, "inset: nothing outside the padding box")
	testing.expectf(t, level(img2, 22, 48) > 0.9, "inset: dark at the padding edge %v", level(img2, 22, 48))
}

@(test)
shadows_follow_transforms :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	c := Case{s = {{{28, 28}, {68, 68}}, {12, 12, 12, 12}}, sigma = 4}
	plain := shoot(&f, proc(dc: ^draw.Context, data: rawptr) {
		c := (^Case)(data)
		draw.box_shadow(dc, c.s.r, c.s.radii, c.sigma, {0, 0, 0, 1})
	}, &c)
	// a quarter turn around the center: the same symmetric shadow
	rot := shoot(&f, proc(dc: ^draw.Context, data: rawptr) {
		c := (^Case)(data)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.PI / 2), {48, 48}))
		draw.box_shadow(dc, c.s.r, c.s.radii, c.sigma, {0, 0, 0, 1})
		draw.pop_transform(dc)
	}, &c)
	worst := 0
	for i := 0; i < len(plain); i += 4 { worst = max(worst, abs(int(plain[i]) - int(rot[i]))) }
	testing.expectf(t, worst <= 2, "rotated a quarter turn: the same (difference %d)", worst)
	// scaled 2x around the center, from a half-size shape and sigma: the same
	half := Case{s = {{{38, 38}, {58, 58}}, {6, 6, 6, 6}}, sigma = 2}
	big := shoot(&f, proc(dc: ^draw.Context, data: rawptr) {
		c := (^Case)(data)
		draw.push_transform(dc, draw.affine_around(draw.affine_scale({2, 2}), {48, 48}))
		draw.box_shadow(dc, c.s.r, c.s.radii, c.sigma, {0, 0, 0, 1})
		draw.pop_transform(dc)
	}, &half)
	worst = 0
	for i := 0; i < len(plain); i += 4 { worst = max(worst, abs(int(plain[i]) - int(big[i]))) }
	testing.expectf(t, worst <= 2, "scaled: the same (difference %d)", worst)
}
