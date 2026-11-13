package tk_config

import "core:testing"

@(test)
titles_read_as_phrases :: proc(t: ^testing.T) {
	T :: struct { d: Def, want: string }
	cases := [?]T{
		{{name = "blocker.badge.style", kind = .String}, "Style"},                   // its groups are headings
		{{name = "blocker.cosmetic.debounce_ms", kind = .Int}, "Debounce"},
		{{name = "blocker.badge.enabled", kind = .Bool}, "Enabled"},                 // nothing else to say
		{{name = "appearance.dark_mode_enabled", kind = .Bool}, "Dark mode"},
		{{name = "network.http.max_connections_per_host", kind = .Int}, "Max connections per host"},
		{{name = "devtools.ui_font_size_px", kind = .Int}, "UI font size"},
		{{name = "text.ms", kind = .Int}, "Ms"},                                     // a unit alone stays
		{{name = "solo", kind = .Int}, "Solo"},
	}
	for c in cases { testing.expect_value(t, title_of(c.d), c.want) }
	testing.expect_value(t, title_of(Def{name = "devtools.network.max_body_kb", kind = .Int}, keep_unit = true), "Max body KB")
}

// A name says its groups; a group's title is the program's, else made from its last segment; the order the program
// gives, else the order its first preference came in.
@(test)
groups_come_from_the_name :: proc(t: ^testing.T) {
	path := path_of("appearance.text.gamma")
	testing.expect_value(t, len(path), 2)
	testing.expect_value(t, path[0], "appearance")
	testing.expect_value(t, path[1], "appearance.text")
	testing.expect_value(t, len(path_of("solo")), 0)
	testing.expect_value(t, len(path_of("appearance.theme")), 1)

	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, []Def{
		{name = "update.auto", kind = .Bool},
		{name = "appearance.theme", kind = .String},
		{name = "appearance.text.gamma", kind = .Float, default = {f = 1.8}},
		{name = "appearance.cursor.blink", kind = .Bool, advanced = true},
		{name = "devtools.port", kind = .Int},
		{name = "layout.split", kind = .Float, hidden = true},   // the program's state: in no list of settings
		{name = "solo", kind = .Int},                            // in no group
	})
	testing.expect_value(t, group_title(&p, "devtools"), "DevTools")
	testing.expect_value(t, group_title(&p, "appearance.text"), "Text")
	testing.expect_value(t, group_title(&p, "web_platform"), "Web platform")
	title_register(&p, "appearance.text", "Text and fonts")
	title_register(&p, "appearance", "Look", order = -1)
	title_register(&p, "appearance", "Appearance", order = -1)   // again: the last one wins
	testing.expect_value(t, group_title(&p, "appearance.text"), "Text and fonts")
	testing.expect_value(t, group_title(&p, "appearance"), "Appearance")

	top := groups_of(&p)
	testing.expect_value(t, len(top), 3)
	testing.expect_value(t, top[0], "appearance")   // its order first
	testing.expect_value(t, top[1], "update")       // then as they came
	testing.expect_value(t, top[2], "devtools")
	inner := groups_of(&p, "appearance")
	testing.expect_value(t, len(inner), 2)
	testing.expect_value(t, inner[0], "appearance.text")
	testing.expect_value(t, inner[1], "appearance.cursor")
	testing.expect_value(t, len(groups_of(&p, "appearance.text")), 0)

	// the titles of its groups find a preference too
	gamma := entry(&p, ref_of(&p, "appearance.text.gamma")).def
	testing.expect(t, matches(&p, gamma, "fonts gamma"))
	testing.expect(t, !matches(&p, gamma, "fonts blink"))
}

// An advanced preference is a setting all the same: a search finds it, and it is in its group.
@(test)
a_search_finds_an_advanced_preference :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, []Def{
		{name = "network.proxy", kind = .String, description = "Where requests go."},
		{name = "network.dns_cache_ttl_s", kind = .Int, description = "How long a DNS answer is kept.", advanced = true},
	})
	s: Search
	search_begin(&s, "dns")
	search_page(&s, "Network")
	show, heading := search_shows(&s, &p, "network.dns_cache_ttl_s")
	testing.expect(t, show, "an advanced preference shows in a search")
	testing.expect_value(t, heading, "Network")
	show, _ = search_shows(&s, &p, "network.proxy")
	testing.expect(t, !show)
	testing.expect_value(t, groups_of(&p)[0], "network")
}

@(test)
summary_is_the_first_sentence :: proc(t: ^testing.T) {
	T :: struct { text, summary, more: string }
	cases := [?]T{
		{"One sentence.", "One sentence.", ""},
		{"No full stop", "No full stop", ""},
		{"First. Second one.", "First.", "Second one."},
		{"Use e.g. this. Then that.", "Use e.g. this.", "Then that."},
		{"Scale 0.5 to 2. More.", "Scale 0.5 to 2.", "More."},
		{"Inside (see below. Then more) stays. Next.", "Inside (see below. Then more) stays.", "Next."},
		{"lower after. stop is not a sentence", "lower after. stop is not a sentence", ""},
		{"Why? Because.", "Why?", "Because."},
		{"  Spaces.   Around.  ", "Spaces.", "Around."},
	}
	for c in cases {
		s, m := summary_of(c.text)
		testing.expect_value(t, s, c.summary)
		testing.expect_value(t, m, c.more)
	}
}

@(test)
search_matches_every_word :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	d := Def{name = "blocker.badge_style", kind = .String, description = "Where the blocked count goes on the shield."}
	testing.expect(t, matches(&p, d, ""))
	testing.expect(t, matches(&p, d, "badge"))
	testing.expect(t, matches(&p, d, "badge style"))         // the title ("Badge style")
	testing.expect(t, matches(&p, d, "shield count"))        // the description, any order
	testing.expect(t, matches(&p, d, "blocker.badge"))       // the name
	testing.expect(t, !matches(&p, d, "badge network"))      // every word must match
	testing.expect(t, !matches(&p, d, "cookies"))
	d.tags = {"counter", "icon"}
	testing.expect(t, matches(&p, d, "icon"), "a tag")
	testing.expect(t, matches(&p, d, "badge counter"), "a word of the title and a tag")
}

// A title the program gives wins over the one made from the name.
@(test)
a_title_of_its_own :: proc(t: ^testing.T) {
	d := Def{name = "shortcut.qr", kind = .String, title = "Read a QR code"}
	testing.expect_value(t, title_of(d), "Read a QR code")
	d.title = ""
	testing.expect_value(t, title_of(d), "Qr")
}
