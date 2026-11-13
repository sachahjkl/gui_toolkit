// The texts a program shows, by language (src/i18n, prefs_page.language_start). One test at a time (tools/run_tests): the
// language in use is one for the process.
package i18n_test

import "core:fmt"
import "core:strings"
import "core:testing"
import config "../../src/config"
import i18n "../../src/i18n"
import prefs_page "../../src/prefs_page"

@(test)
english_is_the_text_itself :: proc(t: ^testing.T) {
	testing.expect_value(t, i18n.tr("Open in a new tab"), "Open in a new tab")
	testing.expect_value(t, i18n.tr(""), "")
	testing.expect_value(t, i18n.tr("tab strip", "Close"), "Close")
}

@(test)
plural_follows_the_count :: proc(t: ^testing.T) {
	testing.expect_value(t, i18n.tr(0, "%d request", "%d requests"), "%d requests")
	testing.expect_value(t, i18n.tr(1, "%d request", "%d requests"), "%d request")
	testing.expect_value(t, i18n.tr(2, "%d request", "%d requests"), "%d requests")
	testing.expect_value(t, i18n.tr(-1, "%d request", "%d requests"), "%d requests")
	n := 1
	testing.expect_value(t, i18n.tr(n, "%d tab", "%d tabs"), "%d tab")
}

// English costs nothing: the text comes back as the very same bytes (no copy, no allocation), which is what keeps a call in
// an interface drawn every frame free.
@(test)
english_returns_the_same_bytes :: proc(t: ^testing.T) {
	text := "Open in a new tab"
	testing.expect(t, raw_data(i18n.tr(text)) == raw_data(text), "tr copied the text")
	testing.expect(t, raw_data(i18n.tr("menu", text)) == raw_data(text), "tr with a context copied the text")
	testing.expect(t, raw_data(i18n.tr(1, text, "other")) == raw_data(text), "tr with a count copied the text")
}

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


// A language: its texts, its contexts, its forms by count (French: 0 is singular), the English where it has none.
@(test)
a_language_gives_its_texts :: proc(t: ^testing.T) {
	l, bad := i18n.load("fr-FR", {{"fr", SAMPLE}})
	defer { i18n.use(nil); i18n.destroy(l) }
	testing.expect_value(t, len(bad), 0)
	i18n.use(l)
	testing.expect_value(t, i18n.tr("Close"), "Fermer")
	testing.expect_value(t, i18n.tr("tab strip", "Close"), "Fermer l'onglet")
	testing.expect_value(t, i18n.tr(0, "%d request", "%d requests"), "%d requête")
	testing.expect_value(t, i18n.tr(2, "%d request", "%d requests"), "%d requêtes")
	testing.expect_value(t, i18n.tr("Two\nlines"), "Deux\nlignes")
	testing.expect_value(t, i18n.tr("Not yet"), "Not yet")
	testing.expect_value(t, i18n.tr("Never written"), "Never written")
	// (twice: the second answer comes from the thread's cache)
	testing.expect_value(t, i18n.tr("Close"), "Fermer")
}

// A text made at run time at the address where a literal was: its own characters decide, never the cache.
@(test)
a_made_text_is_not_taken_for_another :: proc(t: ^testing.T) {
	l, _ := i18n.load("fr", {{"fr", SAMPLE}})
	defer { i18n.use(nil); i18n.destroy(l) }
	i18n.use(l)
	buf: [16]u8
	copy(buf[:], "Close")
	made := string(buf[:5])
	testing.expect_value(t, i18n.tr(made), "Fermer")
	copy(buf[:], "Clase")
	testing.expect_value(t, i18n.tr(made), "Clase")
}

// English and an unknown language load nothing; a catalogue of another language is said.
@(test)
what_loads :: proc(t: ^testing.T) {
	l, _ := i18n.load("en-GB", {{"fr", SAMPLE}})
	testing.expect(t, l == nil, "English")
	l, _ = i18n.load("de", {{"fr", SAMPLE}})
	testing.expect(t, l == nil, "no German")
	wrong, bad := i18n.load("fr", {{"fr", "language de\nen A\nfr B\n"}})
	defer i18n.destroy(wrong)
	testing.expect(t, len(bad) == 1 && strings.contains(bad[0], "another language"), fmt.tprint(bad))
}

// The rules: French reads 0 and 1 as one; Polish has three forms; English two.
@(test)
the_forms_by_count :: proc(t: ^testing.T) {
	fr, pl, en := i18n.plural_rule("fr"), i18n.plural_rule("pl"), i18n.plural_rule("en")
	testing.expect_value(t, fr(0), 0)
	testing.expect_value(t, fr(2), 1)
	testing.expect_value(t, en(0), 1)
	testing.expect_value(t, pl(1), 0)
	testing.expect_value(t, pl(3), 1)
	testing.expect_value(t, pl(5), 2)
	testing.expect_value(t, pl(22), 1)
	testing.expect_value(t, i18n.escape("a\nb\\c", context.temp_allocator), "a\\nb\\\\c")
}

@(private = "file")
PROGRAM_FR :: `language fr

en Open the history
fr Ouvrir l'historique
`

// French asked: the program's texts and the setting's own labels in French; English asked: the texts themselves.
@(test)
the_language_asked_is_in_use :: proc(t: ^testing.T) {
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	d := prefs_page.STANDARD_DEFAULTS
	d.app_name = "Sample"
	prefs_page.standard_register(&prefs, {.Session}, d, context.temp_allocator)
	defer i18n.use(nil)
	_ = config.set_from_string(&prefs, prefs_page.LANGUAGE_PREF, "fr", .User)
	testing.expect_value(t, prefs_page.language_start(&prefs, {{"fr", PROGRAM_FR}}), "fr")
	testing.expect_value(t, i18n.tr("Open the history"), "Ouvrir l'historique")
	_ = config.set_from_string(&prefs, prefs_page.LANGUAGE_PREF, "en", .User)
	prefs_page.language_start(&prefs, {{"fr", PROGRAM_FR}})
	testing.expect_value(t, i18n.tr("Open the history"), "Open the history")
}
