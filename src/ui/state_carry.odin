package ui

// What a part of an interface keeps when it moves to another place, in its State or in another one (a view that goes
// from a dialog to a window of its own): the scroll of its boxes and the focus. The two places wrap it differently, so
// the boxes are paired by name (src/md/features/views.md, section 4.1, decision 4).

// The named boxes under `from_root` in `from` give their scroll and the focus to the boxes of the same names under
// `to_root` in `to`. A name found twice under either root is left alone; an unnamed box keeps nothing. Both subtrees
// are as their last builds laid them out.
state_carry :: proc(from: ^State, from_root: Key, to: ^State, to_root: Key) {
	a := from.boxes[from_root] or_else nil
	b := to.boxes[to_root] or_else nil
	if a == nil || b == nil { return }
	Named :: struct { box: ^Box, twice: bool }
	names := make(map[string]Named, 64, context.temp_allocator)
	collect :: proc(names: ^map[string]Named, x: ^Box) {
		for c := x.first; c != nil; c = c.next {
			if c.name != "" {
				if n, seen := names^[c.name]; seen { names^[c.name] = {n.box, true} } else { names^[c.name] = {c, false} }
			}
			collect(names, c)
		}
	}
	collect(&names, b)
	focus_inside := false
	for f := from.boxes[from.focus_key] or_else nil; f != nil; f = f.parent {
		if f == a { focus_inside = true; break }
	}
	seen := make(map[string]bool, 64, context.temp_allocator)
	pairs := make([dynamic][2]^Box, 0, 32, context.temp_allocator)
	pair :: proc(names: map[string]Named, seen: ^map[string]bool, pairs: ^[dynamic][2]^Box, x: ^Box) {
		for c := x.first; c != nil; c = c.next {
			if c.name != "" {
				if c.name in seen^ {
					seen^[c.name] = true   // (twice in the old place: ambiguous)
				} else {
					seen^[c.name] = false
					if n, ok := names[c.name]; ok && !n.twice { append(pairs, [2]^Box{c, n.box}) }
				}
			}
			pair(names, seen, pairs, c)
		}
	}
	pair(names, &seen, &pairs, a)
	for p in pairs {
		if seen[p[0].name] { continue }
		src, dst := p[0], p[1]
		dst.view_off, dst.view_target, dst.view_top_held = src.view_off, src.view_target, src.view_top_held
		if focus_inside && from.focus_key == src.key {
			to.focus_key, to.focus_visible = dst.key, from.focus_visible
		}
	}
}
