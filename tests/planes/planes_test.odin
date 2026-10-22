// Pixel tests of planes (layers drawn through a 4x4 matrix: CSS 3D transforms) on an offscreen renderer (WARP, the software
// rasterizer: no GPU or window needed), in both blend spaces.   odin test tests/planes -vet
// (The same tests run on the WebGPU backend: tools\test_backends.ps1 -Backend wgpu.)
package planes_test

import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{96, 96}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
open :: proc(f: ^Fx, space: render.Blend_Space) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
frame :: proc(f: ^Fx, body: proc(dc: ^draw.Context)) -> []u8 {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	body(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
px :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

@(private = "file")
is_red :: proc(p: [4]int) -> bool { return p[0] > 240 && p[1] < 16 && p[2] < 16 }
@(private = "file")
is_blue :: proc(p: [4]int) -> bool { return p[2] > 240 && p[0] < 16 && p[1] < 16 }
@(private = "file")
is_white :: proc(p: [4]int) -> bool { return p[0] > 250 && p[1] > 250 && p[2] > 250 }

RED :: draw.Color{1, 0, 0, 1}
BLUE :: draw.Color{0, 0, 1, 1}

// translate(cx, cy) * perspective(d) * rotateY(deg) * translate(-hx, -hy): the plane of size (2hx, 2hy) turned about its middle
// and put with its middle at (cx, cy).
@(private = "file")
turned :: proc(c: [2]f32, hs: [2]f32, d: f32, deg: f32) -> draw.Mat4 {
	a := deg * math.PI / 180
	co, si := math.cos(a), math.sin(a)
	t0 := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -hs.x, -hs.y, 0, 1}
	ry := draw.Mat4{co, 0, -si, 0, 0, 1, 0, 0, si, 0, co, 0, 0, 0, 0, 1}
	p := draw.MAT4_IDENTITY
	if d > 0 { p[11] = -1 / d }
	t1 := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, c.x, c.y, 0, 1}
	return draw.mat4_mul(t1, draw.mat4_mul(p, draw.mat4_mul(ry, t0)))
}

@(private = "file")
project :: proc(m: draw.Mat4, p: [2]f32) -> [2]f32 {
	h := draw.mat4_apply(m, {p.x, p.y, 0})
	return {h.x / h.w, h.y / h.w}
}

@(private = "file")
two_halves :: proc(dc: ^draw.Context, m: draw.Mat4, o: draw.Plane_Draw = {}) {
	draw.push_plane(dc, {{0, 0}, {60, 60}}, 1)
	draw.rect(dc, {{0, 0}, {30, 60}}, RED)
	draw.rect(dc, {{30, 0}, {60, 60}}, BLUE)
	draw.pop_plane_draw(dc, m, 1, o)
}

// A plane through a translation looks like the same rect drawn plainly.
@(test)
flat_plane_equals_plain_rect :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		plane := frame(&f, proc(dc: ^draw.Context) {
			m := draw.mat4_from_affine(draw.affine_translate({10, 20}))
			two_halves(dc, m)
		})
		plain := frame(&f, proc(dc: ^draw.Context) {
			draw.push_transform(dc, draw.affine_translate({10, 20}))
			draw.rect(dc, {{0, 0}, {30, 60}}, RED)
			draw.rect(dc, {{30, 0}, {60, 60}}, BLUE)
			draw.pop_transform(dc)
		})
		worst := 0
		for i in 0 ..< len(plain) { worst = max(worst, abs(int(plain[i]) - int(plane[i]))) }
		testing.expectf(t, worst <= 3, "%v: a plane under a translation differs from the plain rects by up to %d levels", space, worst)
	}
}

// Perspective: the near edge is taller than the far one, the color boundary sits at the projected middle (not at the
// middle of the projected quad), pixels beyond the quad stay clear.
@(test)
perspective_is_correct :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		m := turned({48, 48}, {30, 30}, 90, 50)
		@(static) mm: draw.Mat4
		mm = m
		img := frame(&f, proc(dc: ^draw.Context) { two_halves(dc, mm) })
		tl, tr := project(m, {0, 0}), project(m, {60, 0})
		bl := project(m, {0, 60})
		mid := project(m, {30, 30})
		// rotateY(+): the right side goes away from the eye in CSS (+z is toward the viewer; sin > 0 moves the right edge
		// to -z... whichever side it is, one edge is taller than the other)
		hl := bl.y - tl.y
		tr_h := project(m, {60, 60}).y - tr.y
		testing.expectf(t, abs(hl - tr_h) > 4, "%v: the projected edges have different heights (%.1f, %.1f)", space, hl, tr_h)
		mx, my := int(math.round(mid.x)), int(math.round(mid.y))
		testing.expectf(t, is_red(px(img, mx - 3, my)) && is_blue(px(img, mx + 3, my)), "%v: the boundary is at the projected middle (%d,%d): %v %v", space, mx, my, px(img, mx - 3, my), px(img, mx + 3, my))
		// the screen midpoint of the near and far edges is not where the boundary lies (affine would put it there)
		affine_mid := ((tl + tr) * 0.5 + (bl + project(m, {60, 60})) * 0.5) * 0.5
		testing.expectf(t, abs(affine_mid.x - mid.x) > 1.5, "%v: perspective moved the middle (%.2f vs %.2f)", space, affine_mid.x, mid.x)
		testing.expectf(t, is_white(px(img, 2, 2)) && is_white(px(img, 93, 93)), "%v: outside stays clear", space)
		// just inside the near edge is covered, just outside is not
		near_x := tl.x < tr.x ? 0 : 60
		_ = near_x
		top_mid := (tl + tr) * 0.5
		testing.expectf(t, !is_white(px(img, int(top_mid.x), int(top_mid.y) + 3)), "%v: inside the top edge is painted", space)
		testing.expectf(t, is_white(px(img, int(top_mid.x), int(top_mid.y) - 5)), "%v: above the top edge is clear", space)
	}
}

// backface-visibility: hidden hides a plane seen from behind; visible mirrors it.
@(test)
backface_culling :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	@(static) mm: draw.Mat4
	mm = turned({48, 48}, {30, 30}, 0, 180)
	shown := frame(&f, proc(dc: ^draw.Context) { two_halves(dc, mm) })
	hidden := frame(&f, proc(dc: ^draw.Context) { two_halves(dc, mm, draw.Plane_Draw{cull_back = true}) })
	// mirrored: blue is now on the left
	testing.expectf(t, is_blue(px(shown, 40, 48)) && is_red(px(shown, 56, 48)), "seen from behind the plane is mirrored: %v %v", px(shown, 40, 48), px(shown, 56, 48))
	testing.expectf(t, is_white(px(hidden, 40, 48)) && is_white(px(hidden, 56, 48)), "backface hidden: nothing is drawn: %v", px(hidden, 40, 48))
	front := frame(&f, proc(dc: ^draw.Context) {
		mm = turned({48, 48}, {30, 30}, 0, 0)
		two_halves(dc, mm, draw.Plane_Draw{cull_back = true})
	})
	testing.expectf(t, is_red(px(front, 40, 48)), "facing the viewer, culling draws it: %v", px(front, 40, 48))
}

// A plane partly behind the eye is clipped, not smeared or mirrored in.
@(test)
plane_crossing_the_eye_is_clipped :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	// a strongly turned plane close to the eye: its far corners get w < 0
	@(static) mm: draw.Mat4
	mm = turned({48, 48}, {30, 30}, 30, 75)
	img := frame(&f, proc(dc: ^draw.Context) { two_halves(dc, mm) })
	bad := 0
	for y in 0 ..< SIZE.y { for x in 0 ..< SIZE.x {
		p := px(img, x, y)
		// everything is a blend of white, red and blue: green never exceeds the weaker of red and blue
		if p[1] > min(p[0], p[2]) + 6 { bad += 1 }
	} }
	testing.expectf(t, bad == 0, "%d pixels of an impossible color", bad)
}

// A plane whose content did not change is kept: drawn again from its texture, with another matrix, giving what drawing it
// would have given.
@(test)
kept_plane_is_not_drawn_again :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	@(static) mm: draw.Mat4
	@(static) drawn: int
	@(static) skipped: int
	body :: proc(dc: ^draw.Context) {
		if draw.push_plane(dc, {{0, 0}, {60, 60}}, 1, draw.Plane_Fx{cache_id = 7, cache_key = 1234}) {
			drawn += 1
			draw.rect(dc, {{0, 0}, {30, 60}}, RED)
			draw.rect(dc, {{30, 0}, {60, 60}}, BLUE)
		} else { skipped += 1 }
		draw.pop_plane_draw(dc, mm)
	}
	var_imgs: [4][]u8
	for k in 0 ..< 4 {
		mm = turned({48, 48}, {30, 30}, 90, f32(10 + 10 * k))
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		body(&f.dc)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		var_imgs[k] = render.read_pixels(&f.r, context.temp_allocator)
	}
	testing.expectf(t, drawn == 2 && skipped == 2, "drawn %d times, skipped %d (kept after two frames with the same key, used from the third)", drawn, skipped)
	// the fourth frame (from the kept texture) is what drawing it directly gives
	direct := frame(&f, proc(dc: ^draw.Context) {
		draw.push_plane(dc, {{0, 0}, {60, 60}}, 1)
		draw.rect(dc, {{0, 0}, {30, 60}}, RED)
		draw.rect(dc, {{30, 0}, {60, 60}}, BLUE)
		draw.pop_plane_draw(dc, mm)
	})
	worst := 0
	for i in 0 ..< len(direct) { worst = max(worst, abs(int(direct[i]) - int(var_imgs[3][i]))) }
	testing.expectf(t, worst <= 1, "the kept plane differs from the drawn one by up to %d levels", worst)
}
