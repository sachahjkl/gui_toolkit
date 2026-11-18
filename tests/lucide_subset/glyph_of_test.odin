// lucide.glyph_of: an icon by its name (a plugin's node names one), by a binary search of the generated table.
package lucide_subset_test

import "core:testing"
import lucide "gt:lucide"

@(test)
an_icon_is_found_by_its_name :: proc(t: ^testing.T) {
	g, ok := lucide.glyph_of("search")
	testing.expect(t, ok && g == lucide.SEARCH, "search")
	g, ok = lucide.glyph_of("alert-triangle")
	testing.expect(t, ok && g == lucide.ALERT_TRIANGLE, "alert-triangle")
	// the table's ends: the search reaches both
	first := lucide.NAMES[0]
	last := lucide.NAMES[len(lucide.NAMES) - 1]
	g, ok = lucide.glyph_of(first.name)
	testing.expectf(t, ok && g == first.glyph, "the first, %s", first.name)
	g, ok = lucide.glyph_of(last.name)
	testing.expectf(t, ok && g == last.glyph, "the last, %s", last.name)
	testing.expect_value(t, first.name, "a-arrow-down")
	testing.expect_value(t, last.name, "zoom-out")
	// what is no icon: unknown, a case the font does not use, a prefix, before the first and after the last
	for name in ([?]string{"no-such-icon", "Search", "sea", "", "0", "zzz"}) {
		_, found := lucide.glyph_of(name)
		testing.expectf(t, !found, "'%s' was found", name)
	}
	// (sorted by bytes, each once: the search's premise)
	for i in 1 ..< len(lucide.NAMES) {
		if !(lucide.NAMES[i - 1].name < lucide.NAMES[i].name) {
			testing.expectf(t, false, "%s is not before %s", lucide.NAMES[i - 1].name, lucide.NAMES[i].name)
			break
		}
	}
}
