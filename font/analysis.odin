package font

// Text analyses for layout: bidirectional levels (UAX #9) and line break opportunities (UAX #14), from the backend
// (backend.odin).

// A directional run of a paragraph: bytes [start, end) at an embedding level (odd: right to left).
Bidi_Run :: struct {
	start, end: int,
	level:      u8,
}

// Resolved embedding level of each byte of `text` (one paragraph). `dir` is the paragraph direction (Auto: the first
// strong character, else left to right). Text without right-to-left characters or controls in a left-to-right
// paragraph is all level 0 without calling DirectWrite.
bidi_levels :: proc(s: ^State, text: string, dir: Direction, allocator := context.allocator) -> []u8 {
	levels := make([]u8, len(text), allocator)
	rtl := dir == .Rtl || (dir == .Auto && first_strong_rtl(text))
	if len(text) == 0 { return levels }
	if !rtl && !maybe_rtl(text) { return levels }
	if rtl { for &l in levels { l = 1 } }
	if s.tb == nil { return levels }
	s.tb.bidi(s, text, rtl, levels)
	return levels
}

// The level runs of `text`, in logical order.
bidi_runs :: proc(s: ^State, text: string, dir: Direction, allocator := context.allocator) -> []Bidi_Run {
	levels := bidi_levels(s, text, dir, context.temp_allocator)
	return runs_of_levels(levels, allocator)
}

runs_of_levels :: proc(levels: []u8, allocator := context.allocator) -> []Bidi_Run {
	runs := make([dynamic]Bidi_Run, 0, 4, allocator)
	i := 0
	for i < len(levels) {
		j := i + 1
		for j < len(levels) && levels[j] == levels[i] { j += 1 }
		append(&runs, Bidi_Run{i, j, levels[i]})
		i = j
	}
	return runs[:]
}

// Visual order of runs given their levels (UAX #9 L2): from the highest level down to the lowest odd level, every
// maximal sequence at that level or higher is reversed. Returns indices into `runs`, left to right.
visual_order :: proc(runs: []Bidi_Run, allocator := context.allocator) -> []int {
	levels := make([]u8, len(runs), context.temp_allocator)
	for r, i in runs { levels[i] = r.level }
	return reorder(levels, allocator)
}

// L2 on a list of levels (one per item): the visual order of the items, left to right.
reorder :: proc(levels: []u8, allocator := context.allocator) -> []int {
	n := len(levels)
	order := make([]int, n, allocator)
	for i in 0 ..< n { order[i] = i }
	if n == 0 { return order }
	hi, lo_odd := u8(0), u8(255)
	for l in levels {
		hi = max(hi, l)
		if l & 1 == 1 { lo_odd = min(lo_odd, l) }
	}
	if lo_odd == 255 { return order }
	for lvl := int(hi); lvl >= int(lo_odd); lvl -= 1 {
		i := 0
		for i < n {
			if int(levels[order[i]]) < lvl { i += 1; continue }
			j := i
			for j < n && int(levels[order[j]]) >= lvl { j += 1 }
			for a, b := i, j - 1; a < b; a, b = a + 1, b - 1 { order[a], order[b] = order[b], order[a] }
			i = j
		}
	}
	return order
}

Break_Opportunity :: struct {
	at:        int,    // byte index: a line may break before it
	mandatory: bool,   // a hard break (after a line separator...)
}

// Line break opportunities inside `text` (UAX #14 with dictionaries for Thai, Lao, Khmer, Myanmar...),
// in order, excluding the start of the text.
line_breaks :: proc(s: ^State, text: string, allocator := context.allocator) -> []Break_Opportunity {
	out := make([dynamic]Break_Opportunity, 0, 8, allocator)
	if s.tb == nil || len(text) == 0 { return out[:] }
	if !s.tb.line_breaks(s, text, &out) { clear(&out) }
	return out[:]
}
