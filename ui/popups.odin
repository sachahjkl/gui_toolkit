package ui

import "core:fmt"

// Popups (context menus, dropdowns, tooltips) are floating boxes appended to the ROOT, so they draw above everything
// built so far and win hit testing. Their contents inherit the style of the call site.

// `anchor`: the box that opens the menu (dropdown button, menu bar entry). Pressing it again is not a click
// "outside": the widget toggles the menu itself, instead of the press closing it and the release reopening it.
ctx_menu_open :: proc(key: Key, pos: Vec2, anchor: Key = 0) {
	g.ctx_menu_key = key
	g.ctx_menu_anchor = anchor
	g.ctx_menu_pos = pos
	g.menu_sel = -1
	g.ctx_menu_open_build = g.build_index
}

ctx_menu_close :: proc() { g.ctx_menu_key = 0 }
ctx_menu_is_open :: proc(key: Key) -> bool { return key != 0 && g.ctx_menu_key == key }
ctx_menu_any_open :: proc() -> bool { return g.ctx_menu_key != 0 }

@(private)
is_descendant :: proc(b, ancestor: ^Box) -> bool {
	for p := b; p != nil; p = p.parent { if p == ancestor { return true } }
	return false
}

@(private)
clamp_popup :: proc(pos: Vec2, size, window: Vec2) -> Vec2 {
	return {clamp(pos.x, 0, max(0, window.x - size.x)), clamp(pos.y, 0, max(0, window.y - size.y))}
}

// `if ctx_menu(key, width) { menu_item(...) ... }`. Closes on Escape, on a click outside, or when an item is chosen.
// Keyboard: Up / Down move the selection, Enter or Space choose it.
@(deferred_none = menu_end)
ctx_menu :: proc(key: Key, width: f32) -> bool {
	s := g
	if !ctx_menu_is_open(key) {
		append(&s.popup_stack, false)
		return false
	}
	panel_key := key_from_string(s.root.key, fmt.tprintf("###ctx_%d", u64(key)))
	panel := s.boxes[panel_key]
	pressed := s.pressed_any[.Left] || s.pressed_any[.Right]   // anywhere, not only on clickable boxes
	outside := false
	if pressed && s.build_index > s.ctx_menu_open_build {
		hit := s.pressed_key[.Left] if s.pressed_any[.Left] else s.pressed_key[.Right]
		hb := s.boxes[hit]
		outside = panel == nil || hb == nil || !is_descendant(hb, panel)
		if hit == s.ctx_menu_anchor && hit != 0 { outside = false }
	}
	if key_press(.Escape) || outside {
		ctx_menu_close()
		append(&s.popup_stack, false)
		return false
	}

	append(&s.popup_stack, true)
	s.menu_width = width
	s.menu_index = 0
	s.menu_activate = false
	if s.menu_count > 0 {
		if key_press(.Down) { s.menu_sel = (s.menu_sel + 1) % s.menu_count }
		if key_press(.Up)   { s.menu_sel = s.menu_sel <= 0 ? s.menu_count - 1 : s.menu_sel - 1 }
		if s.menu_sel >= 0 && (key_press(.Return) || key_press(.Space)) { s.menu_activate = true }
	}
	em := font_size()
	size := panel != nil ? panel.size : Vec2{width, em * 10}
	pos := clamp_popup(s.ctx_menu_pos, size, s.window_size)
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()
	set_next_axis(.Y)
	g.next_mod.fixed_x = pos.x
	g.next_mod.fixed_y = pos.y
	g.next_mod.width = children_sum()
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.5
	p := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, fmt.tprintf("###ctx_%d", u64(key)))
	p.cursor = .Arrow
	_ = signal(p)
	push_parent(p)
	return true
}

@(private)
push_style_copy :: proc() { append(&g.style_stack, top_style()^) }

@(private)
menu_end :: proc() {
	if len(g.popup_stack) > 0 && g.popup_stack[len(g.popup_stack) - 1] { g.menu_count = g.menu_index }
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

// One row of a menu. Tags used: "menu_item". Closes the menu when clicked.
menu_item :: proc(text: string, shortcut := "", checked := false, icon := "") -> Signal {
	s := g
	em := font_size()
	width := s.menu_width
	clicked: bool
	sig: Signal
	idx := s.menu_index
	s.menu_index += 1
	selected := idx == s.menu_sel
	if tags("menu_item") {
		if selected { push_tags("selected") }
		set_next_axis(.X, .Center)
		g.next_mod.width = px(width)
		g.next_mod.height = px(dense(em * 2.2))
		g.next_mod.radius = em * 0.35
		if !selected { g.next_mod.border = Color{} }   // always bordered (layout space), visible only when selected
		b := build_box({.Clickable, .Draw_Hot_Effects, .Draw_Background, .Draw_Border}, text)   // text = id; drawn by a child below
		b.text = ""
		if selected { pop_tags() }
		sig = signal(b)
		if sig.hovering { s.menu_sel = idx }
		if parent(b) {
			spacer(px(em * 0.6))
			next({width = px(em * 1.5), height = px(em * 1.5)})
			if checked && s.icon_font != 0 {
				if style({font = s.icon_font, text_align = .Center}) { build_box({.Draw_Text, .No_Text_Trunc}, "V###chk") }
			} else if icon != "" && s.icon_font != 0 {
				if style({font = s.icon_font, text_align = .Center}) { build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", icon)) }
			} else {
				build_box({}, "###nochk")
			}
			next({width = fill(), height = pct(1)})
			build_box({.Draw_Text}, fmt.tprintf("%s###lbl", text))
			if shortcut != "" {
				if tags("weak") {
					next({width = text_size(em * 0.5), height = pct(1)})
					build_box({.Draw_Text}, fmt.tprintf("%s###key", shortcut))
				}
			}
			spacer(px(em * 0.5))
		}
		clicked = sig.clicked || (selected && s.menu_activate)
		sig.clicked = clicked
	}
	if clicked { ctx_menu_close() }
	return sig
}

// True once the pointer has rested on the box for `seconds` (asks the app loop for a timed wake while waiting).
hovered_for :: proc(sig: Signal, seconds: f32) -> bool {
	s := g
	if !sig.hovering { return false }
	waited := s.time_ms - s.hover_since_ms
	if waited >= f64(seconds) * 1000 { return true }
	s.wake_ms = max(1, int(f64(seconds) * 1000 - waited) + 5)
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

@(private)
tooltip_end :: proc() { ctx_menu_end() }
