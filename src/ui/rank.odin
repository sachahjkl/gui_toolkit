package ui

@(require) import "core:slice"   // (rank is generic: its body is checked only where a program uses it)

// A filtered list, the same way everywhere: each item matched against the query, the hits kept, the best first. A picker,
// a slash menu, a mention list and a palette differ only in how an item reads (Rank_Entry) and which matcher scores it.

// One item as the ranking reads it.
Rank_Entry :: struct {
	label: string,     // what the query lights (the hit's ranges are in it)
	group: string,     // its group: palette_match finds an item by it after its label; fuzzy_match reads "label  group" as one text
	tags:  []string,   // other words it is found by (palette_match)
	last:  string,     // a text that finds it when nothing else does (a setting's key, "appearance.system_title"): fuzzy_words, nothing lit
	skip:  bool,       // not in the list whatever is typed (an item of another kind)
}

// A kept item: its index in the list, its score (higher first), what lights in its label.
Rank_Hit :: struct {
	index:  int,
	score:  f64,
	ranges: []Fuzzy_Range,
}

@(private = "file") RANK_LAST_PENALTY :: 100_000

// How a query matches an entry: palette_match, fuzzy_match, or a program's own.
Rank_Match :: #type proc(query, label, group: string, tags: []string) -> (score: int, ranges: []Fuzzy_Range, ok: bool)

// fuzzy_score as a Rank_Match: the label, and the group after it, as one text ("claude-sonnet-5  Anthropic"); tags unused.
fuzzy_match :: proc(query, label, group: string, tags: []string) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	if group == "" { return fuzzy_score(query, label) }
	hay := make([]u8, len(label) + 2 + len(group), context.temp_allocator)
	copy(hay, label)
	copy(hay[len(label):], "  ")
	copy(hay[len(label) + 2:], group)
	return fuzzy_score(query, string(hay))
}

// The items of `items` that `query` finds, best first; equal scores keep the list's order (an empty query: every item, in
// order, as the matchers give it 0). `entry` says how an item reads, `match` scores it (palette_match by default);
// `bonus`, when given, adds to a hit's score (how often the user chose it lately): it is called for hits only. `user` is
// passed to both. The hits and their ranges are in temp memory. The work is in proportion to the list: call it when the
// query or the list changes, not every frame of a long list.
rank :: proc(query: string, items: []$T, entry: proc(it: ^T, user: rawptr) -> Rank_Entry, user: rawptr = nil,
	match: Rank_Match = palette_match, bonus: proc(it: ^T, user: rawptr) -> f64 = nil) -> []Rank_Hit {
	hits := make([dynamic]Rank_Hit, 0, len(items), context.temp_allocator)
	for &it, i in items {
		e := entry(&it, user)
		if e.skip { continue }
		score, ranges, ok := match(query, e.label, e.group, e.tags)
		if !ok && e.last != "" {
			score, _, ok = fuzzy_words(query, e.last)
			score -= RANK_LAST_PENALTY   // (after every hit of a label, tags or group: it is the last resort)
			ranges = nil
		}
		if !ok { continue }
		s := f64(score)
		if bonus != nil { s += bonus(&it, user) }
		append(&hits, Rank_Hit{i, s, ranges})
	}
	slice.stable_sort_by(hits[:], proc(a, b: Rank_Hit) -> bool { return a.score > b.score })
	return hits[:]
}
