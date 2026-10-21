package render

import win "core:sys/windows"

// The renderer has two backends behind one interface, chosen when the program is compiled:
//   -define:TOOLKIT_RENDER=d3d11   Direct3D 11 (render.odin, frame.odin, rect.hlsl, filter.hlsl)   the default
//   -define:TOOLKIT_RENDER=wgpu    WebGPU through wgpu-native (wgpu_*.odin, rect.wgsl, filter.wgsl)
// The procedures below are the ones whose work depends on the backend; each calls its d3d_* or wgpu_* implementation.
// Only the chosen one is compiled into the program (`when` is resolved at compile time). Everything else in this
// package (the frame description, texture pools, retained heap bookkeeping, presentation statistics, text rendering
// settings) is shared.

RENDER_BACKEND :: #config(TOOLKIT_RENDER, "d3d11")
USE_WGPU :: RENDER_BACKEND == "wgpu"
#assert(RENDER_BACKEND == "d3d11" || RENDER_BACKEND == "wgpu", "TOOLKIT_RENDER must be d3d11 or wgpu")

// The backend this program was built with: "d3d11" or "wgpu".
backend_name :: proc() -> string { return RENDER_BACKEND }

init :: proc(r: ^Renderer, hwnd: win.HWND, size: [2]int, transparent := false, space := Blend_Space.Linear) -> bool {
	when USE_WGPU { return wgpu_init(r, hwnd, size, transparent, space) } else { return d3d_init(r, hwnd, size, transparent, space) }
}

destroy :: proc(r: ^Renderer) {
	when USE_WGPU { wgpu_destroy(r) } else { d3d_destroy(r) }
}

init_offscreen :: proc(r: ^Renderer, size: [2]int, warp := false, space := Blend_Space.Linear) -> bool {
	when USE_WGPU { return wgpu_init_offscreen(r, size, warp, space) } else { return d3d_init_offscreen(r, size, warp, space) }
}

set_blend_space :: proc(r: ^Renderer, space: Blend_Space) {
	when USE_WGPU { wgpu_set_blend_space(r, space) } else { d3d_set_blend_space(r, space) }
}

read_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	when USE_WGPU { return wgpu_read_pixels(r, allocator) } else { return d3d_read_pixels(r, allocator) }
}

resize :: proc(r: ^Renderer, size: [2]int) {
	when USE_WGPU { wgpu_resize(r, size) } else { d3d_resize(r, size) }
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
	when USE_WGPU { wgpu_frame_end(r, vsync) } else { d3d_frame_end(r, vsync) }
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
