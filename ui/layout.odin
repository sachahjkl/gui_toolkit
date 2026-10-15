package ui

import "core:math"

// Same passes as raddebugger's ui_layout_root, run once per axis:
//   1. standalone sizes   (pixels, text)
//   2. upward-dependent   (percent of the nearest ancestor that has a real size)
//   3. downward-dependent (children sum), post-order
//   4. violations         (children exceed the parent: shrink by (1 - strictness))
//   5. positions
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
	case .Text:   b.size[ai] = b.text_dim[ai] + 2 * (b.text_pad + b.pref[axis].value)   // value = extra padding on top of text_pad
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
		b.size[ai] = a != nil ? a.size[ai] * b.pref[axis].value : 0
	}
	for c := b.first; c != nil; c = c.next { layout_upward(c, axis) }
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
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) { continue }
			if axis == b.layout_axis { v += c.size[ai] } else { v = max(v, c.size[ai]) }
		}
		b.size[ai] = v
	}
}

@(private)
layout_violations :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	overflow := axis == .X ? .Allow_Overflow_X in b.flags : .Allow_Overflow_Y in b.flags
	if !overflow {
		avail := b.size[ai]
		if axis == b.layout_axis {
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
	cursor: f32
	extent: f32
	for c := b.first; c != nil; c = c.next {
		if is_floating(c, axis) {
			c.rel_pos[ai] = c.fixed_pos[ai]
		} else if axis == b.layout_axis {
			c.rel_pos[ai] = cursor
			cursor += c.size[ai]
			extent = max(extent, cursor)
		} else {
			switch b.cross {
			case .Start:  c.rel_pos[ai] = 0
			case .Center: c.rel_pos[ai] = (b.size[ai] - c.size[ai]) * 0.5
			case .End:    c.rel_pos[ai] = b.size[ai] - c.size[ai]
			}
			extent = max(extent, c.size[ai])
		}
		lo := math.round(b.rect.min[ai] + c.rel_pos[ai] - off)
		hi := math.round(b.rect.min[ai] + c.rel_pos[ai] - off + c.size[ai])
		c.rect.min[ai] = lo
		c.rect.max[ai] = hi
	}
	b.view_bounds[ai] = extent
	for c := b.first; c != nil; c = c.next { layout_positions(c, axis) }
}
