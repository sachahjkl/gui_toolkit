// Package syntax: the colours of source code, by a lexer, not a parser: it puts runs of characters in classes (a comment,
// a string, a keyword, a type or a number, a call or a directive); a program colours each class (a site's style sheet, a
// text view's runs). A language it does not know is plain. The package is named tk_syntax.
//
//	l, ok := syntax.language_of_file("main.odin")       // by the file's extension (or syntax.language("odin", nil))
//	spans: [dynamic]syntax.Span
//	syntax.spans(text, l, &spans)                       // byte ranges and their classes, in order, none overlapping
package tk_syntax

import "core:strings"
import ascii "../ascii"

// A language. `names` are the words that call it (a code block's info string, lower case); `extensions` its files'.
Language :: struct {
	names:        []string,
	extensions:   []string,
	label:        string,
	highlight:    bool,       // false: only the label, the code plain
	keywords:     []string,
	types:        []string,
	line_comment: string,
	block_open:   string,
	block_close:  string,
	sigil:        byte,       // a directive's first byte (Odin's #foreign, an @attribute), 0: none
	char_quote:   bool,       // ' quotes a character or a string
	variable:     byte,       // a variable's first byte ($ in PowerShell and the shell), coloured as a type; 0: none
	preprocessor: bool,       // # at the start of a line runs to its end (C)
}

// What a run of characters is.
Class :: enum u8 { Plain, Keyword, Str, Comment, Func, Type }

// A run of `class` from byte `start` to `end` (not included).
Span :: struct {
	start, end: int,
	class:      Class,
}

// The languages every project gets.
@(rodata)
LANGUAGES := [?]Language{
	{
		names = {"odin"}, extensions = {"odin"}, label = "Odin", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", sigil = '#', char_quote = true,
		keywords = {"package", "import", "proc", "return", "if", "else", "for", "switch", "case", "in", "when", "defer", "using", "struct", "union", "enum", "bit_set", "map", "distinct", "foreign", "cast", "transmute", "auto_cast", "or_else", "or_return", "break", "continue", "fallthrough", "do", "dynamic", "context", "nil", "true", "false", "matrix", "bit_field"},
		types = {"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f16", "f32", "f64", "bool", "b8", "b16", "b32", "b64", "byte", "rune", "string", "cstring", "rawptr", "uintptr", "any", "typeid", "complex64", "complex128"},
	},
	{
		names = {"c"}, extensions = {"c", "h", "cpp", "hpp", "cc", "cxx"}, label = "C", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true, preprocessor = true,
		keywords = {"if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "sizeof", "typedef", "struct", "union", "enum", "static", "const", "extern", "inline", "volatile", "register", "restrict", "_Bool", "NULL"},
		types = {"void", "char", "short", "int", "long", "float", "double", "unsigned", "signed", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "bool"},
	},
	{
		names = {"js", "javascript", "ts", "typescript"}, extensions = {"js", "mjs", "cjs", "ts", "tsx", "jsx"}, label = "JavaScript", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/",
		keywords = {"var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "try", "catch", "finally", "throw", "async", "await", "yield", "import", "export", "from", "as", "void", "null", "undefined", "true", "false"},
		types = {"Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set", "Symbol", "JSON", "Math", "Date", "RegExp", "Error", "console", "document", "window"},
	},
	{
		names = {"powershell", "ps1", "pwsh"}, extensions = {"ps1", "psm1"}, label = "PowerShell", highlight = true, line_comment = "#", block_open = "<#", block_close = "#>", variable = '$',
		keywords = {"if", "else", "elseif", "for", "foreach", "while", "do", "switch", "function", "return", "break", "continue", "try", "catch", "finally", "throw", "param", "begin", "process", "end", "in", "filter"},
		types = {"true", "false", "null"},
	},
	{names = {"json"}, extensions = {"json"}, label = "JSON", highlight = true, keywords = {"true", "false", "null"}},
	{
		names = {"rust", "rs"}, extensions = {"rs"}, label = "Rust", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true,
		keywords = {"fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "while", "loop", "if", "else", "match", "return", "break", "continue", "pub", "use", "mod", "crate", "self", "super", "as", "where", "move", "ref", "dyn", "async", "await", "unsafe", "extern", "type", "true", "false"},
		types = {"i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"},
	},
	{names = {"html"}, extensions = {"html", "htm"}, label = "HTML"},
	{names = {"css"}, extensions = {"css"}, label = "CSS"},
	{
		names = {"bash", "sh", "shell"}, extensions = {"sh", "bash", "zsh"}, label = "Shell", highlight = true, line_comment = "#", variable = '$',
		keywords = {"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "break", "continue", "local", "export", "readonly", "set", "unset", "echo", "exit"},
	},
	{
		names = {"python", "py"}, extensions = {"py", "pyw"}, label = "Python", highlight = true, line_comment = "#", char_quote = true, sigil = '@',
		keywords = {"def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "async", "await", "None", "True", "False", "self"},
		types = {"int", "float", "str", "bytes", "bool", "list", "dict", "set", "tuple", "object"},
	},
	{
		names = {"go", "golang"}, extensions = {"go"}, label = "Go", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true,
		keywords = {"package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "select", "chan", "map", "struct", "interface", "type", "var", "const", "nil", "true", "false", "fallthrough", "goto"},
		types = {"int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "string", "bool", "byte", "rune", "error", "any"},
	},
	{names = {"text"}, label = ""},
}

// The language called `name`: the project's first, then LANGUAGES.
language :: proc(name: string, project: []Language = nil) -> (l: Language, ok: bool) {
	for x in project { for n in x.names { if n == name { return x, true } } }
	for x in LANGUAGES { for n in x.names { if n == name { return x, true } } }
	return {}, false
}

// The language of a file by its extension (any case); ok = false: none known, or one with no colours.
language_of_file :: proc(file_name: string) -> (l: Language, ok: bool) {
	dot := strings.last_index_byte(file_name, '.')
	if dot < 0 { return }
	ext := ascii.lower(file_name[dot + 1:])   // (an extension: ASCII)
	for x in LANGUAGES {
		if !x.highlight { continue }
		for e in x.extensions { if e == ext { return x, true } }
	}
	return
}

// The runs of `src` in `l`'s classes, appended to `out` in order (the plain ones left out).
spans :: proc(src: string, l: Language, out: ^[dynamic]Span) {
	span :: proc(out: ^[dynamic]Span, class: Class, from, to: int) {
		if class == .Plain || to <= from { return }
		append(out, Span{from, to, class})
	}
	i := 0
	n := len(src)
	for i < n {
		c := src[i]
		if l.line_comment != "" && strings.has_prefix(src[i:], l.line_comment) {
			end := strings.index_byte(src[i:], '\n')
			stop := end < 0 ? n : i + end
			span(out, .Comment, i, stop)
			i = stop
			continue
		}
		if l.block_open != "" && strings.has_prefix(src[i:], l.block_open) {
			close := strings.index(src[i:], l.block_close)
			stop := close < 0 ? n : i + close + len(l.block_close)
			span(out, .Comment, i, stop)
			i = stop
			continue
		}
		if c == '"' || c == '`' || (c == '\'' && l.char_quote) {
			stop := scan_string(src, i, c)
			span(out, .Str, i, stop)
			i = stop
			continue
		}
		if l.variable != 0 && c == l.variable {
			j := i + 1
			for j < n && (is_ident(src[j]) || src[j] == ':') { j += 1 }
			span(out, .Type, i, j)
			i = j
			continue
		}
		if l.sigil != 0 && c == l.sigil {
			j := i + 1
			for j < n && is_ident(src[j]) { j += 1 }
			span(out, .Func, i, j)
			i = j
			continue
		}
		if l.preprocessor && c == '#' && at_line_start(src, i) {
			end := strings.index_byte(src[i:], '\n')
			stop := end < 0 ? n : i + end
			span(out, .Func, i, stop)
			i = stop
			continue
		}
		if is_digit(c) || (c == '.' && i + 1 < n && is_digit(src[i + 1]) && !(i > 0 && is_ident(src[i - 1]))) {
			j := i
			for j < n && (is_hex_digit(src[j]) || src[j] == '.' || src[j] == 'x' || src[j] == 'X' || src[j] == '_') { j += 1 }
			for j < n && is_ident(src[j]) { j += 1 }   // a suffix: f64, u8
			span(out, .Type, i, j)
			i = j
			continue
		}
		if is_ident_start(c) {
			j := i
			for j < n && is_ident(src[j]) { j += 1 }
			word := src[i:j]
			token := Class.Plain
			switch {
			case contains_word(l.keywords, word): token = .Keyword
			case contains_word(l.types, word):    token = .Type
			case is_call(src, j):                 token = .Func
			case looks_like_type(word):           token = .Type
			}
			span(out, token, i, j)
			i = j
			continue
		}
		i += 1
	}
}


// The end of a string that starts at `i` with the quote `q`. A string other than a backtick one ends at its line, so an
// unclosed one does not colour the rest of the block.
@(private = "file")
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

@(private = "file")
at_line_start :: proc(s: string, i: int) -> bool {
	j := i - 1
	for j >= 0 && (s[j] == ' ' || s[j] == '\t') { j -= 1 }
	return j < 0 || s[j] == '\n'
}

// A name followed by '(' is a call or a definition.
@(private = "file")
is_call :: proc(s: string, j: int) -> bool {
	k := j
	for k < len(s) && (s[k] == ' ' || s[k] == '\t') { k += 1 }
	return k < len(s) && s[k] == '('
}

// A capital then a small letter somewhere: a type, by its look.
@(private = "file")
looks_like_type :: proc(word: string) -> bool {
	if len(word) < 2 || word[0] < 'A' || word[0] > 'Z' { return false }
	for i in 1 ..< len(word) { if word[i] >= 'a' && word[i] <= 'z' { return true } }
	return false
}

@(private = "file")
contains_word :: proc(words: []string, w: string) -> bool {
	for x in words { if x == w { return true } }
	return false
}
