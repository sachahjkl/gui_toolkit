package ui

// The Panel presentation and the dock spaces (src/md/features/views.md, section 6): a space has four zones, one per edge,
// around its content (a fifth, its centre, when it has no content); a zone is one stack of views or several in a row
// along its axis, a handle between two; a stack has a tab strip only from two views; a lone panel adds nothing to what
// its view draws, but two small icons on the hover of its top area. While a view is dragged, each space built shows its
// targets (its edges; over a stack, a cross that makes the view a tab of it or splits it); a view let go over one docks
// there.
//
//   if ui.views_frame(vs) { ...the program's content... }     the window's frame: its space "", its internal windows
//   if ui.views_dock(vs, "mission", {}) {}                     a space of the program's own, inside its content

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import store "../store"

// A zone's extent when nothing else gives one (ems), and the top area of a panel whose hover shows its icons (ems).
VIEW_ZONE_EM :: f32(18)
VIEW_HOVER_EM :: f32(2.2)

// A dock space: what is remembered of it (the memory's `#<space>` line) and what its last build laid out.
@(private)
View_Space :: struct {
	name:      string,                                  // owned ("": the window's frame)
	mem:       View_Space_Memory,                       // its zones' extents, axes and stacks' shares
	active:    [View_Edge][VIEW_STACKS_MAX]string,      // owned: the modal name of each stack's tab shown ("": the last docked)
	built:     u64,                                     // the build that last built it
	state:     ^State,
	rect:      Rect,                                    // window px, as laid out by its last build
	zone:      [View_Edge]Rect,                         // ... each zone's ({}: none)
	zone_key:  [View_Edge]Key,
	stacks:    [View_Edge][VIEW_STACKS_MAX]Rect,        // ... each stack's, by rank ({}: none)
	stack_key: [View_Edge][VIEW_STACKS_MAX]Key,
	count:     [View_Edge]int,                          // ... how many stacks each zone had
	content:   Key,
	has_content: bool,                                  // the program's content is its centre (else its centre is a zone)
	em:        f32,                                     // its font size in its last build (the targets' size, read from another window too)
}

// What views_dock makes: with `content`, the block is its centre (the program's content); without, panels only, its
// centre a zone of its own.
View_Dock_Options :: struct {
	content: bool,
}

// `if ui.views_frame(vs) { ... }` around the window's content: its zones, its panels, its internal windows (before the
// content: they read their keys first), then the content's box as the block's parent.
@(require_results, deferred_none = views_space_end)
views_frame :: proc(vs: ^Views) -> bool { return views_space_begin(vs, "", true) }

// `if ui.views_dock(vs, name, {content = true}) { ... }`: a dock space of the program's own, where it is built.
@(require_results, deferred_none = views_space_end)
views_dock :: proc(vs: ^Views, name: string, o: View_Dock_Options) -> bool { return views_space_begin(vs, name, o.content) }

@(private)
views_space_end :: proc() {
	s := gs()
	if len(s.views_space_stack) > 0 && pop(&s.views_space_stack) { pop_parent() }
}

// The views of one zone, by stack rank, each stack's in the order they docked.
@(private = "file")
View_Zone_Lists :: [VIEW_STACKS_MAX][dynamic]^View_Record

@(private = "file")
views_space_begin :: proc(vs: ^Views, name: string, content: bool) -> bool {
	s := gs()
	em := font_size()
	views_ready(vs)
	views_attach_state(vs, s)   // (a shared Views built in this window's frame: its panels may come here)
	if name == "" {
		views_settle_all(s)
		s.views_frame_build = s.build_index
	}
	sp := view_space_of(vs, name)
	sp.built, sp.state, sp.em, sp.has_content = s.build_index, s, em, content
	// (F6 is read at the end of the build, views_f6_end: a program's own binding of it, read anywhere in its build, wins)

	// the views docked here, by zone and stack, each stack's in the order they docked; the ranks made compact
	zones: [View_Edge]View_Zone_Lists
	for e in View_Edge { for k in 0 ..< VIEW_STACKS_MAX { zones[e][k] = make([dynamic]^View_Record, 0, 2, context.temp_allocator) } }
	for r in vs.records {
		if r.owner != s || !view_builds_panel(r.machine) || r.machine.place.space != name { continue }
		p := r.machine.place
		if p.edge == .Center && content { continue }   // (a space with content has no centre zone: it waits)
		append(&zones[p.edge][clamp(p.stack, 0, VIEW_STACKS_MAX - 1)], r)
	}
	for e in View_Edge {
		view_zone_compact(vs, sp, e, &zones[e])
		for k in 0 ..< VIEW_STACKS_MAX {
			z := zones[e][k][:]
			for i in 1 ..< len(z) {   // (a few tabs: insertion by dock order)
				x := z[i]
				j := i - 1
				for j >= 0 && z[j].dock_order > x.dock_order { z[j + 1] = z[j]; j -= 1 }
				z[j + 1] = x
			}
		}
	}
	has :: proc(z: ^View_Zone_Lists) -> bool { return len(z[0]) > 0 }   // (compact: a zone with views has a stack 0)

	// the layout: the top zone, the left, the centre, the right, the bottom; each zone's handle on the centre's side
	mod := s.has_next ? s.next_mod : Style_Mod{width = fill(), height = fill()}
	if mod.width == nil { mod.width = fill() }
	if mod.height == nil { mod.height = fill() }
	next(mod)
	space := build_box({}, fmt.tprintf("###views_space_%s", name))
	sp.rect = space.rect
	push_parent(space)
	next({width = fill(), height = fill(), axis = .Y})
	push_parent(build_box({}, "###views_col"))
	boxes: [View_Edge]^Box
	sp.zone, sp.zone_key, sp.stacks, sp.stack_key, sp.count = {}, {}, {}, {}, {}
	if has(&zones[.Top]) { boxes[.Top] = view_zone_box(sp, .Top, zones[.Top][0][0], em); view_zone_handle(vs, sp, .Top, em) }
	next({width = fill(), height = fill(), axis = .X})
	push_parent(build_box({}, "###views_mid"))
	if has(&zones[.Left]) { boxes[.Left] = view_zone_box(sp, .Left, zones[.Left][0][0], em); view_zone_handle(vs, sp, .Left, em) }
	centre: ^Box
	if !content && has(&zones[.Center]) {
		centre = view_zone_box(sp, .Center, zones[.Center][0][0], em)
		boxes[.Center] = centre
	} else {
		next({width = fill(), height = fill(), axis = .Y})
		centre = build_box({}, "###views_content")
	}
	sp.content = centre.key
	if has(&zones[.Right]) { view_zone_handle(vs, sp, .Right, em); boxes[.Right] = view_zone_box(sp, .Right, zones[.Right][0][0], em) }
	pop_parent()   // mid
	if has(&zones[.Bottom]) { view_zone_handle(vs, sp, .Bottom, em); boxes[.Bottom] = view_zone_box(sp, .Bottom, zones[.Bottom][0][0], em) }
	pop_parent()   // col
	pop_parent()   // space

	vs.building += 1
	for e in View_Edge {
		if boxes[e] != nil { view_zone_fill(vs, sp, e, &zones[e], boxes[e], em) }
	}
	// (the frame's internal windows after its panels: a drop on a zone is built from the next frame, the window drawn in
	// this one; children of the root, they draw over the whole frame)
	if name == "" { views_build_internals(s) }
	vs.building -= 1
	views_sweep(vs)

	append(&s.views_space_stack, content)
	if content { push_parent(centre) }
	return content
}

// The space `name` of `vs` (made at its first use, what is remembered of it from the memory).
@(private)
view_space_of :: proc(vs: ^Views, name: string) -> ^View_Space {
	if sp, ok := vs.spaces[name]; ok { return sp }
	context.allocator = vs.allocator
	sp := new(View_Space)
	sp.name = strings.clone(name)
	if text, found := store.get(&vs.memory, view_space_key(name)); found {
		if m, ok := views_space_parse(text); ok { sp.mem = m }
	}
	vs.spaces[sp.name] = sp
	return sp
}

@(private)
view_space_free :: proc(sp: ^View_Space) {
	delete(sp.name)
	for e in View_Edge { for a in sp.active[e] { delete(a) } }
	free(sp)
}

@(private = "file")
view_space_key :: proc(name: string) -> string { return fmt.tprintf("#%s", name) }

@(private = "file")
view_space_remember :: proc(vs: ^Views, sp: ^View_Space) {
	_ = store.set(&vs.memory, view_space_key(sp.name), views_space_format(sp.mem))
}

// The axis a zone's stacks are laid along: the remembered one, else .Y at the left, the right and the centre (one above
// the other), .X at the top and the bottom (side by side).
@(private)
view_zone_axis :: proc(sp: ^View_Space, e: View_Edge) -> Axis {
	if a, ok := sp.mem.axis[e].?; ok { return a }
	return e == .Top || e == .Bottom ? .X : .Y
}

// `r` is the tab shown in its stack, the last docked there (it settled as a Panel, it was dropped or moved there).
@(private)
view_space_activate :: proc(vs: ^Views, r: ^View_Record) {
	if view_built_as(r.machine.as) != .Panel { return }
	context.allocator = vs.allocator
	vs.dock_next += 1
	r.dock_order = vs.dock_next
	sp := view_space_of(vs, r.machine.place.space)
	e, k := r.machine.place.edge, clamp(r.machine.place.stack, 0, VIEW_STACKS_MAX - 1)
	delete(sp.active[e][k])
	sp.active[e][k] = strings.clone(r.modal_name)
}

// The ranks of a zone's stacks made 0, 1, 2...: a stack that emptied leaves no hole. The places of the views that move
// down are written to the memory; the shares and the tabs shown move with them.
@(private = "file")
view_zone_compact :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, z: ^View_Zone_Lists) {
	to := 0
	for k in 0 ..< VIEW_STACKS_MAX {
		if len(z[k]) == 0 { continue }
		if k != to {
			for r in z[k] {
				r.machine.place.stack = to
				view_place_remember(vs, r)
			}
			z[to], z[k] = z[k], z[to]
			sp.mem.shares[e][to], sp.mem.shares[e][k] = sp.mem.shares[e][k], 0
			delete(sp.active[e][to], vs.allocator)
			sp.active[e][to], sp.active[e][k] = sp.active[e][k], ""
			vs.version += 1
		}
		to += 1
	}
}

// A view's place as it is now, in its memory line (another view's drop moved its stack).
@(private = "file")
view_place_remember :: proc(vs: ^Views, r: ^View_Record) {
	m := views_memory_of(vs, r.kind.id)
	d := m.dock.? or_else View_Dock_Memory{extent_em = r.kind.o.extent_em}
	d.place = r.machine.place
	m.dock = d
	views_memory_write(vs, r.kind.id, m)
}

// Whether `owner` built its frame's space in its last or its current build: the Dock items and commands act there.
@(private)
view_frame_built :: proc(vs: ^Views, owner: ^State) -> bool {
	sp, ok := vs.spaces[""]
	return ok && owner != nil && sp.state == owner && sp.built + 1 >= owner.build_index
}

// Whether a view is built this frame as a panel (in its space, when that space is built).
@(private)
view_builds_panel :: proc(m: View_Machine) -> bool {
	#partial switch m.state {
	case .Shown:  return view_built_as(m.as) == .Panel
	case .Moving: return view_built_as(m.from) == .Panel
	}
	return false
}

// A zone's extent in ems: the space's, else its first view's (extent_em, else its width or height), else VIEW_ZONE_EM.
@(private = "file")
view_zone_extent :: proc(sp: ^View_Space, e: View_Edge, first: ^View_Record) -> f32 {
	if sp.mem.extent[e] > 0 { return sp.mem.extent[e] }
	o := first.kind.o
	x := o.extent_em
	if x <= 0 { x = e == .Left || e == .Right ? o.width_em : o.height_em }
	if x <= 0 { x = VIEW_ZONE_EM }
	sp.mem.extent[e] = x
	return x
}

@(private = "file")
view_zone_box :: proc(sp: ^View_Space, e: View_Edge, first: ^View_Record, em: f32) -> ^Box {
	axis := view_zone_axis(sp, e)
	switch e {
	case .Left, .Right:
		next({width = px(math.round(view_zone_extent(sp, e, first) * em)), height = fill(), axis = axis})
	case .Top, .Bottom:
		next({width = fill(), height = px(math.round(view_zone_extent(sp, e, first) * em)), axis = axis})
	case .Center:
		next({width = fill(), height = fill(), axis = axis})
	}
	// (no background, no border of its own: a lone panel adds nothing, rule 1)
	b := build_box({.Clip}, fmt.tprintf("###view_zone_%v", e))
	sp.zone[e], sp.zone_key[e] = b.rect, b.key
	return b
}

// The handle between a zone and the centre: the centre keeps DOCK_MIN_EM; the extent is written when it is let go.
@(private = "file")
view_zone_handle :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, em: f32) {
	s := gs()
	sc := max(s.scale, 0.01)
	across := e == .Left || e == .Right
	total := (across ? sp.rect.max.x - sp.rect.min.x : sp.rect.max.y - sp.rect.min.y) / sc
	least := DOCK_MIN_EM * em / sc
	size := sp.mem.extent[e] * em / sc
	res := splitter(fmt.tprintf("###view_handle_%v", e), across ? .X : .Y, &size, least, max(total - least, least),
		{after = e == .Right || e == .Bottom, total = total > 0 ? total : 0, min_other = least})
	if res.changed { sp.mem.extent[e] = size * sc / em }
	if res.finished { view_space_remember(vs, sp) }
}

// A zone's stacks in a row along its axis, a handle between two; in each, the tab strip from two views, the view shown,
// each view's menu.
@(private = "file")
view_zone_fill :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, z: ^View_Zone_Lists, zone: ^Box, em: f32) {
	s := gs()
	sc := max(s.scale, 0.01)
	axis := view_zone_axis(sp, e)
	n := 0
	for k in 0 ..< VIEW_STACKS_MAX { if len(z[k]) > 0 { n = k + 1 } }
	sp.count[e] = n
	zr := sp.zone[e]
	length := axis == .X ? zr.max.x - zr.min.x : zr.max.y - zr.min.y
	least := DOCK_MIN_EM * em
	// (each share but the last: the remembered one, else an equal one; what the first ones take leaves room for the others)
	shares: [VIEW_STACKS_MAX]f32
	taken := f32(0)
	for k in 0 ..< n - 1 {
		shares[k] = sp.mem.shares[e][k] > 0 ? sp.mem.shares[e][k] : 1 / f32(n)
		taken += shares[k]
	}
	room := length > 0 ? 1 - f32(n - 1) * least / length : 1
	if taken > room && taken > 0 { for k in 0 ..< n - 1 { shares[k] *= room / taken } }
	push_parent(zone)
	for k in 0 ..< n {
		list := z[k][:]
		last := k == n - 1
		size := math.round(shares[k] * length)
		if last || length <= 0 {
			next({width = fill(), height = fill(), axis = .Y})
		} else if axis == .X {
			next({width = px(size), height = fill(), axis = .Y})
		} else {
			next({width = fill(), height = px(size), axis = .Y})
		}
		stack := build_box({.Clip}, fmt.tprintf("###view_stack_%d", k))
		sp.stacks[e][k], sp.stack_key[e][k] = stack.rect, stack.key
		shown := list[len(list) - 1]
		for r in list { if r.modal_name == sp.active[e][k] { shown = r } }
		push_parent(stack)
		if len(list) >= 2 { view_zone_tabs(vs, sp, e, k, list, shown) }
		view_panel_build(vs, sp, shown)
		pop_parent()
		for r in list { view_header_menu(vs, r, .Panel) }
		if last || length <= 0 { continue }
		// (the handle after it: its share of the zone, written when it is let go)
		logical := size / sc
		res := splitter(fmt.tprintf("###view_stack_handle_%v_%d", e, k), axis, &logical, least / sc, max((length - least) / sc, least / sc),
			{total = length / sc, min_other = least / sc})
		if res.changed && length > 0 { sp.mem.shares[e][k] = clamp(logical * sc / length, 0.01, 0.99) }
		if res.finished { view_space_remember(vs, sp) }
	}
	pop_parent()
}

// The tab strip of a stack of two views or more: a tab each (its title); a click shows it, a drag takes it out as an
// internal window, a right click opens its menu.
@(private = "file")
view_zone_tabs :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, k: int, list: []^View_Record, shown: ^View_Record) {
	em := font_size()
	next({width = fill(), height = px(math.round(DOCK_TAB_EM * em)), axis = .X, cross = .Center})
	strip: ^Box
	if tags("bar") { strip = build_box({.Draw_Background, .Draw_Side_Bottom}, "###view_tabs") }
	a11y_default(strip, {role = .Tab_List, orientation = .X})
	push_parent(strip)
	defer pop_parent()
	for r in list {
		on := r == shown
		push_tags(on ? "selected" : "ghost_button")
		next({width = text_size(em * DOCK_TAB_PAD_EM * 2), height = pct(1), text_pad = em * DOCK_TAB_PAD_EM, text_align = .Center})
		tb := build_box({.Clickable, .Draw_Text, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("%s###view_tab_%s", text_shown(view_title_shown(r)), r.modal_name))
		pop_tags()
		a11y_default(tb, {role = .Tab, selected = on})
		sig := signal(tb)
		if sig.clicked && !on {
			delete(sp.active[e][k], vs.allocator)
			sp.active[e][k] = strings.clone(r.modal_name, vs.allocator)
		}
		if sig.right_clicked { menu_open(view_menu_id(r), mouse_pos(), tb.key, search = false) }
		if sig.dragging { view_panel_drag(vs, r, tb.key, sig, em) }
	}
}

// The view as a panel: its body fills its stack; its keys while the focus is in it; on the hover of its top area, its
// two icons (Detach, Close) over the body's top right corner; a right click there opens its menu.
@(private = "file")
view_panel_build :: proc(vs: ^Views, sp: ^View_Space, r: ^View_Record) {
	s := gs()
	k := r.kind
	em := font_size()
	r.flag, r.ending, r.tools, r.header = true, nil, 0, 0
	next({width = fill(), height = fill(), axis = .Y})
	body := build_box({.Clip}, fmt.tprintf("###view_panel_%s", r.modal_name))
	r.panel = body.key
	r.roots[.Panel] = body.key
	last := body.rect   // (the last layout's)
	push_parent(body)
	v := View{id = k.id, instance = r.instance, presentation = .Panel, place = r.machine.place, shown = true, record = r}
	keys_root := s.view_keys_root
	s.view_keys_root = body.key
	k.build(&v, r.data)
	s.view_keys_root = keys_root
	labels := view_labels(vs)
	band := Rect{last.min, {last.max.x, last.min.y + em * VIEW_HOVER_EM}}
	over := s.mouse_valid && view_rect_has(band, mouse_pos())
	if over || view_held_within(s, body.key) {
		side := math.round(em * VIEW_DETACH_EM)
		w := last.max.x - last.min.x
		gap := math.round(em * 0.35)
		next({fixed_x = w - 2 * side - 3 * gap - em * 0.6, fixed_y = gap, width = children_sum(), height = px(side), axis = .X, cross = .Center})
		if parent(build_box({}, "###view_panel_icons")) {
			if view_header_icon("view_detach", lucide.PICTURE_IN_PICTURE_2, labels.floating, true) { view_float(vs, r) }
			if view_header_icon("view_close", lucide.X, labels.close, true) { r.flag = false }
		}
	}
	pop_parent()
	if s.pressed_any[.Right] && over { menu_open(view_menu_id(r), mouse_pos(), body.key, search = false) }
	if view_focus_inside(s, body.key) && r.flag && r.ending == nil {
		if key_press(.W, {.Ctrl}) {
			r.flag = false
		} else if key_press(.Escape) {
			s.focus_key = 0   // (an Escape it did not take: the focus goes back to the content, the panel stays)
		}
	}
	view_build_ended(vs, r)
}

@(private)
view_rect_has :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }

// Whether the left button holds a box under `root` (an icon pressed while the pointer leaves the band keeps it).
@(private = "file")
view_held_within :: proc(s: ^State, root: Key) -> bool {
	k := s.active_key[.Left]
	if k == 0 { return false }
	for b := s.boxes[k] or_else nil; b != nil; b = b.parent {
		if b.key == root { return true }
	}
	return false
}

// Inside a build: `b`, the program's title box of the view, moves it: in a lone panel, a drag of it past DOCK_DRAG_EM
// takes the view out as an internal window under the pointer (its drop on a target docks it again). Elsewhere it does
// nothing: a dialog and an internal window move by the toolkit's header, a panel among tabs by its tab.
view_drag_handle :: proc(v: ^View, b: ^Box) {
	if v.presentation != .Panel || b == nil { return }
	r := v.record
	b.flags += {.Clickable}
	sig := signal(b)
	if sig.dragging { view_panel_drag(r.vs, r, b.key, sig, font_size()) }
}

// A drag from a panel (its tab, its title) past the threshold: an internal window under the pointer, its header where
// the pointer is, as large as the panel was (DOCK_FLOAT_DEFAULT_EM at most); the press goes on in that header.
@(private = "file")
view_panel_drag :: proc(vs: ^Views, r: ^View_Record, from: Key, sig: Signal, em: f32) {
	d := sig.drag_delta
	if r.machine.state != .Shown || math.sqrt(d.x * d.x + d.y * d.y) < DOCK_DRAG_EM * em { return }
	most := DOCK_FLOAT_DEFAULT_EM * em
	size := most
	// (a tab never shown has no body: the default size; one shown: as large as it was, the default at most)
	if body := box_from_key(r.panel); body != nil && r.panel != 0 {
		size = {min(body.rect.max.x - body.rect.min.x, most.x), min(body.rect.max.y - body.rect.min.y, most.y)}
	}
	at := mouse_pos() - Vec2{em * 1.5, em * 1.0}
	at = {math.round(at.x), math.round(at.y)}
	r.irect = {at, at + size}
	r.hand_from, r.hand_origin = from, at - d
	view_apply(vs, r, {kind = .Drag_Start})
}

////////////////////////////////
// The targets of a drag

// Where a drop puts a view: its place; `split`: a new stack at place.stack, the stacks from there on one rank up;
// `axis`: the zone's axis, set by the split of its one stack.
@(private)
View_Target :: struct {
	place: View_Place,
	split: bool,
	axis:  Maybe(Axis),
}

// One square of the targets: where it is, what a drop there does, what the preview shows, its box's name.
@(private = "file")
View_Square :: struct {
	rect:    Rect,
	target:  View_Target,
	preview: Rect,
	name:    string,
}

// The squares of a space as its last build laid it out: one at the middle of each edge (and its centre, a space without
// content whose centre zone is empty); over the stack under `p`, a cross: its middle (a tab of it) and its sides (a split
// before or after it, along its zone's axis; the four sides for a zone's one stack).
@(private = "file")
view_space_squares :: proc(sp: ^View_Space, p: Vec2, out: ^[dynamic]View_Square) {
	em := sp.em
	m := math.round(DOCK_MARKER_EM * em)
	g := math.round(DOCK_MARKER_GAP_EM * em)
	square :: proc(c: Vec2, m: f32) -> Rect {
		at := Vec2{math.round(c.x - m * 0.5), math.round(c.y - m * 0.5)}
		return {at, at + m}
	}
	r := sp.rect
	c := (r.min + r.max) * 0.5
	for e in View_Edge {
		at: Vec2
		switch e {
		case .Left:   at = {r.min.x + g + m * 0.5, c.y}
		case .Right:  at = {r.max.x - g - m * 0.5, c.y}
		case .Top:    at = {c.x, r.min.y + g + m * 0.5}
		case .Bottom: at = {c.x, r.max.y - g - m * 0.5}
		case .Center:
			if sp.has_content || sp.count[.Center] > 0 { continue }
			at = c
		}
		append(out, View_Square{rect = square(at, m), target = {place = {space = sp.name, edge = e}}, preview = view_target_preview(sp, e, em), name = fmt.tprintf("view_target_%s_%v", sp.name, e)})
	}
	for e in View_Edge {
		n := sp.count[e]
		for k in 0 ..< n {
			sr := sp.stacks[e][k]
			if !view_rect_has(sr, p) { continue }
			sc := (sr.min + sr.max) * 0.5
			axis := view_zone_axis(sp, e)
			base := fmt.tprintf("view_target_%s_%v_%d", sp.name, e, k)
			append(out, View_Square{rect = square(sc, m), target = {place = {space = sp.name, edge = e, stack = k}}, preview = sr, name = fmt.tprintf("%s_tab", base)})
			if n >= VIEW_STACKS_MAX { continue }
			Side :: struct { dir: View_Edge, axis: Axis, after: bool, word: string }
			sides := [4]Side{{.Left, .X, false, "left"}, {.Right, .X, true, "right"}, {.Top, .Y, false, "top"}, {.Bottom, .Y, true, "bottom"}}
			step := m + g
			for sd in sides {
				if n > 1 && sd.axis != axis { continue }
				off: Vec2
				half := sr
				switch sd.dir {
				case .Left:   off = {-step, 0}; half.max.x = (sr.min.x + sr.max.x) * 0.5
				case .Right:  off = {step, 0};  half.min.x = (sr.min.x + sr.max.x) * 0.5
				case .Top:    off = {0, -step}; half.max.y = (sr.min.y + sr.max.y) * 0.5
				case .Bottom: off = {0, step};  half.min.y = (sr.min.y + sr.max.y) * 0.5
				case .Center:
				}
				t := View_Target{place = {space = sp.name, edge = e, stack = sd.after ? k + 1 : k}, split = true}
				if n == 1 { t.axis = sd.axis }
				append(out, View_Square{rect = square(sc + off, m), target = t, preview = half, name = fmt.tprintf("%s_%s", base, sd.word)})
			}
		}
	}
}

// The dock target under `p`: a square of a space of a Views of `s`, built in this build or the last (the stacks'
// crosses first: they are over the zones).
@(private)
view_target_at :: proc(s: ^State, p: Vec2) -> (t: View_Target, ok: bool) {
	squares := make([dynamic]View_Square, 0, 16, context.temp_allocator)
	for vs in s.views_attached {
		for _, sp in vs.spaces {
			if sp.state != s || sp.built + 1 < s.build_index || sp.rect == {} { continue }
			clear(&squares)
			view_space_squares(sp, p, &squares)
			#reverse for q in squares {
				if view_rect_has(q.rect, p) { return q.target, true }
			}
		}
	}
	return {}, false
}

// A dragged view let go over `t`: a split moves the stacks from its rank on one rank up (their views' places written
// again, the zone's shares made equal, its axis set by the split of its one stack); then the view docks there.
@(private)
view_target_drop :: proc(vs: ^Views, r: ^View_Record, t: View_Target) {
	place := t.place
	if t.split {
		sp := view_space_of(vs, place.space)
		e := place.edge
		for x in vs.records {
			if x == r || x.machine.state == .Closed || x.machine.as != .Panel { continue }
			xp := &x.machine.place
			if xp.space != place.space || xp.edge != e || xp.stack < place.stack { continue }
			xp.stack = min(xp.stack + 1, VIEW_STACKS_MAX - 1)
			view_place_remember(vs, x)
		}
		for k := VIEW_STACKS_MAX - 1; k > place.stack; k -= 1 {
			delete(sp.active[e][k], vs.allocator)
			sp.active[e][k], sp.active[e][k - 1] = sp.active[e][k - 1], ""
		}
		sp.mem.shares[e] = {}
		if a, ok := t.axis.?; ok { sp.mem.axis[e] = a }
		view_space_remember(vs, sp)
		vs.version += 1
	}
	view_apply(vs, r, {kind = .Drop, as = .Panel, place = place})
	view_space_activate(vs, r)
}

// Where a view dropped at edge `e` of a space would be: the zone there, else a strip of its extent along that edge
// (the centre: what the edges leave).
@(private = "file")
view_target_preview :: proc(sp: ^View_Space, e: View_Edge, em: f32) -> Rect {
	if z := sp.zone[e]; z.max.x > z.min.x { return z }
	r := sp.rect
	if e == .Center { return r }
	ext := min(math.round((sp.mem.extent[e] > 0 ? sp.mem.extent[e] : VIEW_ZONE_EM) * em), (e == .Left || e == .Right ? r.max.x - r.min.x : r.max.y - r.min.y) * 0.4)
	#partial switch e {
	case .Left:   return {r.min, {r.min.x + ext, r.max.y}}
	case .Right:  return {{r.max.x - ext, r.min.y}, r.max}
	case .Top:    return {r.min, {r.max.x, r.min.y + ext}}
	case .Bottom: return {{r.min.x, r.max.y - ext}, r.max}
	}
	return {}
}

// end_build: while a view of `s` is dragged, the squares of each space built in this build, and the preview of the one
// under the pointer. Only during a drag.
@(private)
views_build_targets :: proc(s: ^State) {
	dragged := false
	p := mouse_pos()
	for vs in s.views_attached {
		for r in vs.records {
			if r.owner != s || r.machine.state != .Dragged { continue }
			dragged = true
			// (an external window's header is held in its own window: the pointer as it is over this one)
			if r.machine.as == .External {
				p = r.w_drag.over_owner ? r.w_drag.owner_at : {-1, -1}
				s.anim_busy = true
			}
		}
	}
	if !dragged { return }
	em := font_size()
	push_parent(s.root)
	push_tags_isolated("floating")
	defer { pop_tags_isolated(); pop_parent() }
	squares := make([dynamic]View_Square, 0, 16, context.temp_allocator)
	for vs in s.views_attached {
		for _, sp in vs.spaces {
			if sp.state != s || sp.built != s.build_index || sp.rect == {} { continue }
			clear(&squares)
			view_space_squares(sp, p, &squares)
			lit := -1
			#reverse for q, i in squares { if lit < 0 && view_rect_has(q.rect, p) { lit = i } }
			if lit >= 0 {
				pr := squares[lit].preview
				next({fixed_x = pr.min.x, fixed_y = pr.min.y, width = px(pr.max.x - pr.min.x), height = px(pr.max.y - pr.min.y), transparency = 0.6, radius = em * DOCK_MARKER_RADIUS_EM})
				if tags("selected") { build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###view_preview_%s", squares[lit].name)) }
			}
			for q, i in squares {
				next({fixed_x = q.rect.min.x, fixed_y = q.rect.min.y, width = px(q.rect.max.x - q.rect.min.x), height = px(q.rect.max.y - q.rect.min.y), radius = em * DOCK_MARKER_RADIUS_EM})
				if tags(i == lit ? "selected" : "button") {
					b := build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###%s", q.name))
					a11y_default(b, {ignore = true})
				}
			}
		}
	}
}

////////////////////////////////
// F6

// end_build: F6 and Shift+F6 of the window's frame, when nothing of the build took them (key_press takes a key once:
// a program that binds F6 to a command of its own reads it in its build, before or after views_frame, and keeps it).
@(private)
views_f6_end :: proc(s: ^State) {
	for vs in s.views_attached {
		sp, ok := vs.spaces[""]
		if ok && sp.state == s && sp.built == s.build_index { views_f6(s, vs, sp); return }
	}
}

// F6 and Shift+F6 in the window's frame: the focus to the first stop of the next or the previous area (the content,
// each stack, each internal window).
@(private = "file")
views_f6 :: proc(s: ^State, vs: ^Views, sp: ^View_Space) {
	forward := key_press(.F6)
	backward := !forward && key_press(.F6, {.Shift})
	if !forward && !backward { return }
	areas := make([dynamic]Key, 0, 8, context.temp_allocator)
	if sp.content != 0 && sp.has_content { append(&areas, sp.content) }
	for e in View_Edge {
		for k in 0 ..< sp.count[e] { if sp.stack_key[e][k] != 0 { append(&areas, sp.stack_key[e][k]) } }
	}
	for x in s.views_attached {
		for r in x.records {
			if r.owner == s && r.iframe != 0 { if yes, unseen := view_builds_internal(r.machine); yes && !unseen { append(&areas, r.iframe) } }
		}
	}
	n := len(areas)
	if n == 0 { return }
	at := -1
	for a, i in areas { if view_focus_inside(s, a) { at = i } }
	for step in 1 ..= n {
		i := at < 0 ? (forward ? step - 1 : n - step) : (at + (forward ? step : -step) % n + n) % n
		if first := view_first_stop(s.boxes[areas[i]] or_else nil); first != 0 {
			s.focus_key, s.focus_visible = first, true
			return
		}
	}
}

////////////////////////////////
// The palette's commands

// An act of the palette's commands on a view (views_commands).
View_Act :: enum u8 { Window, Float, Dock_Left, Dock_Right, Dock_Bottom, Reattach, Close }

// The view a command acts on, and how. Its strings are the view's: valid while it is open.
View_Command :: struct {
	id, instance: string,
	act:          View_Act,
}

// A command per act of each open view of `vs`, in the language in use ("Float Properties", "Dock Properties to the
// right"...): an act that does nothing where the view is is absent. `acts[i]` is what `commands[i]` does
// (views_command_run). Make them again when views_version changes.
views_commands :: proc(vs: ^Views, allocator := context.temp_allocator) -> (commands: []Command, acts: []View_Command) {
	cmds := make([dynamic]Command, 0, 4 * len(vs.records), allocator)
	what := make([dynamic]View_Command, 0, 4 * len(vs.records), allocator)
	group := i18n.tr("Views")
	for r in vs.records {
		m := r.machine
		if m.state == .Closed || m.state == .Dragged { continue }
		title := view_title_shown(r)
		add :: proc(cmds: ^[dynamic]Command, what: ^[dynamic]View_Command, r: ^View_Record, act: View_Act, word, title, group, icon: string, allocator := context.allocator) {
			append(cmds, Command{label = fmt.aprintf(word, title, allocator = allocator), group = group, icon = icon})
			append(what, View_Command{id = r.kind.id, instance = r.instance, act = act})
		}
		if m.as != .External && views_windows_ready(vs) { add(&cmds, &what, r, .Window, i18n.tr("Open %s in a window"), title, group, lucide.EXTERNAL_LINK, allocator) }
		if m.as != .Internal { add(&cmds, &what, r, .Float, i18n.tr("Float %s"), title, group, lucide.PICTURE_IN_PICTURE_2, allocator) }
		if view_frame_built(vs, r.owner) {
			edges := [3]View_Edge{.Left, .Right, .Bottom}
			words := [3]string{i18n.tr("Dock %s to the left"), i18n.tr("Dock %s to the right"), i18n.tr("Dock %s to the bottom")}
			icons := [3]string{lucide.PANEL_LEFT, lucide.PANEL_RIGHT, lucide.PANEL_BOTTOM}
			dock_acts := [3]View_Act{.Dock_Left, .Dock_Right, .Dock_Bottom}
			for e, i in edges {
				if m.as == .Panel && m.place.space == "" && m.place.edge == e { continue }
				add(&cmds, &what, r, dock_acts[i], words[i], title, group, icons[i], allocator)
			}
		}
		if !view_machine_at_home(m) { add(&cmds, &what, r, .Reattach, i18n.tr("Re-attach %s"), title, group, lucide.UNDO_2, allocator) }
		add(&cmds, &what, r, .Close, i18n.tr("Close %s"), title, group, lucide.X, allocator)
	}
	return cmds[:], what[:]
}

// Does what a command of views_commands says (nothing when its view closed since).
views_command_run :: proc(vs: ^Views, c: View_Command) {
	r := view_record_find(vs, c.id, c.instance)
	if r == nil || r.machine.state == .Closed { return }
	switch c.act {
	case .Window:      view_apply(vs, r, {kind = .Present, as = .External})
	case .Float:       view_float(vs, r)
	case .Dock_Left:   view_dock_at(vs, r, .Left)
	case .Dock_Right:  view_dock_at(vs, r, .Right)
	case .Dock_Bottom: view_dock_at(vs, r, .Bottom)
	case .Reattach:    view_apply(vs, r, {kind = .Reattach})
	case .Close:       view_apply(vs, r, {kind = .User_Close})
	}
}

// What changes the list of views_commands: a view opened, closed, moved or retitled. The program gives it to palette_set.
views_version :: proc(vs: ^Views) -> u64 { return vs.version }

// The views' commands as a program's palette keeps them (a palette holds its table while it is open: temporary memory
// would go at the frame's end). Made again by views_commands_update only when the views or the language changed.
View_Commands :: struct {
	commands:  []Command,
	acts:      []View_Command,
	serial:    u64,   // changes each time they are made again: a part of the palette's Palette_Options.version
	made:      bool,
	version:   u64,   // the views' version they were made for
	language:  u32,
	allocator: runtime.Allocator,
}

// Makes `vc` again when the views of `vs` changed since (views_version) or the language did; true: they did, the
// program builds its palette's table again (its own commands first, then these: the palette folds each slot's text once,
// and the program's slots stay where they were) and calls palette_set. Cost: one pass over the open views, only then.
views_commands_update :: proc(vc: ^View_Commands, vs: ^Views) -> (changed: bool) {
	views_ready(vs)
	language := i18n.version()
	if vc.made && vc.version == vs.version && vc.language == language { return false }
	views_commands_destroy(vc)
	vc.allocator = vs.allocator
	commands, acts := views_commands(vs, context.temp_allocator)
	vc.commands = make([]Command, len(commands), vc.allocator)
	vc.acts = make([]View_Command, len(acts), vc.allocator)
	for c, i in commands {
		vc.commands[i] = c
		vc.commands[i].label = strings.clone(c.label, vc.allocator)
		vc.commands[i].group = strings.clone(c.group, vc.allocator)
	}
	// (the view's strings cloned: a view that closes while the palette lists it frees its own)
	for a, i in acts {
		vc.acts[i] = {id = strings.clone(a.id, vc.allocator), instance = strings.clone(a.instance, vc.allocator), act = a.act}
	}
	vc.made, vc.version, vc.language = true, vs.version, language
	vc.serial += 1
	return true
}

// Frees what views_commands_update made (its serial goes on: a palette given it again sees a change).
views_commands_destroy :: proc(vc: ^View_Commands) {
	if !vc.made { return }
	for c in vc.commands { delete(c.label, vc.allocator); delete(c.group, vc.allocator) }
	for a in vc.acts { delete(a.id, vc.allocator); delete(a.instance, vc.allocator) }
	delete(vc.commands, vc.allocator)
	delete(vc.acts, vc.allocator)
	vc.commands, vc.acts, vc.made = nil, nil, false
}

// To an edge of the owner's frame: a tab of that zone's first stack (a new zone when it has none).
@(private)
view_dock_at :: proc(vs: ^Views, r: ^View_Record, e: View_Edge) {
	view_apply(vs, r, {kind = .Present, as = .Panel, place = {edge = e}})
	view_space_activate(vs, r)
}
