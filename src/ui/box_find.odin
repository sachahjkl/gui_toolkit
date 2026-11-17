package ui

import "core:strings"

// The `index`-th box of the last build, laid out with some width, named `name` (its id's hash part; "": any) whose words
// contain `text` (any case; "": any), from `within` down (nil: the root), in the tree's order. nil: none. What acts on an
// interface from outside it finds its boxes by this: a test's session, a film.
box_find :: proc(s: ^State, name: string, text := "", index := 0, within: ^Box = nil) -> ^Box {
	if name == "" && text == "" { return nil }
	found := 0
	lower := strings.to_lower(text, context.temp_allocator)
	return box_find_walk(s, within != nil ? within : s.root, name, lower, index, &found)
}

@(private = "file")
box_find_walk :: proc(s: ^State, b: ^Box, name, lower: string, index: int, found: ^int) -> ^Box {
	if b == nil || !box_current(s, b) { return nil }
	ok := name == "" || b.name == name
	if ok && lower != "" { ok = strings.contains(strings.to_lower(box_text(b), context.temp_allocator), lower) }
	if ok && b.rect.max.x > b.rect.min.x {
		if found^ == index { return b }
		found^ += 1
	}
	for c := b.first; c != nil; c = c.next {
		if r := box_find_walk(s, c, name, lower, index, found); r != nil { return r }
	}
	return nil
}
