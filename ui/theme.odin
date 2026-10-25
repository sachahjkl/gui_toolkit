package ui

import "core:strings"

// theme_add("card background", color): the last word is the queried name, the others are required tags. `tags` is
// copied (it may be a temporary string).
theme_add :: proc(t: ^Theme, tags: string, color: Color) {
	source := strings.clone(tags, context.allocator)
	parts := strings.split(source, " ", context.allocator)
	append(&t.patterns, Theme_Pattern{tags = parts, color = color, source = source})
	t.serial += 1
}

theme_set :: proc(t: ^Theme, tags: string, color: Color) {
	for &p in t.patterns {
		if strings.join(p.tags, " ", context.temp_allocator) == tags {
			if p.color != color { p.color = color; t.serial += 1 }
			return
		}
	}
	theme_add(t, tags, color)
}

theme_destroy :: proc(t: ^Theme) {
	for p in t.patterns {
		delete(p.tags)
		delete(p.source)
	}
	delete(t.patterns)
	t.palette_made = false
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

// Color for `name` under the tags a box was built with (usable from custom draw procs). Looked up once per build and
// draw for each (tag stack, name): every box asks for the same few.
color_from_tags :: proc(s: ^State, tags_key: Key, name: string) -> Color {
	k := [2]u64{u64(tags_key), name_hash(name)}
	if c, ok := s.color_memo[k]; ok { return c }
	c := theme_lookup(s.theme, s.tag_sets[tags_key], name)
	s.color_memo[k] = c
	return c
}

// Color for `name` under the current tag stack while building.
color :: proc(name: string) -> Color {
	return color_from_tags(g, current_tags_key(g), name)
}

@(private)
name_hash :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for c in transmute([]u8)s { h = (h ~ u64(c)) * 0x100000001b3 }
	return h
}
