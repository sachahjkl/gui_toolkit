package platform

// Overlay windows: a window above all others, over one whole output, transparent where the program draws nothing. It
// does not move the other windows, is in no task bar, and does not take the keyboard until it is clicked. A screen
// recorder shows the frame of the region it records and its buttons in one.
//
//   w := open_overlay("cliche", area)            // nil: the system has no such window
//   set_input_region(w, {{x, y, width, height}})  // only the buttons take the pointer: the rest reaches the windows below
//   clear_input_region(w)                         // the whole window again
//
// `area` is the output to cover: x, y, width and height in the desktop's logical coordinates (gt:capture's, xdg-output's).
// All zero: the system's choice. The output whose place is `area` is chosen; else the one that holds the centre of
// `area`; else the one that overlaps it most (overlay_output_index).
//
//   * Wayland: a zwlr_layer_shell_v1 surface (layer overlay, anchored to the four edges, exclusive zone -1, keyboard
//     on demand). nil when the compositor has no layer shell (GNOME).
//   * X11: an override-redirect window with an alpha visual over the output, above the others. The input region is
//     the XShape extension's input shape (libXext, loaded at run time; without it the whole window takes the pointer).
//   * Windows: a WS_POPUP window, topmost, a tool window that is not activated by its showing. The input region is a
//     window region (SetWindowRgn), which also clips what is drawn: draw only inside it.
//
// The rects of an input region are window-relative logical pixels (physical pixels divided by `dpi_scale`).

// The index of the output an overlay over `area` covers, from the outputs' places (x, y, width, height, logical); -1
// when `area` is all zero (the system chooses) or there is no output.
overlay_output_index :: proc(outputs: [][4]int, area: [4]int) -> int {
	if area == {} || len(outputs) == 0 { return -1 }
	for o, i in outputs { if o == area { return i } }
	centre := [2]int{area[0] + area[2] / 2, area[1] + area[3] / 2}
	for o, i in outputs {
		if centre.x >= o[0] && centre.x < o[0] + o[2] && centre.y >= o[1] && centre.y < o[1] + o[3] { return i }
	}
	best, best_overlap := -1, 0
	for o, i in outputs {
		w := min(o[0] + o[2], area[0] + area[2]) - max(o[0], area[0])
		h := min(o[1] + o[3], area[1] + area[3]) - max(o[1], area[1])
		if w > 0 && h > 0 && w * h > best_overlap { best, best_overlap = i, w * h }
	}
	return best
}

// The logical places of monitors from their physical rects and scales, by gt:capture's rule (capture.layout_logical),
// so an overlay's area, taken from gt:capture, names the same monitor: the origin divided by the smallest scale, the
// size by the monitor's own, both rounded down. (Windows: the system gives physical rects.)
desktop_logical_places :: proc(physical: [][4]int, scales: []f32, allocator := context.temp_allocator) -> [][4]int {
	out := make([][4]int, len(physical), allocator)
	smallest := f32(0)
	for s in scales {
		v := s > 0 ? s : 1
		if smallest == 0 || v < smallest { smallest = v }
	}
	for r, i in physical {
		s := i < len(scales) && scales[i] > 0 ? scales[i] : 1
		out[i] = {floor_div(r[0], smallest), floor_div(r[1], smallest), floor_div(r[2], s), floor_div(r[3], s)}
	}
	return out
}

@(private = "file")
floor_div :: proc(v: int, s: f32) -> int {
	q := f64(v) / f64(s)
	i := int(q)
	return f64(i) > q ? i - 1 : i
}

// The input region's rects (logical) in physical pixels: each edge rounded outwards, so a button's edge still takes
// the pointer at a fractional scale; empty rects dropped.
overlay_input_rects_px :: proc(rects: [][4]int, scale: f32, allocator := context.temp_allocator) -> [][4]int {
	s := scale > 0 ? scale : 1
	out := make([dynamic][4]int, 0, len(rects), allocator)
	for r in rects {
		if r[2] <= 0 || r[3] <= 0 { continue }
		x0, y0 := int(f32(r[0]) * s), int(f32(r[1]) * s)
		x1, y1 := int(f32(r[0] + r[2]) * s + 0.999), int(f32(r[1] + r[3]) * s + 0.999)
		append(&out, [4]int{x0, y0, x1 - x0, y1 - y0})
	}
	return out[:]
}
