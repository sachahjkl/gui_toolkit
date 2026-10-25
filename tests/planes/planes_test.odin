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

// A plane opened inside another one, closed first and drawn only after the outer one was composited (the members of a
// preserve-3d context): its pixels are not lost.
@(test)
nested_plane_drawn_after_its_parent :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	img := frame(&f, proc(dc: ^draw.Context) {
		m := draw.mat4_from_affine(draw.affine_translate({10, 10}))
		draw.push_plane(dc, {{0, 0}, {40, 40}}, 1)
		draw.push_plane(dc, {{0, 0}, {40, 40}}, 1)
		draw.rect(dc, {{0, 0}, {40, 40}}, RED)
		inner := draw.pop_plane(dc)
		outer_done := draw.pop_plane(dc)
		draw.draw_plane(dc, inner, m)
		draw.draw_plane(dc, outer_done, m)
	})
	testing.expectf(t, is_red(px(img, 30, 30)), "the inner plane shows: %v", px(img, 30, 30))
}

// What is kept of a plane follows the global settings that change its pixels (text rendering, the corner shape): after one changes the
// plane is drawn again, though the caller's key is the same.
@(test)
kept_plane_follows_global_settings :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	frame_drawn :: proc(f: ^Fx) -> bool {
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		drawn := draw.push_plane(&f.dc, {{0, 0}, {60, 60}}, 1, draw.Plane_Fx{cache_id = 7, cache_key = 1234})
		if drawn { draw.rect(&f.dc, {{0, 0}, {60, 60}}, RED, 10) }
		draw.pop_plane_draw(&f.dc, draw.MAT4_IDENTITY)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		return drawn
	}
	for _ in 0 ..< 3 { frame_drawn(&f) }
	testing.expect(t, !frame_drawn(&f), "kept while nothing changes")
	render.set_corner_smoothing(&f.r, 0)
	testing.expect(t, frame_drawn(&f), "drawn again after the corner shape changed")
	frame_drawn(&f)
	testing.expect(t, !frame_drawn(&f), "kept again")
	tr := render.text_rendering(&f.r)
	tr.contrast = 0.5
	render.set_text_rendering(&f.r, tr)
	testing.expect(t, frame_drawn(&f), "drawn again after the text rendering changed")
}

// A plane laid in a frame of its own, as pop_plane gives it.
@(private = "file")
solid_plane :: proc(dc: ^draw.Context, size: [2]f32, color: draw.Color) -> draw.Plane_Layer {
	draw.push_plane(dc, {{0, 0}, {size.x, size.y}}, 1)
	draw.rect(dc, {{0, 0}, {size.x, size.y}}, color)
	return draw.pop_plane(dc)
}

@(private = "file") m_a, m_b: draw.Mat4
@(private = "file") swap_order: bool

// Two planes that cut through each other in an X (rotateY +45 and -45 about the same vertical axis): each is in front on one
// side of the line where they meet. Neither order of drawing may change the picture, and with or without perspective.
@(test)
crossing_planes_are_split :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		for persp in ([2]f32{0, 220}) {
			f: Fx
			if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
			defer { draw.destroy(&f.dc); render.destroy(&f.r) }
			m_a = turned({48, 48}, {30, 30}, persp, 45)
			m_b = turned({48, 48}, {30, 30}, persp, -45)
			imgs: [2][]u8
			for k in 0 ..< 2 {
				swap_order = k == 1
				imgs[k] = frame(&f, proc(dc: ^draw.Context) {
					a := solid_plane(dc, {60, 60}, RED)
					b := solid_plane(dc, {60, 60}, BLUE)
					items := [2]draw.Plane_Item{draw.plane_item(a, m_a), draw.plane_item(b, m_b)}
					if swap_order { items = {items[1], items[0]} }
					draw.draw_planes(dc, items[:])
				})
			}
			for k in 0 ..< 2 {
				img := imgs[k]
				// +45: the left half is nearer: red on the left of the middle line, blue on the right
				testing.expectf(t, is_red(px(img, 38, 48)) && is_red(px(img, 36, 30)) && is_red(px(img, 38, 66)), "%v d=%v order %d: left of the crossing is red: %v %v %v", space, persp, k, px(img, 38, 48), px(img, 36, 30), px(img, 38, 66))
				testing.expectf(t, is_blue(px(img, 58, 48)) && is_blue(px(img, 60, 30)) && is_blue(px(img, 58, 66)), "%v d=%v order %d: right of the crossing is blue: %v %v %v", space, persp, k, px(img, 58, 48), px(img, 60, 30), px(img, 58, 66))
				testing.expectf(t, is_white(px(img, 4, 48)) && is_white(px(img, 92, 48)), "%v d=%v order %d: outside is clear", space, persp, k)
			}
			worst := 0
			for i in 0 ..< len(imgs[0]) { worst = max(worst, abs(int(imgs[0][i]) - int(imgs[1][i]))) }
			testing.expectf(t, worst <= 2, "%v d=%v: the order of the planes changes the picture by up to %d levels", space, persp, worst)
		}
	}
}

@(private = "file") star: [3]draw.Mat4

@(private = "file")
tilted :: proc(c: [2]f32, hs: [2]f32, axis_deg, tilt_deg: f32) -> draw.Mat4 {
	rad :: proc(d: f32) -> f32 { return d * math.PI / 180 }
	rz :: proc(a: f32) -> draw.Mat4 { return {math.cos(a), math.sin(a), 0, 0, -math.sin(a), math.cos(a), 0, 0, 0, 0, 1, 0, 0, 0, 0, 1} }
	rx :: proc(a: f32) -> draw.Mat4 { return {1, 0, 0, 0, 0, math.cos(a), math.sin(a), 0, 0, -math.sin(a), math.cos(a), 0, 0, 0, 0, 1} }
	t0 := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -hs.x, -hs.y, 0, 1}
	t1 := draw.Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, c.x, c.y, 0, 1}
	r := draw.mat4_mul(rz(rad(axis_deg)), draw.mat4_mul(rx(rad(tilt_deg)), draw.mat4_mul(rz(rad(-axis_deg)), t0)))
	return draw.mat4_mul(t1, r)
}

// Three planes through one point, tilted about axes 60 degrees apart (a star): six sectors, each showing the plane that is
// nearest there. Every sample is compared with the depth worked out from the matrices.
@(test)
three_planes_in_a_star :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	star = {tilted({48, 48}, {30, 30}, 0, 35), tilted({48, 48}, {30, 30}, 60, 35), tilted({48, 48}, {30, 30}, 120, 35)}
	img := frame(&f, proc(dc: ^draw.Context) {
		a := solid_plane(dc, {60, 60}, RED)
		b := solid_plane(dc, {60, 60}, draw.Color{0, 1, 0, 1})
		c := solid_plane(dc, {60, 60}, BLUE)
		items := [3]draw.Plane_Item{draw.plane_item(a, star[0]), draw.plane_item(b, star[1]), draw.plane_item(c, star[2])}
		draw.draw_planes(dc, items[:])
	})
	checked, bad := 0, 0
	for y := 14; y < 84; y += 3 {
		for x := 14; x < 84; x += 3 {
			// depth of each plane at this pixel (orthographic: the 2x2 part of the matrix maps the frame to the screen)
			best, second := -f32(1e9), -f32(1e9)
			who := -1
			margin := f32(1e9)
			for i in 0 ..< 3 {
				m := star[i]
				det := m[0] * m[5] - m[4] * m[1]
				dx, dy := f32(x) + 0.5 - m[12], f32(y) + 0.5 - m[13]
				u := (dx * m[5] - dy * m[4]) / det
				v := (m[0] * dy - m[1] * dx) / det
				mg := min(min(u, 60 - u), min(v, 60 - v))
				if abs(mg) < 2.5 { margin = 0 }   // near an edge of any plane: its antialiasing mixes in
				if mg < 0 { continue }
				z := m[2] * u + m[6] * v + m[14]
				if z > best { second = best; best = z; who = i } else if z > second { second = z }
			}
			if who < 0 || best - second < 2.5 || margin < 1 { continue }
			// a pixel where the best plane is alone is checked too; near the edge of the others it is not
			checked += 1
			p := px(img, x, y)
			want: [3]int = who == 0 ? {255, 0, 0} : (who == 1 ? {0, 255, 0} : {0, 0, 255})
			if abs(p[0] - want[0]) > 10 || abs(p[1] - want[1]) > 10 || abs(p[2] - want[2]) > 10 {
				bad += 1
			}
		}
	}
	testing.expectf(t, checked > 150, "enough samples (%d)", checked)
	testing.expectf(t, bad == 0, "%d of %d samples show the wrong plane", bad, checked)
}

// Planes are not recorded in pictures: push_plane says there is nothing to draw, what is drawn anyway goes nowhere, and replaying the
// picture shows nothing of the plane (it used to be recorded flat, unprojected, where the plane frame says).
@(test)
plane_is_not_recorded_in_a_picture :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	pic: draw.Picture
	defer draw.picture_destroy(&f.dc, &pic)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.picture_begin(&f.dc, &pic)
	drawn := draw.push_plane(&f.dc, {{0, 0}, {20, 20}}, 1)
	draw.rect(&f.dc, {{0, 0}, {20, 20}}, RED)
	pl := draw.pop_plane(&f.dc)
	draw.draw_plane(&f.dc, pl, draw.mat4_from_affine(draw.affine_translate({30, 30})))
	draw.rect(&f.dc, {{40, 0}, {60, 20}}, BLUE)   // the picture still records what is not a plane
	draw.picture_end(&f.dc)
	testing.expect(t, !drawn, "push_plane says there is nothing to draw")
	draw.replay(&f.dc, &pic, draw.affine_translate({0, 0}))
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	img := render.read_pixels(&f.r, context.temp_allocator)
	testing.expectf(t, is_white(px(img, 10, 10)) && is_white(px(img, 40, 40)), "no plane content: %v %v", px(img, 10, 10), px(img, 40, 40))
	testing.expectf(t, is_blue(px(img, 50, 10)), "the rest of the picture: %v", px(img, 50, 10))
}

@(private = "file") ring: [9]draw.Mat4
@(private = "file") ring_size: [9][2]f32
@(private = "file") ring_color: [9]draw.Color

// A big plane flat on the screen, and eight tilted ones around its middle, each crossing it along one side of an octagon: the piece
// of the big plane inside the octagon is bounded by eight cuts (more than a draw can test per pixel). Every sample is compared
// with the depth worked out from the matrices.
@(test)
many_cuts_bound_one_piece :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	ring[8] = draw.mat4_from_affine(draw.affine_translate({0, 0}))   // last: the splitters are looked for among the first eight
	ring_size[8] = {96, 96}
	ring_color[8] = draw.Color{1, 1, 0, 1}
	colors := [8]draw.Color{{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {0, 1, 1, 1}, {1, 0, 1, 1}, {0, 0, 0, 1}, {1, 0.5, 0, 1}, {0.5, 0, 0.5, 1}}
	for i in 0 ..< 8 {
		a := f32(i) * 45
		rad := a * math.PI / 180
		c := [2]f32{48 + 24 * math.cos(rad), 48 + 24 * math.sin(rad)}
		ring[i] = tilted(c, {20, 14}, a + 90, -40)
		ring_size[i] = {40, 28}
		ring_color[i] = colors[i]
	}
	img := frame(&f, proc(dc: ^draw.Context) {
		items: [9]draw.Plane_Item
		for i in 0 ..< 9 {
			items[i] = draw.plane_item(solid_plane(dc, ring_size[i], ring_color[i]), ring[i])
		}
		draw.draw_planes(dc, items[:])
	})
	checked, bad := 0, 0
	for y := 4; y < 92; y += 2 {
		for x := 4; x < 92; x += 2 {
			best, second := -f32(1e9), -f32(1e9)
			who := -1
			near_edge := false
			for i in 0 ..< 9 {
				m := ring[i]
				det := m[0] * m[5] - m[4] * m[1]
				dx, dy := f32(x) + 0.5 - m[12], f32(y) + 0.5 - m[13]
				u := (dx * m[5] - dy * m[4]) / det
				v := (m[0] * dy - m[1] * dx) / det
				mg := min(min(u, ring_size[i].x - u), min(v, ring_size[i].y - v))
				if abs(mg) < 2.5 { near_edge = true }
				if mg < 0 { continue }
				z := m[2] * u + m[6] * v + m[14]
				if z > best { second = best; best = z; who = i } else if z > second { second = z }
			}
			if who < 0 || best - second < 2.5 || near_edge { continue }
			checked += 1
			p := px(img, x, y)
			want := ring_color[who]
			lvl :: proc(v: f32) -> int { return v == 0.5 ? 188 : int(v * 255 + 0.5) }   // the colors are linear: half is 188 in sRGB
			if abs(p[0] - lvl(want.r)) > 10 || abs(p[1] - lvl(want.g)) > 10 || abs(p[2] - lvl(want.b)) > 10 { bad += 1 }
		}
	}
	testing.expectf(t, checked > 400, "enough samples (%d)", checked)
	testing.expectf(t, bad == 0, "%d of %d samples show the wrong plane", bad, checked)
}

@(private = "file")
stripes :: proc(dc: ^draw.Context) {
	for i in 0 ..< 24 {
		if i % 2 == 0 { draw.rect(dc, {{f32(i * 4), 0}, {f32(i * 4 + 4), 96}}, draw.Color{0, 0, 0, 1}) }
	}
}

// mix-blend-mode on a plane: a plane under a translation blends as the same rect in an ordinary layer does.
@(test)
blend_on_a_flat_plane_equals_blend_on_a_layer :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		plane := frame(&f, proc(dc: ^draw.Context) {
			stripes(dc)
			draw.rect(dc, {{0, 40}, {96, 60}}, RED)
			draw.push_plane(dc, {{0, 0}, {60, 60}}, 1)
			draw.rect(dc, {{0, 0}, {60, 60}}, draw.Color{0.5, 0.5, 0.5, 1})
			draw.pop_plane_draw(dc, draw.mat4_from_affine(draw.affine_translate({10, 20})), 1, draw.Plane_Draw{blend = .Multiply})
		})
		layer := frame(&f, proc(dc: ^draw.Context) {
			stripes(dc)
			draw.rect(dc, {{0, 40}, {96, 60}}, RED)
			draw.push_transform(dc, draw.affine_translate({10, 20}))
			draw.push_effects(dc, {{0, 0}, {60, 60}}, draw.Layer_Effects{alpha = 1, blend = .Multiply})
			draw.rect(dc, {{0, 0}, {60, 60}}, draw.Color{0.5, 0.5, 0.5, 1})
			draw.pop_layer(dc)
			draw.pop_transform(dc)
		})
		worst := 0
		for i in 0 ..< len(layer) { worst = max(worst, abs(int(layer[i]) - int(plane[i]))) }
		testing.expectf(t, worst <= 4, "%v: a blended plane differs from a blended layer by up to %d levels", space, worst)
		// and it did blend: over a black stripe stays black, over the red band the green and blue stay 0
		testing.expectf(t, px(plane, 42, 30)[0] < 6 && px(plane, 22, 30)[0] > 150 && px(plane, 22, 30)[0] < 230, "%v: multiply took the stripes: %v %v", space, px(plane, 22, 30), px(plane, 42, 30))
	}
}

// mix-blend-mode on a plane turned in perspective: the quad blends with what lies under it, and only there.
@(test)
blend_on_a_turned_plane :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	@(static) mm: draw.Mat4
	mm = turned({48, 48}, {30, 30}, 200, 45)
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.rect(dc, {{0, 0}, {48, 96}}, draw.Color{1, 0, 0, 1})
		draw.rect(dc, {{48, 0}, {96, 96}}, draw.Color{0, 1, 0, 1})
		draw.push_plane(dc, {{0, 0}, {60, 60}}, 1)
		draw.rect(dc, {{0, 0}, {60, 60}}, draw.Color{0.5, 0.5, 0.5, 1})
		draw.pop_plane_draw(dc, mm, 1, draw.Plane_Draw{blend = .Multiply})
	})
	l, r := px(img, 40, 48), px(img, 56, 48)
	testing.expectf(t, l[0] > 100 && l[1] < 6 && l[2] < 6, "multiply over red keeps only red: %v", l)
	testing.expectf(t, r[1] > 100 && r[0] < 6 && r[2] < 6, "multiply over green keeps only green: %v", r)
	testing.expectf(t, px(img, 4, 48)[0] > 250 && px(img, 90, 48)[1] > 250, "outside the quad nothing changed: %v %v", px(img, 4, 48), px(img, 90, 48))
}

// backdrop-filter on a turned plane: what lies under the projected quad is blurred, through the plane's silhouette only.
@(test)
backdrop_filter_on_a_turned_plane :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		@(static) mm: draw.Mat4
		mm = turned({48, 48}, {30, 30}, 400, 35)
		img := frame(&f, proc(dc: ^draw.Context) {
			stripes(dc)
			content := draw.push_plane(dc, {{0, 0}, {60, 60}}, 1)
			_ = content
			pl := draw.pop_plane(dc)   // nothing in it: a glass pane
			shape := solid_plane(dc, {30, 60}, draw.Color{1, 1, 1, 1})   // the left half of the pane
			draw.draw_plane(dc, pl, mm, 1, draw.Plane_Draw{backdrop = []draw.Filter{draw.filter_blur(5)}, shape = shape})
		})
		// stripes are 4 px, black and white: far from the pane they alternate; blurred they become one gray
		a, b := px(img, 6, 48), px(img, 10, 48)
		testing.expectf(t, abs(a[0] - b[0]) > 200, "%v: outside the pane the stripes stay: %v %v", space, a, b)
		// the left half of the pane (x < the projected middle): blurred
		mx := int(project(mm, {30, 30}).x)
		lo, hi := 255, 0
		for x in mx - 14 ..< mx - 5 {
			v := px(img, x, 48)[0]
			lo, hi = min(lo, v), max(hi, v)
		}
		testing.expectf(t, hi - lo < 90, "%v: the left half of the pane is blurred: levels %d..%d", space, lo, hi)
		lo, hi = 255, 0
		for x in mx + 6 ..< mx + 14 {
			v := px(img, x, 48)[0]
			lo, hi = min(lo, v), max(hi, v)
		}
		testing.expectf(t, hi - lo > 200, "%v: the right half (outside the silhouette) keeps its stripes: levels %d..%d", space, lo, hi)
	}
}

@(private = "file") minify_mips: bool

@(private = "file")
minified_stripes :: proc(f: ^Fx, mips: bool) -> []u8 {
	minify_mips = mips
	return frame(f, proc(dc: ^draw.Context) {
		draw.push_plane(dc, {{0, 0}, {64, 64}}, 1, draw.Plane_Fx{mips = minify_mips})
		for y := 0; y < 64; y += 2 { draw.rect(dc, {{0, f32(y)}, {64, f32(y + 1)}}, draw.Color{0, 0, 0, 1}) }
		draw.pop_plane_draw(dc, draw.mat4_from_affine(draw.Affine{a = 0.25, d = 0.25, e = 20, f = 20.375}))
	})
}

// A plane brought far smaller than its layer (a receding plane): lines one texel wide average to gray with mip levels; read
// at level 0 they alias (each pixel lands on a black or a white line).
@(test)
minified_plane_is_filtered_by_its_mips :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	with := minified_stripes(&f, true)
	without := minified_stripes(&f, false)
	lo, hi := 255, 0
	for y in 23 ..< 33 { for x in 23 ..< 33 { v := px(with, x, y)[0]; lo, hi = min(lo, v), max(hi, v) } }
	testing.expectf(t, hi - lo <= 40 && lo > 90 && hi < 170, "with mips the stripes average to gray: %d..%d", lo, hi)
	sum := 0
	for y in 23 ..< 33 { for x in 23 ..< 33 { sum += px(without, x, y)[0] } }
	testing.expectf(t, abs(sum / 100 - 128) > 60, "without them the lines alias (every pixel lands on a line: mean %d)", sum / 100)
}
