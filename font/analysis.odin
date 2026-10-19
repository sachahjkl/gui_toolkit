package font

// Text analyses for layout: bidirectional levels (UAX #9) and line break opportunities (UAX #14), from DirectWrite.

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
	if s.analyzer == nil {
		if rtl { for &l in levels { l = 1 } }
		return levels
	}
	w, bytes := utf16_of(text)
	an: Analysis
	analysis_init(&an, w, rtl)
	lv := make([]u8, len(w), context.temp_allocator)
	base := u8(rtl ? 1 : 0)
	for &l in lv { l = base }
	an.levels = lv
	s.analyzer->AnalyzeBidi(&an.source, 0, u32(len(w)), &an.sink)
	for i in 0 ..< len(w) {
		for b in bytes[i] ..< bytes[i + 1] { levels[b] = lv[i] }
	}
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

// Line break opportunities inside `text` (UAX #14 with DirectWrite's dictionaries for Thai, Lao, Khmer, Myanmar...),
// in order, excluding the start of the text.
line_breaks :: proc(s: ^State, text: string, allocator := context.allocator) -> []Break_Opportunity {
	out := make([dynamic]Break_Opportunity, 0, 8, allocator)
	if s.analyzer == nil || len(text) == 0 { return out[:] }
	w, bytes := utf16_of(text)
	an: Analysis
	analysis_init(&an, w, false)
	bp := make([]DWRITE_LINE_BREAKPOINT, len(w), context.temp_allocator)
	an.breaks = bp
	if s.analyzer->AnalyzeLineBreakpoints(&an.source, 0, u32(len(w)), &an.sink) < 0 { return out[:] }
	for i in 1 ..< len(w) {
		if bytes[i] == bytes[i - 1] { continue }   // second unit of a surrogate pair
		after := DWRITE_BREAK_CONDITION(u8(bp[i - 1]) >> 2 & 3)
		before := DWRITE_BREAK_CONDITION(u8(bp[i]) & 3)
		switch {
		case after == .MUST_BREAK || before == .MUST_BREAK: append(&out, Break_Opportunity{int(bytes[i]), true})
		case after == .MAY_NOT_BREAK || before == .MAY_NOT_BREAK:
		case after == .CAN_BREAK || before == .CAN_BREAK: append(&out, Break_Opportunity{int(bytes[i]), false})
		}
	}
	return out[:]
}
