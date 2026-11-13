package tk_i18n

// A catalogue: the texts of one language, a file of the repository embedded by #load (docs/i18n.md).
//
//	# comments
//	language fr
//
//	ctx tab strip          (optional: the context of tr(context, text))
//	en Close
//	fr Fermer
//
//	en %d request          (a text by count: its English plural, then each form of the language's rule)
//	en+ %d requests
//	fr %d requête
//	fr+ %d requêtes
//
// A blank line ends a text. A translation left empty ("fr" alone) is the English. \n, \t and \\ are escapes; the rest of a
// line after its tag and one space is the text, as it is.

import "base:runtime"
import "core:strings"

// A catalogue's text, for one language: what a program embeds ({"fr", #load("i18n/fr.txt", string)}).
Catalog :: struct {
	language: string,   // its primary subtag, "fr"
	text:     string,
}

// The toolkit's own catalogues (its menus, dialogs and settings).
TOOLKIT_CATALOGS :: [?]Catalog{
	{"fr", #load("lang/fr.txt", string)},
}

// The language of `tag` ("fr", "fr-CA", "fr_FR.UTF-8") made from the toolkit's catalogue (unless `with_toolkit` is false:
// a tool reading one file) and the program's of its primary subtag, in one table; nil when it is English or no catalogue
// has it. `bad`: the lines no catalogue could read, as
// "<line>: <why>" (a catalogue in the repository is checked by the tool: this is said, not fatal). Allocated in
// `allocator` and never freed while the program runs (use).
load :: proc(tag: string, program: []Catalog, with_toolkit := true, allocator := context.allocator) -> (l: ^Language, bad: []string) {
	primary := primary_of(tag)
	if primary == "" || primary == "en" { return nil, nil }
	texts := make([dynamic]string, context.temp_allocator)
	if with_toolkit { for c in TOOLKIT_CATALOGS { if c.language == primary { append(&texts, c.text) } } }
	for c in program { if c.language == primary { append(&texts, c.text) } }
	if len(texts) == 0 { return nil, nil }
	l = new(Language, allocator)
	l.tag = strings.clone(tag, allocator)
	l.rule = plural_rule(primary)
	l.entries = make([dynamic]Entry, allocator)
	problems := make([dynamic]string, context.temp_allocator)
	{
		arena := runtime.arena_allocator(&l.arena)
		for t in texts { parse(l, primary, t, arena, &problems) }
	}
	// (a program's text comes after the toolkit's: the later entry of the same key wins, so a program may say a toolkit's
	// text its own way)
	n := 16
	for n < len(l.entries) * 2 { n *= 2 }
	l.table = make([]i32, n, allocator)
	mask := u64(n - 1)
	for e, at in l.entries {
		for i := key_hash(e.ctx, e.english) & mask; ; i = (i + 1) & mask {
			if l.table[i] == 0 { l.table[i] = i32(at + 1); break }
			old := &l.entries[l.table[i] - 1]
			if old.english == e.english && old.ctx == e.ctx { l.table[i] = i32(at + 1); break }
		}
	}
	return l, problems[:]
}

// Frees a language that is not in use (a test's).
destroy :: proc(l: ^Language, allocator := context.allocator) {
	if l == nil { return }
	runtime.arena_destroy(&l.arena)
	delete(l.entries)
	delete(l.table, allocator)
	delete(l.tag, allocator)
	free(l, allocator)
}

@(private = "file")
parse :: proc(l: ^Language, primary, text: string, arena: runtime.Allocator, problems: ^[dynamic]string) {
	e: Entry
	has := false
	line_no := 0
	finish :: proc(l: ^Language, e: ^Entry, has: ^bool) {
		if has^ && e.english != "" { append(&l.entries, e^) }
		e^ = {}
		has^ = false
	}
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line_no += 1
		line := strings.trim_right(raw, "\r")
		if line == "" { finish(l, &e, &has); continue }
		if line[0] == '#' { continue }
		tag, value := line, ""
		if i := strings.index_byte(line, ' '); i >= 0 { tag, value = line[:i], line[i + 1:] }
		switch {
		case tag == "language":
			if value != primary { append(problems, fmt_line(line_no, "a catalogue of another language")) }
		case tag == "ctx":
			e.ctx = unescape(value, arena); has = true
		case tag == "en":
			e.english = unescape(value, arena); has = true
		case tag == "en+":
			// (the English plural is for the translator and the tool; the key is the singular)
		case tag == primary:
			e.forms[0] = unescape(value, arena); e.form_count = max(e.form_count, 1); has = true
		case strings.has_prefix(tag, primary) && len(tag) > len(primary) && tag[len(primary)] == '+':
			n := 1
			if len(tag) > len(primary) + 1 {
				d := tag[len(primary) + 1:]
				if len(d) != 1 || d[0] < '1' || d[0] > '9' { append(problems, fmt_line(line_no, "a form is +, +2, +3")); continue }
				n = int(d[0] - '0')
			}
			if n >= MAX_FORMS { continue }
			e.forms[n] = unescape(value, arena); e.form_count = max(e.form_count, n + 1); has = true
		case:
			append(problems, fmt_line(line_no, "an unknown tag"))
		}
	}
	finish(l, &e, &has)
}

@(private = "file")
fmt_line :: proc(n: int, why: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, n)
	strings.write_string(&b, ": ")
	strings.write_string(&b, why)
	return strings.to_string(b)
}

// \n, \t and \\ of a catalogue's text; the text as it is when it has none.
unescape :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '\\') < 0 { return strings.clone(s, allocator) }
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':  strings.write_byte(&b, '\n'); i += 1; continue
			case 't':  strings.write_byte(&b, '\t'); i += 1; continue
			case '\\': strings.write_byte(&b, '\\'); i += 1; continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// The text as a catalogue writes it (the tool writes catalogues).
escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for c in transmute([]u8)s {
		switch c {
		case '\n': strings.write_string(&b, "\\n")
		case '\t': strings.write_string(&b, "\\t")
		case '\\': strings.write_string(&b, "\\\\")
		case:      strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}
