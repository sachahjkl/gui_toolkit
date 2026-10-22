package draw

import "core:math"
import "../render"

// Compositing of planes (see plane.odin): the projected quad, its cuts, and the effects of the composite.

// Composites a plane through `m` (plane frame -> current local space, see above) and hands its texture back (unless kept or
// retained).
draw_plane :: proc(c: ^Context, pl: Plane_Layer, m: Mat4, alpha := f32(1), o: Plane_Draw = {}) {
	defer if !o.retain {
		discard_plane(c, pl)
		discard_plane(c, o.shape)
	}
	if pl.img.tex == 0 || pl.direct { return }
	if c.rec != nil { return }
	if o.cull_back && plane_faces_away(pl, m) { return }
	if o.blend == .Normal && len(o.backdrop) == 0 {
		emit_plane(c, pl, m, alpha, o)
		return
	}
	draw_plane_fx(c, pl, m, alpha, o)
}

// pop_plane + draw_plane.
pop_plane_draw :: proc(c: ^Context, m: Mat4, alpha := f32(1), o: Plane_Draw = {}) {
	draw_plane(c, pop_plane(c), m, alpha, o)
}

// The instance of one plane (one piece of it, when cut): a quad through the homography of the layer's texels.
@(private)
emit_plane :: proc(c: ^Context, pl: Plane_Layer, m: Mat4, alpha: f32, o: Plane_Draw) {
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
	ncuts := min(len(o.cuts), MAX_PLANE_CUTS)
	cut_rows: [MAX_PLANE_CUTS][3]f32
	for i in 0 ..< ncuts {
		cut_rows[i] = cut_in_texels(o.cuts[i], pl, m)
	}
	for i := 0; i < ncuts; i += 2 {
		e := render.Xform_Data{}
		e.m = {cut_rows[i][0], cut_rows[i][1], cut_rows[i][2], 0, 0, 0}
		if i + 1 < ncuts { e.m = {cut_rows[i][0], cut_rows[i][1], cut_rows[i][2], cut_rows[i + 1][0], cut_rows[i + 1][1], cut_rows[i + 1][2]} }
		append(&c.xform_table, e)
	}
	taps := f32(o.max_taps > 0 ? o.max_taps : PLANE_MAX_TAPS_DEFAULT)
	al := alpha_stack * alpha
	flags: u32 = render.FLAG_PROJECT | (pl.img.space == .Srgb ? render.FLAG_TEX_SRGB : 0)
	w, h := f32(pl.size.x), f32(pl.size.y)
	inst := render.Rect_Inst{
		dst = {0, 0, w, h}, src = {0, 0, w, h},
		colors = {{1, 1, 1, al}, {taps, f32(ncuts), pl.mips ? 1 : 0, 0}, {0, 0, w, h}, {0, 0, w, h}},
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

// A cut as a half-plane of the layer's texel space: a x + b y + c >= 0 (normalized: c is a distance in texels). In the plane's
// frame the cut is n . (X, Y, Z) + d W of the homogeneous result of `m`, which is affine in (x, y); the layer's texels are the
// plane frame scaled and moved.
@(private)
cut_in_texels :: proc(cut: Plane_Cut, pl: Plane_Layer, m: Mat4) -> [3]f32 {
	n, d := cut.n, cut.d
	fx := n.x * m[0] + n.y * m[1] + n.z * m[2] + d * m[3]
	fy := n.x * m[4] + n.y * m[5] + n.z * m[6] + d * m[7]
	f0 := n.x * m[12] + n.y * m[13] + n.z * m[14] + d * m[15]
	s := pl.scale
	a, b := fx / s, fy / s
	c := fx * pl.origin.x + fy * pl.origin.y + f0
	l := math.sqrt(a * a + b * b)
	if l < 1e-20 { return {0, 0, c >= 0 ? 1 : -1} }
	return {a / l, b / l, c / l}
}

// The plane's scale at its middle: screen units per plane frame unit (the square root of the area of the projected unit square).
@(private)
plane_density :: proc(pl: Plane_Layer, m: Mat4) -> f32 {
	mid := pl.origin + Vec2{f32(pl.size.x), f32(pl.size.y)} / pl.scale * 0.5
	p := [3][2]f32{}
	for i in 0 ..< 3 {
		q := mid + (i == 1 ? Vec2{1, 0} : (i == 2 ? Vec2{0, 1} : Vec2{}))
		h := mat4_apply(m, {q.x, q.y, 0})
		if !(h[3] > 1e-6) { return 1 }
		p[i] = {h[0] / h[3], h[1] / h[3]}
	}
	a, b := p[1] - p[0], p[2] - p[0]
	s := math.sqrt(abs(a.x * b.y - a.y * b.x))
	return s > 1e-6 ? s : 1
}

// A plane with effects on its composite: the screen area of the projected quad becomes an ordinary layer (blend mode against
// what is under it, group opacity), and the backdrop-filter is a masked layer inside: the filtered backdrop times the alpha of
// the plane's silhouette, projected like the plane. The plane itself lies on top.
@(private)
draw_plane_fx :: proc(c: ^Context, pl: Plane_Layer, m: Mat4, alpha: f32, o: Plane_Draw) {
	xf := c.xforms[len(c.xforms) - 1]
	q := plane_corners(pl, m)
	region: Rect
	all_front := true
	for k in 0 ..< 4 { if !(q[k][3] > 1e-6) { all_front = false } }
	if all_front {
		region = Rect{{q[0][0] / q[0][3], q[0][1] / q[0][3]}, {q[0][0] / q[0][3], q[0][1] / q[0][3]}}
		for k in 1 ..< 4 {
			x, y := q[k][0] / q[k][3], q[k][1] / q[k][3]
			region = Rect{{min(region.min.x, x), min(region.min.y, y)}, {max(region.max.x, x), max(region.max.y, y)}}
		}
	} else {
		// part of the plane lies behind the eye: the visible area is bounded by the clip and the target
		inv, ok := affine_inverse(xf.m)
		if !ok { emit_plane(c, pl, m, alpha, o); return }
		vis := rect_intersect(c.clips[len(c.clips) - 1].rect, target_rect(c))
		region = affine_bounds(inv, vis)
	}
	// the layers' own rounding to whole pixels happens in the screen space; a margin for the antialiased edge
	region = Rect{region.min - 1, region.max + 1}
	if rect_empty(region) { return }
	fx_blend := o.blend != .Normal
	bd: Backdrop
	has_bd := len(o.backdrop) > 0
	if has_bd {
		dens := plane_density(pl, m)
		fs := make([]Filter, len(o.backdrop), context.temp_allocator)
		for f, i in o.backdrop {
			fs[i] = f
			fs[i].sigma *= dens
			fs[i].offset *= dens
		}
		bd = backdrop_capture(c, region, fs)
	}
	inner := alpha
	if fx_blend {
		push_effects(c, region, Layer_Effects{alpha = alpha, blend = o.blend})
		inner = 1
	}
	if has_bd && bd.image.tex != 0 {
		push_mask(c, region, Layer_Effects{alpha = fx_blend ? 1 : alpha})
		backdrop_draw(c, bd, region, {})
		mask_layer(c, .Alpha, .Add)
		sh := o.shape
		if sh.img.tex == 0 || sh.direct { sh = pl }
		emit_plane(c, sh, m, 1, o)
		pop_mask(c)
	}
	emit_plane(c, pl, m, inner, o)
	if fx_blend { pop_layer(c) }
}
