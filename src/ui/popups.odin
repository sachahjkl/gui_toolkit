package ui

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "../font"
import "../platform"

// Popups (menus, dropdowns, tooltips) are floating boxes appended to the ROOT, so they draw above everything built so
// far and win hit testing. Their contents inherit the style of the call site.
//
// Menus. One menu is open at a time, with any depth of open submenus and nested menus (`State.menus`, outermost first).
// A menu is named by its `id`, as a widget is; the name is the window's (two menus of one id are one menu: a menu of a
// row puts the row in its id):
//
//   if sig.right_clicked { ui.menu_open("item_menu", ui.mouse_pos()) }
//   if ui.menu("item_menu") {                    // width 0: as wide as its widest item (measured on the previous frame)
//       if ui.menu_item("Copy", "Ctrl+C").clicked { ... }
//       ui.menu_separator()
//       if ui.menu_submenu("Search with") {
//           if ui.menu_item("Engine A").clicked { ... }
//       }
//       if ui.menu_item("Paste", "Ctrl+V", disabled = !can_paste).clicked { ... }
//   }
//
// Keyboard (the open menu owns every key press and typed character of the frame): Up / Down / Home / End move over the
// enabled items (wrapping), Right / Enter / Space open the selected submenu, Enter / Space choose the selected item,
// Left / Escape close the innermost submenu, Escape closes the menu, a typed letter selects the next item starting
// with it (a menu opened with `search`: what is typed searches the items, see menu_open). Pointer: hovering selects, resting on a submenu item opens it (and on another item closes it) after
// Feel.menu_hover_ms, clicking chooses; a press outside every open level closes the menu. A menu opens where asked and
// stays on screen: it flips to the other side of the point (or of the anchor rect) when it does not fit, then is
// clamped to the window. A level taller than the window is as tall as the window and scrolls (wheel, scroll bar; the
// keyboard's selection is brought into view).
//
// A nested menu is a menu opened from inside an open one (`nested`), at a point or under a rect (a row's context menu in
// a drop-down panel), over it; the menu stays open behind it:
//
//   if ui.menu("list_menu") {
//       if row_sig.right_clicked { ui.menu_open("row_menu", ui.mouse_pos(), nested = true) }
//       if ui.menu("row_menu") { if ui.menu_item("Open").clicked { ... } }
//   }
//
// It closes like a submenu: a press outside it closes only it, Escape closes it, choosing an item closes the menu.

// A menu is at least this wide; a level not measured yet is taken to be this tall.
@(private) MENU_MIN_WIDTH_EM :: 10
@(private = "file") MENU_FIRST_HEIGHT_EM :: 10
// Space above the first item and below the last, and on each side of a separator's line.
@(private = "file") MENU_PAD_EM :: 0.25
@(private = "file") MENU_SEPARATOR_GAP_EM :: 0.2
// The columns of a row, in em (menu_row builds them, menu_row_width measures them: one source for both).
@(private = "file") MENU_ROW_LEAD_EM :: 0.6    // before the icon column
@(private = "file") MENU_ICON_EM :: 1.5        // the icon or check column
@(private = "file") MENU_KEY_PAD_EM :: 0.5     // a shortcut's padding on each side, on top of its text_pad
@(private = "file") MENU_ARROW_EM :: 1.2       // a submenu's arrow
@(private = "file") MENU_ROW_TRAIL_EM :: 0.5   // after the last column
// A tooltip's size before it was measured.
@(private = "file") TOOLTIP_FIRST_WIDTH_EM :: 10
@(private = "file") TOOLTIP_FIRST_HEIGHT_EM :: 3
// Where a tooltip goes: right of and below the pointer (below its arrow); above it, this far, when it does not fit below.
@(private = "file") TOOLTIP_BELOW_EM :: Vec2{0.8, 1.4}
TOOLTIP_ABOVE_EM :: 0.5
@(private = "file") TOOLTIP_RADIUS_EM :: 0.4
// tooltip_text wraps its lines past this width.
TOOLTIP_MAX_WIDTH_EM :: 24

// A small weak title above a group of items (not an item: the keyboard skips it).
menu_heading :: proc(text: string) {
	lv, _ := menu_current()
	em := font_size()
	w := lv != nil ? lv.eff_width : em * MENU_MIN_WIDTH_EM
	if lv != nil { lv.width = max(lv.width, text_width(top_style().font, em * 0.9, text) + em * 1.4) }
	spacer(px(em * 0.2))
	if tags("weak") {
		next({width = px(w), height = px(dense(em * 1.5)), font_size = em * 0.9, text_pad = em * 0.7})
		build_box({.Draw_Text}, fmt.tprintf("%s###mh_%s", text, hash_part(text)))
	}
}

Menu_Item_Info :: struct {
	key:     Key,      // the row's box (the next frame knows which item the pointer is on before it builds any)
	enabled: bool,
	submenu: bool,
	first:   rune,     // first letter of the label, lower case (type-ahead)
}

Menu_Level :: struct {
	key:          Key,
	anchor:       Key,       // level 0: the widget that opened it (pressing it again is not a press "outside")
	pos:          Vec2,      // where it was asked to open (top-left corner)
	around:       Rect,      // not empty: open next to this rect (level 0, nested: below, else above; submenus: right, else left)
	nested:       bool,      // opened with menu_open's `nested`: placed like level 0, not closed by resting on its menu's items
	open_build:   u64,
	built_build:  u64,
	sel:          int,       // selected item (-1: none)
	items, prev:  [dynamic]Menu_Item_Info,   // this frame's items / last frame's (keyboard navigation reads those)
	width, prev_width: f32,  // natural width of the widest item: measured this frame / last frame
	eff_width:    f32,       // width of the rows this frame
	activate:     bool,      // keyboard: choose the selected item when it is built
	open_sub:     bool,      // keyboard: open the selected submenu
	from_keyboard: bool,     // opened from the keyboard: the first item starts selected (until its rows are known)
	panel:        Key,
	hover_item:   int,       // item under the pointer and since when (submenus open / close after a delay)
	hover_since:  f64,
	scrolls:      bool,      // its content is taller than the window: as tall as the window, scrolled
	reveal:       bool,      // the keyboard moved the selection: scroll its row into view
	search:       bool,      // typing searches its items (menu_open's `search`)
	query:        Line_Edit,   // what was typed (search): a field's text, edited by a field's keys (line_edit_key)
	                           // (its edited_ms: when it changed or the menu opened: the caret solid, then blinking)
	pick_first:   bool,      // the query changed: the first item that matches is selected when it is built
	// a menu that searches stays where it was first laid out and never narrows: what is typed takes items away, and the
	// menu that flipped or moved, narrower at each letter, ran from under the pointer
	held:         bool,
	held_pos:     Vec2,
	held_width:   f32,
}

// What was typed in a menu that searches ("" none).
@(private)
menu_query :: proc(lv: ^Menu_Level) -> string { return line_edit_string(&lv.query) }

// A key in a menu that searches: a field's key (line_edit_key: the caret, the selection, Ctrl+A, a word taken back, a paste)
// goes to its query; the menu keeps what moves in its items and what chooses or closes. While nothing is typed, Left,
// Right, Home and End are the menu's (a submenu, the first and the last item). A space is typed, not a choice. True:
// the key was the query's.
@(private = "file")
menu_query_key :: proc(lv: ^Menu_Level, e: platform.Event) -> bool {
	#partial switch e.key {
	case .Up, .Down, .Page_Up, .Page_Down, .Return, .Escape, .Tab: return false
	case .Space: return e.mods == {}
	case .Left, .Right, .Home, .End: if len(lv.query.buf) == 0 { return false }
	}
	before := strings.clone(menu_query(lv), context.temp_allocator)
	c0, m0 := lv.query.cursor, lv.query.mark
	if !line_edit_key(&lv.query, lv.key, e.key, e.mods) { return false }
	if menu_query(lv) != before { lv.pick_first, lv.sel = true, -1 }
	if menu_query(lv) != before || lv.query.cursor != c0 || lv.query.mark != m0 { lv.query.edited_ms = now_ms() }
	return true
}

// Whether a row of the level that is being built is shown: no search, or its label has the query's letters in order.
@(private = "file")
menu_matches :: proc(lv: ^Menu_Level, text: string) -> bool {
	q := menu_query(lv)
	if q == "" { return true }
	_, _, ok := fuzzy_score(q, display_part(text))
	return ok
}

// Where a menu opens: its top-left corner at a point (window pixels), or below a rect (above it when there is no room
// below), e.g. under the button that opens it.
Menu_At :: union { Vec2, Rect }

// Opens the menu `id` at `at`, replacing any open menu. `anchor`: the box that opens the menu (dropdown button, menu bar
// entry): pressing it again is not a press "outside", so the widget can toggle the menu itself. `from_keyboard`: the
// first enabled item starts selected. `search` (on: every menu can be filtered): what is typed searches the items (fuzzy,
// File Pilot's): a field at the top shows it (a magnifier, a caret), the items that do not match go, a submenu's items
// come up into the menu, the first match is selected (Enter chooses it); off: a typed letter selects the next item that
// starts with it (a menu of a few fixed choices). `nested`: called in the block of an open menu, the menu opens over it,
// in place of any submenu or nested menu that menu had open, and the menu stays open behind it (it does nothing outside a
// menu's block).
menu_open :: proc(id: string, at: Menu_At, anchor: Key = 0, from_keyboard := false, search := true, nested := false) {
	pos: Vec2
	around: Rect
	switch v in at {
	case Vec2: pos = v
	case Rect: pos, around = {v.min.x, v.max.y}, v
	}
	lv := Menu_Level{key = menu_key(id), pos = pos, around = around, nested = nested, open_build = gs().build_index, sel = -1, hover_item = -1, from_keyboard = from_keyboard, search = search, query = {edited_ms = now_ms()}}
	if nested { menu_nest(lv) } else { lv.anchor = anchor; menu_push(lv) }
}

// The key of the menu `id`: the window's, not that of where it is built.
@(private)
menu_key :: proc(id: string) -> Key { return key_from_string(0, id) }

// In the block of an open menu the rows still to come are that menu's: this one opens when the block ends (menu_end).
@(private = "file")
menu_push :: proc(lv: Menu_Level) {
	s := gs()
	if len(s.menu_build) > 0 { s.menu_next = lv; return }
	menu_pop_to(0)
	s.menu_close_pending = false   // (the menu asked to close is gone: this one is new)
	append(&s.menus, lv)
}

// A nested menu goes over the level being built.
@(private = "file")
menu_nest :: proc(lv: Menu_Level) {
	s := gs()
	_, depth := menu_current()
	if depth < 0 { return }
	menu_pop_to(depth + 1)
	append(&s.menus, lv)
}

// Closes the open menu, every level of it.
menu_close :: proc() { menu_pop_to(0) }

// Whether the menu `id` is open, at any level (a nested menu too).
menu_is_open :: proc(id: string) -> bool {
	key := menu_key(id)
	for lv in gs().menus { if lv.key == key { return true } }
	return false
}

// Whether any menu is open.
menu_any_open :: proc() -> bool { return len(gs().menus) > 0 }

// Is `p` (window pixels) on a level of the open menu (a submenu, a nested menu, a drop-down's list), as the last build
// laid it out? The wheel there is the menu's (`wheel_consumed`): an app that routes the wheel to its own content (a
// page) before it builds the interface gives it nothing.
menu_at :: proc(p: Vec2) -> bool {
	s := gs()
	for lv in s.menus {
		if b := s.boxes[lv.panel]; b != nil && contains(b.rect, p) { return true }
	}
	return false
}

// Selects item `index` of the open menu (e.g. a dropdown's current value, so the keyboard starts from it).
menu_select :: proc(index: int) { if len(gs().menus) > 0 { gs().menus[0].sel = index; gs().menus[0].reveal = true } }

// Number of open levels (1 = the menu, 2 = one submenu open...).
menu_depth :: proc() -> int { return len(gs().menus) }

// Where level `depth` of the open menu was laid out (last build), and its selected item (-1: none).
menu_rect :: proc(depth: int) -> (r: Rect, sel: int, ok: bool) {
	s := gs()
	if depth < 0 || depth >= len(s.menus) { return {}, -1, false }
	lv := &s.menus[depth]
	b := s.boxes[lv.panel]
	if b == nil { return {}, lv.sel, false }
	return b.rect, lv.sel, true
}

// Where item `idx` of level `depth` was laid out (last build): partly or wholly out of `menu_rect` in a level that scrolls.
menu_item_rect :: proc(depth, idx: int) -> (r: Rect, ok: bool) {
	s := gs()
	if depth < 0 || depth >= len(s.menus) || idx < 0 || idx >= len(s.menus[depth].items) { return }
	b := s.boxes[s.menus[depth].items[idx].key]
	if b == nil { return }
	return b.rect, true
}

@(private)
menu_pop_to :: proc(n: int) {
	s := gs()
	for len(s.menus) > n {
		lv := pop(&s.menus)
		delete(lv.items)
		delete(lv.prev)
		line_edit_destroy(&lv.query)
	}
}

@(private)
menus_destroy :: proc(s: ^State) {
	for &lv in s.menus { delete(lv.items); delete(lv.prev); line_edit_destroy(&lv.query) }
	delete(s.menus)
	delete(s.menu_build)
	delete(s.menu_keys.list)
	delete(s.menu_keys.consumed)
}

// While a menu is open it owns the keyboard: key presses and typed text of the frame move to its own queue before any
// widget is built (begin_build).
// Key presses and typed characters stay in the order they came (Text events in the same queue).
@(private)
menu_capture_keys :: proc(s: ^State, events: []platform.Event) {
	clear(&s.menu_keys.list)
	clear(&s.menu_keys.consumed)
	if len(s.menus) == 0 { return }
	// (a field of an open menu has the focus, a panel's search: its keys are its own; the menu took them all, and what
	// was typed in the field went nowhere)
	if f := s.boxes[s.focus_key] or_else nil; f != nil && .Text_Input in f.flags && menu_holds(s, s.focus_key) { return }
	at := 0   // (the keys process_events kept, in their order: what took one of them, Ctrl+zoom or autoscroll's Escape, had it)
	for e in events {
		if e.kind == .Key_Press {
			if at >= len(s.events.list) || s.events.list[at].key != e.key || s.events.list[at].mods != e.mods { continue }
			at += 1
			if s.events.consumed[at - 1] { continue }
		} else if e.kind != .Text { continue }
		append(&s.menu_keys.list, e)
		append(&s.menu_keys.consumed, false)
	}
	clear(&s.events.list)
	clear(&s.events.consumed)
	clear(&s.typed)
}

// The open menus go over whatever the root holds (end_build, before layout): a level is built where the app builds the
// menu (a toolbar's button), and what the app builds at the root after it (notices, a panel, a dialog) would be drawn
// over it and take its pointer. Levels keep their order (a submenu over its menu).
@(private)
menus_raise :: proc(s: ^State) {
	for lv in s.menus { root_raise(s, s.boxes[lv.panel]) }
	// (then the tooltip, over the menus: a tooltip of a menu's button, or of a panel opened as a menu, showed under it)
	root_raise(s, s.boxes[key_from_string(s.root.key, "###tooltip")])
}

// A box of the root, built this frame, goes last among the root's children: drawn over the others, first to take the pointer.
@(private = "file")
root_raise :: proc(s: ^State, b: ^Box) {
	if b == nil || b.last_build != s.build_index || b.parent != s.root || s.root.last == b { return }
	p := b.parent
	if b.prev != nil { b.prev.next = b.next } else { p.first = b.next }
	if b.next != nil { b.next.prev = b.prev } else { p.last = b.prev }
	b.prev, b.next = p.last, nil
	if p.last != nil { p.last.next = b } else { p.first = b }
	p.last = b
}

// Levels the app stopped building close (end_build).
@(private)
menu_prune :: proc(s: ^State) {
	for i in 0 ..< len(s.menus) {
		lv := &s.menus[i]
		if lv.built_build != s.build_index && lv.open_build < s.build_index { menu_pop_to(i); return }
	}
}



// Box `key` (a scroll bar: its box) is on a level of the open menu.
@(private)
menu_holds :: proc(s: ^State, key: Key) -> bool {
	if len(s.menus) == 0 || key == 0 { return false }
	b := s.boxes[s.sb_owner[key] or_else key] or_else nil
	if b == nil { return false }
	for lv in s.menus {
		if p := s.boxes[lv.panel]; p != nil && is_descendant(b, p) { return true }
	}
	return false
}

@(private)
is_descendant :: proc(b, ancestor: ^Box) -> bool {
	for p := b; p != nil; p = p.parent { if p == ancestor { return true } }
	return false
}

@(private)
clamp_popup :: proc(pos: Vec2, size, window: Vec2) -> Vec2 {
	return {clamp(pos.x, 0, max(0, window.x - size.x)), clamp(pos.y, 0, max(0, window.y - size.y))}
}

// Where a level of `size` goes: next to its point or rect, flipped when it does not fit, then clamped to the window.
@(private)
menu_place :: proc(lv: ^Menu_Level, depth: int, size, window: Vec2, em: f32) -> Vec2 {
	r := lv.around
	pos := lv.pos
	if r.max.x > r.min.x || r.max.y > r.min.y {
		if depth == 0 || lv.nested {
			gap := em * 0.25
			pos = {r.min.x, r.max.y + gap}
			if pos.y + size.y > window.y && r.min.y - gap - size.y >= 0 { pos.y = r.min.y - gap - size.y }
		} else {
			pad := dense(em * MENU_PAD_EM)   // the first row lines up with the item that opened the submenu
			pos = {r.max.x - 2, r.min.y - pad}
			if pos.x + size.x > window.x && r.min.x - size.x + 2 >= 0 { pos.x = r.min.x - size.x + 2 }
		}
	} else {
		if pos.x + size.x > window.x && pos.x - size.x >= 0 { pos.x -= size.x }
		if pos.y + size.y > window.y && pos.y - size.y >= 0 { pos.y -= size.y }
	}
	return clamp_popup(pos, size, window)
}

// Next enabled item from `from` in direction `dir` (wrapping); -1 when there is none.
@(private)
menu_step :: proc(items: []Menu_Item_Info, from, dir: int) -> int {
	n := len(items)
	if n == 0 { return -1 }
	i := from
	for _ in 0 ..< n {
		i += dir
		if i < 0 { i = n - 1 } else if i >= n { i = 0 }
		if items[i].enabled { return i }
	}
	return -1
}

// `if menu(id, width) { menu_item(...) ... }`: builds the menu `id` while it is open (a nested menu: in the block of the
// menu that opened it). `width` 0 = as wide as the widest item; a width given is a minimum. Closes on Escape, on a press
// outside every open level (a nested menu: outside it and the levels it opened, which closes only it), or when an item is
// chosen.
@(require_results, deferred_none = menu_end)
menu :: proc(id: string, width: f32 = 0) -> bool {
	s := gs()
	key := menu_key(id)
	_, depth := menu_current()
	if d := depth + 1; depth >= 0 && d < len(s.menus) && s.menus[d].key == key && s.menus[d].nested {
		if s.build_index > s.menus[d].open_build && menu_pressed_outside(s, d, 0) {
			menu_pop_to(d)
			next_drop(s)
			append(&s.popup_stack, false)
			return false
		}
		return menu_level_begin(d, width)
	}
	if len(s.menus) == 0 || s.menus[0].key != key || s.menus[0].nested {
		next_drop(s)
		append(&s.popup_stack, false)
		return false
	}
	// a press outside every open level closes the whole menu
	if s.build_index > s.menus[0].open_build && menu_pressed_outside(s, 0, s.menus[0].anchor) {
		menu_close()
		next_drop(s)
		append(&s.popup_stack, false)
		return false
	}
	return menu_level_begin(0, width)
}

// A press of this frame (any button) landed outside the open levels from `from` on, and not on `anchor`.
@(private = "file")
menu_pressed_outside :: proc(s: ^State, from: int, anchor: Key) -> bool {
	hit: Key
	any_press := false
	for b in platform.Mouse_Button {
		if s.pressed_any[b] { hit, any_press = s.pressed_key[b], true; break }
	}
	if !any_press { return false }
	if hit != 0 && hit == anchor { return false }
	if owner, ok := s.sb_owner[hit]; ok { hit = owner }   // a level's scroll bar is part of it
	hb := s.boxes[hit] if hit != 0 else nil
	if hb == nil { return true }
	for lv in s.menus[from:] {
		if p := s.boxes[lv.panel]; p != nil && is_descendant(hb, p) { return false }
	}
	return true
}

@(private)
menu_level_begin :: proc(depth: int, width: f32) -> bool {
	s := gs()
	lv := &s.menus[depth]
	lv.prev, lv.items = lv.items, lv.prev
	clear(&lv.items)
	lv.prev_width, lv.width = lv.width, 0
	lv.built_build = s.build_index
	lv.activate, lv.open_sub = false, false

	// The pointer's item is the selected one in the frame that sees the pointer there: the rows are built in order, so
	// a row built before the hovered one would otherwise still be drawn selected (and the hovered one not yet) until the
	// next frame.
	if s.hot_key != 0 && (s.mouse_moved || lv.sel < 0) {
		for it, i in lv.prev { if it.enabled && it.key == s.hot_key { lv.sel = i; break } }
	}
	// a disabled row gets no signal: a pointer that moved onto one leaves nothing selected, not the row it came from
	if s.mouse_moved {
		for it in lv.prev {
			if it.enabled || it.key == 0 { continue }
			if b := s.boxes[it.key]; b != nil && contains(b.rect, s.mouse) { lv.sel = -1; break }
		}
	}

	if depth == len(s.menus) - 1 {
		// the innermost level takes the keys in the order they came, until one hands over (opens a submenu, chooses)
		items := lv.prev[:]
		// (once its rows are known: from then on the keys and the pointer say what is selected, nothing too)
		if lv.from_keyboard && len(items) > 0 {
			if lv.sel < 0 { lv.sel = menu_step(items, -1, 1) }
			lv.from_keyboard = false
		}
		// (a paste in the search, asked in an earlier build: its text came)
		if lv.search && line_edit_paste_answer(&lv.query, lv.key) {
			lv.pick_first, lv.sel = true, -1
			lv.query.edited_ms = now_ms()
		}
		keys: for e, i in s.menu_keys.list {
			if s.menu_keys.consumed[i] { continue }
			s.menu_keys.consumed[i] = true
			valid := lv.sel >= 0 && lv.sel < len(items) && items[lv.sel].enabled
			if lv.search && e.kind == .Text {
				if e.text >= ' ' {
					buf, n := utf8.encode_rune(e.text)
					line_edit_checkpoint(&lv.query, .Insert)
					insert_text(&lv.query, string(buf[:n]))
					lv.pick_first, lv.sel = true, -1
					lv.query.edited_ms = now_ms()
				}
				continue
			}
			if lv.search && e.kind != .Text && menu_query_key(lv, e) { continue }
			if e.kind == .Text {
				want := unicode.to_lower(e.text)
				for k in 1 ..= len(items) {
					j := (lv.sel + k) %% max(len(items), 1)
					if items[j].enabled && items[j].first == want { lv.sel = j; lv.reveal = true; break }
				}
				continue
			}
			if e.mods - {.Shift} != {} { continue }
			#partial switch e.key { case .Down, .Up, .Home, .End, .Page_Up, .Page_Down: lv.reveal = true }
			#partial switch e.key {
			case .Escape, .Left:
				if e.key == .Left && depth == 0 { continue }
				menu_pop_to(depth)
				next_drop(s)
				append(&s.popup_stack, false)
				return false
			case .Down: lv.sel = menu_step(items, lv.sel, 1)
			case .Up:   lv.sel = menu_step(items, lv.sel < 0 ? len(items) : lv.sel, -1)
			case .Home, .Page_Up: lv.sel = menu_step(items, -1, 1)
			case .End, .Page_Down: lv.sel = menu_step(items, len(items), -1)
			case .Right:
				if valid && items[lv.sel].submenu { lv.open_sub = true; break keys }
			case .Return, .Space:
				if valid {
					if items[lv.sel].submenu { lv.open_sub = true } else { lv.activate = true }
					break keys
				}
			}
		}
	}

	// (the rows are built in the window's style, below: the menu's sizes are in its em, not the caller's)
	em := s.style_stack[0].font_size
	id := fmt.tprintf("###menu_%d", u64(lv.key))
	panel := s.boxes[key_from_string(s.root.key, id)]
	first := panel == nil
	// (its content's height: the last layout's; taller than the window, the rows leave room for the scroll bar)
	lv.scrolls = !first && panel.view_bounds.y > s.window_size.y
	// As wide as its widest row (measured on the last frame), `width` at least: a width given is a minimum, never a cut.
	w := max(lv.prev_width, width, em * MENU_MIN_WIDTH_EM) + menu_bar_room(lv, em)
	if lv.search {
		w = max(w, lv.held_width)
		lv.held_width = w
	}
	// (placed with the width it is built with this frame, its frame added (what the last frame's panel had over the width
	// it was built with): the last frame's was narrower when its rows learned their width only then (lv.prev_width), and a
	// menu at the window's right edge showed past it, then jumped back)
	frame_w: f32 = first ? 2 * max(1, math.round(s.scale)) : max(0, panel.size.x - lv.eff_width)
	// (wider than the window: as wide as the window, its rows cut, each showing its whole label as a tooltip)
	w = max(0, min(w, s.window_size.x - frame_w))
	lv.eff_width = w
	size := first ? Vec2{w, em * MENU_FIRST_HEIGHT_EM} : Vec2{max(panel.size.x, w + frame_w), min(panel.view_bounds.y, s.window_size.y)}
	pos := menu_place(lv, depth, size, s.window_size, em)
	// (a menu that searches: its corner where its first measured frame put it, held in the window)
	if lv.search && !first {
		if !lv.held { lv.held, lv.held_pos = true, pos }
		pos = clamp_popup(lv.held_pos, size, s.window_size)
	}
	// (wherever it is built, a menu is a menu: its own tags and the window's style, not those of the field or the dialog
	// that opens it)
	push_parent(s.root)
	push_tags_isolated("floating")
	append(&s.style_stack, s.style_stack[0])
	set_next_axis(.Y)
	s.next_mod.fixed_x = pos.x
	s.next_mod.fixed_y = pos.y
	s.next_mod.width = children_sum()
	s.next_mod.height = lv.scrolls ? px(s.window_size.y) : children_sum()
	s.next_mod.radius = em * 0.5
	if first { s.next_mod.transparency = 1; s.anim_busy = true }   // measured on this frame, shown on the next
	p := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Plate}, id)
	p.cursor = .Arrow
	if !lv.scrolls { view_jump(p, 0) }
	a11y_default(p, {role = .Menu, orientation = .Y})
	lv.panel = p.key
	_ = signal(p)
	push_parent(p)
	append(&s.popup_stack, true)
	append(&s.menu_build, depth)
	// (a menu that searches has its field at its very top, from edge to edge)
	if lv.search {
		next({width = px(w)})
		search_band("menu_search", &lv.query, {owner_keys = true})
	}
	spacer(px(em * MENU_PAD_EM))
	return true
}

// The room a level that scrolls leaves its scroll bar at the end of its rows (0 for one that fits).
@(private = "file")
menu_bar_room :: proc(lv: ^Menu_Level, em: f32) -> f32 {
	if !lv.scrolls { return 0 }
	w, m := scrollbar_size(em)
	return w + 2 * m
}

// Scrolls a level that scrolls so that its row `b` (laid out in the last frame) is in view.
@(private = "file")
menu_reveal :: proc(lv: ^Menu_Level, b: ^Box) {
	s := gs()
	panel := s.boxes[lv.panel]
	if !lv.scrolls || panel == nil || b.first_build == s.build_index { return }
	top: f32
	for q := b; q != nil && q != panel; q = q.parent { top += q.rel_pos.y }
	if view_reveal(panel, top, top + b.size.y) { scrollbar_reveal(panel) }
	view_jump(panel, panel.view_target.y)   // (a step of the keyboard jumps, as the system's menus do)
	lv.reveal = false
}

@(private)
push_style_copy :: proc() { append(&gs().style_stack, top_style()^) }

@(private)
menu_end :: proc() {
	s := gs()
	if len(s.popup_stack) > 0 && s.popup_stack[len(s.popup_stack) - 1] && len(s.menu_build) > 0 {
		spacer(px(font_size() * MENU_PAD_EM))
		pop(&s.menu_build)
		if len(s.menu_build) == 0 && s.menu_close_pending {
			s.menu_close_pending = false
			menu_close()
		}
		if lv, opens := s.menu_next.?; opens && len(s.menu_build) == 0 {
			s.menu_next = nil
			s.menu_close_pending = false
			menu_close()
			append(&s.menus, lv)
		}
	}
	popup_end()
}

// The end of a floating box of the root (a menu's level, a tooltip, a dialog, a popover) that its start opened.
@(private)
popup_end :: proc() {
	s := gs()
	if pop(&s.popup_stack) {
		pop_parent()     // panel
		pop(&s.style_stack)
		pop_tags_isolated()
		pop_parent()     // root
	}
}

// The level whose items are being built (nil outside a menu).
@(private)
menu_current :: proc() -> (^Menu_Level, int) {
	s := gs()
	if len(s.menu_build) == 0 { return nil, -1 }
	d := s.menu_build[len(s.menu_build) - 1]
	if d >= len(s.menus) { return nil, -1 }
	return &s.menus[d], d
}

@(private)
first_letter :: proc(label: string) -> rune {
	for r in label { if unicode.is_letter(r) || unicode.is_digit(r) { return unicode.to_lower(r) } }
	return 0
}

// The width a row of `st` needs to show `label`, `shortcut` and a submenu's arrow whole: the columns menu_row lays out, in
// the same numbers (its border, the lead, the icon column, the label and its padding, the shortcut's box as the layout
// sizes it, the arrow, the trail). The room of a scroll bar is not in it (menu_bar_room).
@(private = "file")
menu_row_width :: proc(st: ^Style, label, shortcut: string, submenu: bool) -> f32 {
	em, pad := st.font_size, st.text_pad
	w := 2 * max(1, math.round(gs().scale))   // (the row is always bordered: border_inset)
	w += em * (MENU_ROW_LEAD_EM + MENU_ICON_EM + MENU_ROW_TRAIL_EM)
	w += text_width(st.font, em, label) + 2 * pad
	// (the layout ceils a text box: layout_standalone)
	if shortcut != "" { w += math.ceil(text_width(st.font, em, shortcut) + 2 * (pad + em * MENU_KEY_PAD_EM)) }
	if submenu && widget_icons() != 0 { w += em * MENU_ARROW_EM }
	return math.ceil(w)
}

// One row: check mark or icon, label, shortcut (weak), submenu arrow. Returns the row's signal.
@(private)
menu_row :: proc(lv: ^Menu_Level, idx: int, text, shortcut, icon: string, checked, enabled, submenu, highlight: bool, icon_font: font.Font_Id = 0) -> Signal {
	s := gs()
	em := font_size()
	label := display_part(text)
	natural := menu_row_width(top_style(), label, shortcut, submenu)
	lv.width = max(lv.width, natural)
	width := lv.eff_width
	sig: Signal
	if disabled(!enabled) {
		if tags("menu_item") {
			if highlight { push_tags("selected") }
			set_next_axis(.X, .Center)
			s.next_mod.width = px(width)
			s.next_mod.height = px(dense(em * s.feel.menu_item_em))
			s.next_mod.radius = 0   // (a row of a list: square, as a list's and a table's)
			if !highlight { s.next_mod.border = Color{} }   // always bordered (layout space), visible only when selected
			b := build_box({.Clickable, .Draw_Hot_Effects, .Draw_Background, .Draw_Border}, fmt.tprintf("###mi_%d_%s", idx, hash_part(text)))
			if highlight { pop_tags() }
			if idx < len(lv.items) { lv.items[idx].key = b.key }
			if idx == lv.sel && lv.reveal { menu_reveal(lv, b) }
			sig = signal(b)
			if checked {
				a11y_default(b, {role = .Menu_Item_Check_Box, name = label, shortcut = shortcut, toggled = .True, position = idx + 1})
			} else {
				info := A11y_Info{role = .Menu_Item, name = label, shortcut = shortcut, position = idx + 1}
				if submenu { info.popup = .Menu; info.expanded = false }
				a11y_default(b, info)
			}
			if parent(b) {
				spacer(px(em * MENU_ROW_LEAD_EM))
				next({width = px(em * MENU_ICON_EM), height = pct(1)})
				if checked && widget_icons() != 0 {
					if style({font = widget_icons(), text_align = .Center}) { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###chk", ICON_CHECK)) }
				} else if face := icon_font != 0 ? icon_font : (s.menu_icon_font != 0 ? s.menu_icon_font : s.icon_font); icon != "" && face != 0 {
					if style({font = face, text_align = .Center}) { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", icon)) }
				} else {
					build_box({}, "###nochk")
				}
				// (a menu that searches: what was typed lit in the label)
				if q := menu_query(lv); q != "" {
					_, ranges, _ := fuzzy_score(q, label)
					next({width = fill()})
					matched_label("###lbl", label, ranges)
				} else {
					next({width = fill(), height = pct(1)})
					build_box({.Draw_Text}, fmt.tprintf("%s###lbl", label))
				}
				if shortcut != "" {
					if tags("weak") {
						next({width = text_size(em * MENU_KEY_PAD_EM), height = pct(1)})
						build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###key", shortcut))
					}
				}
				if submenu && widget_icons() != 0 {
					next({width = px(em * MENU_ARROW_EM), height = pct(1), font = widget_icons(), text_align = .Center})
					if tags("weak") { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf(">###ico%d", parent_box().child_count)) }
				}
				spacer(px(em * MENU_ROW_TRAIL_EM + menu_bar_room(lv, em)))
			}
		}
	}
	// (a row narrower than its content: the window cut the menu; its whole label in a tooltip)
	if sig.box != nil && natural + menu_bar_room(lv, em) > width + 0.5 && hovered_for(sig) {
		if tooltip() { tooltip_text(label) }
	}
	if sig.hovering {
		if s.mouse_moved || lv.sel < 0 { lv.sel = idx }
		if lv.hover_item != idx { lv.hover_item = idx; lv.hover_since = s.time_ms }
	} else if lv.hover_item == idx {
		lv.hover_item = -1
	} else if !enabled && s.mouse_moved && sig.box != nil && contains(sig.box.rect, s.mouse) {
		// the pointer moved onto a disabled row (it gets no signal): the row it left must not stay selected
		lv.sel = -1
	}
	return sig
}

// Box `b`, a line of `text`, was laid out narrower than its text (last layout): it shows "...". For a list whose width
// the person chose (the palette): its cut lines show their whole text as a tooltip.
@(private)
label_cut :: proc(b: ^Box, text: string) -> bool {
	if b == nil || b.first_build == gs().build_index { return false }
	return text_width(b.font, b.font_size, text) + 2 * b.text_pad > (b.rect.max.x - b.rect.min.x) + 0.5
}

// The pointer has rested on item `idx` of `lv` for Feel.menu_hover_ms (asks for a timed wake while waiting).
@(private)
menu_hover_due :: proc(lv: ^Menu_Level, idx: int) -> bool {
	s := gs()
	if lv.hover_item != idx { return false }
	waited := s.time_ms - lv.hover_since
	hover := f64(s.feel.menu_hover_ms)
	if waited >= hover { return true }
	wake_within(s, max(1, int(hover - waited) + WAKE_MARGIN_MS))
	return false
}

// One item of the menu being built. Tags used: "menu_item" (+ "selected" on the selected one). Closes the whole menu
// when chosen (click, or Enter / Space on the selected item). A disabled item (`disabled`, or inside a `disabled`
// scope) is shown muted and skipped by the keyboard. `icon` is a character of `icon_font` (0: State.icon_font, the
// program's icons; a menu of the toolkit's own gives lucide_icons()).
menu_item :: proc(text: string, shortcut := "", checked := false, icon := "", disabled := false, keep_open := false, icon_font: font.Font_Id = 0) -> Signal {
	s := gs()
	lv, depth := menu_current()
	if lv == nil {
		// outside a menu: a plain row (so menu bodies can be factored into procs and reused elsewhere)
		return button(text, display_part(text))
	}
	if !menu_matches(lv, text) { return {} }
	en := !disabled && s.disabled_depth == 0
	idx := len(lv.items)
	append(&lv.items, Menu_Item_Info{enabled = en, first = first_letter(display_part(text))})
	if lv.pick_first && en { lv.sel, lv.pick_first, lv.reveal = idx, false, true }
	sig := menu_row(lv, idx, text, shortcut, icon, checked, en, false, idx == lv.sel, icon_font)
	// resting on another item than the open submenu's closes that submenu (a nested menu stays: a press closes it)
	if sig.hovering && len(s.menus) > depth + 1 && !s.menus[depth + 1].nested && menu_hover_due(lv, idx) { menu_pop_to(depth + 1) }
	clicked := en && (sig.clicked || (idx == lv.sel && lv.activate))
	sig.clicked = clicked
	// (closed when the menu's block ends: the items after this one are still part of the menu until then, and a menu
	// the caller opens in answer to the click is not the one that closes)
	if clicked && !keep_open { s.menu_close_pending = true }
	return sig
}

// A line between groups of items (not an item: the keyboard skips it).
menu_separator :: proc() {
	lv, _ := menu_current()
	if lv != nil && menu_query(lv) != "" { return }   // (a search shows the matches alone)
	em := font_size()
	w := lv != nil ? lv.eff_width : em * MENU_MIN_WIDTH_EM
	spacer(px(em * MENU_SEPARATOR_GAP_EM))
	hline(px(w))
	spacer(px(em * MENU_SEPARATOR_GAP_EM))
}

// `if menu_submenu("Label") { menu_item(...) }`: an item that opens a nested menu (to its right, or its left when there
// is no room). Opens on click, after the pointer rests on it, or with Right / Enter / Space; the block builds the
// submenu's items while it is open.
@(require_results, deferred_none = menu_end)
menu_submenu :: proc(text: string, icon := "", disabled := false) -> bool {
	s := gs()
	lv, depth := menu_current()
	if lv == nil { append(&s.popup_stack, false); return false }
	// (a search: the submenu's items come up into this level, the submenu itself is not shown)
	if menu_query(lv) != "" {
		append(&s.popup_stack, false)
		return !disabled && s.disabled_depth == 0
	}
	en := !disabled && s.disabled_depth == 0
	idx := len(lv.items)
	append(&lv.items, Menu_Item_Info{enabled = en, submenu = true, first = first_letter(display_part(text))})
	sub_key := key_from_string(lv.key, hash_part(text))
	open := len(s.menus) > depth + 1 && s.menus[depth + 1].key == sub_key
	sig := menu_row(lv, idx, text, "", icon, false, en, true, idx == lv.sel || open)
	want, kb := false, false
	if en {
		if sig.clicked { want = true }
		if idx == lv.sel && lv.open_sub { want, kb = true, true; lv.open_sub = false }
		if sig.hovering && !open && menu_hover_due(lv, idx) { want = true }
	}
	if want && !open {
		lv.sel = idx
		rect := sig.box.rect
		menu_pop_to(depth + 1)
		append(&s.menus, Menu_Level{key = sub_key, around = rect, pos = rect.min, open_build = s.build_index, sel = -1, hover_item = -1, from_keyboard = kb})
		open = true
	}
	if sig.box != nil && sig.box.a11y != nil { sig.box.a11y.expanded = open }
	if !open {
		append(&s.popup_stack, false)
		return false
	}
	return menu_level_begin(depth + 1, 0)
}

// True once the pointer has rested on the box for Feel.tooltip_delay_ms: its tooltip shows (asks the app loop for a timed
// wake while waiting). One delay for every tooltip, so that the user's setting reaches them all.
hovered_for :: proc(sig: Signal) -> bool {
	s := gs()
	if !sig.hovering { return false }
	delay := f64(s.feel.tooltip_delay_ms)
	waited := s.time_ms - s.hover_since_ms
	if waited >= delay { return true }
	wake_within(s, max(1, int(delay - waited) + WAKE_MARGIN_MS))
	return false
}

// `if tooltip() { tooltip_text("...") }` near the pointer: below it, above it when it does not fit, inside the window.
// Not clickable, so it never blocks the box below. It is as large as what is built in it: a size relative to the
// window (the app's style may fill) is the content's own there.
@(require_results, deferred_none = tooltip_end)
tooltip :: proc() -> bool {
	s := gs()
	em := font_size()
	size := tooltip_last_size(em)
	pos := s.mouse + TOOLTIP_BELOW_EM * em
	if pos.y + size.y > s.window_size.y && s.mouse.y - TOOLTIP_ABOVE_EM * em - size.y >= 0 { pos.y = s.mouse.y - TOOLTIP_ABOVE_EM * em - size.y }
	tooltip_open(clamp_popup(pos, size, s.window_size), em)
	return true
}

// The text of a tooltip: as wide as it is, up to TOOLTIP_MAX_WIDTH_EM; its lines wrap past that.
tooltip_text :: proc(text: string) -> Signal {
	st := top_style()
	w := font.text_width(gs().fonts, st.font, st.font_size, text) + 2 * st.text_pad
	next({width = px(math.ceil(min(w, font_size() * TOOLTIP_MAX_WIDTH_EM))), height = text_size()})
	return signal(build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, fmt.tprintf("%s###tooltip_text", text)))
}

// `tooltip` beside the pointer instead of below it: to its right (to its left when there is no room), centered on it. For
// the rows of a list or a table, where a tooltip below the pointer would cover the rows under the one it is about.
@(require_results, deferred_none = tooltip_end)
tooltip_beside :: proc() -> bool {
	s := gs()
	em := font_size()
	size := tooltip_last_size(em)
	pos := s.mouse + {em * 1.2, -size.y * 0.5}
	if pos.x + size.x > s.window_size.x { pos.x = s.mouse.x - em * 1.2 - size.x }
	tooltip_open(clamp_popup(pos, size, s.window_size), em)
	return true
}

// The size the tooltip had in the last build.
@(private)
tooltip_last_size :: proc(em: f32) -> Vec2 {
	prev := gs().boxes[key_from_string(gs().root.key, "###tooltip")]
	return prev != nil ? prev.size : Vec2{em * TOOLTIP_FIRST_WIDTH_EM, em * TOOLTIP_FIRST_HEIGHT_EM}
}

@(private)
tooltip_open :: proc(pos: Vec2, em: f32) {
	s := gs()
	push_parent(s.root)
	push_tags_isolated("floating")
	push_style_copy()
	st := top_style()
	for a in Axis { if st.pref[a].kind == .Percent { st.pref[a] = text_size() } }
	set_next_axis(.Y)
	s.next_mod.fixed_x = pos.x
	s.next_mod.fixed_y = pos.y
	s.next_mod.width = children_sum()
	s.next_mod.height = children_sum()
	s.next_mod.radius = em * TOOLTIP_RADIUS_EM
	prev := s.boxes[key_from_string(s.root.key, "###tooltip")]
	if prev == nil || prev.last_build + 1 != s.build_index { s.next_mod.transparency = 1; s.anim_busy = true }   // measured on this frame, placed and shown on the next
	p := build_box({.Draw_Background, .Draw_Border, .Draw_Shadow, .Plate}, "###tooltip")
	a11y_default(p, {role = .Tooltip})
	push_parent(p)
	append(&s.popup_stack, true)
}

@(private)
tooltip_end :: proc() { popup_end() }


