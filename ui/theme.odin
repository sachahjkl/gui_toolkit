package ui

import "core:strings"

// theme_add("card background", color): the last word is the queried name, the others are required tags.
theme_add :: proc(t: ^Theme, tags: string, color: Color) {
	parts := strings.split(tags, " ", context.allocator)
	append(&t.patterns, Theme_Pattern{tags = parts, color = color})
}

theme_set :: proc(t: ^Theme, tags: string, color: Color) {
	for &p in t.patterns {
		if strings.join(p.tags, " ", context.temp_allocator) == tags { p.color = color; return }
	}
	theme_add(t, tags, color)
}

theme_destroy :: proc(t: ^Theme) {
	for p in t.patterns { delete(p.tags) }
	delete(t.patterns)
}

// `name` may have several words ("focus border"): the last one is the color name, the others act as extra tags
// that count as present (like raddebugger's ui_color_from_tags_key_extras).
theme_lookup :: proc(t: ^Theme, stack: []string, name: string) -> Color {
	extras: []string
	key := name
	if i := strings.last_index_byte(name, ' '); i >= 0 {
		key = name[i + 1:]
		extras = strings.split(name[:i], " ", context.temp_allocator)
	}
	best := -1
	best_n := 0
	for p, i in t.patterns {
		n := len(p.tags)
		if p.tags[n - 1] != key || n <= best_n { continue }
		ok := true
		for tag in p.tags[:n - 1] {
			found := false
			for st in stack { if st == tag { found = true; break } }
			for ex in extras { if ex == tag { found = true; break } }
			if !found { ok = false; break }
		}
		if ok { best = i; best_n = n }
	}
	if best < 0 { return {1, 0, 1, 1} }   // magenta = missing theme entry
	return t.patterns[best].color
}

// Color for `name` under the tags a box was built with (usable from custom draw procs).
color_from_tags :: proc(s: ^State, tags_key: Key, name: string) -> Color {
	stack := s.tag_sets[tags_key]
	return theme_lookup(s.theme, stack, name)
}

// Color for `name` under the current tag stack while building.
color :: proc(name: string) -> Color {
	return theme_lookup(g.theme, g.tag_stack[:], name)
}
