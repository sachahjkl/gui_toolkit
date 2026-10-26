package ui

import "core:math"

// Same passes as raddebugger's ui_layout_root, run once per axis:
//   1. standalone sizes   (pixels, text)
//   2. upward-dependent   (percent of the nearest ancestor that has a real size)
//   3. downward-dependent (children sum), post-order
//   4. violations         (children exceed the parent: shrink by (1 - strictness))
//   5. positions
// A box with .Draw_Border keeps its border out of the content area (like CSS border-box): its children are laid out
// inside it, so they never draw under the border (a selection outline in a menu or a bordered list stays visible).
@(private)
layout :: proc(s: ^State) {
	root := s.root
	root.size = s.window_size
	for axis in Axis {
		layout_standalone(root, axis)
		layout_upward(root, axis)
		layout_downward(root, axis)
		layout_violations(root, axis)
		layout_positions(root, axis)
	}
}

@(private)
layout_standalone :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	switch b.pref[axis].kind {
	case .Pixels: b.size[ai] = b.pref[axis].value
	case .Text:
		if axis == .Y && .Text_Wrap in b.flags {
			// the X pass is done: the lines follow the width the box got
			lines := wrap_lines_cached(b.font, b.font_size, b.text, b.size.x - 2 * b.text_pad)
			b.text_dim.y = f32(max(len(lines), 1)) * line_height_of(b)
		} else if axis == .Y && b.measure_y != nil {
			b.text_dim.y = b.measure_y(b)
		}
		b.size[ai] = math.ceil(b.text_dim[ai] + 2 * (b.text_pad + b.pref[axis].value))   // value = extra padding on top of text_pad; ceil: rounding during placement must never trigger "..." truncation
	case .None, .Percent, .Children_Sum:
	}
	for c := b.first; c != nil; c = c.next { layout_standalone(c, axis) }
}

@(private)
layout_upward :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	if b.pref[axis].kind == .Percent {
		a := b.parent
		for a != nil && a.pref[axis].kind == .Children_Sum { a = a.parent }
		b.size[ai] = a != nil ? max(0, a.size[ai] - 2 * border_inset(a)) * b.pref[axis].value : 0
	}
	for c := b.first; c != nil; c = c.next { layout_upward(c, axis) }
}

@(private)
border_inset :: proc(b: ^Box) -> f32 {
	return .Draw_Border in b.flags ? max(1, math.round(g.scale)) : 0
}

@(private)
is_floating :: proc(b: ^Box, axis: Axis) -> bool {
	return axis == .X ? .Floating_X in b.flags : .Floating_Y in b.flags
}

@(private)
layout_downward :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	for c := b.first; c != nil; c = c.next { layout_downward(c, axis) }
	if b.pref[axis].kind == .Children_Sum {
		v: f32
		if .Wrap in b.flags && axis == .Y {
			v = wrap_height(b)
		} else {
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				if axis == b.layout_axis { v += c.size[ai] } else { v = max(v, c.size[ai]) }
			}
			if .Wrap in b.flags && axis == .X {   // natural width: everything on one line
				n := 0
				for c := b.first; c != nil; c = c.next { if !is_floating(c, axis) { n += 1 } }
				v += b.gap.x * f32(max(n - 1, 0))
			}
			v += 2 * border_inset(b)
		}
		b.size[ai] = v
	}
}

// Height of a .Wrap box: tallest item of each line, plus the gaps between lines (lines come from the X pass).
@(private)
wrap_height :: proc(b: ^Box) -> f32 {
	total: f32
	line, lines := -1, 0
	line_h: f32
	for c := b.first; c != nil; c = c.next {
		if is_floating(c, .Y) { continue }
		if c.wrap_line != line {
			total += line_h
			line_h = 0
			line = c.wrap_line
			lines += 1
		}
		line_h = max(line_h, c.size.y)
	}
	total += line_h
	return total + b.gap.y * f32(max(lines - 1, 0)) + 2 * border_inset(b)
}

@(private)
layout_violations :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	overflow := axis == .X ? .Allow_Overflow_X in b.flags : .Allow_Overflow_Y in b.flags
	if !overflow {
		avail := b.size[ai] - 2 * border_inset(b)
		if .Wrap in b.flags {
			// items keep their size and move to the next line instead; only an item wider than the box shrinks
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				violation := c.size[ai] - avail
				if violation > 0 { c.size[ai] -= min(violation, c.size[ai] * (1 - c.pref[axis].strictness)) }
			}
		} else if axis == b.layout_axis {
			total, budget: f32
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				total += c.size[ai]
				budget += c.size[ai] * (1 - c.pref[axis].strictness)
			}
			violation := total - avail
			if violation > 0.01 && budget > 0 {
				for c := b.first; c != nil; c = c.next {
					if is_floating(c, axis) { continue }
					share := c.size[ai] * (1 - c.pref[axis].strictness) / budget
					c.size[ai] = max(0, c.size[ai] - violation * share)
				}
			}
		} else {
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				violation := c.size[ai] - avail
				if violation > 0 {
					c.size[ai] -= min(violation, c.size[ai] * (1 - c.pref[axis].strictness))
				}
			}
		}
	}
	for c := b.first; c != nil; c = c.next { layout_violations(c, axis) }
}

@(private)
layout_positions :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	scrolls := axis == .X ? .View_Scroll_X in b.flags : .View_Scroll_Y in b.flags
	off := scrolls ? b.view_off[ai] : 0
	inset := border_inset(b)
	cursor := inset
	extent: f32
	if .Wrap in b.flags {
		layout_wrap_positions(b, axis, off)
		for c := b.first; c != nil; c = c.next { layout_positions(c, axis) }
		return
	}
	for c := b.first; c != nil; c = c.next {
		if is_floating(c, axis) {
			c.rel_pos[ai] = c.fixed_pos[ai]
		} else if axis == b.layout_axis {
			c.rel_pos[ai] = cursor
			cursor += c.size[ai]
			extent = max(extent, cursor)
		} else {
			switch b.cross {
			case .Start:  c.rel_pos[ai] = inset
			case .Center: c.rel_pos[ai] = (b.size[ai] - c.size[ai]) * 0.5
			case .End:    c.rel_pos[ai] = b.size[ai] - inset - c.size[ai]
			}
			extent = max(extent, c.rel_pos[ai] + c.size[ai])
		}
		lo := math.round(b.rect.min[ai] + c.rel_pos[ai] - off)
		hi := math.round(b.rect.min[ai] + c.rel_pos[ai] - off + c.size[ai])
		c.rect.min[ai] = lo
		c.rect.max[ai] = hi
	}
	b.view_bounds[ai] = extent + inset
	for c := b.first; c != nil; c = c.next { layout_positions(c, axis) }
}

// .Wrap boxes. X pass: place items left to right and start a new line when the next one does not fit.
// Y pass: stack the lines, each item vertically centred in its line.
@(private)
layout_wrap_positions :: proc(b: ^Box, axis: Axis, off: f32) {
	ai := int(axis)
	inset := border_inset(b)
	if axis == .X {
		x := inset
		line := 0
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) { c.rel_pos.x = c.fixed_pos.x; continue }
			if x > inset && x + c.size.x > b.size.x - inset + 0.5 { line += 1; x = inset }
			c.rel_pos.x = x
			c.wrap_line = line
			x += c.size.x + b.gap.x
		}
	} else {
		// line tops and heights
		tops := make([dynamic]f32, 0, 8, context.temp_allocator)
		heights := make([dynamic]f32, 0, 8, context.temp_allocator)
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) { continue }
			for len(heights) <= c.wrap_line { append(&heights, 0) }
			heights[c.wrap_line] = max(heights[c.wrap_line], c.size.y)
		}
		y := inset
		for h in heights { append(&tops, y); y += h + b.gap.y }
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) { c.rel_pos.y = c.fixed_pos.y; continue }
			c.rel_pos.y = tops[c.wrap_line] + (heights[c.wrap_line] - c.size.y) * 0.5
		}
	}
	for c := b.first; c != nil; c = c.next {
		c.rect.min[ai] = math.round(b.rect.min[ai] + c.rel_pos[ai] - off)
		c.rect.max[ai] = math.round(b.rect.min[ai] + c.rel_pos[ai] - off + c.size[ai])
	}
	b.view_bounds[ai] = b.size[ai]
}