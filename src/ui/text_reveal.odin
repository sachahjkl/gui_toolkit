package ui

// A cut text shows itself whole (src/md/features/text-reveal.md): its ellipsis is a target of its own (the hit test's
// reveal_key), and a click on it opens a bubble with the whole text, selectable, Copy and a close cross. It stays until
// the cross, Escape or a press outside it.

import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// What a cut text ends with.
TRUNC_ELLIPSIS :: "..."
// The target around the ellipsis's dots, on each side, in ems of its text.
REVEAL_PAD_EM :: 0.2
// The bubble's text wraps past this width, in ems.
@(private = "file") REVEAL_MAX_WIDTH_EM :: 28
// Between the ellipsis and the bubble, in ems.
@(private = "file") REVEAL_GAP_EM :: 0.3
@(private = "file") REVEAL_SALT :: 0x7e7e_a1ee_5ca1_ab1e

// The bubble open: a copy of the whole text (heap), and the ellipsis it came from (window pixels).
Text_Reveal :: struct {
	open: bool,
	text: string,
	at:   Rect,
}

// The hit test's key for the ellipsis of `b`'s cut text.
@(private)
reveal_key :: proc(b: ^Box) -> Key { return key_from_u64(b.key, REVEAL_SALT) }

// Whether a text's bubble is open, and its text (for a program's tests and its accessibility).
text_reveal_shown :: proc() -> (text: string, open: bool) {
	r := &gs().reveal
	return r.text, r.open
}

@(private)
text_reveal_close :: proc(s: ^State) {
	delete(s.reveal.text)
	s.reveal = {}
}

@(private = "file")
text_reveal_open :: proc(s: ^State, b: ^Box) {
	text_reveal_close(s)
	s.reveal = {open = true, text = strings.clone(b.text), at = b.ellipsis}
	s.anim_busy = true
}

// end_build: a click on an ellipsis opens its bubble; the open bubble is built over the page, and closes on its cross,
// on Escape or on a press outside it.
@(private)
text_reveal_build :: proc(s: ^State) {
	r := &s.reveal
	bubble_key := key_from_string(s.root.key, "###text_reveal")
	if _, on := s.reveal_owner[s.hot_key]; on && s.hot_key != 0 { s.cursor_request = .Hand }
	if r.open {
		// (a press outside it closes it; the press on an ellipsis is the click that opens one, below)
		for btn in ([]platform.Mouse_Button{.Left, .Right}) {
			if !s.pressed_any[btn] { continue }
			_, on_ellipsis := s.reveal_owner[s.pressed_key[btn]]
			bubble := s.boxes[bubble_key] or_else nil
			if !on_ellipsis && (bubble == nil || !contains(bubble.rect, s.press_pos[btn])) { text_reveal_close(s); break }
		}
	}
	if owner, ok := s.reveal_owner[s.clicked_key[.Left]]; ok {
		if b := s.boxes[owner] or_else nil; b != nil && b.ellipsis != {} { text_reveal_open(s, b) }
	}
	if !r.open { overlay_release_keys(s, .Text_Reveal); return }
	overlay_release_keys(s, .Text_Reveal)
	if key_press(.Escape) { text_reveal_close(s); return }
	copy := false
	// (Ctrl+C: the selection's, when there is one; the whole text otherwise)
	if !has_selection(s) && (key_press(.C, {.Ctrl}) || key_press(.Insert, {.Ctrl})) { copy = true }

	em := font_size()
	push_parent(s.root)
	push_tags_isolated("floating")
	push_style_copy()
	defer { pop_style(); pop_tags(); pop_parent() }
	// (under the ellipsis, its right edge on it; above it when there is no room under; inside the window)
	prev := s.boxes[bubble_key] or_else nil
	size := prev != nil ? prev.size : Vec2{em * REVEAL_MAX_WIDTH_EM * 0.5, em * 4}
	gap := em * REVEAL_GAP_EM
	pos := Vec2{r.at.max.x - size.x, r.at.max.y + gap}
	if pos.y + size.y > s.window_size.y && r.at.min.y - gap - size.y >= 0 { pos.y = r.at.min.y - gap - size.y }
	pos = clamp_popup(pos, size, s.window_size)
	next({fixed_x = pos.x, fixed_y = pos.y, width = children_sum(), height = children_sum(), axis = .Y, radius = em * 0.5})
	if prev == nil || prev.last_build + 1 != s.build_index { s.next_mod.transparency = 1; s.anim_busy = true }   // (measured on this frame, placed on the next)
	// (Clickable: a press on its edges is a press on it, not on what is under it)
	p := build_box({.Draw_Background, .Draw_Border, .Draw_Shadow, .Plate, .Clickable}, "###text_reveal")
	a11y_default(p, {role = .Dialog, name = r.text})
	push_parent(p)
	defer pop_parent()
	spacer(px(em * 0.4))
	// (one row: the text, Copy, the cross; as wide as they are)
	next({width = children_sum(), height = children_sum(), axis = .X})
	if row(id = "###reveal_row") {
		spacer(px(em * 0.75))
		w := text_width(top_style().font, top_style().font_size, r.text)
		next({width = px(math.ceil(min(w + 1, em * REVEAL_MAX_WIDTH_EM))), height = text_size()})
		paragraph(fmt.tprintf("%s###reveal_text", text_shown(r.text)))
		spacer(px(em * 0.75))
		if button("###reveal_copy", i18n.tr("Copy"), lucide.COPY, {face = .Ghost, icon_font = lucide_icons()}).clicked { copy = true }
		spacer(px(em * 0.2))
		next({width = px(math.round(em * 1.6)), height = px(math.round(em * 1.6))})
		if button("###reveal_close", icon = lucide.X, o = {icon_font = lucide_icons()}).clicked { text_reveal_close(s) }
		spacer(px(em * 0.4))
	}
	spacer(px(em * 0.4))
	if copy && s.clipboard_set != nil && r.open { s.clipboard_set(r.text) }
}
