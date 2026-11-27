package ui

// Native child views hosted inside a toolkit window (src/md/features/popup-over-native.md):
// a program that embeds an OS child window (such as WebView2 on Windows) calls `native_child(b)`
// on the box that holds it during each build. At `end_build`, after layout, `ui` computes:
//   - `native_split`: the last direct child of `s.root` that contains a visible native child.
//     Root children up to and including it draw on the base surface (below OS child windows);
//     root children strictly after it draw on the overlay surface (above OS child windows)
//     whenever any of them visually overlaps a native child (including drop-shadow reach).
//   - `native_input_rects`: window-pixel rectangles where an interactive overlay needs pointer
//     input over a native child (hidden when idle or when only non-interactive tooltips show).

import "../draw"

// Registers `b` as hosting a native child window for the current build. Call each frame while
// the native child is visible inside `b`.
native_child :: proc(b: ^Box) {
	if b == nil { return }
	append(&gs().native_children, b.key)
}

// Whether the last completed build registered at least one visible native child box.
has_native_children :: proc(s: ^State) -> bool {
	return s != nil && len(s.native_rects) > 0
}

// Whether the last completed build has overlay visuals that overlap a native child and must
// draw on an above-children surface (`draw_tree_overlay`).
has_native_overlay :: proc(s: ^State) -> bool {
	return s != nil && s.native_has_overlay
}

// Window-pixel rectangles of the visible native child boxes from the last completed build.
native_child_rects :: proc(s: ^State) -> []Rect {
	if s == nil { return nil }
	return s.native_rects[:]
}

// Window-pixel rectangles where interactive overlays need pointer input above a native child
// (empty when idle or when only non-interactive overlays such as tooltips are shown).
native_input_rects :: proc(s: ^State) -> []Rect {
	if s == nil { return nil }
	return s.native_input_rects[:]
}

@(private = "file")
NATIVE_DRAWN_FLAGS :: Box_Flags{
	.Draw_Background, .Draw_Border, .Draw_Text, .Draw_Shadow,
	.Draw_Side_Top, .Draw_Side_Bottom, .Draw_Side_Left, .Draw_Side_Right,
	.Row, .Plate,
}

@(private = "file")
NATIVE_INTERACTIVE_FLAGS :: Box_Flags{
	.Clickable, .Scroll_Self, .View_Scroll_X, .View_Scroll_Y, .Text_Input, .Selectable,
}

@(private = "file")
rect_empty :: proc(r: Rect) -> bool {
	return r.max.x <= r.min.x || r.max.y <= r.min.y
}

@(private = "file")
rect_intersect :: proc(a, b: Rect) -> Rect {
	return {{max(a.min.x, b.min.x), max(a.min.y, b.min.y)}, {min(a.max.x, b.max.x), min(a.max.y, b.max.y)}}
}

@(private = "file")
rects_overlap :: proc(a, b: Rect) -> bool {
	return a.min.x < b.max.x && b.min.x < a.max.x && a.min.y < b.max.y && b.min.y < a.max.y
}

// Direct child of `root` containing `b`, plus whether `b` and every ancestor up to `root` is visible.
@(private = "file")
root_child_of :: proc(root, b: ^Box) -> (host_root: ^Box, visible: bool) {
	cur := b
	for cur != nil && cur != root {
		if cur.transparency >= 1 { return nil, false }
		if cur.parent == root { host_root = cur }
		cur = cur.parent
	}
	return host_root, cur == root && host_root != nil
}

// Ordinal of `target` among `root`'s direct children (-1 if not found).
@(private = "file")
root_child_index :: proc(root, target: ^Box) -> int {
	i := 0
	for c := root.first; c != nil; c = c.next {
		if c == target { return i }
		i += 1
	}
	return -1
}

// True when any visible drawn box in `b`'s subtree (padded by `shadow_pad` when it draws a shadow)
// overlaps any rectangle in `targets`.
@(private = "file")
subtree_overlaps_any :: proc(b: ^Box, targets: []Rect, shadow_pad: f32) -> bool {
	if b == nil || b.transparency >= 1 { return false }
	if !rect_empty(b.rect) && (b.flags & NATIVE_DRAWN_FLAGS != {} || b.custom != nil) {
		r := b.rect
		if .Draw_Shadow in b.flags && shadow_pad > 0 {
			r = draw.rect_pad(r, shadow_pad)
		}
		for t in targets {
			if rects_overlap(r, t) { return true }
		}
	}
	for c := b.first; c != nil; c = c.next {
		if subtree_overlaps_any(c, targets, shadow_pad) { return true }
	}
	return false
}

// Appends intersections of outermost visible interactive boxes in `b`'s subtree with `targets`.
@(private = "file")
collect_interactive_overlaps :: proc(b: ^Box, targets: []Rect, out: ^[dynamic]Rect) {
	if b == nil || b.transparency >= 1 { return }
	if !rect_empty(b.rect) && (b.flags & NATIVE_INTERACTIVE_FLAGS != {}) {
		for t in targets {
			if inter := rect_intersect(b.rect, t); !rect_empty(inter) {
				append(out, inter)
			}
		}
		// (an interactive container already shields its whole box; children inside it need no separate rects)
		return
	}
	for c := b.first; c != nil; c = c.next {
		collect_interactive_overlaps(c, targets, out)
	}
}

// Computes `native_rects`, `native_split`, `native_has_overlay`, and `native_input_rects`
// once layout and root child raising (`menus_raise`, `toasts_build`) have finished.
@(private)
native_children_end_build :: proc(s: ^State) {
	clear(&s.native_rects)
	clear(&s.native_input_rects)
	s.native_split = nil
	s.native_has_overlay = false
	if len(s.native_children) == 0 || s.root == nil { return }

	best_ord := -1
	for k in s.native_children {
		b := s.boxes[k] or_else nil
		if b == nil || b.last_build != s.build_index || rect_empty(b.rect) { continue }
		host_root, visible := root_child_of(s.root, b)
		if !visible { continue }
		ord := root_child_index(s.root, host_root)
		if ord < 0 { continue }
		append(&s.native_rects, b.rect)
		if ord > best_ord {
			best_ord = ord
			s.native_split = host_root
		}
	}
	if len(s.native_rects) == 0 || s.native_split == nil { return }

	shadow_pad := (DROP_SHADOW_SPREAD_PX + DROP_SHADOW_OFFSET_PX + DROP_SHADOW_SOFT_PX) * s.scale
	modal_or_menu := len(s.menus) > 0 || len(s.modals_built) > 0
	if modal_or_menu {
		// (a click anywhere on a native child while a menu or modal is open must reach the owner to dismiss it)
		for nr in s.native_rects { append(&s.native_input_rects, nr) }
	}

	for c := s.native_split.next; c != nil; c = c.next {
		if c.transparency >= 1 { continue }
		if !s.native_has_overlay && subtree_overlaps_any(c, s.native_rects[:], shadow_pad) {
			s.native_has_overlay = true
		}
		if !modal_or_menu {
			collect_interactive_overlaps(c, s.native_rects[:], &s.native_input_rects)
		}
	}

	if s.auto.phase != .Off || s.wireframe || (s.inspected != 0 && box_current(s, s.boxes[s.inspected])) {
		s.native_has_overlay = true
	}
}
