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
// A language (load, use) is the toolkit's catalogue and the program's for one language tag, made once at the start into
// one table; tr looks a text up there by its characters the first time, then by the address of the literal in a small
// cache of its thread (the interface is immediate: tr runs for every label at every frame, so it must not hash the
// text each time). The cache compares the text too: a text made at run time at an address a literal had is never taken
// for it. See docs/i18n.md.
//
// The package name is `tk_i18n` (the directory is `i18n`): an application that keeps a thin `i18n` alias package of its
// own needs the two names to differ, because Odin package names are unique within a build.
package tk_i18n

import "base:runtime"
import "core:sync"

tr :: proc{tr_text, tr_context, tr_count}

// The text to show for `text`, an English sentence or label.
@(require_results)
tr_text :: proc "contextless" (text: string) -> string {
	l := current()
	if l == nil { return text }
	e := lookup(l, "", text)
	return e != nil && e.forms[0] != "" ? e.forms[0] : text
}

// The text to show for `text` in the place named by `context_`, to tell apart two meanings of the same English word ("Close"
// a tab, "Close" a dialog). The context is for the translator and is never shown.
@(require_results)
tr_context :: proc "contextless" (context_: string, text: string) -> string {
	l := current()
	if l == nil { return text }
	e := lookup(l, context_, text)
	return e != nil && e.forms[0] != "" ? e.forms[0] : text
}

// The form for `count` of a text with a singular and a plural. Languages have more forms than two (Polish, Russian and
// Arabic have several; French reads 0 as singular): the choice belongs to the language, which is why a caller never writes
// `count == 1`.
@(require_results)
tr_count :: proc "contextless" (count: int, one: string, other: string) -> string {
	l := current()
	if l == nil { return one if count == 1 else other }
	e := lookup(l, "", one)
	if e == nil { return one if count == 1 else other }
	form := l.rule(count)
	if form < e.form_count && e.forms[form] != "" { return e.forms[form] }
	return one if count == 1 else other
}

////////////////////////////////
// The language in use

// The language whose texts tr gives (nil: English). Set by use, at the start (the setting takes effect at the next start):
// a language in use is never freed while the program runs.
@(private = "file") in_use: ^Language
// Counts the changes of language: a cached answer of another language is not taken.
@(private = "file") generation: u32

// The texts of `l` from now on (nil: English). A language passed here lives until the end of the program (or until a
// test's last tr of it): the threads' caches point into it.
use :: proc(l: ^Language) {
	sync.atomic_store(&in_use, l)
	sync.atomic_add(&generation, 1)
}

// The language in use (nil: English).
current :: proc "contextless" () -> ^Language { return sync.atomic_load(&in_use) }

////////////////////////////////
// The thread's cache: the address of a literal to its entry

@(private = "file") CACHE_SLOTS :: 512   // a power of two: what one window shows, with room

@(private = "file")
Slot :: struct {
	text, ctx:  rawptr,   // the addresses the caller passed
	entry:      ^Entry,
	generation: u32,
}

@(private = "file", thread_local) cache: [CACHE_SLOTS]Slot

// The entry of `text` in `ctx` (nil: not translated).
@(private)
lookup :: proc "contextless" (l: ^Language, ctx, text: string) -> ^Entry {
	gen := sync.atomic_load(&generation)
	h := (uintptr(raw_data(text)) >> 3) ~ (uintptr(raw_data(ctx)) >> 5) ~ uintptr(len(text))
	s := &cache[h & (CACHE_SLOTS - 1)]
	// (the address alone is not enough: a text made at run time may sit where another was; the characters decide)
	if s.generation == gen && s.text == raw_data(text) && s.ctx == raw_data(ctx) && s.entry != nil &&
	   s.entry.english == text && s.entry.ctx == ctx {
		return s.entry
	}
	e := find(l, ctx, text)
	if e != nil { s^ = {raw_data(text), raw_data(ctx), e, gen} }
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
}

// The texts of one language, from the catalogues given to load. Made once; read by every thread.
Language :: struct {
	tag:     string,                    // "fr", "fr-CA": the tag it was loaded for
	rule:    proc "contextless" (count: int) -> int,   // the form for a count
	entries: [dynamic]Entry,
	table:   []i32,                     // open addressing: the index of an entry + 1, 0 empty
	arena:   runtime.Arena,             // the texts, unescaped
}

// The entry of `text` in `ctx`, by its characters (nil: none).
@(private)
find :: proc "contextless" (l: ^Language, ctx, text: string) -> ^Entry {
	if len(l.table) == 0 { return nil }
	mask := u64(len(l.table) - 1)
	for i := key_hash(ctx, text) & mask; ; i = (i + 1) & mask {
		at := l.table[i]
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
