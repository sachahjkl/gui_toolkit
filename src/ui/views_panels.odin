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
import "../platform"
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
	defaults:  View_Dock_Options,                       // what its last build gave (its zones' extents at first)
	// the stack that takes the whole space for a while (its Maximise; not remembered: a start shows the content)
	max_edge:  Maybe(View_Edge),
	max_stack: int,
}

// What views_dock makes: with `content`, the block is its centre (the program's content); without, panels only, its
// centre a zone of its own. A zone's extent at first: `extent_frac` (a share of the space's width at the left and the
// right, of its height at the top and the bottom: it follows the window), else `extent_em`, else its first view's
// (View_Options.extent_frac, extent_em). What the user drags is remembered in the zone's unit.
View_Dock_Options :: struct {
	content:     bool,
	extent_em:   [View_Edge]f32,
	extent_frac: [View_Edge]f32,
}

// `if ui.views_frame(vs) { ... }` around the window's content: its zones, its panels, its internal windows (before the
// content: they read their keys first), then the content's box as the block's parent. `o`: its zones' extents at first
// (its `content` is always true).
@(require_results, deferred_none = views_space_end)
views_frame :: proc(vs: ^Views, o := View_Dock_Options{}) -> bool { return views_space_begin(vs, "", true, o) }

// `if ui.views_dock(vs, name, {content = true}) { ... }`: a dock space of the program's own, where it is built.
@(require_results, deferred_none = views_space_end)
views_dock :: proc(vs: ^Views, name: string, o: View_Dock_Options) -> bool { return views_space_begin(vs, name, o.content, o) }

@(private)
views_space_end :: proc() {
	s := gs()
	if len(s.views_space_stack) > 0 && pop(&s.views_space_stack) { pop_parent() }
}

// The views of one zone, by stack rank, each stack's in the order they docked.
@(private = "file")
View_Zone_Lists :: [VIEW_STACKS_MAX][dynamic]^View_Record

@(private = "file")
views_space_begin :: proc(vs: ^Views, name: string, content: bool, o: View_Dock_Options) -> bool {
	s := gs()
	em := font_size()
	views_ready(vs)
	views_attach_state(vs, s)   // (a shared Views built in this window's frame: its panels may come here)
	if name == "" {
		views_settle_all(s)
		s.views_frame_build = s.build_index
	}
	sp := view_space_of(vs, name)
	sp.built, sp.state, sp.em, sp.has_content, sp.defaults = s.build_index, s, em, content, o
	// (F6 is read at the end of the build, views_f6_end: a program's own binding of it, read anywhere in its build, wins)

	// the views docked here, by zone and stack, each stack's in the order they docked; the ranks made compact
	zones: [View_Edge]View_Zone_Lists
	for e in View_Edge { for k in 0 ..< VIEW_STACKS_MAX { zones[e][k] = make([dynamic]^View_Record, 0, 2, context.temp_allocator) } }
	for r in vs.records {
		if r.owner != s || !view_builds_panel(r.machine) || r.machine.place.space != name { continue }
		if r.ibuilt == s.build_index { continue }   // (floating this frame, its space was not built: from the next one here)
		p := r.machine.place
		if p.edge == .Center && content { continue }   // (a space with content has no centre zone: it waits)
		// (placed in this build, its tab shown or not: not a late panel of end_build, whose body would cover its zone)
		r.pbuilt = s.build_index
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
	stacks :: proc(z: ^View_Zone_Lists) -> (n: int) { for k in 0 ..< VIEW_STACKS_MAX { if len(z[k]) > 0 { n = k + 1 } }; return }

	// a stack maximised (its strip's button): it alone fills the space, the other zones are not built, and the content
	// is laid out at no size (built: its state is kept). A stack that went: nothing maximised.
	maxed_e, maxed := sp.max_edge.?
	if maxed && (sp.max_stack < 0 || sp.max_stack >= VIEW_STACKS_MAX || len(zones[maxed_e][sp.max_stack]) == 0) {
		sp.max_edge, maxed = nil, false
	}
	shows :: proc(e: View_Edge, maxed_e: View_Edge, maxed: bool) -> bool { return !maxed || e == maxed_e }
	// (a zone's handle: not when it is maximised or minimised, its size is not the user's then)
	handle :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, em: f32, maxed: bool) {
		if !maxed && !sp.mem.minimised[e] { view_zone_handle(vs, sp, e, em) }
	}

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
	if has(&zones[.Top]) && shows(.Top, maxed_e, maxed) {
		boxes[.Top] = view_zone_box(sp, .Top, zones[.Top][0][0], em, maxed, stacks(&zones[.Top]))
		handle(vs, sp, .Top, em, maxed)
	}
	mid_gone := maxed && (maxed_e == .Top || maxed_e == .Bottom)
	next({width = fill(), height = mid_gone ? px(0) : fill(), axis = .X})
	push_parent(build_box(mid_gone ? Box_Flags{.Clip} : Box_Flags{}, "###views_mid"))
	if has(&zones[.Left]) && shows(.Left, maxed_e, maxed) {
		boxes[.Left] = view_zone_box(sp, .Left, zones[.Left][0][0], em, maxed, stacks(&zones[.Left]))
		handle(vs, sp, .Left, em, maxed)
	}
	centre: ^Box
	if !content && has(&zones[.Center]) && shows(.Center, maxed_e, maxed) {
		centre = view_zone_box(sp, .Center, zones[.Center][0][0], em, maxed, stacks(&zones[.Center]))
		boxes[.Center] = centre
	} else {
		// (maximised elsewhere: at no size, clipped; the same box, its content's state kept)
		next({width = maxed ? px(0) : fill(), height = maxed ? px(0) : fill(), axis = .Y})
		centre = build_box(maxed ? Box_Flags{.Clip} : Box_Flags{}, "###views_content")
	}
	sp.content = centre.key
	if has(&zones[.Right]) && shows(.Right, maxed_e, maxed) {
		handle(vs, sp, .Right, em, maxed)
		boxes[.Right] = view_zone_box(sp, .Right, zones[.Right][0][0], em, maxed, stacks(&zones[.Right]))
	}
	pop_parent()   // mid
	if has(&zones[.Bottom]) && shows(.Bottom, maxed_e, maxed) {
		handle(vs, sp, .Bottom, em, maxed)
		boxes[.Bottom] = view_zone_box(sp, .Bottom, zones[.Bottom][0][0], em, maxed, stacks(&zones[.Bottom]))
	}
	pop_parent()   // col
	pop_parent()   // space

	vs.building += 1
	for e in View_Edge {
		if boxes[e] != nil { view_zone_fill(vs, sp, e, &zones[e], boxes[e], em, maxed ? sp.max_stack : -1) }
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

// The layout of the space `name` as at first: its zones' extents, axes and stacks' shares and the tabs shown go back to
// its defaults (its memory line goes), and each open view docked there or whose home is there goes back to its home
// (Reattach: one the user moved out comes back, one moved in goes home). A command "the layout as at first" calls it.
views_space_reset :: proc(vs: ^Views, name: string) {
	views_ready(vs)
	context.allocator = vs.allocator
	sp := view_space_of(vs, name)
	sp.mem = {}
	sp.max_edge = nil
	for e in View_Edge {
		for &a in sp.active[e] { delete(a); a = "" }
	}
	store.remove(&vs.memory, view_space_key(name))
	for i := 0; i < len(vs.records); i += 1 {
		r := vs.records[i]
		m := r.machine
		if m.state == .Closed || m.state == .Dragged { continue }
		here := (m.as == .Panel && m.place.space == name) || (m.state == .Moving && m.from == .Panel && m.from_place.space == name)
		homed := m.home == .Panel && m.home_place.space == name
		if !here && !homed { continue }
		view_apply(vs, r, {kind = .Reattach})
		view_space_activate(vs, r)   // (a view at home: its tab shown, in the order they come back)
	}
	vs.version += 1
	if sp.state != nil { sp.state.anim_busy = true }
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
	key := view_instance_key(r.kind.id, r.instance)   // (an instance's own line: its own place)
	m := views_memory_of(vs, key)
	d := m.dock.? or_else View_Dock_Memory{extent_em = r.kind.o.extent_em}
	d.place = r.machine.place
	m.dock = d
	views_memory_write(vs, key, m)
}

// Whether `owner` built its frame's space in its last or its current build: the Dock items and commands act there.
@(private)
view_frame_built :: proc(vs: ^Views, owner: ^State) -> bool {
	sp, ok := vs.spaces[""]
	return ok && owner != nil && sp.state == owner && sp.built + 1 >= owner.build_index
}

// Whether a panel floats (an internal window) in this build: its place is the window's frame, and the window built no
// views_frame in this build nor in the last one. It goes to the frame from the build after the frame's. A panel of a
// space of the program's (views_dock) never floats: while its space is not built (a section not shown) it waits there,
// not built, and shows when the space is built again (section 8.2, decision 2).
@(private)
view_panel_floats :: proc(vs: ^Views, r: ^View_Record, s: ^State) -> bool {
	if r.machine.place.space != "" { return false }
	sp, ok := vs.spaces[""]
	return !ok || sp.state != s || sp.built + 1 < s.build_index
}

// end_build: the panels not built in this build, opened (or moved here) after their space was built. Each is built now,
// in the frame it opens: unseen, at the place it will have, its body's key its own (key_rooted): what its first build
// focused keeps the focus in its zone from the next frame. A panel whose space this build did not build floats now when
// its place is the frame of a window with no frame (view_panel_floats), and waits when it is a space of the program's.
@(private)
views_build_late_panels :: proc(s: ^State) {
	for vi := 0; vi < len(s.views_attached); vi += 1 {
		vs := s.views_attached[vi]
		for i := 0; i < len(vs.records); i += 1 {
			r := vs.records[i]
			if r.owner != s || !view_builds_panel(r.machine) || r.pbuilt == s.build_index || r.ibuilt == s.build_index { continue }
			sp, ok := vs.spaces[r.machine.place.space]
			if !ok || sp.state != s || sp.built != s.build_index {
				// (its space not built in this build: a frame-less window's panel floats at once; one of a space of the
				// program's waits there, not built, until the space is)
				if view_panel_floats(vs, r, s) { view_internal_build(vs, r, false) }
				continue
			}
			em := sp.em
			at := view_target_preview(sp, r.machine.place.edge, em)
			if r.machine.place.edge == .Center && sp.has_content { at = sp.rect }
			push_parent(s.root)
			next({fixed_x = at.min.x, fixed_y = at.min.y, width = px(max(at.max.x - at.min.x, 1)), height = px(max(at.max.y - at.min.y, 1)), axis = .Y, transparency = 1})
			holder := build_box({}, fmt.tprintf("###view_late_%s", r.modal_name))
			push_parent(holder)
			view_panel_build(vs, sp, r, false)
			pop_parent()
			pop_parent()
			s.anim_busy = true   // (the next frame shows it in its zone)
		}
	}
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

// A zone's extent, in its own unit (sp.mem): the remembered one, else the space's (extent_frac, extent_em), else its
// first view's (extent_frac, extent_em, else its width or height), else VIEW_ZONE_EM. One of the two is set from then
// on: the handle keeps that unit.
@(private = "file")
view_zone_extent :: proc(sp: ^View_Space, e: View_Edge, first: ^View_Record) -> (em_size: f32, frac: f32) {
	m := &sp.mem
	if m.frac[e] > 0 { return 0, m.frac[e] }
	if m.extent[e] > 0 { return m.extent[e], 0 }
	o := first.kind.o
	switch {
	case sp.defaults.extent_frac[e] > 0: m.frac[e] = sp.defaults.extent_frac[e]
	case sp.defaults.extent_em[e] > 0:   m.extent[e] = sp.defaults.extent_em[e]
	case o.extent_frac > 0:              m.frac[e] = o.extent_frac
	case o.extent_em > 0:                m.extent[e] = o.extent_em
	case:
		x := e == .Left || e == .Right ? o.width_em : o.height_em
		m.extent[e] = x > 0 ? x : VIEW_ZONE_EM
	}
	m.frac[e] = clamp(m.frac[e], 0, 0.95)
	return m.extent[e], m.frac[e]
}

// The extent of a zone of `sp` in pixels, a space `length` long along it.
@(private = "file")
view_zone_px :: proc(sp: ^View_Space, e: View_Edge, em, length: f32) -> f32 {
	if sp.mem.frac[e] > 0 { return math.round(sp.mem.frac[e] * length) }
	return math.round((sp.mem.extent[e] > 0 ? sp.mem.extent[e] : VIEW_ZONE_EM) * em)
}

@(private = "file")
view_zone_box :: proc(sp: ^View_Space, e: View_Edge, first: ^View_Record, em: f32, maxed: bool, stacks: int) -> ^Box {
	axis := view_zone_axis(sp, e)
	// (a share is laid out against the space as this layout makes it, not the last one: it follows a resize at once)
	// (strict: the content gives way, as it does to a zone in ems)
	size :: proc(x, frac, em: f32) -> Size { return frac > 0 ? pct(frac, 1) : px(math.round(x * em)) }
	strip := math.round(DOCK_TAB_EM * em)
	switch {
	case maxed:
		next({width = fill(), height = fill(), axis = axis})   // (the one shown: the whole space)
	case sp.mem.minimised[e] && (e == .Top || e == .Bottom):
		// (its strips only: one row of them, or one above the other along a zone laid along Y)
		next({width = fill(), height = px(strip * f32(axis == .Y ? max(stacks, 1) : 1)), axis = axis})
	case e == .Left || e == .Right:
		x, frac := view_zone_extent(sp, e, first)
		next({width = size(x, frac, em), height = fill(), axis = axis})
	case e == .Top || e == .Bottom:
		x, frac := view_zone_extent(sp, e, first)
		next({width = fill(), height = size(x, frac, em), axis = axis})
	case:
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
	size := view_zone_px(sp, e, em, total * sc) / sc
	res := splitter(fmt.tprintf("###view_handle_%v", e), across ? .X : .Y, &size, least, max(total - least, least),
		{after = e == .Right || e == .Bottom, total = total > 0 ? total : 0, min_other = least})
	// (the drag kept in the zone's unit: a share stays a share, it goes on following the window)
	if res.changed {
		if sp.mem.frac[e] > 0 {
			if total > 0 { sp.mem.frac[e] = clamp(size / total, 0.01, 0.95) }
		} else {
			sp.mem.extent[e] = size * sc / em
		}
	}
	if res.finished { view_space_remember(vs, sp) }
}

// A zone's stacks in a row along its axis, a handle between two; in each, its tab strip (two views or more, a view
// `tabs_always`, a zone minimised), the view shown (not in a zone minimised), each view's menu. `only` >= 0: that
// stack alone, maximised.
@(private = "file")
view_zone_fill :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, z: ^View_Zone_Lists, zone: ^Box, em: f32, only: int) {
	s := gs()
	sc := max(s.scale, 0.01)
	axis := view_zone_axis(sp, e)
	n := 0
	for k in 0 ..< VIEW_STACKS_MAX { if len(z[k]) > 0 { n = k + 1 } }
	sp.count[e] = n
	minimised := sp.mem.minimised[e] && (e == .Top || e == .Bottom) && only < 0
	strip_h := math.round(DOCK_TAB_EM * em)
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
		if only >= 0 && k != only { continue }
		list := z[k][:]
		if len(list) == 0 { continue }
		last := k == n - 1 || only >= 0
		size := math.round(shares[k] * length)
		if minimised && axis == .Y {
			next({width = fill(), height = px(strip_h), axis = .Y})   // (one strip above the other)
		} else if last || length <= 0 {
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
		with_strip := minimised || len(list) >= 2
		for r in list { if r.kind.o.tabs_always { with_strip = true } }
		shown.strip_tools = 0
		if with_strip { view_stack_strip(vs, sp, e, k, list, shown, only >= 0) }
		if !minimised { view_panel_build(vs, sp, shown, with_strip) }
		pop_parent()
		for r in list { view_header_menu(vs, r, .Panel) }
		if last || length <= 0 || (minimised && axis == .Y) { continue }
		// (the handle after it: its share of the zone, written when it is let go)
		logical := size / sc
		res := splitter(fmt.tprintf("###view_stack_handle_%v_%d", e, k), axis, &logical, least / sc, max((length - least) / sc, least / sc),
			{total = length / sc, min_other = least / sc})
		if res.changed && length > 0 { sp.mem.shares[e][k] = clamp(logical * sc / length, 0.01, 0.99) }
		if res.finished { view_space_remember(vs, sp) }
	}
	pop_parent()
}

// The tab strip of a stack (section 2.5, rule 2b), left to right: a tab each (its title: a click shows it and restores
// a zone minimised, a drag takes it out as an internal window, a right click opens its menu); the "+" of the shown
// view's kind (new_tab), where its new tab will be; the shown view's moves, small and weak; the slot of its program's
// tools (view_header_tools); at the right end, the stack's Minimise (top and bottom zones), Maximise and Close, drawn
// as a window's caption buttons (caption_row).
@(private = "file")
view_stack_strip :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, k: int, list: []^View_Record, shown: ^View_Record, maxed: bool) {
	s := gs()
	em := font_size()
	labels := view_labels(vs)
	minimised := sp.mem.minimised[e] && !maxed
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
		if sig.clicked {
			if !on {
				delete(sp.active[e][k], vs.allocator)
				sp.active[e][k] = strings.clone(r.modal_name, vs.allocator)
			}
			if minimised { view_stack_minimise(vs, sp, e, false) }
		}
		if sig.right_clicked { menu_open(view_menu_id(r), mouse_pos(), tb.key, search = false) }
		if sig.dragging { view_panel_drag(vs, r, tb.key, sig, em) }
	}
	// the "+": right after the last tab, where the new one comes
	if shown.kind.o.new_tab != nil && view_header_icon("view_new_tab", lucide.PLUS, view_new_tab_label(vs, shown.kind), true) {
		view_new_tab(vs, shown)
	}
	// the shown view's moves, where the eye already is
	spacer(px(em * 0.4))
	if view_header_icon("view_detach", lucide.PICTURE_IN_PICTURE_2, labels.floating, true) { view_float(vs, shown) }
	if view_header_icon("view_window", lucide.EXTERNAL_LINK, labels.window, views_windows_ready(vs)) {
		view_apply(vs, shown, {kind = .Present, as = .External})
	}
	if !view_machine_at_home(shown.machine) && view_header_icon("view_reattach", lucide.UNDO_2, labels.reattach, true) {
		view_apply(vs, shown, {kind = .Reattach})
	}
	// the program's tools of the shown view: its body fills this slot (view_header_tools)
	spacer(px(em * 0.4))
	next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
	shown.strip_tools = build_box({}, "###view_strip_tools").key
	spacer(fill())
	// the stack's own, at the right end, as a window's: Minimise where a strip is the zone's height
	buttons := bit_set[platform.Caption_Button]{.Maximize, .Close}
	if e == .Top || e == .Bottom { buttons += {.Minimize} }
	names := [4]string{minimised ? labels.restore : labels.minimize, labels.maximize, labels.close_stack, labels.restore}
	ids := [platform.Caption_Button]string{.Minimize = "###view_stack_min", .Maximize = "###view_stack_max", .Close = "###view_stack_close"}
	clicked, ok, _ := caption_row(ids, buttons, maxed, s.window == nil || s.window.active, names)
	if !ok { return }
	switch clicked {
	case .Minimize:
		sp.max_edge = nil
		view_stack_minimise(vs, sp, e, !minimised)
	case .Maximize:
		if maxed { sp.max_edge = nil } else { sp.max_edge, sp.max_stack = e, k }
	case .Close:
		// (every view of the stack: the stack's button; one tab closes by Ctrl+W, its menu, the palette)
		if maxed { sp.max_edge = nil }
		for r in list { view_apply(vs, r, {kind = .User_Close}) }
	}
	s.anim_busy = true
}

// A zone at the top or the bottom shows its strips only (`on`), or its stacks again; remembered in the space's line.
@(private = "file")
view_stack_minimise :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, on: bool) {
	if sp.mem.minimised[e] == on { return }
	sp.mem.minimised[e] = on
	view_space_remember(vs, sp)
	vs.version += 1
	if sp.state != nil { sp.state.anim_busy = true }
}

// Whether a stack of `vs`'s space `name` is maximised (its strip's Maximise), and which.
views_space_maximised :: proc(vs: ^Views, name: string) -> (edge: View_Edge, stack: int, ok: bool) {
	sp, found := vs.spaces[name]
	if !found { return }
	edge, ok = sp.max_edge.?
	return edge, sp.max_stack, ok
}

// The view as a panel: its body fills its stack; its keys while the focus is in it; on the hover of its top area, its
// two icons (Detach, Close) over the body's top right corner, unless its stack shows a strip (`with_strip`: the strip
// holds them); a right click there opens its menu.
@(private = "file")
view_panel_build :: proc(vs: ^Views, sp: ^View_Space, r: ^View_Record, with_strip: bool) {
	s := gs()
	k := r.kind
	em := font_size()
	r.flag, r.ending, r.tools, r.header = true, nil, 0, 0
	next({width = fill(), height = fill(), axis = .Y})
	// (its key its name's alone: a panel opened late is built at end_build first, then in its zone; its field keeps its
	// key, and the focus its first build gave it)
	s.key_rooted = true
	body := build_box({.Clip}, fmt.tprintf("###view_panel_%s", r.modal_name))
	r.panel = body.key
	r.roots[.Panel] = body.key
	r.pbuilt = s.build_index
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
	if !with_strip && (over || view_held_within(s, body.key)) {
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
	// (the view's menu only where nothing of the body takes the right press: the box a press there acts on (hot_key, by
	// the last layout) is none of the body's, and the body opened no menu in this build. A tab in the band with a menu
	// of its own keeps it: its right click comes at the release, the view's menu would have replaced it at the press)
	if s.pressed_any[.Right] && over && !view_body_takes(s, body.key) && !menu_opened_now(s) {
		menu_open(view_menu_id(r), mouse_pos(), body.key, search = false)
	}
	if view_focus_inside(s, body.key) && r.flag && r.ending == nil {
		if key_press(.W, {.Ctrl}) {
			r.flag = false
		} else if key_press(.Escape) {
			// (an Escape it did not take: its stack maximised comes back to its size; else the focus goes back to the
			// content, the panel stays)
			if e, maxed := sp.max_edge.?; maxed && e == r.machine.place.edge && sp.max_stack == r.machine.place.stack {
				sp.max_edge = nil
				s.anim_busy = true
			} else {
				s.focus_key = 0
			}
		}
	}
	view_build_ended(vs, r)
}

// Whether the box a press at the pointer acts on (the last layout's hot box) is in the body under `root`, not `root`.
@(private = "file")
view_body_takes :: proc(s: ^State, root: Key) -> bool {
	if s.hot_key == 0 || s.hot_key == root { return false }
	for b := s.boxes[s.hot_key] or_else nil; b != nil; b = b.parent {
		if b.key == root { return true }
	}
	return false
}

// Whether a menu opened in this build (a level of it, or one waiting for the block of an open menu to end).
@(private)
menu_opened_now :: proc(s: ^State) -> bool {
	for lv in s.menus { if lv.open_build == s.build_index { return true } }
	if lv, ok := s.menu_next.?; ok && lv.open_build == s.build_index { return true }
	return false
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
	length := e == .Left || e == .Right ? r.max.x - r.min.x : r.max.y - r.min.y
	ext := min(view_zone_px(sp, e, em, length), length * 0.4)
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
View_Act :: enum u8 { Window, Float, Dock_Left, Dock_Right, Dock_Bottom, Reattach, Close, New_Tab }

// The view a command acts on, and how. Its strings are the view's: valid while it is open.
View_Command :: struct {
	id, instance: string,
	act:          View_Act,
}

// A command per act of each open view of `vs`, in the language in use ("Float Properties", "Dock Properties to the
// right"...): an act that does nothing where the view is is absent. `acts[i]` is what `commands[i]` does
// (views_command_run). Make them again when views_version changes.
// `owner`: only the views that window owns (the window's own palette lists its own views' moves, its palette and its
// sheet included); nil: every view.
views_commands :: proc(vs: ^Views, allocator := context.temp_allocator, owner: ^State = nil) -> (commands: []Command, acts: []View_Command) {
	cmds := make([dynamic]Command, 0, 4 * len(vs.records), allocator)
	what := make([dynamic]View_Command, 0, 4 * len(vs.records), allocator)
	group := i18n.tr("Views")
	new_tabs := make(map[^View_Kind]bool, 4, context.temp_allocator)   // (one "New tab" per kind: its first open view's)
	for r in vs.records {
		m := r.machine
		if m.state == .Closed || m.state == .Dragged || (owner != nil && r.owner != owner) { continue }
		title := view_title_shown(r)
		add :: proc(cmds: ^[dynamic]Command, what: ^[dynamic]View_Command, r: ^View_Record, act: View_Act, word, title, group, icon: string, allocator := context.allocator) {
			append(cmds, Command{label = fmt.aprintf(word, title, allocator = allocator), group = group, icon = icon})
			append(what, View_Command{id = r.kind.id, instance = r.instance, act = act})
		}
		if r.kind.o.new_tab != nil && !(r.kind in new_tabs) {
			new_tabs[r.kind] = true
			// (the program's words, whole: no title in them)
			append(&cmds, Command{label = strings.clone(view_new_tab_label(vs, r.kind), allocator), group = group, icon = lucide.PLUS})
			append(&what, View_Command{id = r.kind.id, instance = r.instance, act = .New_Tab})
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
	case .New_Tab:     view_new_tab(vs, r)
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
	owner:     ^State,   // the window whose views they are (nil: every view)
	allocator: runtime.Allocator,
}

// Makes `vc` again when the views of `vs` changed since (views_version) or the language did; true: they did, the
// program builds its palette's table again (its own commands first, then these: the palette folds each slot's text once,
// and the program's slots stay where they were) and calls palette_set. Cost: one pass over the open views, only then.
// `owner`: only the views that window owns (a program of several windows keeps one View_Commands per window); nil: all.
views_commands_update :: proc(vc: ^View_Commands, vs: ^Views, owner: ^State = nil) -> (changed: bool) {
	views_ready(vs)
	language := i18n.version()
	if vc.made && vc.version == vs.version && vc.language == language && vc.owner == owner { return false }
	views_commands_destroy(vc)
	vc.allocator, vc.owner = vs.allocator, owner
	commands, acts := views_commands(vs, context.temp_allocator, owner)
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
