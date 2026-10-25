package ui

import "core:fmt"
import "core:unicode"
import "../platform"

// Popups (menus, dropdowns, tooltips) are floating boxes appended to the ROOT, so they draw above everything built so
// far and win hit testing. Their contents inherit the style of the call site.
//
// Menus. One menu is open at a time, with any depth of open submenus (`State.menus`, outermost first):
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
// clamped to the window.

MENU_HOVER_MS :: 280.0

// The height of a menu item, in em, unless `set_menu_item_height` says otherwise.
MENU_ITEM_EM :: 2.2

// Menus built from now on have items of `em` times the font size in height (0: back to MENU_ITEM_EM). A dense tool
// panel sets it while it builds its menus, and resets it after.
set_menu_item_height :: proc(em: f32) { g.menu_item_em = em }

// A small weak title above a group of items (not an item: the keyboard skips it).
menu_heading :: proc(text: string) {
	lv, _ := menu_current()
	em := font_size()
	w := lv != nil ? lv.eff_width : em * 10
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
	around:       Rect,      // not empty: open next to this rect (level 0: below, else above; submenus: right, else left)
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
}

// Opens the menu `key` with its top-left corner at `pos` (window pixels), replacing any open menu.
// `anchor`: the box that opens the menu (dropdown button, menu bar entry): pressing it again is not a press "outside",
// so the widget can toggle the menu itself. `from_keyboard`: the first enabled item starts selected.
ctx_menu_open :: proc(key: Key, pos: Vec2, anchor: Key = 0, from_keyboard := false) {
	menu_pop_to(0)
	g.menu_close_pending = false   // (the menu asked to close is gone: this one is new)
	append(&g.menus, Menu_Level{key = key, anchor = anchor, pos = pos, open_build = g.build_index, sel = -1, hover_item = -1, from_keyboard = from_keyboard})
}

// Opens the menu below `rect` (above it when there is no room below), e.g. under the button that opens it.
ctx_menu_open_rect :: proc(key: Key, rect: Rect, anchor: Key = 0, from_keyboard := false) {
	ctx_menu_open(key, {rect.min.x, rect.max.y}, anchor, from_keyboard)
	g.menus[0].around = rect
}

ctx_menu_close :: proc() { menu_pop_to(0) }
ctx_menu_is_open :: proc(key: Key) -> bool { return key != 0 && len(g.menus) > 0 && g.menus[0].key == key }
ctx_menu_any_open :: proc() -> bool { return len(g.menus) > 0 }

// Selects item `index` of the open menu (e.g. a dropdown's current value, so the keyboard starts from it).
menu_select :: proc(index: int) { if len(g.menus) > 0 { g.menus[0].sel = index } }

// Number of open levels (1 = the menu, 2 = one submenu open...).
menu_depth :: proc() -> int { return len(g.menus) }

// Where level `depth` of the open menu was laid out (last build), and its selected item (-1: none).
menu_rect :: proc(depth: int) -> (r: Rect, sel: int, ok: bool) {
	if depth < 0 || depth >= len(g.menus) { return {}, -1, false }
	lv := &g.menus[depth]
	b := g.boxes[lv.panel]
	if b == nil { return {}, lv.sel, false }
	return b.rect, lv.sel, true
}

@(private)
menu_pop_to :: proc(n: int) {
	s := g
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
		if depth == 0 {
			gap := em * 0.25
			pos = {r.min.x, r.max.y + gap}
			if pos.y + size.y > window.y && r.min.y - gap - size.y >= 0 { pos.y = r.min.y - gap - size.y }
		} else {
			pad := em * 0.3   // the first row lines up with the item that opened the submenu
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
	s := g
	if !ctx_menu_is_open(key) {
		append(&s.popup_stack, false)
		return false
	}
	// a press outside every open level closes the whole menu
	if (s.pressed_any[.Left] || s.pressed_any[.Right] || s.pressed_any[.Middle]) && s.build_index > s.menus[0].open_build {
		hit: Key
		switch {
		case s.pressed_any[.Left]:  hit = s.pressed_key[.Left]
		case s.pressed_any[.Right]: hit = s.pressed_key[.Right]
		case:                       hit = s.pressed_key[.Middle]
		}
		hb := s.boxes[hit] if hit != 0 else nil
		inside := hit != 0 && hit == s.menus[0].anchor
		for lv in s.menus {
			if p := s.boxes[lv.panel]; p != nil && hb != nil && is_descendant(hb, p) { inside = true }
		}
		if !inside {
			ctx_menu_close()
			append(&s.popup_stack, false)
			return false
		}
	}
	return menu_level_begin(0, width)
}

@(private)
menu_level_begin :: proc(depth: int, width: f32) -> bool {
	s := g
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
					if items[j].enabled && items[j].first == want { lv.sel = j; break }
				}
				continue
			}
			if e.mods - {.Shift} != {} { continue }
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
	w := width > 0 ? width : max(lv.prev_width, em * 10)
	lv.eff_width = w
	id := fmt.tprintf("###menu_%d", u64(lv.key))
	panel := s.boxes[key_from_string(s.root.key, id)]
	first := panel == nil
	size := first ? Vec2{w, em * 10} : panel.size
	pos := menu_place(lv, depth, size, s.window_size, em)
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()
	set_next_axis(.Y)
	g.next_mod.fixed_x = pos.x
	g.next_mod.fixed_y = pos.y
	g.next_mod.width = children_sum()
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.5
	if first { g.next_mod.transparency = 1; s.anim_busy = true }   // measured on this frame, shown on the next
	p := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, id)
	p.cursor = .Arrow
	lv.panel = p.key
	_ = signal(p)
	push_parent(p)
	append(&s.popup_stack, true)
	append(&s.menu_build, depth)
	spacer(px(em * 0.3))
	return true
}

@(private)
push_style_copy :: proc() { append(&g.style_stack, top_style()^) }

@(private)
menu_end :: proc() {
	s := g
	if len(s.popup_stack) > 0 && s.popup_stack[len(s.popup_stack) - 1] && len(s.menu_build) > 0 {
		spacer(px(font_size() * 0.3))
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
	s := g
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
	s := g
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
	s := g
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
			g.next_mod.width = px(width)
			g.next_mod.height = px(dense(em * (s.menu_item_em > 0 ? s.menu_item_em : MENU_ITEM_EM)))
			g.next_mod.radius = em * 0.35
			if !highlight { g.next_mod.border = Color{} }   // always bordered (layout space), visible only when selected
			b := build_box({.Clickable, .Draw_Hot_Effects, .Draw_Background, .Draw_Border}, fmt.tprintf("###mi_%d_%s", idx, hash_part(text)))
			if highlight { pop_tags() }
			if idx < len(lv.items) { lv.items[idx].key = b.key }
			sig = signal(b)
			if parent(b) {
				spacer(px(em * 0.6))
				next({width = px(em * 1.5), height = px(em * 1.5)})
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
				spacer(px(em * 0.5))
			}
		}
	}
	if sig.hovering {
		if s.mouse_moved || lv.sel < 0 { lv.sel = idx }
		if lv.hover_item != idx { lv.hover_item = idx; lv.hover_since = s.time_ms }
	} else if lv.hover_item == idx {
		lv.hover_item = -1
	}
	return sig
}

// The pointer has rested on item `idx` of `lv` for MENU_HOVER_MS (asks for a timed wake while waiting).
@(private)
menu_hover_due :: proc(lv: ^Menu_Level, idx: int) -> bool {
	s := g
	if lv.hover_item != idx { return false }
	waited := s.time_ms - lv.hover_since
	if waited >= MENU_HOVER_MS { return true }
	s.wake_ms = s.wake_ms == 0 ? max(1, int(MENU_HOVER_MS - waited) + 5) : min(s.wake_ms, max(1, int(MENU_HOVER_MS - waited) + 5))
	return false
}

// One item of the menu being built. Tags used: "menu_item" (+ "selected" on the selected one). Closes the whole menu
// when chosen (click, or Enter / Space on the selected item). A disabled item (`enabled` false, or inside a `disabled`
// scope) is shown muted and skipped by the keyboard.
menu_item :: proc(text: string, shortcut := "", checked := false, icon := "", enabled := true, keep_open := false) -> Signal {
	s := g
	lv, depth := menu_current()
	if lv == nil {
		// outside a menu: a plain row (so menu bodies can be factored into procs and reused elsewhere)
		return button(text)
	}
	en := enabled && s.disabled_depth == 0
	idx := len(lv.items)
	append(&lv.items, Menu_Item_Info{enabled = en, first = first_letter(display_part(text))})
	sig := menu_row(lv, idx, text, shortcut, icon, checked, en, false, idx == lv.sel)
	// resting on another item than the open submenu's closes that submenu
	if sig.hovering && len(s.menus) > depth + 1 && menu_hover_due(lv, idx) { menu_pop_to(depth + 1) }
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
	w := lv != nil ? lv.eff_width : em * 10
	spacer(px(em * 0.25))
	hline(px(w))
	spacer(px(em * 0.25))
}

// `if menu_submenu("Label") { menu_item(...) }`: an item that opens a nested menu (to its right, or its left when there
// is no room). Opens on click, after the pointer rests on it, or with Right / Enter / Space; the block builds the
// submenu's items while it is open.
@(deferred_none = menu_end)
menu_submenu :: proc(text: string, icon := "", enabled := true) -> bool {
	s := g
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
	if !open {
		append(&s.popup_stack, false)
		return false
	}
	return menu_level_begin(depth + 1, 0)
}

// True once the pointer has rested on the box for `seconds` (asks the app loop for a timed wake while waiting).
hovered_for :: proc(sig: Signal, seconds: f32) -> bool {
	s := g
	if !sig.hovering { return false }
	waited := s.time_ms - s.hover_since_ms
	if waited >= f64(seconds) * 1000 { return true }
	wake_within(s, max(1, int(f64(seconds) * 1000 - waited) + 5))
	return false
}

// `if tooltip() { label("...") }` near the pointer. Not clickable, so it never blocks the box below.
@(deferred_none = tooltip_end)
tooltip :: proc() -> bool {
	s := g
	em := font_size()
	key := key_from_string(s.root.key, "###tooltip")
	prev := s.boxes[key]
	size := prev != nil ? prev.size : Vec2{em * 10, em * 3}
	pos := clamp_popup(s.mouse + {em * 0.8, em * 1.4}, size, s.window_size)
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()
	set_next_axis(.Y)
	g.next_mod.fixed_x = pos.x
	g.next_mod.fixed_y = pos.y
	g.next_mod.width = children_sum()
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.4
	p := build_box({.Draw_Background, .Draw_Border, .Draw_Shadow}, "###tooltip")
	push_parent(p)
	append(&s.popup_stack, true)
	return true
}

// `tooltip` beside the pointer instead of below it: to its right (to its left when there is no room), centered on it. For
// the rows of a list or a table, where a tooltip below the pointer would cover the rows under the one it is about.
@(deferred_none = tooltip_end)
tooltip_beside :: proc() -> bool {
	s := g
	em := font_size()
	key := key_from_string(s.root.key, "###tooltip")
	prev := s.boxes[key]
	size := prev != nil ? prev.size : Vec2{em * 10, em * 3}
	pos := s.mouse + {em * 1.2, -size.y * 0.5}
	if pos.x + size.x > s.window_size.x { pos.x = s.mouse.x - em * 1.2 - size.x }
	pos = clamp_popup(pos, size, s.window_size)
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()
	set_next_axis(.Y)
	g.next_mod.fixed_x = pos.x
	g.next_mod.fixed_y = pos.y
	g.next_mod.width = children_sum()
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.4
	p := build_box({.Draw_Background, .Draw_Border, .Draw_Shadow}, "###tooltip")
	push_parent(p)
	append(&s.popup_stack, true)
	return true
}

@(private)
tooltip_end :: proc() { ctx_menu_end() }

