package tk_config

import "core:testing"

@(private = "file")
SEARCH_DEFS := [?]Def{
	{name = "appearance.font_size", description = "Size of the interface's text.", kind = .Int, default = {i = 14}},
	{name = "appearance.glow", description = "Halos around lit buttons.", kind = .Bool, default = {b = true}},
	{name = "update.auto", description = "Look for a new version at start.", kind = .Bool, default = {b = true}},
	{name = "update.channel", description = "Which releases this copy follows.", kind = .String, default = {s = "stable"}},
}

// Two pages, as a settings dialog draws them: what a query shows, and each page's heading before its first row only.
@(private = "file")
shown :: proc(p: ^Prefs, query: string) -> (rows: [dynamic]string, headings: [dynamic]string, found: int) {
	s: Search
	search_begin(&s, query)
	rows = make([dynamic]string, context.temp_allocator)
	headings = make([dynamic]string, context.temp_allocator)
	pages := [?]struct { title: string, names: []string }{
		{"Appearance", {"appearance.font_size", "appearance.glow"}},
		{"Updates", {"update.auto", "update.channel"}},
	}
	for page in pages {
		search_page(&s, page.title)
		for name in page.names {
			show, heading := search_shows(&s, p, name)
			if heading != "" { append(&headings, heading) }
			if show { append(&rows, name) }
		}
	}
	return rows, headings, s.found
}

@(test)
a_search_shows_what_matches_under_its_page :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, SEARCH_DEFS[:])

	rows, headings, found := shown(&p, "")
	testing.expect_value(t, len(rows), 4)    // no search: everything, and no headings (the page says its title)
	testing.expect_value(t, len(headings), 0)
	testing.expect_value(t, found, 0)

	rows, headings, found = shown(&p, "  VERSION start ")   // words in any case and order, in the description
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0], "update.auto")
	testing.expect_value(t, len(headings), 1)
	testing.expect_value(t, headings[0], "Updates")
	testing.expect_value(t, found, 1)

	rows, headings, _ = shown(&p, "appearance")   // a page's title: all of it, its heading once
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, len(headings), 1)

	rows, headings, found = shown(&p, "nothing like this")
	testing.expect_value(t, len(rows), 0)
	testing.expect_value(t, len(headings), 0)
	testing.expect_value(t, found, 0)

	s: Search
	search_begin(&s, "glow")
	search_page(&s, "Appearance")
	show, _ := search_shows(&s, &p, "no.such.preference")
	testing.expect(t, !show, "a name that is not registered never shows")
}
