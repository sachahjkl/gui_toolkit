package draw

// Drawing into a texture of its own, then reading it back: what is drawn between offscreen_begin and offscreen_end goes
// to a transparent target of the size asked, in its own space ((0, 0) is its top left, no transform or clip of the
// frame applies, nothing outside the window cuts it), and is never shown. offscreen_end records the copy of it; the
// pixels come from render.readback_poll after the frame (straight RGBA, sRGB values, alpha kept). For pictures of
// parts of a scene that may be off the screen or hidden by others: a drag image of an element, a capture of one
// element, an element to blob.
//
//   if draw.offscreen_begin(dc, {w, h}) {
//       ...draw as usual, at (0, 0)..(w, h)...
//       id := draw.offscreen_end(dc)
//   }
//   // a frame or two later:
//   pixels, size, status := render.readback_poll(renderer, id)
//
// Inside, everything works as in a layer (images, text, other layers). Not while a picture is recorded.

import "../render"

// Opens an offscreen target of `size` pixels. False (nothing to close): recording a picture, an empty or too large
// size, or the renderer refused a target.
offscreen_begin :: proc(c: ^Context, size: [2]int) -> bool {
	if c.rec != nil || size.x <= 0 || size.y <= 0 { return false }
	tex := render.acquire_target(c.renderer, size.x, size.y)
	if tex == 0 { return false }
	append(&c.layers, render.Layer{tex = tex, origin = {0, 0}, size = size, space = blend_space(c)})
	id := len(c.layers)
	ol := Open_Layer{id = id, alpha = 1, parent = c.target, xform = AFFINE_IDENTITY, kind = .Offscreen, planes = len(c.planes), pending0 = c.glyphs_pending}
	add_op(c, render.Op{kind = .Clear, dst = tex})
	close_batch(c)
	c.target = id
	append(&c.clips, Clip{rect = {{0, 0}, {f32(size.x), f32(size.y)}}})
	append(&c.xforms, Transform{m = AFFINE_IDENTITY, simple = true})
	start_batch(c)
	append(&c.alphas, 1)
	ol.floor = floor_raise(c)
	append(&c.open_layers, ol)
	return true
}

// Closes the offscreen target opened last: its copy for readback is recorded, the target goes back to the pool. 0: no
// offscreen target is open.
offscreen_end :: proc(c: ^Context) -> render.Readback_Id {
	if !offscreen_active(c) { return 0 }
	ol := offscreen_close(c)
	ly := c.layers[ol.id - 1]
	id := render.readback_new(c.renderer)
	if id != 0 { add_op(c, render.Op{kind = .Read, source = ol.id, box = {0, 0, i32(ly.size.x), i32(ly.size.y)}, readback = id}) }
	render.release_target(c.renderer, ly.tex)
	return id
}

// Back to what the target was opened in.
@(private = "file")
offscreen_close :: proc(c: ^Context) -> Open_Layer {
	layer_settle(c)
	ol := pop(&c.open_layers)
	c.floor = ol.floor
	pop(&c.alphas)
	close_batch(c)
	pop(&c.clips)
	pop(&c.xforms)
	c.target = ol.parent
	start_batch(c)
	return ol
}

// An offscreen target closed by anything but offscreen_end (pop_layer, the end of the frame): nothing reads it.
@(private)
offscreen_drop :: proc(c: ^Context) {
	ol := offscreen_close(c)
	render.release_target(c.renderer, c.layers[ol.id - 1].tex)
}

// Whether the target open last is an offscreen one (drawing code that must not open layers of the frame inside).
offscreen_active :: proc(c: ^Context) -> bool {
	return len(c.open_layers) > 0 && c.open_layers[len(c.open_layers) - 1].kind == .Offscreen
}
