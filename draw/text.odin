package draw

import "core:math"
import "../font"
import "../render"

// Text: shaped glyph runs (font.shape) drawn from the font package's atlas pages. Coverage glyphs are KIND_GLYPH
// instances sampling a gray page (t0: a page change starts a batch); color glyphs (emoji) are KIND_IMAGE instances of a
// color page, like any image. Each context keeps one texture per page and uploads what changed before submitting.

// Glyphs are re-rasterized at the on-screen size when the transform scales text by more than this (either way);
// within it the bitmap is stretched (press "squish" animations must not fill the atlas with in-between sizes).
TEXT_RASTER_TOLERANCE :: 0.1

@(private)
Glyph_Tex :: struct {
	tex:     render.Texture,
	kind:    font.Page_Kind,
	size:    int,
	version: u64,    // atlas page version uploaded
}

// What a context keeps of the atlas.
Glyph_Pages :: struct {
	pages: [dynamic]Glyph_Tex,
}

@(private)
text_destroy :: proc(c: ^Context) {
	if c.fonts != nil { font.atlas_remove_user(c.fonts, c) }
	for p in c.glyphs.pages {
		if p.tex != 0 && p.tex != c.atlas { render.destroy_texture(c.renderer, p.tex) }
	}
	delete(c.glyphs.pages)
}

@(private)
text_begin_frame :: proc(c: ^Context) {
	if c.fonts != nil { font.atlas_begin_frame(c.fonts, c) }
}

// The texture of atlas page `page`, made on first use (the first gray page reuses the context's `atlas`).
@(private)
glyph_texture :: proc(c: ^Context, page: int) -> render.Texture {
	for len(c.glyphs.pages) <= page { append(&c.glyphs.pages, Glyph_Tex{}) }
	gt := &c.glyphs.pages[page]
	kind, size, _ := font.atlas_page_info(c.fonts, page)
	if gt.tex != 0 && gt.kind == kind && gt.size == size { return gt.tex }
	if gt.tex != 0 && gt.tex != c.atlas { render.destroy_texture(c.renderer, gt.tex) }
	gt^ = Glyph_Tex{kind = kind, size = size}
	switch kind {
	case .Gray:
		reuse := c.atlas != 0 && render.texture_size(c.renderer, c.atlas).x == size
		for other in c.glyphs.pages { if other.tex == c.atlas && other.tex != 0 { reuse = false } }
		gt.tex = reuse ? c.atlas : render.create_texture_r8(c.renderer, size)
	case .Color:
		gt.tex = render.create_texture_rgba(c.renderer, size, size, false)
	}
	return gt.tex
}

// Uploads the atlas changes this context has not seen. Called by end_frame.
@(private)
text_upload :: proc(c: ^Context) {
	if c.fonts == nil { return }
	n := font.atlas_page_count(c.fonts)
	for i in 0 ..< n {
		tex := glyph_texture(c, i)
		if tex == 0 { continue }
		gt := &c.glyphs.pages[i]
		gt.version = font.atlas_sync_page(c.fonts, i, gt.version, c, proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
			c := (^Context)(user)
			tex := c.glyphs.pages[page].tex
			switch kind {
			case .Gray: render.update_texture_r8(c.renderer, tex, x, y, w, h, pixels, stride)
			case .Color: render.update_texture_rgba(c.renderer, tex, x, y, w, h, pixels, stride)
			}
		})
	}
}

// The current batch samples `tex` as its coverage texture (t0); a different one starts a new batch.
@(private)
use_glyph_tex :: proc(c: ^Context, tex: render.Texture) {
	b := &c.batches[len(c.batches) - 1]
	if b.tex == tex { return }
	if len(c.insts) > b.first {
		close_batch(c)
		start_batch(c)
		b = &c.batches[len(c.batches) - 1]
	}
	b.tex = tex
}

// Draws `s` (shaped with the cascade's fallback and features, bidi resolved with the direction of its first strong
// character) with the pen starting at `pos` = (left, baseline). Returns the advance width (local units). Layout
// (advances, kerning) always uses `size`, so a transformed string measures as font.text_width says.
text :: proc(c: ^Context, id: font.Font_Id, size: f32, pos: Vec2, color: Color, s: string) -> f32 {
	return text_ex(c, id, size, pos, color, s, {})
}

// `text` with shaping options (direction, letter / word spacing).
text_ex :: proc(c: ^Context, id: font.Font_Id, size: f32, pos: Vec2, color: Color, s: string, opts: font.Shape_Options) -> f32 {
	if len(s) == 0 { return 0 }
	sh := font.shape(c.fonts, id, size, s, opts, context.temp_allocator)
	glyph_run(c, size, pos, color, sh.glyphs)
	return sh.width
}

// Draws glyphs shaped by font.shape (or any list of positioned glyphs) with the text origin at `pos` = (left, baseline).
// This is the one entry point a painter needs: positions come from the shaped run, faces from its fallback.
glyph_run :: proc(c: ^Context, size: f32, pos: Vec2, color: Color, glyphs: []font.Glyph_Pos) {
	if len(glyphs) == 0 || size <= 0 || c.fonts == nil { return }
	xf, alpha, shape := cur(c)
	col := color
	col.a *= alpha
	if col.a <= 0 { return }
	sf := affine_scale_factor(xf.m)
	// k: raster size / layout size. Scaled text gets bitmaps at its screen size: sharp, not a blurred or aliased
	// stretch of the 1x bitmap.
	k: f32 = 1
	if abs(sf - 1) > TEXT_RASTER_TOLERANCE { k = clamp(size * sf, 1, 4096) / size }
	raster := size * k
	gpu: u32 = xf.simple ? 0 : gpu_xform(c, xf)
	sc, o := xf.m.a, Vec2{xf.m.e, xf.m.f}
	page_size := f32(c.fonts.settings.page_size)
	for g in glyphs {
		lx, ly := pos.x + g.x, pos.y + g.y
		// where the bitmap goes: screen pixels (simple transforms) or local units (GPU transform)
		dst: [4]f32
		sub := 0
		img: font.Glyph_Image
		if xf.simple {
			if k == 1 {
				// layout and raster sizes agree: snap in local units, then scale (sc is within the tolerance of 1)
				ix: f32
				ix, sub = font.subpixel(c.fonts, lx)
				img = font.glyph_image(c.fonts, g.face, g.id, raster, sub)
				if img.page < 0 { continue }
				x0 := ix + img.offset.x
				y0 := math.round(ly) + img.offset.y
				dst = {x0 * sc + o.x, y0 * sc + o.y, (x0 + img.size.x) * sc + o.x, (y0 + img.size.y) * sc + o.y}
			} else {
				// bitmap at screen size: snap the pen on the screen pixel grid
				ix: f32
				ix, sub = font.subpixel(c.fonts, lx * sc + o.x)
				img = font.glyph_image(c.fonts, g.face, g.id, raster, sub)
				if img.page < 0 { continue }
				x0 := ix + img.offset.x
				y0 := math.round(ly * sc + o.y) + img.offset.y
				dst = {x0, y0, x0 + img.size.x, y0 + img.size.y}
			}
		} else {
			img = font.glyph_image(c.fonts, g.face, g.id, raster, 0)
			if img.page < 0 { continue }
			x0 := (k == 1 ? math.round(lx) : lx) + img.offset.x / k
			y0 := ly + img.offset.y / k
			dst = {x0, y0, x0 + img.size.x / k, y0 + img.size.y / k}
		}
		tex := glyph_texture(c, int(img.page))
		if tex == 0 { continue }
		if img.color {
			// an image of the color page: image_inst applies the transform, so give it local units
			r := Rect{{dst[0], dst[1]}, {dst[2], dst[3]}}
			if xf.simple { r = Rect{(r.min - o) / sc, (r.max - o) / sc} }
			image_inst(c, tex, r, img.uv, {1, 1, 1, color.a}, {}, texture_flags(c, tex))
			continue
		}
		use_glyph_tex(c, tex)
		append(&c.insts, render.Rect_Inst{
			dst = dst, src = img.uv, colors = {col, col, col, col}, use_tex = render.KIND_GLYPH, soft = 1,
			tex_size = page_size, xform = gpu, clip = shape,
		})
	}
}
