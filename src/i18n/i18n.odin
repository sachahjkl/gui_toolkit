// Package i18n: every text the user reads goes through `tr`, so an application is translated without going through its
// code again.
//
// One name, `tr`, a procedure group: the compiler picks the form from the arguments.
//
//	label := i18n.tr("Open in a new tab")                                    // a text
//	close := i18n.tr("tab strip", "Close")                                   // a context for the translator, then the text
//	text  := fmt.tprintf(i18n.tr(count, "%d request", "%d requests"), count) // singular, plural, by count
//
// The English text is the key. In English (no language in use) each call returns its argument: no lookup, no allocation.
// A language (load, use) is the toolkit's catalogue and the program's for one language tag, made once (at the start, or
// when the user picks it); tr looks a text up there by its characters the first time, then by the address of the literal
// in a small cache of its thread (the interface is immediate: tr runs for every label at every frame, so it must not hash
// the text each time). The cache compares the text too: a text made at run time at an address a literal had is never
// taken for it.
//
// Each catalogue is a domain: a tr called from the toolkit's code (its file under the toolkit's src/) looks in the
// toolkit's catalogue first, a tr of a program's code in the program's first; each then in the other (a program's text
// that the toolkit's widgets show, a toolkit's text a program shows). A program's catalogue never changes the toolkit's
// words. See docs/i18n.md.
//
// The package name is `tk_i18n` (the directory is `i18n`): an application that keeps a thin `i18n` alias package of its
// own needs the two names to differ, because Odin package names are unique within a build.
package tk_i18n

import "base:runtime"
import "core:sync"

tr :: proc{tr_text, tr_context, tr_count}

// The text to show for `text`, an English sentence or label. `loc` (the caller's file) picks the catalogue looked in
// first: the toolkit's for the toolkit's code, the program's for a program's.
@(require_results)
tr_text :: proc "contextless" (text: string, loc := #caller_location) -> string {
	gen, l := in_use_now()
	if l == nil { return text }
	e := lookup(l, gen, domain_of(loc.file_path), "", text)
	return e != nil && e.forms[0] != "" ? e.forms[0] : text
}

// The text to show for `text` in the place named by `context_`, to tell apart two meanings of the same English word ("Close"
// a tab, "Close" a dialog). The context is for the translator and is never shown.
@(require_results)
tr_context :: proc "contextless" (context_: string, text: string, loc := #caller_location) -> string {
	gen, l := in_use_now()
	if l == nil { return text }
	e := lookup(l, gen, domain_of(loc.file_path), context_, text)
	return e != nil && e.forms[0] != "" ? e.forms[0] : text
}

// The form for `count` of a text with a singular and a plural. Languages have more forms than two (Polish, Russian and
// Arabic have several; French reads 0 as singular): the choice belongs to the language, which is why a caller never writes
// `count == 1`.
@(require_results)
tr_count :: proc "contextless" (count: int, one: string, other: string, loc := #caller_location) -> string {
	gen, l := in_use_now()
	if l == nil { return one if count == 1 else other }
	e := lookup(l, gen, domain_of(loc.file_path), "", one)
	if e == nil { return one if count == 1 else other }
	form := l.rule(count)
	if form < e.form_count && e.forms[form] != "" { return e.forms[form] }
	return one if count == 1 else other
}

// A text translated later, where it is shown (`tr(def.title)`): the English as it is, marked for the catalogue's tool.
// For a text kept before the language is known (a setting's title, registered before the settings are read).
later :: #force_inline proc "contextless" (text: string) -> string { return text }

////////////////////////////////
// The domains: whose catalogue a tr looks in first

// The catalogue a text is looked up in first: the program's, or the toolkit's. A program's catalogue may hold a text the
// toolkit also has ("Paste", "Off") in its own sense: the toolkit's words stay the toolkit's.
Domain :: enum u8 { Program, Toolkit }

// This file's folder: src/i18n of the toolkit. The compiler gives #directory and #caller_location from the same path of a
// file, so the toolkit's other files start with its parent.
@(private = "file") I18N_DIRECTORY :: #directory

// The toolkit's src folder, as the compiler names its files (no separator at its end).
toolkit_root :: proc "contextless" () -> string {
	d := I18N_DIRECTORY
	for len(d) > 0 && is_separator(d[len(d) - 1]) { d = d[:len(d) - 1] }
	for i := len(d) - 1; i >= 0; i -= 1 {
		if is_separator(d[i]) { return d[:i] }
	}
	return d
}

// The domain of the code in `file` (a #caller_location's file_path): the toolkit's when it is under the toolkit's src/.
domain_of :: proc "contextless" (file: string) -> Domain {
	root := toolkit_root()
	if len(file) <= len(root) || !is_separator(file[len(root)]) { return .Program }
	// (from the end: two paths share their long start; the separators may be written either way on Windows)
	for i := len(root) - 1; i >= 0; i -= 1 {
		a, b := file[i], root[i]
		if a != b && !(is_separator(a) && is_separator(b)) { return .Program }
	}
	return .Toolkit
}

@(private = "file")
is_separator :: #force_inline proc "contextless" (c: u8) -> bool { return c == '/' || c == '\\' }

////////////////////////////////
// The language in use

// The language whose texts tr gives (nil: English). Set by use, at the start and at each change of the language while the
// program runs: a language once in use is never freed while it runs (a text tr gave may be held by a widget, a thread may
// be in the middle of a lookup in it).
@(private = "file") in_use: ^Language
// Counts the changes of language: a cached answer of another language is not taken, and what a program made of
// translated text is made again when it moves (version).
@(private = "file") generation: u32

// The texts of `l` from now on (nil: English), on every thread at its next tr: each thread's cache sees the new generation.
// A language passed here lives until the end of the program (or until a test's last tr of it): the threads' caches and
// the texts tr gave point into it. Using the language already in use changes nothing (the version does not move).
use :: proc(l: ^Language) {
	if sync.atomic_load(&in_use) == l { return }
	// (the language first, then the generation: a thread that reads the new generation reads the new language, see
	// in_use_now)
	sync.atomic_store(&in_use, l)
	sync.atomic_add(&generation, 1)
}

// The language in use (nil: English).
current :: proc "contextless" () -> ^Language { return sync.atomic_load(&in_use) }

// Moves each time the language in use changes (use). What a program made once from translated text (a table of commands,
// a sheet, a cached layout) is made again when this is not the value it was made at; a widget that translates where it
// shows (i18n.later) needs nothing.
version :: proc "contextless" () -> u32 { return sync.atomic_load(&generation) }

// The generation, then the language. In this order a slot is never filled with an old language's entry under the new
// generation (use stores the language before it counts): at worst a new entry is kept under the old generation, and
// looked up again at the next call.
@(private = "file")
in_use_now :: #force_inline proc "contextless" () -> (gen: u32, l: ^Language) {
	gen = sync.atomic_load(&generation)
	l = sync.atomic_load(&in_use)
	return
}

////////////////////////////////
// The thread's cache: the address of a literal to its entry

@(private = "file") CACHE_SLOTS :: 512   // a power of two: what one window shows, with room

@(private = "file")
Slot :: struct {
	text, ctx:  rawptr,   // the addresses the caller passed
	entry:      ^Entry,
	generation: u32,
	domain:     Domain,   // (one literal may serve both: the linker merges equal literals of the toolkit and a program)
}

@(private = "file", thread_local) cache: [CACHE_SLOTS]Slot

// The entry of `text` in `ctx` (nil: not translated) for code of `domain`, `l` being the language in use at generation
// `gen`.
@(private)
lookup :: proc "contextless" (l: ^Language, gen: u32, domain: Domain, ctx, text: string) -> ^Entry {
	h := (uintptr(raw_data(text)) >> 3) ~ (uintptr(raw_data(ctx)) >> 5) ~ uintptr(len(text)) ~ uintptr(domain)
	s := &cache[h & (CACHE_SLOTS - 1)]
	// (the address alone is not enough: a text made at run time may sit where another was; the characters decide)
	if s.generation == gen && s.text == raw_data(text) && s.ctx == raw_data(ctx) && s.domain == domain && s.entry != nil &&
	   s.entry.english == text && s.entry.ctx == ctx {
		return s.entry
	}
	e := find(l, domain, ctx, text)
	if e != nil { s^ = {raw_data(text), raw_data(ctx), e, gen, domain} }
	return e
}

////////////////////////////////
// A language

MAX_FORMS :: 4   // the forms of a text by count a language may have (French 2, Polish 3, Arabic 6 is cut to the first 4)

// One text of a catalogue: its English (the key), its context, its translated forms (one for a plain text; by count, as
// many as the language's rule says).
Entry :: struct {
	ctx, english: string,
	forms:        [MAX_FORMS]string,
	form_count:   int,
	domain:       Domain,   // whose catalogue it comes from
}

// The texts of one language, from the catalogues given to load. Made once; read by every thread.
Language :: struct {
	tag:          string,                    // "fr", "fr-CA": the tag it was loaded for
	rule:         proc "contextless" (count: int) -> int,   // the form for a count
	entries:      [dynamic]Entry,
	tables:       [Domain][]i32,             // by domain, open addressing: the index of an entry + 1, 0 empty
	arena:        runtime.Arena,             // the texts, unescaped
	decimal_mark: u8,                        // '.' or ',' (decimal, percent)
	percent_gap:  bool,                      // "34 %" (a no-break space before the sign) rather than "34%"
}

// The entry of `text` in `ctx`, by its characters (nil: none): in the catalogue of `domain`, else in the other.
@(private)
find :: proc "contextless" (l: ^Language, domain: Domain, ctx, text: string) -> ^Entry {
	if e := find_in(l, l.tables[domain], ctx, text); e != nil { return e }
	return find_in(l, l.tables[domain == .Toolkit ? .Program : .Toolkit], ctx, text)
}

@(private = "file")
find_in :: proc "contextless" (l: ^Language, table: []i32, ctx, text: string) -> ^Entry {
	if len(table) == 0 { return nil }
	mask := u64(len(table) - 1)
	for i := key_hash(ctx, text) & mask; ; i = (i + 1) & mask {
		at := table[i]
		if at == 0 { return nil }
		e := &l.entries[at - 1]
		if e.english == text && e.ctx == ctx { return e }
	}
}

// FNV-1a of the context, a separator and the text.
@(private)
key_hash :: proc "contextless" (ctx, text: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for c in transmute([]u8)ctx { h = (h ~ u64(c)) * 0x100000001b3 }
	h = (h ~ 4) * 0x100000001b3
	for c in transmute([]u8)text { h = (h ~ u64(c)) * 0x100000001b3 }
	return h
}

// The form for a count, by language (CLDR's cardinal rules, for whole numbers): 0 the first form ("one"), then the next.
plural_rule :: proc(primary: string) -> proc "contextless" (count: int) -> int {
	switch primary {
	case "fr", "pt":                       // 0 and 1 are singular
		return proc "contextless" (n: int) -> int { return n == 0 || n == 1 ? 0 : 1 }
	case "ja", "zh", "ko", "vi", "th", "id":   // one form
		return proc "contextless" (n: int) -> int { return 0 }
	case "pl":                             // one, few, many
		return proc "contextless" (n: int) -> int {
			if n == 1 { return 0 }
			if n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14) { return 1 }
			return 2
		}
	case "ru", "uk":                       // one, few, many
		return proc "contextless" (n: int) -> int {
			if n % 10 == 1 && n % 100 != 11 { return 0 }
			if n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14) { return 1 }
			return 2
		}
	}
	return proc "contextless" (n: int) -> int { return n == 1 ? 0 : 1 }   // English, German, Spanish, Italian...
}

// The primary subtag of a language tag: "fr" of "fr-CA" or "fr_CA.UTF-8".
primary_of :: proc(tag: string) -> string {
	for c, i in tag {
		if c == '-' || c == '_' || c == '.' || c == '@' { return tag[:i] }
	}
	return tag
}
