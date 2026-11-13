package ui

// Overlays that sit above the page: toasts, modal dialogs and the menu bar helper.
// Build overlays AFTER the page content: later boxes draw on top and win hit testing.

import "core:fmt"
import "core:math"
import "core:strings"
import "../font"
import "../platform"

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
// Call it every frame it applies (the toasts are built at the end of the build); the default is the whole window.
set_toast_area :: proc(r: Rect) { gs().toast_area = r; gs().toast_area_set = true }

@(private = "file") TOAST_LIFE_MS :: 3800
@(private = "file") TOAST_FADE_IN_S :: 0.25
@(private = "file") TOAST_FADE_OUT_S :: 0.35
@(private = "file") TOAST_GLIDE_RATE :: 40
@(private = "file") TOAST_PAD_Y_EM :: 0.65   // above and below its words

// Queue a message. Toasts fade in, stay ~3.8 s, fade out; click to dismiss (toast_action: to do something). Oldest is replaced when all slots are used.
toast :: proc(kind: Toast_Kind, format: string, args: ..any) { toast_add(kind, nil, nil, fmt.tprintf(format, ..args)) }

// A toast that says what can be done: a click on it does `action`, and dismisses it. (Called while the interface is built, after the
// toasts are; `user` must still be good when it is clicked.)
toast_action :: proc(kind: Toast_Kind, action: proc(user: rawptr), user: rawptr, format: string, args: ..any) {
	toast_add(kind, action, user, fmt.tprintf(format, ..args))
}

// A toast of two parts: `title` in bold on its line (cut with "…" when long), `body` under it, on as many lines as it needs.
// `action`: what a click does (nil: it only dismisses it).
toast_titled :: proc(kind: Toast_Kind, title, body: string, action: proc(user: rawptr) = nil, user: rawptr = nil) {
	toast_add(kind, action, user, body, title)
}

// (`text` cut to `buf`, between clusters, not inside a character)
@(private = "file")
toast_copy :: proc(buf: []u8, text: string) -> int {
	n := min(len(text), len(buf))
	if n < len(text) { n = font.grapheme_prev(text, n + 1) }
	copy(buf, text[:n])
	return n
}

@(private = "file")
toast_add :: proc(kind: Toast_Kind, action: proc(user: rawptr), user: rawptr, msg: string, title := "") {
	s := gs()
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
	t.action, t.user = action, user
	t.len = toast_copy(t.text[:], msg)
	t.title_len = toast_copy(t.title[:], title)
	s.toast_serial += 1
	t.alive, t.kind, t.born_ms, t.life_ms, t.serial = true, kind, build_now_ms(), TOAST_LIFE_MS, s.toast_serial
}

toasts_clear :: proc() { for &t in gs().toasts { t.alive = false } }

// Builds the toast stack, at the end of every build (end_build): a program never forgets it, and a message it says
// (ui.announce) always shows. Look: panel background, a 1.5 px border all around tinted by the kind (info = accent,
// good / warn / bad), the icon in the same tint. Newest toast is nearest to the anchored edge; the others glide to
// their new place when one leaves.
@(private)
toasts_build :: proc() {
	s := gs()
	em := font_size()
	area := s.toast_area_set ? s.toast_area : Rect{{0, 0}, s.window_size}
	w := min(em * 26, (area.max.x - area.min.x) * 0.9)
	min_h, gap, margin := em * 3.0, em * 0.6, em * 1.1
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
	// each as tall as its lines (what its words took in the last layout; a new one the least, while it fades in)
	heights := make([]f32, n, context.temp_allocator)
	stack_h := f32(n - 1) * gap
	for idx, slot in order {
		words := s.boxes[key_from_string(key_from_string(s.root.key, fmt.tprintf("###toast_%d", s.toasts[idx].serial)), "###words")]
		heights[slot] = words != nil ? max(min_h, math.ceil(words.size.y + em * TOAST_PAD_Y_EM * 2)) : min_h
		stack_h += heights[slot]
	}
	before: f32   // the heights and gaps of the toasts nearer the anchored edge

	icons := [Toast_Kind]string{.Info = ICON_INFO, .Good = ICON_CHECK, .Warn = ICON_WARN, .Bad = ICON_WARN_BIG}
	tag := [Toast_Kind]string{.Info = "accent", .Good = "good", .Warn = "warn", .Bad = "bad"}
	clicked: proc(user: rawptr)   // (after the loop: it may queue a toast, in a slot this loop is reading)
	clicked_user: rawptr
	defer if clicked != nil { clicked(clicked_user) }
	for idx, slot in order {
		t := &s.toasts[idx]
		age := f32(s.time_ms - t.born_ms) / 1000
		life := f32(t.life_ms) / 1000
		ease, alpha: f32 = 1, 1
		if s.anim_rate != 0 {
			in_t := clamp(age / TOAST_FADE_IN_S, 0, 1)
			ease = 1 - (1 - in_t) * (1 - in_t) * (1 - in_t)
			alpha = min(ease, clamp((life - age) / TOAST_FADE_OUT_S, 0, 1))
			// frames while it fades; between the two nothing moves until the fade out
			holds := life - TOAST_FADE_OUT_S - age
			if age < TOAST_FADE_IN_S || holds <= 0 { s.anim_busy = true } else { wake_within(s, int(holds * 1000) + WAKE_MARGIN_MS) }
		} else {
			// no animation: just wake up when the oldest one expires
			left_ms := int((life - age) * 1000) + WAKE_MARGIN_MS
			wake_within(s, left_ms)
		}
		h := heights[slot]
		target_y: f32
		switch {
		case top:    target_y = area.min.y + margin + before
		case bottom: target_y = area.max.y - margin - h - before
		case:        target_y = (area.min.y + area.max.y - stack_h) * 0.5 + before
		}
		before += h + gap
		id := fmt.tprintf("###toast_%d", t.serial)
		key := key_from_string(s.root.key, id)
		y := anim(key_from_string(key, "y"), target_y, TOAST_GLIDE_RATE, target_y)
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
		s.next_mod.fixed_x, s.next_mod.fixed_y = x + dx, y + dy
		s.next_mod.fixed_w, s.next_mod.fixed_h = w, h
		s.next_mod.transparency = 1 - alpha
		s.next_mod.radius = em * 0.6
		s.next_mod.border = tint
		b := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Draw_Hot_Effects, .Clip}, id)
		b.cursor = .Hand
		if signal(b).clicked {
			t.alive = false
			clicked, clicked_user = t.action, t.user
		}
		// announced when it appears (a live region): a problem at once, the rest when the reader is free
		urgent := t.kind == .Bad || t.kind == .Warn
		said := t.title_len > 0 ? fmt.tprintf("%s: %s", string(t.title[:t.title_len]), string(t.text[:t.len])) : string(t.text[:t.len])
		a11y_default(b, {role = urgent ? .Alert : .Status, name = strings.clone(said, frame_allocator()), live = urgent ? .Assertive : .Polite, no_children = true})
		push_parent(b)
		spacer(px(em * 0.6))
		widget_icon(icons[t.kind], em * 1.8, tint)
		spacer(px(em * 0.4))
		// the words: a title on its line, the text under it on as many as it needs, centered in the toast
		next({width = fill(), height = children_sum(), axis = .Y})
		push_parent(build_box({}, "###words"))
		if t.title_len > 0 {
			st := top_style()
			next({width = fill(), height = text_size(), text_pad = 0, font = styled_face(st.font, true, false)})
			build_box({.Draw_Text}, fmt.tprintf("%s###title", string(t.title[:t.title_len])))
			spacer(px(em * 0.15))
			if t.len > 0 {
				push_tags("weak")
				next({width = fill(), height = text_size(), text_pad = 0})
				build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, fmt.tprintf("%s###msg", string(t.text[:t.len])))
				pop_tags()
			}
		} else {
			next({width = fill(), height = text_size(), text_pad = 0})
			build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, fmt.tprintf("%s###msg", string(t.text[:t.len])))
		}
		pop_parent()
		spacer(px(em * 0.8))
		pop_parent()
		pop_tags()   // floating (push_style_copy is popped with the style stack below)
		pop(&s.style_stack)
		pop_parent()
	}
}
////////////////////////////////
// Modal dialog

// `if modal("confirm", width, &open) { ... }`: dims the page, centers a panel, closes on a click outside or on Escape:
// what is inside it has Escape first (a focused field), and of several dialogs the one on top (opened last) takes it. It stays in
// the window: narrower than `width` if it must, and higher than `y_fraction` says when what is in it would go past the bottom.
//
// `if modal_sized("settings", preferred, &size, &open, min_size) { ... }`: a dialog of a size of its own, what is in it filling it
// (`height = fill()`). Centered and always within the window, however small; `preferred` is what it opens at (pixels), and the
// person resizes it by its edges and corners, the two sides moving together as it stays centered; a double click on one goes back
// to `preferred`. `size` is the application's to keep (logical pixels, {}: `preferred`): a smaller window does not change it.
// `top` (0..1, of the window's height): its top is held there instead (a command palette); its bottom edge follows the pointer.
@(private)
Modal_Scope :: struct {
	panel:   Key,
	order:   int,       // its place among this build's dialogs, from 1: what Tab goes by (Focus_Entry.modal)
	open:    ^bool,
	size:    ^Vec2,     // modal_sized: what the person chose
	preferred: Vec2,    // modal_sized: what a double click on an edge goes back to
	wh:      Vec2,      // its size in this frame
	lo, hi:  Vec2,      // how small and how large it may be, in this window
	top:     bool,      // modal_sized with `top`: its top stays where it is; its bottom follows the pointer (no grips at its top)
	corner_side:  f32,  // dialog_header with `close`: the side of the control in its top right corner (0: none)
	corner_inset: f32,  // and its margin from the dialog's top and right edges
	close:        bool, // dialog_header asked for a close button
	close_label:  string,
	corner_built: bool, // modal_corner built the corner's control (the program's own): the toolkit's is not built
}

// A dialog of this build or the last. `focus`: what had the focus when it opened, and gets it back when it closes.
// `shown`: it was drawn (its first build measures it unseen): what had the focus loses it then, as the dialog appears.
@(private)
Modal_Open :: struct {
	panel: Key,
	focus: Key,
	shown: bool,
}

// Where a dialog is, from the last build: not in it (the focus leaves the page for it), under another one, or the
// one on top (Escape is its own).
@(private)
Modal_Phase :: enum u8 { Opening, Below, Top }

@(private)
modal_phase :: proc(s: ^State, panel: Key) -> (phase: Modal_Phase, last: Modal_Open) {
	for m, i in s.modals_open {
		if m.panel == panel { return i == len(s.modals_open) - 1 ? .Top : .Below, m }
	}
	return .Opening, {}
}

// Escape was this dialog's in the last build (modals_settle): it closes now, by the `open` of this build.
@(private = "file")
modal_take_escape :: proc(s: ^State, id: string, open: ^bool) {
	if s.modal_escape == 0 || s.modal_escape != key_from_string(s.root.key, fmt.tprintf("###modal_%s", id)) { return }
	s.modal_escape = 0
	open^ = false
}

// A dialog of the last build that is not of this one has closed: what it took the focus from has it back, unless
// something else took it since (a focus inside the dialog is gone with it). Escape goes to the dialog on top at the end
// of the build: one that opened after the dialog that took the key is the one it closes.
@(private)
modals_settle :: proc(s: ^State) {
	s.modal_escape = 0
	if s.modal_escape_taken && len(s.modals_built) > 0 {
		s.modal_escape = s.modals_built[len(s.modals_built) - 1].panel
		s.anim_busy = true   // (the frame that closes it)
	}
	s.modal_escape_taken = false
	#reverse for m in s.modals_open {
		gone := true
		for b in s.modals_built { if b.panel == m.panel { gone = false; break } }
		if !gone || m.focus == 0 { continue }
		now := s.boxes[s.focus_key] or_else nil
		if now != nil && now.last_build == s.build_index { continue }
		back := s.boxes[m.focus] or_else nil
		if back == nil || back.last_build != s.build_index { continue }
		s.focus_key = m.focus
		s.anim_busy = true   // (the frame that shows it)
	}
}

MODAL_MARGIN_EM :: 1.0   // between a dialog and the edge of the window
@(private = "file") MODAL_EDGE_EM :: 0.4     // what takes a press along an edge (inside the dialog: the scrim is the rest)
@(private = "file") MODAL_CORNER_EM :: 0.9   // and in a corner

@(deferred_none = modal_end)
modal :: proc(id: string, width: f32, open: ^bool, y_fraction: f32 = 0.28) -> bool {
	s := gs()
	modal_take_escape(s, id, open)
	if !open^ {
		next_drop(s)
		append(&s.popup_stack, false)
		return false
	}
	margin := font_size() * MODAL_MARGIN_EM
	w := max(min(width, s.window_size.x - 2 * margin), 1)
	y := s.window_size.y * y_fraction
	// (from the height of the last frame: nothing is laid out yet. Its first build is not drawn (modal_begin): the frame
	// that shows it is already where it stays)
	if b := box_from_key(modal_key(s, id)); b != nil {
		y = max(min(y, s.window_size.y - b.size.y - margin), min(margin, y))
	}
	modal_begin(s, id, open, {(s.window_size.x - w) * 0.5, y}, {w, 0})
	return true
}

// `preferred.y` 0: as tall as what is in it (modal_content_height), within `min_size` and the window.
@(deferred_none = modal_end)
modal_sized :: proc(id: string, preferred: Vec2, size: ^Vec2, open: ^bool, min_size: Vec2 = {}, top: f32 = -1) -> bool {
	s := gs()
	modal_take_escape(s, id, open)
	if !open^ {
		next_drop(s)
		append(&s.popup_stack, false)
		return false
	}
	margin := font_size() * MODAL_MARGIN_EM
	hi := Vec2{max(s.window_size.x - 2 * margin, 1), max(s.window_size.y - 2 * margin, 1)}
	lo := Vec2{min(min_size.x, hi.x), min(min_size.y, hi.y)}
	pref := preferred
	if pref.y <= 0 {
		// (its first build, unseen, lays what is in it out in all the room there is; then it is as tall as that was)
		key := modal_key(s, id)
		phase, _ := modal_phase(s, key)
		panel := box_from_key(key)
		pref.y = phase != .Opening && panel != nil ? modal_content_height(panel) : hi.y
	}
	want := size^ != {} ? size^ * s.scale : pref
	wh := Vec2{math.round(clamp(want.x, lo.x, hi.x)), math.round(clamp(want.y, lo.y, hi.y))}
	y := math.round((s.window_size.y - wh.y) * 0.5)
	if top >= 0 {
		// held at `top` of the window's height, unless it would go past its bottom
		y = math.round(clamp(s.window_size.y * top, margin, max(s.window_size.y - margin - wh.y, margin)))
	}
	modal_begin(s, id, open, {math.round((s.window_size.x - wh.x) * 0.5), y}, wh)
	m := &s.modal_stack[len(s.modal_stack) - 1]
	m.size, m.preferred, m.wh, m.lo, m.hi, m.top = size, pref, wh, lo, hi, top >= 0
	// (its resize grip's corner is square, the grip's bevel filling it: a choice of the design, not a corner the rounding
	// forgot. Keep it square)
	if panel := box_from_key(m.panel); panel != nil { panel.square_corners = {.Bottom_Right} }
	return true
}

// The key of the panel of dialog `id`.
@(private = "file")
modal_key :: proc(s: ^State, id: string) -> Key { return key_from_string(s.root.key, fmt.tprintf("###modal_%s", id)) }

// The height of what is in a dialog (as the last build laid it out), its border counted: what fills it (`fill()`) counts as
// what it holds, a region that scrolls as all of its content. A modal_sized of `preferred.y` 0 is that tall.
@(private)
modal_content_height :: proc(panel: ^Box) -> f32 {
	natural :: proc(b: ^Box) -> f32 {
		if .View_Scroll_Y in b.flags { return b.view_bounds.y + border_inset(b) }   // (view_bounds has its top inset)
		if b.pref[.Y].kind != .Percent { return b.size.y }
		v: f32
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, .Y) { continue }
			h := natural(c)
			if b.layout_axis == .Y { v += h } else { v = max(v, h) }
		}
		return v + 2 * border_inset(b)
	}
	v: f32
	for c := panel.first; c != nil; c = c.next {
		if !is_floating(c, .Y) { v += natural(c) }
	}
	return math.ceil(v + 2 * border_inset(panel))
}

// How long a dialog takes to appear: its scrim and its panel fade in together.
@(private = "file") MODAL_FADE_MS :: 120

// The scrim and the panel at `at`, `wh` its size (a height of 0: that of what is in it). The build that opens it lays it out
// unseen and asks for the next frame at once: the first frame that shows it has it at its size and place, and what is in it
// laid out (a tall dialog moved up on its second frame, its content's own measures settled one frame late). Then the scrim
// and the panel fade in together (MODAL_FADE_MS; at once with animations off).
@(private = "file")
modal_begin :: proc(s: ^State, id: string, open: ^bool, at, wh: Vec2) {
	em := font_size()
	key := modal_key(s, id)
	phase, last := modal_phase(s, key)
	fade_key := key_from_string(key, "fade")
	shown: f32
	if phase == .Opening {
		_ = tween(fade_key, 0, 0)               // (from nothing, each time it opens)
		_ = tween(fade_key, 1, MODAL_FADE_MS)   // (its fade starts with the frame that shows it)
		s.anim_busy = true                      // (that frame now)
	} else {
		shown = tween(fade_key, 1, MODAL_FADE_MS)
	}
	push_parent(s.root)
	push_tags_isolated("floating")   // (a dialog is a dialog, whatever the tags where it is built)
	push_style_copy()

	// (what the app said with `a11y` is the panel's, not the scrim's)
	app_a11y, had_a11y := s.a11y.next, s.a11y.has_next
	s.a11y.has_next = false
	// scrim first, panel second: the panel is later in the tree, so it is on top and takes its own clicks
	push_tags("scrim")
	next({fixed_x = 0, fixed_y = 0, fixed_w = s.window_size.x, fixed_h = s.window_size.y, bg = color("background"), transparency = 1 - shown})
	scrim := build_box({.Clickable, .Draw_Background}, fmt.tprintf("###modal_scrim_%s", id))
	scrim.cursor = .Arrow
	a11y_default(scrim, {ignore = true})
	pop_tags()
	if signal(scrim).pressed { open^ = false }
	if had_a11y { a11y(app_a11y) }

	set_next_axis(.Y)
	s.next_mod.fixed_x = at.x
	s.next_mod.fixed_y = at.y
	s.next_mod.width = px(wh.x)
	s.next_mod.height = wh.y > 0 ? px(wh.y) : children_sum()
	s.next_mod.radius = DIALOG_RADIUS_EM * em
	s.next_mod.transparency = 1 - shown
	panel := build_box({.Clickable, .Press_Stop, .Draw_Background, .Draw_Border, .Draw_Shadow, .Plate}, fmt.tprintf("###modal_%s", id))
	panel.cursor = .Arrow
	_ = signal(panel)
	a11y_default(panel, {role = .Dialog, modal = true})
	push_parent(panel)
	append(&s.popup_stack, true)
	// keyboard: Tab cycles inside the dialog; what had the focus loses it while the dialog is open. Lost when the dialog
	// shows, not in its unseen build: the focus ring behind went one frame before the dialog came. (What the dialog's own
	// first build focused keeps it.)
	cur := last
	if phase == .Opening {
		cur = {panel = panel.key, focus = s.focus_key}
	} else if !cur.shown {
		if s.focus_key == cur.focus { s.focus_key = 0 }
		cur.shown = true
	}
	append(&s.modals_built, cur)
	append(&s.modal_stack, Modal_Scope{panel = panel.key, order = len(s.modals_built), open = open, wh = wh})
}

// A dialog's corners (before the rounding), in ems: what a strip across its top (dialog_top_draw) takes too.
DIALOG_RADIUS_EM :: 0.8

// The control in the top right corner of the dialog being built, whose dialog_header asked for one (`close`): a box of
// `flags`, a square, the same margin from the dialog's top and from its right edge, centered on the header, its corners
// concentric with the dialog's (corner_place; Fixed_Radius: `radius` is as drawn, its look draws it with that). The
// dialog's close button is one; a program's own look of it is another, built in the header's block (the toolkit's then
// is not built). What `next` said is kept, but for its place, its size and its radius.
modal_corner :: proc(flags: Box_Flags, id: string) -> ^Box {
	s := gs()
	assert(len(s.modal_stack) > 0, "modal_corner: outside a dialog")
	s.modal_stack[len(s.modal_stack) - 1].corner_built = true
	m := s.modal_stack[len(s.modal_stack) - 1]
	assert(m.corner_side > 0, "modal_corner: the dialog's header has no close control (dialog_header's `close`)")
	panel := box_from_key(m.panel)
	outer: f32 = .Top_Right in panel.square_corners ? 0 : box_drawn_radius(s, panel)
	side := m.corner_side
	r, radius := corner_place({{0, 0}, m.wh}, outer, .Top_Right, {side, side}, m.corner_inset)
	if radius < ROUND_LEAST_PX * max(1, s.scale) { radius = 0 }   // (as radius_drawn: a corner of a pixel or two is a blob)
	next_merge({fixed_x = r.min.x, fixed_y = r.min.y, width = px(side), height = px(side), radius = radius, flags = {.Fixed_Radius}})
	push_parent(panel)   // (its place is the dialog's, wherever it is built)
	defer pop_parent()
	return build_box(flags, id)
}

// What the press of a dialog's grip keeps (press_data): the size it started from, and whether it moved yet.
@(private = "file")
Modal_Grip_Press :: struct { from: Vec2, taken, moved: bool }

// The edges and corners of a dialog that is resized, over what is in it. It stays centered: a side moved by the pointer takes the
// opposite one along, so the size changes twice as fast as the pointer and the side stays under it.
@(private = "file")
modal_grips :: proc(s: ^State, m: Modal_Scope) {
	em := font_size()
	e, c := math.round(em * MODAL_EDGE_EM), math.round(em * MODAL_CORNER_EM)
	w, h, sc := m.wh.x, m.wh.y, s.scale
	Grip :: struct { dir: Vec2, cursor: platform.Cursor }
	grips := [8]Grip{
		{{0, -1}, .Resize_N}, {{0, 1}, .Resize_S}, {{-1, 0}, .Resize_W}, {{1, 0}, .Resize_E},
		{{-1, -1}, .Resize_NW}, {{1, -1}, .Resize_NE}, {{-1, 1}, .Resize_SW}, {{1, 1}, .Resize_SE},
	}
	for g, i in grips {
		if m.top && g.dir.y < 0 { continue }   // (its top stays: nothing to hold there)
		corner := g.dir.x != 0 && g.dir.y != 0
		t := corner ? c : e
		if g.dir == {1, 1} { t = c + RESIZE_GRIP_BEVEL_PAST_PX * sc }   // (the grip's bevel: all of it takes the press, with its cursor)
		// (a control in the top right corner holds it: the grips there stay within its margin, they are built after it)
		if m.corner_side > 0 && (g.dir == {1, -1} || g.dir == {0, -1} || g.dir == {1, 0}) { t = min(t, m.corner_inset) }
		gw := g.dir.x != 0 ? t : w - 2 * c
		gh := g.dir.y != 0 ? t : h - 2 * c
		gx := g.dir.x < 0 ? 0 : g.dir.x > 0 ? w - gw : c
		gy := g.dir.y < 0 ? 0 : g.dir.y > 0 ? h - gh : c
		next({fixed_x = gx, fixed_y = gy, width = px(gw), height = px(gh), cursor = g.cursor})
		b := build_box({.Clickable}, fmt.tprintf("###modal_grip%d", i))
		a11y_default(b, {ignore = true})
		sig := signal(b)
		if g.dir == {1, 1} { resize_grip_paint(b, sig) }
		press := press_data(Modal_Grip_Press, b.key)
		if press != nil && !press.taken { press^ = {from = {w, h}, taken = true} }
		if sig.double_clicked {
			m.size^ = {}
			// (the button is still down: a move from here starts at the size it went back to)
			if press != nil { press.from = {clamp(m.preferred.x, m.lo.x, m.hi.x), clamp(m.preferred.y, m.lo.y, m.hi.y)} }
			continue
		}
		if !sig.dragging || press == nil { continue }
		// (a press alone sets nothing: the size of this window, clamped, is not the person's)
		if sig.drag_delta == {} && !press.moved { continue }
		press.moved = true
		nw := g.dir.x != 0 ? clamp(press.from.x + 2 * g.dir.x * sig.drag_delta.x, m.lo.x, m.hi.x) : w
		// (centred, the opposite side moves too: twice the pointer; held at its top, the bottom alone follows it)
		nh := g.dir.y != 0 ? clamp(press.from.y + (m.top ? 1 : 2) * g.dir.y * sig.drag_delta.y, m.lo.y, m.hi.y) : h
		m.size^ = {nw / sc, nh / sc}
	}
}

@(private)
modal_end :: proc() {
	s := gs()
	if len(s.popup_stack) > 0 && s.popup_stack[len(s.popup_stack) - 1] {
		if top := &s.modal_stack[len(s.modal_stack) - 1]; top.close && !top.corner_built { dialog_close_button(top) }
		m := pop(&s.modal_stack)
		if m.size != nil { modal_grips(s, m) }
		// closed in this build (a button set its `open` false): it holds no key in the next one, where it is not built
		if m.open != nil && !m.open^ {
			for b, i in s.modals_built {
				if b.panel == m.panel { ordered_remove(&s.modals_built, i); break }
			}
		}
		phase, _ := modal_phase(s, m.panel)
		if phase != .Below && len(s.menus) == 0 && key_press_any(.Escape) { s.modal_escape_taken = true }
	}
	ctx_menu_end()
}

////////////////////////////////
// Menu bar

@(private = "file") MENU_BAR_KEY_SALT :: 0xbabe

// A menu bar entry. Returns the key to pass to `ctx_menu`. Clicking toggles the menu; while another bar menu is open,
// hovering switches to this one.
menu_bar_button :: proc(id: string) -> Key {
	s := gs()
	em := font_size()
	key := key_from_string(parent_box().key, id)
	menu_key := key_from_u64(key, MENU_BAR_KEY_SALT)
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
	return font.text_width(gs().fonts, f, size, text)
}
