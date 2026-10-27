package ui

// Overlays that sit above the page: toasts, modal dialogs and the menu bar helper.
// Build overlays AFTER the page content: later boxes draw on top and win hit testing.

import "core:fmt"
import "core:math"
import "core:strings"
import "../font"

////////////////////////////////
// Toasts

// Where the toast stack sits inside the toast area (see `set_toast_area`).
Toast_Position :: enum u8 { Top_Left, Top_Center, Top_Right, Middle_Left, Middle_Right, Bottom_Left, Bottom_Center, Bottom_Right }

toast_position_names := [Toast_Position]string{
	.Top_Left = "Top left", .Top_Center = "Top center", .Top_Right = "Top right",
	.Middle_Left = "Middle left", .Middle_Right = "Middle right",
	.Bottom_Left = "Bottom left", .Bottom_Center = "Bottom center", .Bottom_Right = "Bottom right",
}

set_toast_position :: proc(s: ^State, p: Toast_Position) { s.toast_pos = p }
toast_position :: proc(s: ^State) -> Toast_Position { return s.toast_pos }

// Rectangle (window pixels) the toasts are placed in, e.g. the content area between a menu bar and a status bar.
// Call it every frame before `toasts_build`; the default is the whole window.
set_toast_area :: proc(r: Rect) { g.toast_area = r; g.toast_area_set = true }

// Queue a message. Toasts fade in, stay ~3.8 s, fade out; click to dismiss. Oldest is replaced when all slots are used.
toast :: proc(kind: Toast_Kind, format: string, args: ..any) {
	s := g
	slot := -1
	oldest_ms := max(f64)
	oldest := 0
	for t, i in s.toasts {
		if !t.alive { slot = i; break }
		if t.born_ms < oldest_ms { oldest_ms = t.born_ms; oldest = i }
	}
	if slot < 0 { slot = oldest }
	t := &s.toasts[slot]
	t^ = {}
	msg := fmt.tprintf(format, ..args)
	t.len = min(len(msg), len(t.text))
	if t.len < len(msg) { t.len = font.grapheme_prev(msg, t.len + 1) }   // cut between clusters, not inside a character
	copy(t.text[:], msg[:t.len])
	s.toast_serial += 1
	t.alive, t.kind, t.born_ms, t.life_ms, t.serial = true, kind, build_open ? s.time_ms : now_ms(), 3800, s.toast_serial
}

toasts_clear :: proc() { for &t in g.toasts { t.alive = false } }

// Builds the toast stack. Look: panel background, a 1.5 px border all around tinted by the kind
// (info = accent, good / warn / bad), the icon in the same tint. Newest toast is nearest to the anchored edge;
// the others glide to their new place when one leaves.
toasts_build :: proc() {
	s := g
	em := font_size()
	area := s.toast_area_set ? s.toast_area : Rect{{0, 0}, s.window_size}
	s.toast_area_set = false
	w := min(em * 26, (area.max.x - area.min.x) * 0.9)
	h, gap, margin := em * 3.0, em * 0.6, em * 1.1
	pos := s.toast_pos

	// alive toasts, newest first
	order := make([dynamic]int, 0, len(s.toasts), context.temp_allocator)
	for &t, i in s.toasts {
		if !t.alive { continue }
		if s.time_ms - t.born_ms > t.life_ms { t.alive = false; continue }
		append(&order, i)
	}
	for a in 1 ..< len(order) {   // insertion sort by birth, newest first
		v := order[a]
		b := a - 1
		for b >= 0 && s.toasts[order[b]].serial < s.toasts[v].serial { order[b + 1] = order[b]; b -= 1 }
		order[b + 1] = v
	}
	n := len(order)
	if n == 0 { return }

	left := pos == .Top_Left || pos == .Middle_Left || pos == .Bottom_Left
	right := pos == .Top_Right || pos == .Middle_Right || pos == .Bottom_Right
	top := pos == .Top_Left || pos == .Top_Center || pos == .Top_Right
	bottom := pos == .Bottom_Left || pos == .Bottom_Center || pos == .Bottom_Right
	x := left ? area.min.x + margin : (right ? area.max.x - margin - w : (area.min.x + area.max.x - w) * 0.5)
	stack_h := f32(n) * h + f32(n - 1) * gap

	icons := [Toast_Kind]string{.Info = ICON_INFO, .Good = ICON_CHECK, .Warn = ICON_WARN, .Bad = ICON_WARN_BIG}
	tag := [Toast_Kind]string{.Info = "accent", .Good = "good", .Warn = "warn", .Bad = "bad"}
	for idx, slot in order {
		t := &s.toasts[idx]
		age := f32(s.time_ms - t.born_ms) / 1000
		life := f32(t.life_ms) / 1000
		ease, alpha: f32 = 1, 1
		if s.anim_rate != 0 {
			in_t := clamp(age / 0.25, 0, 1)
			ease = 1 - (1 - in_t) * (1 - in_t) * (1 - in_t)
			alpha = min(ease, clamp((life - age) / 0.35, 0, 1))
			s.anim_busy = true
		} else {
			// no animation: just wake up when the oldest one expires
			left_ms := int((life - age) * 1000) + 5
			s.wake_ms = s.wake_ms == 0 ? left_ms : min(s.wake_ms, left_ms)
		}
		target_y: f32
		switch {
		case top:    target_y = area.min.y + margin + f32(slot) * (h + gap)
		case bottom: target_y = area.max.y - margin - h - f32(slot) * (h + gap)
		case:        target_y = (area.min.y + area.max.y - stack_h) * 0.5 + f32(slot) * (h + gap)
		}
		id := fmt.tprintf("###toast_%d", t.serial)
		key := key_from_string(s.root.key, id)
		y := anim(key_from_string(key, "y"), target_y, 40, target_y)
		when #config(TOAST_PROBE, false) { fmt.eprintf("build %d toast serial=%d slot=%d target=%.0f y=%.0f alpha=%.2f age=%.2f\n", s.build_index, t.serial, slot, target_y, y, alpha, age) }
		// slide in from the anchored edge
		slide := (1 - ease) * em * 3
		dx, dy: f32
		switch {
		case left:   dx = -slide
		case right:  dx = slide
		case top:    dy = -slide
		case bottom: dy = slide
		}

		push_parent(s.root)
		push_tags("floating")
		push_style_copy()
		push_tags(tag[t.kind])
		tint := color(t.kind == .Info ? "accent" : "text")
		pop_tags()
		set_next_axis(.X, .Center)
		g.next_mod.fixed_x, g.next_mod.fixed_y = x + dx, y + dy
		g.next_mod.fixed_w, g.next_mod.fixed_h = w, h
		g.next_mod.transparency = 1 - alpha
		g.next_mod.radius = em * 0.6
		g.next_mod.border = tint
		b := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Draw_Hot_Effects, .Clip}, id)
		b.cursor = .Hand
		if signal(b).clicked { t.alive = false }
		// announced when it appears (a live region): a problem at once, the rest when the reader is free
		urgent := t.kind == .Bad || t.kind == .Warn
		a11y_default(b, {role = urgent ? .Alert : .Status, name = strings.clone(string(t.text[:t.len]), frame_allocator()), live = urgent ? .Assertive : .Polite, no_children = true})
		push_parent(b)
		spacer(px(em * 0.6))
		icon(icons[t.kind], em * 1.8, tint)
		spacer(px(em * 0.4))
		next({width = fill(), height = pct(1)})
		build_box({.Draw_Text}, fmt.tprintf("%s###msg", string(t.text[:t.len])))
		spacer(px(em * 0.8))
		pop_parent()
		pop_tags()   // floating (push_style_copy is popped with the style stack below)
		pop(&s.style_stack)
		pop_parent()
	}
}
////////////////////////////////
// Modal dialog

// `if modal("confirm", width, &open) { ... }`: dims the page, centers a panel, closes on Escape or a click outside.
@(deferred_none = modal_end)
modal :: proc(id: string, width: f32, open: ^bool, y_fraction: f32 = 0.28) -> bool {
	s := g
	if !open^ {
		append(&s.popup_stack, false)
		return false
	}
	em := font_size()
	if len(s.menus) == 0 && key_press(.Escape) { open^ = false; append(&s.popup_stack, false); return false }
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()

	// (what the app said with `a11y` is the panel's, not the scrim's)
	app_a11y, had_a11y := s.a11y.next, s.a11y.has_next
	s.a11y.has_next = false
	// scrim first, panel second: the panel is later in the tree, so it is on top and takes its own clicks
	push_tags("scrim")
	next({fixed_x = 0, fixed_y = 0, fixed_w = s.window_size.x, fixed_h = s.window_size.y, bg = color("background")})
	scrim := build_box({.Clickable, .Draw_Background}, fmt.tprintf("###modal_scrim_%s", id))
	scrim.cursor = .Arrow
	a11y_default(scrim, {ignore = true})
	pop_tags()
	if signal(scrim).pressed { open^ = false }
	if had_a11y { a11y(app_a11y) }

	set_next_axis(.Y)
	g.next_mod.fixed_x = (s.window_size.x - width) * 0.5
	g.next_mod.fixed_y = s.window_size.y * y_fraction
	g.next_mod.width = px(width)
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.8
	panel := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow}, fmt.tprintf("###modal_%s", id))
	panel.cursor = .Arrow
	_ = signal(panel)
	a11y_default(panel, {role = .Dialog, modal = true})
	push_parent(panel)
	append(&s.popup_stack, true)
	// keyboard: Tab cycles inside the dialog; the page widget that had the focus loses it when the dialog opens
	s.trap_depth += 1
	s.modal_now = panel.key
	if s.modal_prev != panel.key { s.focus_key = 0 }
	return true
}

@(private)
modal_end :: proc() {
	if len(g.popup_stack) > 0 && g.popup_stack[len(g.popup_stack) - 1] { g.trap_depth -= 1 }
	ctx_menu_end()
}

////////////////////////////////
// Menu bar

// A menu bar entry. Returns the key to pass to `ctx_menu`. Clicking toggles the menu; while another bar menu is open,
// hovering switches to this one.
menu_bar_button :: proc(id: string) -> Key {
	s := g
	em := font_size()
	key := key_from_string(parent_box().key, id)
	menu_key := key_from_u64(key, 0xbabe)
	append(&s.bar_keys, menu_key)
	open := ctx_menu_is_open(menu_key)
	bar_active := false
	for k in s.bar_keys_prev { if ctx_menu_is_open(k) { bar_active = true } }

	push_tags(open ? "selected" : "ghost_button")
	next({width = px(font_text_width(id) + em * 1.6), height = px(dense(em * 1.9)), text_align = .Center, radius = em * 0.4})
	b := build_box({.Clickable, .Draw_Text, .Draw_Hot_Effects, .Draw_Background}, id)
	pop_tags()
	a11y_default(parent_box(), {role = .Menu_Bar, orientation = .X})
	a11y_default(b, {role = .Menu_Item, popup = .Menu, expanded = open})
	sig := signal(b)
	if sig.clicked {
		if open { ctx_menu_close() } else { ctx_menu_open_rect(menu_key, b.rect, b.key) }
	} else if sig.hovering && bar_active && !open {
		ctx_menu_open_rect(menu_key, b.rect, b.key)
	}
	return menu_key
}

@(private)
font_text_width :: proc(text_with_id: string) -> f32 {
	st := top_style()
	return text_width(st.font, st.font_size, display_part(text_with_id))
}

// Width in pixels of a string in the given font/size.
text_width :: proc(f: font.Font_Id, size: f32, text: string) -> f32 {
	return font.text_width(g.fonts, f, size, text)
}

_ :: math
