package capture

// What every backend does with the pictures it gets, whatever the system: frames placed on the desktop composed into one
// (desktop), and a buffer in a system's pixel format and orientation made into a Frame. Pure: the tests drive them with
// made-up frames.

import "base:runtime"
import "core:math"

// The frames composed into one, placed by their `origin` (logical) on the bounding rectangle of their logical rects, at
// the highest scale of them. A frame at a lower scale is enlarged by the nearest pixel; at the same scale it is copied as
// is. What no frame covers is transparent. ok is false when there is no frame with pixels.
compose :: proc(parts: []Frame, allocator := context.allocator) -> (out: Frame, ok: bool) {
	scale: f32
	x0, y0, x1, y1 := max(i32), max(i32), min(i32), min(i32)
	for p in parts {
		if p.width <= 0 || p.height <= 0 || p.scale <= 0 { continue }
		r := frame_rect(p)
		scale = max(scale, p.scale)
		x0, y0 = min(x0, r.x), min(y0, r.y)
		x1, y1 = max(x1, r.x + r.w), max(y1, r.y + r.h)
	}
	if scale <= 0 || x1 <= x0 || y1 <= y0 { return {}, false }
	w := i32(math.ceil(f32(x1 - x0) * scale))
	h := i32(math.ceil(f32(y1 - y0) * scale))
	out = Frame{width = w, height = h, stride = w * 4, scale = scale, origin = {x0, y0}, allocator = allocator}
	out.pixels = make([]u8, int(w) * int(h) * 4, allocator)
	for p in parts {
		if p.width <= 0 || p.height <= 0 || p.scale <= 0 { continue }
		// (rounded, not floored: two outputs side by side at a fractional scale meet without a gap)
		dx := i32(math.round(f32(p.origin.x - x0) * scale))
		dy := i32(math.round(f32(p.origin.y - y0) * scale))
		if p.scale == scale {
			cw := min(p.width, w - dx)
			for y in 0 ..< min(p.height, h - dy) {
				if cw <= 0 || dx < 0 || dy + y < 0 { break }
				copy(out.pixels[int((dy + y) * out.stride + dx * 4):][:int(cw * 4)], p.pixels[int(y * p.stride):][:int(cw * 4)])
			}
			continue
		}
		r := frame_rect(p)
		pw := i32(math.round(f32(r.w) * scale))
		ph := i32(math.round(f32(r.h) * scale))
		ratio := p.scale / scale
		for y in 0 ..< ph {
			oy := dy + y
			if oy < 0 || oy >= h { continue }
			sy := min(i32(f32(y) * ratio), p.height - 1)
			src_row := p.pixels[int(sy * p.stride):]
			dst_row := out.pixels[int(oy * out.stride):]
			for x in 0 ..< pw {
				ox := dx + x
				if ox < 0 || ox >= w { continue }
				sx := min(i32(f32(x) * ratio), p.width - 1)
				copy(dst_row[int(ox * 4):][:4], src_row[int(sx * 4):][:4])
			}
		}
	}
	return out, true
}

// Where a frame is on the desktop, logical.
@(private)
frame_rect :: proc(f: Frame) -> Rect {
	return {f.origin.x, f.origin.y, i32(math.round(f32(f.width) / f.scale)), i32(math.round(f32(f.height) / f.scale))}
}

// How a system's buffer holds its pixels, as far as the conversion to a Frame cares.
@(private)
Pixel_Order :: enum u8 {
	BGRA,   // B, G, R, A in memory (Wayland's ARGB8888 and XRGB8888 on a little-endian machine, X11's 32-bit visuals)
	RGBA,   // R, G, B, A in memory (Wayland's ABGR8888 and XBGR8888)
}

// The orientation of a buffer: wl_output.transform's values. A buffer with a transform holds the picture turned as the
// value says; the picture upright is the buffer turned back.
@(private)
Turn :: enum u8 { Normal, Rot90, Rot180, Rot270, Flipped, Flipped90, Flipped180, Flipped270 }

// A system's buffer as an upright, straight-alpha BGRA frame. `opaque`: the alpha byte means nothing (XRGB, a screen):
// every pixel gets 255. Otherwise the buffer's alpha is premultiplied (Wayland's and X11's ARGB are) and is made straight.
// `y_invert`: the rows are bottom to top (wlr-screencopy's flag). The frame's origin and scale are the caller's to set.
@(private)
frame_from_buffer :: proc(src: []u8, width, height, stride: i32, order: Pixel_Order, turn: Turn, y_invert, opaque: bool, allocator: runtime.Allocator) -> Frame {
	ow, oh := turned_size(width, height, turn)
	pixels := make([]u8, int(ow) * int(oh) * 4, allocator)
	f := frame_from_buffer_into(pixels, src, width, height, stride, order, turn, y_invert, opaque)
	f.allocator = allocator
	return f
}

// The size of a buffer of `width` x `height` once upright.
@(private)
turned_size :: proc(width, height: i32, turn: Turn) -> (w, h: i32) {
	quarter := turn == .Rot90 || turn == .Rot270 || turn == .Flipped90 || turn == .Flipped270
	return quarter ? height : width, quarter ? width : height
}

// frame_from_buffer into `dst` (turned_size's pixels, packed rows): what a stream does with each frame, without an
// allocation. The frame's pixels are `dst`; it does not own them.
@(private)
frame_from_buffer_into :: proc(dst: []u8, src: []u8, width, height, stride: i32, order: Pixel_Order, turn: Turn, y_invert, opaque: bool) -> Frame #no_bounds_check {
	ow, oh := turned_size(width, height, turn)
	f := Frame{width = ow, height = oh, stride = ow * 4, scale = 1}
	f.pixels = dst[:int(ow) * int(oh) * 4]
	flipped := turn >= .Flipped
	k := u8(turn) & 3
	for y in 0 ..< oh {
		for x in 0 ..< ow {
			// the upright picture is the buffer turned back: first the quarter turns clockwise, then the mirror
			ux := flipped ? ow - 1 - x : x
			uy := y
			sx, sy: i32
			switch k {
			case 0: sx, sy = ux, uy
			case 1: sx, sy = uy, height - 1 - ux
			case 2: sx, sy = width - 1 - ux, height - 1 - uy
			case 3: sx, sy = width - 1 - uy, ux
			}
			if y_invert { sy = height - 1 - sy }
			s := src[int(sy * stride + sx * 4):][:4]
			d := f.pixels[int(y * f.stride + x * 4):][:4]
			b, g, r, a := s[0], s[1], s[2], s[3]
			if order == .RGBA { b, r = r, b }
			if opaque {
				a = 255
			} else if a != 0 && a != 255 {
				b = u8(min(u32(b) * 255 / u32(a), 255))
				g = u8(min(u32(g) * 255 / u32(a), 255))
				r = u8(min(u32(r) * 255 / u32(a), 255))
			}
			d[0], d[1], d[2], d[3] = b, g, r, a
		}
	}
	return f
}

// The path of a file:// URI (a portal's answer), its %XX decoded, in `allocator`. ok is false for another scheme, a
// remote host, or a bad escape.
file_uri_path :: proc(uri: string, allocator := context.allocator) -> (path: string, ok: bool) {
	PREFIX :: "file://"
	if len(uri) < len(PREFIX) || uri[:len(PREFIX)] != PREFIX { return "", false }
	rest := uri[len(PREFIX):]
	// file://host/path: only this machine's (empty or "localhost")
	slash := -1
	for c, i in rest { if c == '/' { slash = i; break } }
	if slash < 0 { return "", false }
	host := rest[:slash]
	if host != "" && host != "localhost" { return "", false }
	rest = rest[slash:]
	out := make([dynamic]u8, 0, len(rest), allocator)
	for i := 0; i < len(rest); i += 1 {
		c := rest[i]
		if c == '?' || c == '#' { break }
		if c != '%' { append(&out, c); continue }
		if i + 2 >= len(rest) { delete(out); return "", false }
		hi, lo := hex_value(rest[i + 1]), hex_value(rest[i + 2])
		if hi < 0 || lo < 0 { delete(out); return "", false }
		append(&out, u8(hi << 4 | lo))
		i += 2
	}
	return string(out[:]), true
}

@(private = "file")
hex_value :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a' + 10)
	case 'A' ..= 'F': return int(c - 'A' + 10)
	}
	return -1
}
