// The texts a program shows, by language (src/i18n, prefs_page.language_start). One test at a time (tools/run_tests): the
// language in use is one for the process.
package i18n_test

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
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
OWN_PASTE :: `language fr

en Paste
fr Collage
`

// A program's catalogue never changes the toolkit's words: the toolkit's code (a file under its src/) finds the toolkit's
// "Paste" though the program says "Collage"; the program's code finds its own; a text only the other has is found there.
@(test)
each_catalogue_is_its_domain :: proc(t: ^testing.T) {
	root := i18n.toolkit_root()
	toolkit_file := fmt.tprintf("%s/ui/field_menu.odin", root)
	testing.expect_value(t, i18n.domain_of(toolkit_file), i18n.Domain.Toolkit)
	testing.expect_value(t, i18n.domain_of(#file), i18n.Domain.Program)
	testing.expect_value(t, i18n.domain_of(fmt.tprintf("%s_other/a.odin", root)), i18n.Domain.Program)   // (a folder beside it)
	testing.expect_value(t, i18n.domain_of(root), i18n.Domain.Program)
	l, bad := i18n.load("fr", {{"fr", OWN_PASTE}, {"fr", PROGRAM_FR}})
	defer { i18n.use(nil); i18n.destroy(l) }
	testing.expect_value(t, len(bad), 0)
	i18n.use(l)
	toolkit := runtime.Source_Code_Location{file_path = toolkit_file}
	testing.expect_value(t, i18n.tr("Paste"), "Collage")
	testing.expect_value(t, i18n.tr_text("Paste", toolkit), "Coller")
	// (twice: the thread's cache keeps the two answers of one literal apart)
	testing.expect_value(t, i18n.tr("Paste"), "Collage")
	testing.expect_value(t, i18n.tr_text("Paste", toolkit), "Coller")
	// the other domain's text: the program's in the toolkit's widgets, the toolkit's in the program
	testing.expect_value(t, i18n.tr_text("Open the history", toolkit), "Ouvrir l'historique")
	testing.expect_value(t, i18n.tr("Search settings"), "Rechercher un réglage")
}

// French typography is set at load: the space before : ; ? ! % » and after « never ends a line; a format verb, a time, an
// address are left alone; the tool reads the catalogue as written.
@(test)
french_typography_at_load :: proc(t: ^testing.T) {
	NB :: i18n.NO_BREAK_SPACE
	testing.expect_value(t, i18n.typeset("fr", "Fichier : %s ; prêt ? oui ! « a » 34 % et 12 %% de %s à 12:30 http://x"),
		"Fichier" + NB + ": %s" + NB + "; prêt" + NB + "? oui" + NB + "! «" + NB + "a" + NB + "» 34" + NB + "% et 12" + NB + "%% de %s à 12:30 http://x")
	testing.expect_value(t, i18n.typeset("en", "Name : x"), "Name : x")
	l, _ := i18n.load("fr", {{"fr", "language fr\n\nen A: b\nfr A : b\n"}}, with_toolkit = false)
	defer { i18n.use(nil); i18n.destroy(l) }
	i18n.use(l)
	testing.expect_value(t, i18n.tr("A: b"), "A" + NB + ": b")
	raw, _ := i18n.load("fr", {{"fr", "language fr\n\nen A: b\nfr A : b\n"}}, with_toolkit = false, as_written = true)
	defer i18n.destroy(raw)
	testing.expect_value(t, raw.entries[0].forms[0], "A : b")
}

// Numbers as the language writes them: "7.8" and "34%" in English, "7,8" and "34 %" in French; either mark is read.
@(test)
numbers_follow_the_language :: proc(t: ^testing.T) {
	testing.expect_value(t, i18n.decimal(7.84, 1), "7.8")
	testing.expect_value(t, i18n.percent(0.34), "34%")
	testing.expect_value(t, i18n.decimal_marks("2.2 ms, v1.2"), "2.2 ms, v1.2")
	l, _ := i18n.load("fr", {{"fr", SAMPLE}})
	defer { i18n.use(nil); i18n.destroy(l) }
	i18n.use(l)
	testing.expect_value(t, i18n.decimal_mark(), u8(','))
	testing.expect_value(t, i18n.decimal(7.84, 1), "7,8")
	testing.expect_value(t, i18n.decimal(1, 2), "1,00")
	testing.expect_value(t, i18n.decimal(-0.5, 1), "-0,5")
	testing.expect_value(t, i18n.percent(0.34), "34" + i18n.NO_BREAK_SPACE + "%")
	testing.expect_value(t, i18n.percent(0.125, 1), "12,5" + i18n.NO_BREAK_SPACE + "%")
	testing.expect_value(t, i18n.decimal_marks("2.2 ms. 26.3 Mbit/s"), "2,2 ms. 26,3 Mbit/s")
	for text in ([]string{"7,8", " 7.8 ", "7,80"}) {
		v, ok := i18n.parse_decimal(text)
		testing.expectf(t, ok && abs(v - 7.8) < 1e-9, "%q: %v %v", text, v, ok)
	}
	_, ok := i18n.parse_decimal("sept")
	testing.expect(t, !ok, "not a number")
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

// A change of general.language is in use at once, on this thread and on another whose cache holds the old language's
// answers; i18n.version moves with it (what a program made of translated text is made again), and only then: the same
// language again changes nothing, and a language picked again is the one loaded before.
@(test)
the_language_changes_at_once :: proc(t: ^testing.T) {
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	prefs_page.standard_register(&prefs, {.Session}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	defer i18n.use(nil)
	_ = config.set_from_string(&prefs, prefs_page.LANGUAGE_PREF, "fr", .User)
	prefs_page.language_start(&prefs, {{"fr", PROGRAM_FR}})
	french := i18n.current()
	testing.expect(t, french != nil, "French in use")
	testing.expect_value(t, i18n.tr("Open the history"), "Ouvrir l'historique")   // (this thread's cache holds it now)
	Worker :: struct { sem: sync.Sema, done: sync.Sema, shown: [2]string }
	w: Worker
	th := thread.create_and_start_with_poly_data(&w, proc(w: ^Worker) {
		w.shown[0] = i18n.tr("Open the history")
		sync.post(&w.done)
		sync.wait(&w.sem)
		w.shown[1] = i18n.tr("Open the history")
		sync.post(&w.done)
	})
	defer thread.destroy(th)
	sync.wait(&w.done)
	before := i18n.version()
	_ = config.set_from_string(&prefs, prefs_page.LANGUAGE_PREF, "en", .User)
	testing.expect_value(t, i18n.tr("Open the history"), "Open the history")
	testing.expect(t, i18n.version() != before, "the version moved")
	sync.post(&w.sem)
	sync.wait(&w.done)
	testing.expect_value(t, w.shown[0], "Ouvrir l'historique")
	testing.expect_value(t, w.shown[1], "Open the history")
	_ = config.set_from_string(&prefs, prefs_page.LANGUAGE_PREF, "fr", .User)
	testing.expect(t, i18n.current() == french, "the language loaded before")
	testing.expect_value(t, i18n.tr("Open the history"), "Ouvrir l'historique")
	same := i18n.version()
	i18n.use(french)
	testing.expect_value(t, i18n.version(), same)
}
