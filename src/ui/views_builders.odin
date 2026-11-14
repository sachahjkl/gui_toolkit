package ui

// The presentations' builders (src/md/features/views.md, sections 2.5, 3.4 and 5): at the end of each build, the settle
// of every view, then the internal windows (back to front), then the dialogs (the last opened on top). Layers, from the
// bottom: the page, the internal windows, the dialogs, the menus, the toasts.

import "core:fmt"
import "core:math"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"

// What the press of a header or of an internal window's grip keeps (press_data): where the window was when it began.
@(private = "file")
// (cancelled: Escape ended its drag; the same press, still held, starts no other one)
View_Move_Press :: struct { from: Vec2, taken, cancelled: bool }
@(private = "file")
View_Grip_Press :: struct { from: Rect, taken: bool }

// end_build: the views of `s`.
@(private)
views_build :: proc(s: ^State) {
	// (a view's build may attach another Views to `s`: only these hold their records in place)
	n := len(s.views_attached)
	for vs in s.views_attached[:n] { vs.building += 1 }
	defer {
		for vs in s.views_attached[:n] { vs.building -= 1 }
		for vs in s.views_attached { views_sweep(vs) }
	}

	views_settle_all(s)
	// every view is built in the frame it opens, in every presentation of this window: its focus is there before the
	// next keys. The internal windows views_frame did not build (opened since, or no views_frame), then the panels opened
	// after their space was built (views_panels.odin)
	views_build_internals(s)
	views_build_late_panels(s)

	// the dialogs, in their order; a view opened by a view's build is built after it, in this build
	for vi := 0; vi < len(s.views_attached); vi += 1 {
		vs := s.views_attached[vi]
		for i := 0; i < len(vs.records); i += 1 {
			r := vs.records[i]
			if r.owner == s && view_builds_dialog(r.machine) { view_dialog_build(vs, r) }
		}
	}
	// while a view is dragged, the dock targets of the spaces built this frame, over everything
	views_build_targets(s)
	// (F6 last: only when nothing of the build took it; a dialog holds the keys, key_press says none then)
	views_f6_end(s)
	// a window refused between two frames (views_windows_step): said here, in a build of its owner
	for vs in s.views_attached {
		for r in vs.records {
			if r.owner != s || !r.announce { continue }
			r.announce = false
			toast_add(.Warn, nil, nil, i18n.tr("No window: the system refused it."))
		}
	}
}

// The settle of each view of `s`, once per build, before any is built: its old place and its new never show in one
// frame. views_frame does it first; end_build again, for what opened since (each view settles once per build).
@(private)
views_settle_all :: proc(s: ^State) {
	for vi := 0; vi < len(s.views_attached); vi += 1 {
		vs := s.views_attached[vi]
		for r in vs.records {
			if r.owner != s || r.machine.state == .Closed || r.settled_build == s.build_index { continue }
			r.settled_build = s.build_index
			view_settle(vs, r)
		}
	}
}

// The internal windows of `s`, back to front; a press on one brings it to the front first.
@(private)
views_build_internals :: proc(s: ^State) {
	n := len(s.views_attached)
	Internal :: struct { vs: ^Views, r: ^View_Record, unseen: bool }
	internals := make([dynamic]Internal, 0, 4, context.temp_allocator)
	for vs in s.views_attached[:n] {
		for r in vs.records {
			// (each once per build: views_frame's, then end_build's for what opened since)
			if r.owner != s || r.ibuilt == s.build_index { continue }
			yes, unseen := view_builds_internal(r.machine)
			// (a panel whose space is not built: a floating window until it is, at once)
			if !yes && view_builds_panel(r.machine) && r.pbuilt != s.build_index && view_panel_floats(vs, r, s) { yes, unseen = true, false }
			if yes { append(&internals, Internal{vs, r, unseen}) }
		}
	}
	if mouse_pressed(.Left) {
		top: ^Internal
		for &x in internals {
			f := s.boxes[x.r.iframe] or_else nil
			if x.unseen || f == nil || !rect_has(f.rect, mouse_pos()) { continue }
			if top == nil || x.r.z > top.r.z { top = &x }
		}
		if top != nil { view_raise(top.vs, top.r) }
	}
	for i in 1 ..< len(internals) {   // (a few windows: insertion by z)
		x := internals[i]
		j := i - 1
		for j >= 0 && internals[j].r.z > x.r.z { internals[j + 1] = internals[j]; j -= 1 }
		internals[j + 1] = x
	}
	for x in internals {
		if x.r.machine.state != .Closed { view_internal_build(x.vs, x.r, x.unseen) }
	}
}

@(private = "file")
rect_has :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }

// Where a view is built this frame as an internal window, and whether unseen (measured before it shows).
@(private)
view_builds_internal :: proc(m: View_Machine) -> (yes, unseen: bool) {
	#partial switch m.state {
	case .Opening:          return view_built_as(m.as) == .Internal, true
	case .Shown, .Dragged:  return view_built_as(m.as) == .Internal, false
	case .Moving:
		if view_built_as(m.from) == .Internal { return true, false }
		return view_built_as(m.as) == .Internal, true
	}
	return false, false
}

// Whether a view is built this frame as a dialog (unseen or not: the modal's own measure says).
@(private)
view_builds_dialog :: proc(m: View_Machine) -> bool {
	#partial switch m.state {
	case .Opening, .Shown, .Dragged: return view_built_as(m.as) == .Dialog
	case .Moving: return view_built_as(m.from) == .Dialog || view_built_as(m.as) == .Dialog
	}
	return false
}

// A view that opens or moves settles here, from the last layout: a dialog when its modal shows, an internal window when
// its layout is the same two builds in a row (or after MODAL_MEASURES_MAX), a move between two presentations built
// alike at once.
@(private = "file")
view_settle :: proc(vs: ^Views, r: ^View_Record) {
	s := gs()
	m := r.machine
	if m.state != .Opening && m.state != .Moving { return }
	if m.state == .Moving && view_built_as(m.as) == view_built_as(m.from) {
		view_apply(vs, r, {kind = .Settled})
		view_space_activate(vs, r)   // (a panel to another zone: its tab is the one shown there)
		return
	}
	switch view_built_as(m.as) {
	case .Dialog:
		// (Ready: this build shows it; the old place is not built in it)
		phase, last := modal_phase(s, modal_key(s, r.modal_name))
		if phase != .Opening && last.show != .Measuring { view_apply(vs, r, {kind = .Settled}) }
	case .Internal:
		s.anim_busy = true   // (each unseen build at once)
		f := s.boxes[r.iframe] or_else nil
		if f == nil || f.last_build + 1 != s.build_index { return }
		sig := modal_layout_signature(f)
		settled := r.imeasures > 0 && sig == r.ilayout
		r.ilayout = sig
		r.imeasures += 1
		if !settled && r.imeasures < MODAL_MEASURES_MAX { return }
		r.imeasures, r.ilayout = 0, 0
		// (as tall as what is in it, its first time: its height is the one it settled at)
		if r.irect.max.y <= r.irect.min.y { r.irect.max.y = r.irect.min.y + (f.rect.max.y - f.rect.min.y) }
		if m.state == .Moving && view_built_as(m.from) == .Dialog {
			// (what the dialog took the focus from gets it back when the window closes)
			if _, last := modal_phase(s, modal_key(s, r.modal_name)); last.focus != 0 { r.focus_back = last.focus }
		}
		view_apply(vs, r, {kind = .Settled})
	case .Panel:
		// (a panel's size is its zone's: nothing to measure; in a space not built, it waits there, Shown)
		s.anim_busy = true   // (settled after its space was built: the next build shows it)
		view_apply(vs, r, {kind = .Settled})
		view_space_activate(vs, r)
	case .External:
		// (no backend: nothing will open a window, refused now: it floats inside its owner, or stays where it was)
		if !views_windows_ready(vs) {
			view_apply(vs, r, {kind = .Window_Refused})
			return
		}
		// (its window shown, and a frame of it drawn since: the old place goes in this build; until then it shows)
		s.anim_busy = true
		if w := r.w_state; w != nil && r.w_shown_build != 0 && w.build_index > r.w_shown_build {
			view_apply(vs, r, {kind = .Settled})
		}
	}
}

////////////////////////////////
// What floats over a view

// A view that floats over the window's content: where it is (window px, as the last layout made it), its layer (0: an
// internal window, 1: a dialog) and its place in that layer (an internal window's z; a dialog's rank, the top last).
@(private = "file")
View_Floating :: struct {
	rect:  Rect,
	r:     ^View_Record,
	layer: int,
	order: u64,
}

@(private = "file")
views_floating :: proc(vs: ^Views, s: ^State, allocator := context.temp_allocator) -> [dynamic]View_Floating {
	out := make([dynamic]View_Floating, 0, 4, allocator)
	for r, i in vs.records {
		if r.owner != s || r.machine.state == .Closed { continue }
		p := view_shown_in(r.machine)
		if p != .Internal && p != .Dialog { continue }
		b := s.boxes[r.roots[p]] or_else nil
		// (built in the last build or this one, and seen: one measured unseen covers nothing yet)
		if b == nil || r.roots[p] == 0 || b.last_build + 1 < s.build_index || b.transparency >= 1 { continue }
		append(&out, View_Floating{rect = b.rect, r = r, layer = p == .Dialog ? 1 : 0, order = p == .Dialog ? u64(i) : r.z})
	}
	// (bottom to top: a few at most, an insertion)
	for i in 1 ..< len(out) {
		x := out[i]
		j := i - 1
		for j >= 0 && (out[j].layer > x.layer || (out[j].layer == x.layer && out[j].order > x.order)) { out[j + 1] = out[j]; j -= 1 }
		out[j + 1] = x
	}
	return out
}

// The rects of the views of `vs` that float over the content of window `s`: its internal windows and its dialogs shown,
// bottom to top, in window pixels as the last layout made them. A page under a native child window (a web view, which
// the toolkit cannot draw over) steps aside from them or clips to them.
views_floating_rects :: proc(vs: ^Views, s: ^State, allocator := context.temp_allocator) -> []Rect {
	all := views_floating(vs, s, context.temp_allocator)
	out := make([]Rect, len(all), allocator)
	for f, i in all { out[i] = f.rect }
	return out[:]
}

// Inside a build: the rects of the views that float over `v` where it is now (window pixels of the State it is built
// in, as the last layout made them): over the content or a panel, every internal window and dialog; over an internal
// window, those above it and the dialogs; over a dialog, the dialogs above it; in a window of its own, its own window's
// floating views (its dialogs). A view with a native child window clips or moves it by them.
view_occluders :: proc(v: ^View, allocator := context.temp_allocator) -> []Rect {
	r := v.record
	s := gs()
	all := views_floating(r.vs, s, context.temp_allocator)
	out := make([dynamic]Rect, 0, len(all), allocator)
	at := -1   // (its own place among them: what is above it covers it)
	for f, i in all { if f.r == r { at = i } }
	for f, i in all {
		if at >= 0 && i <= at { continue }
		append(&out, f.rect)
	}
	return out[:]
}

// It comes to the front of the internal windows.
@(private)
view_raise :: proc(vs: ^Views, r: ^View_Record) {
	vs.z_next += 1
	r.z = vs.z_next
}

////////////////////////////////
// The Dialog presentation

// The view as a dialog: the toolkit's modal (its first frames measured unseen, its fade, its grips, Escape and the
// scrim), the header strip, then the body.
@(private = "file")
view_dialog_build :: proc(vs: ^Views, r: ^View_Record) {
	s := gs()
	k := r.kind
	key := modal_key(s, r.modal_name)
	o := Modal_Options{width_em = k.o.width_em, height_em = k.o.height_em, min_width_em = k.o.min_width_em, min_height_em = k.o.min_height_em, top = k.o.top}
	// (view_size of this opening: a non-resizable dialog of a width asked past DIALOG_MAX_WIDTH_EM keeps it, modal's `most`)
	if r.asked.x > 0 { o.width_em = r.asked.x }
	if r.asked.y > 0 { o.height_em = r.asked.y }
	if r.dialog_back {
		// (a drag of its header cancelled: it was laid out a moment ago, at this rect; it shows in this build, with no
		// unseen layout, where it was)
		r.dialog_back = false
		scrim := key_from_string(s.root.key, fmt.tprintf("###modal_scrim_%s", r.modal_name))
		append(&s.modals_open, Modal_Open{panel = key, scrim = scrim, focus = r.focus_back, show = .Ready, measures = MODAL_MEASURES_MAX})
		o.first_h = r.dialog_rect.max.y - r.dialog_rect.min.y
	}
	phase, last := modal_phase(s, key)
	r.flag, r.ending, r.tools, r.header = true, nil, 0, 0
	if k.o.resizable { o.size = &r.size }
	v := View{id = k.id, instance = r.instance, presentation = .Dialog, place = r.machine.place, record = r}
	v.shown = phase != .Opening && (last.show == .Showing || last.show == .Shown)
	if modal(r.modal_name, &r.flag, o) {
		r.panel = parent_box().key
		r.roots[.Dialog] = r.panel
		if k.o.backdrop != nil { k.o.backdrop(&v, r.data) }
		if !k.o.no_header { view_header_begin(vs, r, .Dialog) }
		k.build(&v, r.data)
		if !k.o.no_header { view_header_end(vs, r, .Dialog) }
		// (Ctrl+W closes the dialog on top, as Escape does)
		if r.flag && r.ending == nil && phase == .Top && key_press(.W, {.Ctrl}) { r.flag = false }
	}
	view_build_ended(vs, r)
	if r.machine.state == .Closed { return }
	// (the size the user gave it, kept once the grip is let go)
	if k.o.resizable && r.size != r.size_kept && s.active_key[.Left] == 0 {
		m := views_memory_of(vs, k.id)
		m.dialog = r.size
		views_memory_write(vs, k.id, m)
		r.size_kept = r.size
	}
}

// After a build: view_end's answer, or the user's close (Escape, the scrim, a close button, the menu).
@(private)
view_build_ended :: proc(vs: ^Views, r: ^View_Record) {
	if code, ended := r.ending.?; ended {
		view_apply(vs, r, {kind = .End, code = code})
	} else if !r.flag {
		view_apply(vs, r, {kind = .User_Close})
	}
}

////////////////////////////////
// The Internal presentation

// The view as an internal window: a floating frame of the owner window, the header strip (it moves the window), the
// body, the grips of its edges and corners. Unseen: built at its place, not drawn, taking no input of its own.
@(private)
view_internal_build :: proc(vs: ^Views, r: ^View_Record, unseen: bool) {
	s := gs()
	k := r.kind
	em := font_size()
	r.flag, r.ending, r.tools, r.header = true, nil, 0, 0
	rect := view_internal_place(vs, r, em)
	w, h := rect.max.x - rect.min.x, rect.max.y - rect.min.y
	title := view_title_shown(r)

	push_parent(s.root)
	push_tags_isolated("floating")   // (a window is a window, whatever the tags where it is built)
	push_style_copy()
	next({fixed_x = rect.min.x, fixed_y = rect.min.y, width = px(w), height = h > 0 ? px(h) : children_sum(), axis = .Y,
		radius = DIALOG_RADIUS_EM * em, transparency = unseen ? 1 : 0})
	frame := build_box({.Clickable, .Press_Stop, .Draw_Background, .Draw_Border, .Draw_Shadow, .Plate, .Clip}, fmt.tprintf("###internal_%s", r.modal_name))
	frame.cursor = .Arrow
	frame.square_corners = {.Bottom_Right}   // (the grip's corner, as a floating panel's)
	_ = signal(frame)
	a11y_default(frame, {role = .Dialog, name = title, role_description = i18n.tr("floating window")})
	r.iframe, r.panel = frame.key, frame.key
	r.roots[.Internal] = frame.key
	r.ibuilt = s.build_index
	view_input_arrive(r, !unseen)   // (a window of its own refused: the keys held for it are this one's)
	push_parent(frame)
	v := View{id = k.id, instance = r.instance, presentation = .Internal, place = r.machine.place, shown = !unseen, record = r}
	if k.o.backdrop != nil { k.o.backdrop(&v, r.data) }
	// (an internal window always has its header: it is what moves it, whatever a dialog of `no_header` draws)
	view_header_begin(vs, r, .Internal)
	next({width = fill(), height = h > 0 ? fill() : children_sum(), axis = .Y})
	body := build_box({.Clip}, "###view_body")
	push_parent(body)
	// (its keys only while the focus is in it: section 6.5)
	keys_root := s.view_keys_root
	s.view_keys_root = r.iframe
	k.build(&v, r.data)
	s.view_keys_root = keys_root
	pop_parent()
	view_header_end(vs, r, .Internal)
	if !unseen { view_internal_grips(r, frame, w, h, em) }
	pop_parent()   // frame
	pop(&s.style_stack)
	pop_tags_isolated()
	pop_parent()   // root

	if !unseen {
		// (its keys while the focus is in it: Escape and Ctrl+W close it; a dialog on top holds them)
		inside := view_focus_inside(s, r.iframe)
		if inside && r.flag && r.ending == nil && (key_press(.Escape) || key_press(.W, {.Ctrl})) { r.flag = false }
		if r.focus_in {
			r.focus_in = false
			if !inside { if first := view_first_stop(s.boxes[r.iframe] or_else nil); first != 0 { s.focus_key = first } }
		}
	} else {
		s.anim_busy = true
	}
	view_build_ended(vs, r)
	if r.machine.state == .Closed { return }
	// (its rect, kept once a move or a resize is let go: logical pixels)
	if !unseen && r.irect != r.irect_kept && s.active_key[.Left] == 0 && r.irect.max.y > r.irect.min.y {
		m := views_memory_of(vs, k.id)
		sc := max(s.scale, 0.01)
		m.internal = {i32(math.round(r.irect.min.x / sc)), i32(math.round(r.irect.min.y / sc)), i32(math.round((r.irect.max.x - r.irect.min.x) / sc)), i32(math.round((r.irect.max.y - r.irect.min.y) / sc))}
		views_memory_write(vs, k.id, m)
		r.irect_kept = r.irect
	}
}

// Where the internal window is this frame, in window pixels: its rect (what the user made it), else the memory's, else
// centred at its width, as tall as what is in it (a height of 0). Kept inside the window, the rect itself unchanged.
@(private = "file")
view_internal_place :: proc(vs: ^Views, r: ^View_Record, em: f32) -> Rect {
	s := gs()
	win := s.window_size
	if r.irect == {} {
		m := views_memory_of(vs, r.kind.id)
		if m.internal[2] > 0 {
			sc := s.scale
			r.irect = {{f32(m.internal[0]) * sc, f32(m.internal[1]) * sc}, {f32(m.internal[0] + m.internal[2]) * sc, f32(m.internal[1] + m.internal[3]) * sc}}
			r.irect_kept = r.irect
		} else {
			w := math.round((r.kind.o.width_em > 0 ? r.kind.o.width_em : DIALOG_WIDTH_EM) * em)
			hh := math.round(r.kind.o.height_em * em)
			x := math.round((win.x - w) * 0.5)
			y := math.round(win.y * VIEW_INTERNAL_TOP)
			r.irect = {{x, y}, {x + w, y + hh}}
		}
	}
	rect := r.irect
	w := min(rect.max.x - rect.min.x, win.x)
	h := min(rect.max.y - rect.min.y, win.y)
	x := clamp(rect.min.x, 0, max(win.x - w, 0))
	y := clamp(rect.min.y, 0, max(win.y - max(h, em * DIALOG_HEADER_EM), 0))
	return {{x, y}, {x + w, y + max(h, 0)}}
}

// Where an internal window of no rect opens: its top at this share of the window's height.
@(private = "file") VIEW_INTERNAL_TOP :: 0.15

// The edges and corners of an internal window: the side held follows the pointer, the opposite one stays.
@(private = "file")
view_internal_grips :: proc(r: ^View_Record, frame: ^Box, w, h, em: f32) {
	e, c := math.round(em * 0.4), math.round(em * 0.9)
	lo := DOCK_FLOAT_MIN_EM * em
	Grip :: struct { dir: Vec2, cursor: platform.Cursor }
	grips := [8]Grip{
		{{0, -1}, .Resize_N}, {{0, 1}, .Resize_S}, {{-1, 0}, .Resize_W}, {{1, 0}, .Resize_E},
		{{-1, -1}, .Resize_NW}, {{1, -1}, .Resize_NE}, {{-1, 1}, .Resize_SW}, {{1, 1}, .Resize_SE},
	}
	if h <= 0 { return }   // (as tall as what is in it, until its first settled layout)
	for g, i in grips {
		corner := g.dir.x != 0 && g.dir.y != 0
		t := corner ? c : e
		if g.dir == {1, 1} { t = c + RESIZE_GRIP_BEVEL_PAST_PX * scale() }
		if g.dir.y < 0 { t = min(t, e) }   // (the top's grips stay thin: the header under them moves the window)
		gw := g.dir.x != 0 ? t : w - 2 * c
		gh := g.dir.y != 0 ? t : h - 2 * c
		gx := g.dir.x < 0 ? 0 : g.dir.x > 0 ? w - gw : c
		gy := g.dir.y < 0 ? 0 : g.dir.y > 0 ? h - gh : c
		next({fixed_x = gx, fixed_y = gy, width = px(gw), height = px(gh), cursor = g.cursor})
		b := build_box({.Clickable}, fmt.tprintf("###view_grip%d", i))
		a11y_default(b, {ignore = true})
		sig := signal(b)
		if g.dir == {1, 1} { resize_grip_paint(b, sig) }
		p := press_data(View_Grip_Press, b.key)
		if p != nil && !p.taken { p^ = {from = r.irect, taken = true} }
		if !sig.dragging || p == nil { continue }
		nr, d := p.from, sig.drag_delta
		if g.dir.x < 0 { nr.min.x = min(p.from.min.x + d.x, p.from.max.x - lo.x) }
		if g.dir.x > 0 { nr.max.x = max(p.from.max.x + d.x, p.from.min.x + lo.x) }
		if g.dir.y < 0 { nr.min.y = min(p.from.min.y + d.y, p.from.max.y - lo.y) }
		if g.dir.y > 0 { nr.max.y = max(p.from.max.y + d.y, p.from.min.y + lo.y) }
		r.irect = {{math.round(nr.min.x), math.round(nr.min.y)}, {math.round(nr.max.x), math.round(nr.max.y)}}
	}
}

// Whether the focus is on a box under `root` (as the last build laid them out).
@(private)
view_focus_inside :: proc(s: ^State, root: Key) -> bool {
	if root == 0 || s.focus_key == 0 { return false }
	for b := s.boxes[s.focus_key] or_else nil; b != nil; b = b.parent {
		if b.key == root { return true }
	}
	return false
}

// The first stop of Tab under `b` (0: none).
@(private)
view_first_stop :: proc(b: ^Box) -> Key {
	if b == nil { return 0 }
	if .Focusable in b.flags && .Disabled not_in b.flags { return b.key }
	for c := b.first; c != nil; c = c.next {
		if k := view_first_stop(c); k != 0 { return k }
	}
	return 0
}

////////////////////////////////
// The header: two steps

// The title, as this opening shows it: view_title's, a ready-made view's, else the kind's.
@(private)
view_title_shown :: proc(r: ^View_Record) -> string {
	return r.title != "" ? r.title : i18n.tr(r.kind.o.title)
}

// The first step, before the body: the strip, its icon and its title (never cut: it wraps). The buttons come after the
// body (view_header_end), and the box of the program's tools only if the body asks for it (view_header_tools).
@(private)
view_header_begin :: proc(vs: ^Views, r: ^View_Record, p: View_Presentation) {
	s := gs()
	em := font_size()
	k := r.kind
	labels := view_labels(vs)
	title := view_title_shown(r)
	// (a ready-made view's icon for this opening is Lucide's)
	icon := r.icon != "" ? r.icon : k.o.icon
	icon_font := k.o.icon_font != 0 ? k.o.icon_font : s.icon_font
	if r.icon_set {
		if r.icon_font != 0 { icon_font = r.icon_font }   // (view_icon's, in its font)
	} else if r.icon != "" {
		icon_font = lucide_icons()   // (a ready-made view's)
	}
	panel := parent_box()
	h := math.round(dense(em * DIALOG_HEADER_EM))
	if p == .Dialog {
		// (the close cross in the dialog's corner, the same margin from its top and right edges: modal_end builds it)
		m := &s.modal_stack[len(s.modal_stack) - 1]
		border := border_inset(box_from_key(m.panel))
		m.corner_side = math.round(min(em * DIALOG_CLOSE_EM, h))
		m.corner_inset = border + math.round((h - m.corner_side) * 0.5)
		m.close, m.close_label = true, labels.close
	}
	shade := frame_new(Color)
	shade^ = srgb_step(panel.bg, {0, 0, 0, panel.bg.a}, DIALOG_HEADER_DARKEN)
	tall := children_sum()
	tall.least = h
	next({width = fill(), height = tall, radius = 0, axis = .X, cross = .Center})
	b := build_box({.Clickable}, "###view_header")   // (Clickable: it is dragged; its right click opens its menu)
	b.custom, b.custom_user = top_strip_draw, shade
	a11y_default(b, {role = .Heading, name = title})
	r.header = b.key
	push_parent(b)
	spacer(px(em * 1.0))
	if icon != "" {
		next({width = px(em * 1.4), height = px(h), font = icon_font, font_size = em * 1.1, text_align = .Center, text_pad = 0, fg = color("accent")})
		build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###view_header_icon", icon))
		spacer(px(em * 0.55))
	}
	// (its width is its words on one line: a dialog grows to it, up to its most, then it wraps)
	next({width = text_size(), height = text_size(math.round(em * DIALOG_TITLE_MARGIN_EM)), font_size = em * 1.05, text_pad = 0, text_align = .Left})
	build_box({.Draw_Text, .Text_Wrap, .No_Text_Trunc}, fmt.tprintf("%s###view_header_title", text_shown(title)))
	spacer(fill())
	pop_parent()
}

// The second step, after the body: the buttons of this presentation, its drag, its menu.
@(private)
view_header_end :: proc(vs: ^Views, r: ^View_Record, p: View_Presentation) {
	s := gs()
	em := font_size()
	hb := box_from_key(r.header)
	if hb == nil || r.header == 0 { return }
	labels := view_labels(vs)
	at_home := view_machine_at_home(r.machine) && r.machine.state != .Dragged
	push_parent(hb)
	switch p {
	case .Dialog:
		if view_header_icon("view_detach", lucide.PICTURE_IN_PICTURE_2, labels.floating, true) { view_float(vs, r) }
		dialog_header_end()   // (clear of the close cross; pops the strip)
	case .Internal:
		if !at_home && view_header_icon("view_reattach", lucide.UNDO_2, labels.reattach, true) { view_apply(vs, r, {kind = .Reattach}) }
		if view_header_icon("view_window", lucide.EXTERNAL_LINK, labels.window, views_windows_ready(vs)) {
			view_apply(vs, r, {kind = .Present, as = .External})
		}
		if view_header_icon("view_close", lucide.X, labels.close, true) { r.flag = false }
		spacer(px(em * 0.5))
		pop_parent()
	case .External:
		view_window_header_buttons(vs, r, at_home)
		spacer(px(em * 0.5))
		pop_parent()
	case .Panel:
		pop_parent()
	}
	if p == .External {
		// (its own drag: the window of the system follows the pointer, where the system tells positions)
		sig := signal(hb)
		view_window_header_drag(vs, r, hb, sig, em)
		if sig.right_clicked { menu_open(view_menu_id(r), mouse_pos(), hb.key, search = false) }
		view_header_menu(vs, r, p)
		return
	}

	// the drag: a dialog's header detaches it under the pointer; an internal window's moves it
	if p == .Internal && r.hand_from != 0 {
		// (the press of the dialog's header goes on here: the same gesture)
		// (from where the dialog was when the press began: the pointer may have moved since the threshold)
		if press_hand(r.hand_from, hb.key) {
			if pd := press_data(View_Move_Press, hb.key); pd != nil { pd^ = {from = r.hand_origin, taken = true} }
		}
		r.hand_from = 0
	}
	if p == .Internal && r.machine.state == .Dragged {
		if s.active_key[.Left] != hb.key {
			// released: on a dock target, a panel there (built from the next frame: the window shows this one);
			// elsewhere, an internal window where it is
			if target, ok := view_target_at(s, mouse_pos()); ok {
				view_target_drop(vs, r, target)
			} else if view_drop_outside(vs, r) {
				// (outside the window, where the system says so: a window of its own there; this one shows until it does)
			} else {
				view_apply(vs, r, {kind = .Drop, as = .Internal})
				view_raise(vs, r)
				r.focus_in = true
			}
		} else if key_press(.Escape) {
			// back where it was, nothing remembered: a dialog shows in this build at its rect, the window is not drawn; a
			// panel shows from the next frame, the window drawn in this one
			from := r.machine.from
			view_apply(vs, r, {kind = .Drag_Cancel})
			r.irect = r.irect_kept
			if pd := press_data(View_Move_Press, hb.key); pd != nil { pd.cancelled = true }
			if from == .Dialog {
				r.dialog_back = true
				if f := box_from_key(r.iframe); f != nil { f.transparency = 1 }
			}
		}
	}
	sig := signal(hb)
	if sig.dragging {
		if pd := press_data(View_Move_Press, hb.key); pd != nil {
			if !pd.taken { pd^ = {from = r.irect.min, taken = true} }
			d := sig.drag_delta
			if p == .Dialog && r.machine.state == .Shown && math.sqrt(d.x * d.x + d.y * d.y) >= DOCK_DRAG_EM * em {
				// past the threshold: an internal window at the dialog's place, moved by the pointer from now on
				if panel := box_from_key(r.panel); panel != nil {
					r.irect = {panel.rect.min + d, panel.rect.max + d}
					r.hand_from, r.hand_origin, r.dialog_rect = hb.key, panel.rect.min, panel.rect
					// (what the dialog took the focus from: the window gives it back, or the dialog if the drag is cancelled)
					if _, last := modal_phase(s, modal_key(s, r.modal_name)); last.focus != 0 { r.focus_back = last.focus }
					view_apply(vs, r, {kind = .Drag_Start})
				}
			} else if p == .Internal && view_built_as(r.machine.as) == .Internal && !pd.cancelled {
				size := r.irect.max - r.irect.min
				at := Vec2{math.round(pd.from.x + d.x), math.round(pd.from.y + d.y)}
				r.irect = {at, at + size}
				// (past the threshold, a drag: the dock targets show; its release docks it or leaves it where it is)
				if r.machine.state == .Shown && math.sqrt(d.x * d.x + d.y * d.y) >= DOCK_DRAG_EM * em {
					r.irect_kept = {pd.from, pd.from + size}
					view_apply(vs, r, {kind = .Drag_Start})
				}
			}
		}
	}
	if sig.right_clicked { menu_open(view_menu_id(r), mouse_pos(), hb.key, search = false) }
	view_header_menu(vs, r, p)
}

// A small icon button of a header, in the weak colour. `active` false: drawn, not clickable.
@(private)
view_header_icon :: proc(id, glyph, label: string, active: bool) -> (clicked: bool) {
	em := font_size()
	side := math.round(em * VIEW_DETACH_EM)
	spacer(px(em * 0.3))
	push_tags("ghost_button", "button", "weak")
	defer pop_tags()
	flags := Box_Flags{.Draw_Text, .No_Text_Trunc}
	if active { flags += {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects} } else { flags += {.Disabled} }
	next({width = px(side), height = px(side), font = lucide_icons(), font_size = em * 0.85, text_pad = 0, text_align = .Center, radius = em * 0.3})
	b := build_box(flags, fmt.tprintf("%s###%s", glyph, id))
	a11y_default(b, {role = .Button, name = label})
	sig := signal(b)
	if active && hovered_for(sig) { if tooltip() { tooltip_text(label) } }
	return active && sig.clicked
}

@(private)
view_menu_id :: proc(r: ^View_Record) -> string { return fmt.tprintf("###view_menu_%s", r.modal_name) }

// The header's right-click menu: the same acts in every presentation (src/md/features/views.md, section 2.5).
@(private)
view_header_menu :: proc(vs: ^Views, r: ^View_Record, p: View_Presentation) {
	if menu(view_menu_id(r)) { view_header_menu_items(vs, r, p) }
}

@(private = "file")
view_header_menu_items :: proc(vs: ^Views, r: ^View_Record, p: View_Presentation) {
	labels := view_labels(vs)
	if p != .External {
		if menu_item(fmt.tprintf("%s###vm_window", labels.window), icon = lucide.EXTERNAL_LINK, icon_font = lucide_icons(), disabled = !views_windows_ready(vs)).clicked {
			view_apply(vs, r, {kind = .Present, as = .External})
		}
	}
	if p != .Internal {
		if menu_item(fmt.tprintf("%s###vm_float", labels.floating), icon = lucide.PICTURE_IN_PICTURE_2, icon_font = lucide_icons()).clicked { view_float(vs, r) }
	}
	// (the frame's edges, when the owner window has a frame space: views_frame)
	no_frame := !view_frame_built(vs, r.owner)
	Dock_Item :: struct { edge: View_Edge, word, glyph, id: string }
	items := [3]Dock_Item{{.Left, labels.dock_left, lucide.PANEL_LEFT, "vm_left"}, {.Right, labels.dock_right, lucide.PANEL_RIGHT, "vm_right"}, {.Bottom, labels.dock_bottom, lucide.PANEL_BOTTOM, "vm_bottom"}}
	for it in items {
		here := p == .Panel && r.machine.place.space == "" && r.machine.place.edge == it.edge
		if here { continue }
		if menu_item(fmt.tprintf("%s###%s", it.word, it.id), icon = it.glyph, icon_font = lucide_icons(), disabled = no_frame).clicked {
			view_dock_at(vs, r, it.edge)
		}
	}
	menu_separator()
	if !view_machine_at_home(r.machine) {
		if menu_item(fmt.tprintf("%s###vm_reattach", labels.reattach), icon = lucide.UNDO_2, icon_font = lucide_icons()).clicked { view_apply(vs, r, {kind = .Reattach}) }
	}
	if menu_item(fmt.tprintf("%s###vm_close", labels.close), icon = lucide.X, icon_font = lucide_icons()).clicked {
		// (a panel's menu is built after its body, past the check of its flag; a tab not shown is not built at all)
		if p == .Panel { view_apply(vs, r, {kind = .User_Close}) } else { r.flag = false }
	}
}

// Open as a floating window: Internal, at its last rect, else where the dialog is now.
@(private)
view_float :: proc(vs: ^Views, r: ^View_Record) {
	// (an external window's rect is its own window's, not the owner's: the memory's, else centred)
	if r.irect == {} && views_memory_of(vs, r.kind.id).internal[2] <= 0 && r.machine.as != .External {
		if panel := box_from_key(r.panel); panel != nil && r.panel != 0 {
			r.irect = panel.rect
			// (a panel can be the window's height: a floating window of it is the dock's default size at most)
			if r.machine.as == .Panel {
				most := DOCK_FLOAT_DEFAULT_EM * font_size()
				r.irect.max = r.irect.min + {min(r.irect.max.x - r.irect.min.x, most.x), min(r.irect.max.y - r.irect.min.y, most.y)}
			}
		}
	}
	view_apply(vs, r, {kind = .Present, as = .Internal})
}

// The words of the views' header and menu, in the language in use.
@(private)
view_labels :: proc(vs: ^Views) -> View_Labels {
	d := view_default_labels()
	l := vs.labels
	if l.detach == "" { l.detach = d.detach }
	if l.close == "" { l.close = d.close }
	if l.reattach == "" { l.reattach = d.reattach }
	if l.close_view == "" { l.close_view = d.close_view }
	if l.window == "" { l.window = d.window }
	if l.floating == "" { l.floating = d.floating }
	if l.dock_left == "" { l.dock_left = d.dock_left }
	if l.dock_right == "" { l.dock_right = d.dock_right }
	if l.dock_bottom == "" { l.dock_bottom = d.dock_bottom }
	return l
}

// The side of a header's small icons (Detach, Re-attach, Close of an internal window), in ems: smaller than the close
// cross of a dialog (DIALOG_CLOSE_EM).
VIEW_DETACH_EM :: f32(1.5)
