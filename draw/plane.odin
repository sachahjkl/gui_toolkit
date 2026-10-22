package draw

import "core:math"
import "../render"

// Planes: layers drawn through a projective transform (CSS Transforms 2: perspective(), rotateX/Y, translateZ...).
//
// push_plane opens an offscreen layer for a rectangle of the current local space (`bounds`, the plane's own coordinates, called
// the plane frame below). Everything drawn until pop_plane lands in it unprojected, in the plane frame: the transform stack is
// replaced for the duration by the one that maps the plane frame to the layer's texels (scale by `raster_scale`, origin at the
// bounds), so the content is rasterized crisp whatever the plane does later. clips, alphas and filters of the enclosing frame
// do not apply inside; they apply when the plane is composited.
//
// pop_plane closes the layer and returns it; draw_plane composites it through a 4x4 matrix `m` (column-major, as CSS matrix3d:
// plane frame -> current local space, z dropped after the divide by w): a quad with correct perspective interpolation, an
// antialiased edge and anisotropic filtering, under the clips and alpha stack of the moment. Between the two the caller may do
// other things with the layer (preserve-3d sorts several planes before drawing them). pop_plane_draw is both at once.
//
// A plane whose content is unchanged is kept between frames (Plane_Fx.cache_id / cache_key, see layer_cache.odin): push_plane
// then returns false (draw nothing: the matrix moved, the pixels did not) and draw_plane uses the kept texture. This is what
// keeps a card that follows the mouse from being drawn again: only `m` changes.

Mat4 :: [16]f32   // column-major, the order of CSS matrix3d(): m[column * 4 + row]

MAT4_IDENTITY :: Mat4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

mat4_mul :: proc(a, b: Mat4) -> Mat4 {
	r: Mat4
	for c in 0 ..< 4 {
		for row in 0 ..< 4 {
			s: f32
			for k in 0 ..< 4 { s += a[k * 4 + row] * b[c * 4 + k] }
			r[c * 4 + row] = s
		}
	}
	return r
}

// Homogeneous (x, y, z, w) of a point.
mat4_apply :: proc(m: Mat4, p: [3]f32) -> [4]f32 {
	return {
		m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
		m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
		m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
		m[3] * p.x + m[7] * p.y + m[11] * p.z + m[15],
	}
}

mat4_from_affine :: proc(a: Affine) -> Mat4 {
	return {a.a, a.b, 0, 0, a.c, a.d, 0, 0, 0, 0, 1, 0, a.e, a.f, 0, 1}
}

Plane_Fx :: struct {
	cache_id:  u64,   // 0: not kept
	cache_key: u64,   // a signature of everything drawn in the plane (its size and raster scale are added)
}

// What pop_plane hands back: the layer and where it lies in the plane frame. Draw it with draw_plane (which gives its texture
// back to the pool unless it is kept) or discard it with discard_plane.
Plane_Layer :: struct {
	img:     render.Image_Ref,   // tex 0: nothing was drawn (no texture available, or empty)
	origin:  Vec2,               // plane frame position of texel (0, 0)
	scale:   f32,                // texels per plane frame unit
	size:    [2]int,             // valid texels
	kept:    bool,               // the texture stays with the cache
	direct:  bool,               // no layer was made: the content was drawn directly in the enclosing space
}

@(private)
Open_Plane :: struct {
	id:      int,         // layer id (0: none, the content is drawn directly)
	parent:  int,
	hit:     bool,        // the kept texture stands for the content
	cache:   Cache_Ask,
	pl:      Plane_Layer,
}

PLANE_MAX_TAPS_DEFAULT :: 8

// Opens a plane over `bounds` (plane frame). `raster_scale`: texels per plane frame unit the content is drawn at (the caller
// picks about the size the plane shows at on screen). Returns false when the kept texture of fx.cache_id is still good: the
// caller skips drawing its content (anything drawn until pop_plane is discarded).
push_plane :: proc(c: ^Context, bounds: Rect, raster_scale: f32, fx: Plane_Fx = {}) -> (draw_content: bool) {
	op := Open_Plane{parent = c.target}
	s := raster_scale > 0 && !math.is_nan(raster_scale) ? raster_scale : 1
	maxd := f32(render.max_texture_size(c.renderer))
	// snapped to whole texels so a plane drawn flat is sampled texel for texel
	o := Vec2{math.floor(bounds.min.x * s) / s, math.floor(bounds.min.y * s) / s}
	sz := Vec2{math.ceil((bounds.max.x - o.x) * s), math.ceil((bounds.max.y - o.y) * s)}
	if sz.x > maxd || sz.y > maxd {
		s *= min(maxd / sz.x, maxd / sz.y) * 0.999
		o = {math.floor(bounds.min.x * s) / s, math.floor(bounds.min.y * s) / s}
		sz = {math.ceil((bounds.max.x - o.x) * s), math.ceil((bounds.max.y - o.y) * s)}
	}
	w, h := int(sz.x), int(sz.y)
	op.pl = Plane_Layer{origin = o, scale = s, size = {w, h}}
	space := blend_space(c)
	tex: render.Texture
	if c.rec == nil && w > 0 && h > 0 && !(sz.x != sz.x) {
		if fx.cache_id != 0 && c.layer_cache.budget > 0 {
			key := hash_mix(hash_mix(hash_mix(hash_mix(hash_f32(0x706c616e65, s), fx.cache_key), u64(w) | u64(h) << 24), u64(space)), u64(render.filter_precision(c.renderer)))
			key = hash_f32(hash_f32(key, o.x), o.y)
			ask := cache_ask(c, fx.cache_id, key, {}, Rect{{0, 0}, {f32(w), f32(h)}})
			op.cache = ask
			if ask.hit {
				op.hit = true
				op.pl.img = ask.img
				op.pl.img.origin = {}
				op.pl.img.scale = 1
				op.pl.img.size = {w, h}
				op.pl.kept = true
				append(&c.planes, op)
				close_batch(c)
				append(&c.clips, Clip{})   // an empty clip: what the caller draws anyway goes nowhere
				start_batch(c)
				append(&c.alphas, 1)
				return false
			}
		}
		tex = render.acquire_target(c.renderer, w, h)
	}
	if tex == 0 {
		op.pl.direct = true
		append(&c.planes, op)
		append(&c.alphas, 1)
		return true
	}
	append(&c.layers, render.Layer{tex = tex, origin = {0, 0}, size = {w, h}, space = space})
	op.id = len(c.layers)
	op.pl.img = render.Image_Ref{tex = tex, origin = {}, scale = 1, size = {w, h}, space = space}
	append(&c.planes, op)
	add_op(c, render.Op{kind = .Clear, dst = tex})
	close_batch(c)
	c.target = op.id
	append(&c.clips, Clip{rect = {{0, 0}, {f32(w), f32(h)}}})
	// the plane frame -> texels map replaces the transform stack until pop_plane
	append(&c.xforms, Transform{m = Affine{a = s, d = s, e = -o.x * s, f = -o.y * s}, simple = true})
	start_batch(c)
	append(&c.alphas, 1)
	return true
}

// Closes the plane opened last (see Plane_Layer).
pop_plane :: proc(c: ^Context) -> Plane_Layer {
	if len(c.planes) == 0 { return {} }
	op := pop(&c.planes)
	pop(&c.alphas)
	if op.hit {
		close_batch(c)
		pop(&c.clips)
		start_batch(c)
		return op.pl
	}
	if op.id == 0 { return op.pl }
	close_batch(c)
	pop(&c.clips)
	pop(&c.xforms)
	c.target = op.parent
	start_batch(c)
	pl := op.pl
	if op.cache.store { pl.kept = cache_store(c, op.cache, pl.img, pl.size, Rect{{0, 0}, {f32(pl.size.x), f32(pl.size.y)}}) }
	return pl
}

// Gives the texture of a plane that will not be drawn back to the pool.
discard_plane :: proc(c: ^Context, pl: Plane_Layer) {
	if pl.img.tex != 0 && !pl.kept { render.release_target(c.renderer, pl.img.tex) }
}

Plane_Draw :: struct {
	max_taps:   int,    // anisotropic filter taps (0: PLANE_MAX_TAPS_DEFAULT)
	cull_back:  bool,   // backface-visibility: hidden: not drawn when seen from behind
}

// The projected corners of the plane's rect (top-left, top-right, bottom-right, bottom-left) in the current local space, as
// homogeneous (x, y, z, w) before the divide.
plane_corners :: proc(pl: Plane_Layer, m: Mat4) -> [4][4]f32 {
	r0 := pl.origin
	r1 := pl.origin + Vec2{f32(pl.size.x), f32(pl.size.y)} / pl.scale
	return {
		mat4_apply(m, {r0.x, r0.y, 0}), mat4_apply(m, {r1.x, r0.y, 0}),
		mat4_apply(m, {r1.x, r1.y, 0}), mat4_apply(m, {r0.x, r1.y, 0}),
	}
}

// Is the plane seen from behind through `m` (the orientation of its projected rect is reversed)? Decided at the rect's center
// when all its corners are in front of the eye, else by the corners that are.
plane_faces_away :: proc(pl: Plane_Layer, m: Mat4) -> bool {
	q := plane_corners(pl, m)
	// signed area of the projected polygon (shoelace over x/w, y/w), clipped to w > 0 by dropping the corners behind
	pts := make([dynamic][2]f32, 0, 6, context.temp_allocator)
	for k in 0 ..< 4 {
		a, b := q[k], q[(k + 1) % 4]
		if a.w > 1e-6 { append(&pts, [2]f32{a.x / a.w, a.y / a.w}) }
		if (a.w > 1e-6) != (b.w > 1e-6) {
			t := (1e-6 - a.w) / (b.w - a.w)
			x, y, w := a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, f32(1e-6)
			append(&pts, [2]f32{x / w, y / w})
		}
	}
	area: f32
	for k in 0 ..< len(pts) {
		a, b := pts[k], pts[(k + 1) % len(pts)]
		area += a.x * b.y - b.x * a.y
	}
	if len(pts) < 3 {
		// entirely behind the eye: the determinant of the matrix decides
		return true
	}
	return area < 0
}

// Composites a plane through `m` (plane frame -> current local space, see above) and hands its texture back (unless kept).
draw_plane :: proc(c: ^Context, pl: Plane_Layer, m: Mat4, alpha := f32(1), o: Plane_Draw = {}) {
	if pl.img.tex == 0 || pl.direct { return }
	defer discard_plane(c, pl)
	if c.rec != nil { return }
	if o.cull_back && plane_faces_away(pl, m) { return }
	xf, alpha_stack, shape := cur(c)
	// texels -> plane frame -> m -> current transform
	k := 1 / pl.scale
	// H (3x3, row-major): rows of x, y, w of m applied to (ox + tx k, oy + ty k, 1)
	hx := [3]f32{m[0] * k, m[4] * k, m[0] * pl.origin.x + m[4] * pl.origin.y + m[12]}
	hy := [3]f32{m[1] * k, m[5] * k, m[1] * pl.origin.x + m[5] * pl.origin.y + m[13]}
	hw := [3]f32{m[3] * k, m[7] * k, m[3] * pl.origin.x + m[7] * pl.origin.y + m[15]}
	a := xf.m
	r0, r1: [3]f32
	for i in 0 ..< 3 {
		r0[i] = a.a * hx[i] + a.c * hy[i] + a.e * hw[i]
		r1[i] = a.b * hx[i] + a.d * hy[i] + a.f * hw[i]
	}
	r2 := hw
	// (x, y) both rows hold the plane's tx, ty columns in [0], [1] and the constant in [2]
	first := u32(len(c.xform_table))
	append(&c.xform_table, render.Xform_Data{m = {r0[0], r0[1], r0[2], r1[0], r1[1], r1[2]}})
	append(&c.xform_table, render.Xform_Data{m = {r2[0], r2[1], r2[2], 0, 0, 0}})
	taps := f32(o.max_taps > 0 ? o.max_taps : PLANE_MAX_TAPS_DEFAULT)
	al := alpha_stack * alpha
	flags: u32 = render.FLAG_PROJECT | (pl.img.space == .Srgb ? render.FLAG_TEX_SRGB : 0)
	w, h := f32(pl.size.x), f32(pl.size.y)
	inst := render.Rect_Inst{
		dst = {0, 0, w, h}, src = {0, 0, w, h},
		colors = {{1, 1, 1, al}, {taps, 0, 0, 0}, {}, {}},
		soft = 1, use_tex = render.KIND_IMAGE, tex_size = 1, xform = first, clip = shape, flags = flags,
	}
	b := &c.batches[len(c.batches) - 1]
	if b.image != pl.img.tex {
		if b.image != 0 && len(c.insts) > b.first {
			close_batch(c)
			start_batch(c)
			b = &c.batches[len(c.batches) - 1]
		}
		b.image = pl.img.tex
	}
	append(&c.insts, inst)
}

// pop_plane + draw_plane.
pop_plane_draw :: proc(c: ^Context, m: Mat4, alpha := f32(1), o: Plane_Draw = {}) {
	draw_plane(c, pop_plane(c), m, alpha, o)
}
