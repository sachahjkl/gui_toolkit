package draw

import "../render"

// Masks (CSS Masking 1 §7): content drawn into a layer is multiplied by the coverage of mask layers drawn after it,
// each one an image, a gradient, text... whose coverage is its alpha or its luminance, composited with the layers
// before it (mask-composite). CSS mask-image, and background-clip: text (the text of the element as an alpha mask
// over its backgrounds), are both drawn this way.
//
//	push_mask(dc, bounds, {alpha = 1})     // the content: everything until the first mask_layer
//	... draw the content ...
//	mask_layer(dc, .Alpha, .Add)           // the bottom mask layer (its operator is ignored: nothing is below it)
//	... draw it ...
//	mask_layer(dc, .Luminance, .Intersect) // the next one, composited with the bottom one
//	... draw it ...
//	pop_mask(dc)                           // composite: content x mask, then filters, opacity, blend mode
//
// A mask without any layer leaves the content as it is (CSS: `mask-image: none`). Mask layers draw in sRGB, whatever
// the frame's blend space, so their luminance is that of their CSS colors. When no render target can be had (empty,
// too large, or while a picture is recorded) the content is drawn directly and the mask layers are not drawn: the
// content shows unmasked. A mask layer with no target of its own is lost alone: its drawing is cut away, the others apply.

Mask_Mode :: enum u8 {
	Alpha,       // coverage = the layer's alpha
	Luminance,   // coverage = the luminance of its premultiplied color (sRGB, Rec. 709 coefficients)
}

Mask_Op :: render.Mask_Op

// Opens a masked layer: what is drawn next is its content, until mask_layer starts the mask. `fx` composites the
// result as push_effects does (its filters apply to the content before the mask, as CSS orders them).
// `fx.cache_id`: the masked result is kept as push_effects keeps a layer's (layer_cache.odin); `fx.cache_key` must then
// cover the mask layers as well as the content. Returns false when the kept result stands: neither the content nor the
// mask layers need be drawn (what is drawn until pop_mask is discarded).
push_mask :: proc(c: ^Context, bounds: Rect, fx: Layer_Effects = {alpha = 1}) -> (draw_content: bool) {
	return open_layer(c, bounds, fx, .Masked)
}

// Starts the next mask layer of the innermost push_mask: what is drawn until the next mask_layer or pop_mask is that
// layer. `op` composites it with the layers drawn before it (the first one has none: `op` is ignored).
mask_layer :: proc(c: ^Context, mode: Mask_Mode, op: Mask_Op) {
	if len(c.open_layers) == 0 { return }
	ol := &c.open_layers[len(c.open_layers) - 1]
	if ol.kind != .Masked || ol.cache.hit { return }   // (a kept result: everything drawn is already discarded)
	if ol.id == 0 {
		// no layer: the mask cannot apply
		if ol.mask_draw == .Content { mask_cut(c, ol) }
		return
	}
	switch ol.mask_draw {
	case .Content:
	case .Layer: mask_fold(c, ol)
	case .Cut:
		floor_settle(c)
		ol.mask_draw = .Content
	}
	content := c.layers[ol.id - 1]
	tex: render.Texture
	if !failing(.Mask_Target) { tex = render.acquire_target(c.renderer, content.size.x, content.size.y) }
	if tex == 0 {
		// out of targets: this layer is lost (as if fully covering: the others still apply)
		ol.cache.store = false
		mask_cut(c, ol)
		return
	}
	append(&c.layers, render.Layer{tex = tex, origin = content.origin, size = content.size, space = .Srgb})
	ol.mask_draw, ol.mask = .Layer, len(c.layers)
	ol.mask_mode, ol.mask_op = mode, op
	add_op(c, render.Op{kind = .Clear, dst = tex})
	close_batch(c)
	c.target = ol.mask
	start_batch(c)
}

// What is drawn for this mask layer is cut away (an empty scissor) instead of showing. floor_settle ends it.
@(private)
mask_cut :: proc(c: ^Context, ol: ^Open_Layer) {
	push_clip(c, Rect{})
	ol.mask_draw = .Cut
}

// The mask layer just drawn, composited with those before it.
@(private)
mask_fold :: proc(c: ^Context, ol: ^Open_Layer) {
	close_batch(c)
	ly := c.layers[ol.mask - 1]
	layer := render.Image_Ref{tex = ly.tex, origin = ly.origin, scale = 1, size = ly.size, space = ly.space}
	dst := render.acquire_target(c.renderer, ly.size.x, ly.size.y)
	ol.mask_draw, ol.mask = .Content, 0
	c.target = ol.id
	start_batch(c)
	if dst == 0 {
		render.release_target(c.renderer, layer.tex)
		ol.cache.store = false   // a mask layer is lost: the result is not the masked one, do not keep it
		return
	}
	flags: u32 = ol.mask_mode == .Luminance ? render.PASS_MASK_LUMINANCE : 0
	if ol.coverage.tex != 0 { flags |= render.PASS_MASK_DEST | u32(ol.mask_op) << render.MASK_OP_SHIFT }
	out := render.Image_Ref{tex = dst, origin = ly.origin, scale = 1, size = ly.size, space = .Srgb}
	add_op(c, render.Op{kind = .Pass, dst = dst, pass = render.Pass{mode = .Mask, flags = flags, src = ol.coverage, src2 = layer, dst = out}})
	if ol.coverage.tex != 0 { render.release_target(c.renderer, ol.coverage.tex) }
	render.release_target(c.renderer, layer.tex)
	ol.coverage = out
}

// Closes the innermost push_mask: its content times the coverage of its mask layers, through its filters, composited
// with its opacity and blend mode under the clips around it.
pop_mask :: proc(c: ^Context) {
	if len(c.open_layers) == 0 { return }
	top := &c.open_layers[len(c.open_layers) - 1]
	if top.kind != .Masked || top.cache.hit { pop_layer(c); return }
	layer_settle(c)
	if top.id == 0 {
		c.floor = pop(&c.open_layers).floor
		pop(&c.alphas)
		return
	}
	if top.mask_draw == .Layer { mask_fold(c, top) }
	ol := pop(&c.open_layers)
	c.floor = ol.floor
	pop(&c.alphas)
	close_batch(c)
	pop(&c.clips)   // the layer's own clip root
	c.target = ol.parent
	start_batch(c)
	ly := c.layers[ol.id - 1]
	img := render.Image_Ref{tex = ly.tex, origin = ly.origin, scale = 1, size = ly.size, space = ly.space}
	filters := c.filter_store[ol.filters[0]:ol.filters[1]]
	core, tail := layer_split(filters, true)
	f := Filtered{img = img, full = ly.size}
	if len(core) > 0 { f = run_filters(c, img, core, ol.xform, false) }
	set_tail(&f, tail)
	resize(&c.filter_store, ol.filters[0])
	if ol.coverage.tex != 0 {
		// at scale 1, as the coverage: a reduced result (a large blur last) is sampled back bilinearly, as the
		// composite would
		dst := render.acquire_target(c.renderer, f.full.x, f.full.y)
		if dst != 0 {
			out := render.Image_Ref{tex = dst, origin = f.img.origin, scale = 1, size = f.full, space = f.img.space}
			add_op(c, render.Op{kind = .Pass, dst = dst, pass = render.Pass{mode = .Mask, flags = render.PASS_MASK_APPLY, src = f.img, src2 = ol.coverage, dst = out}})
			render.release_target(c.renderer, f.img.tex)
			f.img = out
		} else {
			ol.cache.store = false   // no target for the masked result: the content is composited unmasked, not kept as the masked one
		}
		render.release_target(c.renderer, ol.coverage.tex)
	}
	composite_layer(c, ol, f)
}

// The mask layers of content that fades out at the edges of `r` (after push_mask's content): opaque inside, transparent
// at each edge whose width in `fade` (left, top, right, bottom) is not 0, a linear ramp over that width. A list that
// scrolls fades out this way where it goes on.
mask_edge_fade :: proc(c: ^Context, r: Rect, fade: [4]f32) {
	ramp :: proc(c: ^Context, r: Rect, lead, trail, length: f32, horizontal: bool) {
		clear :: Color{1, 1, 1, 0}
		a := clamp(lead / length, 0, 1)
		z := clamp(1 - trail / length, a, 1)
		stops := [4]Gradient_Stop{{color = lead > 0 ? clear : WHITE, pos = 0}, {color = WHITE, pos = a}, {color = WHITE, pos = z}, {color = trail > 0 ? clear : WHITE, pos = 1}}
		gradient(c, r, {kind = .Linear, start = {0, 0}, end = horizontal ? {length, 0} : {0, length}, stops = stops[:]})
	}
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	if w <= 0 || h <= 0 { return }
	horizontal := fade[0] > 0 || fade[2] > 0
	vertical := fade[1] > 0 || fade[3] > 0
	if horizontal {
		mask_layer(c, .Alpha, .Add)
		ramp(c, r, fade[0], fade[2], w, true)
	}
	if vertical {
		mask_layer(c, .Alpha, horizontal ? .Intersect : .Add)
		ramp(c, r, fade[1], fade[3], h, false)
	}
}
