package render

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
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

RENDER_BACKEND :: #config(TOOLKIT_RENDER, "d3d11") when ODIN_OS == .Windows else "wgpu"
USE_WGPU :: RENDER_BACKEND == "wgpu"
#assert(RENDER_BACKEND == "d3d11" || RENDER_BACKEND == "wgpu", "TOOLKIT_RENDER must be d3d11 or wgpu")
#assert(ODIN_OS == .Windows || USE_WGPU, "the Direct3D 11 backend is Windows only; other systems use wgpu")

// The backend this program was built with: "d3d11" or "wgpu".
backend_name :: proc() -> string { return RENDER_BACKEND }

// Opens the renderer on a window from the neutral native handles the platform package fills (platform.Surface_Handles,
// from platform.native_surface_handles(window)): the HWND on Windows, the Wayland or XCB handles on Linux. An offscreen
// window has no handles (backend .None): use init_offscreen instead. `transparent`: the window shows through where the
// frame has alpha < 1 (open the window translucent too). `space`: what the frame blends in.
init :: proc(r: ^Renderer, surface: platform.Surface_Handles, size: [2]int, transparent := false, space := Blend_Space.Linear) -> bool {
	ok: bool
	when USE_WGPU { ok = wgpu_init(r, surface, size, transparent, space) } else { ok = d3d_init(r, surface, size, transparent, space) }
	if ok { r.id = sync.atomic_add(&renderer_ids, 1) + 1 }
	return ok
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
}

init_offscreen :: proc(r: ^Renderer, size: [2]int, warp := false, space := Blend_Space.Linear) -> bool {
	ok: bool
	when USE_WGPU { ok = wgpu_init_offscreen(r, size, warp, space) } else { ok = d3d_init_offscreen(r, size, warp, space) }
	if ok { r.id = sync.atomic_add(&renderer_ids, 1) + 1 }
	return ok
}

set_blend_space :: proc(r: ^Renderer, space: Blend_Space) {
	when USE_WGPU { wgpu_set_blend_space(r, space) } else { d3d_set_blend_space(r, space) }
}

read_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	when USE_WGPU { return wgpu_read_pixels(r, allocator) } else { return d3d_read_pixels(r, allocator) }
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
	when USE_WGPU { return r.wg.surface == nil && r.wg.device != nil } else { return r.swapchain == nil && r.offscreen != nil }
}

// Most frames the swap chain may queue: 1 (the default) keeps the time from input to screen at one frame; 2 or more let
// a frame be presented while the previous one is still on its way to the screen (a resize, a burst of frames), at the
// cost of input latency. False: the backend cannot (or has no window). It can be raised and lowered again at will: the surplus
// the system leaves in the latency object when it is lowered is taken back (frame_waitable, wait_for_frame).
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
	when USE_WGPU { wgpu_update_texture_r8(r, t, x, y, w, h, pixels, pitch) } else { d3d_update_texture_r8(r, t, x, y, w, h, pixels, pitch) }
}

max_texture_size :: proc(r: ^Renderer) -> int {
	when USE_WGPU { return wgpu_max_texture_size(r) } else { return d3d_max_texture_size(r) }
}

create_texture_rgba :: proc(r: ^Renderer, w, h: int, mips := true) -> Texture {
	when USE_WGPU { return wgpu_create_texture_rgba(r, w, h, mips) } else { return d3d_create_texture_rgba(r, w, h, mips) }
}

update_texture_rgba :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) {
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
	when USE_WGPU { wgpu_update_texture_data(r, t, x, y, w, h, pixels, stride) } else { d3d_update_texture_data(r, t, x, y, w, h, pixels, stride) }
}

destroy_texture :: proc(r: ^Renderer, t: Texture) {
	when USE_WGPU { wgpu_destroy_texture(r, t) } else { d3d_destroy_texture(r, t) }
}

frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	when USE_WGPU { wgpu_frame_begin(r, clear) } else { d3d_frame_begin(r, clear) }
}

wait_for_frame :: proc(r: ^Renderer, timeout_ms := 100) -> bool {
	when USE_WGPU { return wgpu_wait_for_frame(r, timeout_ms) } else { return d3d_wait_for_frame(r, timeout_ms) }
}

frame_submit :: proc(r: ^Renderer, f: Frame_Data) {
	when USE_WGPU { wgpu_frame_submit(r, f) } else { d3d_frame_submit(r, f) }
}

frame_end :: proc(r: ^Renderer, vsync := true) {
	r.present.drawn = time.tick_now()
	when !USE_WGPU { if r.capture.requested { capture_copy(r) } }   // before the present: a flip chain does not keep the frame
	when USE_WGPU { wgpu_frame_end(r, vsync) } else { d3d_frame_end(r, vsync) }
	if !r.first_present_noted {
		r.first_present_noted = true
		if render_trace() {
			if ms := process_uptime_ms(); ms >= 0 {
				fmt.eprintfln("render: first present %.0f ms after the process started (backend %s)", ms, RENDER_BACKEND)
			}
		}
	}
}

// TOOLKIT_RENDER_TRACE=1 (or TOOLKIT_WGPU_TRACE=1) in the environment: timings of the renderer on stderr.
@(private)
render_trace :: proc() -> bool {
	@(static) state: int   // 0: unknown, 1: off, 2: on
	if state == 0 { state = os.get_env("TOOLKIT_RENDER_TRACE", context.temp_allocator) != "" || os.get_env("TOOLKIT_WGPU_TRACE", context.temp_allocator) != "" ? 2 : 1 }
	return state == 2
}

heap_write :: proc(r: ^Renderer, kind: Heap_Kind, offset: int, data: rawptr, n: int) {
	when USE_WGPU { wgpu_heap_write(r, kind, offset, data, n) } else { d3d_heap_write(r, kind, offset, data, n) }
}

recover :: proc(r: ^Renderer) -> bool {
	when USE_WGPU { return wgpu_recover(r) } else { return d3d_recover(r) }
}

@(private)
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