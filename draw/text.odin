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

// The device was recreated: the page textures kept their handles but lost their contents. The atlas still has every
// bitmap on the CPU, so the pages upload again whole at the end of the frame; recorded pictures stay valid.
@(private)
text_device_reset :: proc(c: ^Context) {
	for &p in c.glyphs.pages { p.version = 0 }
}

// The atlas page whose texture (in this context) is `tex`, -1 when none.
@(private)
glyph_page_of :: proc(c: ^Context, tex: render.Texture) -> i32 {
	if tex == 0 { return -1 }
	for p, i in c.glyphs.pages { if p.tex == tex { return i32(i) } }
	return -1
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

// A glyph with nothing to draw. A color glyph still being drawn (font.Glyph_Image.pending) shows in a later frame; a
// picture recorded without it is stale once it is ready.
@(private)
glyph_missing :: proc(c: ^Context, img: font.Glyph_Image, ready: u64) {
	if !img.pending || c.rec == nil || c.rec.glyphs_pending { return }
	c.rec.glyphs_pending = true
	c.rec.pending_ready = ready   // read before the lookups: a glyph finished since makes it differ
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
//
// While a picture is recorded the glyphs go into it with the atlas pages they use (font.Page_Ref): the picture is
// stale once one of those pages is reused or the rendering settings change. Text is rasterized for the picture's
// `raster_scale` times the slot's scale; positions are baked (subpixel snapped) only at the picture's own scale, else
// they stay in local units and the replay transforms them.
glyph_run :: proc(c: ^Context, size: f32, pos: Vec2, color: Color, glyphs: []font.Glyph_Pos) {
	if len(glyphs) == 0 || size <= 0 || c.fonts == nil { return }
	xf, alpha, shape := cur(c)
	col := color
	col.a *= alpha
	if col.a <= 0 { return }
	sf := affine_scale_factor(xf.m) * c.raster_scale   // while recording: the scale the picture is expected at
	// k: raster size / layout size. Scaled text gets bitmaps at its screen size: sharp, not a blurred or aliased
	// stretch of the 1x bitmap.
	k: f32 = 1
	if abs(sf - 1) > TEXT_RASTER_TOLERANCE { k = clamp(size * sf, 1, 4096) / size }
	raster := size * k
	// baked on the CPU: uniform scale + translation (in a picture only at its own scale: the screen is not known)
	baked := xf.simple && (c.rec == nil || k == 1)
	gpu: u32 = xf.simple ? 0 : gpu_xform(c, xf)
	noted := false   // a picture knows this slot's text is made of bitmaps (picture_note_text)
	sc, o := xf.m.a, Vec2{xf.m.e, xf.m.f}
	slug := c.fonts.settings.text_renderer == .Slug
	page_size := f32(c.fonts.settings.page_size)
	// the text color as color glyphs with text-color layers are drawn in it (sRGB; the alpha is the image's tint)
	enc :: #force_inline proc(v: f32) -> u8 { return u8(clamp(render.linear_to_srgb(clamp(v, 0, 1)) * 255 + 0.5, 0, 255)) }
	fg := [3]u8{enc(color.r), enc(color.g), enc(color.b)}
	ready := font.color_ready_generation(c.fonts)
	for g in glyphs {
		lx, ly := pos.x + g.x, pos.y + g.y
		if slug {
			// The outline is drawn as it is: at any scale or transform, the pen unrounded across, the baseline on a
			// whole pixel (of the screen when baked, else of the local space at the 1:1 scale) as the bitmaps' is.
			if sg := font.slug_glyph(c.fonts, g.face, g.id); sg.kind != .Atlas {
				if sg.kind == .Curves {
					if c.rec != nil { picture_note_slug(c.rec, sg) }
					if xf.simple {
						oy := ly * sc + o.y
						slug_inst(c, sg, lx * sc + o.x, math.round(oy), size * sc, col, 0, shape)
					} else {
						slug_inst(c, sg, lx, k == 1 ? math.round(ly) : ly, size, col, gpu, shape)
					}
				}
				continue
			}
		}
		if c.rec != nil && !noted { picture_note_text(c, xf.gpu, sf); noted = true }
		// where the bitmap goes: screen pixels (baked) or local units (GPU transform, or a picture's slot)
		dst: [4]f32
		sub := 0
		img: font.Glyph_Image
		if baked {
			if k == 1 {
				// layout and raster sizes agree: snap in local units, then scale (sc is within the tolerance of 1)
				ix: f32
				ix, sub = font.subpixel(c.fonts, lx)
				img = font.glyph_image(c.fonts, g.face, g.id, raster, sub, fg)
				if img.page < 0 { glyph_missing(c, img, ready); continue }
				x0 := ix + img.offset.x
				y0 := math.round(ly) + img.offset.y
				dst = {x0 * sc + o.x, y0 * sc + o.y, (x0 + img.size.x) * sc + o.x, (y0 + img.size.y) * sc + o.y}
			} else {
				// bitmap at screen size: snap the pen on the screen pixel grid
				ix: f32
				ix, sub = font.subpixel(c.fonts, lx * sc + o.x)
				img = font.glyph_image(c.fonts, g.face, g.id, raster, sub, fg)
				if img.page < 0 { glyph_missing(c, img, ready); continue }
				x0 := ix + img.offset.x
				y0 := math.round(ly * sc + o.y) + img.offset.y
				dst = {x0, y0, x0 + img.size.x, y0 + img.size.y}
			}
		} else if k == 1 {
			// local units snapped as when baked (a picture recorded at its own scale and replayed rotated draws
			// what direct drawing draws)
			ix: f32
			ix, sub = font.subpixel(c.fonts, lx)
			img = font.glyph_image(c.fonts, g.face, g.id, raster, sub, fg)
			if img.page < 0 { glyph_missing(c, img, ready); continue }
			x0 := ix + img.offset.x
			y0 := math.round(ly) + img.offset.y
			dst = {x0, y0, x0 + img.size.x, y0 + img.size.y}
		} else {
			img = font.glyph_image(c.fonts, g.face, g.id, raster, 0, fg)
			if img.page < 0 { glyph_missing(c, img, ready); continue }
			x0 := lx + img.offset.x / k
			y0 := ly + img.offset.y / k
			dst = {x0, y0, x0 + img.size.x / k, y0 + img.size.y / k}
		}
		tex := glyph_texture(c, int(img.page))
		if tex == 0 { continue }
		if c.rec != nil { picture_note_page(c.rec, img) }
		if img.color {
			// an image of the color page: image_inst applies the transform, so give it local units
			r := Rect{{dst[0], dst[1]}, {dst[2], dst[3]}}
			if baked { r = Rect{(r.min - o) / sc, (r.max - o) / sc} }
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