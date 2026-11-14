package ui

// The Panel presentation and the dock spaces (src/md/features/views.md, section 6): a space has four zones, one per edge,
// around its content; a zone is one stack of views, with a tab strip only from two views; a lone panel adds nothing to
// what its view draws, but two small icons on the hover of its top area. While a view is dragged, each space built shows
// its four targets; a view released over one docks there.
//
//   if ui.views_frame(vs) { ...the program's content... }     the window's frame: its space "", its internal windows
//   if ui.views_dock(vs, "mission", {}) {}                     a space of the program's own, inside its content

import "core:fmt"
import "core:math"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import store "../store"

// A zone's extent when nothing else gives one (ems), and the top area of a panel whose hover shows its icons (ems).
VIEW_ZONE_EM :: f32(18)
VIEW_HOVER_EM :: f32(2.2)

// A dock space: its zones' extents (the memory's `#<space>` line) and what its last build laid out.
@(private)
View_Space :: struct {
	name:    string,               // owned ("": the window's frame)
	extent:  [View_Edge]f32,       // ems (0: none yet)
	active:  [View_Edge]string,    // owned: the modal name of the tab shown ("": the last docked)
	built:   u64,                  // the build that last built it
	state:   ^State,
	rect:    Rect,                 // window px, as laid out by its last build
	zone:    [View_Edge]Rect,      // ... each zone's ({}: none)
	zone_key: [View_Edge]Key,
	content: Key,
}

// What views_dock makes: with `content`, the block is its centre (the program's content); without, panels only.
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
	sp.built, sp.state = s.build_index, s
	if name == "" { views_f6(s, vs, sp) }

	// the views docked here, each zone's in the order they docked
	zones: [View_Edge][dynamic]^View_Record
	for e in View_Edge { zones[e] = make([dynamic]^View_Record, 0, 2, context.temp_allocator) }
	for r in vs.records {
		if r.owner == s && view_builds_panel(r.machine) && r.machine.place.space == name { append(&zones[r.machine.place.edge], r) }
	}
	for e in View_Edge {
		z := zones[e][:]
		for i in 1 ..< len(z) {   // (a few tabs: insertion by dock order)
			x := z[i]
			j := i - 1
			for j >= 0 && z[j].dock_order > x.dock_order { z[j + 1] = z[j]; j -= 1 }
			z[j + 1] = x
		}
	}

	// the layout: the top zone, the left, the content, the right, the bottom; each zone's handle on its content's side
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
	sp.zone, sp.zone_key = {}, {}
	if len(zones[.Top]) > 0 { boxes[.Top] = view_zone_box(sp, .Top, zones[.Top][0], em); view_zone_handle(vs, sp, .Top, em) }
	next({width = fill(), height = fill(), axis = .X})
	push_parent(build_box({}, "###views_mid"))
	if len(zones[.Left]) > 0 { boxes[.Left] = view_zone_box(sp, .Left, zones[.Left][0], em); view_zone_handle(vs, sp, .Left, em) }
	next({width = fill(), height = fill(), axis = .Y})
	centre := build_box({}, "###views_content")
	sp.content = centre.key
	if len(zones[.Right]) > 0 { view_zone_handle(vs, sp, .Right, em); boxes[.Right] = view_zone_box(sp, .Right, zones[.Right][0], em) }
	pop_parent()   // mid
	if len(zones[.Bottom]) > 0 { view_zone_handle(vs, sp, .Bottom, em); boxes[.Bottom] = view_zone_box(sp, .Bottom, zones[.Bottom][0], em) }
	pop_parent()   // col
	pop_parent()   // space

	vs.building += 1
	for e in View_Edge {
		if boxes[e] != nil { view_zone_fill(vs, sp, e, zones[e][:], boxes[e]) }
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

// The space `name` of `vs` (made at its first use, its zones' extents from the memory).
@(private)
view_space_of :: proc(vs: ^Views, name: string) -> ^View_Space {
	if sp, ok := vs.spaces[name]; ok { return sp }
	context.allocator = vs.allocator
	sp := new(View_Space)
	sp.name = strings.clone(name)
	if text, found := store.get(&vs.memory, view_space_key(name)); found {
		if ext, ok := views_space_parse(text); ok { sp.extent = ext }
	}
	vs.spaces[sp.name] = sp
	return sp
}

@(private)
view_space_free :: proc(sp: ^View_Space) {
	delete(sp.name)
	for a in sp.active { delete(a) }
	free(sp)
}

@(private = "file")
view_space_key :: proc(name: string) -> string { return fmt.tprintf("#%s", name) }

// `r` is the tab shown in its zone, the last docked there (it settled as a Panel, it was dropped or moved there).
@(private)
view_space_activate :: proc(vs: ^Views, r: ^View_Record) {
	if view_built_as(r.machine.as) != .Panel { return }
	context.allocator = vs.allocator
	vs.dock_next += 1
	r.dock_order = vs.dock_next
	sp := view_space_of(vs, r.machine.place.space)
	e := r.machine.place.edge
	delete(sp.active[e])
	sp.active[e] = strings.clone(r.modal_name)
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
	if sp.extent[e] > 0 { return sp.extent[e] }
	o := first.kind.o
	x := o.extent_em
	if x <= 0 { x = e == .Left || e == .Right ? o.width_em : o.height_em }
	if x <= 0 { x = VIEW_ZONE_EM }
	sp.extent[e] = x
	return x
}

@(private = "file")
view_zone_box :: proc(sp: ^View_Space, e: View_Edge, first: ^View_Record, em: f32) -> ^Box {
	ext := math.round(view_zone_extent(sp, e, first) * em)
	if e == .Left || e == .Right { next({width = px(ext), height = fill(), axis = .Y}) } else { next({width = fill(), height = px(ext), axis = .Y}) }
	// (no background, no border of its own: a lone panel adds nothing, rule 1)
	b := build_box({.Clip}, fmt.tprintf("###view_zone_%v", e))
	sp.zone[e], sp.zone_key[e] = b.rect, b.key
	return b
}

// The handle between a zone and the content: the content keeps DOCK_MIN_EM; the extent is written when it is let go.
@(private = "file")
view_zone_handle :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, em: f32) {
	s := gs()
	sc := max(s.scale, 0.01)
	across := e == .Left || e == .Right
	total := (across ? sp.rect.max.x - sp.rect.min.x : sp.rect.max.y - sp.rect.min.y) / sc
	least := DOCK_MIN_EM * em / sc
	size := sp.extent[e] * em / sc
	res := splitter(fmt.tprintf("###view_handle_%v", e), across ? .X : .Y, &size, least, max(total - least, least),
		{after = e == .Right || e == .Bottom, total = total > 0 ? total : 0, min_other = least})
	if res.changed { sp.extent[e] = size * sc / em }
	if res.finished { _ = store.set(&vs.memory, view_space_key(sp.name), views_space_format(sp.extent)) }
}

// A zone's views: the tab strip from two, the one shown, each one's menu.
@(private = "file")
view_zone_fill :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, list: []^View_Record, zone: ^Box) {
	shown := list[len(list) - 1]
	for r in list { if r.modal_name == sp.active[e] { shown = r } }
	push_parent(zone)
	if len(list) >= 2 { view_zone_tabs(vs, sp, e, list, shown) }
	view_panel_build(vs, sp, shown)
	pop_parent()
	for r in list { view_header_menu(vs, r, .Panel) }
}

// The tab strip of a zone of two views or more: a tab each (its icon, its title); a click shows it, a drag takes it out
// as an internal window, a right click opens its menu.
@(private = "file")
view_zone_tabs :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, list: []^View_Record, shown: ^View_Record) {
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
			delete(sp.active[e], vs.allocator)
			sp.active[e] = strings.clone(r.modal_name, vs.allocator)
		}
		if sig.right_clicked { menu_open(view_menu_id(r), mouse_pos(), tb.key, search = false) }
		if sig.dragging { view_panel_drag(vs, r, tb.key, sig, em) }
	}
}

// The view as a panel: its body fills its zone; its keys while the focus is in it; on the hover of its top area, its
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

// The dock target under `p`: a space of a Views of `s`, built in this build or the last, and the edge of the square
// that holds `p`.
@(private)
view_target_at :: proc(s: ^State, p: Vec2) -> (place: View_Place, ok: bool) {
	em := font_size()
	for vs in s.views_attached {
		for _, sp in vs.spaces {
			if sp.state != s || sp.built + 1 < s.build_index || sp.rect == {} { continue }
			for e in View_Edge {
				if view_rect_has(view_target_square(sp.rect, e, em), p) { return {space = sp.name, edge = e}, true }
			}
		}
	}
	return {}, false
}

// The square of edge `e` of a space: at the middle of that edge, DOCK_MARKER_GAP_EM inside it.
@(private = "file")
view_target_square :: proc(r: Rect, e: View_Edge, em: f32) -> Rect {
	m := math.round(DOCK_MARKER_EM * em)
	g := math.round(DOCK_MARKER_GAP_EM * em)
	c := (r.min + r.max) * 0.5
	at: Vec2
	switch e {
	case .Left:   at = {r.min.x + g, c.y - m * 0.5}
	case .Right:  at = {r.max.x - g - m, c.y - m * 0.5}
	case .Top:    at = {c.x - m * 0.5, r.min.y + g}
	case .Bottom: at = {c.x - m * 0.5, r.max.y - g - m}
	}
	at = {math.round(at.x), math.round(at.y)}
	return {at, at + m}
}

// Where a view dropped at edge `e` would be: the zone there, else a strip of its extent along that edge.
@(private = "file")
view_target_preview :: proc(sp: ^View_Space, e: View_Edge, em: f32) -> Rect {
	if z := sp.zone[e]; z.max.x > z.min.x { return z }
	r := sp.rect
	ext := min(math.round((sp.extent[e] > 0 ? sp.extent[e] : VIEW_ZONE_EM) * em), (e == .Left || e == .Right ? r.max.x - r.min.x : r.max.y - r.min.y) * 0.4)
	switch e {
	case .Left:   return {r.min, {r.min.x + ext, r.max.y}}
	case .Right:  return {{r.max.x - ext, r.min.y}, r.max}
	case .Top:    return {r.min, {r.max.x, r.min.y + ext}}
	case .Bottom: return {{r.min.x, r.max.y - ext}, r.max}
	}
	return {}
}

// end_build: while a view of `s` is dragged, the four squares of each space built in this build, and the preview of the
// one under the pointer. Only during a drag.
@(private)
views_build_targets :: proc(s: ^State) {
	dragged := false
	for vs in s.views_attached {
		for r in vs.records { if r.owner == s && r.machine.state == .Dragged { dragged = true } }
	}
	if !dragged { return }
	em := font_size()
	p := mouse_pos()
	push_parent(s.root)
	push_tags_isolated("floating")
	defer { pop_tags_isolated(); pop_parent() }
	for vs in s.views_attached {
		for _, sp in vs.spaces {
			if sp.state != s || sp.built != s.build_index || sp.rect == {} { continue }
			for e in View_Edge {
				sq := view_target_square(sp.rect, e, em)
				lit := view_rect_has(sq, p)
				if lit {
					pr := view_target_preview(sp, e, em)
					next({fixed_x = pr.min.x, fixed_y = pr.min.y, width = px(pr.max.x - pr.min.x), height = px(pr.max.y - pr.min.y), transparency = 0.6, radius = em * DOCK_MARKER_RADIUS_EM})
					if tags("selected") { build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###view_preview_%s_%v", sp.name, e)) }
				}
				next({fixed_x = sq.min.x, fixed_y = sq.min.y, width = px(sq.max.x - sq.min.x), height = px(sq.max.y - sq.min.y), radius = em * DOCK_MARKER_RADIUS_EM})
				if tags(lit ? "selected" : "button") {
					b := build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###view_target_%s_%v", sp.name, e))
					a11y_default(b, {ignore = true})
				}
			}
		}
	}
}

////////////////////////////////
// F6

// F6 and Shift+F6 in the window's frame: the focus to the first stop of the next or the previous area (the content,
// each zone, each internal window).
@(private = "file")
views_f6 :: proc(s: ^State, vs: ^Views, sp: ^View_Space) {
	forward := key_press(.F6)
	backward := !forward && key_press(.F6, {.Shift})
	if !forward && !backward { return }
	areas := make([dynamic]Key, 0, 8, context.temp_allocator)
	if sp.content != 0 { append(&areas, sp.content) }
	for e in View_Edge { if sp.zone_key[e] != 0 { append(&areas, sp.zone_key[e]) } }
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
View_Act :: enum u8 { Float, Dock_Left, Dock_Right, Dock_Bottom, Reattach, Close }

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
		if m.as != .Internal { add(&cmds, &what, r, .Float, i18n.tr("Float %s"), title, group, lucide.PICTURE_IN_PICTURE_2, allocator) }
		if view_frame_built(vs, r.owner) {
			edges := [3]View_Edge{.Left, .Right, .Bottom}
			words := [3]string{i18n.tr("Dock %s to the left"), i18n.tr("Dock %s to the right"), i18n.tr("Dock %s to the bottom")}
			icons := [3]string{lucide.PANEL_LEFT, lucide.PANEL_RIGHT, lucide.PANEL_BOTTOM}
			dock_acts := [3]View_Act{.Dock_Left, .Dock_Right, .Dock_Bottom}
			for e, i in edges {
				if m.as == .Panel && m.place == (View_Place{edge = e}) { continue }
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
	case .Float:       view_float(vs, r)
	case .Dock_Left:   view_dock_at(vs, r, .Left)
	case .Dock_Right:  view_dock_at(vs, r, .Right)
	case .Dock_Bottom: view_dock_at(vs, r, .Bottom)
	case .Reattach:    view_apply(vs, r, {kind = .Reattach})
	case .Close:       view_apply(vs, r, {kind = .User_Close})
	}
}

// What changes the list of views_commands: a view opened, closed or moved. The program gives it to palette_set.
views_version :: proc(vs: ^Views) -> u64 { return vs.version }

@(private = "file")
view_dock_at :: proc(vs: ^Views, r: ^View_Record, e: View_Edge) {
	view_apply(vs, r, {kind = .Present, as = .Panel, place = {edge = e}})
	view_space_activate(vs, r)
}
