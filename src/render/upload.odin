package render

// A picture's pixels uploaded to a texture over several frames (docs/rendering.md, "Staged upload";
// src/md/features/staged-upload.md): a band of rows at a time, as many bands as a frame's time budget holds, its mip
// chain made once after the last band. A 200 MB photo's upload (its premultiplication, the copy the driver makes, its
// mips) took one frame of the interface's thread; spread, no frame waits more than the budget and a band.
//
//   u, ok := render.upload_begin(r, pixels, w, h)          // the texture made; nothing written yet
//   ...each frame, on the interface's thread:
//   if render.upload_step(r, &u) { show(u.texture) }       // done: every row written, the mips to come before its draw
//
// The texture must not be drawn before upload_step says done: its rows past u.row are undefined (Direct3D) or zero
// (WebGPU). `pixels` stay the caller's, unchanged, until then.

import "core:time"

// What a frame spends on uploads when the caller says nothing: well under a 120 Hz frame's 8 ms.
UPLOAD_BUDGET_DEFAULT :: 2 * time.Millisecond
// The bytes of a band: the unit an upload_step writes (one at least per call, so an upload always moves).
UPLOAD_BAND_BYTES :: 1 << 20

// An upload in progress. Its fields are the renderer's but `texture` and `row` (how far it went) may be read.
Upload :: struct {
	texture: Texture,
	pixels:  []u8,   // the caller's, straight RGBA8
	w, h:    int,
	stride:  int,    // bytes from a row to the next
	row:     int,    // the rows written
	mips:    bool,
	generation: u64, // the device its rows were written on: a device recovered since lost them
}

// Makes the texture of a w x h picture (mipmapped when `mips`) for an upload in steps. ok is false when the renderer
// makes no texture of that size (past max_texture_size). `stride` 0: w * 4.
upload_begin :: proc(r: ^Renderer, pixels: []u8, w, h: int, stride := 0, mips := true) -> (u: Upload, ok: bool) {
	pitch := stride > 0 ? stride : w * 4
	if w <= 0 || h <= 0 || len(pixels) < pitch * (h - 1) + w * 4 { return }
	t := create_texture_rgba(r, w, h, mips)
	if t == 0 { return }
	// (every row will be written before a draw: Direct3D's zeroing of a texture never written, a whole upload of zeros
	// in one frame, is not needed)
	r.textures[int(t)].unfilled = false
	return {texture = t, pixels = pixels, w = w, h = h, stride = pitch, mips = mips, generation = r.device_generation}, true
}

// Writes bands of rows until `budget` is spent (one band at least), on the interface's thread. True once every row is
// written: the texture may be drawn (its mips are made before its first draw).
upload_step :: proc(r: ^Renderer, u: ^Upload, budget := UPLOAD_BUDGET_DEFAULT) -> (done: bool) {
	if u.texture == 0 || u.row >= u.h { return true }
	if u.generation != r.device_generation {
		// (the device was recovered: the texture came back empty, the bands written are gone; again from the top, with
		// no zeroing as at the start)
		u.row, u.generation = 0, r.device_generation
		if int(u.texture) < len(r.textures) { r.textures[int(u.texture)].unfilled = false }
	}
	band := max(1, UPLOAD_BAND_BYTES / (u.w * 4))
	began := time.tick_now()
	for u.row < u.h {
		n := min(band, u.h - u.row)
		update_texture_rgba(r, u.texture, 0, u.row, u.w, n, u.pixels[u.row * u.stride:], u.stride)
		u.row += n
		// (the mips are made once, from the whole picture: a band a frame would make them again each frame)
		if u.row < u.h && int(u.texture) < len(r.textures) { r.textures[int(u.texture)].mips_dirty = false }
		if time.tick_since(began) >= budget { break }
	}
	return u.row >= u.h
}

// An upload given up: its texture destroyed. The pixels are the caller's again.
upload_cancel :: proc(r: ^Renderer, u: ^Upload) {
	if u.texture != 0 { destroy_texture(r, u.texture) }
	u^ = {}
}
