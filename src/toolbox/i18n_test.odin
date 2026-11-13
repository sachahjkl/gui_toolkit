package tk_toolbox

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../fsx"

// The catalogue from the code: the translations kept, a new text added to translate, a text the code lost dropped, the
// three forms of tr; -check fails until every text is translated.
@(test)
a_catalogue_follows_the_code :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "gt-i18n-*", context.temp_allocator)
	if !testing.expect(t, err == nil, "a temporary folder") { return }
	defer fsx.remove_tree(dir)
	src := fmt.tprintf("%s/src", dir)
	_ = os.make_directory(src)
	code := "package sample\n" +
		"a :: proc() { _ = i18n.tr(\"Close\") }\n" +
		"b :: proc() { _ = i18n.tr(\"tab strip\", \"Close\") }\n" +
		"c :: proc(n: int) { _ = i18n.tr(n, \"%d file\", \"%d files\") }\n" +
		"d :: proc(s: string) { _ = i18n.tr(s) }   // not a literal\n" +
		"TITLE := i18n.later(\"Rounding\")\n"
	_ = os.write_entire_file(fmt.tprintf("%s/a.odin", src), transmute([]u8)code)
	cat := fmt.tprintf("%s/fr.txt", dir)
	old := "# mine\nlanguage fr\n\nen Close\nfr Fermer\n\nen Gone\nfr Parti\n"
	_ = os.write_entire_file(cat, transmute([]u8)old)
	testing.expect_value(t, i18n_catalogue({src}, cat, "fr", false), "")
	data, _ := os.read_entire_file(cat, context.temp_allocator)
	made := string(data)
	testing.expect(t, strings.has_prefix(made, "# mine\nlanguage fr\n"), "its head kept")
	testing.expect(t, strings.contains(made, "en Close\nfr Fermer\n"), "a translation kept")
	testing.expect(t, strings.contains(made, "ctx tab strip\nen Close\nfr\n"), "a context, to translate")
	testing.expect(t, strings.contains(made, "en %d file\nen+ %d files\nfr\nfr+\n"), "the forms by count")
	testing.expect(t, !strings.contains(made, "Gone"), "what the code lost")
	testing.expect(t, strings.contains(made, "en Rounding\nfr\n"), "a text translated later")
	testing.expect(t, i18n_catalogue({src}, cat, "fr", true) != "", "not all translated")
	done, _ := strings.replace_all(made, "ctx tab strip\nen Close\nfr\n", "ctx tab strip\nen Close\nfr Fermer l'onglet\n", context.temp_allocator)
	done, _ = strings.replace_all(done, "fr\nfr+\n", "fr %d fichier\nfr+ %d fichiers\n", context.temp_allocator)
	done, _ = strings.replace_all(done, "en Rounding\nfr\n", "en Rounding\nfr Arrondi\n", context.temp_allocator)
	_ = os.write_entire_file(cat, transmute([]u8)done)
	testing.expect_value(t, i18n_catalogue({src}, cat, "fr", true), "")
}
