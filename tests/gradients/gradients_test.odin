// Pixel tests of gradients evaluated by the shader (draw.gradient): values at the stops, between them, hard stops,
// transition hints, repeating, radial and conic geometry, interpolation spaces, tiles, dithering, rounded corners.
// Offscreen renderer (WARP).   odin test tests/gradients -vet
package gradients_test

import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

W :: 200
H :: 40
SIZE :: [2]int{W, H}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
open :: proc(f: ^Fx, space: render.Blend_Space) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	font.init(&f.fonts)
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); font.destroy(&f.fonts); render.destroy(&f.r) }

@(private = "file")
shoot :: proc(f: ^Fx, g: draw.Gradient, r: draw.Rect = {{0, 0}, {W, H}}, radii: [4]f32 = {}) -> []u8 {
	draw.begin_frame(&f.dc, {W, H})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.gradient(&f.dc, r, g, radii)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
px :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * W + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

@(private = "file")
near :: proc(a: [4]int, b: [3]int, tol := 2) -> bool {
	for i in 0 ..< 3 { if abs(a[i] - b[i]) > tol { return false } }
	return true
}

// sRGB byte -> linear color (stop colors are given linear, as every draw color)
@(private = "file")
c8 :: proc(r, g, b: int, a: f32 = 1) -> draw.Color { return draw.srgb(f32(r) / 255, f32(g) / 255, f32(b) / 255, a) }

RED :: [3]int{255, 0, 0}
BLUE :: [3]int{0, 0, 255}

// A linear gradient across the width, pixel x at t = (x + 0.5) / W.
@(private = "file")
across :: proc(stops: []draw.Gradient_Stop, space := draw.Gradient_Space.Srgb, repeating := false) -> draw.Gradient {
	return draw.Gradient{kind = .Linear, start = {0, 0}, end = {W, 0}, stops = stops, space = space, repeating = repeating}
}

@(test)
linear_stops_and_midpoints :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	stops := []draw.Gradient_Stop{{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255), pos = 1}}
	img := shoot(&f, across(stops))
	testing.expectf(t, near(px(img, 0, 20), RED), "start: red %v", px(img, 0, 20))
	testing.expectf(t, near(px(img, W - 1, 20), BLUE), "end: blue %v", px(img, W - 1, 20))
	// t = 100.5 / 200: interpolated on sRGB values (CSS default): 127.4 red, 127.6 blue
	testing.expectf(t, near(px(img, 100, 20), {127, 0, 128}, 1), "middle in sRGB: %v", px(img, 100, 20))
	testing.expectf(t, near(px(img, 50, 5), {191, 0, 64}, 1), "a quarter: %v", px(img, 50, 5))
	// constant across the gradient line
	testing.expect(t, px(img, 77, 0) == px(img, 77, H - 1))

	// in linear light the middle is lighter: sRGB of 0.5 linear = 188
	lin := shoot(&f, across(stops, .Linear))
	testing.expectf(t, near(px(lin, 100, 20), {188, 0, 188}, 2), "middle in linear light: %v", px(lin, 100, 20))

	// to a transparent color: premultiplied, no gray fringe (red stays red while it fades)
	fade := shoot(&f, across({{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255, 0), pos = 1}}))
	testing.expectf(t, near(px(fade, 100, 20), {255, 128, 128}, 2), "red to transparent over white: %v", px(fade, 100, 20))

	// the transparent end takes no blue in
	testing.expectf(t, px(fade, 160, 20)[2] == px(fade, 160, 20)[1], "no blue in a fade to transparent blue: %v", px(fade, 160, 20))
}

@(test)
hard_stops_hints_and_extensions :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	hard := shoot(&f, across({{color = c8(255, 0, 0), pos = 0.3}, {color = c8(0, 0, 255), pos = 0.3}}))
	testing.expectf(t, near(px(hard, 58, 20), RED, 0), "before the hard stop: red %v", px(hard, 58, 20))
	testing.expectf(t, near(px(hard, 61, 20), BLUE, 0), "after: blue %v", px(hard, 61, 20))
	testing.expectf(t, near(px(hard, 0, 20), RED, 0) && near(px(hard, W - 1, 20), BLUE, 0), "the ends extend the first and last colors")

	// a hint at 25 %: the half-and-half color at a quarter of the interval
	hinted := shoot(&f, across({{color = c8(255, 0, 0), pos = 0, has_hint = true, hint = 0.25}, {color = c8(0, 0, 255), pos = 1}}))
	p := px(hinted, 49, 20)   // t = 49.5 / 200 ~ 0.2475
	testing.expectf(t, near(p, {128, 0, 127}, 3), "hint: half mix at a quarter %v", p)
	q := px(hinted, 150, 20)
	testing.expectf(t, q[2] > 200, "past the hint the far color dominates %v", q)

	// three stops with the middle one unpositioned by the caller: positions as given
	three := shoot(&f, across({{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 255, 0), pos = 0.5}, {color = c8(0, 0, 255), pos = 1}}))
	testing.expectf(t, near(px(three, 100, 20), {0, 255, 0}, 3), "middle stop: green %v", px(three, 100, 20))
}

@(test)
repeating_radial_conic :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	// a period of 50 px (t 0..0.25)
	rep := shoot(&f, across({{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255), pos = 0.25}}, repeating = true))
	for k in 0 ..< 4 {
		a, b := px(rep, k * 50 + 2, 20), px(rep, k * 50 + 25, 20)
		testing.expectf(t, a[0] > 230 && a[2] < 25, "period %d starts red %v", k, a)
		testing.expectf(t, near(b, {127, 0, 128}, 3), "period %d middle %v", k, b)
	}
	// a period of zero: the average color
	avg := shoot(&f, across({{color = c8(255, 0, 0), pos = 0.5}, {color = c8(0, 0, 255), pos = 0.5}}, repeating = true))
	pa := px(avg, 10, 10)
	testing.expectf(t, pa == px(avg, 190, 30) && pa[0] > 100 && pa[2] > 100, "zero period: one average color %v", pa)

	// radial: a circle of radius 20 centered at (100, 20); white at the center, black from the radius on
	rad := shoot(&f, draw.Gradient{kind = .Radial, center = {100, 20}, radii = {20, 20},
		stops = {{color = c8(255, 255, 255), pos = 0}, {color = c8(0, 0, 0), pos = 1}}})
	testing.expectf(t, px(rad, 100, 20)[0] > 245, "radial center: white %v", px(rad, 100, 20))
	m := px(rad, 110, 19)   // distance 10.5 / 20 from the center (pixel center 110.5, 19.5)
	testing.expectf(t, abs(m[0] - int(255 * (1 - math.sqrt(f32(10.5 * 10.5 + 0.25)) / 20) + 0.5)) <= 3, "radial half way %v", m)
	testing.expectf(t, near(px(rad, 130, 20), {0, 0, 0}, 0) && near(px(rad, 5, 5), {0, 0, 0}, 0), "outside the radius: the last color")
	// an ellipse: twice as wide
	ell := shoot(&f, draw.Gradient{kind = .Radial, center = {100, 20}, radii = {40, 20},
		stops = {{color = c8(255, 255, 255), pos = 0}, {color = c8(0, 0, 0), pos = 1}}})
	testing.expectf(t, abs(px(ell, 119, 20)[0] - px(rad, 109, 20)[0]) <= 3, "ellipse: x distances count half")

	// conic from the top, clockwise: red at 0 turn, blue at 1 turn
	con := shoot(&f, draw.Gradient{kind = .Conic, center = {100, 20}, angle = 0,
		stops = {{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255), pos = 1}}})
	right := px(con, 150, 19)   // a quarter turn (just above the horizontal)
	left := px(con, 50, 19)     // three quarters
	below := px(con, 100, 39)   // half a turn
	testing.expectf(t, near(right, {191, 0, 64}, 4), "conic: quarter turn %v", right)
	testing.expectf(t, near(below, {127, 0, 128}, 4), "conic: half turn %v", below)
	testing.expectf(t, near(left, {64, 0, 191}, 4), "conic: three quarters %v", left)
	// a start angle of a quarter turn moves everything by 90 degrees
	con2 := shoot(&f, draw.Gradient{kind = .Conic, center = {100, 20}, angle = math.PI / 2,
		stops = {{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255), pos = 1}}})
	testing.expectf(t, near(px(con2, 100, 39), {191, 0, 64}, 4), "conic from 90deg: a quarter at the bottom %v", px(con2, 100, 39))
}

@(test)
color_spaces :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	stops := []draw.Gradient_Stop{{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255), pos = 1}}
	// reference: oklab midpoint of red and blue (CSS Color 4 sample code), to sRGB bytes
	mid := oklab_mid({1, 0, 0}, {0, 0, 1}, 100.5 / 200)
	ok := shoot(&f, across(stops, .Oklab))
	testing.expectf(t, near(px(ok, 100, 20), mid, 2), "oklab middle %v, expected %v", px(ok, 100, 20), mid)
	// oklch goes around the hue circle: the middle of red and blue is a saturated purple, not oklab's dull one
	lch := shoot(&f, across(stops, .Oklch))
	pl := px(lch, 100, 20)
	testing.expectf(t, pl[0] + pl[2] > px(ok, 100, 20)[0] + px(ok, 100, 20)[2], "oklch middle more saturated %v", pl)
	// hsl: red (0) to blue (240) the shorter way passes through magenta (300)
	hsl := shoot(&f, across(stops, .Hsl))
	testing.expectf(t, near(px(hsl, 100, 20), {255, 0, 255}, 4), "hsl shorter hue: magenta %v", px(hsl, 100, 20))
	// longer: through green
	hl := draw.Gradient{kind = .Linear, start = {0, 0}, end = {W, 0}, stops = stops, space = .Hsl, hue = .Longer}
	hsl_long := shoot(&f, hl)
	testing.expectf(t, near(px(hsl_long, 100, 20), {0, 255, 0}, 6), "hsl longer hue: green %v", px(hsl_long, 100, 20))
	// lab and lch run (finite colors)
	inner := []draw.Gradient_Stop{{color = c8(255, 0, 0), pos = 0.05}, {color = c8(0, 0, 255), pos = 0.95}}
	for sp in ([]draw.Gradient_Space{.Lab, .Lch, .Hwb, .Oklch}) {
		img := shoot(&f, across(inner, sp))
		testing.expectf(t, near(px(img, 0, 20), RED, 3) && near(px(img, W - 1, 20), BLUE, 3), "%v: ends exact %v %v", sp, px(img, 0, 20), px(img, W - 1, 20))
	}
}

@(private = "file")
oklab_mid :: proc(a, b: [3]f64, t: f64) -> [3]int {
	to :: proc(c: [3]f64) -> [3]f64 {
		l := 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
		m := 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
		s := 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
		l, m, s = math.cbrt(l), math.cbrt(m), math.cbrt(s)
		return {0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s}
	}
	x, y := to(a), to(b)
	o := x + (y - x) * t
	l_ := o.x + 0.3963377774 * o.y + 0.2158037573 * o.z
	m_ := o.x - 0.1055613458 * o.y - 0.0638541728 * o.z
	s_ := o.x - 0.0894841775 * o.y - 1.2914855480 * o.z
	l, m, s := l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
	lin := [3]f64{4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s}
	out: [3]int
	for i in 0 ..< 3 {
		v := clamp(lin[i], 0, 1)
		e := v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055
		out[i] = int(e * 255 + 0.5)
	}
	return out
}

@(test)
tiles_corners_dither :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	stops := []draw.Gradient_Stop{{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255), pos = 1}}
	// a 20 x 40 tile repeated along x, a gap of 5 between tiles (background-repeat: space)
	tiled := shoot(&f, draw.Gradient{kind = .Linear, start = {0, 0}, end = {20, 0}, stops = stops,
		tile = {{10, 0}, {30, 40}}, repeat = {true, false}, spacing = {5, 0}})
	testing.expectf(t, px(tiled, 15, 20) == px(tiled, 40, 20) && px(tiled, 40, 20) == px(tiled, 65, 20), "tiles repeat every 25 px")
	testing.expectf(t, near(px(tiled, 32, 20), {255, 255, 255}, 0), "the gap shows what is below: %v", px(tiled, 32, 20))
	testing.expectf(t, near(px(tiled, 4, 20), {6, 0, 249}, 3), "before the first tile: the end of the previous copy %v", px(tiled, 4, 20))

	// rounded corners: the SDF of rects
	round := shoot(&f, across(stops), {{0, 0}, {W, H}}, {16, 16, 16, 16})
	testing.expectf(t, near(px(round, 0, 0), {255, 255, 255}, 0), "corner cut: %v", px(round, 0, 0))
	testing.expectf(t, near(px(round, 2, 20), RED, 3), "edge kept: %v", px(round, 2, 20))

	// dithering: each pixel within one level, the average unchanged
	g := across({{color = c8(40, 40, 40), pos = 0}, {color = c8(60, 60, 60), pos = 1}})
	plain := shoot(&f, g)
	g.dither = true
	dith := shoot(&f, g)
	sum_p, sum_d, moved := 0, 0, 0
	for y in 0 ..< H {
		for x in 0 ..< W {
			a, b := px(plain, x, y), px(dith, x, y)
			testing.expect(t, abs(a[1] - b[1]) <= 2)
			sum_p += a[1]
			sum_d += b[1]
			if a[1] != b[1] { moved += 1 }
		}
	}
	testing.expectf(t, abs(f32(sum_p - sum_d)) / f32(W * H) < 0.15, "dithering keeps the average (%d vs %d)", sum_p, sum_d)
	testing.expectf(t, moved > W * H / 10, "dithering moves pixels (%d)", moved)
}

@(test)
linear_blend_space_and_transform :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	stops := []draw.Gradient_Stop{{color = c8(255, 0, 0), pos = 0}, {color = c8(0, 0, 255), pos = 1}}
	img := shoot(&f, across(stops))
	testing.expectf(t, near(px(img, 100, 20), {127, 0, 128}, 1), "sRGB interpolation in a linear frame %v", px(img, 100, 20))
	// under a transform (scale 2 around the origin, rotation 180 degrees about the center): same colors, moved
	draw.begin_frame(&f.dc, {W, H})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.push_transform(&f.dc, draw.affine_around(draw.affine_rotate(math.PI), {W / 2, H / 2}))
	draw.gradient(&f.dc, {{0, 0}, {W, H}}, across(stops))
	draw.pop_transform(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	rot := render.read_pixels(&f.r, context.temp_allocator)
	testing.expectf(t, near(px(rot, 2, 20), BLUE, 4) && near(px(rot, W - 3, 20), RED, 4), "rotated half a turn: blue on the left")
}
