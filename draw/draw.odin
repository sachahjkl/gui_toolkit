// Package draw: immediate-mode drawing on top of render + font.
//
// Primitives are appended to one instance list; a new GPU batch starts only when the clip rect changes or when an
// image needs a different texture than the batch's (glyphs and shapes never break a batch).
// Colors are LINEAR rgba (use `srgb` / `hex` to author them), whatever the renderer's blend space (render.Blend_Space:
// where they are mixed, linear light or sRGB values). A transform stack (2D affine, see `Affine`) and an alpha
// stack apply to everything drawn while they are pushed. Uniform scale + translation (press "squish", zoom) is baked
// on the CPU; rotation, skew and non-uniform scale go to the GPU as a per-instance transform, with shapes evaluated
// in local space (exact rounded corners, 1 px antialiasing under any transform).
package draw

import "core:math"
import "../font"
import "../render"

Color :: [4]f32
Vec2  :: [2]f32

Rect :: struct { min, max: Vec2 }

WHITE :: Color{1, 1, 1, 1}

rect_size :: proc(r: Rect) -> Vec2 { return r.max - r.min }
rect_center :: proc(r: Rect) -> Vec2 { return (r.min + r.max) * 0.5 }
rect_contains :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }
rect_pad :: proc(r: Rect, d: f32) -> Rect { return {r.min - d, r.max + d} }
rect_shift :: proc(r: Rect, d: Vec2) -> Rect { return {r.min + d, r.max + d} }
rect_intersect :: proc(a, b: Rect) -> Rect {
	return {{max(a.min.x, b.min.x), max(a.min.y, b.min.y)}, {min(a.max.x, b.max.x), min(a.max.y, b.max.y)}}
}

// sRGB (0..1) to the linear color the renderer expects
srgb :: proc(r, g, b: f32, a: f32 = 1) -> Color {
	lin :: proc(c: f32) -> f32 { return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) }
	return {lin(r), lin(g), lin(b), a}
}

// HSV (all 0..1, hue wraps) to a linear color
hsv :: proc(h, s, v: f32, a: f32 = 1) -> Color {
	hh := (h - math.floor(h)) * 6
	i := int(hh)
	f := hh - f32(i)
	p, q, t := v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	r, g, b: f32
	switch i {
	case 0: r, g, b = v, t, p
	case 1: r, g, b = q, v, p
	case 2: r, g, b = p, v, t
	case 3: r, g, b = p, q, v
	case 4: r, g, b = t, p, v
	case: r, g, b = v, p, q
	}
	return srgb(r, g, b, a)
}

// sRGB (0..1) hue/sat/val of a 0xRRGGBBAA color
hsv_from_hex :: proc(v: u32) -> (h, s, val: f32) {
	r, g, b := f32((v >> 24) & 255) / 255, f32((v >> 16) & 255) / 255, f32((v >> 8) & 255) / 255
	mx, mn := max(r, g, b), min(r, g, b)
	d := mx - mn
	val = mx
	s = mx == 0 ? 0 : d / mx
	switch {
	case d == 0: h = 0
	case mx == r: h = math.mod((g - b) / d, 6) / 6
	case mx == g: h = ((b - r) / d + 2) / 6
	case: h = ((r - g) / d + 4) / 6
	}
	if h < 0 { h += 1 }
	return
}

// 0xRRGGBBAA in sRGB
hex :: proc(v: u32) -> Color {
	return srgb(f32((v >> 24) & 255) / 255, f32((v >> 16) & 255) / 255, f32((v >> 8) & 255) / 255, f32(v & 255) / 255)
}

mix :: proc(a, b: Color, t: f32) -> Color { return a + (b - a) * t }

Blend_Space :: render.Blend_Space

// Where the corner colors of rect_corners (gradients) are interpolated across the primitive.
Interpolation :: enum u8 {
	Target,   // the blend space of the target drawn into (the default)
	Srgb,     // sRGB values: CSS gradients (CSS Images 4: `in srgb`, the default)
	Linear,   // linear light (CSS `in srgb-linear`)
}

// The alpha that makes `color` over `over` look, blended in `space`, as it does at `alpha` blended in linear light
// (luminance match; colors linear). For colors tuned for one space (a theme's translucent hover, a selection tint)
// drawn in the other one. Identity in Linear, or when color and backdrop have the same luminance.
alpha_like_linear :: proc(space: Blend_Space, color: Color, alpha: f32, over: Color) -> f32 {
	if space == .Linear || alpha <= 0 || alpha >= 1 { return alpha }
	y :: proc(c: Color) -> f32 { return clamp(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b, 0, 1) }
	yc, yb := y(color), y(over)
	sc, sb := render.linear_to_srgb(yc), render.linear_to_srgb(yb)
	if abs(sc - sb) < 1.0 / 255 { return alpha }
	want := render.linear_to_srgb(alpha * yc + (1 - alpha) * yb)
	return clamp((want - sb) / (sc - sb), 0, 1)
}

// The alpha that makes `color` over `over` look, blended in `space`, as it does at `alpha` blended in sRGB values (a
// perceptual step: the theme's hover and press fills are fractions of the way to a tint in sRGB values, so they read
// as the same step over dark and light surfaces). Identity in Srgb, or when color and backdrop have the same luminance.
alpha_like_srgb :: proc(space: Blend_Space, color: Color, alpha: f32, over: Color) -> f32 {
	if space == .Srgb || alpha <= 0 || alpha >= 1 { return alpha }
	y :: proc(c: Color) -> f32 { return clamp(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b, 0, 1) }
	yc, yb := y(color), y(over)
	if abs(yc - yb) < 1e-6 { return alpha }
	sc, sb := render.linear_to_srgb(yc), render.linear_to_srgb(yb)
	want := render.srgb_to_linear(sb + alpha * (sc - sb))
	return clamp((want - yb) / (yc - yb), 0, 1)
}

// Legacy scale + offset transform (p' = p * scale + offset); the stack now holds `Affine`s (see affine_from_xform).
Xform :: struct { scale: f32, offset: Vec2 }

// One level of the transform stack. `simple` (uniform scale + translation) is baked into the instances on the CPU;
// otherwise the matrix goes to the frame's GPU table the first time something is drawn with it (`gpu`, 0 = not yet).
Transform :: struct {
	m:      Affine,
	simple: bool,
	gpu:    u32,
}

// One level of the clip stack: the screen scissor, plus an optional shape evaluated per pixel (index into the
// frame's clip table, 0 = none) for rounded or transformed clips.
Clip :: struct {
	rect:  Rect,
	shape: u32,
}

Context :: struct {
	fonts:    ^font.State,
	renderer: ^render.Renderer,
	atlas:    render.Texture,
	insts:    [dynamic]render.Rect_Inst,
	batches:  [dynamic]render.Batch,
	clips:    [dynamic]Clip,
	alphas:   [dynamic]f32,
	xforms:   [dynamic]Transform,
	xform_table: [dynamic]render.Xform_Data,   // GPU transforms of this frame (entry 0 unused)
	clip_table:  [dynamic]render.Clip_Data,    // clip shapes of this frame (entry 0 unused)
	clip_points: [dynamic][2]f32,              // polygon clip vertices of this frame
	layers:   [dynamic]render.Layer,           // offscreen layers of this frame (push_layer), by id - 1
	ops:      [dynamic]render.Op,              // clears, copies and filter passes of this frame, in order
	open_layers: [dynamic]Open_Layer,
	filter_store: [dynamic]Filter,             // the filters of open layers (Open_Layer.filters indexes it)
	target:   int,                             // where new batches draw: 0 = the frame, else a layer id
	circular: bool,                            // set_circular_corners
	interp:   Interpolation,                   // set_interpolation
	size:     Vec2,
	grads:    [dynamic][4]f32,                 // gradient table of this frame (or of the picture being recorded)
	replays:  [dynamic]render.Replay,          // pictures drawn this frame
	glyphs:   Glyph_Pages,                     // textures of the font atlas pages (text.odin)
	slug_runs: [dynamic][2]int,                // instances of KIND_SLUG: [first, count) of `insts` (slug.odin)
	slug:     Slug_GPU,                        // textures of the font's Slug glyph pages
	// retained drawing (picture.odin)
	rec:      ^Picture,                        // the picture being recorded, nil = drawing the frame
	saved:    Saved_Frame,                     // the frame's lists while a picture is recorded
	raster_scale: f32,                         // while recording: screen pixels per picture unit expected (text raster size)
	pictures: [dynamic]^Picture,               // pictures holding retained heap ranges (eviction)
	frame_no: u64,
	retained_budget: int,                      // bytes of retained heaps kept before evicting unused pictures, 0 = no limit
	device_generation: u64,                    // render.Renderer.device_generation seen last
	layer_cache: Layer_Cache,                  // filter results kept across frames (layer_cache.odin)
}

// A layer being drawn (push_layer / push_effects ... pop_layer).
Open_Layer :: struct {
	id:      int,       // 0: no layer (fallback to per-primitive alpha)
	alpha:   f32,
	parent:  int,       // the target to go back to
	filters: [2]int,    // [first, end) of Context.filter_store
	blend:   Blend_Mode,
	xform:   Affine,    // the transform when it was pushed (filter lengths and offsets are in that local space)
	// a masked layer (push_mask): the content is layer `id`; mask layers are drawn one after the other into layer
	// `mask` and folded into `coverage` (mask_layer, pop_mask)
	masked:   bool,
	mask:     int,               // the mask layer being drawn (0: still the content)
	mask_mode: Mask_Mode,
	mask_op:  Mask_Op,
	coverage: render.Image_Ref,  // the mask layers drawn so far, composited (tex 0: none yet)
	cache:   Cache_Ask, // Layer_Effects.cache_id: a kept result composited (cache.hit: nothing drawn), or one to keep
	region:  Rect,      // screen region of the layer
}

init :: proc(c: ^Context, r: ^render.Renderer, fonts: ^font.State) {
	c.renderer = r
	c.fonts = fonts
	c.atlas = render.create_texture_r8(r, fonts.settings.page_size > 0 ? fonts.settings.page_size : font.ATLAS_SIZE)
	c.device_generation = r.device_generation
	c.raster_scale = 1
}

// Frees the context's memory. Pictures recorded with it should be destroyed first (picture_destroy).
destroy :: proc(c: ^Context) {
	delete(c.insts); delete(c.batches); delete(c.clips); delete(c.alphas); delete(c.xforms)
	delete(c.xform_table); delete(c.clip_table); delete(c.clip_points); delete(c.layers); delete(c.ops)
	delete(c.open_layers); delete(c.filter_store); delete(c.grads); delete(c.replays); delete(c.pictures); delete(c.slug_runs)
	saved_destroy(&c.saved)
	slug_gpu_destroy(c)
	text_destroy(c)
	cache_destroy(c)
}

begin_frame :: proc(c: ^Context, size: Vec2) {
	assert(c.rec == nil, "draw.begin_frame while a picture is being recorded")
	// a lost device is recreated before anything is drawn: the atlas page textures came back empty (same handles)
	if c.renderer.lost { render.recover(c.renderer) }
	if c.renderer.device_generation != c.device_generation {
		c.device_generation = c.renderer.device_generation
		text_device_reset(c)
		slug_gpu_device_reset(c)
	}
	clear(&c.slug_runs)
	clear(&c.insts); clear(&c.batches); clear(&c.clips); clear(&c.alphas); clear(&c.xforms)
	clear(&c.xform_table); clear(&c.clip_table); clear(&c.clip_points); clear(&c.layers); clear(&c.ops)
	clear(&c.open_layers); clear(&c.filter_store); clear(&c.grads); clear(&c.replays)
	c.frame_no += 1
	cache_begin_frame(c)
	c.raster_scale = 1
	c.target = 0
	c.circular = false
	c.interp = .Target
	c.size = size
	text_begin_frame(c)
	append(&c.clips, Clip{rect = {{0, 0}, size}})
	append(&c.alphas, 1)
	append(&c.xforms, Transform{m = AFFINE_IDENTITY, simple = true})
	append(&c.xform_table, render.Xform_Data{})
	append(&c.clip_table, render.Clip_Data{})
	start_batch(c)
}

@(private)
start_batch :: proc(c: ^Context) {
	top := c.clips[len(c.clips) - 1]
	cl := top.rect
	append(&c.batches, render.Batch{clip = {cl.min.x, cl.min.y, cl.max.x, cl.max.y}, tex = c.atlas, first = len(c.insts), target = c.target, shape = top.shape})
}

// Records a step that is not a draw call (it runs between the batches recorded before and after it).
@(private)
add_op :: proc(c: ^Context, op: render.Op) {
	close_batch(c)
	append(&c.ops, op)
	append(&c.batches, render.Batch{first = len(c.insts), target = c.target, op = len(c.ops)})
	start_batch(c)
}

@(private)
close_batch :: proc(c: ^Context) {
	b := &c.batches[len(c.batches) - 1]
	b.count = len(c.insts) - b.first
}

////////////////////////////////
// Clips

// Clips to `r` (current local space). Without a transform, or with only scale + translation, this is the GPU
// scissor (free). Under rotation / skew the scissor is the screen bounds and the exact rect is clipped per pixel
// (as push_clip_rounded with zero radii).
push_clip :: proc(c: ^Context, r: Rect) {
	xf := c.xforms[len(c.xforms) - 1]
	if c.rec != nil {
		// the screen is not known yet: a clip of the picture, turned into the scissor at replay
		push_clip_shape(c, r, render.Clip_Data{kind = render.CLIP_RRECT, flags = render.CLIP_SCISSOR, center = rect_center(r), half_size = rect_half(r)})
		return
	}
	if !xf.simple { push_clip_rounded(c, r, {}); return }
	s, o := xf.m.a, Vec2{xf.m.e, xf.m.f}
	parent := c.clips[len(c.clips) - 1]
	t := rect_intersect(Rect{r.min * s + o, r.max * s + o}, parent.rect)
	close_batch(c)
	append(&c.clips, Clip{rect = t, shape = parent.shape})
	start_batch(c)
}

// Clips to a rounded rect in the current local space (any transform): `overflow: hidden` with `border-radius`, or a
// clip inside a rotated element. Corner order as rect_corners (top-left, bottom-left, top-right, bottom-right); the
// corner shape (circular / squircle) is the one rects use, so a clip matches a rect drawn with the same radii.
// Coverage is antialiased and nests: everything drawn is multiplied by every enclosing shape (up to
// render.MAX_CLIP_DEPTH shapes deep; deeper ones are ignored). Costs a little pixel-shader work per clipped pixel.
push_clip_rounded :: proc(c: ^Context, r: Rect, radii: [4]f32) {
	xf := c.xforms[len(c.xforms) - 1]
	if xf.simple && radii == {} { push_clip(c, r); return }
	push_clip_shape(c, r, render.Clip_Data{
		kind = render.CLIP_RRECT, flags = c.circular ? render.CLIP_CIRCLE : 0,
		center = rect_center(r), half_size = rect_half(r), radii = radii,
	})
}

@(private)
rect_half :: proc(r: Rect) -> Vec2 {
	half := rect_size(r) * 0.5
	return {max(half.x, 0), max(half.y, 0)}
}

// Pushes a clip shape whose local bounds are `bounds` (the scissor is their screen bounds): the transform's inverse,
// the antialiasing scale and the parent link are filled in here.
@(private)
push_clip_shape :: proc(c: ^Context, bounds: Rect, shape: render.Clip_Data) {
	xf := c.xforms[len(c.xforms) - 1]
	parent := c.clips[len(c.clips) - 1]
	if c.rec != nil {
		// a clip of the picture: in the space of the current slot, its scissor computed at replay
		d := shape
		d.xform = xf.gpu
		d.parent = parent.shape
		append(&c.clip_table, d)
		append(&c.rec.clip_rects, bounds)
		close_batch(c)
		append(&c.clips, Clip{shape = u32(len(c.clip_table) - 1)})
		start_batch(c)
		return
	}
	inv, ok := affine_inverse(xf.m)
	// 1 px of slack: the scissor is integer, the shape's antialiased edge is not
	scissor := rect_intersect(rect_pad(affine_bounds(xf.m, bounds), 1), parent.rect)
	if !ok { scissor = {} }
	d := shape
	d.inv = {inv.a, inv.b, inv.c, inv.d, inv.e, inv.f}
	d.px = affine_scale_factor(xf.m)
	d.parent = parent.shape
	append(&c.clip_table, d)
	close_batch(c)
	append(&c.clips, Clip{rect = scissor, shape = u32(len(c.clip_table) - 1)})
	start_batch(c)
}

pop_clip :: proc(c: ^Context) {
	close_batch(c)
	pop(&c.clips)
	start_batch(c)
}

// Current scissor rect (screen pixels).
current_clip :: proc(c: ^Context) -> Rect { return c.clips[len(c.clips) - 1].rect }

////////////////////////////////
// Alpha and transforms

push_alpha :: proc(c: ^Context, a: f32) { append(&c.alphas, c.alphas[len(c.alphas) - 1] * a) }
pop_alpha :: proc(c: ^Context) { pop(&c.alphas) }

// Rounded corners drawn from now on (rects, images, rounded clips) are circular arcs when `on`, whatever the
// renderer's corner shape (render.set_corner_smoothing, the squircle of the UI): content that follows its own rules,
// such as CSS border-radius, sets it around its drawing. Returns the previous setting. begin_frame resets it.
set_circular_corners :: proc(c: ^Context, on: bool) -> (previous: bool) {
	previous = c.circular
	c.circular = on
	return
}

// Where the corner colors of what is drawn from now on (rect_corners) are interpolated. Returns the previous setting.
// begin_frame resets it to .Target.
set_interpolation :: proc(c: ^Context, interp: Interpolation) -> (previous: Interpolation) {
	previous = c.interp
	c.interp = interp
	return
}

// The blend space of what is drawn now: the open layer's, or the frame's.
blend_space :: proc(c: ^Context) -> Blend_Space {
	if c.target > 0 { return c.layers[c.target - 1].space }
	return c.renderer.space
}

// Layers opened and not closed yet.
layer_depth :: proc(c: ^Context) -> int { return len(c.open_layers) }

// Everything drawn next goes through `m` first, then through the transforms already pushed (CSS nesting: push the
// element's `transform` with its transform-origin folded in, see affine_around). Pop with pop_transform.
// While a picture is recorded, each pushed transform is a slot of the picture (see picture_set_slot).
push_transform :: proc(c: ^Context, m: Affine) {
	n := affine_mul(c.xforms[len(c.xforms) - 1].m, m)
	if c.rec != nil { push_new_slot(c, m, n); return }
	append(&c.xforms, Transform{m = n, simple = affine_is_scale_translate(n)})
}
pop_transform :: proc(c: ^Context) { pop(&c.xforms) }

// Scale everything drawn next by `s` around `center` (screen space, i.e. applied after the current transform).
push_scale :: proc(c: ^Context, center: Vec2, s: f32) {
	m := c.xforms[len(c.xforms) - 1].m
	// new(p) = (cur(p) - center) * s + center
	n := Affine{m.a * s, m.b * s, m.c * s, m.d * s, (m.e - center.x) * s + center.x, (m.f - center.y) * s + center.y}
	if c.rec != nil {
		inv, _ := affine_inverse(m)
		push_new_slot(c, affine_mul(inv, n), n)
		return
	}
	append(&c.xforms, Transform{m = n, simple = affine_is_scale_translate(n)})
}
// Same as pop_transform (pops push_scale or push_transform).
pop_xform :: proc(c: ^Context) { pop(&c.xforms) }

// Local -> screen transform of what is drawn now (its affine_inverse maps a screen point back, for hit testing).
current_transform :: proc(c: ^Context) -> Affine { return c.xforms[len(c.xforms) - 1].m }

@(private)
cur :: proc(c: ^Context) -> (xf: ^Transform, alpha: f32, shape: u32) {
	return &c.xforms[len(c.xforms) - 1], c.alphas[len(c.alphas) - 1], c.clips[len(c.clips) - 1].shape
}

// GPU table index of the current transform (uploaded on first use).
@(private)
gpu_xform :: proc(c: ^Context, xf: ^Transform) -> u32 {
	if c.rec != nil { return xf.gpu }   // the slot, made when it was pushed
	if xf.gpu == 0 {
		m := xf.m
		append(&c.xform_table, render.Xform_Data{m = {m.a, m.b, m.c, m.d, m.e, m.f}})
		xf.gpu = u32(len(c.xform_table) - 1)
	}
	return xf.gpu
}

////////////////////////////////
// Primitives

Rect_Style :: struct {
	radius: [4]f32,     // top-left, bottom-left, top-right, bottom-right
	border: f32,        // > 0: outline only
	soft:   f32,        // > 1: soft edge (shadows)
}

// Filled (or outlined) rounded rect, uniform color.
rect :: proc(c: ^Context, r: Rect, color: Color, radius: f32 = 0, border: f32 = 0, soft: f32 = 1) {
	rect_corners(c, r, {color, color, color, color}, {radius, radius, radius, radius}, border, soft)
}

// Per-corner colors (gradients) and radii; corner order: top-left, bottom-left, top-right, bottom-right. Colors are
// interpolated premultiplied, in the space set_interpolation chooses.
rect_corners :: proc(c: ^Context, r: Rect, colors: [4]Color, radii: [4]f32, border: f32 = 0, soft: f32 = 1) {
	xf, alpha, shape := cur(c)
	flags: u32 = c.circular ? render.FLAG_CIRCLE : 0
	switch c.interp {
	case .Target:
	case .Srgb: flags |= render.FLAG_LERP_SRGB
	case .Linear: flags |= render.FLAG_LERP_LINEAR
	}
	inst := render.Rect_Inst{colors = colors, soft = soft, use_tex = render.KIND_SHAPE, tex_size = font.ATLAS_SIZE, clip = shape, flags = flags}
	if xf.simple {
		s, o := xf.m.a, Vec2{xf.m.e, xf.m.f}
		inst.dst = {r.min.x * s + o.x, r.min.y * s + o.y, r.max.x * s + o.x, r.max.y * s + o.y}
		inst.radii, inst.border = radii * s, border * s
		if soft > 1 { inst.soft = soft * s }
	} else {
		inst.dst = {r.min.x, r.min.y, r.max.x, r.max.y}
		inst.radii, inst.border = radii, border
		inst.xform = gpu_xform(c, xf)
	}
	for i in 0 ..< 4 { inst.colors[i].a *= alpha }
	append(&c.insts, inst)
}

////////////////////////////////
// Images

// Draws the `src` sub-rectangle of `tex` (texels; the zero Rect = the whole texture) into `dst`, bilinear with mips,
// multiplied by `tint` (linear, straight alpha) and the alpha stack, with rounded corners like `rect`.
// `tex` comes from render.create_texture_rgba. Works under any transform.
image :: proc(c: ^Context, tex: render.Texture, dst: Rect, src: Rect = {}, tint: Color = WHITE, radius: f32 = 0) {
	image_corners(c, tex, dst, src, tint, {radius, radius, radius, radius})
}

// `image` with per-corner radii (top-left, bottom-left, top-right, bottom-right).
image_corners :: proc(c: ^Context, tex: render.Texture, dst: Rect, src: Rect, tint: Color, radii: [4]f32) {
	ts := render.texture_size(c.renderer, tex)
	if ts.x == 0 { return }
	s := src
	if s == {} { s = {{0, 0}, {f32(ts.x), f32(ts.y)}} }
	image_inst(c, tex, dst, {s.min.x, s.min.y, s.max.x, s.max.y}, tint, radii, texture_flags(c, tex))
}

// FLAG_TEX_SRGB for an RGBA texture stored in sRGB (render.texture_space).
@(private)
texture_flags :: proc(c: ^Context, tex: render.Texture) -> u32 {
	return render.texture_space(c.renderer, tex) == .Srgb ? render.FLAG_TEX_SRGB : 0
}

// Repeats the whole texture (CSS background-repeat): one copy lands on `tile` (local coords, may be smaller or larger
// than the texture, any offset), copies repeat in both directions and `dst` crops them. One instance, seamless
// (hardware wrap addressing, mips follow the tile size). For a single-axis repeat make `dst` one tile tall / wide;
// for repeating a sub-rectangle of a texture (sprite sheets), draw one `image` per tile instead.
image_tiled :: proc(c: ^Context, tex: render.Texture, dst: Rect, tile: Rect, tint: Color = WHITE, radii: [4]f32 = {}) {
	ts := render.texture_size(c.renderer, tex)
	tsz := rect_size(tile)
	if ts.x == 0 || tsz.x == 0 || tsz.y == 0 { return }
	k := Vec2{f32(ts.x), f32(ts.y)} / tsz   // texels per local unit
	uv0 := (dst.min - tile.min) * k
	uv1 := (dst.max - tile.min) * k
	image_inst(c, tex, dst, {uv0.x, uv0.y, uv1.x, uv1.y}, tint, radii, render.FLAG_TILE | texture_flags(c, tex))
}

@(private)
image_inst :: proc(c: ^Context, tex: render.Texture, dst: Rect, src: [4]f32, tint: Color, radii: [4]f32, flags: u32) {
	xf, alpha, shape := cur(c)
	// t1 holds one image per batch: a different image starts a new batch (glyphs and shapes do not care)
	b := &c.batches[len(c.batches) - 1]
	if b.image != tex {
		if b.image != 0 && len(c.insts) > b.first {
			close_batch(c)
			start_batch(c)
			b = &c.batches[len(c.batches) - 1]
		}
		b.image = tex
	}
	col := tint
	col.a *= alpha
	inst := render.Rect_Inst{src = src, colors = {col, col, col, col}, soft = 1, use_tex = render.KIND_IMAGE, tex_size = 1, clip = shape, flags = flags | (c.circular ? render.FLAG_CIRCLE : 0)}
	if xf.simple {
		s, o := xf.m.a, Vec2{xf.m.e, xf.m.f}
		inst.dst = {dst.min.x * s + o.x, dst.min.y * s + o.y, dst.max.x * s + o.x, dst.max.y * s + o.y}
		inst.radii = radii * s
	} else {
		inst.dst = {dst.min.x, dst.min.y, dst.max.x, dst.max.y}
		inst.radii = radii
		inst.xform = gpu_xform(c, xf)
	}
	append(&c.insts, inst)
}

// Uploads new glyphs (text.odin), then draws the whole frame. Call once per frame after all primitives.
end_frame :: proc(c: ^Context) {
	if c.rec != nil { picture_end(c) }   // an unbalanced picture_begin: what was recorded is kept, not drawn
	for len(c.open_layers) > 0 { pop_layer(c) }   // unbalanced push_layer: composite what was drawn
	close_batch(c)
	text_upload(c)
	slug_upload(c)
	render.frame_submit(c.renderer, render.Frame_Data{
		insts = c.insts[:], batches = c.batches[:],
		xforms = len(c.xform_table) > 1 ? c.xform_table[:] : nil,
		clips = len(c.clip_table) > 1 ? c.clip_table[:] : nil,
		points = c.clip_points[:], layers = c.layers[:], ops = c.ops[:],
		grads = c.grads[:], replays = c.replays[:],
		slug_runs = c.slug_runs[:], slug_curves = c.slug.curves, slug_bands = c.slug.bands,
	})
}
