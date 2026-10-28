package render

import "vendor:directx/d3d11"

// Slug text (the shaders are slug.wgsl, written after rect.wgsl in one module; algorithm: Eric Lengyel's Slug,
// font/slug_ref/PINNED.md). Glyphs are ordinary Rect_Inst instances of KIND_SLUG in the frame's list, so order, clips,
// transforms, fades and pictures work as for every other primitive. Only the draw call differs: a batch with Slug text
// is drawn in pieces (Frame_Data.slug_runs, Replay.slug_runs), switching pipelines. Their data lives in two textures a
// draw context fills (font.slug_sync_page): one row per glyph page. This file holds the shared type and the
// frame_has_slug helper; the Direct3D side (slug_pipeline_*, the draw split, the glyph textures) is in slug_d3d.odin,
// the wgpu side in wgpu_frame.odin.

SLUG_TEXTURE_WIDTH :: 4096   // both textures; font.SLUG_TEXTURE_WIDTH

Slug_Pipeline :: struct {
	vs:     ^d3d11.IVertexShader,
	ps:     ^d3d11.IPixelShader,
	layout: ^d3d11.IInputLayout,
	on:     bool,   // frame_submit: the Slug shaders are the bound ones
	ready:  bool,   // the textures of the frame are bound
	failed: bool,   // the device refused the shaders: no Slug text this run (until the device is recreated)
}

// Whether the frame draws any Slug instance (immediate or in a replayed picture). Shared (both backends).
@(private)
frame_has_slug :: proc(f: Frame_Data) -> bool {
	if len(f.slug_runs) > 0 { return true }
	for rp in f.replays { if len(rp.slug_runs) > 0 { return true } }
	return false
}
