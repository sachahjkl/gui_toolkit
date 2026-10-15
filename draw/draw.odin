// Package draw: immediate-mode drawing on top of render + font.
//
// Primitives are appended to one instance list; a new GPU batch starts only when the clip rect changes.
// Colors are LINEAR rgba (use `srgb` / `hex` to author them). A scale+translate transform stack and an alpha stack
// are applied to everything drawn while they are pushed (used for press "squish" and fades).
package draw

import "core:math"
import "../font"
import "../render"

Color :: [4]f32
Vec2  :: [2]f32

Rect :: struct { min, max: Vec2 }

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

// 0xRRGGBBAA in sRGB
hex :: proc(v: u32) -> Color {
	return srgb(f32((v >> 24) & 255) / 255, f32((v >> 16) & 255) / 255, f32((v >> 8) & 255) / 255, f32(v & 255) / 255)
}

mix :: proc(a, b: Color, t: f32) -> Color { return a + (b - a) * t }

Xform :: struct { scale: f32, offset: Vec2 }   // p' = p * scale + offset

Context :: struct {
	fonts:    ^font.State,
	renderer: ^render.Renderer,
	atlas:    render.Texture,
	insts:    [dynamic]render.Rect_Inst,
	batches:  [dynamic]render.Batch,
	clips:    [dynamic]Rect,
	alphas:   [dynamic]f32,
	xforms:   [dynamic]Xform,
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
}

begin_frame :: proc(c: ^Context, size: Vec2) {
	clear(&c.insts); clear(&c.batches); clear(&c.clips); clear(&c.alphas); clear(&c.xforms)
	c.size = size
	append(&c.clips, Rect{{0, 0}, size})
	append(&c.alphas, 1)
	append(&c.xforms, Xform{1, {0, 0}})
	start_batch(c)
}

@(private)
start_batch :: proc(c: ^Context) {
	cl := c.clips[len(c.clips) - 1]
	append(&c.batches, render.Batch{clip = {cl.min.x, cl.min.y, cl.max.x, cl.max.y}, tex = c.atlas, first = len(c.insts)})
}

@(private)
close_batch :: proc(c: ^Context) {
	b := &c.batches[len(c.batches) - 1]
	b.count = len(c.insts) - b.first
}

push_clip :: proc(c: ^Context, r: Rect) {
	xf := c.xforms[len(c.xforms) - 1]
	t := Rect{r.min * xf.scale + xf.offset, r.max * xf.scale + xf.offset}
	t = rect_intersect(t, c.clips[len(c.clips) - 1])
	close_batch(c)
	append(&c.clips, t)
	start_batch(c)
}

pop_clip :: proc(c: ^Context) {
	close_batch(c)
	pop(&c.clips)
	start_batch(c)
}

push_alpha :: proc(c: ^Context, a: f32) { append(&c.alphas, c.alphas[len(c.alphas) - 1] * a) }
pop_alpha :: proc(c: ^Context) { pop(&c.alphas) }

// Scale everything drawn next by `s` around `center` (screen space).
push_scale :: proc(c: ^Context, center: Vec2, s: f32) {
	cur := c.xforms[len(c.xforms) - 1]
	// new(p) = (p*cur.scale + cur.offset - center) * s + center
	append(&c.xforms, Xform{cur.scale * s, (cur.offset - center) * s + center})
}
pop_xform :: proc(c: ^Context) { pop(&c.xforms) }

@(private)
cur :: proc(c: ^Context) -> (xf: Xform, alpha: f32) {
	return c.xforms[len(c.xforms) - 1], c.alphas[len(c.alphas) - 1]
}

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
	xf, alpha := cur(c)
	inst := render.Rect_Inst{
		dst = {r.min.x * xf.scale + xf.offset.x, r.min.y * xf.scale + xf.offset.y, r.max.x * xf.scale + xf.offset.x, r.max.y * xf.scale + xf.offset.y},
		colors = colors, radii = radii * xf.scale, border = border * xf.scale, soft = soft, use_tex = 0, tex_size = font.ATLAS_SIZE,
	}
	for &col in inst.colors { col.a *= alpha }
	append(&c.insts, inst)
}

// Draws `s` with the pen starting at `pos` = (left, baseline). Returns the advance width.
text :: proc(c: ^Context, id: font.Font_Id, size: f32, pos: Vec2, color: Color, s: string) -> f32 {
	xf, alpha := cur(c)
	col := color
	col.a *= alpha
	pen := Vec2{pos.x, math.round(pos.y)}
	prev: rune
	px := f32(u16(math.round(size)))
	for r in s {
		if prev != 0 { pen.x += font.kern(c.fonts, id, px, prev, r) }
		g := font.glyph(c.fonts, id, size, r)
		if g.size.x > 0 {
			x0 := math.round(pen.x) + g.offset.x
			y0 := pen.y + g.offset.y
			append(&c.insts, render.Rect_Inst{
				dst = {x0 * xf.scale + xf.offset.x, y0 * xf.scale + xf.offset.y, (x0 + g.size.x) * xf.scale + xf.offset.x, (y0 + g.size.y) * xf.scale + xf.offset.y},
				src = {g.uv.x, g.uv.y, g.uv.z, g.uv.w},
				colors = {col, col, col, col}, use_tex = 1, soft = 1, tex_size = font.ATLAS_SIZE,
			})
		}
		pen.x += g.advance
		prev = r
	}
	return pen.x - pos.x
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
	render.frame_submit(c.renderer, c.insts[:], c.batches[:])
}
