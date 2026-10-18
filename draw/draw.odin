// Package draw: immediate-mode drawing on top of render + font.
//
// Primitives are appended to one instance list; a new GPU batch starts only when the clip rect changes or when an
// image needs a different texture than the batch's (glyphs and shapes never break a batch).
// Colors are LINEAR rgba (use `srgb` / `hex` to author them). A transform stack (2D affine, see `Affine`) and an alpha
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
	size:     Vec2,
	generation: int,
}

init :: proc(c: ^Context, r: ^render.Renderer, fonts: ^font.State) {
	c.renderer = r
	c.fonts = fonts
	c.atlas = render.create_texture_r8(r, font.ATLAS_SIZE)
	c.generation = fonts.generation
}

destroy :: proc(c: ^Context) {
	delete(c.insts); delete(c.batches); delete(c.clips); delete(c.alphas); delete(c.xforms)
	delete(c.xform_table); delete(c.clip_table)
}

begin_frame :: proc(c: ^Context, size: Vec2) {
	clear(&c.insts); clear(&c.batches); clear(&c.clips); clear(&c.alphas); clear(&c.xforms)
	clear(&c.xform_table); clear(&c.clip_table)
	c.size = size
	append(&c.clips, Clip{rect = {{0, 0}, size}})
	append(&c.alphas, 1)
	append(&c.xforms, Transform{m = AFFINE_IDENTITY, simple = true})
	append(&c.xform_table, render.Xform_Data{})
	append(&c.clip_table, render.Clip_Data{})
	start_batch(c)
}

@(private)
start_batch :: proc(c: ^Context) {
	cl := c.clips[len(c.clips) - 1].rect
	append(&c.batches, render.Batch{clip = {cl.min.x, cl.min.y, cl.max.x, cl.max.y}, tex = c.atlas, first = len(c.insts)})
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
	parent := c.clips[len(c.clips) - 1]
	inv, ok := affine_inverse(xf.m)
	// 1 px of slack: the scissor is integer, the shape's antialiased edge is not
	scissor := rect_intersect(rect_pad(affine_bounds(xf.m, r), 1), parent.rect)
	if !ok { scissor = {} }
	half := rect_size(r) * 0.5
	append(&c.clip_table, render.Clip_Data{
		inv = {inv.a, inv.b, inv.c, inv.d, inv.e, inv.f}, px = affine_scale_factor(xf.m), parent = parent.shape,
		center = rect_center(r), half_size = {max(half.x, 0), max(half.y, 0)}, radii = radii,
	})
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

// Everything drawn next goes through `m` first, then through the transforms already pushed (CSS nesting: push the
// element's `transform` with its transform-origin folded in, see affine_around). Pop with pop_transform.
push_transform :: proc(c: ^Context, m: Affine) {
	n := affine_mul(c.xforms[len(c.xforms) - 1].m, m)
	append(&c.xforms, Transform{m = n, simple = affine_is_scale_translate(n)})
}
pop_transform :: proc(c: ^Context) { pop(&c.xforms) }

// Scale everything drawn next by `s` around `center` (screen space, i.e. applied after the current transform).
push_scale :: proc(c: ^Context, center: Vec2, s: f32) {
	m := c.xforms[len(c.xforms) - 1].m
	// new(p) = (cur(p) - center) * s + center
	n := Affine{m.a * s, m.b * s, m.c * s, m.d * s, (m.e - center.x) * s + center.x, (m.f - center.y) * s + center.y}
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

// Per-corner colors (gradients) and radii; corner order: top-left, bottom-left, top-right, bottom-right.
rect_corners :: proc(c: ^Context, r: Rect, colors: [4]Color, radii: [4]f32, border: f32 = 0, soft: f32 = 1) {
	xf, alpha, shape := cur(c)
	inst := render.Rect_Inst{colors = colors, soft = soft, use_tex = render.KIND_SHAPE, tex_size = font.ATLAS_SIZE, clip = shape}
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

// Glyphs are re-rasterized at the on-screen size when the transform scales text by more than this (either way);
// within it the bitmap is stretched (press "squish" animations must not fill the atlas with in-between sizes).
TEXT_RASTER_TOLERANCE :: 0.1

// Draws `s` with the pen starting at `pos` = (left, baseline). Returns the advance width (local units).
// Layout (advances, kerning) always uses `size`, so a transformed string measures as font.text_width says.
text :: proc(c: ^Context, id: font.Font_Id, size: f32, pos: Vec2, color: Color, s: string) -> f32 {
	xf, alpha, shape := cur(c)
	col := color
	col.a *= alpha
	pen := Vec2{pos.x, math.round(pos.y)}
	prev: rune
	px := f32(u16(math.round(size)))
	// k: raster size / layout size. Scaled text gets bitmaps at its screen size: sharp, not a blurred or aliased
	// stretch of the 1x bitmap.
	k: f32 = 1
	if sf := affine_scale_factor(xf.m); px >= 1 && abs(sf - 1) > TEXT_RASTER_TOLERANCE {
		k = clamp(math.round(px * sf), 1, 512) / px
	}
	gpu: u32 = xf.simple ? 0 : gpu_xform(c, xf)
	for r in s {
		if prev != 0 { pen.x += font.kern(c.fonts, id, px, prev, r) }
		g := font.glyph(c.fonts, id, size, r)
		gr := k == 1 ? g : font.glyph(c.fonts, id, px * k, r)
		if gr.size.x > 0 {
			inst := render.Rect_Inst{
				src = {gr.uv.x, gr.uv.y, gr.uv.z, gr.uv.w},
				colors = {col, col, col, col}, use_tex = render.KIND_GLYPH, soft = 1, tex_size = font.ATLAS_SIZE,
				xform = gpu, clip = shape,
			}
			if xf.simple {
				sc, o := xf.m.a, Vec2{xf.m.e, xf.m.f}
				if k == 1 {
					x0 := math.round(pen.x) + g.offset.x
					y0 := pen.y + g.offset.y
					inst.dst = {x0 * sc + o.x, y0 * sc + o.y, (x0 + g.size.x) * sc + o.x, (y0 + g.size.y) * sc + o.y}
				} else {
					// bitmap at screen size: snap the pen on the screen pixel grid
					x0 := math.round(pen.x * sc + o.x) + gr.offset.x
					y0 := math.round(pen.y * sc + o.y) + gr.offset.y
					inst.dst = {x0, y0, x0 + gr.size.x, y0 + gr.size.y}
				}
			} else {
				x0 := (k == 1 ? math.round(pen.x) : pen.x) + gr.offset.x / k
				y0 := pen.y + gr.offset.y / k
				inst.dst = {x0, y0, x0 + gr.size.x / k, y0 + gr.size.y / k}
			}
			append(&c.insts, inst)
		}
		pen.x += g.advance
		prev = r
	}
	return pen.x - pos.x
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
	image_inst(c, tex, dst, {s.min.x, s.min.y, s.max.x, s.max.y}, tint, radii, 0)
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
	image_inst(c, tex, dst, {uv0.x, uv0.y, uv1.x, uv1.y}, tint, radii, render.FLAG_TILE)
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
	inst := render.Rect_Inst{src = src, colors = {col, col, col, col}, soft = 1, use_tex = render.KIND_IMAGE, tex_size = 1, clip = shape, flags = flags}
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

// Uploads new glyphs, then draws the whole frame. Call once per frame after all primitives.
end_frame :: proc(c: ^Context) {
	close_batch(c)
	f := c.fonts
	for u in f.pending {
		render.update_texture_r8(c.renderer, c.atlas, u.x, u.y, u.w, u.h, f.pending_pixels[u.offset:u.offset + u.w * u.h], u.w)
	}
	clear(&f.pending)
	clear(&f.pending_pixels)
	xforms := len(c.xform_table) > 1 ? c.xform_table[:] : nil
	clips := len(c.clip_table) > 1 ? c.clip_table[:] : nil
	render.frame_submit(c.renderer, c.insts[:], c.batches[:], xforms, clips)
}
