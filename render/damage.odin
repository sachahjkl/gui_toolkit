package render

import "core:fmt"
import "core:os"
import "core:sync"
import "vendor:directx/d3d11"

// Partial redraw (damage regions). When only a small part of the window changed between two frames (a blinking text
// caret, a hovered button, a progress bar, a <video> in a corner, a local CSS animation), repainting and presenting
// the whole window wastes GPU power and bandwidth. Damage lets the application tell the renderer which rectangles
// changed; the renderer then rasterizes only the elements that touch them (per-batch scissor), into a target kept across
// frames that is copied whole to the swap chain and presented (damage_d3d.odin, damage_wgpu.odin).
//
// The flow, set before frame_submit:
//   * damage_begin(r)                 clears the region built for this frame (once a frame)
//   * damage_add(r, {x0, y0, x1, y1}) adds a dirty rectangle, in screen pixels (y down); as many as the app wants
//   * damage_scroll(r, rect, dx, dy)  the content of `rect` moved by (dx, dy) since the last frame
//   * frame_submit / frame_end        use the region
// A frame that calls damage_begin and adds nothing is a frame with no damage: the renderer draws nothing and does not
// present (the window keeps what it had). Without damage_begin the renderer treats the whole frame as damaged, exactly
// as before this feature: the default is lossless.
//
// The region is the union of the rectangles, with near rectangles merged so the list stays bounded (MAX_DAMAGE_RECTS):
// over the budget, or when two rectangles are close enough that covering both separately would redraw more than their
// union, they are fused. This bounds the scissor work.
//
// Correctness is not negotiable: a partial frame must be byte-for-byte identical to the full frame. The diagnostic flag
// `render.damage.verify` (set_damage_verify) renders every frame BOTH ways and compares; the first differing pixel and
// the rectangle it is in are reported, so a missing damage rectangle (a filter that reads outside its box, an
// overshooting shadow) is caught at once.
//
// -define:TOOLKIT_DAMAGE_CHECK=true proves it on a program's own content, which marks nothing: each frame is drawn whole on
// the side, what differs from the last frame becomes its region, and the partial frame must come out the same to the byte.
// Differences are printed, and a program that gets to render.destroy ends with exit code 1 (DAMAGE_CHECK below).

// Most rectangles a damage region keeps before it starts fusing them: the scissor loop in frame_submit tests each batch
// against each rectangle, so a small, bounded count matters.
MAX_DAMAGE_RECTS :: 16

// A rectangle in screen pixels, half-open: covers columns [x0, x1) and rows [y0, y1). Empty when x1 <= x0 or y1 <= y0.
Damage_Rect :: struct {
	x0, y0, x1, y1: i32,
}

// How a frame's damage is presented and verified.
Damage_Mode :: enum u8 {
	Off,     // the whole frame is damaged: draw and present everything (the behaviour before partial redraw)
	On,      // the region set this frame is the only part redrawn and presented
}

Damage_State :: struct {
	mode:        Damage_Mode,     // set_partial_redraw: Off (always full) or On (use the region when one was built)
	building:    bool,            // damage_begin was called this frame: a region is being built
	have_region: bool,            // the built region is in effect for this frame (frame_submit / frame_end read it)
	rects:       [MAX_DAMAGE_RECTS]Damage_Rect,   // what changed this frame: what is cleared and rasterized
	count:       int,
	verify:      bool,            // set_damage_verify / render.damage.verify: render full too and compare
	clear:       [4]f32,          // the frame's clear colour, in the target's values (frame_begin kept it)
	have_clear:  bool,            // frame_begin deferred the clear to frame_submit (a possible partial frame)
	skip_present: bool,           // a region of nothing, on top of a good target: frame_end does not present
	side:         bool,           // this submit draws on the side (verify): the window does not get it
	// counters (damage_stats): reset by damage_begin
	rects_in:    int,             // rectangles the app added this frame (before fusion)
	px_raster:   int,             // pixels inside the region (what partial rendering rasterized)
	px_full:     int,             // pixels of the whole frame (what a full frame would rasterize)
	verify_differences: int,      // frames render.damage.verify found different (damage_verify_differences)
	// Direct3D 11 (damage_d3d.odin; WebGPU keeps its own in Wgpu_State). One window's, so it goes with the state in surface_use.
	target:       ^d3d11.ITexture2D,          // the kept target: what the next region starts from
	target_rtv:   ^d3d11.IRenderTargetView,
	target_size:  [2]int,
	target_ready: bool,                       // it holds the last frame
	clear_tex:    ^d3d11.ITexture2D,          // a texture of the clear color, copied into the region
	clear_rtv:    ^d3d11.IRenderTargetView,
	clear_size:   [2]int,
	side_target:  ^d3d11.ITexture2D,          // a whole frame for comparison (verify): exchanged with `target` to draw it
	side_rtv:     ^d3d11.IRenderTargetView,
	side_size:    [2]int,
	side_ready:   bool,
}

// Off (the renderer always draws and presents the whole frame, the behaviour before this feature) or On (a region built
// with damage_begin / damage_add is the only part redrawn and presented). Set it once; it stays until changed. `auto`
// in an application (browser.gpu.partial_redraw) maps to On where the backend supports it.
set_partial_redraw :: proc(r: ^Renderer, on: bool) { r.damage.mode = on ? .On : .Off }
partial_redraw :: proc(r: ^Renderer) -> bool { return r.damage.mode == .On }

// Renders every frame both partially and in full and compares them (render.damage.verify): the first differing pixel
// and the rectangle it lies in are printed. For development only; it costs a full extra frame.
set_damage_verify :: proc(r: ^Renderer, on: bool) { r.damage.verify = on }
damage_verify :: proc(r: ^Renderer) -> bool { return r.damage.verify }

// Frames render.damage.verify found different from a full render since the renderer was made.
damage_verify_differences :: proc(r: ^Renderer) -> int { return r.damage.verify_differences }

// Begins a new damage region for this frame (clearing the one built before). Call once, before frame_submit, when the
// application tracks damage; then damage_add / damage_scroll. A frame that begins a region and adds nothing redraws and
// presents nothing. Not calling it means the whole frame is damaged (lossless default).
damage_begin :: proc(r: ^Renderer) {
	d := &r.damage
	d.building = true
	d.count = 0
	d.rects_in = 0
	d.px_raster, d.px_full = 0, 0
}

// Adds a dirty rectangle (screen pixels, y down). Clamped to the frame; empty rectangles are ignored. Over the budget,
// or when fusing two rectangles redraws fewer pixels than keeping them apart, rectangles are merged (the region stays
// bounded). Only between damage_begin and frame_submit.
damage_add :: proc(r: ^Renderer, rect: Damage_Rect) {
	d := &r.damage
	if !d.building { return }
	nr := clamp_rect(rect, r.size)
	if rect_empty(nr) { return }
	d.rects_in += 1
	region_add(&d.rects, &d.count, nr)
}

// The content of `rect` moved by (dx, dy) screen pixels since the last frame (a scrolled view). No backend moves pixels
// by a block copy today: where it was and where it is now are redrawn, like damage_add.
damage_scroll :: proc(r: ^Renderer, rect: Damage_Rect, dx, dy: i32) {
	d := &r.damage
	if !d.building { return }
	nr := clamp_rect(rect, r.size)
	if rect_empty(nr) || (dx == 0 && dy == 0) { return }
	moved := clamp_rect({rect.x0 + dx, rect.y0 + dy, rect.x1 + dx, rect.y1 + dy}, r.size)
	damage_add(r, nr)
	damage_add(r, moved)
}

// The damage of this frame: how many rectangles were added, how many remain after fusion, the pixels the region covers
// and the pixels of the whole frame, and whether a region is in effect. For wren ctl stats / render.damage.*.
damage_stats :: proc(r: ^Renderer) -> (added, kept, px_region, px_frame: int, active: bool) {
	d := &r.damage
	return d.rects_in, d.count, d.px_raster, d.px_full, d.have_region
}

// The rectangles of the region in effect this frame (valid until the next damage_begin); empty when the whole frame is
// drawn. For an application that wants to show or log them.
damage_rects :: proc(r: ^Renderer) -> []Damage_Rect {
	d := &r.damage
	if !d.have_region { return nil }
	return d.rects[:d.count]
}

////////////////////////////////
// Region arithmetic (pure, backend independent)

@(private)
rect_empty :: proc(a: Damage_Rect) -> bool { return a.x1 <= a.x0 || a.y1 <= a.y0 }

@(private)
rect_area :: proc(a: Damage_Rect) -> int { return rect_empty(a) ? 0 : int(a.x1 - a.x0) * int(a.y1 - a.y0) }

@(private)
rect_union_d :: proc(a, b: Damage_Rect) -> Damage_Rect {
	if rect_empty(a) { return b }
	if rect_empty(b) { return a }
	return {min(a.x0, b.x0), min(a.y0, b.y0), max(a.x1, b.x1), max(a.y1, b.y1)}
}

@(private)
rect_overlap :: proc(a, b: Damage_Rect) -> bool {
	return a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1
}

@(private)
clamp_rect :: proc(a: Damage_Rect, size: [2]int) -> Damage_Rect {
	w, h := i32(size.x), i32(size.y)
	return {clamp(a.x0, 0, w), clamp(a.y0, 0, h), clamp(a.x1, 0, w), clamp(a.y1, 0, h)}
}

// Adds `nr` to a bounded list of rectangles, fusing where it pays. Two rectangles are fused when they overlap, or when
// their union redraws no more pixels than keeping them apart (near rectangles: the strip between them is cheaper to
// repaint than two scissors and two dirty rects). Over the budget, the pair whose union wastes the fewest pixels is
// fused first, so the final list never exceeds MAX_DAMAGE_RECTS. The rectangles never overlap: a batch is drawn once per rectangle.
@(private)
region_add :: proc(rects: ^[MAX_DAMAGE_RECTS]Damage_Rect, count: ^int, nr: Damage_Rect) {
	cur := nr
	// fold the new rect into any it wants to fuse with, repeatedly (a rect bridging two others merges all three)
	for {
		merged := false
		for i := 0; i < count^; {
			if should_fuse(rects[i], cur) {
				cur = rect_union_d(rects[i], cur)
				rects[i] = rects[count^ - 1]
				count^ -= 1
				merged = true
			} else {
				i += 1
			}
		}
		if !merged { break }
	}
	if count^ < MAX_DAMAGE_RECTS {
		rects[count^] = cur
		count^ += 1
		return
	}
	// the list is full: fuse `cur` with the rect whose union wastes the least, keeping the count bounded
	best, best_waste := -1, max(int)
	for i in 0 ..< count^ {
		u := rect_union_d(rects[i], cur)
		waste := rect_area(u) - rect_area(rects[i]) - rect_area(cur) + overlap_area(rects[i], cur)
		if waste < best_waste { best, best_waste = i, waste }
	}
	// (taken out and added again: what it grew into may overlap others, and the rectangles never overlap)
	u := rect_union_d(rects[best], cur)
	rects[best] = rects[count^ - 1]
	count^ -= 1
	region_add(rects, count, u)
}

// Whether merging the two rectangles into their bounding union is at least as cheap as keeping them apart: they
// overlap, or the union adds no more pixels than the two rectangles cover separately (so the strip between them is free
// to repaint). Prevents a line of tiny rectangles (a scrolling list, a caret moving) from fragmenting the region.
@(private)
should_fuse :: proc(a, b: Damage_Rect) -> bool {
	if rect_overlap(a, b) { return true }
	u := rect_area(rect_union_d(a, b))
	return u <= rect_area(a) + rect_area(b)
}

@(private)
overlap_area :: proc(a, b: Damage_Rect) -> int {
	x0, y0 := max(a.x0, b.x0), max(a.y0, b.y0)
	x1, y1 := min(a.x1, b.x1), min(a.y1, b.y1)
	if x1 <= x0 || y1 <= y0 { return 0 }
	return int(x1 - x0) * int(y1 - y0)
}

// Grows every rectangle of the region by `pad` pixels on each side, clamped to the frame. Backends that read outside a
// damaged box (a backdrop-filter blur, a drop shadow) call this with the filter's reach so the region still bounds what
// the frame reads. (The application is expected to add such boxes already grown; this is a safety net the verify flag
// checks against.)
@(private)
region_pad :: proc(d: ^Damage_State, size: [2]int, pad: i32) {
	if pad <= 0 { return }
	for i in 0 ..< d.count {
		r := d.rects[i]
		d.rects[i] = clamp_rect({r.x0 - pad, r.y0 - pad, r.x1 + pad, r.y1 + pad}, size)
	}
}

////////////////////////////////
// Frame hooks (called by frame.odin / wgpu_frame.odin / present.odin)

// A frame that copies its own target while it is drawn (a backdrop, a blend mode) reads pixels the region does not redraw, and they
// are the last frame's finished ones, not what lies under the copy at this point: only a whole frame is exact.
@(private)
damage_frame_reads_itself :: proc(f: Frame_Data) -> bool {
	for &op in f.ops { if op.kind == .Copy && op.source == 0 { return true } }
	return false
}

// At frame_submit: whether a region was built this frame, and its counters. False: the frame is whole (no damage tracking,
// mode Off). The backend still decides whether the kept target allows a partial frame (have_region says it did).
@(private)
damage_resolve :: proc(r: ^Renderer) -> bool {
	d := &r.damage
	d.have_region = false
	if d.mode != .On || !d.building { return false }
	d.building = false
	// the environment flag mirrors the pref, read once: render.damage.verify
	damage_verify_env(d)
	d.px_full = r.size.x * r.size.y
	px := 0
	for i in 0 ..< d.count { px += rect_area(d.rects[i]) }
	d.px_raster = px
	d.have_region = true
	return true
}

@(private)
damage_verify_env :: proc(d: ^Damage_State) {
	@(static) state: int   // 0 unknown, 1 off, 2 on
	if state == 0 { state = os.get_env("TOOLKIT_DAMAGE_VERIFY", context.temp_allocator) != "" ? 2 : 1 }
	if state == 2 { d.verify = true }
}

// The frame `f` drawn whole on the side, read back (nil: it could not be): the target the frames compose into changes place with
// another one for this submit, which runs the frame's steps again. Their pooled textures are all there until the next acquire.
@(private)
damage_side_frame :: proc(r: ^Renderer, f: Frame_Data) -> []u8 {
	d := &r.damage
	if r.frame_format == .R16G16B16A16_FLOAT { return nil }   // (the comparison reads BGRA8)
	skip, in_effect := d.skip_present, d.have_region
	defer d.skip_present, d.have_region = skip, in_effect
	when USE_WGPU {
		wgpu_damage_side_swap(r)
		defer wgpu_damage_side_swap(r)
		r.wg.damage_ready = false
		r.wg.clear_pending = true
		if !wgpu_damage_ensure_target(r) { return nil }
	} else {
		d3d_damage_side_swap(r)
		defer d3d_damage_side_swap(r)
		d.target_ready = false
		d.have_clear = true
		if !d3d_damage_ensure_target(r) { return nil }
	}
	d.side, d.building = true, true
	defer d.side = false
	damage_backend_submit(r, f)
	return damage_read_target(r)
}

@(private)
damage_backend_submit :: proc(r: ^Renderer, f: Frame_Data) {
	when USE_WGPU { wgpu_frame_submit(r, f) } else { d3d_frame_submit(r, f) }
}

// What the kept target holds, BGRA8, tightly packed. nil: nothing.
@(private)
damage_read_target :: proc(r: ^Renderer) -> []u8 {
	when USE_WGPU { return wgpu_damage_readback(r, r.wg.damage_target) } else { return d3d_read_texture(r, r.damage.target) }
}

// render.damage.verify: the partial frame just drawn against the frame drawn whole.
@(private)
damage_verify_frame :: proc(r: ^Renderer, f: Frame_Data) {
	got := damage_read_target(r)
	defer delete(got)
	full := damage_side_frame(r, f)
	defer delete(full)
	if got != nil && full != nil { damage_compare(&r.damage, full, got, r.size) }
}

DAMAGE_CHECK :: #config(TOOLKIT_DAMAGE_CHECK, false)
// What differs from the last frame is looked for in tiles of this many pixels: a region of what changes, not one box around all of it.
@(private) DAMAGE_CHECK_TILE_PX :: 64
@(private) damage_check_frames, damage_check_partial, damage_check_differences: int   // atomic: renderers may live on several threads

// A frame of a program that marks nothing (see the top of this file). A region the program opened itself is left alone.
@(private)
damage_check_submit :: proc(r: ^Renderer, f: Frame_Data) {
	d := &r.damage
	full := damage_side_frame(r, f)
	defer delete(full)
	sync.atomic_add(&damage_check_frames, 1)
	ready: bool
	when USE_WGPU { ready = r.wg.damage_ready } else { ready = d.target_ready }
	damage_begin(r)
	if ready && full != nil {
		last := damage_read_target(r)
		defer delete(last)
		if last != nil { damage_check_mark(r, full, last) }
	}
	when USE_WGPU { r.wg.clear_pending = true } else { d.have_clear = true }
	damage_backend_submit(r, f)
	if d.have_region { sync.atomic_add(&damage_check_partial, 1) }
	if full == nil { return }
	got := damage_read_target(r)
	defer delete(got)
	before := d.verify_differences
	if got != nil { damage_compare(d, full, got, r.size) }
	sync.atomic_add(&damage_check_differences, d.verify_differences - before)
}

@(private)
damage_check_mark :: proc(r: ^Renderer, full, last: []u8) {
	w, h := r.size.x, r.size.y
	for ty := 0; ty < h; ty += DAMAGE_CHECK_TILE_PX {
		for tx := 0; tx < w; tx += DAMAGE_CHECK_TILE_PX {
			x1, y1 := min(tx + DAMAGE_CHECK_TILE_PX, w), min(ty + DAMAGE_CHECK_TILE_PX, h)
			for y in ty ..< y1 {
				a, b := full[(y * w + tx) * 4:(y * w + x1) * 4], last[(y * w + tx) * 4:(y * w + x1) * 4]
				if string(a) != string(b) {
					damage_add(r, {i32(tx), i32(ty), i32(x1), i32(y1)})
					break
				}
			}
		}
	}
}

// At render.destroy: what the check found, and the exit code of a program that it failed.
@(private)
damage_check_report :: proc() {
	n := sync.atomic_load(&damage_check_differences)
	fmt.eprintfln("render.damage.check: %d frames, %d of them partial, %d different from the whole frame", sync.atomic_load(&damage_check_frames), sync.atomic_load(&damage_check_partial), n)
	if n > 0 { os.exit(1) }
}

// Compares two BGRA8 frames and, on the first differing pixel, prints it and the damage rectangle it belongs to (or
// that it lies outside the region: a dirty rectangle is missing). Backend independent (both verify paths call it).
@(private)
damage_compare :: proc(d: ^Damage_State, full, partial: []u8, size: [2]int) {
	n := min(len(full), len(partial))
	for i := 0; i + 3 < n; i += 4 {
		if full[i] == partial[i] && full[i + 1] == partial[i + 1] && full[i + 2] == partial[i + 2] && full[i + 3] == partial[i + 3] { continue }
		d.verify_differences += 1
		px := i / 4
		x, y := px % size.x, px / size.x
		in_region := false
		which := -1
		for k in 0 ..< d.count {
			rr := d.rects[k]
			if i32(x) >= rr.x0 && i32(x) < rr.x1 && i32(y) >= rr.y0 && i32(y) < rr.y1 { in_region, which = true, k; break }
		}
		fmt.eprintfln(
			"render.damage.verify: first difference at pixel (%d, %d): full BGRA %v, partial BGRA %v | %s",
			x, y, full[i:i + 4], partial[i:i + 4],
			in_region ? fmt.tprintf("inside damage rect %d %v", which, d.rects[which]) : "OUTSIDE every damage rectangle (a dirty rectangle is missing)")
		return
	}
}

