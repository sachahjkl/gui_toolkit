package render

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import base "../base"
import "../platform"

// The renderer has two backends behind one interface, chosen when the program is compiled:
//   -define:TOOLKIT_RENDER=d3d11   Direct3D 11 (render.odin, frame.odin; the HLSL naga writes from the WGSL)   the default on Windows
//   -define:TOOLKIT_RENDER=wgpu    WebGPU through wgpu-native (wgpu_*.odin; the WGSL as it is)
// The procedures below are the ones whose work depends on the backend; each calls its d3d_* or wgpu_* implementation.
// Only the chosen one is compiled into the program (`when` is resolved at compile time). Everything else in this
// package (the frame description, texture pools, retained heap bookkeeping, presentation statistics, text rendering
// settings) is shared.
//
// Direct3D 11 is a Windows-only backend (render.odin and the files it needs are built #+build windows). On every other
// system the only backend is wgpu, so TOOLKIT_RENDER is ignored there and USE_WGPU is forced on: a program compiled for
// Linux renders through wgpu-native (Vulkan) from the neutral surface handles the platform package hands over
// (platform.Surface_Handles), with no Direct3D, DXGI or Win32 type in the public API.

RENDER_BACKEND :: #config(TOOLKIT_RENDER, "d3d11") when SYSTEM_DIRECT3D else "wgpu"
USE_WGPU :: RENDER_BACKEND == "wgpu"
#assert(RENDER_BACKEND == "d3d11" || RENDER_BACKEND == "wgpu", "TOOLKIT_RENDER must be d3d11 or wgpu")
#assert(SYSTEM_DIRECT3D || USE_WGPU, "the Direct3D 11 backend is Windows only; other systems use wgpu")

// The backend this program was built with: "d3d11" or "wgpu".
backend_name :: proc() -> string { return RENDER_BACKEND }

// Whether the images of one batch must all repeat or all clamp (Batch.image_wrap): on wgpu's GL backend, where GLSL
// samples a texture through one sampler only, so t1's sampler is the batch's. A batch builder (gt:draw) starts a new
// batch where the mode changes. Elsewhere the shader picks the sampler per instance, and batches stay as they are.
image_wrap_splits_batches :: proc(r: ^Renderer) -> bool {
	when USE_WGPU { return r != nil && r.wg.gl } else { return false }
}

// Opens the renderer on a window from the neutral native handles the platform package fills (platform.Surface_Handles,
// from platform.native_surface_handles(window)): the HWND on Windows, the Wayland or XCB handles on Linux. An offscreen
// window has no handles (backend .None): use init_offscreen instead. `transparent`: the window shows through where the
// frame has alpha < 1 (open the window translucent too). `space`: what the frame blends in.
// False: no renderer, nothing of it left but why (init_failure, init_failure_text).
init :: proc(r: ^Renderer, surface: platform.Surface_Handles, size: [2]int, transparent := false, space := Blend_Space.Linear) -> bool {
	r.failure = {}
	ok: bool
	when USE_WGPU { ok = wgpu_init(r, surface, size, transparent, space) } else { ok = d3d_init(r, surface, size, transparent, space) }
	if ok { r.id = sync.atomic_add(&renderer_ids, 1) + 1 } else { init_release(r) }
	return ok
}

// What a failed init made goes; why it failed stays. (A failure no step named is a failure all the same.)
@(private)
init_release :: proc(r: ^Renderer) {
	failure := r.failure
	if failure.error == .None { failure.error = .Failed }
	when USE_WGPU { wgpu_destroy(r) } else { d3d_destroy(r) }
	r.failure = failure
}

// init from a window directly: the common case, equivalent to init(r, platform.native_surface_handles(w), ...).
init_window :: proc(r: ^Renderer, w: ^platform.Window, size: [2]int, transparent := false, space := Blend_Space.Linear) -> bool {
	return init(r, platform.native_surface_handles(w), size, transparent, space)
}

@(private) renderer_ids: u64

// A number no other renderer of this process has had (a renderer destroyed and made again at the same address is another one):
// what caches of GPU objects keyed by renderer compare, together with `device_generation` (a device recovered keeps the id and
// loses its textures' contents).
renderer_id :: proc(r: ^Renderer) -> u64 { return r.id }

destroy :: proc(r: ^Renderer) {
	when USE_WGPU { wgpu_destroy(r) } else { d3d_destroy(r) }
	when DAMAGE_CHECK { damage_check_report() }
}

// A renderer that draws into an image of `size` (tests, image export). `warp`: the software rasterizer. `half_float`: the
// frame is stored in half floats, as a translucent window's in linear light is (the same values a window in that format
// holds, for a test to read with read_pixels_float); else in 8 bits a channel.
init_offscreen :: proc(r: ^Renderer, size: [2]int, warp := false, space := Blend_Space.Linear, half_float := false) -> bool {
	r.failure = {}
	r.half_float_offscreen = half_float
	ok: bool
	when USE_WGPU { ok = wgpu_init_offscreen(r, size, warp, space) } else { ok = d3d_init_offscreen(r, size, warp, space) }
	if ok { r.id = sync.atomic_add(&renderer_ids, 1) + 1 } else { init_release(r) }
	return ok
}

set_blend_space :: proc(r: ^Renderer, space: Blend_Space) {
	when USE_WGPU { wgpu_set_blend_space(r, space) } else { d3d_set_blend_space(r, space) }
}

// Whether the frame is stored in half floats (a translucent window in linear light, init_offscreen's `half_float`).
frame_is_half :: proc(r: ^Renderer) -> bool { return r.frame_format == .R16G16B16A16_FLOAT }

// The bytes a texel of the frame takes: 8 in half floats, 4 in bytes.
frame_texel_bytes :: proc(r: ^Renderer) -> int { return frame_is_half(r) ? 8 : 4 }

// The offscreen image (init_offscreen) after the last frame: RGBA8, `size.x * size.y * 4` bytes, premultiplied, as an
// 8-bit frame holds it (its colour sRGB-encoded in a linear blend space). A half-float frame is encoded so, each value
// clamped to [0, 1] as an 8-bit target clamps it (read_pixels_float gives its values as they are). nil: not offscreen.
read_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	raw := read_frame_raw(r, context.allocator)
	if raw == nil { return nil }
	defer delete(raw)
	n := r.size.x * r.size.y
	out := make([]u8, n * 4, allocator)
	if frame_is_half(r) {
		half_texels_to_rgba8(out, raw, n, r.space)
	} else {
		swap_red_blue(raw_data(out), raw_data(raw), n)   // (stored B8G8R8A8)
	}
	return out
}

// The offscreen image as read_pixels gives it, but in B, G, R, A order: an 8-bit frame's texels as the card stores them,
// with no copy and no pass over them (a film writes them to its encoder as they come). A half-float frame is encoded as
// read_pixels encodes it. nil: not offscreen.
read_pixels_bgra :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	raw := read_frame_raw(r, allocator)
	if raw == nil || !frame_is_half(r) { return raw }
	defer delete(raw, allocator)
	n := r.size.x * r.size.y
	out := make([]u8, n * 4, allocator)
	half_texels_to_rgba8(out, raw, n, r.space)
	for i in 0 ..< n { out[i * 4], out[i * 4 + 2] = out[i * 4 + 2], out[i * 4] }
	return out
}

// The offscreen image's values as they are stored: RGBA, four f32 a pixel, premultiplied. A half-float frame: its halves,
// unclamped (a value past [0, 1], an infinity or a NaN is kept); an 8-bit frame: its bytes / 255. nil: not offscreen.
read_pixels_float :: proc(r: ^Renderer, allocator := context.allocator) -> [][4]f32 {
	raw := read_frame_raw(r, context.allocator)
	if raw == nil { return nil }
	defer delete(raw)
	n := r.size.x * r.size.y
	out := make([][4]f32, n, allocator)
	if frame_is_half(r) {
		h := ([^]u16)(raw_data(raw))
		for i in 0 ..< n { for k in 0 ..< 4 { out[i][k] = f32(transmute(f16)h[i * 4 + k]) } }
	} else {
		for i in 0 ..< n {
			b := raw[i * 4:][:4]
			out[i] = {f32(b[2]) / 255, f32(b[1]) / 255, f32(b[0]) / 255, f32(b[3]) / 255}
		}
	}
	return out
}

// The offscreen frame's texels as they are stored, rows packed (frame_texel_bytes each).
@(private)
read_frame_raw :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	when USE_WGPU { return wgpu_read_frame_raw(r, allocator) } else { return d3d_read_frame_raw(r, allocator) }
}

// Resize the renderer to `size`. For a windowed renderer this resizes the swap chain (Direct3D) or reconfigures the
// surface (wgpu); for an offscreen renderer (init_offscreen, a headless window) it remakes the offscreen target, so the
// same call serves both and a headless app resizes its window the usual way.
resize :: proc(r: ^Renderer, size: [2]int) {
	if size.x <= 0 || size.y <= 0 || size == r.size { return }
	if is_offscreen(r) { _ = resize_offscreen(r, size); return }
	when USE_WGPU { wgpu_resize(r, size) } else { d3d_resize(r, size) }
}

// Resize an offscreen renderer (init_offscreen): the target is remade at `size`, whatever the backend. A no-op for a
// renderer with a window (use `resize`). False: the new target could not be made (the old one is kept).
resize_offscreen :: proc(r: ^Renderer, size: [2]int) -> bool {
	if size.x <= 0 || size.y <= 0 || size == r.size { return size == r.size }
	when USE_WGPU { return wgpu_resize_offscreen(r, size) } else { return d3d_resize_offscreen(r, size) }
}

// Whether the renderer draws into an offscreen target (init_offscreen), not a window's swap chain or surface.
is_offscreen :: proc(r: ^Renderer) -> bool {
	when USE_WGPU { return r.surface_handles.backend == .None && r.wg.device != nil } else { return r.swapchain == nil && r.offscreen != nil }
}

// Most frames the swap chain may queue: 1 (the default) keeps the time from input to screen at one frame; 2 or more let
// a frame be presented while the previous one is still on its way to the screen (a resize, a burst of frames), at the
// cost of input latency. False: the backend cannot (or has no window). It can be raised and lowered again at will: the surplus
// the system leaves in the latency object when it is lowered is taken back (wait_frame_slot, wait_for_frame).
set_max_frame_latency :: proc(r: ^Renderer, n: int) -> bool {
	when USE_WGPU { return wgpu_set_max_frame_latency(r, n) } else { return d3d_set_max_frame_latency(r, n) }
}

// One surface size while the window resizes (see d3d set_fixed_surface): never scaled, clipped by the window.
set_fixed_surface :: proc(r: ^Renderer, max_size: [2]int) -> bool {
	when USE_WGPU { return false } else { return d3d_set_fixed_surface(r, max_size) }
}

create_texture_r8 :: proc(r: ^Renderer, size: int) -> Texture {
	when USE_WGPU { return wgpu_create_texture_r8(r, size) } else { return d3d_create_texture_r8(r, size) }
}

update_texture_r8 :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, pitch: int) {
	texture_written(r, t)
	when USE_WGPU { wgpu_update_texture_r8(r, t, x, y, w, h, pixels, pitch) } else { d3d_update_texture_r8(r, t, x, y, w, h, pixels, pitch) }
}

max_texture_size :: proc(r: ^Renderer) -> int {
	when USE_WGPU { return wgpu_max_texture_size(r) } else { return d3d_max_texture_size(r) }
}

create_texture_rgba :: proc(r: ^Renderer, w, h: int, mips := true) -> Texture {
	when USE_WGPU { return wgpu_create_texture_rgba(r, w, h, mips) } else { return d3d_create_texture_rgba(r, w, h, mips) }
}

update_texture_rgba :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) {
	texture_written(r, t)
	when USE_WGPU { wgpu_update_texture_rgba(r, t, x, y, w, h, pixels, stride) } else { d3d_update_texture_rgba(r, t, x, y, w, h, pixels, stride) }
}

// A texture of raw 8-bit data for the shaders of draw.app_shader (a normal map, a height map, a mask): sampled as 0..1 floats,
// with no sRGB decoding and no premultiplication, whatever the blend space. Contents start at zero. 0: out of range or refused.
create_texture_data :: proc(r: ^Renderer, w, h: int, format := Data_Format.RGBA8, mips := true) -> Texture {
	when USE_WGPU { return wgpu_create_texture_data(r, w, h, format, mips) } else { return d3d_create_texture_data(r, w, h, format, mips) }
}

// Uploads a w x h block at (x, y) of a data texture: `pixels` are its texels as they are (4 bytes each for RGBA8, 1 for R8);
// `stride` = bytes per row (0: tight).
update_texture_data :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) {
	texture_written(r, t)
	when USE_WGPU { wgpu_update_texture_data(r, t, x, y, w, h, pixels, stride) } else { d3d_update_texture_data(r, t, x, y, w, h, pixels, stride) }
}

destroy_texture :: proc(r: ^Renderer, t: Texture) {
	when USE_WGPU { wgpu_destroy_texture(r, t) } else { d3d_destroy_texture(r, t) }
}

frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	r.damage.have_region = false
	r.damage.frame_clear = clear
	when DAMAGE_CHECK { r.damage.mode = .On }
	when USE_WGPU { wgpu_frame_begin(r, clear) } else { d3d_frame_begin(r, clear) }
}

// What wait_for_frame waits at most, by default.
FRAME_WAIT_TIMEOUT_MS :: 100

// Whether a present of the surface in use may wait for the compositor (Fifo): a window must then present only once the
// compositor showed its last picture (platform.frame_shown_pending), or its thread may wait for ever. A mailbox, a
// tearing present and Direct3D's flip model never wait so.
present_may_block :: proc(r: ^Renderer) -> bool {
	when USE_WGPU { return r.wg.present_mode == .Fifo || r.wg.present_mode == .FifoRelaxed } else { return false }
}

wait_for_frame :: proc(r: ^Renderer, timeout_ms := FRAME_WAIT_TIMEOUT_MS) -> bool {
	when USE_WGPU { return wgpu_wait_for_frame(r, timeout_ms) } else { return d3d_wait_for_frame(r, timeout_ms) }
}

// Waits until the swap chain can take the next frame, `timeout_ms` at most, taking the window's keyboard and mouse input
// meanwhile (platform.wait_handle; `until_press`: a key or a button ends the wait). 0: no wait, only whether it can now.
// True: the frame holds its slot until its present (a frame that presents nothing keeps it for the next one). Call it before
// the frame reads its input. Without a latency object (Linux, offscreen, no LOW_LATENCY) it returns true at once.
// The renderer counts the slots taken here: a present without one leaves a count in Direct3D's latency object, which the
// next wait takes back (src/md/infrastructure/frame-latency-object.md). A wait the renderer does not see would break that
// count, so the object's handle is not given out.
wait_frame_slot :: proc(r: ^Renderer, w: ^platform.Window, timeout_ms := FRAME_WAIT_TIMEOUT_MS, until_press := false) -> bool {
	when USE_WGPU { h := r.wg.latency.timer } else { h := r.latency_handle }
	return latency_take(&r.present, h, timeout_ms, w, until_press)
}

frame_submit :: proc(r: ^Renderer, f: Frame_Data) {
	defer readback_frame_done(f)
	when DAMAGE_CHECK {
		if !r.damage.building { damage_check_submit(r, f); return }
	}
	damage_backend_submit(r, f)
	if r.damage.have_region && r.damage.verify { damage_verify_frame(r, f) }
}

frame_end :: proc(r: ^Renderer, vsync := true) {
	r.present.drawn = time.tick_now()
	when !USE_WGPU {
		d3d_damage_finish_clear(r)
		if r.capture.requested { capture_copy(r) }   // before the present: a flip chain does not keep the frame
	}
	when USE_WGPU { wgpu_frame_end(r, vsync) } else { d3d_frame_end(r, vsync) }
	r.damage.building, r.damage.skip_present = false, false
	if !r.first_present_noted && r.present.presents > 0 {
		r.first_present_noted = true
		first := base.start_mark("render: first frame shown")   // (the process's first: a later window prints no steps)
		if render_trace() {
			fmt.eprintfln("render: first present %.0f ms after the process started (backend %s)", base.start_ms(), RENDER_BACKEND)
			if first { base.start_print() }
		}
	}
}

// TOOLKIT_RENDER_TRACE=1 (or TOOLKIT_WGPU_TRACE=1) in the environment: timings of the renderer on stderr.
@(private)
render_trace :: proc() -> bool {
	@(static) state: int   // 0: unknown, 1: off, 2: on (the process's: atomic, every thread reads the same environment)
	s := sync.atomic_load(&state)
	if s == 0 {
		s = os.get_env("TOOLKIT_RENDER_TRACE", context.temp_allocator) != "" || os.get_env("TOOLKIT_WGPU_TRACE", context.temp_allocator) != "" ? 2 : 1
		sync.atomic_store(&state, s)
	}
	return s == 2
}

heap_write :: proc(r: ^Renderer, kind: Heap_Kind, offset: int, data: rawptr, n: int) {
	when USE_WGPU { wgpu_heap_write(r, kind, offset, data, n) } else { d3d_heap_write(r, kind, offset, data, n) }
}

recover :: proc(r: ^Renderer) -> bool {
	when USE_WGPU { return wgpu_recover(r) } else { return d3d_recover(r) }
}

// The instances one page of a frame holds (a test's: the device's largest buffer else), so that a frame of a few
// hundred instances is drawn from several pages. The pages made are released; the next frame makes them again.
@(private)
set_instance_page :: proc(r: ^Renderer, n: int) {
	when USE_WGPU {
		wgpu_set_limits(&r.wg, n * size_of(Rect_Inst), r.wg.max_binding)
	} else {
		for &p in r.inst_pages { if p.buf != nil { p.buf->Release() } }
		clear(&r.inst_pages)
		r.inst_page = n
	}
}

heap_grow :: proc(r: ^Renderer, kind: Heap_Kind, need: int) -> bool {
	when USE_WGPU { return wgpu_heap_grow(r, kind, need) } else { return d3d_heap_grow(r, kind, need) }
}

@(private)
heaps_destroy :: proc(r: ^Renderer) {
	when USE_WGPU { wgpu_heaps_destroy(r) } else { d3d_heaps_destroy(r) }
}

// Slug text (slug.odin): the two glyph data textures a draw context fills, and a glyph page written into them.
create_slug_textures :: proc(r: ^Renderer, rows: int) -> (curves, bands: Texture) {
	when USE_WGPU { return wgpu_create_slug_textures(r, rows) } else { return d3d_create_slug_textures(r, rows) }
}

update_slug_page :: proc(r: ^Renderer, curves, bands: Texture, page: int, c: [][4]f16, b: [][2]u16) {
	when USE_WGPU { wgpu_update_slug_page(r, curves, bands, page, c, b) } else { d3d_update_slug_page(r, curves, bands, page, c, b) }
}