package tk_toolbox

// The catalogue of a language from the code: every `tr` call with literal texts in the .odin files of some folders (not
// their tests), the translations already written kept, the new texts added to be translated, the texts the code no
// longer has dropped (docs/i18n.md).
//   i18n <language> [-check]     writes the catalogue; -check: writes nothing, fails when a text is not translated, when
//                                the code has a text the catalogue has not, or the catalogue one the code has not

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:strconv"
import "core:strings"
import i18n "../i18n"

// A text of the code: a tr call's literals.
I18n_Text :: struct {
	ctx, english, plural: string,   // plural: the English of tr(count, one, other)'s other ("" for a plain text)
	at:                   string,   // where it was first seen, "file:line"
}

// What a project's tool runs as its `i18n` command: the texts of `dirs` (each walked) into `<folder>/<language>.txt`.
I18n_Catalogues :: struct {
	dirs:   []string,
	folder: string,
}

// The command `i18n` of a project's tool (copied, its folders too: a literal's slice lives on the caller's stack).
i18n_command :: proc(c: I18n_Catalogues) -> Command {
	kept := new_clone(I18n_Catalogues{dirs = make([]string, len(c.dirs)), folder = strings.clone(c.folder)})
	for d, i in c.dirs { kept.dirs[i] = strings.clone(d) }
	return {name = "i18n", usage = "<language> [-check]: the catalogue of a language from the code's tr calls (docs/i18n.md)",
		run_with = i18n_run, user = kept, checked = true, flags = I18N_FLAGS[:], positionals = 1}
}

@(private = "file", rodata)
I18N_FLAGS := [?]string{"check"}

@(private = "file")
i18n_run :: proc(args: []string, user: rawptr) -> int {
	c := (^I18n_Catalogues)(user)^
	language := plain_args(args)[0]
	path := fmt.tprintf("%s/%s.txt", c.folder, language)
	return done(i18n_catalogue(c.dirs, path, language, has_flag(args, "check")))
}

// The catalogue at `path` made again from the texts of `dirs`; `check`: compared, not written. "": done, or it agrees.
i18n_catalogue :: proc(dirs: []string, path, language: string, check: bool) -> string {
	texts := make([dynamic]I18n_Text, context.temp_allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	odd := make([dynamic]string, context.temp_allocator)
	for d in dirs {
		for f in odin_files(d) {
			if strings.has_suffix(f, "_test.odin") { continue }
			data, err := os.read_entire_file(f, context.temp_allocator)
			if err != nil { return fmt.tprintf("%s: %v", f, err) }
			i18n_texts_of(string(data), f, &texts, &seen, &odd)
		}
	}
	old_text, _ := os.read_entire_file(path, context.temp_allocator)
	old := i18n_entries_of(string(old_text), language)
	made := i18n_write(texts[:], old, language, string(old_text))
	untranslated, gone := 0, 0
	for t in texts {
		key := i18n_key(t.ctx, t.english)
		if e, ok := old[key]; !ok || e.forms[0] == "" { untranslated += 1 }
	}
	for k in old { if !seen[k] { gone += 1 } }
	for o in odd { fmt.eprintln(o) }
	if check {
		if untranslated > 0 || gone > 0 || made != string(old_text) {
			return fmt.tprintf("%s: %d texts not translated, %d no longer in the code, not up to date: run `i18n %s`", path, untranslated, gone, language)
		}
		fmt.printfln("%s: %d texts, all translated", path, len(texts))
		return ""
	}
	if made != string(old_text) {
		if err := os.write_entire_file(path, transmute([]u8)made); err != nil { return fmt.tprintf("%s: %v", path, err) }
	}
	fmt.printfln("%s: %d texts, %d to translate, %d dropped (no longer in the code)", path, len(texts), untranslated, gone)
	return ""
}

@(private = "file")
i18n_key :: proc(ctx, english: string) -> string { return fmt.tprintf("%s\x04%s", ctx, english) }

// The tr calls of a file whose texts are literals, in their order; a call with a text that is not one is said in `odd`
// (it cannot be translated from a catalogue).
@(private)
i18n_texts_of :: proc(src, file: string, texts: ^[dynamic]I18n_Text, seen: ^map[string]bool, odd: ^[dynamic]string) {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, file)
	toks := make([dynamic]tokenizer.Token, context.temp_allocator)
	for {
		tok := tokenizer.scan(&t)
		if tok.kind == .EOF { break }
		if tok.kind == .Comment { continue }
		append(&toks, tok)
	}
	for i := 0; i + 1 < len(toks); i += 1 {
		if toks[i].kind != .Ident || toks[i + 1].kind != .Open_Paren { continue }
		// tr(...), or i18n.later("..."): a text translated where it is shown (`later` alone is too common a name)
		later := toks[i].text == "later" && i >= 2 && toks[i - 1].kind == .Period && toks[i - 2].text == "i18n"
		if toks[i].text != "tr" && !later { continue }
		// the arguments at depth 1, each a run of tokens
		args := make([dynamic][]tokenizer.Token, context.temp_allocator)
		depth, start := 0, i + 2
		j := i + 1
		for ; j < len(toks); j += 1 {
			#partial switch toks[j].kind {
			case .Open_Paren, .Open_Brace, .Open_Bracket: depth += 1
			case .Close_Paren, .Close_Brace, .Close_Bracket:
				depth -= 1
				if depth == 0 {
					if j > start { append(&args, toks[start:j]) }
					break
				}
			case .Comma:
				if depth == 1 { append(&args, toks[start:j]); start = j + 1 }
			}
			if depth == 0 { break }
		}
		at := fmt.tprintf("%s:%d", file, toks[i].pos.line)
		literal :: proc(a: []tokenizer.Token) -> (string, bool) {
			if len(a) != 1 || a[0].kind != .String { return "", false }
			s := a[0].text
			if strings.has_prefix(s, "`") { return s[1:len(s) - 1], true }
			v, _, ok := strconv.unquote_string(s, context.temp_allocator)
			return v, ok
		}
		text: I18n_Text
		ok := false
		switch {
		case later && len(args) == 1:
			text.english, ok = literal(args[0])
		case later:
		case len(args) == 1:
			text.english, ok = literal(args[0])
		case len(args) == 2:
			c, ok1 := literal(args[0])
			e, ok2 := literal(args[1])
			text.ctx, text.english, ok = c, e, ok1 && ok2
		case len(args) == 3:
			o, ok1 := literal(args[1])
			p, ok2 := literal(args[2])
			text.english, text.plural, ok = o, p, ok1 && ok2
		}
		if !ok {
			// (a text that is a variable cannot come from a catalogue: it is said, and stays English)
			append(odd, fmt.tprintf("%s: a tr call whose text is not a literal: it stays English", at))
			continue
		}
		if text.english == "" { continue }
		key := i18n_key(text.ctx, text.english)
		if seen[key] { continue }
		seen[key] = true
		text.at = at
		append(texts, text)
	}
}

// The entries of a catalogue, by key ("ctx\x04english").
@(private)
i18n_entries_of :: proc(text, language: string) -> map[string]i18n.Entry {
	out := make(map[string]i18n.Entry, allocator = context.temp_allocator)
	l, _ := i18n.load(language, {{i18n.primary_of(language), text}}, with_toolkit = false, allocator = context.temp_allocator)
	if l == nil { return out }
	for e in l.entries { out[i18n_key(e.ctx, e.english)] = e }
	return out
}

// The catalogue: its head (the comment lines at the top of the old file, else a new one), then each text in the order
// of the code, its translations kept.
@(private)
i18n_write :: proc(texts: []I18n_Text, old: map[string]i18n.Entry, language, old_text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	primary := i18n.primary_of(language)
	head := 0
	rest := old_text
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "#") { break }
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
		head += 1
	}
	if head == 0 {
		fmt.sbprintf(&b, "# The texts in %s (docs/i18n.md). Written by the i18n command: a translation left empty is the English.\n", language)
	}
	fmt.sbprintf(&b, "language %s\n", primary)
	for t in texts {
		strings.write_byte(&b, '\n')
		e := old[i18n_key(t.ctx, t.english)]
		if t.ctx != "" { fmt.sbprintf(&b, "ctx %s\n", i18n.escape(t.ctx, context.temp_allocator)) }
		fmt.sbprintf(&b, "en %s\n", i18n.escape(t.english, context.temp_allocator))
		if t.plural != "" { fmt.sbprintf(&b, "en+ %s\n", i18n.escape(t.plural, context.temp_allocator)) }
		forms := t.plural != "" ? max(2, e.form_count) : 1
		for f in 0 ..< forms {
			tag := f == 0 ? primary : (f == 1 ? fmt.tprintf("%s+", primary) : fmt.tprintf("%s+%d", primary, f))
			value := i18n.escape(e.forms[f], context.temp_allocator)
			if value == "" { fmt.sbprintf(&b, "%s\n", tag) } else { fmt.sbprintf(&b, "%s %s\n", tag, value) }
		}
	}
	return strings.to_string(b)
}
