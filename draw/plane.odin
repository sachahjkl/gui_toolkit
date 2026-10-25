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
	mips:      bool,  // build the layer's mip levels (minification by perspective is filtered by them); needs device support,
	                  // else the layer has none (Plane_Layer.mips says)
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
	mips:    bool,               // the texture has its mip levels (minification is filtered by them)
}

@(private)
Open_Plane :: struct {
	id:      int,         // layer id (0: none, the content is drawn directly)
	parent:  int,
	hit:     bool,        // the kept texture stands for the content
	cache:   Cache_Ask,
	pl:      Plane_Layer,
	pending0: u64,        // Context.glyphs_pending when it was opened
}

PLANE_MAX_TAPS_DEFAULT :: 8

// Opens a plane over `bounds` (plane frame). `raster_scale`: texels per plane frame unit the content is drawn at (the caller
// picks about the size the plane shows at on screen). Returns false when the kept texture of fx.cache_id is still good: the
// caller skips drawing its content (anything drawn until pop_plane is discarded).
push_plane :: proc(c: ^Context, bounds: Rect, raster_scale: f32, fx: Plane_Fx = {}) -> (draw_content: bool) {
	op := Open_Plane{parent = c.target, pending0 = c.glyphs_pending}
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
	mips := fx.mips && render.target_mips_supported(c.renderer)
	tex: render.Texture
	if c.rec != nil {
		// planes are not recorded in pictures: nothing is drawn (what the caller draws anyway goes nowhere: an empty clip) and draw_plane
		// of the result does nothing
		op.hit = true
		append(&c.planes, op)
		push_clip(c, Rect{})
		append(&c.alphas, 1)
		return false
	}
	if w > 0 && h > 0 && !(sz.x != sz.x) {
		if fx.cache_id != 0 && c.layer_cache.budget > 0 {
			key := hash_mix(hash_mix(hash_mix(hash_mix(hash_f32(0x706c616e65, s), fx.cache_key), u64(w) | u64(h) << 24), u64(space) | u64(mips) << 8), u64(render.filter_precision(c.renderer)))
			key = hash_f32(hash_f32(key, o.x), o.y)
			key = hash_mix(key, settings_key(c))
			ask := cache_ask(c, fx.cache_id, key, {}, Rect{{0, 0}, {f32(w), f32(h)}})
			op.cache = ask
			if ask.hit {
				op.hit = true
				op.pl.img = ask.img
				op.pl.img.origin = {}
				op.pl.img.scale = 1
				op.pl.img.size = {w, h}
				op.pl.kept = true
				op.pl.mips = mips
				append(&c.planes, op)
				close_batch(c)
				append(&c.clips, Clip{})   // an empty clip: what the caller draws anyway goes nowhere
				start_batch(c)
				append(&c.alphas, 1)
				return false
			}
		}
		if mips { tex = render.acquire_target_mips(c.renderer, w, h); op.pl.mips = tex != 0 }
		if tex == 0 { tex = render.acquire_target(c.renderer, w, h) }
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
	if pl.mips { add_op(c, render.Op{kind = .Mips, dst = pl.img.tex}) }
	if op.cache.store && c.glyphs_pending == op.pending0 { pl.kept = cache_store(c, op.cache, pl.img, pl.size, Rect{{0, 0}, {f32(pl.size.x), f32(pl.size.y)}}) }
	return pl
}

// The frame of the plane being drawn (the innermost open one): the plane frame position of texel (0, 0) and the texels per plane
// frame unit. What is drawn meanwhile goes through the transform stack and then texels = (frame - origin) * scale. ok = false:
// no plane is open, or its content is drawn directly (no layer: nothing projects it).
open_plane_frame :: proc(c: ^Context) -> (origin: Vec2, scale: f32, ok: bool) {
	if len(c.planes) == 0 { return }
	op := c.planes[len(c.planes) - 1]
	if op.pl.direct { return }
	return op.pl.origin, op.pl.scale, true
}
// Gives the texture of a plane that will not be drawn back to the pool.
discard_plane :: proc(c: ^Context, pl: Plane_Layer) {
	if pl.img.tex != 0 && !pl.kept { render.release_target(c.renderer, pl.img.tex) }
}

// A half-space of the space a plane is drawn into, after the perspective divide: n . (x / w, y / w, z / w) + d >= 0 (n of unit
// length). The surfaces of planes are planes there (a projective map keeps them), and the function is affine in the plane's own
// frame once multiplied by w, so a cut is exact in every layer whose matrix is known. See draw_planes.
Plane_Cut :: struct {
	n: [3]f32,
	d: f32,
}

MAX_PLANE_CUTS :: 6   // render.MAX_CUTS in rect.wgsl

Plane_Draw :: struct {
	max_taps:   int,    // anisotropic filter taps (0: PLANE_MAX_TAPS_DEFAULT)
	cull_back:  bool,   // backface-visibility: hidden: not drawn when seen from behind
	cuts:       []Plane_Cut,   // only the part of the plane inside every cut is drawn (hard edges: pieces of one plane cut by
	                           // others fit without a seam)
	retain:     bool,   // the layer's texture is not given back: the caller draws it again (other pieces), then discard_plane
	// Effects on the composite (the projected quad), CSS Compositing 1 and Filter Effects 2:
	blend:      Blend_Mode,    // mix-blend-mode of the quad against what is under it
	backdrop:   []Filter,      // backdrop-filter: what lies under the quad, filtered (screen space), shown through `shape`.
	                           // Lengths (blur, shadow offsets) are in plane frame units: they follow the plane's scale at its middle
	shape:      Plane_Layer,   // what the backdrop shows through: the alpha of this layer (same frame as the plane, drawn through
	                           // the same matrix); tex 0: the alpha of the plane itself
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

