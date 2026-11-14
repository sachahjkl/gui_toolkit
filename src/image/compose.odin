package tk_image

// `src` drawn over `dst` in place, its top-left corner at (x, y), its alpha times `opacity` (0 to 1): the usual "over" of
// straight colours. The part outside `dst` is left out.
draw_over :: proc(dst, src: Image, x, y: int, opacity: f32 = 1) #no_bounds_check {
	if !valid(dst) || !valid(src) || opacity <= 0 { return }
	r := clip_rect(dst, {x, y, src.width, src.height})
	if r.w == 0 { return }
	k := u32(clamp(opacity, 0, 1) * 255 + 0.5)
	dpx, spx := words(dst), words(src)
	for j in 0 ..< r.h {
		d := dpx[(r.y + j) * dst.width + r.x:][:r.w]
		s := spx[(r.y + j - y) * src.width + (r.x - x):][:r.w]
		for &dw, i in d {
			sw := s[i]
			sp := transmute(Color)sw
			sa := (u32(sp[3]) * k + 127) / 255
			if sa == 0 { continue }
			if sa == 255 { dw = sw; continue }
			dw = word_of(over(transmute(Color)dw, sp, sa))
		}
	}
}

// `s` with alpha `sa` (0 to 255) over `d`, straight colours in and out.
@(private)
over :: #force_inline proc "contextless" (d, s: Color, sa: u32) -> Color {
	da := u32(d[3])
	// the destination's share: its alpha times what the source lets through, times 255
	dk := da * (255 - sa)
	a255 := sa * 255 + dk   // the result's alpha, times 255
	if a255 == 0 { return {} }
	out: Color
	for c in 0 ..< 3 {
		out[c] = u8((u32(s[c]) * sa * 255 + u32(d[c]) * dk + a255 / 2) / a255)
	}
	out[3] = u8((a255 + 127) / 255)
	return out
}

// Where a mark goes in a picture: a corner, the middle of a side, or the centre.
Anchor :: enum u8 {
	Top_Left, Top, Top_Right,
	Left, Center, Right,
	Bottom_Left, Bottom, Bottom_Right,
}

// The top-left corner of a `size` box put at `anchor` in a `frame` box, `margin` pixels in from the sides it touches.
anchor_point :: proc(frame, size: [2]int, anchor: Anchor, margin: int) -> [2]int {
	column, row := int(anchor) % 3, int(anchor) / 3
	at: [2]int
	switch column {
	case 0: at.x = margin
	case 1: at.x = (frame.x - size.x) / 2
	case:   at.x = frame.x - size.x - margin
	}
	switch row {
	case 0: at.y = margin
	case 1: at.y = (frame.y - size.y) / 2
	case:   at.y = frame.y - size.y - margin
	}
	return at
}

// `mark` drawn over `img` in place at `anchor`, `margin` pixels in from the sides, its alpha times `opacity`.
watermark :: proc(img, mark: Image, anchor := Anchor.Bottom_Right, margin := 16, opacity: f32 = 0.5) {
	at := anchor_point({img.width, img.height}, {mark.width, mark.height}, anchor, margin)
	draw_over(img, mark, at.x, at.y, opacity)
}

// The pictures side by side, left to right (or stacked, top to bottom, when `vertical`), `gap` pixels apart, on
// `background`. Each is centred across: a narrower one in a stack has a margin of background on each side. An empty
// picture in the list takes no room. Empty when none has pixels.
combine :: proc(images: []Image, vertical := false, gap := 0, background := TRANSPARENT, allocator := context.allocator) -> Image {
	along, across, count := 0, 0, 0
	for img in images {
		if !valid(img) { continue }
		along += vertical ? img.height : img.width
		across = max(across, vertical ? img.width : img.height)
		count += 1
	}
	if count == 0 { return {} }
	along += max(gap, 0) * (count - 1)
	out := vertical ? create(across, along, background, allocator) : create(along, across, background, allocator)
	at := 0
	for img in images {
		if !valid(img) { continue }
		// (replaced, not drawn over: a transparent part of a picture stays transparent, as a screenshot's corners)
		if vertical {
			place(out, img, (across - img.width) / 2, at)
			at += img.height + max(gap, 0)
		} else {
			place(out, img, at, (across - img.height) / 2)
			at += img.width + max(gap, 0)
		}
	}
	return out
}
