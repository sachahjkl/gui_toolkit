package draw

import "../font"
import "../render"

// Text drawn by the Slug algorithm (font.Text_Renderer.Slug): a glyph is one instance of KIND_SLUG whose shaders read the
// glyph's curves and bands from two textures (the font package's glyph pages, one row each), so text is sharp under any
// scale or transform with no bitmaps. The instances are in the frame's list like all others; `slug_runs` tells the
// renderer which ones to draw with the Slug shaders. See render/slug.wgsl and font/slug_cache.odin.

// What a context keeps of the font's Slug pages: the two textures (a row per page, grown by doubling) and the version of
// each page it uploaded.
Slug_GPU :: struct {
	curves, bands: render.Texture,
	rows:          int,
	versions:      [dynamic]u64,
}

SLUG_MIN_ROWS :: 16

@(private)
slug_gpu_destroy :: proc(c: ^Context) {
	if c.slug.curves != 0 { render.destroy_texture(c.renderer, c.slug.curves) }
	if c.slug.bands != 0 { render.destroy_texture(c.renderer, c.slug.bands) }
	delete(c.slug.versions)
	c.slug = {}
}

// The device was recreated: the textures kept their handles and sizes but lost their contents.
@(private)
slug_gpu_device_reset :: proc(c: ^Context) {
	for &v in c.slug.versions { v = 0 }
}

// Uploads the pages that changed since this context last looked (growing the textures when there are more pages than
// rows). Called by end_frame.
@(private)
slug_upload :: proc(c: ^Context) {
	if c.fonts == nil { return }
	n := font.slug_page_count(c.fonts)
	if n == 0 { return }
	g := &c.slug
	if n > g.rows {
		rows := SLUG_MIN_ROWS
		for rows < n { rows *= 2 }
		rows = min(rows, render.max_texture_size(c.renderer))
		if rows < n { return }
		if g.curves != 0 { render.destroy_texture(c.renderer, g.curves) }
		if g.bands != 0 { render.destroy_texture(c.renderer, g.bands) }
		g.curves, g.bands = render.create_slug_textures(c.renderer, rows)
		g.rows = g.curves != 0 ? rows : 0
		clear(&g.versions)   // empty textures: every page uploads again
	}
	if g.curves == 0 { return }
	for len(g.versions) < n { append(&g.versions, 0) }
	for i in 0 ..< n {
		g.versions[i] = font.slug_sync_page(c.fonts, i, g.versions[i], c, proc(user: rawptr, page: int, curves: [][4]f16, bands: [][2]u16) {
			c := (^Context)(user)
			render.update_slug_page(c.renderer, c.slug.curves, c.slug.bands, page, curves, bands)
		})
	}
}

// Records instance `n` (just appended) as a Slug instance for the renderer.
@(private)
slug_note_run :: proc(c: ^Context) {
	i := len(c.insts) - 1
	if k := len(c.slug_runs); k > 0 && c.slug_runs[k - 1][0] + c.slug_runs[k - 1][1] == i {
		c.slug_runs[k - 1][1] += 1
	} else {
		append(&c.slug_runs, [2]int{i, 1})
	}
}

// A picture that drew glyph `g` depends on its page as it was then (like picture_note_page for the atlas).
@(private)
picture_note_slug :: proc(pic: ^Picture, g: font.Slug_Glyph) {
	pic.text = true
	for r in pic.slug_pages {
		if r.page != g.page { continue }
		if r.epoch != g.epoch { pic.pages_broken = true }   // the page was reused under the recording
		return
	}
	append(&pic.slug_pages, font.Page_Ref{page = g.page, epoch = g.epoch})
}

// Appends the instance of one glyph. (ox, oy): the pen on the baseline, size: pixels per em, in the units of the
// instance (screen pixels when baked, local units under `xform`).
@(private)
slug_inst :: proc(c: ^Context, g: font.Slug_Glyph, ox, oy, size: f32, col: Color, xform, shape: u32) {
	b := g.bbox
	inst := render.Rect_Inst{
		dst = {ox + b[0] * size, oy - b[3] * size, ox + b[2] * size, oy - b[1] * size}, src = b,
		colors = {col, col, col, col}, radii = g.transform, soft = 1, use_tex = render.KIND_SLUG, tex_size = 1,
		xform = xform, clip = shape,
		flags = u32(g.band_max.x) | u32(g.band_max.y) << 8, aux = u32(g.loc.x) | u32(g.loc.y) << 16,
	}
	append(&c.insts, inst)
	slug_note_run(c)
}
