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
// content shows unmasked.

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
	return open_layer(c, bounds, fx, true)
}

// Starts the next mask layer of the innermost push_mask: what is drawn until the next mask_layer or pop_mask is that
// layer. `op` composites it with the layers drawn before it (the first one has none: `op` is ignored).
mask_layer :: proc(c: ^Context, mode: Mask_Mode, op: Mask_Op) {
	if len(c.open_layers) == 0 { return }
	ol := &c.open_layers[len(c.open_layers) - 1]
	if !ol.masked || ol.cache.hit { return }   // (a kept result: everything drawn is already discarded)
	if ol.id == 0 {
		// no layer: the mask cannot apply; its drawing is cut away (an empty scissor) instead of showing
		if ol.mask == 0 {
			push_clip(c, Rect{})
			ol.mask = -1
		}
		return
	}
	if ol.mask > 0 { mask_fold(c, ol) }
	content := c.layers[ol.id - 1]
	tex := render.acquire_target(c.renderer, content.size.x, content.size.y)
	if tex == 0 {
		// out of targets: this layer is lost (as if fully covering: the others still apply)
		ol.mask = 0
		close_batch(c)
		c.target = ol.id
		start_batch(c)
		return
	}
	append(&c.layers, render.Layer{tex = tex, origin = content.origin, size = content.size, space = .Srgb})
	ol.mask = len(c.layers)
	ol.mask_mode, ol.mask_op = mode, op
	add_op(c, render.Op{kind = .Clear, dst = tex})
	close_batch(c)
	c.target = ol.mask
	start_batch(c)
}

// The mask layer just drawn, composited with those before it.
@(private)
mask_fold :: proc(c: ^Context, ol: ^Open_Layer) {
	close_batch(c)
	ly := c.layers[ol.mask - 1]
	layer := render.Image_Ref{tex = ly.tex, origin = ly.origin, scale = 1, size = ly.size, space = ly.space}
	dst := render.acquire_target(c.renderer, ly.size.x, ly.size.y)
	ol.mask = 0
	c.target = ol.id
	start_batch(c)
	if dst == 0 {
		render.release_target(c.renderer, layer.tex)
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
	if !top.masked || top.cache.hit { pop_layer(c); return }
	if top.id == 0 {
		if top.mask == -1 { pop_clip(c) }
		pop(&c.open_layers)
		pop(&c.alphas)
		return
	}
	if top.mask > 0 { mask_fold(c, top) }
	ol := pop(&c.open_layers)
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
		}
		render.release_target(c.renderer, ol.coverage.tex)
	}
	composite_layer(c, ol, f)
}
