package ui

import "core:fmt"
import "core:unicode"
import "../platform"

// Popups (menus, dropdowns, tooltips) are floating boxes appended to the ROOT, so they draw above everything built so
// far and win hit testing. Their contents inherit the style of the call site.
//
// Menus. One menu is open at a time, with any depth of open submenus and nested menus (`State.menus`, outermost first):
//
//   if ui.ctx_menu(key) {                      // width 0: as wide as its widest item (measured on the previous frame)
//       if ui.menu_item("Copy", "Ctrl+C").clicked { ... }
//       ui.menu_separator()
//       if ui.menu_submenu("Search with") {
//           if ui.menu_item("Engine A").clicked { ... }
//       }
//       if ui.menu_item("Paste", "Ctrl+V", enabled = can_paste).clicked { ... }
//   }
//
// Keyboard (the open menu owns every key press and typed character of the frame): Up / Down / Home / End move over the
// enabled items (wrapping), Right / Enter / Space open the selected submenu, Enter / Space choose the selected item,
// Left / Escape close the innermost submenu, Escape closes the menu, a typed letter selects the next item starting
// with it. Pointer: hovering selects, resting on a submenu item opens it (and on another item closes it) after
// MENU_HOVER_MS, clicking chooses; a press outside every open level closes the menu. A menu opens where asked and
// stays on screen: it flips to the other side of the point (or of the anchor rect) when it does not fit, then is
// clamped to the window. A level taller than the window is as tall as the window and scrolls (wheel, scroll bar; the
// keyboard's selection is brought into view).
//
// A nested menu is a menu opened from inside an open one, at a point or under a rect (a row's context menu in a
// drop-down panel), over it; the menu stays open behind it:
//
//   if ui.ctx_menu(key) {
//       if row_sig.right_clicked { ui.menu_nested_open(row_menu, ui.mouse_pos()) }
//       if ui.menu_nested(row_menu) { if ui.menu_item("Open").clicked { ... } }
//   }
//
// It closes like a submenu: a press outside it closes only it, Escape closes it, choosing an item closes the menu.

MENU_HOVER_MS :: 280.0

// The height of a menu item, in em, unless `set_menu_item_height` says otherwise (times the density): about the rows of
// Windows 11's and Chrome's menus, 28 to 32 px for 14 to 15 px text.
MENU_ITEM_EM :: 1.9

// A menu is at least this wide; a level not measured yet is taken to be this tall.
@(private) MENU_MIN_WIDTH_EM :: 10
@(private = "file") MENU_FIRST_HEIGHT_EM :: 10
// Space above the first item and below the last, and on each side of a separator's line.
@(private = "file") MENU_PAD_EM :: 0.25
@(private = "file") MENU_SEPARATOR_GAP_EM :: 0.2
// A tooltip's size before it was measured.
@(private = "file") TOOLTIP_FIRST_WIDTH_EM :: 10
@(private = "file") TOOLTIP_FIRST_HEIGHT_EM :: 3

// Menus built from now on have items of `em` times the font size in height (0: back to MENU_ITEM_EM). A dense tool
// panel sets it while it builds its menus, and resets it after.
set_menu_item_height :: proc(em: f32) { gs().menu_item_em = em }

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
	nested:       bool,      // opened by menu_nested_open: placed like level 0, not closed by resting on its menu's items
	open_build:   u64,
	built_build:  u64,
	sel:          int,       // selected item (-1: none)
	items, prev:  [dynamic]Menu_Item_Info,   // this frame's items / last frame's (keyboard navigation reads those)
	width, prev_width: f32,  // natural width of the widest item: measured this frame / last frame
	eff_width:    f32,       // width of the rows this frame
	activate:     bool,      // keyboard: choose the selected item when it is built
	open_sub:     bool,      // keyboard: open the selected submenu
	from_keyboard: bool,     // opened from the keyboard: the first item starts selected
	panel:        Key,
	hover_item:   int,       // item under the pointer and since when (submenus open / close after a delay)
	hover_since:  f64,
	scrolls:      bool,      // its content is taller than the window: as tall as the window, scrolled
	reveal:       bool,      // the keyboard moved the selection: scroll its row into view
}

// Opens the menu `key` with its top-left corner at `pos` (window pixels), replacing any open menu.
// `anchor`: the box that opens the menu (dropdown button, menu bar entry): pressing it again is not a press "outside",
// so the widget can toggle the menu itself. `from_keyboard`: the first enabled item starts selected.
ctx_menu_open :: proc(key: Key, pos: Vec2, anchor: Key = 0, from_keyboard := false) {
	s := gs()
	menu_pop_to(0)
	s.menu_close_pending = false   // (the menu asked to close is gone: this one is new)
	append(&s.menus, Menu_Level{key = key, anchor = anchor, pos = pos, open_build = s.build_index, sel = -1, hover_item = -1, from_keyboard = from_keyboard})
}

// Opens the menu below `rect` (above it when there is no room below), e.g. under the button that opens it.
ctx_menu_open_rect :: proc(key: Key, rect: Rect, anchor: Key = 0, from_keyboard := false) {
	ctx_menu_open(key, {rect.min.x, rect.max.y}, anchor, from_keyboard)
	gs().menus[0].around = rect
}

ctx_menu_close :: proc() { menu_pop_to(0) }
ctx_menu_is_open :: proc(key: Key) -> bool { return key != 0 && len(gs().menus) > 0 && gs().menus[0].key == key }
ctx_menu_any_open :: proc() -> bool { return len(gs().menus) > 0 }

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
	}
}

@(private)
menus_destroy :: proc(s: ^State) {
	for &lv in s.menus { delete(lv.items); delete(lv.prev) }
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
	for e in events {
		if e.kind != .Key_Press && e.kind != .Text { continue }
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
	for lv in s.menus {
		b := s.boxes[lv.panel]
		if b == nil || b.last_build != s.build_index || b.parent != s.root || s.root.last == b { continue }
		p := b.parent
		if b.prev != nil { b.prev.next = b.next } else { p.first = b.next }
		if b.next != nil { b.next.prev = b.prev } else { p.last = b.prev }
		b.prev, b.next = p.last, nil
		if p.last != nil { p.last.next = b } else { p.first = b }
		p.last = b
	}
}

// Levels the app stopped building close (end_build).
@(private)
menu_prune :: proc(s: ^State) {
	for i in 0 ..< len(s.menus) {
		lv := &s.menus[i]
		if lv.built_build != s.build_index && lv.open_build < s.build_index { menu_pop_to(i); return }
	}
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

// `if ctx_menu(key, width) { menu_item(...) ... }`: builds the menu `key` when it is open. `width` 0 = as wide as the
// widest item. Closes on Escape, on a press outside every open level, or when an item is chosen.
@(deferred_none = menu_end)
ctx_menu :: proc(key: Key, width: f32 = 0) -> bool {
	s := gs()
	if !ctx_menu_is_open(key) {
		append(&s.popup_stack, false)
		return false
	}
	// a press outside every open level closes the whole menu
	if s.build_index > s.menus[0].open_build && menu_pressed_outside(s, 0, s.menus[0].anchor) {
		ctx_menu_close()
		append(&s.popup_stack, false)
		return false
	}
	return menu_level_begin(0, width)
}

// A press of this frame (any button) landed outside the open levels from `from` on, and not on `anchor`.
@(private = "file")
menu_pressed_outside :: proc(s: ^State, from: int, anchor: Key) -> bool {
	if !s.pressed_any[.Left] && !s.pressed_any[.Right] && !s.pressed_any[.Middle] { return false }
	hit: Key
	switch {
	case s.pressed_any[.Left]:  hit = s.pressed_key[.Left]
	case s.pressed_any[.Right]: hit = s.pressed_key[.Right]
	case:                       hit = s.pressed_key[.Middle]
	}
	if hit != 0 && hit == anchor { return false }
	if owner, ok := s.sb_owner[hit]; ok { hit = owner }   // a level's scroll bar is part of it
	hb := s.boxes[hit] if hit != 0 else nil
	if hb == nil { return true }
	for lv in s.menus[from:] {
		if p := s.boxes[lv.panel]; p != nil && is_descendant(hb, p) { return false }
	}
	return true
}

// Opens the nested menu `key` over the menu being built (call it in that menu's block), its top-left corner at `pos`,
// in place of any submenu or nested menu that menu had open. Does nothing outside a menu's block.
menu_nested_open :: proc(key: Key, pos: Vec2, from_keyboard := false) { menu_nested_push(key, pos, {}, from_keyboard) }

// Opens the nested menu below `rect` (above it when there is no room below), e.g. under a row's menu button.
menu_nested_open_rect :: proc(key: Key, rect: Rect, from_keyboard := false) { menu_nested_push(key, {rect.min.x, rect.max.y}, rect, from_keyboard) }

@(private = "file")
menu_nested_push :: proc(key: Key, pos: Vec2, around: Rect, from_keyboard: bool) {
	s := gs()
	_, depth := menu_current()
	if depth < 0 { return }
	menu_pop_to(depth + 1)
	append(&s.menus, Menu_Level{key = key, pos = pos, around = around, nested = true, open_build = s.build_index, sel = -1, hover_item = -1, from_keyboard = from_keyboard})
}

// `if menu_nested(key, width) { menu_item(...) }`, in the block of the menu that opened it: builds the nested menu
// `key` while it is open. `width` 0 = as wide as the widest item. A press outside it (and the levels it opened) closes
// only it.
@(deferred_none = menu_end)
menu_nested :: proc(key: Key, width: f32 = 0) -> bool {
	s := gs()
	_, depth := menu_current()
	d := depth + 1
	if depth < 0 || d >= len(s.menus) || s.menus[d].key != key || !s.menus[d].nested {
		append(&s.popup_stack, false)
		return false
	}
	if s.build_index > s.menus[d].open_build && menu_pressed_outside(s, d, 0) {
		menu_pop_to(d)
		append(&s.popup_stack, false)
		return false
	}
	return menu_level_begin(d, width)
}

@(private)
menu_level_begin :: proc(depth: int, width: f32) -> bool {
	s := gs()
	lv := &s.menus[depth]
	lv.prev, lv.items = lv.items, lv.prev
	clear(&lv.items)
	lv.prev_width, lv.width = lv.width, 0
	lv.built_build = s.build_index
	lv.activate = false

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
		if lv.from_keyboard && lv.sel < 0 { lv.sel = menu_step(items, -1, 1) }
		keys: for e, i in s.menu_keys.list {
			if s.menu_keys.consumed[i] { continue }
			s.menu_keys.consumed[i] = true
			valid := lv.sel >= 0 && lv.sel < len(items) && items[lv.sel].enabled
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

	em := font_size()
	id := fmt.tprintf("###menu_%d", u64(lv.key))
	panel := s.boxes[key_from_string(s.root.key, id)]
	first := panel == nil
	// (its content's height: the last layout's; taller than the window, the rows leave room for the scroll bar)
	lv.scrolls = !first && panel.view_bounds.y > s.window_size.y
	w := (width > 0 ? width : max(lv.prev_width, em * MENU_MIN_WIDTH_EM)) + menu_bar_room(lv, em)
	lv.eff_width = w
	size := first ? Vec2{w, em * MENU_FIRST_HEIGHT_EM} : Vec2{panel.size.x, min(panel.view_bounds.y, s.window_size.y)}
	pos := menu_place(lv, depth, size, s.window_size, em)
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()
	set_next_axis(.Y)
	s.next_mod.fixed_x = pos.x
	s.next_mod.fixed_y = pos.y
	s.next_mod.width = children_sum()
	s.next_mod.height = lv.scrolls ? px(s.window_size.y) : children_sum()
	s.next_mod.radius = em * 0.5
	if first { s.next_mod.transparency = 1; s.anim_busy = true }   // measured on this frame, shown on the next
	p := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, id)
	p.cursor = .Arrow
	if !lv.scrolls { p.view_off, p.view_target = {}, {} }
	a11y_default(p, {role = .Menu, orientation = .Y})
	lv.panel = p.key
	_ = signal(p)
	push_parent(p)
	append(&s.popup_stack, true)
	append(&s.menu_build, depth)
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
	y := panel.view_target.y
	if top < y { y = top }
	if top + b.size.y > y + panel.size.y { y = top + b.size.y - panel.size.y }
	if y != panel.view_target.y { scrollbar_reveal(panel) }
	panel.view_target.y, panel.view_off.y = y, y   // (a step of the keyboard jumps, as the system's menus do)
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
			ctx_menu_close()
		}
	}
	ctx_menu_end()
}

@(private)
ctx_menu_end :: proc() {
	s := gs()
	if pop(&s.popup_stack) {
		pop_parent()     // panel
		pop(&s.style_stack)
		pop_tags()
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

// One row: check mark or icon, label, shortcut (weak), submenu arrow. Returns the row's signal.
@(private)
menu_row :: proc(lv: ^Menu_Level, idx: int, text, shortcut, glyph: string, checked, enabled, submenu, highlight: bool) -> Signal {
	s := gs()
	em := font_size()
	label := display_part(text)
	// spacers, icon cell, label and its padding, borders (with a little room so the label never gets "...")
	natural := em * 0.6 + em * 1.5 + text_width(top_style().font, em, label) + 2 * top_style().text_pad + em * 0.5 + em * 0.6 + 4 * max(1, scale())
	if shortcut != "" { natural += text_width(top_style().font, em, shortcut) + em * 2.5 }
	if submenu { natural += em * 1.6 }
	lv.width = max(lv.width, natural)
	width := lv.eff_width
	sig: Signal
	if disabled(!enabled) {
		if tags("menu_item") {
			if highlight { push_tags("selected") }
			set_next_axis(.X, .Center)
			s.next_mod.width = px(width)
			s.next_mod.height = px(dense(em * (s.menu_item_em > 0 ? s.menu_item_em : MENU_ITEM_EM)))
			s.next_mod.radius = em * 0.35
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
				spacer(px(em * 0.6))
				next({width = px(em * 1.5), height = pct(1)})
				if checked && s.icon_font != 0 {
					if style({font = s.icon_font, text_align = .Center}) { build_box({.Draw_Text, .No_Text_Trunc}, "V###chk") }
				} else if glyph != "" && s.icon_font != 0 {
					if style({font = s.icon_font, text_align = .Center}) { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", glyph)) }
				} else {
					build_box({}, "###nochk")
				}
				next({width = fill(), height = pct(1)})
				build_box({.Draw_Text}, fmt.tprintf("%s###lbl", label))
				if shortcut != "" {
					if tags("weak") {
						next({width = text_size(em * 0.5), height = pct(1)})
						build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###key", shortcut))
					}
				}
				if submenu && s.icon_font != 0 {
					if tags("weak") { icon(">", em * 1.2) }
				}
				spacer(px(em * 0.5 + menu_bar_room(lv, em)))
			}
		}
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

// The pointer has rested on item `idx` of `lv` for MENU_HOVER_MS (asks for a timed wake while waiting).
@(private)
menu_hover_due :: proc(lv: ^Menu_Level, idx: int) -> bool {
	s := gs()
	if lv.hover_item != idx { return false }
	waited := s.time_ms - lv.hover_since
	if waited >= MENU_HOVER_MS { return true }
	wake_within(s, max(1, int(MENU_HOVER_MS - waited) + WAKE_MARGIN_MS))
	return false
}

// One item of the menu being built. Tags used: "menu_item" (+ "selected" on the selected one). Closes the whole menu
// when chosen (click, or Enter / Space on the selected item). A disabled item (`enabled` false, or inside a `disabled`
// scope) is shown muted and skipped by the keyboard.
menu_item :: proc(text: string, shortcut := "", checked := false, icon := "", enabled := true, keep_open := false) -> Signal {
	s := gs()
	lv, depth := menu_current()
	if lv == nil {
		// outside a menu: a plain row (so menu bodies can be factored into procs and reused elsewhere)
		return button(text)
	}
	en := enabled && s.disabled_depth == 0
	idx := len(lv.items)
	append(&lv.items, Menu_Item_Info{enabled = en, first = first_letter(display_part(text))})
	sig := menu_row(lv, idx, text, shortcut, icon, checked, en, false, idx == lv.sel)
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
	em := font_size()
	w := lv != nil ? lv.eff_width : em * MENU_MIN_WIDTH_EM
	spacer(px(em * MENU_SEPARATOR_GAP_EM))
	hline(px(w))
	spacer(px(em * MENU_SEPARATOR_GAP_EM))
}

// `if menu_submenu("Label") { menu_item(...) }`: an item that opens a nested menu (to its right, or its left when there
// is no room). Opens on click, after the pointer rests on it, or with Right / Enter / Space; the block builds the
// submenu's items while it is open.
@(deferred_none = menu_end)
menu_submenu :: proc(text: string, icon := "", enabled := true) -> bool {
	s := gs()
	lv, depth := menu_current()
	if lv == nil { append(&s.popup_stack, false); return false }
	en := enabled && s.disabled_depth == 0
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

// True once the pointer has rested on the box for `seconds` (asks the app loop for a timed wake while waiting).
hovered_for :: proc(sig: Signal, seconds: f32) -> bool {
	s := gs()
	if !sig.hovering { return false }
	waited := s.time_ms - s.hover_since_ms
	if waited >= f64(seconds) * 1000 { return true }
	wake_within(s, max(1, int(f64(seconds) * 1000 - waited) + WAKE_MARGIN_MS))
	return false
}

// `if tooltip() { label("...") }` near the pointer. Not clickable, so it never blocks the box below.
@(deferred_none = tooltip_end)
tooltip :: proc() -> bool {
	s := gs()
	em := font_size()
	tooltip_open(clamp_popup(s.mouse + {em * 0.8, em * 1.4}, tooltip_last_size(em), s.window_size), em)
	return true
}

// `tooltip` beside the pointer instead of below it: to its right (to its left when there is no room), centered on it. For
// the rows of a list or a table, where a tooltip below the pointer would cover the rows under the one it is about.
@(deferred_none = tooltip_end)
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
	push_tags("floating")
	push_style_copy()
	set_next_axis(.Y)
	s.next_mod.fixed_x = pos.x
	s.next_mod.fixed_y = pos.y
	s.next_mod.width = children_sum()
	s.next_mod.height = children_sum()
	s.next_mod.radius = em * 0.4
	p := build_box({.Draw_Background, .Draw_Border, .Draw_Shadow}, "###tooltip")
	a11y_default(p, {role = .Tooltip})
	push_parent(p)
	append(&s.popup_stack, true)
}

@(private)
tooltip_end :: proc() { ctx_menu_end() }

