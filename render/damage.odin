package render

import "core:os"
import "core:slice"

// Partial redraw (damage regions). When only a small part of the window changed between two frames (a blinking text
// caret, a hovered button, a progress bar, a <video> in a corner, a local CSS animation), repainting and presenting
// the whole window wastes GPU power and bandwidth. Damage lets the application tell the renderer which rectangles
// changed; the renderer then rasterizes only the elements that touch them (per-batch scissor) and presents only those
// rectangles (DXGI Present1 with dirty rects, or a persistent render target on WebGPU).
//
// The flow, set between frame_begin and frame_submit:
//   * damage_begin(r)                 clears the region built for this frame (call once after frame_begin)
//   * damage_add(r, {x0, y0, x1, y1}) adds a dirty rectangle, in screen pixels (y down); as many as the app wants
//   * damage_scroll(r, rect, dx, dy)  the content of `rect` moved by (dx, dy) since the last frame (one per frame)
//   * frame_submit / frame_end        use the region
// A frame that calls damage_begin and adds nothing is a frame with no damage: the renderer draws nothing and does not
// present (the window keeps what it had). Without damage_begin the renderer treats the whole frame as damaged, exactly
// as before this feature: the default is lossless.
//
// The region is the union of the rectangles, with near rectangles merged so the list stays bounded (MAX_DAMAGE_RECTS):
// over the budget, or when two rectangles are close enough that covering both separately would redraw more than their
// union, they are fused. This bounds both the scissor work and the dirty-rect array Present1 takes.
//
// Correctness is not negotiable: a partial frame must be byte-for-byte identical to the full frame. The diagnostic flag
// `render.damage.verify` (set_damage_verify) renders every frame BOTH ways and compares; the first differing pixel and
// the rectangle it is in are reported, so a missing damage rectangle (a filter that reads outside its box, an
// overshooting shadow) is caught at once.

// Most rectangles a damage region keeps before it starts fusing them. Present1 is given at most this many dirty rects;
// the scissor loop in frame_submit tests each batch against each rectangle, so a small, bounded count matters.
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
	rects:       [MAX_DAMAGE_RECTS]Damage_Rect,   // what changed this frame (Present1 dirty rects)
	count:       int,
	render_rects: [MAX_DAMAGE_RECTS]Damage_Rect,  // what to actually clear and rasterize (this frame + buffer-age history)
	render_count: int,
	scroll:      Damage_Rect,     // damage_scroll: the region whose content moved (empty: none)
	scroll_dx:   i32,
	scroll_dy:   i32,
	have_scroll: bool,
	verify:      bool,            // set_damage_verify / render.damage.verify: render full too and compare
	clear:       [4]f32,          // the frame's clear colour (frame_begin kept it; a partial frame clears per rectangle)
	have_clear:  bool,            // frame_begin deferred the clear to frame_submit (a possible partial frame)
	// counters (damage_stats): reset by damage_begin
	rects_in:    int,             // rectangles the app added this frame (before fusion)
	px_raster:   int,             // pixels inside the region (what partial rendering rasterized)
	px_full:     int,             // pixels of the whole frame (what a full frame would rasterize)
	// buffer age for flip models that do not keep content (d3d_present_partial): how many of the last frames' regions
	// a present must also redraw. Entry [k] is the region presented k frames ago; a present with a buffer `age` old
	// must have drawn the union of the last `age` regions into it.
	history:     [MAX_BUFFER_AGE]History_Region,
	history_len: int,
}

// The damaged region of one past frame, kept for the buffer-age logic of flip swap chains (see d3d_present_partial).
@(private)
MAX_BUFFER_AGE :: 4

@(private)
History_Region :: struct {
	rects: [MAX_DAMAGE_RECTS]Damage_Rect,
	count: int,
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

// Begins a new damage region for this frame (clearing the one built before). Call once, after frame_begin, when the
// application tracks damage; then damage_add / damage_scroll. A frame that begins a region and adds nothing redraws and
// presents nothing. Not calling it means the whole frame is damaged (lossless default).
damage_begin :: proc(r: ^Renderer) {
	d := &r.damage
	d.building = true
	d.count = 0
	d.scroll = {}
	d.scroll_dx, d.scroll_dy, d.have_scroll = 0, 0, false
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

// The content of `rect` moved by (dx, dy) screen pixels since the last frame (a scrolled view): presented as a block
// copy (Present1 pScrollRect) when the backend can, so the moved pixels are not redrawn. The newly exposed band must
// still be added with damage_add. One scroll per frame; a second replaces the first.
damage_scroll :: proc(r: ^Renderer, rect: Damage_Rect, dx, dy: i32) {
	d := &r.damage
	if !d.building { return }
	nr := clamp_rect(rect, r.size)
	if rect_empty(nr) || (dx == 0 && dy == 0) { return }
	d.scroll, d.scroll_dx, d.scroll_dy, d.have_scroll = nr, dx, dy, true
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
// fused first, so the final list never exceeds MAX_DAMAGE_RECTS.
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
	if best >= 0 { rects[best] = rect_union_d(rects[best], cur) }
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

// At frame_submit, after the region was built this frame: decides whether a partial frame is possible, fills the
// render region (this frame plus the history a back buffer of `buffer_age` frames needs: a flip buffer does not keep
// its content, so a partial frame must repaint everything that changed while that buffer was off screen), and records
// the counters. Returns false to draw the whole frame (no damage tracking, mode Off, or the buffer age is unknown or
// older than the history kept). `buffer_age`: how many frames old the back buffer being drawn is (flip buffer count);
// 1 or less means the buffer still holds the previous frame (nothing extra to redraw beyond this frame's region).
@(private)
damage_resolve :: proc(r: ^Renderer, buffer_age: int) -> bool {
	d := &r.damage
	d.have_region = false
	d.render_count = 0
	if d.mode != .On || !d.building { return false }
	d.building = false
	// the environment flag mirrors the pref, read once: render.damage.verify
	damage_verify_env(d)
	d.px_full = r.size.x * r.size.y
	// the render region: this frame's rectangles plus the regions of the frames this buffer missed (buffer_age <= 1:
	// just this frame). When the history is too short for the age, there is no safe partial frame: fall back to full.
	if buffer_age > 1 {
		cnt, ok := damage_history_union(d, buffer_age, &d.render_rects)
		if !ok { return false }
		d.render_count = cnt
	} else {
		for i in 0 ..< d.count { d.render_rects[i] = d.rects[i] }
		d.render_count = d.count
	}
	px := 0
	for i in 0 ..< d.render_count { px += rect_area(d.render_rects[i]) }
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

// True when a batch whose scissor is `clip` (screen pixels x0 y0 x1 y1) touches the damaged region: it must be drawn.
// With no region in effect every batch is drawn. The returned rectangle is the scissor intersected with the region's
// bounding box, so a batch that straddles two far rectangles is still clipped to what changed.
@(private)
damage_clip_batch :: proc(d: ^Damage_State, clip: [4]f32) -> (out: [4]f32, draw: bool) {
	if !d.have_region { return clip, true }
	bx0, by0, bx1, by1 := f32(clip[0]), f32(clip[1]), f32(clip[2]), f32(clip[3])
	hit := false
	ux0, uy0, ux1, uy1: f32
	for i in 0 ..< d.render_count {
		rr := d.render_rects[i]
		ix0, iy0 := max(bx0, f32(rr.x0)), max(by0, f32(rr.y0))
		ix1, iy1 := min(bx1, f32(rr.x1)), min(by1, f32(rr.y1))
		if ix1 <= ix0 || iy1 <= iy0 { continue }
		if !hit { ux0, uy0, ux1, uy1, hit = ix0, iy0, ix1, iy1, true }
		else { ux0, uy0, ux1, uy1 = min(ux0, ix0), min(uy0, iy0), max(ux1, ix1), max(uy1, iy1) }
	}
	if !hit { return clip, false }
	return {ux0, uy0, ux1, uy1}, true
}

// Records the region of the frame being presented into the history ring, so a later flip present can tell, from the
// buffer's age, how many frames it must redraw into the back buffer (see d3d_present_partial).
@(private)
damage_push_history :: proc(d: ^Damage_State) {
	for k := min(d.history_len, MAX_BUFFER_AGE - 1); k > 0; k -= 1 { d.history[k] = d.history[k - 1] }
	h := &d.history[0]
	h.count = d.count
	for i in 0 ..< d.count { h.rects[i] = d.rects[i] }
	d.history_len = min(d.history_len + 1, MAX_BUFFER_AGE)
}

// The union of the regions of the last `age` presented frames, as a list of rectangles (the area a flip back buffer of
// that age must have redrawn so that it holds the same pixels as a fully kept buffer). `age` 0 or 1: this frame's
// region. `age` >= MAX_BUFFER_AGE or history too short: nil, meaning the whole frame must be redrawn.
@(private)
damage_history_union :: proc(d: ^Damage_State, age: int, out: ^[MAX_DAMAGE_RECTS]Damage_Rect) -> (count: int, ok: bool) {
	back := max(age - 1, 0)   // age 1 means "the buffer holds the frame before this one": redraw this frame's region only
	if back >= d.history_len || back >= MAX_BUFFER_AGE { return 0, false }
	count = 0
	// this frame's region first
	for i in 0 ..< d.count { region_add(out, &count, d.rects[i]) }
	for k in 0 ..< back {
		h := d.history[k]
		for i in 0 ..< h.count { region_add(out, &count, h.rects[i]) }
	}
	return count, true
}

_ :: slice
