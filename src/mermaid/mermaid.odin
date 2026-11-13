// Package mermaid: a Mermaid diagram's text (flowchart, sequence, class, state, ER, gantt, pie, mindmap, timeline, git
// graph...) to a drawing the svg package draws with the toolkit's paths and fonts. The diagram is laid out by mermaid-svg,
// in native/mermaid (gt_mermaid): no browser, no JavaScript.
//
//	doc, why := mermaid.diagram(text, dark = true)
//	if why == "" { svg.draw_doc(dc, &doc, at, scale, {regular = f, bold = fb}); svg.destroy(&doc) }
//
// It links build/mermaid/gt_mermaid.lib (tools/tk build_mermaid). A program that has a Rust library of its own builds gt_mermaid
// into it (as a dependency: its gt_mermaid_* functions stay exported) and builds with -define:MERMAID_NATIVE_LINK=false.
package tk_mermaid

import "core:strings"
import svg "../svg"

MERMAID_NATIVE_LINK :: #config(MERMAID_NATIVE_LINK, true)

when !MERMAID_NATIVE_LINK {
	// (the symbols come from the program's own Rust library, which every program links already)
	when ODIN_OS == .Windows { foreign import gt_mermaid "system:kernel32.lib" } else { foreign import gt_mermaid "system:c" }
} else when ODIN_OS == .Windows {
	foreign import gt_mermaid {
		"../../build/mermaid/gt_mermaid.lib",
		"system:ntdll.lib",
		"system:userenv.lib",
		"system:ws2_32.lib",
		"system:bcrypt.lib",
		"system:advapi32.lib",
		"system:kernel32.lib",
		"system:dbghelp.lib",
	}
} else {
	foreign import gt_mermaid {
		"../../build/mermaid/libgt_mermaid.a",
		"system:dl",
		"system:pthread",
		"system:m",
	}
}

@(private) GT_MERMAID_ABI :: 1
@(private) GT_MERMAID_OK :: 1
@(private) GT_MERMAID_ERROR :: 0

@(default_calling_convention = "c")
foreign gt_mermaid {
	@(private) gt_mermaid_abi :: proc() -> u32 ---
	@(private) gt_mermaid_render :: proc(src: [^]u8, src_len: uint, theme: [^]u8, theme_len: uint, font_size: f64, out: ^[^]u8, out_len: ^uint) -> i32 ---
	@(private) gt_mermaid_free :: proc(p: [^]u8, len: uint) ---
}

// The diagram as SVG, in `allocator`. why: "" when it is one, else what the library says of the text ("the library failed":
// it could not draw it). `theme`: mermaid's ("default", "dark", "neutral", "forest"); `font_size` 0: the theme's.
to_svg :: proc(text: string, theme := "default", font_size: f64 = 0, allocator := context.allocator) -> (out: string, why: string) {
	if gt_mermaid_abi() != GT_MERMAID_ABI { return "", "gt_mermaid is of another version" }
	p: [^]u8
	n: uint
	code := gt_mermaid_render(raw_data(text), uint(len(text)), raw_data(theme), uint(len(theme)), font_size, &p, &n)
	if p == nil { return "", "the library failed" }
	defer gt_mermaid_free(p, n)
	s := strings.clone(string(p[:n]), code == GT_MERMAID_OK ? allocator : context.temp_allocator)
	if code != GT_MERMAID_OK { return "", s }
	return s, ""
}

// The diagram as a drawing (svg.destroy frees it). why: "" when it is one, else why not (temp memory). `direction`: the way
// its graph runs (with_direction); .Text: as its text says.
diagram :: proc(text: string, dark := false, font_size: f64 = 0, direction := Direction.Text) -> (doc: svg.Document, why: string) {
	src := direction == .Text ? text : with_direction(text, direction, context.temp_allocator)
	s, err := to_svg(src, dark ? "dark" : "default", font_size, context.temp_allocator)
	if err != "" { return {}, err }
	d, ok := svg.parse(s)
	if !ok { return {}, "the library gave no drawing" }
	return d, ""
}

// The way a diagram's graph runs: mermaid's text says it ("flowchart LR", or "direction LR" in a class, state, ER or
// requirement diagram), and the same layout lays it out the other ways. .Text: as the text says.
Direction :: enum u8 { Text, Top_Down, Left_Right, Bottom_Top, Right_Left }

// Mermaid's word for a direction ("" for .Text).
direction_word :: proc(d: Direction) -> string {
	switch d {
	case .Text:       return ""
	case .Top_Down:   return "TD"
	case .Left_Right: return "LR"
	case .Bottom_Top: return "BT"
	case .Right_Left: return "RL"
	}
	return ""
}

// How a kind of diagram says its direction: on its header line (a flowchart), on a line of its own (`direction LR`), or not.
@(private)
Direction_Place :: enum u8 { None, Header, Statement }

// The header of `text`: the first line that is not empty, a comment (%%) or the front matter (between two "---" lines), its
// start in `text`, and where its direction is said.
@(private)
direction_header :: proc(text: string) -> (line: string, start: int, place: Direction_Place) {
	rest := text
	at := 0
	front := false
	first := true
	for len(rest) > 0 {
		n := strings.index_byte(rest, '\n')
		l := n < 0 ? rest : rest[:n]
		next := n < 0 ? len(rest) : n + 1
		t := strings.trim_space(l)
		if c := strings.index(t, "%%"); c >= 0 { t = strings.trim_space(t[:c]) }
		switch {
		case first && t == "---": front, first = true, false
		case front:               if t == "---" { front = false }
		case t != "":
			word := t
			if sp := strings.index_any(t, " \t;"); sp >= 0 { word = t[:sp] }
			word = strings.trim_right(word, ":")
			switch word {
			case "flowchart", "graph", "flowchart-elk":
				place = .Header
			case "classDiagram", "classDiagram-v2", "stateDiagram", "stateDiagram-v2", "erDiagram", "requirementDiagram":
				place = .Statement
			}
			return l, at, place
		}
		if t != "" { first = false }
		at += next
		rest = rest[next:]
	}
	return "", 0, .None
}

// Whether the diagram of `text` can be laid out in another direction (with_direction): a flowchart, a class, state, ER or
// requirement diagram.
takes_direction :: proc(text: string) -> bool {
	_, _, place := direction_header(text)
	return place != .None
}

// The direction the text of a diagram says (.Top_Down when it says none); .Text for a diagram that takes none.
direction_of :: proc(text: string) -> Direction {
	line, start, place := direction_header(text)
	switch place {
	case .None:
		return .Text
	case .Header:
		word, _ := header_direction(line)
		return direction_from_word(word)
	case .Statement:
		d := Direction.Top_Down
		rest := text[start:]
		for l in strings.split_lines_iterator(&rest) {
			t := strings.trim_space(l)
			if strings.has_prefix(t, "direction ") { d = direction_from_word(strings.trim_space(t[len("direction "):])) }
		}
		return d
	}
	return .Text
}

// `text` laid out in direction `d` (in `allocator`): a flowchart's header says it, another diagram has its `direction`
// lines replaced by one after its header. A diagram that takes no direction, or .Text: the text as it is (a copy).
with_direction :: proc(text: string, d: Direction, allocator := context.allocator) -> string {
	line, start, place := direction_header(text)
	if d == .Text || place == .None { return strings.clone(text, allocator) }
	b := strings.builder_make(allocator)
	strings.write_string(&b, text[:start])
	end := start + len(line)
	if place == .Header {
		lead := len(line) - len(strings.trim_left_space(line))
		t := line[lead:]
		word_end := strings.index_any(t, " \t;")
		if word_end < 0 { word_end = len(t) }
		_, after := header_direction(line)
		strings.write_string(&b, line[:lead + word_end])
		strings.write_byte(&b, ' ')
		strings.write_string(&b, direction_word(d))
		strings.write_string(&b, after)
		strings.write_string(&b, text[end:])
		return strings.to_string(b)
	}
	strings.write_string(&b, line)
	strings.write_string(&b, "\ndirection ")
	strings.write_string(&b, direction_word(d))
	rest := text[end:]
	for len(rest) > 0 {
		n := strings.index_byte(rest, '\n')
		l := n < 0 ? rest : rest[:n + 1]
		rest = rest[len(l):]
		if !strings.has_prefix(strings.trim_space(l), "direction ") { strings.write_string(&b, l) }
	}
	return strings.to_string(b)
}

// The direction word of a flowchart's header line ("" when it says none), and what follows it on the line.
@(private)
header_direction :: proc(line: string) -> (word, after: string) {
	t := strings.trim_left_space(line)
	sp := strings.index_any(t, " \t;")
	if sp < 0 { return "", "" }
	rest := t[sp:]
	r := strings.trim_left(rest, " \t")
	n := strings.index_any(r, " \t;")
	w := n < 0 ? r : r[:n]
	switch w {
	case "TD", "TB", "BT", "LR", "RL", ">", "<", "^", "v":
		return w, r[len(w):]
	}
	return "", rest
}

@(private)
direction_from_word :: proc(w: string) -> Direction {
	switch w {
	case "LR", ">": return .Left_Right
	case "BT", "^": return .Bottom_Top
	case "RL", "<": return .Right_Left
	}
	return .Top_Down
}
