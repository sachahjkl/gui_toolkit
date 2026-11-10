package tk_site

// The colours of a code block, given when the page is made (no script in the page): the toolkit's syntax package puts
// runs of characters in classes, and each class goes in a <span> whose class the style sheet colours: .k keyword,
// .s string, .c comment, .f call or directive, .t type or number. A language it does not know is escaped plain. A project
// adds its own languages (Markdown_Context.languages).

import "core:strings"
import syntax "../syntax"

// A language of the code blocks (the syntax package's).
Code_Language :: syntax.Language

// The language called `name`: the project's first, then the syntax package's.
code_language :: proc(name: string, project: []Code_Language) -> (language: Code_Language, ok: bool) {
	return syntax.language(name, project)
}

// A code block: the language's label above it (the name as written when the language is unknown), the code coloured.
write_code_block :: proc(b: ^strings.Builder, code: string, lang: string, project: []Code_Language = nil) {
	language, known := code_language(lang, project)
	label := known ? language.label : lang
	strings.write_string(b, "<div class=\"code\">")
	if lang != "" {
		strings.write_string(b, "<div class=\"file\">")
		write_escaped(b, label)
		strings.write_string(b, "</div>")
	}
	strings.write_string(b, "<pre><code>")
	src := strings.trim_right(code, "\n")
	if known && language.highlight {
		highlight(b, src, language)
	} else {
		write_escaped(b, src)
	}
	strings.write_string(b, "</code></pre></div>\n")
}

highlight :: proc(b: ^strings.Builder, src: string, l: Code_Language) {
	spans := make([dynamic]syntax.Span, context.temp_allocator)
	syntax.spans(src, l, &spans)
	CLASSES := [syntax.Class]string{.Plain = "", .Keyword = "k", .Str = "s", .Comment = "c", .Func = "f", .Type = "t"}
	at := 0
	for sp in spans {
		write_escaped(b, src[at:sp.start])
		strings.write_string(b, "<span class=\"")
		strings.write_string(b, CLASSES[sp.class])
		strings.write_string(b, "\">")
		write_escaped(b, src[sp.start:sp.end])
		strings.write_string(b, "</span>")
		at = sp.end
	}
	write_escaped(b, src[at:])
}
