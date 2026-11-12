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

// The slots of a rank's cache that one item takes: RANK_MATCH_SLOTS for its matcher, then one for its last text.
RANK_MATCH_SLOTS :: 3
@(private = "file") RANK_SLOTS :: RANK_MATCH_SLOTS + 1

// How a query (folded once: `needle`) matches an entry: rank_palette, rank_fuzzy, or a program's own. It folds the texts
// it reads with fuzzy_cache_text in `c`, in the slots `first` to `first + RANK_MATCH_SLOTS - 1`: a text that did not
// change since the last rank is not folded again.
Rank_Match :: #type proc(needle: Fuzzy_Needle, e: Rank_Entry, c: ^Fuzzy_Cache, first: int) -> (score: int, ranges: []Fuzzy_Range, ok: bool)

// palette_match as a Rank_Match: the label, then the tags, then the group (the palette's way).
rank_palette :: proc(needle: Fuzzy_Needle, e: Rank_Entry, c: ^Fuzzy_Cache, first: int) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	return palette_match(needle, palette_entry_cached(c, first, e.label, e.group, e.tags))
}

// fuzzy_score as a Rank_Match: the label, and the group after it, as one text ("claude-sonnet-5  Anthropic"); tags unused.
rank_fuzzy :: proc(needle: Fuzzy_Needle, e: Rank_Entry, c: ^Fuzzy_Cache, first: int) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	if e.group == "" { return fuzzy_score(needle, fuzzy_cache_text(c, first, e.label)) }
	return fuzzy_score(needle, fuzzy_cache_text(c, first, e.label, "  ", e.group))
}

// The items of `items` that `query` finds, best first; equal scores keep the list's order (an empty query: every item, in
// order, as the matchers give it 0). `entry` says how an item reads, `match` scores it (rank_palette by default);
// `bonus`, when given, adds to a hit's score (how often the user chose it lately): it is called for hits only. `user` is
// passed to both. The hits and their ranges are in temp memory. `cache`: the query and the items' texts folded, kept from
// one call to the next (an item's texts by its index in `items`), so that a list ranked each frame folds only what
// changed; nil folds everything for this call alone. The matching itself is in proportion to the list.
rank :: proc(query: string, items: []$T, entry: proc(it: ^T, user: rawptr) -> Rank_Entry, user: rawptr = nil,
	match: Rank_Match = rank_palette, bonus: proc(it: ^T, user: rawptr) -> f64 = nil, cache: ^Fuzzy_Cache = nil) -> []Rank_Hit {
	once: Fuzzy_Cache
	c := cache != nil ? cache : &once
	defer if cache == nil { fuzzy_cache_destroy(&once) }   // (the hits' ranges are in temp memory, not in the cache)
	needle := fuzzy_cache_needle(c, query)
	hits := make([dynamic]Rank_Hit, 0, len(items), context.temp_allocator)
	for &it, i in items {
		e := entry(&it, user)
		if e.skip { continue }
		score, ranges, ok := match(needle, e, c, RANK_SLOTS * i)
		if !ok && e.last != "" {
			score, _, ok = fuzzy_words(needle, fuzzy_cache_text(c, RANK_SLOTS * i + RANK_MATCH_SLOTS, e.last))
			score -= RANK_LAST_PENALTY   // (after every hit of a label, tags or group: it is the last resort)
			ranges = nil
		}
		if !ok { continue }
		s := f64(score)
		if bonus != nil { s += bonus(&it, user) }
		append(&hits, Rank_Hit{i, s, ranges})
	}
	if cache != nil { fuzzy_cache_keep(cache, RANK_SLOTS * len(items)) }
	slice.stable_sort_by(hits[:], proc(a, b: Rank_Hit) -> bool { return a.score > b.score })
	return hits[:]
}
