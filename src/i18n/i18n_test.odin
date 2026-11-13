package tk_i18n

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
SAMPLE :: `# a sample
language fr

en Close
fr Fermer

ctx tab strip
en Close
fr Fermer l'onglet

en %d request
en+ %d requests
fr %d requête
fr+ %d requêtes

en Two\nlines
fr Deux\nlignes

en Not yet
fr
`

// English: each call is its argument, the same bytes.
@(test)
english_is_the_text_itself :: proc(t: ^testing.T) {
	use(nil)
	s := "Open in a new tab"
	testing.expect(t, raw_data(tr(s)) == raw_data(s), "the same bytes")
	testing.expect_value(t, tr(1, "%d file", "%d files"), "%d file")
	testing.expect_value(t, tr(0, "%d file", "%d files"), "%d files")
}

// A language: its texts, its contexts, its forms by count (French: 0 is singular), the English where it has none.
@(test)
a_language_gives_its_texts :: proc(t: ^testing.T) {
	l, bad := load("fr-FR", {{"fr", SAMPLE}})
	defer { use(nil); destroy(l) }
	testing.expect_value(t, len(bad), 0)
	use(l)
	testing.expect_value(t, tr("Close"), "Fermer")
	testing.expect_value(t, tr("tab strip", "Close"), "Fermer l'onglet")
	testing.expect_value(t, tr(0, "%d request", "%d requests"), "%d requête")
	testing.expect_value(t, tr(2, "%d request", "%d requests"), "%d requêtes")
	testing.expect_value(t, tr("Two\nlines"), "Deux\nlignes")
	testing.expect_value(t, tr("Not yet"), "Not yet")
	testing.expect_value(t, tr("Never written"), "Never written")
	// (twice: the second answer comes from the thread's cache)
	testing.expect_value(t, tr("Close"), "Fermer")
}

// A text made at run time at the address where a literal was: its own characters decide, never the cache.
@(test)
a_made_text_is_not_taken_for_another :: proc(t: ^testing.T) {
	l, _ := load("fr", {{"fr", SAMPLE}})
	defer { use(nil); destroy(l) }
	use(l)
	buf: [16]u8
	copy(buf[:], "Close")
	made := string(buf[:5])
	testing.expect_value(t, tr(made), "Fermer")
	copy(buf[:], "Clase")
	testing.expect_value(t, tr(made), "Clase")
}

// English and an unknown language load nothing; a catalogue of another language is said.
@(test)
what_loads :: proc(t: ^testing.T) {
	l, _ := load("en-GB", {{"fr", SAMPLE}})
	testing.expect(t, l == nil, "English")
	l, _ = load("de", {{"fr", SAMPLE}})
	testing.expect(t, l == nil, "no German")
	wrong, bad := load("fr", {{"fr", "language de\nen A\nfr B\n"}})
	defer destroy(wrong)
	testing.expect(t, len(bad) == 1 && strings.contains(bad[0], "another language"), fmt.tprint(bad))
}

// The rules: French reads 0 and 1 as one; Polish has three forms; English two.
@(test)
the_forms_by_count :: proc(t: ^testing.T) {
	fr, pl, en := plural_rule("fr"), plural_rule("pl"), plural_rule("en")
	testing.expect_value(t, fr(0), 0)
	testing.expect_value(t, fr(2), 1)
	testing.expect_value(t, en(0), 1)
	testing.expect_value(t, pl(1), 0)
	testing.expect_value(t, pl(3), 1)
	testing.expect_value(t, pl(5), 2)
	testing.expect_value(t, pl(22), 1)
	testing.expect_value(t, escape("a\nb\\c", context.temp_allocator), "a\\nb\\\\c")
}
