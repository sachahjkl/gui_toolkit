// Tests of the renderer's life cycle: teardown, device loss and recovery, captures, on an offscreen renderer (WARP; both render
// backends: -define:TOOLKIT_RENDER=wgpu).   odin test tests/lifecycle -vet
package lifecycle_test

import "core:mem"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{64, 64}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

// An allocator that fills what is freed with 0xAA first: a read of freed memory finds garbage handles (and crashes) instead of the old values.
Poison :: struct { inner: mem.Allocator }

@(private = "file")
poison_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, align: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	p := (^Poison)(data)
	if mode == .Free && old != nil && old_size > 0 { mem.set(old, 0xAA, old_size) }
	return p.inner.procedure(p.inner.data, mode, size, align, old, old_size, loc)
}

// destroy released the texture table, then walked it again to release the objects of the textures.
@(test)
destroy_does_not_read_the_freed_texture_table :: proc(t: ^testing.T) {
	p := Poison{context.allocator}
	context.allocator = mem.Allocator{poison_proc, &p}
	f: Fx
	if !open(&f) { testing.fail_now(t, "no device (WARP)") }
	tex := render.create_texture_rgba(&f.r, 16, 16)
	testing.expect(t, tex != 0)
	data := render.create_texture_data(&f.r, 8, 8)
	testing.expect(t, data != 0)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.image(&f.dc, tex, {{8, 8}, {24, 24}})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	draw.destroy(&f.dc)
	render.destroy(&f.r)
}
