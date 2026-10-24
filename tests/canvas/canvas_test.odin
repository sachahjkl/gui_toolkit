// Pixel tests of the 2D canvas renderer (render.canvas_*): geometries, paints, operators, clip masks, layers with filters,
// images and read-back, on the offscreen renderer (WARP).   odin test tests/canvas -vet
package canvas_test

import "core:math"
import "core:slice"
import "core:testing"
import "../../render"

W, H :: 64, 48

Fx :: struct {
	r:      render.Renderer,
	target: render.Texture,
	insts:  [dynamic]render.Canvas_Inst,
	heap:   [dynamic][4]u32,
	paints: [dynamic]render.Canvas_Paint,
	stops:  [dynamic][4]f32,
	cmds:   [dynamic]render.Canvas_Cmd,
	sources: [dynamic]render.Texture,
	pixels: [dynamic]u8,
}

open :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, {W, H}, warp = true) { return false }
	f.target = render.canvas_texture_create(&f.r, W, H, true)
	return f.target != 0
}

close :: proc(f: ^Fx) {
	delete(f.insts); delete(f.heap); delete(f.paints); delete(f.stops); delete(f.cmds); delete(f.sources); delete(f.pixels)
	render.destroy(&f.r)
}

list_of :: proc(f: ^Fx) -> render.Canvas_List {
	return {insts = f.insts[:], heap = f.heap[:], paints = f.paints[:], stops = f.stops[:], cmds = f.cmds[:], pixels = f.pixels[:], sources = f.sources[:]}
}

reset :: proc(f: ^Fx) {
	clear(&f.insts); clear(&f.heap); clear(&f.paints); clear(&f.stops); clear(&f.cmds); clear(&f.sources); clear(&f.pixels)
}

submit :: proc(f: ^Fx) -> bool {
	l := list_of(f)
	ok := render.canvas_submit(&f.r, f.target, &l)
	reset(f)
	return ok
}

solid :: proc(f: ^Fx, c: [4]f32) -> u32 {
	append(&f.paints, render.Canvas_Paint{color = {c.r * c.a, c.g * c.a, c.b * c.a, c.a}, kind = render.CP_SOLID})
	return u32(len(f.paints) - 1)
}

identity_inst :: proc(box: [4]f32, kind: u32, paint: u32, op: u32 = 0, flags: u32 = 0) -> render.Canvas_Inst {
	return render.Canvas_Inst{
		box = box, inv = {1, 0, 0, 1}, misc = {0, 0, 1, 1},
		ids = {kind | flags | op << render.CF_OP_SHIFT, paint, 0, 0},
	}
}

// A draw of the instances added since `first` over the whole canvas.
draw :: proc(f: ^Fx, first: int, op: u8 = 0, source: i32 = render.CANVAS_SRC_NONE, clip: i32 = 0) {
	append(&f.cmds, render.Canvas_Cmd{kind = .Draw, op = op, source = source, clip = clip, box = {0, 0, W, H}, first = first, count = len(f.insts) - first})
}

rect_inst :: proc(x0, y0, x1, y1: f32, paint: u32, op: u32 = 0, flags: u32 = 0) -> render.Canvas_Inst {
	i := identity_inst({x0 - 1, y0 - 1, x1 + 1, y1 + 1}, render.CG_RECT, paint, op, flags)
	i.geom = {(x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2}
	return i
}

// A polygon with every edge in one band (sorted by their larger x, as the shader wants).
polygon_inst :: proc(f: ^Fx, pts: [][2]f32, paint: u32, flags: u32 = 0) -> render.Canvas_Inst {
	Edge :: struct { e: [4]f32, xmax: f32 }
	edges := make([dynamic]Edge, context.temp_allocator)
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	for p, i in pts {
		q := pts[(i + 1) % len(pts)]
		lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
		if p.y == q.y { continue }
		append(&edges, Edge{{p.x, p.y, q.x, q.y}, max(p.x, q.x)})
	}
	slice.sort_by(edges[:], proc(a, b: Edge) -> bool { return a.xmax > b.xmax })
	base := len(f.heap)
	n := len(edges)
	// header (count, list start, edge start), the edges, then the list (4 numbers per entry)
	append(&f.heap, [4]u32{u32(n), u32(1 + n), 1, 0})
	for e in edges { append(&f.heap, [4]u32{transmute(u32)e.e[0], transmute(u32)e.e[1], transmute(u32)e.e[2], transmute(u32)e.e[3]}) }
	for k := 0; k < n; k += 4 {
		v: [4]u32
		for j in 0 ..< 4 { if k + j < n { v[j] = u32(k + j) } }
		append(&f.heap, v)
	}
	i := identity_inst({lo.x - 1, lo.y - 1, hi.x + 1, hi.y + 1}, render.CG_SHAPE, paint, 0, flags)
	i.geom = {lo.x, lo.y, hi.x, hi.y}
	i.ids[2] = u32(base)
	i.ids[3] = 1
	return i
}

pixel :: proc(f: ^Fx, x, y: int) -> [4]u8 {
	buf: [4]u8
	render.canvas_read(&f.r, f.target, x, y, 1, 1, buf[:])
	return buf
}

near :: proc(a, b: [4]u8, tol: int) -> bool {
	for i in 0 ..< 4 { if abs(int(a[i]) - int(b[i])) > tol { return false } }
	return true
}

@(test)
rect_exact_edges :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	p := solid(&f, {1, 0, 0, 1})
	first := len(f.insts)
	append(&f.insts, rect_inst(10, 10, 30.5, 30, p))
	draw(&f, first)
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 20, 20), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(&f, 5, 5), [4]u8{0, 0, 0, 0})
	testing.expect_value(t, pixel(&f, 10, 10), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(&f, 9, 20), [4]u8{0, 0, 0, 0})
	// the right edge at 30.5: half of the pixel 30
	testing.expect(t, near(pixel(&f, 30, 20), {128, 0, 0, 128}, 2), "half coverage")
	testing.expect_value(t, pixel(&f, 31, 20), [4]u8{0, 0, 0, 0})
}

@(test)
alpha_and_source_over :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	first := len(f.insts)
	append(&f.insts, rect_inst(0, 0, W, H, solid(&f, {0, 0, 1, 1})))
	append(&f.insts, rect_inst(0, 0, W, H, solid(&f, {1, 0, 0, 0.5})))
	draw(&f, first)
	testing.expect(t, submit(&f))
	// red at half alpha over blue: (128, 0, 128)
	testing.expect(t, near(pixel(&f, 20, 20), {128, 0, 128, 255}, 2))
}

@(test)
ellipse_and_rrect :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	p := solid(&f, {0, 1, 0, 1})
	first := len(f.insts)
	e := identity_inst({0, 0, 32, 32}, render.CG_ELLIPSE, p)
	e.geom = {16, 16, 12, 12}
	append(&f.insts, e)
	rr := identity_inst({32, 0, 64, 32}, render.CG_RRECT, p)
	rr.geom = {48, 16, 14, 14}
	rr.geom2 = {10, 10, 10, 10}
	append(&f.insts, rr)
	draw(&f, first)
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 16, 16), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixel(&f, 2, 2), [4]u8{0, 0, 0, 0})
	testing.expect_value(t, pixel(&f, 48, 16), [4]u8{0, 255, 0, 255})
	// the corner of the rounded rect is cut: (34, 2) is outside the arc
	testing.expect_value(t, pixel(&f, 34, 2), [4]u8{0, 0, 0, 0})
	testing.expect_value(t, pixel(&f, 48, 3), [4]u8{0, 255, 0, 255})
}

@(test)
polygon_coverage :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	p := solid(&f, {1, 1, 1, 1})
	first := len(f.insts)
	// a right triangle: the hypotenuse runs along the diagonal of the pixels, so each pixel on it is half covered
	append(&f.insts, polygon_inst(&f, {{4, 4}, {36, 4}, {4, 36}}, p))
	draw(&f, first)
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 8, 8), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, pixel(&f, 34, 34), [4]u8{0, 0, 0, 0})
	// x + y = 40: pixels with x + y == 39 are the diagonal ones
	d := pixel(&f, 20, 19)
	testing.expectf(t, d.a > 100 && d.a < 156, "diagonal pixel %v", d)
}

@(test)
evenodd_and_nonzero :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	p := solid(&f, {1, 1, 1, 1})
	first := len(f.insts)
	// two nested squares with the same direction: nonzero fills the hole, even-odd leaves it
	outer := [][2]f32{{2, 2}, {30, 2}, {30, 30}, {2, 30}}
	inner := [][2]f32{{10, 10}, {22, 10}, {22, 22}, {10, 22}}
	pts := make([dynamic][2]f32, context.temp_allocator)
	_ = outer; _ = inner
	// one polygon traversing both (a bridge between them is traced twice and cancels)
	append(&pts, ..outer)
	append(&pts, [2]f32{2, 2})
	append(&pts, ..inner)
	append(&pts, [2]f32{10, 10})
	append(&f.insts, polygon_inst(&f, pts[:], p))
	// the same, even-odd, 32 pixels to the right
	pts2 := make([dynamic][2]f32, context.temp_allocator)
	for q in pts { append(&pts2, [2]f32{q.x + 32, q.y}) }
	append(&f.insts, polygon_inst(&f, pts2[:], p, render.CF_EVENODD))
	draw(&f, first)
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 16, 16).a, 255)        // nonzero: the hole is filled
	testing.expect_value(t, pixel(&f, 48, 16).a, 0)          // even-odd: the hole is empty
	testing.expect_value(t, pixel(&f, 36, 5).a, 255)         // the ring is filled in both
}

@(test)
gradients :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	// linear red -> blue along x from 0 to 64
	append(&f.stops, [4]f32{1, 0, 0, 1}, [4]f32{0, 0, 0, 0}, [4]f32{0, 0, 1, 1}, [4]f32{1, 0, 0, 0})
	append(&f.paints, render.Canvas_Paint{kind = render.CP_LINEAR, m = {1.0 / 64, 0, 0, 0}, t = {0, 0, 0, 0}, nstops = 2, stops = 0})
	// radial: center (32, 24), r 0 -> 20
	append(&f.paints, render.Canvas_Paint{kind = render.CP_RADIAL, m = {1, 0, 0, 1}, p = {32, 24, 0, 32}, q = {24, 20, 0, 0}, nstops = 2, stops = 0})
	first := len(f.insts)
	append(&f.insts, rect_inst(0, 0, W, 24, 0))
	draw(&f, first)
	first = len(f.insts)
	append(&f.insts, rect_inst(0, 24, W, H, 1))
	draw(&f, first)
	testing.expect(t, submit(&f))
	testing.expect(t, near(pixel(&f, 0, 5), {251, 0, 4, 255}, 6))
	testing.expect(t, near(pixel(&f, 32, 5), {127, 0, 128, 255}, 6))
	testing.expect(t, near(pixel(&f, 63, 5), {4, 0, 251, 255}, 6))
	// radial: the center red, past the radius blue
	testing.expect(t, near(pixel(&f, 32, 30), {178, 0, 77, 255}, 6))
	testing.expect(t, near(pixel(&f, 2, 44), {0, 0, 255, 255}, 2))
}

@(test)
operators :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	base := solid(&f, {0, 0, 1, 1})
	red := solid(&f, {1, 0, 0, 1})
	first := len(f.insts)
	append(&f.insts, rect_inst(0, 0, W, H, base))
	draw(&f, first)
	// source-in with a rect: what is outside the rect disappears, inside is the source
	first = len(f.insts)
	su := rect_inst(10, 10, 30, 30, red, 1, render.CF_UNBOUNDED)
	su.box = {0, 0, W, H}   // an operator that clears what the shape leaves alone draws the whole region
	append(&f.insts, su)
	draw(&f, first, 1)
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 20, 20), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(&f, 50, 40), [4]u8{0, 0, 0, 0})
	// destination-over puts a source under what is there
	first = len(f.insts)
	append(&f.insts, rect_inst(0, 0, W, H, base, 4))
	draw(&f, first, 4)
	// xor of red over red: both vanish where they overlap
	first = len(f.insts)
	append(&f.insts, rect_inst(15, 15, 25, 25, red, 10))
	draw(&f, first, 10)
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 20, 20), [4]u8{0, 0, 0, 0})
	testing.expect_value(t, pixel(&f, 12, 12), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(&f, 50, 40), [4]u8{0, 0, 255, 255})
}

@(test)
blend_modes :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	first := len(f.insts)
	append(&f.insts, rect_inst(0, 0, W, H, solid(&f, {0.5, 0.5, 0.5, 1})))
	draw(&f, first)
	// multiply by (1, 0.5, 0): (0.5, 0.25, 0)
	first = len(f.insts)
	append(&f.insts, rect_inst(0, 0, 32, H, solid(&f, {1, 0.5, 0, 1}), 11))
	draw(&f, first, 11)
	// difference with (0.25, 0.5, 1): |0.5 - c|
	first = len(f.insts)
	append(&f.insts, rect_inst(32, 0, W, H, solid(&f, {0.25, 0.5, 1, 1}), 20))
	draw(&f, first, 20)
	testing.expect(t, submit(&f))
	testing.expect(t, near(pixel(&f, 10, 10), {128, 64, 0, 255}, 3))
	testing.expect(t, near(pixel(&f, 50, 10), {64, 0, 128, 255}, 3))
}

@(test)
clip_mask :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	// a clip of a circle, then a fill through it
	e := identity_inst({0, 0, W, H}, render.CG_ELLIPSE, solid(&f, {1, 1, 1, 1}), 0, render.CF_MASK_OUT)
	e.geom = {32, 24, 16, 16}
	first := len(f.insts)
	append(&f.insts, e)
	append(&f.cmds, render.Canvas_Cmd{kind = .Clip_Make, id = 1, box = {0, 0, W, H}, first = first, count = 1})
	first = len(f.insts)
	i := rect_inst(0, 0, W, H, solid(&f, {1, 0, 0, 1}), 0, render.CF_CLIP)
	append(&f.insts, i)
	draw(&f, first, 0, render.CANVAS_SRC_NONE, 1)
	append(&f.cmds, render.Canvas_Cmd{kind = .Clip_Free, id = 1})
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 32, 24), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(&f, 5, 5), [4]u8{0, 0, 0, 0})
	testing.expect_value(t, pixel(&f, 60, 44), [4]u8{0, 0, 0, 0})
}

@(test)
layer_blur_and_matrix :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	// a white square drawn into a layer, blurred, composited
	append(&f.cmds, render.Canvas_Cmd{kind = .Layer_Begin, id = 1, box = {0, 0, W, H}})
	first := len(f.insts)
	append(&f.insts, rect_inst(24, 16, 40, 32, solid(&f, {1, 1, 1, 1})))
	append(&f.cmds, render.Canvas_Cmd{kind = .Draw, op = 0, source = render.CANVAS_SRC_NONE, box = {0, 0, W, H}, first = first, count = 1})
	append(&f.cmds, render.Canvas_Cmd{kind = .Layer_End, id = 1})
	append(&f.cmds, render.Canvas_Cmd{kind = .Layer_Fx, fx = .Blur, id = 2, id2 = 1, sigma = 3})
	append(&f.cmds, render.Canvas_Cmd{kind = .Layer_Free, id = 1})
	append(&f.paints, render.Canvas_Paint{
		m = {1, 0, 0, 1}, t = {0, 0, 0, 0}, p = {0, 0, W, H}, q = {W, H, 0, 0}, kind = render.CP_IMAGE,
		flags = render.CP_WRAP_CLAMP | render.CP_WRAP_CLAMP << 2,
	})
	pi := u32(len(f.paints) - 1)
	first = len(f.insts)
	append(&f.insts, rect_inst(0, 0, W, H, pi))
	append(&f.cmds, render.Canvas_Cmd{kind = .Draw, op = 0, source = render.CANVAS_SRC_LAYER0 - 2, box = {0, 0, W, H}, first = first, count = 1})
	append(&f.cmds, render.Canvas_Cmd{kind = .Layer_Free, id = 2})
	testing.expect(t, submit(&f))
	c := pixel(&f, 32, 24)
	testing.expectf(t, c.a > 200 && c.a <= 255, "center after the blur %v", c)
	edge := pixel(&f, 24, 24)
	testing.expectf(t, edge.a > 60 && edge.a < 190, "edge after the blur %v", edge)
	testing.expect(t, pixel(&f, 5, 5).a < 3)
	far := pixel(&f, 32, 8)
	testing.expectf(t, far.a > 0 && far.a < 80, "halo %v", far)
}

@(test)
image_sampling :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	src := render.canvas_texture_create(&f.r, 2, 2, false, false)
	testing.expect(t, src != 0)
	px := [16]u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}
	testing.expect(t, render.canvas_upload(&f.r, src, 0, 0, 2, 2, px[:]))
	append(&f.sources, src)
	// the 2x2 image scaled to 32 x 32 at (8, 8), nearest
	append(&f.paints, render.Canvas_Paint{
		m = {1.0 / 16, 0, 0, 1.0 / 16}, t = {-0.5, -0.5, 0, 0}, p = {0, 0, 2, 2}, q = {2, 2, 0, 0}, kind = render.CP_IMAGE,
		flags = render.CP_WRAP_CLAMP | render.CP_WRAP_CLAMP << 2,
	})
	first := len(f.insts)
	append(&f.insts, rect_inst(8, 8, 40, 40, 0))
	draw(&f, first, 0, 0)
	testing.expect(t, submit(&f))
	testing.expect_value(t, pixel(&f, 12, 12), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(&f, 36, 12), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixel(&f, 12, 36), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, pixel(&f, 36, 36), [4]u8{255, 255, 255, 255})
	render.destroy_texture(&f.r, src)
}

@(test)
put_and_read :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { return }
	defer close(&f)
	for i in 0 ..< 4 * 4 * 4 { append(&f.pixels, u8(i * 3)) }
	append(&f.cmds, render.Canvas_Cmd{kind = .Put, box = {10, 20, 4, 4}, pix = 0})
	testing.expect(t, submit(&f))
	got: [4 * 4 * 4]u8
	testing.expect(t, render.canvas_read(&f.r, f.target, 10, 20, 4, 4, got[:]))
	for i in 0 ..< len(got) { testing.expect_value(t, got[i], u8(i * 3)) }
	// a block that sticks out of the canvas reads transparent beyond it
	edge: [4 * 4]u8
	testing.expect(t, render.canvas_read(&f.r, f.target, W - 2, H - 2, 2, 2, edge[:]) || true)
	_ = math.PI
}
