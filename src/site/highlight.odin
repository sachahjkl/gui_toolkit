package tk_site

// The colours of a code block, given when the page is made (no script in the page). A lexer, not a parser: it puts runs of
// characters in classes (comment, string, keyword, type or number, call or directive) and each class in a <span> whose class the
// style sheet colours: .k keyword, .s string, .c comment, .f call or directive, .t type or number. A language it does not know is
// escaped plain, so nothing breaks. A project adds its own languages (Markdown_Context.languages).

import "core:strings"

// A language of the code blocks. `names` are the info strings that call it (lower case); `label` is the title of its blocks.
Code_Language :: struct {
	names:        []string,
	label:        string,
	highlight:    bool,       // false: only the label, the code plain
	keywords:     []string,
	types:        []string,
	line_comment: string,
	block_open:   string,
	block_close:  string,
	sigil:        byte,       // a directive's first byte (Odin's #foreign, an @attribute), 0: none
	char_quote:   bool,       // ' quotes a character or a string
	variable:     byte,       // a variable's first byte ($ in PowerShell), coloured as a type; 0: none
	preprocessor: bool,       // # at the start of a line runs to its end (C)
}

// The languages every project gets.
@(rodata)
CODE_LANGUAGES := [?]Code_Language{
	{
		names = {"odin"}, label = "Odin", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", sigil = '#', char_quote = true,
		keywords = {"package", "import", "proc", "return", "if", "else", "for", "switch", "case", "in", "when", "defer", "using", "struct", "union", "enum", "bit_set", "map", "distinct", "foreign", "cast", "transmute", "auto_cast", "or_else", "or_return", "break", "continue", "fallthrough", "do", "dynamic", "context", "nil", "true", "false", "matrix", "bit_field"},
		types = {"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f16", "f32", "f64", "bool", "b8", "b16", "b32", "b64", "byte", "rune", "string", "cstring", "rawptr", "uintptr", "any", "typeid", "complex64", "complex128"},
	},
	{
		names = {"c"}, label = "C", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true, preprocessor = true,
		keywords = {"if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "sizeof", "typedef", "struct", "union", "enum", "static", "const", "extern", "inline", "volatile", "register", "restrict", "_Bool", "NULL"},
		types = {"void", "char", "short", "int", "long", "float", "double", "unsigned", "signed", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "bool"},
	},
	{
		names = {"js", "javascript"}, label = "JavaScript", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/",
		keywords = {"var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "try", "catch", "finally", "throw", "async", "await", "yield", "import", "export", "from", "as", "void", "null", "undefined", "true", "false"},
		types = {"Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set", "Symbol", "JSON", "Math", "Date", "RegExp", "Error", "console", "document", "window"},
	},
	{
		names = {"powershell", "ps1", "pwsh"}, label = "PowerShell", highlight = true, line_comment = "#", block_open = "<#", block_close = "#>", variable = '$',
		keywords = {"if", "else", "elseif", "for", "foreach", "while", "do", "switch", "function", "return", "break", "continue", "try", "catch", "finally", "throw", "param", "begin", "process", "end", "in", "filter"},
		types = {"true", "false", "null"},
	},
	{names = {"json"}, label = "JSON", highlight = true, keywords = {"true", "false", "null"}},
	{
		names = {"rust", "rs"}, label = "Rust", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true,
		keywords = {"fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "while", "loop", "if", "else", "match", "return", "break", "continue", "pub", "use", "mod", "crate", "self", "super", "as", "where", "move", "ref", "dyn", "async", "await", "unsafe", "extern", "type", "true", "false"},
		types = {"i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"},
	},
	{names = {"html"}, label = "HTML"},
	{names = {"css"}, label = "CSS"},
	{names = {"bash", "sh", "shell"}, label = "Shell"},
	{names = {"text"}, label = ""},
}

// The language called `name`: the project's first, then CODE_LANGUAGES.
code_language :: proc(name: string, project: []Code_Language) -> (language: Code_Language, ok: bool) {
	for l in project { for n in l.names { if n == name { return l, true } } }
	for l in CODE_LANGUAGES { for n in l.names { if n == name { return l, true } } }
	return {}, false
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

@(private)
Token :: enum {
	Plain,
	Keyword,
	Str,
	Comment,
	Func,
	Type,
}

@(private)
token_class :: proc(t: Token) -> string {
	switch t {
	case .Plain:   return ""
	case .Keyword: return "k"
	case .Str:     return "s"
	case .Comment: return "c"
	case .Func:    return "f"
	case .Type:    return "t"
	}
	return ""
}

highlight :: proc(b: ^strings.Builder, src: string, l: Code_Language) {
	i := 0
	n := len(src)
	for i < n {
		c := src[i]
		if l.line_comment != "" && strings.has_prefix(src[i:], l.line_comment) {
			end := strings.index_byte(src[i:], '\n')
			stop := end < 0 ? n : i + end
			span(b, .Comment, src[i:stop])
			i = stop
			continue
		}
		if l.block_open != "" && strings.has_prefix(src[i:], l.block_open) {
			close := strings.index(src[i:], l.block_close)
			stop := close < 0 ? n : i + close + len(l.block_close)
			span(b, .Comment, src[i:stop])
			i = stop
			continue
		}
		if c == '"' || c == '`' || (c == '\'' && l.char_quote) {
			stop := scan_string(src, i, c)
			span(b, .Str, src[i:stop])
			i = stop
			continue
		}
		if l.variable != 0 && c == l.variable {
			j := i + 1
			for j < n && (is_ident(src[j]) || src[j] == ':') { j += 1 }
			span(b, .Type, src[i:j])
			i = j
			continue
		}
		if l.sigil != 0 && c == l.sigil {
			j := i + 1
			for j < n && is_ident(src[j]) { j += 1 }
			span(b, .Func, src[i:j])
			i = j
			continue
		}
		if l.preprocessor && c == '#' && at_line_start(src, i) {
			end := strings.index_byte(src[i:], '\n')
			stop := end < 0 ? n : i + end
			span(b, .Func, src[i:stop])
			i = stop
			continue
		}
		if is_digit(c) || (c == '.' && i + 1 < n && is_digit(src[i + 1]) && !(i > 0 && is_ident(src[i - 1]))) {
			j := i
			for j < n && (is_hex_digit(src[j]) || src[j] == '.' || src[j] == 'x' || src[j] == 'X' || src[j] == '_') { j += 1 }
			for j < n && is_ident(src[j]) { j += 1 }   // a suffix: f64, u8
			span(b, .Type, src[i:j])
			i = j
			continue
		}
		if is_ident_start(c) {
			j := i
			for j < n && is_ident(src[j]) { j += 1 }
			word := src[i:j]
			token := Token.Plain
			switch {
			case contains_word(l.keywords, word): token = .Keyword
			case contains_word(l.types, word):    token = .Type
			case is_call(src, j):                 token = .Func
			case looks_like_type(word):           token = .Type
			}
			span(b, token, word)
			i = j
			continue
		}
		write_escaped(b, src[i:i + 1])
		i += 1
	}
}

@(private)
span :: proc(b: ^strings.Builder, token: Token, text: string) {
	class := token_class(token)
	if class == "" { write_escaped(b, text); return }
	strings.write_string(b, "<span class=\"")
	strings.write_string(b, class)
	strings.write_string(b, "\">")
	write_escaped(b, text)
	strings.write_string(b, "</span>")
}

@(private)
contains_word :: proc(words: []string, w: string) -> bool {
	for x in words { if x == w { return true } }
	return false
}

// The end of a string that starts at `i` with the quote `q`. A string other than a backtick one ends at its line, so an
// unclosed one does not colour the rest of the block.
@(private)
scan_string :: proc(src: string, i: int, q: byte) -> int {
	j := i + 1
	raw := q == '`'
	for j < len(src) {
		if !raw && src[j] == '\\' { j += 2; continue }
		if src[j] == q { return j + 1 }
		if src[j] == '\n' && !raw { return j }
		j += 1
	}
	return len(src)
}

@(private) is_ident_start :: proc(c: byte) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
@(private) is_ident :: proc(c: byte) -> bool { return is_ident_start(c) || is_digit(c) }
@(private) is_digit :: proc(c: byte) -> bool { return c >= '0' && c <= '9' }
@(private) is_hex_digit :: proc(c: byte) -> bool { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

@(private)
at_line_start :: proc(s: string, i: int) -> bool {
	j := i - 1
	for j >= 0 && (s[j] == ' ' || s[j] == '\t') { j -= 1 }
	return j < 0 || s[j] == '\n'
}

// A name followed by '(' is a call or a definition.
@(private)
is_call :: proc(s: string, j: int) -> bool {
	k := j
	for k < len(s) && (s[k] == ' ' || s[k] == '\t') { k += 1 }
	return k < len(s) && s[k] == '('
}

// A capital then a small letter somewhere: a type, by its look.
@(private)
looks_like_type :: proc(word: string) -> bool {
	if len(word) < 2 || word[0] < 'A' || word[0] > 'Z' { return false }
	for i in 1 ..< len(word) { if word[i] >= 'a' && word[i] <= 'z' { return true } }
	return false
}
