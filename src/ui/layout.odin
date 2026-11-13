package ui

import "core:fmt"
import "core:math"

// Same passes as raddebugger's ui_layout_root, run once per axis:
//   1. standalone sizes   (pixels, text)
//   2. upward-dependent   (percent of the nearest ancestor that has a real size)
//   3. downward-dependent (children sum), post-order
//   4. violations         (children exceed the parent: shrink by (1 - strictness), never under Size.least)
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
	b.size[ai] = max(b.size[ai], b.pref[axis].least)
	for c := b.first; c != nil; c = c.next { layout_standalone(c, axis) }
}

@(private)
layout_upward :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	if b.pref[axis].kind == .Percent {
		a := b.parent
		for a != nil && a.pref[axis].kind == .Children_Sum { a = a.parent }
		b.size[ai] = a != nil ? max(0, a.size[ai] - 2 * border_inset(a)) * b.pref[axis].value : 0
		// the classic mistake: a percentage inside a box sized by its children is of a distant ancestor (often the
		// window): a label meant to fill its row's height stretches the row, a dialog, a list to the window's
		if gs().layout_warnings && a != b.parent && b.size[ai] > gs().window_size[ai] * 0.5 { layout_warn(b, axis, a) }
		b.size[ai] = max(b.size[ai], b.pref[axis].least)
	}
	for c := b.first; c != nil; c = c.next { layout_upward(c, axis) }
}

// One warning per box (by key) for the percentage that went past a box sized by its children (layout_upward).
@(private)
layout_warn :: proc(b: ^Box, axis: Axis, ancestor: ^Box) {
	if b.key in gs().layout_warned { return }
	name := b.name != "" ? b.name : "(unnamed)"
	anc := ancestor != nil && ancestor.name != "" ? ancestor.name : "the window"
	msg := fmt.aprintf("%s: its %s is %.0f%% of %s's (%.0f px): its parent %s is sized by its children, so the percentage went past it. Give it a size of its own (px, text_size) or give the parent one.",
		name, axis == .X ? "width" : "height", b.pref[axis].value * 100, anc, b.size[int(axis)], b.parent != nil && b.parent.name != "" ? b.parent.name : "(unnamed)")
	gs().layout_warned[b.key] = msg
	fmt.eprintfln("ui: layout: %s", msg)
}

// The layout warnings given so far (each once), for a tool or a test to show them (temp memory).
layout_warnings :: proc() -> []string {
	out := make([dynamic]string, 0, len(gs().layout_warned), context.temp_allocator)
	for _, m in gs().layout_warned { append(&out, m) }
	return out[:]
}

@(private)
border_inset :: proc(b: ^Box) -> f32 {
	return .Draw_Border in b.flags ? max(1, math.round(gs().scale)) : 0
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
		b.size[ai] = max(v, b.pref[axis].least)
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

@(private = "file") LAYOUT_VIOLATION_EPS_PX :: 0.01   // children over by less than this are left alone

@(private)
layout_violations :: proc(b: ^Box, axis: Axis) {
	ai := int(axis)
	overflow := axis == .X ? .Allow_Overflow_X in b.flags : .Allow_Overflow_Y in b.flags
	// (a percentage is of the box's size now, the violations above it done: the upward pass gave it the box's size
	// before an ancestor shrank, and a box that lets its children overflow kept them that large)
	if overflow && b.pref[axis].kind != .Children_Sum {
		avail := b.size[ai] - 2 * border_inset(b)
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) || c.pref[axis].kind != .Percent { continue }
			c.size[ai] = max(0, avail * c.pref[axis].value, c.pref[axis].least)
		}
	}
	// A view inside a view that scrolls the same way gives up what passes the outer one's room, and scrolls to it itself:
	// one bar on that axis, the innermost's. (The outer view kept it whole: two bars, one under the other, for one content.)
	if overflow && box_scrolls(b, axis) && b.pref[axis].kind != .Children_Sum {
		avail := b.size[ai] - 2 * border_inset(b)
		if axis == b.layout_axis {
			violation := -avail
			for c := b.first; c != nil; c = c.next { if !is_floating(c, axis) { violation += c.size[ai] } }
			for c := b.first; c != nil && violation > LAYOUT_VIOLATION_EPS_PX; c = c.next {
				if is_floating(c, axis) || !box_scrolls(c, axis) { continue }
				give := min(shrinkable(c, axis), violation)
				c.size[ai] -= give
				violation -= give
			}
		} else {
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) || !box_scrolls(c, axis) { continue }
				if violation := c.size[ai] - avail; violation > 0 { c.size[ai] -= min(violation, shrinkable(c, axis)) }
			}
		}
	}
	if !overflow {
		avail := b.size[ai] - 2 * border_inset(b)
		if .Wrap in b.flags {
			// items keep their size and move to the next line instead; only an item wider than the box shrinks (its words
			// wrapping when its strictness keeps it wider)
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				violation := c.size[ai] - avail
				if violation > 0 { c.size[ai] -= min(violation, shrinkable(c, axis)) }
				if left := c.size[ai] - avail; left > 0 && axis == .X { c.size.x -= min(left, wrap_room(c)) }
			}
		} else if axis == b.layout_axis {
			total, budget: f32
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				total += c.size[ai]
				budget += shrinkable(c, axis)
			}
			violation := total - avail
			// (a fill() share gives what it has beyond what is in it first: two buttons that share a row by halves keep
			// their words whole when the row holds both, rather than both shrink by the same share)
			if axis == .X && violation > LAYOUT_VIOLATION_EPS_PX {
				slack: f32
				for c := b.first; c != nil; c = c.next { if !is_floating(c, axis) { slack += share_slack(c) } }
				if slack > 0 {
					taken := min(slack, violation)
					for c := b.first; c != nil; c = c.next {
						if is_floating(c, axis) { continue }
						give := share_slack(c)
						if give <= 0 { continue }
						give = min(give, taken * give / slack)
						c.size.x -= give
					}
					violation -= taken
					budget = 0
					for c := b.first; c != nil; c = c.next { if !is_floating(c, axis) { budget += shrinkable(c, axis) } }
				}
			}
			if violation > LAYOUT_VIOLATION_EPS_PX && budget > 0 {
				for c := b.first; c != nil; c = c.next {
					if is_floating(c, axis) { continue }
					give := shrinkable(c, axis)
					c.size[ai] = max(0, c.size[ai] - min(give, violation * give / budget))
				}
			}
			// (still too wide once what may shrink did: words wrap onto more lines rather than spill past the edge and be
			// cut. A second step, so a row's fill() spacers and shares give way first, as they did)
			if axis == .X { layout_wrap_give(b, avail) }
		} else {
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				violation := c.size[ai] - avail
				if violation > 0 { c.size[ai] -= min(violation, shrinkable(c, axis)) }
				if left := c.size[ai] - avail; left > 0 && axis == .X { c.size.x -= min(left, wrap_room(c)) }
			}
		}
	}
	for c := b.first; c != nil; c = c.next { layout_violations(c, axis) }
}

// How much of its size a box gives up when its parent is too small: (1 - strictness) of it, never going under its least.
// A box that scrolls that way gives all of it down to its least, whatever its strictness: it scrolls to what it hides.
@(private = "file")
shrinkable :: proc(c: ^Box, axis: Axis) -> f32 {
	ai := int(axis)
	p := c.pref[axis]
	if box_scrolls(c, axis) { return max(0, c.size[ai] - p.least) }
	return max(0, min(c.size[ai] * (1 - p.strictness), c.size[ai] - p.least))
}

// What a fill() share of a row's width (a box with children) has beyond what is in it (natural_width), and gives first
// when the row is too narrow; 0 for a box of another size or with nothing in it.
@(private = "file")
share_slack :: proc(c: ^Box) -> f32 {
	if c.pref[.X].kind != .Percent || c.first == nil { return 0 }
	return max(0, min(c.size.x - natural_width(c), shrinkable(c, .X)))
}

// A row's children along X still wider together than `avail` after what may shrink did: each gives what its words can
// by wrapping (wrap_room), in proportion to it.
@(private = "file")
layout_wrap_give :: proc(b: ^Box, avail: f32) {
	total, room: f32
	for c := b.first; c != nil; c = c.next {
		if !is_floating(c, .X) { total += c.size.x }
	}
	violation := total - avail
	// (what fits asks nothing of its words: they are measured only when the row is too narrow)
	if violation <= LAYOUT_VIOLATION_EPS_PX { return }
	for c := b.first; c != nil; c = c.next {
		if !is_floating(c, .X) { room += wrap_room(c) }
	}
	if room <= 0 { return }
	for c := b.first; c != nil; c = c.next {
		if is_floating(c, .X) { continue }
		r := wrap_room(c)
		c.size.x = max(0, c.size.x - min(r, violation * r / room))
	}
}

// A line of wrapped words is never narrower than this many of its font sizes (its text_pad aside): narrower, each word
// breaks between letters.
@(private = "file") WRAP_LEAST_EM :: 3

// How much narrower a box can be, as laid out so far along X, by wrapping the words in it onto more lines: a .Text_Wrap
// box of a text width gives what is over WRAP_LEAST_EM, and a text that is never cut (.No_Text_Trunc: a button's words)
// what is over its widest word (its lines break only between words: the box stays wider, the never-cut rule); a box of
// boxes, what its children give (in a row, all of them; in a column, as much as the widest can; in a .Wrap box, what its
// widest item can, the others moving to new lines). Never under the box's least. A box that lets its children overflow,
// or scrolls them, gives nothing (they already fit).
@(private)
wrap_room :: proc(b: ^Box) -> f32 {
	if .Text_Wrap in b.flags {
		if b.pref[.X].kind != .Text { return 0 }
		least := max(b.pref[.X].least, 2 * b.text_pad + b.font_size * WRAP_LEAST_EM)
		if .No_Text_Trunc in b.flags && b.size.x > least {
			least = max(least, math.ceil(2 * b.text_pad + widest_word_cached(b.font, b.font_size, b.text)))
		}
		return max(0, b.size.x - least)
	}
	if b.first == nil || .Allow_Overflow_X in b.flags || .View_Scroll_X in b.flags { return 0 }
	inner := b.size.x - 2 * border_inset(b)
	room: f32
	switch {
	case .Wrap in b.flags:
		widest: f32
		for c := b.first; c != nil; c = c.next {
			if !is_floating(c, .X) { widest = max(widest, c.size.x - wrap_room(c)) }
		}
		room = inner - widest
	case b.layout_axis == .X:
		for c := b.first; c != nil; c = c.next {
			if !is_floating(c, .X) { room += wrap_room(c) }
		}
	case:
		room = math.F32_MAX
		for c := b.first; c != nil; c = c.next {
			if !is_floating(c, .X) { room = min(room, wrap_room(c) + inner - c.size.x) }
		}
		if room == math.F32_MAX { room = 0 }
	}
	return clamp(room, 0, max(0, b.size.x - b.pref[.X].least))
}

// The width box `b` asks for along X, before any layout: given in pixels, of its text (a .Text_Wrap box's on one line),
// of its children (in a row their sum, in a column the widest; a .Wrap box all on one line), a fill() share's least
// and its children's. What a box that scrolls or lets its children overflow holds is not counted, nor what floats.
// What a panel that grows to its content (a dialog, a popover) measures before its layout: one source, the layout's.
natural_width :: proc(b: ^Box) -> f32 {
	p := b.pref[.X]
	v: f32
	switch p.kind {
	case .Pixels: v = p.value
	case .Text: v = math.ceil(b.text_dim.x + 2 * (b.text_pad + p.value))
	case .None:
	case .Percent, .Children_Sum:
		if .Allow_Overflow_X in b.flags || .View_Scroll_X in b.flags { break }
		n := 0
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, .X) { continue }
			w := natural_width(c)
			if b.layout_axis == .X || .Wrap in b.flags { v += w; n += 1 } else { v = max(v, w) }
		}
		if .Wrap in b.flags { v += b.gap.x * f32(max(n - 1, 0)) }
		if b.first != nil { v += 2 * border_inset(b) }
	}
	return max(v, p.least)
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
		ends := make([dynamic]f32, 0, 8, context.temp_allocator)   // each line's right end
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) { c.rel_pos.x = c.fixed_pos.x; continue }
			if x > inset && x + c.size.x > b.size.x - inset + 0.5 { line += 1; x = inset }
			c.rel_pos.x = x
			c.wrap_line = line
			x += c.size.x
			for len(ends) <= line { append(&ends, inset) }
			ends[line] = x
			x += b.gap.x
		}
		// (its cross alignment says where each line goes: a dialog's buttons at its right, wrapped ones too)
		if b.cross != .Start {
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) { continue }
				spare := max(0, b.size.x - inset - ends[c.wrap_line])
				c.rel_pos.x += b.cross == .End ? spare : math.round(spare * 0.5)
			}
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
// Layout warnings (printed once per box, on stderr): the percentage of a box sized by its children that went past it to a
// distant ancestor. On in debug builds; an application may turn them on in a release build to look for mistakes.
set_layout_warnings :: proc(s: ^State, on: bool) { s.layout_warnings = on }

// Whether a box scrolls its content along `axis` (View_Scroll_X, View_Scroll_Y).
@(private)
box_scrolls :: proc(b: ^Box, axis: Axis) -> bool { return axis == .X ? .View_Scroll_X in b.flags : .View_Scroll_Y in b.flags }
