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

// The diagram as a drawing (svg.destroy frees it). why: "" when it is one, else why not (temp memory).
diagram :: proc(text: string, dark := false, font_size: f64 = 0) -> (doc: svg.Document, why: string) {
	s, err := to_svg(text, dark ? "dark" : "default", font_size, context.temp_allocator)
	if err != "" { return {}, err }
	d, ok := svg.parse(s)
	if !ok { return {}, "the library gave no drawing" }
	return d, ""
}
