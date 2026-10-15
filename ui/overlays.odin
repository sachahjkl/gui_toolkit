package ui

// Overlays that sit above the page: toasts, modal dialogs and the menu bar helper.
// Build overlays AFTER the page content: later boxes draw on top and win hit testing.

import "core:fmt"
import "core:math"
import "../font"

////////////////////////////////
// Toasts

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
	copy(t.text[:], msg[:t.len])
	t.alive, t.kind, t.born_ms, t.life_ms = true, kind, now_ms(), 3800
}

toasts_clear :: proc() { for &t in g.toasts { t.alive = false } }

toasts_build :: proc() {
	s := g
	em := font_size()
	w := min(em * 28, s.window_size.x * 0.9)
	h, gap, margin := em * 3.1, em * 0.55, em * 1.1
	slot := 0
	icons := [Toast_Kind]string{.Info = ICON_INFO, .Good = ICON_CHECK, .Warn = ICON_WARN, .Bad = ICON_WARN_BIG}
	tag := [Toast_Kind]string{.Info = "weak", .Good = "good", .Warn = "warn", .Bad = "bad"}
	for &t, i in s.toasts {
		if !t.alive { continue }
		age := f32(s.time_ms - t.born_ms) / 1000
		life := f32(t.life_ms) / 1000
		if age > life { t.alive = false; continue }
		ease: f32 = 1
		alpha: f32 = 1
		if s.anim_rate != 0 {
			in_t := clamp(age / 0.28, 0, 1)
			ease = 1 - (1 - in_t) * (1 - in_t) * (1 - in_t)
			alpha = min(ease, clamp((life - age) / 0.35, 0, 1))
		}
		x := s.window_size.x - margin - w + (1 - ease) * em * 6
		y := em * 3 + margin + f32(slot) * (h + gap)
		slot += 1
		s.anim_busy = true
		if s.anim_rate == 0 { s.wake_ms = 100 }

		push_parent(s.root)
		push_tags("floating")
		push_style_copy()
		set_next_axis(.X, .Center)
		g.next_mod.fixed_x, g.next_mod.fixed_y = x, y
		g.next_mod.fixed_w, g.next_mod.fixed_h = w, h
		g.next_mod.transparency = 1 - alpha
		g.next_mod.radius = em * 0.6
		b := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, fmt.tprintf("###toast_%d", i))
		b.cursor = .Hand
		if signal(b).clicked { t.alive = false }
		push_parent(b)
		stripe := color("accent")
		push_tags(tag[t.kind])
		if t.kind != .Info { stripe = color("text") }
		next({width = px(em * 0.4), height = pct(1), bg = stripe})
		build_box({.Draw_Background}, "stripe")
		spacer(px(em * 0.7))
		icon(icons[t.kind], em * 1.8)
		pop_tags()
		spacer(px(em * 0.3))
		next({width = fill(), height = pct(1)})
		build_box({.Draw_Text}, fmt.tprintf("%s###msg", string(t.text[:t.len])))
		spacer(px(em * 0.6))
		pop_parent()
		pop(&s.style_stack)
		pop_tags()
		pop_parent()
	}
}

////////////////////////////////
// Modal dialog

// `if modal("confirm", width, &open) { ... }`: dims the page, centers a panel, closes on Escape or a click outside.
@(deferred_none = ctx_menu_end)
modal :: proc(id: string, width: f32, open: ^bool, y_fraction: f32 = 0.28) -> bool {
	s := g
	if !open^ {
		append(&s.popup_stack, false)
		return false
	}
	em := font_size()
	if key_press(.Escape) { open^ = false; append(&s.popup_stack, false); return false }
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()

	// scrim first, panel second: the panel is later in the tree, so it is on top and takes its own clicks
	push_tags("scrim")
	next({fixed_x = 0, fixed_y = 0, fixed_w = s.window_size.x, fixed_h = s.window_size.y, bg = color("background")})
	scrim := build_box({.Clickable, .Draw_Background}, fmt.tprintf("###modal_scrim_%s", id))
	scrim.cursor = .Arrow
	pop_tags()
	if signal(scrim).pressed { open^ = false }

	set_next_axis(.Y)
	g.next_mod.fixed_x = (s.window_size.x - width) * 0.5
	g.next_mod.fixed_y = s.window_size.y * y_fraction
	g.next_mod.width = px(width)
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.8
	panel := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow}, fmt.tprintf("###modal_%s", id))
	panel.cursor = .Arrow
	_ = signal(panel)
	push_parent(panel)
	append(&s.popup_stack, true)
	return true
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
	for k in s.bar_keys_prev { if s.ctx_menu_key == k { bar_active = true } }

	push_tags(open ? "selected" : "ghost_button")
	next({width = px(font_text_width(id) + em * 1.6), height = px(em * 1.9), text_align = .Center, radius = em * 0.4})
	b := build_box({.Clickable, .Draw_Text, .Draw_Hot_Effects, .Draw_Background}, id)
	pop_tags()
	sig := signal(b)
	pos := Vec2{b.rect.min.x, b.rect.max.y + 4}
	if sig.clicked {
		if open { ctx_menu_close() } else { ctx_menu_open(menu_key, pos, b.key) }
	} else if sig.hovering && bar_active && !open {
		ctx_menu_open(menu_key, pos, b.key)
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
