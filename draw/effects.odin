package draw

import "core:math"
import "../render"

// Effects drawn through offscreen layers: group opacity, filters (CSS Filter Effects 1: color matrices, gaussian
// blur, drop shadow), blend modes (CSS Compositing 1), backdrops (CSS backdrop-filter) and clip shapes beyond rounded
// rects (ellipses, polygons: CSS clip-path). See docs/draw.md.

Blend_Mode :: render.Blend_Mode

// A color matrix, row-major 4 x 5: r' = m[0] r + m[1] g + m[2] b + m[3] a + m[4], then g', b', a'. It applies to
// straight (not premultiplied) sRGB values in 0..1, as CSS filter functions do; the result is clamped.
Color_Matrix :: [20]f32

COLOR_MATRIX_IDENTITY :: Color_Matrix{1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0}

Filter_Kind :: enum u8 {
	Color_Matrix,   // `cm`
	Blur,           // gaussian, standard deviation `sigma`
	Drop_Shadow,    // the alpha of the input, blurred (`sigma`), moved by `offset`, in `color`, under the input
}

// One filter function. Lengths (sigma, offset) are in the local units of the layer (they follow its transform).
Filter :: struct {
	kind:   Filter_Kind,
	cm:     Color_Matrix,
	sigma:  f32,
	offset: Vec2,
	color:  Color,      // linear, straight alpha, like every color of draw
}

filter_matrix :: proc(m: Color_Matrix) -> Filter { return Filter{kind = .Color_Matrix, cm = m} }

// CSS brightness(): multiplies the color channels.
filter_brightness :: proc(a: f32) -> Filter {
	return filter_matrix({a, 0, 0, 0, 0, 0, a, 0, 0, 0, 0, 0, a, 0, 0, 0, 0, 0, 1, 0})
}

// CSS contrast(): around mid gray.
filter_contrast :: proc(a: f32) -> Filter {
	b := 0.5 - 0.5 * a
	return filter_matrix({a, 0, 0, 0, b, 0, a, 0, 0, b, 0, 0, a, 0, b, 0, 0, 0, 1, 0})
}

// CSS grayscale() (amount 0..1).
filter_grayscale :: proc(amount: f32) -> Filter {
	g := 1 - clamp(amount, 0, 1)
	return filter_matrix({
		0.2126 + 0.7874 * g, 0.7152 - 0.7152 * g, 0.0722 - 0.0722 * g, 0, 0,
		0.2126 - 0.2126 * g, 0.7152 + 0.2848 * g, 0.0722 - 0.0722 * g, 0, 0,
		0.2126 - 0.2126 * g, 0.7152 - 0.7152 * g, 0.0722 + 0.9278 * g, 0, 0,
		0, 0, 0, 1, 0,
	})
}

// CSS sepia() (amount 0..1).
filter_sepia :: proc(amount: f32) -> Filter {
	g := 1 - clamp(amount, 0, 1)
	return filter_matrix({
		0.393 + 0.607 * g, 0.769 - 0.769 * g, 0.189 - 0.189 * g, 0, 0,
		0.349 - 0.349 * g, 0.686 + 0.314 * g, 0.168 - 0.168 * g, 0, 0,
		0.272 - 0.272 * g, 0.534 - 0.534 * g, 0.131 + 0.869 * g, 0, 0,
		0, 0, 0, 1, 0,
	})
}

// CSS saturate() (0 = gray, 1 = unchanged, above 1 = more saturated).
filter_saturate :: proc(s: f32) -> Filter {
	return filter_matrix({
		0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
		0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
		0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
		0, 0, 0, 1, 0,
	})
}

// CSS hue-rotate() (radians).
filter_hue_rotate :: proc(radians: f32) -> Filter {
	c, s := math.cos(radians), math.sin(radians)
	return filter_matrix({
		0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
		0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
		0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
		0, 0, 0, 1, 0,
	})
}

// CSS invert() (amount 0..1).
filter_invert :: proc(amount: f32) -> Filter {
	a := clamp(amount, 0, 1)
	k := 1 - 2 * a
	return filter_matrix({k, 0, 0, 0, a, 0, k, 0, 0, a, 0, 0, k, 0, a, 0, 0, 0, 1, 0})
}

// CSS opacity() as a filter function (amount 0..1).
filter_opacity :: proc(amount: f32) -> Filter {
	a := clamp(amount, 0, 1)
	return filter_matrix({1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, a, 0})
}

// CSS blur(): gaussian of standard deviation `sigma` (local units).
filter_blur :: proc(sigma: f32) -> Filter { return Filter{kind = .Blur, sigma = max(sigma, 0)} }

// CSS drop-shadow(): `sigma` is the standard deviation (CSS: half the blur radius).
filter_drop_shadow :: proc(offset: Vec2, sigma: f32, color: Color) -> Filter {
	return Filter{kind = .Drop_Shadow, offset = offset, sigma = max(sigma, 0), color = color}
}

// The filter changes nothing (brightness(1), blur(0), a transparent shadow...).
filter_is_identity :: proc(f: Filter) -> bool {
	switch f.kind {
	case .Color_Matrix: return f.cm == COLOR_MATRIX_IDENTITY
	case .Blur: return f.sigma <= 0
	case .Drop_Shadow: return f.color.a <= 0
	}
	return true
}

// How far, in screen pixels, `filters` (drawn under `m`) spread content past its bounds: left, top, right, bottom.
filters_outset :: proc(m: Affine, filters: []Filter) -> [4]f32 {
	k := affine_scale_factor(m)
	o: [4]f32
	for f in filters {
		if filter_is_identity(f) { continue }
		#partial switch f.kind {
		case .Blur:
			o += blur_extent(f.sigma * k)
		case .Drop_Shadow:
			d := affine_apply_vector(m, f.offset)
			e := blur_extent(f.sigma * k)
			o = {max(o[0], o[0] + e - d.x), max(o[1], o[1] + e - d.y), max(o[2], o[2] + e + d.x), max(o[3], o[3] + e + d.y)}
		}
	}
	return o
}

// A gaussian reaches about 3 standard deviations.
@(private)
blur_extent :: proc(sigma: f32) -> f32 { return sigma <= 0 ? 0 : math.ceil(3 * sigma) }

////////////////////////////////
// Layers

// The blend space of a layer's content.
Layer_Space :: enum u8 {
	Inherit,   // the enclosing target's (layer or frame)
	Linear,
	Srgb,
}

// How a layer is composited.
Layer_Effects :: struct {
	alpha:   f32,          // group opacity
	filters: []Filter,     // applied in order to the layer's pixels before compositing (copied: may be temporary)
	blend:   Blend_Mode,   // how the result combines with what is already drawn in the enclosing layer (or frame)
	space:   Layer_Space,  // what the content blends in inside the layer (the composite blends in the enclosing space)
}

// Everything drawn until pop_layer goes to an offscreen layer, composited once at pop with opacity `alpha` (times
// the alpha stack): overlapping primitives inside do not show through each other, as with CSS `opacity` on an element
// (push_alpha instead fades each primitive on its own). `bounds` (current local space) must contain what is drawn.
// Same as push_effects with only an alpha.
push_layer :: proc(c: ^Context, bounds: Rect, alpha: f32) { push_effects(c, bounds, Layer_Effects{alpha = alpha}) }

// Opens a layer composited at pop_layer through `fx`: filters, opacity, blend mode (in that order, as CSS applies
// them). `bounds` (current local space) must contain what is drawn; the layer covers their screen bounds grown by
// what the filters spread (blur, shadows), cut to what can reach the visible part of the current clip. Inside, the
// clip stack starts afresh at the layer's rect: what is drawn is not cut by the clip shapes around the layer; those
// apply when it is composited, after the filters (a blur is cut by an enclosing rounded clip, not blurred with it).
// Transforms, clips, images, text and other layers work inside as outside. When no render target can be had (empty,
// or larger than a texture), the content is drawn directly with push_alpha and the filters and blend mode are lost.
push_effects :: proc(c: ^Context, bounds: Rect, fx: Layer_Effects) {
	m := c.xforms[len(c.xforms) - 1].m
	first := len(c.filter_store)
	for f in fx.filters { if !filter_is_identity(f) { append(&c.filter_store, f) } }
	ol := Open_Layer{alpha = fx.alpha, parent = c.target, filters = {first, len(c.filter_store)}, blend = fx.blend, xform = m}
	out := filters_outset(m, c.filter_store[first:])
	visible := rect_intersect(c.clips[len(c.clips) - 1].rect, target_rect(c))
	// content as far as the filters spread it, and content close enough to the visible area to spread into it
	r := affine_bounds(m, bounds)
	r = Rect{r.min - {out[0], out[1]}, r.max + {out[2], out[3]}}
	r = rect_intersect(r, Rect{visible.min - {out[2], out[3]}, visible.max + {out[0], out[1]}})
	x0, y0 := math.floor(r.min.x), math.floor(r.min.y)
	x1, y1 := math.ceil(r.max.x), math.ceil(r.max.y)
	w, h := int(x1 - x0), int(y1 - y0)
	tex: render.Texture
	// a picture holds no offscreen layer (its screen place is not known): the alpha alone, as without a target
	if w > 0 && h > 0 && fx.alpha > 0 && !rect_empty(visible) && c.rec == nil { tex = render.acquire_target(c.renderer, w, h) }
	if tex == 0 {
		resize(&c.filter_store, first)
		ol.filters = {first, first}
		append(&c.open_layers, ol)
		push_alpha(c, fx.alpha)
		return
	}
	space := blend_space(c)
	switch fx.space {
	case .Inherit:
	case .Linear: space = .Linear
	case .Srgb: space = .Srgb
	}
	append(&c.layers, render.Layer{tex = tex, origin = {x0, y0}, size = {w, h}, space = space})
	ol.id = len(c.layers)
	append(&c.open_layers, ol)
	add_op(c, render.Op{kind = .Clear, dst = tex})
	close_batch(c)
	c.target = ol.id
	append(&c.clips, Clip{rect = {{x0, y0}, {x1, y1}}})
	start_batch(c)
	append(&c.alphas, 1)   // full opacity inside: the layer's alpha applies once, when it is composited
}

pop_layer :: proc(c: ^Context) {
	if len(c.open_layers) > 0 && c.open_layers[len(c.open_layers) - 1].masked { pop_mask(c); return }
	ol := pop(&c.open_layers)
	pop(&c.alphas)
	if ol.id == 0 { return }
	close_batch(c)
	pop(&c.clips)   // the layer's own clip root
	c.target = ol.parent
	start_batch(c)
	ly := c.layers[ol.id - 1]
	img := render.Image_Ref{tex = ly.tex, origin = ly.origin, scale = 1, size = ly.size, space = ly.space}
	if ol.filters[1] > ol.filters[0] {
		img = run_filters(c, img, c.filter_store[ol.filters[0]:ol.filters[1]], ol.xform, false)
	}
	resize(&c.filter_store, ol.filters[0])
	composite_layer(c, ol, img)
}

// Draws a closed layer's result (`img`, its filters applied) into the enclosing target: with the layer's opacity
// times the alpha stack, its blend mode, cut by the clips around it. Hands `img` back.
@(private)
composite_layer :: proc(c: ^Context, ol: Open_Layer, img: render.Image_Ref) {
	a := c.alphas[len(c.alphas) - 1] * ol.alpha
	_, _, shape := cur(c)
	x0, y0 := img.origin.x, img.origin.y
	w, h := f32(img.size.x), f32(img.size.y)
	tex_flag: u32 = img.space == .Srgb ? render.FLAG_TEX_SRGB : 0
	inst := render.Rect_Inst{
		dst = {x0, y0, x0 + w, y0 + h}, src = {0, 0, w, h}, colors = {{1, 1, 1, a}, {1, 1, 1, a}, {1, 1, 1, a}, {1, 1, 1, a}},
		soft = 1, use_tex = render.KIND_IMAGE, tex_size = 1, flags = render.FLAG_LAYER | tex_flag, clip = shape,
	}
	if ol.blend != .Normal && img.tex != 0 {
		// what lies under the composite, copied from the enclosing target, is read by the blend
		under := rect_intersect(rect_intersect(Rect{{x0, y0}, {x0 + w, y0 + h}}, c.clips[len(c.clips) - 1].rect), target_rect(c))
		ux0, uy0 := math.floor(under.min.x), math.floor(under.min.y)
		ux1, uy1 := math.ceil(under.max.x), math.ceil(under.max.y)
		if ux1 > ux0 && uy1 > uy0 {
			snap := render.acquire_snapshot(c.renderer, int(ux1 - ux0), int(uy1 - uy0), c.target)
			if snap != 0 {
				o := target_origin(c)
				add_op(c, render.Op{kind = .Copy, dst = snap, source = c.target, box = {i32(ux0 - o.x), i32(uy0 - o.y), i32(ux1 - o.x), i32(uy1 - o.y)}})
				inst.dst = {ux0, uy0, ux1, uy1}
				inst.src = {ux0 - x0, uy0 - y0, ux1 - x0, uy1 - y0}
				inst.radii = {ux0, uy0, 0, 0}
				inst.flags = render.FLAG_LAYER | render.FLAG_BLEND | tex_flag | u32(ol.blend) << render.BLEND_SHIFT
				close_batch(c)
				start_batch(c)
				b := &c.batches[len(c.batches) - 1]
				b.image, b.backdrop = img.tex, snap
				append(&c.insts, inst)
				close_batch(c)
				start_batch(c)
				render.release_target(c.renderer, snap)
				render.release_target(c.renderer, img.tex)
				return
			}
		}
	}
	// the composite: the layer's pixels 1:1 at their screen place (no transform: the content already went through
	// it), cut by the clip shapes around the layer
	b := &c.batches[len(c.batches) - 1]
	if b.image != img.tex {
		if b.image != 0 && len(c.insts) > b.first {
			close_batch(c)
			start_batch(c)
			b = &c.batches[len(c.batches) - 1]
		}
		b.image = img.tex
	}
	append(&c.insts, inst)
	render.release_target(c.renderer, img.tex)
}

// Screen rect of what the current target holds: the frame, or the open layer.
@(private)
target_rect :: proc(c: ^Context) -> Rect {
	if c.target == 0 { return Rect{{0, 0}, c.size} }
	ly := c.layers[c.target - 1]
	return Rect{ly.origin, ly.origin + {f32(ly.size.x), f32(ly.size.y)}}
}

@(private)
target_origin :: proc(c: ^Context) -> Vec2 {
	if c.target == 0 { return {} }
	return c.layers[c.target - 1].origin
}

@(private)
rect_empty :: proc(r: Rect) -> bool { return r.max.x <= r.min.x || r.max.y <= r.min.y }

////////////////////////////////
// Filter chains

@(private)
Chain :: struct {
	c:      ^Context,
	full:   [2]int,           // size of the input at scale 1
	passes: [dynamic]render.Pass,
}

@(private)
chain_target :: proc(ch: ^Chain, scale: f32, origin: Vec2) -> (render.Image_Ref, bool) {
	w := max(int(math.ceil(f32(ch.full.x) * scale)), 1)
	h := max(int(math.ceil(f32(ch.full.y) * scale)), 1)
	t := render.acquire_target(ch.c.renderer, w, h)
	if t == 0 { return {}, false }
	return render.Image_Ref{tex = t, origin = origin, scale = scale, size = {w, h}}, true
}

// The passes of `filters` on `input` (which they take over: it is released once read). Returns the result:
// premultiplied in the input's space, at scale 1, on the same screen rect; the caller releases it after recording
// what reads it. The passes compute in sRGB (converting from and back to a linear input at the ends of the chain).
// `clamp_edges`: what lies past the input repeats its edge (a backdrop) instead of being transparent.
@(private)
run_filters :: proc(c: ^Context, input: render.Image_Ref, filters: []Filter, m: Affine, clamp_edges: bool) -> render.Image_Ref {
	ch := Chain{c = c, full = input.size}
	ch.passes = make([dynamic]render.Pass, 0, 8, context.temp_allocator)
	cur := input
	cur_linear := input.space == .Linear
	base: u32 = clamp_edges ? render.PASS_CLAMP : 0
	k := affine_scale_factor(m)
	limit := max(c.renderer.blur_sigma_limit, 2)
	failed := false
	// a gaussian of `sigma` screen pixels over `src`: reduced first when large; the result may be at a lower scale
	blur :: proc(ch: ^Chain, src: render.Image_Ref, src_linear: bool, sigma, limit: f32, base: u32) -> (out: render.Image_Ref, out_linear: bool, ok: bool) {
		scale: f32 = 1
		for sigma * scale > limit && scale > 1.0 / 64 { scale *= 0.5 }
		s := src
		lin := src_linear
		variance: f32   // added by the reductions, screen px^2
		for s.scale > scale * 1.01 {
			d := chain_target(ch, s.scale * 0.5, s.origin) or_return
			append(&ch.passes, render.Pass{mode = .Downsample, flags = base | (lin ? render.PASS_IN_LINEAR : 0), src = s, dst = d})
			variance += 0.25 / (s.scale * s.scale)
			s, lin = d, false
		}
		eff := math.sqrt(max(sigma * sigma - variance, 0.09 / (scale * scale)))
		h := chain_target(ch, s.scale, s.origin) or_return
		append(&ch.passes, render.Pass{mode = .Blur, flags = base | (lin ? render.PASS_IN_LINEAR : 0), src = s, dst = h, dir = {1, 0}, sigma = eff * s.scale})
		v := chain_target(ch, s.scale, s.origin) or_return
		append(&ch.passes, render.Pass{mode = .Blur, flags = base, src = h, dst = v, dir = {0, 1}, sigma = eff * s.scale})
		return v, false, true
	}
	i := 0
	for i < len(filters) && !failed {
		f := filters[i]
		switch f.kind {
		case .Color_Matrix:
			p := render.Pass{mode = .Color, flags = base | (cur_linear ? render.PASS_IN_LINEAR : 0), src = cur}
			for i < len(filters) && filters[i].kind == .Color_Matrix && p.matrix_count < render.MAX_COLOR_MATRICES {
				p.matrices[p.matrix_count] = filters[i].cm
				p.matrix_count += 1
				i += 1
			}
			d, ok := chain_target(&ch, 1, cur.origin)
			if !ok { failed = true; break }
			p.dst = d
			append(&ch.passes, p)
			cur, cur_linear = d, false
			continue
		case .Blur:
			out, lin, ok := blur(&ch, cur, cur_linear, f.sigma * k, limit, base)
			if !ok { failed = true; break }
			cur, cur_linear = out, lin
		case .Drop_Shadow:
			src := cur
			blurred, src_lin := cur, cur_linear
			if f.sigma * k > 0.1 {
				out, _, ok := blur(&ch, cur, cur_linear, f.sigma * k, limit, base)
				if !ok { failed = true; break }
				blurred = out
			}
			d, ok := chain_target(&ch, 1, cur.origin)
			if !ok { failed = true; break }
			col := f.color
			enc :: proc(v: f32) -> f32 {
				x := clamp(v, 0, 1)
				return x <= 0.0031308 ? x * 12.92 : 1.055 * math.pow(x, 1 / 2.4) - 0.055
			}
			append(&ch.passes, render.Pass{
				mode = .Shadow, flags = base | (src_lin ? render.PASS_SRC2_LINEAR : 0), src = blurred, src2 = src, dst = d,
				offset = affine_apply_vector(m, f.offset), color = {enc(col.r), enc(col.g), enc(col.b), clamp(col.a, 0, 1)},
			})
			cur, cur_linear = d, false
		}
		i += 1
	}
	if failed || len(ch.passes) == 0 {
		// out of texture memory: the input as it is (the passes recorded so far are dropped)
		for p in ch.passes { if p.dst.tex != input.tex { render.release_target(c.renderer, p.dst.tex) } }
		return input
	}
	if cur.scale != 1 {
		// ended on a reduced blur: back to full size
		d, ok := chain_target(&ch, 1, cur.origin)
		if ok {
			append(&ch.passes, render.Pass{mode = .Color, flags = base, src = cur, dst = d})
			cur = d
		}
	}
	if input.space == .Linear { ch.passes[len(ch.passes) - 1].flags |= render.PASS_OUT_LINEAR }
	cur.space = input.space
	// record in order; a texture is handed back after the last pass that reads it
	last_read := make(map[render.Texture]int, 16, context.temp_allocator)
	for p, n in ch.passes {
		if p.src.tex != 0 { last_read[p.src.tex] = n }
		if p.src2.tex != 0 { last_read[p.src2.tex] = n }
	}
	for p, n in ch.passes {
		add_op(c, render.Op{kind = .Pass, dst = p.dst.tex, pass = p})
		for t, at in last_read { if at == n && t != cur.tex { render.release_target(c.renderer, t) } }
	}
	return cur
}

////////////////////////////////
// Backdrops (CSS backdrop-filter)

// What was drawn behind a rect, filtered: draw it with backdrop_draw. Holds a pooled texture until then.
Backdrop :: struct {
	image: render.Image_Ref,
}

// Copies what the current target (frame or layer) holds under rect `r` (current local space; its screen bounds cut to
// the current clip) and runs `filters` on it (lengths in local units). Past the copied area the image repeats its
// edge, so a blur does not darken the borders. Record it before drawing what goes in front.
backdrop_capture :: proc(c: ^Context, r: Rect, filters: []Filter) -> Backdrop {
	if c.rec != nil { return {} }   // nothing to capture while recording a picture
	m := c.xforms[len(c.xforms) - 1].m
	reg := rect_intersect(rect_intersect(affine_bounds(m, r), c.clips[len(c.clips) - 1].rect), target_rect(c))
	x0, y0 := math.floor(reg.min.x), math.floor(reg.min.y)
	x1, y1 := math.ceil(reg.max.x), math.ceil(reg.max.y)
	if x1 <= x0 || y1 <= y0 { return {} }
	w, h := int(x1 - x0), int(y1 - y0)
	snap := render.acquire_snapshot(c.renderer, w, h, c.target)
	if snap == 0 { return {} }
	o := target_origin(c)
	add_op(c, render.Op{kind = .Copy, dst = snap, source = c.target, box = {i32(x0 - o.x), i32(y0 - o.y), i32(x1 - o.x), i32(y1 - o.y)}})
	img := render.Image_Ref{tex = snap, origin = {x0, y0}, scale = 1, size = {w, h}, space = blend_space(c)}
	active := make([dynamic]Filter, 0, len(filters), context.temp_allocator)
	for f in filters { if !filter_is_identity(f) { append(&active, f) } }
	if len(active) > 0 { img = run_filters(c, img, active[:], m, true) }
	return Backdrop{image = img}
}

// Draws a captured backdrop clipped to the rounded rect `r` (current local space, radii as rect_corners) under the
// current transform, clips and alpha, then hands its texture back.
backdrop_draw :: proc(c: ^Context, b: Backdrop, r: Rect, radii: [4]f32) {
	im := b.image
	if im.tex == 0 { return }
	flags: u32 = render.FLAG_SCREEN | (im.space == .Srgb ? render.FLAG_TEX_SRGB : 0)
	image_inst(c, im.tex, r, {im.origin.x, im.origin.y, f32(im.size.x), f32(im.size.y)}, WHITE, radii, flags)
	render.release_target(c.renderer, im.tex)
}

// backdrop_capture + backdrop_draw.
backdrop :: proc(c: ^Context, r: Rect, radii: [4]f32, filters: []Filter) {
	backdrop_draw(c, backdrop_capture(c, r, filters), r, radii)
}

////////////////////////////////
// Clip shapes

// Clips to an ellipse (current local space), antialiased; nests with the other clips. pop_clip pops it.
push_clip_ellipse :: proc(c: ^Context, center: Vec2, radii: Vec2) {
	rr := Vec2{max(radii.x, 0), max(radii.y, 0)}
	push_clip_shape(c, Rect{center - rr, center + rr}, render.Clip_Data{kind = render.CLIP_ELLIPSE, center = center, half_size = rr})
}

// Clips to a polygon (current local space) with the nonzero or even-odd fill rule, antialiased; nests with the
// other clips. Costs work proportional to the number of vertices for each pixel inside its bounds. pop_clip pops it.
push_clip_polygon :: proc(c: ^Context, pts: []Vec2, evenodd := false) {
	if len(pts) < 3 {
		push_clip_shape(c, Rect{}, render.Clip_Data{kind = render.CLIP_POLYGON})
		return
	}
	first := len(c.clip_points)
	b := Rect{pts[0], pts[0]}
	for p in pts {
		append(&c.clip_points, [2]f32{p.x, p.y})
		b = Rect{{min(b.min.x, p.x), min(b.min.y, p.y)}, {max(b.max.x, p.x), max(b.max.y, p.y)}}
	}
	push_clip_shape(c, b, render.Clip_Data{kind = render.CLIP_POLYGON, first = u32(first), count = u32(len(pts)), flags = evenodd ? render.CLIP_EVENODD : 0})
}
