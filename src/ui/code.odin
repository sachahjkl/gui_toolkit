package ui

// Source code in the theme's colours: tk_syntax's classes (a keyword, a string, a comment, a call, a type) coloured by the
// theme's entries code_keyword, code_string, code_comment, code_func and code_type. A paragraph of it (code_runs, then
// rich_paragraph), or an editor's (code_highlight, for text_edit).
//
//	l, ok := syntax.guess(text)                          // or syntax.language_of_file(name)
//	runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
//	ui.code_runs(text, l, {font = mono}, &runs)
//	ui.rich_paragraph("###code", runs[:])

import syntax "../syntax"

// The colour of a class of code in the current theme (the box's text colour for plain).
code_color :: proc(class: syntax.Class) -> Color {
	switch class {
	case .Keyword: return color("code_keyword")
	case .Str:     return color("code_string")
	case .Comment: return color("code_comment")
	case .Func:    return color("code_func")
	case .Type:    return color("code_type")
	case .Plain:
	}
	return color("text")
}

// `text` as runs of `style`, each class of `l` in its colour, appended to `runs` (the text's own bytes: no copy).
code_runs :: proc(text: string, l: syntax.Language, style: Rich_Style, runs: ^[dynamic]Rich_Run) {
	spans := make([dynamic]syntax.Span, context.temp_allocator)
	syntax.spans(text, l, &spans)
	code_runs_of(text, spans[:], style, runs)
}

// The same with the spans syntax.spans made already (a text kept with its spans: they are not made at each build).
code_runs_of :: proc(text: string, spans: []syntax.Span, style: Rich_Style, runs: ^[dynamic]Rich_Run) {
	at := 0
	for sp in spans {
		if sp.start > at { append(runs, Rich_Run{text = text[at:sp.start], style = style}) }
		st := style
		st.color = code_color(sp.class)
		st.italic = st.italic || sp.class == .Comment
		append(runs, Rich_Run{text = text[sp.start:sp.end], style = st})
		at = sp.end
	}
	if at < len(text) { append(runs, Rich_Run{text = text[at:], style = style}) }
}

// A text_edit's colours for `l` (the language is copied into the frame's memory: build the highlight at each build).
code_highlight :: proc(l: syntax.Language) -> ^Text_Highlight {
	lang := new_clone(l, context.temp_allocator)
	h := new(Text_Highlight, context.temp_allocator)
	h.user = lang
	h.spans = proc(user: rawptr, line_text: string, para: int, out: ^[dynamic]Text_Span) {
		spans := make([dynamic]syntax.Span, context.temp_allocator)
		syntax.spans(line_text, (^syntax.Language)(user)^, &spans)
		for sp in spans { append(out, Text_Span{sp.start, sp.end, code_color(sp.class)}) }
	}
	return h
}
