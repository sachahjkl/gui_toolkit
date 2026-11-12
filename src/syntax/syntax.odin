// Package syntax: the colours of source code, by a lexer, not a parser: it puts runs of characters in classes (a comment,
// a string, a keyword, a type or a number, a call or a directive); a program colours each class (a site's style sheet, a
// text view's runs). A language it does not know is plain. The package is named tk_syntax.
//
//	l, ok := syntax.language_of_file("main.odin")       // by the file's name or extension (or syntax.language("odin", nil))
//	spans: [dynamic]syntax.Span
//	syntax.spans(text, l, &spans)                       // byte ranges and their classes, in order, none overlapping
//	l, ok = syntax.guess(clipboard_text)                // by what the text holds (a #! line, signs, keywords): no name
//	                                                    // (Markdown and diffs too: l.highlight = false, the label only)
package tk_syntax

import "core:strings"
import ascii "../ascii"

// A language. `names` are the words that call it (a code block's info string, lower case); `extensions` its files'.
Language :: struct {
	names:        []string,
	extensions:   []string,
	file_names:   []string,   // whole file names that are its (Dockerfile, Makefile), any case; "Dockerfile.dev" too
	label:        string,
	highlight:    bool,       // false: only the label, the code plain
	markup:       Markup,     // tags or rules, cut by a lexer of their own: the fields below are not read
	keywords:     []string,
	types:        []string,
	line_comment: string,
	block_open:   string,
	block_close:  string,
	sigil:        byte,       // a directive's first byte (Odin's #foreign, an @attribute), 0: none
	char_quote:   bool,       // ' quotes a character or a string
	variable:     byte,       // a variable's first byte ($ in PowerShell and the shell), coloured as a type; 0: none
	preprocessor: bool,       // # at the start of a line runs to its end (C)
	fold_case:    bool,       // its keywords and types in any case (SQL); the lists in small letters
	key:          byte,       // a name at a line's start followed by it is a key, coloured as a call (YAML's ':'); 0: none
	sections:     bool,       // a [section] at a line's start is a keyword (TOML, INI)
	plain_values: bool,       // a key's unquoted value is text to its line's end, a string (INI, YAML)
	// What betrays it in a text with no name (guess): pieces only its code is likely to hold ("fn ", ":= proc", "#include")
	signs:        []string,
}

// A text that is not words and statements: tags (HTML, XML) or a style sheet's rules (CSS).
Markup :: enum u8 { None, Tags, Rules }

// What a run of characters is.
Class :: enum u8 { Plain, Keyword, Str, Comment, Func, Type }

// A run of `class` from byte `start` to `end` (not included).
Span :: struct {
	start, end: int,
	class:      Class,
}

// The languages every project gets. The order breaks guess's ties: the stricter languages first.
@(rodata)
LANGUAGES := [?]Language{
	{
		names = {"odin"}, extensions = {"odin"}, label = "Odin", highlight = true, signs = {":: proc", ":: struct", ":= ", "proc ", "proc(", "package ", "import \"core:", "#partial", "or_return"}, line_comment = "//", block_open = "/*", block_close = "*/", sigil = '#', char_quote = true,
		keywords = {"package", "import", "proc", "return", "if", "else", "for", "switch", "case", "in", "when", "defer", "using", "struct", "union", "enum", "bit_set", "map", "distinct", "foreign", "cast", "transmute", "auto_cast", "or_else", "or_return", "break", "continue", "fallthrough", "do", "dynamic", "context", "nil", "true", "false", "matrix", "bit_field"},
		types = {"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f16", "f32", "f64", "bool", "b8", "b16", "b32", "b64", "byte", "rune", "string", "cstring", "rawptr", "uintptr", "any", "typeid", "complex64", "complex128"},
	},
	{
		names = {"zig"}, extensions = {"zig", "zon"}, label = "Zig", highlight = true, line_comment = "//", sigil = '@', char_quote = true,
		signs = {"@import(", "const std = ", "std.debug.print", "!void", "errdefer ", "comptime ", "orelse ", ".{"},
		keywords = {"const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "unreachable", "struct", "enum", "union", "error", "comptime", "inline", "export", "extern", "test", "and", "or", "null", "undefined", "true", "false", "usingnamespace", "async", "await", "suspend", "resume", "threadlocal", "align", "packed", "allowzero", "anytype"},
		types = {"i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "usize", "isize", "f16", "f32", "f64", "f128", "bool", "void", "type", "anyerror", "anyopaque", "noreturn", "comptime_int", "comptime_float", "c_int"},
	},
	{
		names = {"c"}, extensions = {"c", "h", "cpp", "hpp", "cc", "cxx"}, label = "C", highlight = true, signs = {"#include", "#define", "int main(", "printf(", "->", "};", "NULL", "unsigned "}, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true, preprocessor = true,
		keywords = {"if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "sizeof", "typedef", "struct", "union", "enum", "static", "const", "extern", "inline", "volatile", "register", "restrict", "_Bool", "NULL"},
		types = {"void", "char", "short", "int", "long", "float", "double", "unsigned", "signed", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "bool"},
	},
	{
		names = {"cs", "csharp", "c#"}, extensions = {"cs", "csx"}, label = "C#", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true, preprocessor = true,
		signs = {"using System", "namespace ", "Console.Write", "{ get; set; }", "async Task", "public override ", "private readonly ", "string[] args"},
		keywords = {"abstract", "as", "base", "break", "case", "catch", "checked", "class", "const", "continue", "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "finally", "fixed", "for", "foreach", "goto", "if", "implicit", "in", "interface", "internal", "is", "lock", "namespace", "new", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "ref", "return", "sealed", "sizeof", "stackalloc", "static", "struct", "switch", "this", "throw", "try", "typeof", "unchecked", "unsafe", "using", "virtual", "volatile", "while", "async", "await", "var", "get", "set", "init", "record", "yield", "where", "null", "true", "false"},
		types = {"bool", "byte", "sbyte", "char", "decimal", "double", "float", "int", "uint", "long", "ulong", "short", "ushort", "object", "string", "void", "dynamic", "nint", "nuint"},
	},
	{
		names = {"java"}, extensions = {"java"}, label = "Java", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", sigil = '@', char_quote = true,
		signs = {"public static void", "System.out", "import java.", "public class ", "private final ", "@Override", "throws ", "new ArrayList<"},
		keywords = {"abstract", "assert", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface", "native", "new", "package", "private", "protected", "public", "return", "static", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "volatile", "while", "var", "record", "sealed", "permits", "yield", "null", "true", "false"},
		types = {"boolean", "byte", "char", "short", "int", "long", "float", "double", "void", "String", "Object", "Integer", "Long", "Double", "Boolean", "List", "Map"},
	},
	{
		names = {"kotlin", "kt", "kts"}, extensions = {"kt", "kts"}, label = "Kotlin", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", sigil = '@', char_quote = true,
		signs = {"fun main(", "fun ", "val ", "data class ", "companion object", "?.let", "override fun ", ": String"},
		keywords = {"package", "import", "class", "interface", "object", "fun", "val", "var", "if", "else", "when", "for", "while", "do", "return", "break", "continue", "try", "catch", "finally", "throw", "is", "in", "as", "typealias", "this", "super", "null", "true", "false", "data", "sealed", "enum", "open", "override", "private", "public", "protected", "internal", "abstract", "companion", "lateinit", "suspend", "inline", "by", "init", "constructor", "where"},
		types = {"Int", "Long", "Short", "Byte", "Float", "Double", "Boolean", "Char", "String", "Unit", "Any", "Nothing", "List", "Map", "Set", "Array"},
	},
	{
		names = {"swift"}, extensions = {"swift"}, label = "Swift", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", sigil = '@',
		signs = {"import SwiftUI", "import Foundation", "import UIKit", "guard let ", "-> some View", "var body: some", "@State ", "func "},
		keywords = {"import", "func", "let", "var", "if", "else", "guard", "switch", "case", "default", "for", "in", "while", "repeat", "return", "break", "continue", "class", "struct", "enum", "protocol", "extension", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "throw", "throws", "rethrows", "try", "catch", "do", "defer", "where", "as", "is", "static", "public", "private", "fileprivate", "internal", "open", "mutating", "override", "final", "lazy", "weak", "inout", "some", "any", "async", "await", "typealias", "associatedtype", "subscript"},
		types = {"Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float", "Bool", "String", "Character", "Array", "Dictionary", "Set", "Optional", "Void", "Any"},
	},
	{
		names = {"dart"}, extensions = {"dart"}, label = "Dart", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", sigil = '@', char_quote = true,
		signs = {"import 'package:", "Widget build(", "@override", "setState(", "void main() {", "StatelessWidget", "StatefulWidget", "Future<"},
		keywords = {"abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "deferred", "do", "else", "enum", "export", "extends", "extension", "external", "factory", "final", "finally", "for", "get", "if", "implements", "import", "in", "is", "late", "library", "mixin", "new", "null", "on", "operator", "part", "required", "rethrow", "return", "set", "static", "super", "switch", "this", "throw", "true", "false", "try", "typedef", "var", "while", "with", "yield"},
		types = {"int", "double", "num", "bool", "String", "List", "Map", "Set", "Future", "Stream", "void", "dynamic", "Object"},
	},
	{
		names = {"js", "javascript", "ts", "typescript"}, extensions = {"js", "mjs", "cjs", "ts", "tsx", "jsx"}, label = "JavaScript", highlight = true, signs = {"=> ", "const ", "let ", "function ", "console.", "===", "require(", "export "}, line_comment = "//", block_open = "/*", block_close = "*/",
		keywords = {"var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "try", "catch", "finally", "throw", "async", "await", "yield", "import", "export", "from", "as", "void", "null", "undefined", "true", "false"},
		types = {"Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set", "Symbol", "JSON", "Math", "Date", "RegExp", "Error", "console", "document", "window"},
	},
	{
		names = {"php"}, extensions = {"php", "phtml"}, label = "PHP", highlight = true, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true, variable = '$',
		signs = {"<?php", "$this->", "public function ", "=> $", "::class", "$_GET", "$_POST", "<?="},
		keywords = {"abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "include_once", "instanceof", "interface", "isset", "match", "namespace", "new", "or", "print", "private", "protected", "public", "readonly", "require", "require_once", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "while", "yield", "null", "true", "false"},
		types = {"int", "float", "string", "bool", "object", "mixed", "void", "callable", "iterable", "self", "parent"},
	},
	{
		names = {"powershell", "ps1", "pwsh"}, extensions = {"ps1", "psm1"}, label = "PowerShell", highlight = true, signs = {"$_", "Get-", "Set-", "-eq ", "-ne ", "param(", "Write-Host", "| Where-Object"}, line_comment = "#", block_open = "<#", block_close = "#>", variable = '$',
		keywords = {"if", "else", "elseif", "for", "foreach", "while", "do", "switch", "function", "return", "break", "continue", "try", "catch", "finally", "throw", "param", "begin", "process", "end", "in", "filter"},
		types = {"true", "false", "null"},
	},
	{names = {"json"}, extensions = {"json"}, label = "JSON", highlight = true, keywords = {"true", "false", "null"}},
	{
		names = {"sql"}, extensions = {"sql"}, label = "SQL", highlight = true, line_comment = "--", block_open = "/*", block_close = "*/", char_quote = true, fold_case = true,
		signs = {"select ", "from ", "where ", "insert into", "update ", "create table", "join ", "order by", "group by", "values ("},
		keywords = {"select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "index", "join", "left", "right", "inner", "outer", "on", "as", "order", "by", "group", "having", "limit", "offset", "distinct", "union", "all", "case", "when", "then", "else", "end", "null", "is", "in", "like", "between", "exists", "primary", "key", "foreign", "references", "default", "with", "returning", "begin", "commit", "true", "false"},
		types = {"int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean", "real", "float", "double", "numeric", "decimal", "date", "timestamp", "blob", "json", "uuid", "serial"},
	},
	{
		names = {"rust", "rs"}, extensions = {"rs"}, label = "Rust", highlight = true, signs = {"fn ", "let mut ", "impl ", "pub fn", "-> ", "::", "&mut ", "println!"}, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true,
		keywords = {"fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "while", "loop", "if", "else", "match", "return", "break", "continue", "pub", "use", "mod", "crate", "self", "super", "as", "where", "move", "ref", "dyn", "async", "await", "unsafe", "extern", "type", "true", "false"},
		types = {"i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"},
	},
	{
		names = {"nix"}, extensions = {"nix"}, label = "Nix", highlight = true, line_comment = "#", block_open = "/*", block_close = "*/",
		signs = {"{ pkgs", "pkgs.", "mkDerivation", "inherit ", "let\n", "nixpkgs", "mkShell", "...}:"},
		keywords = {"let", "in", "with", "inherit", "rec", "if", "then", "else", "assert", "import", "or", "true", "false", "null"},
		types = {"builtins"},
	},
	// Tag names are keywords, attribute names calls (as CSS's properties and the keys of YAML: a name given a value),
	// their values strings; the signs and keywords in small letters (fold_case): only guess reads them.
	{
		names = {"html", "htm", "xhtml"}, extensions = {"html", "htm", "xhtml"}, label = "HTML", highlight = true, markup = .Tags, fold_case = true,
		signs = {"<!doctype html", "<html", "<div", "<body", "<head>", "<script", "class=\"", "href=\""},
		keywords = {"html", "div", "span", "script", "doctype"},
	},
	{
		names = {"xml", "svg", "xaml", "plist"}, extensions = {"xml", "svg", "xaml", "csproj", "fsproj", "vbproj", "props", "targets", "plist", "xsd", "xsl", "xslt", "rss", "atom", "resx", "xlf"}, label = "XML", highlight = true, markup = .Tags,
		signs = {"<?xml", "xmlns", "</", "/>"},
	},
	{
		names = {"css"}, extensions = {"css"}, label = "CSS", highlight = true, markup = .Rules,
		signs = {"px;", "color: ", "margin", "padding", "@media", "display: ", "!important", "font-size"},
	},
	{
		names = {"dockerfile", "docker", "containerfile"}, extensions = {"dockerfile", "containerfile"}, file_names = {"Dockerfile", "Containerfile"}, label = "Dockerfile", highlight = true, line_comment = "#", char_quote = true, variable = '$', fold_case = true,
		signs = {"workdir ", "entrypoint ", "\nrun ", "\ncopy ", "\ncmd ", "\nenv ", "\nexpose ", "\narg "},
		keywords = {"from", "run", "cmd", "label", "maintainer", "expose", "env", "add", "copy", "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"},
	},
	{
		names = {"make", "makefile", "mk"}, extensions = {"mk", "mak"}, file_names = {"Makefile", "GNUmakefile"}, label = "Makefile", highlight = true, line_comment = "#", variable = '$', key = ':',
		signs = {".PHONY", "$<", "$^", "$(CC)", "$(MAKE)", "$(CFLAGS)", "\nall:", ":= $("},
		keywords = {"ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "define", "endef", "include", "export", "unexport", "override", "vpath"},
	},
	{
		names = {"toml"}, extensions = {"toml"}, file_names = {"Cargo.lock"}, label = "TOML", highlight = true, line_comment = "#", char_quote = true, key = '=', sections = true,
		signs = {"[package]", "[dependencies]", "[tool.", "[[package]]"},
		keywords = {"true", "false", "inf", "nan"},
	},
	{
		names = {"ini", "cfg", "conf", "desktop", "systemd"}, extensions = {"ini", "cfg", "conf", "desktop", "service", "socket", "timer", "mount", "editorconfig", "gitconfig", "properties"}, label = "INI", highlight = true, line_comment = "#", key = '=', sections = true, plain_values = true,
		signs = {"[Desktop Entry]", "[Unit]", "[Service]", "[Install]", "[core]"},
		keywords = {"true", "false", "yes", "no", "on", "off"},
	},
	{
		names = {"yaml", "yml"}, extensions = {"yaml", "yml"}, label = "YAML", highlight = true, line_comment = "#", char_quote = true, key = ':', plain_values = true,
		signs = {"---\n", "apiVersion: ", "- name: ", ": |\n"},
		keywords = {"true", "false", "null", "yes", "no", "on", "off"},
	},
	{
		names = {"bash", "sh", "shell"}, extensions = {"sh", "bash", "zsh"}, label = "Shell", highlight = true, signs = {"fi\n", "done", "$(", "${", "echo ", "then\n", "esac", "&& "}, line_comment = "#", variable = '$',
		keywords = {"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "break", "continue", "local", "export", "readonly", "set", "unset", "echo", "exit"},
	},
	{
		names = {"ruby", "rb"}, extensions = {"rb", "rake", "gemspec", "ru"}, file_names = {"Gemfile", "Rakefile"}, label = "Ruby", highlight = true, line_comment = "#", block_open = "=begin", block_close = "=end", char_quote = true, variable = '@',
		signs = {"puts ", "require '", "require \"", "require_relative", "elsif ", "attr_accessor", " do |", "\nend"},
		keywords = {"alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "require_relative", "attr_accessor", "attr_reader", "attr_writer", "puts", "lambda"},
		types = {"String", "Integer", "Float", "Array", "Hash", "Symbol", "Proc"},
	},
	{
		names = {"lua"}, extensions = {"lua"}, label = "Lua", highlight = true, line_comment = "--", block_open = "--[[", block_close = "]]", char_quote = true,
		signs = {"local function", "local ", " then\n", " .. ", "~= ", "ipairs(", "pairs(", "\nend"},
		keywords = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"},
		types = {"string", "table", "math", "io", "os", "coroutine", "self"},
	},
	{
		names = {"python", "py"}, extensions = {"py", "pyw"}, label = "Python", highlight = true, signs = {"def ", "self.", "import ", "elif ", "print(", "__init__", "None", "):\n"}, line_comment = "#", char_quote = true, sigil = '@',
		keywords = {"def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "async", "await", "None", "True", "False", "self"},
		types = {"int", "float", "str", "bytes", "bool", "list", "dict", "set", "tuple", "object"},
	},
	{
		names = {"go", "golang"}, extensions = {"go"}, label = "Go", highlight = true, signs = {"func ", ":= ", "package ", "fmt.", "err != nil", "chan ", "go func", "[]string"}, line_comment = "//", block_open = "/*", block_close = "*/", char_quote = true,
		keywords = {"package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "select", "chan", "map", "struct", "interface", "type", "var", "const", "nil", "true", "false", "fallthrough", "goto"},
		types = {"int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "string", "bool", "byte", "rune", "error", "any"},
	},
	// Known by guess (markdown_like, diff_like), not coloured: a program shows them its own way.
	{names = {"markdown", "md"}, extensions = {"md", "markdown"}, label = "Markdown"},
	{names = {"diff", "patch"}, extensions = {"diff", "patch"}, label = "Diff"},
	{names = {"text"}, label = ""},
}

// The language called `name`: the project's first, then LANGUAGES.
language :: proc(name: string, project: []Language = nil) -> (l: Language, ok: bool) {
	for x in project { for n in x.names { if n == name { return x, true } } }
	for x in LANGUAGES { for n in x.names { if n == name { return x, true } } }
	return {}, false
}

// The language of a file by its whole name (Dockerfile, Makefile, and Dockerfile.dev) or its extension, any case; a path
// is read by its last part. ok = false: none known, or one with no colours.
language_of_file :: proc(file_name: string) -> (l: Language, ok: bool) {
	base := file_name
	if slash := strings.last_index_any(file_name, "/\\"); slash >= 0 { base = file_name[slash + 1:] }
	for x in LANGUAGES {
		if !x.highlight { continue }
		for f in x.file_names {
			if ascii.equal_fold(base, f) || (len(base) > len(f) && base[len(f)] == '.' && ascii.has_prefix_fold(base, f)) { return x, true }
		}
	}
	dot := strings.last_index_byte(base, '.')
	if dot < 0 { return }
	ext := ascii.lower(base[dot + 1:])   // (an extension: ASCII)
	for x in LANGUAGES {
		if !x.highlight { continue }
		for e in x.extensions { if e == ext { return x, true } }
	}
	return
}

// The language of a text that comes with no name (a copy, a paste). First the forms that are sure: a diff (Diff, even of
// code), a #! line, "<?php", JSON, a text in tags (HTML or XML), [sections] of keys (TOML or INI), "key: value" lines
// (YAML), Markdown's signs (Markdown). Diff and Markdown come with highlight = false: the label, no colours. Else the
// language whose signs and keywords it holds the most of, the project's languages first. ok = false: prose, or nothing
// sure enough. Reads the first GUESS_READ bytes.
guess :: proc(text: string, project: []Language = nil) -> (l: Language, ok: bool) {
	src := strings.trim_left_space(text[:min(len(text), GUESS_READ)])
	if diff_like(src) { return language("diff") }
	if strings.has_prefix(src, "#!") {
		line := src
		if nl := strings.index_byte(src, '\n'); nl >= 0 { line = src[:nl] }
		switch {
		case strings.contains(line, "python"): return language("python")
		case strings.contains(line, "node") || strings.contains(line, "deno") || strings.contains(line, "bun"): return language("js")
		case strings.contains(line, "pwsh"): return language("powershell")
		case strings.contains(line, "sh"): return language("bash")
		}
	}
	if strings.has_prefix(src, "<?php") { return language("php") }
	if (strings.has_prefix(src, "{") || strings.has_prefix(src, "[")) && json_like(src) { return language("json") }
	lower := ascii.lower(src)
	if name, is_markup := markup_of(lower); is_markup { return language(name) }
	if ini, toml := ini_like(src); ini { return language(toml ? "toml" : "ini") }
	if yaml_like(src) { return language("yaml") }
	if markdown_like(src) { return language("markdown") }
	best, best_score := -1, 0
	score_of :: proc(x: Language, src, lower: string) -> int {
		if !x.highlight { return 0 }
		n := 0
		for sign in x.signs { if strings.contains(x.fold_case ? lower : src, sign) { n += GUESS_SIGN } }
		// (each keyword once: prose says "if" and "for" often)
		words := x.fold_case ? lower : src
		for k in x.keywords { if len(k) > 2 && has_word(words, k) { n += 1 } }
		return n
	}
	all := make([dynamic]Language, context.temp_allocator)
	append(&all, ..project)
	append(&all, ..LANGUAGES[:])
	for x, i in all {
		if n := score_of(x, src, lower); n > best_score { best, best_score = i, n }
	}
	if best < 0 || best_score < GUESS_ENOUGH || !code_like(src) { return }
	return all[best], true
}

// What guess reads of a text, what a sign weighs against a keyword, and the score under which a text is not code.
GUESS_READ   :: 8 * 1024
GUESS_SIGN   :: 3
GUESS_ENOUGH :: 5

// Whether `w` is in `s` as a word of its own.
@(private = "file")
has_word :: proc(s, w: string) -> bool {
	rest := s
	at := 0
	for {
		i := strings.index(rest, w)
		if i < 0 { return false }
		a := at + i
		b := a + len(w)
		if (a == 0 || !is_ident(s[a - 1])) && (b >= len(s) || !is_ident(s[b])) { return true }
		at = a + 1
		rest = s[at:]
	}
}

// Code has its punctuation: brackets, operators, ends of statements. A sentence has few of them for its letters.
@(private = "file")
code_like :: proc(src: string) -> bool {
	marks, letters := 0, 0
	for c in transmute([]u8)src {
		switch c {
		case '{', '}', '(', ')', '[', ']', ';', '=', '<', '>', '$', '#', '|', '&', ':': marks += 1
		case 'a' ..= 'z', 'A' ..= 'Z': letters += 1
		}
	}
	return marks * GUESS_MARKS_PER >= letters
}

// Of the letters, at least one mark in GUESS_MARKS_PER.
GUESS_MARKS_PER :: 40

// A text that opens and closes as JSON, with a quoted key or only values in it.
@(private = "file")
json_like :: proc(src: string) -> bool {
	t := strings.trim_right_space(src)
	if len(t) < 2 { return false }
	open, close := t[0], t[len(t) - 1]
	if !(open == '{' && close == '}') && !(open == '[' && close == ']') { return false }
	return open == '[' || strings.contains(t, "\":")
}

// A unified diff: a "diff --git" line, a "--- " line over a "+++ " line, or a hunk's "@@ -1,2 +1,3 @@" header. Checked
// before anything else: a diff of code is a diff.
@(private = "file")
diff_like :: proc(src: string) -> bool {
	rest := src
	previous := ""
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		switch {
		case strings.has_prefix(line, "diff --git "): return true
		case strings.has_prefix(line, "+++ ") && strings.has_prefix(previous, "--- "): return true
		case hunk_header(line): return true
		}
		previous = line
	}
	return false
}

// "@@ -N[,N] +N[,N] @@", what may follow it (the function's line) left out.
@(private = "file")
hunk_header :: proc(line: string) -> bool {
	// The end of "N" or "N,N" from `j`; -1: no number there.
	numbers :: proc(s: string, j: int) -> int {
		k := j
		for k < len(s) && is_digit(s[k]) { k += 1 }
		if k == j { return -1 }
		if k < len(s) && s[k] == ',' {
			m := k + 1
			for m < len(s) && is_digit(s[m]) { m += 1 }
			if m == k + 1 { return -1 }
			k = m
		}
		return k
	}
	if !strings.has_prefix(line, "@@ -") { return false }
	j := numbers(line, len("@@ -"))
	if j < 0 || !strings.has_prefix(line[j:], " +") { return false }
	j = numbers(line, j + 2)
	return j >= 0 && strings.has_prefix(line[j:], " @@")
}

// Markdown: a fenced code block (``` to ```: a snippet with a few words around it), or two kinds of its signs among a
// heading, a list, a link, emphasis, a table and a quote, or one of the last three with `inline code`. One kind is not
// enough: a note has a list, a script has "# " comments and a shell's `backticks`.
@(private = "file")
markdown_like :: proc(src: string) -> bool {
	Sign :: enum { Heading, List, Quote, Link, Emphasis, Table, Code }
	signs: bit_set[Sign]
	fences := 0
	rest := src
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if strings.has_prefix(strings.trim_left_space(line), "```") { fences += 1; continue }
		if fences % 2 == 1 { continue }   // (inside a fence: code, not signs)
		switch {
		case heading_line(line):            signs += {.Heading}
		case list_item(line):               signs += {.List}
		case strings.has_prefix(line, "> "): signs += {.Quote}
		}
		for target in ([?]string{"](http", "](./", "](../", "](/", "](#", "](mailto:"}) {
			if strings.contains(line, target) { signs += {.Link} }
		}
		if emphasis(line) { signs += {.Emphasis} }
		if table_rule(line) { signs += {.Table} }
		if strings.count(line, "`") >= 2 { signs += {.Code} }
	}
	if fences >= 2 { return true }
	return card(signs - {.Code}) >= 2 || (card(signs & {.Link, .Emphasis, .Table}) >= 1 && .Code in signs)
}

// "# Title" to "###### Title", at the line's start: an indented "# " is a comment of code.
@(private = "file")
heading_line :: proc(line: string) -> bool {
	j := 0
	for j < len(line) && line[j] == '#' { j += 1 }
	return j >= 1 && j <= 6 && j + 1 < len(line) && line[j] == ' ' && line[j + 1] != ' '
}

// "- item", "* item", "+ item", "1. item", "1) item", at the line's start: the " * " of a block comment is indented.
@(private = "file")
list_item :: proc(line: string) -> bool {
	if len(line) >= 3 && (line[0] == '-' || line[0] == '*' || line[0] == '+') && line[1] == ' ' && line[2] != ' ' { return true }
	j := 0
	for j < len(line) && is_digit(line[j]) { j += 1 }
	return j >= 1 && j + 2 < len(line) && (line[j] == '.' || line[j] == ')') && line[j + 1] == ' ' && line[j + 2] != ' '
}

// "**strong**": opened before a letter, closed after one, not in a word (Python's 2**3 + 4**5 is no emphasis).
@(private = "file")
emphasis :: proc(line: string) -> bool {
	a := strings.index(line, "**")
	if a < 0 || (a > 0 && is_ident(line[a - 1])) || a + 2 >= len(line) || line[a + 2] == ' ' || line[a + 2] == '*' { return false }
	b := strings.index(line[a + 2:], "**")
	if b <= 0 { return false }
	c := a + 2 + b
	return line[c - 1] != ' ' && (c + 2 >= len(line) || !is_ident(line[c + 2]))
}

// A table's rule under its header: "| --- | :-: |".
@(private = "file")
table_rule :: proc(line: string) -> bool {
	t := strings.trim_space(line)
	if !strings.contains(t, "|") || !strings.contains(t, "---") { return false }
	for c in transmute([]u8)t { if c != '|' && c != '-' && c != ':' && c != ' ' { return false } }
	return true
}

// A text in tags: it opens with one (or <!DOCTYPE, <?xml, a comment) and ends with one. HTML when it says so or holds one
// of HTML's common elements, XML otherwise.
@(private = "file")
markup_of :: proc(lower: string) -> (name: string, ok: bool) {
	t := strings.trim_right_space(lower)
	if len(t) < 3 || t[0] != '<' || t[len(t) - 1] != '>' { return }
	if !(is_ident_start(t[1]) || t[1] == '!' || t[1] == '?') { return }
	if strings.has_prefix(t, "<?xml") { return "xml", true }
	if strings.has_prefix(t, "<!doctype html") { return "html", true }
	tags := [?]string{"html", "head", "body", "div", "span", "p", "a", "ul", "ol", "li", "table", "tr", "td", "img", "br", "hr", "script", "style", "section", "article", "nav", "main", "h1", "h2", "h3", "h4", "button", "input", "form", "label", "meta", "em", "strong", "pre", "code"}
	for k := 0; k < len(t); k += 1 {
		if t[k] != '<' { continue }
		j := k + 1
		for j < len(t) && is_ident(t[j]) { j += 1 }
		if contains_word(tags[:], t[k + 1:j]) { return "html", true }
	}
	return "xml", true
}

// TOML or INI: a [section] line at the left edge and most lines "key = value". TOML when every value is one of its typed
// ones (a quoted string, a number, a boolean, an array, a table) and no section name holds a space; INI otherwise.
@(private = "file")
ini_like :: proc(src: string) -> (ini: bool, toml: bool) {
	lines, matched, sections, keys := 0, 0, 0, 0
	toml = true
	rest := src
	for raw in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(raw)
		if t == "" || t[0] == '#' || t[0] == ';' { continue }
		lines += 1
		if raw[0] == '[' && t[len(t) - 1] == ']' {
			name := strings.trim(t, "[]")
			if name == "" || !(is_ident(name[0]) || name[0] == '"') { continue }
			sections += 1
			matched += 1
			for c in transmute([]u8)name { if !is_ident(c) && c != '.' && c != '-' && c != '"' { toml = false } }
			continue
		}
		eq := strings.index_byte(t, '=')
		if eq <= 0 || (eq + 1 < len(t) && t[eq + 1] == '=') { continue }
		key := strings.trim_right_space(t[:eq])
		if !(is_ident(key[0]) || key[0] == '"') { continue }
		plain := true
		for c in transmute([]u8)key { if !is_ident(c) && strings.index_byte(".-[]\"@ ", c) < 0 { plain = false } }
		if !plain { continue }
		keys += 1
		matched += 1
		if !toml_value(strings.trim_space(t[eq + 1:])) { toml = false }
	}
	ini = sections >= 1 && keys >= 1 && matched * 10 >= lines * 7
	return ini, ini && toml
}

// A value TOML can write: a string, a number or a date, a boolean, an array, an inline table.
@(private = "file")
toml_value :: proc(v: string) -> bool {
	if v == "" { return false }
	switch v[0] {
	case '"', '\'', '[', '{', '+', '-', '0' ..= '9': return true
	}
	j := 0
	for j < len(v) && is_ident(v[j]) { j += 1 }
	word := v[:j]
	return word == "true" || word == "false" || word == "inf" || word == "nan"
}

// YAML: most of its lines "key: value" or "- item", two keys at least, and a sign of its structure: a nested key, a list
// item, a "---" line (mail's headers are keys with no structure). No line opens with a tab: YAML forbids them, a
// Makefile's recipes and Odin's blocks have them.
@(private = "file")
yaml_like :: proc(src: string) -> bool {
	lines, yaml, keys := 0, 0, 0
	structure := false
	rest := src
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right_space(raw)
		t := strings.trim_left_space(line)
		if t == "" || t[0] == '#' { continue }
		if line[0] == '\t' { return false }
		lines += 1
		if t == "---" || t == "..." { yaml += 1; structure = true; continue }
		item := t == "-" || strings.has_prefix(t, "- ")
		if item {
			yaml += 1
			structure = true
			t = strings.trim_left_space(t[1:])
		}
		if yaml_key(t) {
			keys += 1
			if !item { yaml += 1 }
			if len(t) < len(line) { structure = true }   // (indented: nested)
		}
	}
	return keys >= 2 && structure && yaml * 10 >= lines * 6
}

// "key: value" or "key:": a name, then ':' and a space or the line's end; not a statement of code ("name: string;",
// "x: int = 1", "key: 'a',") nor a URL ("https://").
@(private = "file")
yaml_key :: proc(t: string) -> bool {
	k := 0
	for k < len(t) && (is_ident(t[k]) || t[k] == '-' || t[k] == '.' || t[k] == '/') { k += 1 }
	if k == 0 || !is_ident(t[0]) || k >= len(t) || t[k] != ':' { return false }
	if k + 1 < len(t) && t[k + 1] != ' ' { return false }
	value := strings.trim_space(t[k + 1:])
	if value == "" { return true }
	last := value[len(value) - 1]
	return last != ';' && last != ',' && last != '{' && !strings.contains(value, " = ")
}

// The runs of `src` in `l`'s classes, appended to `out` in order (the plain ones left out). None for a language with no
// colours (highlight = false): its label only.
spans :: proc(src: string, l: Language, out: ^[dynamic]Span) {
	if !l.highlight { return }
	switch l.markup {
	case .Tags:  tag_spans(src, out); return
	case .Rules: rule_spans(src, out); return
	case .None:
	}
	i := 0
	n := len(src)
	for i < n {
		c := src[i]
		// (the block first: Lua's "--[[" opens with its line comment "--")
		if l.block_open != "" && strings.has_prefix(src[i:], l.block_open) {
			i = span_to(out, .Comment, src, i, l.block_close)
			continue
		}
		if l.line_comment != "" && strings.has_prefix(src[i:], l.line_comment) {
			end := strings.index_byte(src[i:], '\n')
			stop := end < 0 ? n : i + end
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
		if l.sections && c == '[' && (i == 0 || src[i - 1] == '\n') {
			end := strings.index_byte(src[i:], '\n')
			line := end < 0 ? src[i:] : src[i:i + end]
			if close := strings.last_index_byte(line, ']'); close > 0 {
				span(out, .Keyword, i, i + close + 1)
				i += close + 1
				continue
			}
		}
		if l.variable != 0 && c == l.variable {
			j := variable_end(src, i)
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
		if l.key != 0 && is_ident_start(c) && key_start(src, i) {
			j := i
			for j < n && (is_ident(src[j]) || strings.index_byte("-.[]", src[j]) >= 0) { j += 1 }
			k := j
			for k < n && (src[k] == ' ' || src[k] == '\t') { k += 1 }
			// (a ':' key is followed by a space or the line's end: "https://" and make's ":=" are no keys)
			if k < n && src[k] == l.key && (l.key != ':' || k + 1 >= n || is_space(src[k + 1])) {
				span(out, .Func, i, j)
				i = k + 1
				if l.plain_values {
					if from, to, ok := plain_value(src, i, l); ok {
						span(out, .Str, from, to)
						i = to
					}
				}
				continue
			}
		}
		if is_ident_start(c) {
			j := i
			for j < n && is_ident(src[j]) { j += 1 }
			word := src[i:j]
			token := Class.Plain
			folded := l.fold_case ? ascii.lower(word) : word
			switch {
			case contains_word(l.keywords, folded): token = .Keyword
			case contains_word(l.types, folded):    token = .Type
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

@(private = "file")
span :: proc(out: ^[dynamic]Span, class: Class, from, to: int) {
	if class == .Plain || to <= from { return }
	append(out, Span{from, to, class})
}

// A run of `class` from `i` to the end of `close` (the text's end when it is not there); returns where it stops.
@(private = "file")
span_to :: proc(out: ^[dynamic]Span, class: Class, src: string, i: int, close: string) -> int {
	k := strings.index(src[i + 1:], close)
	stop := k < 0 ? len(src) : i + 1 + k + len(close)
	span(out, class, i, stop)
	return stop
}

// The end of a variable at `i`: $name, ${name...} to its brace, $(NAME) (a Makefile's), $@ $< $^ $? (the automatic ones
// of make and the shell), or the sign alone.
@(private = "file")
variable_end :: proc(src: string, i: int) -> int {
	n := len(src)
	j := i + 1
	if j >= n { return j }
	if src[i] == '$' {
		switch src[j] {
		case '{':
			k := j + 1
			for k < n && src[k] != '}' && src[k] != '\n' { k += 1 }
			if k < n && src[k] == '}' { return k + 1 }
			return j
		case '(':
			k := j + 1
			for k < n && is_ident(src[k]) { k += 1 }
			if k > j + 1 && k < n && src[k] == ')' { return k + 1 }
			return j
		case '@', '<', '^', '?', '*', '#', '!', '%', '+':
			return j + 1
		}
	}
	for j < n && (is_ident(src[j]) || src[j] == ':') { j += 1 }
	return j
}

// A key opens its line, or follows a YAML list's "- ".
@(private = "file")
key_start :: proc(src: string, i: int) -> bool {
	return at_line_start(src, i) || (i >= 2 && src[i - 1] == ' ' && src[i - 2] == '-' && at_line_start(src, i - 2))
}

// The text a key is given, from `from` to its line's end or a comment after a space; ok = false when it is empty, quoted,
// a number, a keyword alone, a flow ([a, b], {a: b}) or a block (|, >), which the tokenizer colours as such.
@(private = "file")
plain_value :: proc(src: string, from: int, l: Language) -> (start, end: int, ok: bool) {
	n := len(src)
	start = from
	for start < n && (src[start] == ' ' || src[start] == '\t') { start += 1 }
	if start >= n { return }
	switch src[start] {
	case '\n', '\r', '"', '\'', '[', '{', '|', '>', '&', '*', '0' ..= '9': return
	case '-': if start + 1 < n && is_digit(src[start + 1]) { return }
	}
	if l.line_comment != "" && strings.has_prefix(src[start:], l.line_comment) { return }
	nl := strings.index_byte(src[start:], '\n')
	end = nl < 0 ? n : start + nl
	if l.line_comment != "" {
		for k in start ..< end {
			if (src[k] == ' ' || src[k] == '\t') && strings.has_prefix(src[k + 1:], l.line_comment) { end = k; break }
		}
	}
	for end > start && (src[end - 1] == ' ' || src[end - 1] == '\t' || src[end - 1] == '\r') { end -= 1 }
	j := start
	for j < end && is_ident(src[j]) { j += 1 }
	if j == end && contains_word(l.keywords, l.fold_case ? ascii.lower(src[start:j]) : src[start:j]) { return }
	return start, end, end > start
}

// The runs of a text in tags (HTML, XML). A tag's name is a keyword; an attribute's name is a call, as CSS's properties
// and YAML's keys (a name given a value: its value, a string, then stands apart from it); a comment is a comment;
// <!DOCTYPE> and <?xml?> are directives (calls, as C's # lines); an &entity; is a type, as a number. The text between
// the tags stays plain: it is prose. A <script> holds JavaScript, a <style> CSS, coloured as such.
@(private = "file")
tag_spans :: proc(src: string, out: ^[dynamic]Span) {
	n := len(src)
	i := 0
	for i < n {
		c := src[i]
		if c == '&' {
			j := i + 1
			if j < n && src[j] == '#' { j += 1 }
			for j < n && is_ident(src[j]) { j += 1 }
			if j < n && src[j] == ';' && j > i + 1 {
				span(out, .Type, i, j + 1)
				i = j + 1
			} else {
				i += 1
			}
			continue
		}
		if c != '<' || i + 1 >= n { i += 1; continue }
		switch {
		case strings.has_prefix(src[i:], "<!--"):
			i = span_to(out, .Comment, src, i, "-->")
			continue
		case strings.has_prefix(src[i:], "<![CDATA["):
			i = span_to(out, .Str, src, i, "]]>")
			continue
		case src[i + 1] == '!' || src[i + 1] == '?':
			i = span_to(out, .Func, src, i, ">")
			continue
		}
		closing := src[i + 1] == '/'
		j := closing ? i + 2 : i + 1
		if j >= n || !is_ident_start(src[j]) { i += 1; continue }   // ("a < b" in the text)
		name_start := j
		for j < n && (is_ident(src[j]) || src[j] == '-' || src[j] == ':' || src[j] == '.') { j += 1 }
		name := src[name_start:j]
		span(out, .Keyword, name_start, j)
		empty := false   // <br/>: nothing inside
		tag: for j < n {
			d := src[j]
			switch {
			case d == '>':
				j += 1
				break tag
			case d == '<':
				break tag   // a tag left open: the next one starts here
			case d == '/' && j + 1 < n && src[j + 1] == '>':
				empty = true
				j += 2
				break tag
			case d == '"' || d == '\'':
				close := strings.index_byte(src[j + 1:], d)
				stop := close < 0 ? n : j + close + 2
				span(out, .Str, j, stop)
				j = stop
			case d == '=':
				j += 1
				for j < n && (src[j] == ' ' || src[j] == '\t') { j += 1 }
				if j < n && src[j] != '"' && src[j] != '\'' && src[j] != '>' && !is_space(src[j]) {
					k := j
					// (to a space or the tag's end: "/>" too, while href=/a/b keeps its slashes)
					for k < n && !is_space(src[k]) && src[k] != '>' && !(src[k] == '/' && k + 1 < n && src[k + 1] == '>') { k += 1 }
					span(out, .Str, j, k)
					j = k
				}
			case is_ident(d) || strings.index_byte("-:.@[]()*#", d) >= 0:
				k := j
				for k < n && (is_ident(src[k]) || strings.index_byte("-:.@[]()*#", src[k]) >= 0) { k += 1 }
				span(out, .Func, j, k)
				j = k
			case:
				j += 1
			}
		}
		i = j
		if closing || empty { continue }
		inner := ""
		if ascii.equal_fold(name, "script") { inner = "js" } else if ascii.equal_fold(name, "style") { inner = "css" }
		if inner == "" { continue }
		stop := closing_tag(src, i, name)
		lang, _ := language(inner)
		first := len(out)
		spans(src[i:stop], lang, out)
		for &s in out^[first:] { s.start += i; s.end += i }
		i = stop
	}
}

// Where the element `name` that holds raw text (a script, a style) closes: its "</name", any case; the text's end if none.
@(private = "file")
closing_tag :: proc(src: string, from: int, name: string) -> int {
	k := from
	for {
		at := strings.index(src[k:], "</")
		if at < 0 { return len(src) }
		k += at
		if ascii.has_prefix_fold(src[k + 2:], name) { return k }
		k += 2
	}
}

// The runs of a style sheet (CSS). A selector's element is a keyword, its .class and #id types (as numbers), its :hover a
// call; a property is a call (as an attribute's name in HTML); in a value, a number with its unit and a #colour are types,
// url() and rgb() calls; an @rule and !important are keywords.
@(private = "file")
rule_spans :: proc(src: string, out: ^[dynamic]Span) {
	n := len(src)
	i := 0
	statement := true   // at a statement's start: what it is is not known yet
	selector := true    // a selector or an @rule's prelude, before '{'; else a declaration
	value := false      // past a declaration's ':'
	for i < n {
		c := src[i]
		if strings.has_prefix(src[i:], "/*") { i = span_to(out, .Comment, src, i, "*/"); continue }
		if is_space(c) { i += 1; continue }
		if statement {
			// A statement that ends with ';' or '}' is a declaration ("color: red;"), one that opens a block a selector:
			// the same test for a sheet, a block's inside and one line of an editor.
			end := strings.index_any(src[i:], "{;}")
			selector = end < 0 || src[i + end] == '{'
			value = false
			statement = false
		}
		next_digit := i + 1 < n && is_digit(src[i + 1])
		switch {
		case c == '{' || c == '}' || c == ';':
			statement = true
			i += 1
		case c == '"' || c == '\'':
			stop := scan_string(src, i, c)
			span(out, .Str, i, stop)
			i = stop
		case c == '@' || c == '!':
			j := css_name_end(src, i + 1)
			if j > i + 1 { span(out, .Keyword, i, j) }
			i = max(j, i + 1)
		case is_digit(c) || ((c == '.' || c == '-' || c == '+') && next_digit):
			j := i + 1
			for j < n && (is_digit(src[j]) || src[j] == '.') { j += 1 }
			for j < n && (is_ident(src[j]) || src[j] == '%') { j += 1 }   // its unit: px, em, %
			span(out, .Type, i, j)
			i = j
		case c == '#' || (selector && c == '.'):
			j := css_name_end(src, i + 1)
			if j > i + 1 { span(out, .Type, i, j) }
			i = max(j, i + 1)
		case c == ':' && selector:
			j := i + 1
			if j < n && src[j] == ':' { j += 1 }
			k := css_name_end(src, j)
			if k > j { span(out, .Func, i, k) }
			i = max(k, j)
		case c == ':':
			value = true
			i += 1
		case is_ident_start(c) || c == '-':
			j := css_name_end(src, i)
			switch {
			case selector:        span(out, .Keyword, i, j)
			case !value:          span(out, .Func, i, j)
			case is_call(src, j): span(out, .Func, i, j)
			}
			i = j
		case:
			i += 1
		}
	}
}

// The end of a CSS name from `i`: letters, digits, '_' and '-' (font-size, --accent, -webkit-box).
@(private = "file")
css_name_end :: proc(s: string, i: int) -> int {
	j := i
	for j < len(s) && (is_ident(s[j]) || s[j] == '-') { j += 1 }
	return j
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
@(private) is_space :: proc(c: byte) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

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
