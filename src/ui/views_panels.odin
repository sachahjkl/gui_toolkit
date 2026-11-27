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
import "../draw"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import store "../store"

// A zone's extent when nothing else gives one (ems).
VIEW_ZONE_EM :: f32(18)
// A lone panel's strip (view_hover_strip): the band at the stack's top edge where the pointer arms it (ems), and how
// long the pointer rests there before it shows (ms). Its own delay, not a Feel one: a submenu delay set to 0 would
// show the strip on the first build of a pointer that only crosses the band (views.md, section 2.5, rule 2).
VIEW_HOVER_EDGE_EM :: f32(0.6)
VIEW_HOVER_DWELL_MS :: 300

// The states of a lone panel's strip: at rest; armed (the pointer rests in the top band since View_Record.hover_since);
// shown until the pointer leaves the stack.
@(private)
View_Hover :: enum u8 { Rest, Armed, Shown }

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
	handle_key: [View_Edge]Key,                         // ... each zone's handle (view_dock_line)
	stacks:    [View_Edge][VIEW_STACKS_MAX]Rect,        // ... each stack's, by rank ({}: none)
	stack_key: [View_Edge][VIEW_STACKS_MAX]Key,
	count:     [View_Edge]int,                          // ... how many stacks each zone had
	content:   Key,
	middle:    Rect,                                    // ... the centre's (the content, or the centre zone)
	key:       Key,                                     // its box's: the content's and the zones' keys come from it (State.key_under)
	// the spans its last build laid out (.Top, .Bottom; section 6.1b): what it was asked, but the top's yield in a pinwheel
	laid_span: [View_Edge]View_Span,
	has_content: bool,                                  // the program's content is its centre (else its centre is a zone)
	em:        f32,                                     // its font size in its last build (the targets' size, read from another window too)
	defaults:  View_Dock_Options,                       // what its last build gave (its zones' extents at first)
	// the stack of mem.max showed maximised in this run (a stack that then empties ends it; at a start it waits for its
	// views: section 6.1d)
	max_seen:  bool,
	// the program's content is laid out at no size in its last build (a view in the main zone, a maximise)
	content_hidden: bool,
	// a side zone's rail width (em) this build: the largest View_Options.rail_em of its views (0: the icons' rail)
	rail_em:   [View_Edge]f32,
	// a side zone's least open (em): the largest View_Options.min_width_em of its views (0: its extent, it does not narrow)
	least_em:  [View_Edge]f32,
	// what view_sides_fit gave a side zone this build (px): the width it shows (0: its extent, unfitted), and its room
	// (the space less the other side; 0: the space's)
	shown:     [View_Edge]f32,
	room:      [View_Edge]f32,
}

// Whether zone `e` shows collapsed: its fold (a side zone's Side_Fold: by the rule or by the user; a top or bottom
// zone's Minimise).
@(private = "file")
view_zone_collapsed :: proc(sp: ^View_Space, e: View_Edge) -> bool { return sp.mem.fold[e].folded }

// The side zones' rule, both together (side-panels.md, Two sides), on the space's last width: the right zone narrows
// to its least, then folds to its rail when even its least leaves the content less than DOCK_MIN_EM (open again past
// DOCK_MIN_EM plus SIDE_FOLD_GAP_EM); then the left does the same, its room the space less the right's rail. The left
// is decided first, and the right's room is what the left shows: the left never reads the right's state, so the two
// cannot wait for each other. A crossing ends a Minimise or a Restore of the user's, and is remembered. Only where the
// centre is the program's content; elsewhere (and before the first layout) each zone shows at its extent or its rail.
@(private = "file")
view_sides_fit :: proc(vs: ^Views, sp: ^View_Space, left, right: ^View_Record, content: bool, em: f32) {
	sp.shown, sp.room = {}, {}
	width := sp.rect.max.x - sp.rect.min.x
	if !content || width <= 0 { return }
	has_left, has_right := left != nil, right != nil
	// (a side zone's handle takes this much of the row, folded too: its rail's edge line)
	handle := math.round(SPLITTER_THICKNESS_PX * max(gs().scale, 0.01))
	content_min, gap := DOCK_MIN_EM * em, SIDE_FOLD_GAP_EM * em
	side :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, first: ^View_Record, room, width, handle, content_min, gap, em: f32) {
		// (the zone's extent as its box will take it in this build: a zone that just opened has none remembered yet)
		_, _ = view_zone_extent(sp, e, first)
		extent := view_zone_px(sp, e, em, width)
		least := sp.least_em[e] > 0 ? min(math.round(sp.least_em[e] * em), extent) : extent
		if side_fold_follow(&sp.mem.fold[e], room, least, content_min, gap) {
			view_space_remember(vs, sp)
			vs.version += 1
		}
		rail := view_rail_px(sp, e, em)
		// (open: its extent, or narrower down to its least so the content keeps its own; never past the space's edge,
		// even opened by the person while narrow)
		w := sp.mem.fold[e].folded ? rail : clamp(room - content_min, least, extent)
		sp.shown[e] = max(min(w, room - handle), min(rail, max(room - handle, 0)))
		sp.room[e] = room
	}
	left_room, right_room := width, width
	if has_right { left_room -= view_rail_px(sp, .Right, em) + handle }
	if has_left {
		side(vs, sp, .Left, left, left_room, width, handle, content_min, gap, em)
		right_room -= sp.shown[.Left] + handle
	}
	if has_right { side(vs, sp, .Right, right, right_room, width, handle, content_min, gap, em) }
}

// What views_dock makes: with `content`, the block is its centre (the program's content); without, panels only, its
// centre a zone of its own. A zone's extent at first: `extent_frac` (a share of the space's width at the left and the
// right, of its height at the top and the bottom: it follows the window), else `extent_em`, else its first view's
// (View_Options.extent_frac, extent_em). What the user drags is remembered in the zone's unit.
View_Dock_Options :: struct {
	content:     bool,
	extent_em:   [View_Edge]f32,
	extent_frac: [View_Edge]f32,
	// how far the top and the bottom zones go across (views.md, section 6.1b); the person's choice wins
	// (views_space_set_span). nil: .Content for the window's frame, .Full for a space of the program's
	top_span:    Maybe(View_Span),
	bottom_span: Maybe(View_Span),
	// the zones the person's Maximise of a stack keeps (its strip's, its menu's, a double click on its strip; section
	// 6.1d): {.Left} keeps a sidebar. {}: the stack takes the whole space
	maximise_keeps: bit_set[View_Edge],
}

// How far a top or a bottom zone goes across its space: which zone takes each of its two corners (views.md, section
// 6.1b). .Content: across the content only, the side zones the space's full height; .Left: across the left zone too;
// .Right: across the right zone too; .Full: the whole width, the side zones between the top and the bottom.
View_Span :: enum u8 { Content, Left, Right, Full }

// The words of a span in a space's memory line (`bottom.span=content`).
@(rodata)
VIEW_SPAN_NAMES := [View_Span]string{.Content = "content", .Left = "left", .Right = "right", .Full = "full"}

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
		p := view_panel_place(r.machine)
		if r.owner != s || !view_builds_panel(r.machine) || p.space != name { continue }
		if r.ibuilt == s.build_index { continue }   // (floating this frame, its space was not built: from the next one here)
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

	// a stack maximised (section 6.1d): it fills the space but the zones it keeps, the other zones are not built, and the
	// content is laid out at no size (built: its state is kept). Its stack not there: at a start it waits for its views;
	// one that emptied after it showed ends it.
	mx, maxed := sp.mem.max.?
	maxed_e := mx.edge
	if maxed && (mx.stack < 0 || mx.stack >= VIEW_STACKS_MAX || len(zones[mx.edge][mx.stack]) == 0) {
		maxed = false
		if sp.max_seen {
			sp.mem.max, sp.max_seen = nil, false
			view_space_remember(vs, sp)
			vs.version += 1
		}
	}
	if maxed { sp.max_seen = true }
	for e in ([]View_Edge{.Left, .Right}) {
		sp.rail_em[e], sp.least_em[e] = 0, 0
		for k in 0 ..< VIEW_STACKS_MAX {
			for r in zones[e][k] {
				sp.rail_em[e] = max(sp.rail_em[e], r.kind.o.rail_em)
				sp.least_em[e] = max(sp.least_em[e], r.kind.o.min_width_em)
			}
		}
	}
	// (after the rails and the leasts: the fit reads both)
	first :: proc(z: ^View_Zone_Lists) -> ^View_Record { return len(z[0]) > 0 ? z[0][0] : nil }
	view_sides_fit(vs, sp, first(&zones[.Left]), first(&zones[.Right]), content, em)

	// the layout (section 6.1b): the zones peeled from the outside in, as far across as the spans say, each zone's
	// handle on the centre's side; maximised, the one stack's zone alone, the content at no size
	mod := s.has_next ? s.next_mod : Style_Mod{width = fill(), height = fill()}
	if mod.width == nil { mod.width = fill() }
	if mod.height == nil { mod.height = fill() }
	next(mod)
	space := build_box({}, fmt.tprintf("###views_space_%s", name))
	sp.rect, sp.key = space.rect, space.key
	push_parent(space)
	boxes: [View_Edge]^Box
	was_zones := sp.zone_key
	sp.zone, sp.zone_key, sp.stacks, sp.stack_key, sp.count = {}, {}, {}, {}, {}
	nest := View_Nest{vs = vs, sp = sp, zones = &zones, boxes = &boxes, em = em, content = content}
	nest.top, nest.bottom = view_space_spans(sp)
	// (around the centre: every zone with views, or, maximised, those it keeps; at the centre: the maximised stack's
	// zone, else the main zone when it has views (section 6.1c), else the content)
	rest: bit_set[View_Edge]
	for e in ([]View_Edge{.Top, .Left, .Right, .Bottom}) {
		if has(&zones[e]) && (!maxed || (e in mx.keep && e != maxed_e)) { rest += {e} }
	}
	if maxed {
		nest.centre_edge = maxed_e
	} else if has(&zones[.Center]) {
		nest.centre_edge = View_Edge.Center
	}
	view_space_nest(&nest, rest, 0)
	sp.laid_span[.Top], sp.laid_span[.Bottom] = nest.top, nest.bottom
	sp.middle = nest.centre.rect
	sp.content = nest.content_box != nil ? nest.content_box.key : 0
	_, sp.content_hidden = nest.centre_edge.?
	sp.content_hidden = sp.content_hidden && content
	pop_parent()   // space

	vs.building += 1
	for e in View_Edge {
		if boxes[e] != nil { view_zone_fill(vs, sp, e, &zones[e], boxes[e], em, maxed && e == maxed_e ? mx.stack : -1) }
	}
	// (a focus left where nobody sees it any more, the content under a main view or a zone a maximise hides: to the
	// first stop of what stands in the centre, section 6.1c, 6.1d)
	if ce, ok := nest.centre_edge.?; ok && boxes[ce] != nil {
		lost := sp.content_hidden && view_focus_inside(s, sp.content)
		for e in View_Edge { if boxes[e] == nil && was_zones[e] != 0 && view_focus_inside(s, was_zones[e]) { lost = true } }
		if lost { s.focus_key = view_first_stop(boxes[ce]) }
	}
	// (the frame's internal windows after its panels: a drop on a zone is built from the next frame, the window drawn in
	// this one; children of the root, they draw over the whole frame)
	if name == "" { views_build_internals(s) }
	vs.building -= 1
	views_sweep(vs)

	append(&s.views_space_stack, content)
	if content { push_parent(nest.content_box) }
	return content
}

// What the nest of a space's zones reads and fills (view_space_nest).
@(private = "file")
View_Nest :: struct {
	vs:          ^Views,
	sp:          ^View_Space,
	zones:       ^[View_Edge]View_Zone_Lists,
	boxes:       ^[View_Edge]^Box,
	em:          f32,
	content:     bool,       // the space has the program's content
	// the zone that stands at the centre: a maximised stack's (sized as the whole centre), the main zone (section 6.1c),
	// the centre zone of a space without content; nil: the content
	centre_edge: Maybe(View_Edge),
	top, bottom: View_Span,  // the spans laid out (the top's may yield: view_space_peel)
	centre:      ^Box,       // what stands at the centre
	content_box: ^Box,       // the program's content (at no size when a zone stands there)
}

// The spans of a space's top and bottom zones: the person's (its memory), else the program's (View_Dock_Options),
// else the toolkit's: .Content for the window's frame, .Full for a space of the program's (section 6.1b).
@(private = "file")
view_space_spans :: proc(sp: ^View_Space) -> (top, bottom: View_Span) {
	kind := sp.name == "" ? View_Span.Content : View_Span.Full
	top = sp.mem.span[.Top].? or_else (sp.defaults.top_span.? or_else kind)
	bottom = sp.mem.span[.Bottom].? or_else (sp.defaults.bottom_span.? or_else kind)
	return
}

// Which zone takes each corner: the top or the bottom zone (true), else the side zone there.
@(private = "file")
View_Corners :: struct { top_left, top_right, bottom_left, bottom_right: bool }

@(private = "file")
view_corners :: proc(top, bottom: View_Span) -> View_Corners {
	return {
		top_left     = top == .Left || top == .Full,
		top_right    = top == .Right || top == .Full,
		bottom_left  = bottom == .Left || bottom == .Full,
		bottom_right = bottom == .Right || bottom == .Full,
	}
}

// The zones of `rest` that take a whole side of what is left: each owns both of its corners, a corner whose other zone
// is not in `rest` counting as its own. They are on one axis: two zones that meet cannot both own their corner.
@(private = "file")
view_space_peel :: proc(rest: bit_set[View_Edge], top, bottom: View_Span) -> (peel: bit_set[View_Edge]) {
	c := view_corners(top, bottom)
	l, r, t, b := .Left in rest, .Right in rest, .Top in rest, .Bottom in rest
	if t && (c.top_left || !l) && (c.top_right || !r) { peel += {.Top} }
	if b && (c.bottom_left || !l) && (c.bottom_right || !r) { peel += {.Bottom} }
	if l && (!c.top_left || !t) && (!c.bottom_left || !b) { peel += {.Left} }
	if r && (!c.top_right || !t) && (!c.bottom_right || !b) { peel += {.Right} }
	return
}

// The zones of `rest` around the centre: those that take a whole side of it in a column (the top, the bottom) or a row
// (the left, the right), what is left between them, nested the same way, down to the centre. A pinwheel (the top
// .Left and the bottom .Right, or the mirror, the four zones there) has no zone to start with: the top gives way, laid
// out as .Content. The content's box and the zones' take their keys from the space's (State.key_under): a nest that
// changes keeps their state.
@(private = "file")
view_space_nest :: proc(n: ^View_Nest, rest: bit_set[View_Edge], depth: int) {
	sp, em := n.sp, n.em
	if rest == {} {
		ce, zone := n.centre_edge.?
		if zone {
			// (a zone at the centre: the whole of it, its maximised stack alone when it is one; view_zone_box's maxed)
			n.centre = view_zone_box(sp, ce, n.zones[ce][0][0], em, true, view_zone_stacks(&n.zones[ce]))
			n.boxes[ce] = n.centre
		}
		if n.content || !zone {
			// (under a zone: at no size, clipped; the same box, its content's state kept)
			next({width = zone ? px(0) : fill(), height = zone ? px(0) : fill(), axis = .Y})
			// (.Fits_Width: its width is what the zones leave, a split; least-width.md: else a wide content pushes the
			// right zone out of the space)
			gs().key_under = sp.key
			n.content_box = build_box(zone ? Box_Flags{.Clip, .Fits_Width} : Box_Flags{.Fits_Width}, "###views_content")
			if !zone { n.centre = n.content_box }
		}
		return
	}
	peel := view_space_peel(rest, n.top, n.bottom)
	if peel == {} {
		n.top = .Content
		peel = view_space_peel(rest, n.top, n.bottom)
	}
	across := peel & {.Top, .Bottom} != {}
	first, last := across ? View_Edge.Top : View_Edge.Left, across ? View_Edge.Bottom : View_Edge.Right
	next({width = fill(), height = fill(), axis = across ? .Y : .X})
	push_parent(build_box({}, fmt.tprintf("###views_nest_%d", depth)))
	if first in peel {
		n.boxes[first] = view_zone_box(sp, first, n.zones[first][0][0], em, false, view_zone_stacks(&n.zones[first]))
		view_space_handle(n.vs, sp, first, em)
	}
	view_space_nest(n, rest - peel, depth + 1)
	if last in peel {
		view_space_handle(n.vs, sp, last, em)
		n.boxes[last] = view_zone_box(sp, last, n.zones[last][0][0], em, false, view_zone_stacks(&n.zones[last]))
	}
	pop_parent()
}

// How many stacks a zone has (compact: its last rank with views, plus one).
@(private = "file")
view_zone_stacks :: proc(z: ^View_Zone_Lists) -> (n: int) {
	for k in 0 ..< VIEW_STACKS_MAX { if len(z[k]) > 0 { n = k + 1 } }
	return
}

// A zone's handle (a zone around the centre: one maximised stands at the centre and has none): not a top or bottom
// zone minimised to its strips; a side zone's rail keeps it (its edge line, and the pull that opens it).
@(private = "file")
view_space_handle :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, em: f32) {
	if !view_zone_collapsed(sp, e) || e == .Left || e == .Right { view_zone_handle(vs, sp, e, em) }
}

// The span of zone `e` along its edge as its space's last build laid it out, whether it is there or not: where its
// corners' zones leave it room (the content's rect says where they end). The preview of a drop there, and its square.
@(private = "file")
view_edge_span :: proc(sp: ^View_Space, e: View_Edge) -> (lo, hi: f32) {
	r, m := sp.rect, sp.middle
	if m.max.x <= m.min.x || m.max.y <= m.min.y { m = r }
	c := view_corners(sp.laid_span[.Top], sp.laid_span[.Bottom])
	#partial switch e {
	case .Top:    return c.top_left ? r.min.x : m.min.x, c.top_right ? r.max.x : m.max.x
	case .Bottom: return c.bottom_left ? r.min.x : m.min.x, c.bottom_right ? r.max.x : m.max.x
	case .Left:   return c.top_left ? m.min.y : r.min.y, c.bottom_left ? m.max.y : r.max.y
	case .Right:  return c.top_right ? m.min.y : r.min.y, c.bottom_right ? m.max.y : r.max.y
	}
	return
}

// The span of the top or the bottom zone of the space `name` (`edge` .Top or .Bottom; section 6.1b): the person's
// choice (`chosen`), else the program's (View_Dock_Options.top_span, bottom_span), else the toolkit's.
views_space_span :: proc(vs: ^Views, name: string, edge: View_Edge) -> (span: View_Span, chosen: bool) {
	views_ready(vs)
	sp := view_space_of(vs, name)
	top, bottom := view_space_spans(sp)
	#partial switch edge {
	case .Top:    _, chosen = sp.mem.span[.Top].?; return top, chosen
	case .Bottom: _, chosen = sp.mem.span[.Bottom].?; return bottom, chosen
	}
	return .Content, false
}

// The person's span of the top or the bottom zone of the space `name`, remembered in its line (`bottom.span=content`);
// nil forgets it: the program's again. The space is laid out so from its next build. Another edge: nothing.
views_space_set_span :: proc(vs: ^Views, name: string, edge: View_Edge, span: Maybe(View_Span)) {
	if edge != .Top && edge != .Bottom { return }
	views_ready(vs)
	sp := view_space_of(vs, name)
	sp.mem.span[edge] = span
	view_space_remember(vs, sp)
	vs.version += 1
	if sp.state != nil { sp.state.anim_busy = true }
}

// Opens the view `id` in the main zone of the window's frame, in place of the content (section 6.1c), or moves it there
// when it is open elsewhere; its home stays its own. The content comes back when the last view there closes or leaves.
view_show_main :: proc(vs: ^Views, id: string, data: ^$T, instance := "", owner: ^State = nil) {
	view_open(vs, id, data, instance, owner)
	view_present(vs, id, .Panel, View_Place{edge = .Center}, instance)
}

// The view the main zone of the space `space` shows (its first stack's tab shown): ok false while the content shows.
views_main :: proc(vs: ^Views, space := "") -> (id, instance: string, ok: bool) {
	sp, found := vs.spaces[space]
	shown: ^View_Record
	for r in vs.records {
		p := view_panel_place(r.machine)
		if !view_builds_panel(r.machine) || p.space != space || p.edge != .Center || p.stack != 0 { continue }
		if found && r.modal_name == sp.active[.Center][0] { shown = r; break }
		if shown == nil || r.dock_order > shown.dock_order { shown = r }
	}
	if shown == nil { return }
	return shown.kind.id, shown.instance, true
}

// The zones the last build of the space `name` laid out (none: not built yet). A setting shows the top's span only
// where there is a top zone.
views_space_zones :: proc(vs: ^Views, name: string) -> (zones: bit_set[View_Edge]) {
	sp, ok := vs.spaces[name]
	if !ok { return }
	for e in View_Edge { if sp.count[e] > 0 { zones += {e} } }
	return
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
	sp.max_seen = false
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

// `r`, docked and opened again, is the tab shown in its stack, its zone restored when it was minimised: what a click on
// its tab (or its rail's button) does. Unlike view_space_activate, its place among the tabs stays: the user ordered them.
@(private)
view_tab_show :: proc(vs: ^Views, r: ^View_Record) {
	context.allocator = vs.allocator
	sp := view_space_of(vs, r.machine.place.space)
	e, k := r.machine.place.edge, clamp(r.machine.place.stack, 0, VIEW_STACKS_MAX - 1)
	if sp.active[e][k] != r.modal_name {
		delete(sp.active[e][k])
		sp.active[e][k] = strings.clone(r.modal_name)
	}
	if view_zone_collapsed(sp, e) { view_stack_minimise(vs, sp, e, false) }
	if sp.state != nil { sp.state.anim_busy = true }
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
				// (one leaving is listed at the place it still shows in: that place moves; it goes elsewhere, nothing to
				// remember here)
				if r.machine.state == .Moving { r.machine.from_place.stack = to; continue }
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
			place := view_panel_place(r.machine)
			sp, ok := vs.spaces[place.space]
			if !ok || sp.state != s || sp.built != s.build_index {
				// (its space not built in this build: a frame-less window's panel floats at once; one of a space of the
				// program's waits there, not built, until the space is)
				if view_panel_floats(vs, r, s) { view_internal_build(vs, r, false) }
				continue
			}
			em := sp.em
			at := view_target_preview(sp, place.edge, em)
			push_parent(s.root)
			next({fixed_x = at.min.x, fixed_y = at.min.y, width = px(max(at.max.x - at.min.x, 1)), height = px(max(at.max.y - at.min.y, 1)), axis = .Y, transparency = 1})
			holder := build_box({}, fmt.tprintf("###view_late_%s", r.modal_name))
			push_parent(holder)
			view_panel_build(vs, sp, r)
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

// Where a view built as a panel is built: while it moves away, the place it still shows in (`from_place`), not the one it
// goes to (a panel moving into its own window was laid out at another edge, and its window took that size).
@(private)
view_panel_place :: proc(m: View_Machine) -> View_Place {
	return m.state == .Moving ? m.from_place : m.place
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
	case sp.defaults.extent_frac[e] > 0: frac = sp.defaults.extent_frac[e]
	case sp.defaults.extent_em[e] > 0:   em_size = sp.defaults.extent_em[e]
	case o.extent_frac > 0:              frac = o.extent_frac
	case o.extent_em > 0:                em_size = o.extent_em
	case:
		x := e == .Left || e == .Right ? o.width_em : o.height_em
		em_size = x > 0 ? x : VIEW_ZONE_EM
	}
	frac = clamp(frac, 0, 0.95)
	// (a view leaving the zone is still laid out there for its last frames, but the zone's extent is not its own: the
	// views that stay or come set it)
	if first.machine.state != .Moving { m.extent[e], m.frac[e] = em_size, frac }
	return
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
	case view_zone_collapsed(sp, e) && (e == .Top || e == .Bottom):
		// (its strips only: one row of them, or one above the other along a zone laid along Y)
		next({width = fill(), height = px(strip * f32(axis == .Y ? max(stacks, 1) : 1)), axis = axis})
	case view_zone_collapsed(sp, e):
		next({width = px(view_rail_px(sp, e, em)), height = fill(), axis = .Y})
	case e == .Left || e == .Right:
		x, frac := view_zone_extent(sp, e, first)
		// (narrowed by the fit of both sides: the width it gave, in pixels; else its extent, a share following a resize)
		w := size(x, frac, em)
		if sp.shown[e] > 0 && sp.shown[e] < view_zone_px(sp, e, em, sp.rect.max.x - sp.rect.min.x) { w = px(sp.shown[e]) }
		next({width = w, height = fill(), axis = axis})
	case e == .Top || e == .Bottom:
		x, frac := view_zone_extent(sp, e, first)
		next({width = fill(), height = size(x, frac, em), axis = axis})
	case:
		next({width = fill(), height = fill(), axis = axis})
	}
	// (no background, no border of its own: a lone panel adds nothing, rule 1)
	// (.Fits_Width: its width is its extent or the space's, a split, never its views'; least-width.md)
	// (its key from the space's: the nest around it changes with the spans and the zones there, section 6.1b)
	gs().key_under = sp.key
	b := build_box({.Clip, .Fits_Width}, fmt.tprintf("###view_zone_%v", e))
	sp.zone[e], sp.zone_key[e] = b.rect, b.key
	return b
}

// A side zone's rail width in pixels: its views' own compact column (View_Options.rail_em), else one strip wide, its
// buttons one above the other.
@(private = "file")
view_rail_px :: proc(sp: ^View_Space, e: View_Edge, em: f32) -> f32 {
	return math.round((sp.rail_em[e] > 0 ? sp.rail_em[e] : DOCK_TAB_EM) * em)
}

// Where a zone's handle draws its rule.
@(private = "file")
VIEW_HANDLE_LINE :: Splitter_Line.Middle

// Where zone `e`'s handle draws its rule in the space `space` ("": the window's frame), in window pixels: from this
// frame's layout when called after it (a box's custom draw), else from the last one. A program's own line that goes on
// across a bar (a title bar's, a status bar's) takes its place from here, never from a width of its own: one value, the
// same pixel column during a drag and after it; a side zone's rail has it too. ok = false: no handle there in its last
// build (nothing docked, a top or bottom zone minimised, a stack maximised).
view_dock_line :: proc(vs: ^Views, e: View_Edge, space := "") -> (line: Rect, ok: bool) {
	sp, found := vs.spaces[space]
	if !found || sp.state == nil || sp.handle_key[e] == 0 { return }
	b := sp.state.boxes[sp.handle_key[e]] or_else nil
	if b == nil || b.last_build != sp.built { return }
	return splitter_line(b.rect, VIEW_HANDLE_LINE, splitter_line_width(sp.state.scale)), true
}

// What a drag of a side zone's handle keeps from its press: the zone's extent then, in its own unit, which a fold
// during the drag puts back exactly (Restore brings it).
@(private = "file")
View_Zone_Pull :: struct { extent, frac: f32, taken: bool }

// The handle between a zone and the centre: the centre keeps DOCK_MIN_EM; the extent is written when it is let go.
// A side zone's handle is side_handle (side-panels.md): built collapsed too (its rail's edge line), its drag says the
// state (pulling the rail opens the zone, a push into it folds it). The keys never fold it.
@(private = "file")
view_zone_handle :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, em: f32) {
	s := gs()
	sc := max(s.scale, 0.01)
	across := e == .Left || e == .Right
	total := (across ? sp.rect.max.x - sp.rect.min.x : sp.rect.max.y - sp.rect.min.y) / sc
	least := DOCK_MIN_EM * em / sc
	most := max(total - least, least)
	id := fmt.tprintf("###view_handle_%v", e)
	after := e == .Right || e == .Bottom
	// (the extent in the zone's unit: a share stays a share, it goes on following the window)
	write :: proc(sp: ^View_Space, e: View_Edge, size, total, sc, em: f32) {
		if sp.mem.frac[e] > 0 {
			if total > 0 { sp.mem.frac[e] = clamp(size / total, 0.01, 0.95) }
		} else {
			sp.mem.extent[e] = size * sc / em
		}
	}
	if !across {
		size := view_zone_px(sp, e, em, total * sc) / sc
		res := splitter(id, .Y, &size, least, most, {after = after, total = max(total, 0), min_other = least, line_at = VIEW_HANDLE_LINE})
		if res.box == nil { return }
		sp.handle_key[e] = res.box.key
		if res.changed { write(sp, e, size, total, sc, em) }
		if res.finished { view_space_remember(vs, sp) }
		return
	}
	collapsed := view_zone_collapsed(sp, e)
	// (a zone narrowed by the fit of both sides is dragged from the width it shows, and within its own room: the space
	// less the other side)
	extent := view_zone_px(sp, e, em, total * sc)
	size := (sp.shown[e] > 0 ? min(sp.shown[e], extent) : extent) / sc
	room := sp.room[e] > 0 ? sp.room[e] / sc : total
	h := side_handle(id, collapsed, &size, view_rail_px(sp, e, em) / sc, least, max(room - least, least),
		{after = after, total = max(room, 0), min_other = least, line_at = VIEW_HANDLE_LINE})
	if h.box == nil { return }
	sp.handle_key[e] = h.box.key
	pull := press_data(View_Zone_Pull, h.box.key)
	if pull != nil && !pull.taken { pull^ = {extent = sp.mem.extent[e], frac = sp.mem.frac[e], taken = true} }
	if h.fold_changed {
		view_zone_unmaximise(vs, sp, e)
		view_stack_minimise(vs, sp, e, h.fold)
	}
	if h.dragging && h.fold && pull != nil {
		sp.mem.extent[e], sp.mem.frac[e] = pull.extent, pull.frac
	} else if h.changed && !h.fold {
		write(sp, e, size, total, sc, em)
	}
	if h.finished { view_space_remember(vs, sp) }
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
	if (e == .Left || e == .Right) && view_zone_collapsed(sp, e) && only < 0 {
		if sp.rail_em[e] > 0 { view_zone_rail_views(vs, sp, e, z, zone, n) } else { view_zone_rail(vs, sp, e, z, zone, n) }
		return
	}
	minimised := view_zone_collapsed(sp, e) && (e == .Top || e == .Bottom) && only < 0
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
		// (.Fits_Width: its width is its share of the zone, a split; least-width.md: else the last stack of a row of
		// stacks keeps its view's width and passes the zone's edge)
		stack := build_box({.Clip, .Fits_Width}, fmt.tprintf("###view_stack_%d", k))
		sp.stacks[e][k], sp.stack_key[e][k] = stack.rect, stack.key
		shown := list[len(list) - 1]
		for r in list { if r.modal_name == sp.active[e][k] { shown = r } }
		push_parent(stack)
		with_strip := minimised || len(list) >= 2
		for r in list { if r.kind.o.tabs_always { with_strip = true } }
		// (a lone panel's strip comes on a rest at its top edge and pushes its body down: its controls never lie over
		// the body's; with company it is the stack's strip, and its hover starts again from rest)
		on_hover := false
		if with_strip {
			for r in list { r.hover = .Rest }
		} else {
			with_strip = view_hover_strip(shown, stack)
			on_hover = with_strip
		}
		shown.strip_tools = 0
		// (the shown view placed its zone's fold button in its last build: the strip says Minimise no second time)
		folds := shown.fold_built != 0 && shown.fold_built + 1 >= s.build_index
		if with_strip { view_stack_strip(vs, sp, e, k, list, shown, only >= 0, minimise = !folds) }
		// (a click on the strip did its act in this build: the strip goes in the next one. Not a click on its free part:
		// the first of a double click that maximises)
		tabs_key := key_from_string(stack.key, "###view_tabs")
		if on_hover && s.clicked_key[.Left] != 0 && s.clicked_key[.Left] != tabs_key && view_key_within(s, s.clicked_key[.Left], tabs_key) {
			shown.hover = .Rest
		}
		if !minimised { view_panel_build(vs, sp, shown) }
		pop_parent()
		view_panel_menu_press(shown, stack, with_strip ? strip_h : em * VIEW_HOVER_EDGE_EM)
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
// as a window's caption buttons (caption_row). `minimise` false: the shown view places its zone's fold button.
@(private = "file")
view_stack_strip :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, k: int, list: []^View_Record, shown: ^View_Record, maxed: bool, minimise := true) {
	em := font_size()
	minimised := view_zone_collapsed(sp, e) && !maxed
	next({width = fill(), height = px(math.round(DOCK_TAB_EM * em)), axis = .X, cross = .Center})
	bar: ^Box
	// (clickable: a double click on its free part maximises the stack or restores it, as a window's title bar does; a
	// right click there opens the shown view's menu. Its tabs and buttons take their own clicks)
	if tags("bar") { bar = build_box({.Draw_Background, .Clickable}, "###view_tabs") }
	bar.custom = tab_line_draw   // (its bottom edge a line, out of which the shown tab rises: tab_box)
	push_parent(bar)
	defer {
		pop_parent()
		bs := signal(bar)
		if bs.double_clicked { view_stack_maximise(vs, sp, e, k, !maxed) }
		if bs.right_clicked { menu_open(view_menu_id(shown), mouse_pos(), bar.key) }
	}
	// the tabs, as every row of tabs of the toolkit (tab_box), on a strip: too many for the stack, they scroll with arrows
	if strip("###view_tab_strip") {
		a11y_default(parent_box(), {role = .Tab_List, orientation = .X})
		for r in list {
			on := r == shown
			title := text_shown(view_title_shown(r))
			tb := tab_box(fmt.tprintf("###view_tab_%s", r.modal_name), on)
			if on { strip_reveal(tb) }   // (a tab its "+" opened at the end, or one a command showed, comes into view)
			if parent(tb) { if tab_body() {
				if !on { push_tags("weak") }
				next({width = text_size(em * DOCK_TAB_PAD_EM * 2), height = pct(1), text_pad = em * DOCK_TAB_PAD_EM, text_align = .Center})
				build_box({.Draw_Text}, fmt.tprintf("%s###view_tab_title", title))
				if !on { pop_tags() }
			} }
			a11y_default(tb, {role = .Tab, selected = on, name = title})
			view_stack_tab_input(vs, sp, e, k, r, tb, on, minimised)
		}
	}
	// the "+": right after the last tab, where the new one comes (at the strip's end when the tabs scroll)
	if shown.kind.o.new_tab != nil && view_header_icon("view_new_tab", lucide.PLUS, view_new_tab_label(vs, shown.kind), true) {
		view_new_tab(vs, shown)
	}
	view_stack_strip_rest(vs, sp, e, k, list, shown, maxed, minimised, minimise)
}

// What a tab of a stack's strip does: a click shows its view (and restores a zone minimised), a right click opens its
// menu, a drag takes it out as an internal window.
@(private = "file")
view_stack_tab_input :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, k: int, r: ^View_Record, tb: ^Box, on, minimised: bool) {
	em := font_size()
	sig := signal(tb)
	if sig.clicked {
		if !on {
			delete(sp.active[e][k], vs.allocator)
			sp.active[e][k] = strings.clone(r.modal_name, vs.allocator)
		}
		if minimised { view_stack_minimise(vs, sp, e, false) }
	}
	if sig.right_clicked { menu_open(view_menu_id(r), mouse_pos(), tb.key) }
	if sig.dragging { view_panel_drag(vs, r, tb.key, sig, em) }
}

// The least room a stack's strip keeps for its tabs beside the shown view's moves and the stack's own buttons (em).
@(private = "file") VIEW_STRIP_TABS_LEAST_EM :: 3

// The rest of a stack's strip after its tabs and its "+": the shown view's moves, the slot of its program's tools, the
// stack's own buttons at the right end.
@(private = "file")
view_stack_strip_rest :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, k: int, list: []^View_Record, shown: ^View_Record, maxed, minimised, minimise: bool) {
	s := gs()
	em := font_size()
	labels := view_labels(vs)
	// a stack too narrow for its moves and its window-sized buttons (a side zone of a few ems; the tabs never give way
	// past their largest one, strip.md): no moves (the view's menu and the palette have them), and its Minimise,
	// Maximise and Close as small icons, so they stay whole in it
	dpi := s.zoom > 0 ? s.scale / s.zoom : s.scale
	stack_w := sp.stacks[e][k].max.x - sp.stacks[e][k].min.x
	moves_w := 3 * (math.round(em * VIEW_DETACH_EM) + em * 0.3) + em * 0.8
	least_tabs := em * VIEW_STRIP_TABS_LEAST_EM
	wide := stack_w <= 0 || stack_w >= 3 * math.round(CAPTION_BUTTON_WIDTH * dpi) + moves_w + least_tabs
	spacer(px(em * 0.4))
	if wide {
		if view_header_icon("view_detach", lucide.PICTURE_IN_PICTURE_2, labels.floating, true) { view_float(vs, shown) }
		if view_header_icon("view_window", lucide.EXTERNAL_LINK, labels.window, views_windows_ready(vs)) {
			view_apply(vs, shown, {kind = .Present, as = .External})
		}
		if !view_machine_at_home(shown.machine) && view_header_icon("view_reattach", lucide.UNDO_2, labels.reattach, true) {
			view_apply(vs, shown, {kind = .Reattach})
		}
	}
	// the program's tools of the shown view: its body fills this slot (view_header_tools)
	spacer(px(em * 0.4))
	next({width = children_sum(), height = pct(1), axis = .X, cross = .Center})
	shown.strip_tools = build_box({}, "###view_strip_tools").key
	spacer(fill())
	// the stack's own, at the right end, as a window's: Minimise (a side zone's to its rail), Maximise, Close
	buttons := bit_set[platform.Caption_Button]{.Minimize, .Maximize, .Close}
	if e == .Center { buttons -= {.Minimize} }   // (the centre has nowhere to fold to)
	if !minimise { buttons -= {.Minimize} }      // (said once: the view's fold button, view_fold_button)
	names := [4]string{minimised ? labels.restore : labels.minimize, labels.maximize, labels.close_stack, labels.restore}
	ids := [platform.Caption_Button]string{.Minimize = "###view_stack_min", .Maximize = "###view_stack_max", .Close = "###view_stack_close"}
	clicked: platform.Caption_Button
	ok: bool
	if wide {
		clicked, ok, _ = caption_row(ids, buttons, maxed, s.window == nil || s.window.active, names)
	} else {
		glyphs := [platform.Caption_Button]string{.Minimize = minimised ? lucide.PANEL_LEFT_OPEN : lucide.MINUS, .Maximize = maxed ? lucide.MINIMIZE_2 : lucide.MAXIMIZE_2, .Close = lucide.X}
		for b in platform.Caption_Button {
			if b not_in buttons { continue }
			if view_stack_icon(ids[b], glyphs[b], names[b == .Maximize && maxed ? 3 : int(b)]).clicked { clicked, ok = b, true }
		}
		spacer(px(em * SPACE_1))
	}
	if !ok { return }
	switch clicked {
	case .Minimize:
		view_zone_unmaximise(vs, sp, e)
		view_stack_minimise(vs, sp, e, !minimised)
	case .Maximize:
		view_stack_maximise(vs, sp, e, k, !maxed)
	case .Close:
		// (every view of the stack: the stack's button; one tab closes by Ctrl+W, its menu, the palette)
		if maxed { view_stack_maximise(vs, sp, e, k, false) }
		for r in list { view_apply(vs, r, {kind = .User_Close}) }
	}
	s.anim_busy = true
}

// The user's Minimise (`on`) or Restore of a zone: a top or bottom zone shows its strips only, or its stacks again; a
// side zone's is a manual act of its fold, which holds until the space next crosses its threshold (side-panels.md).
// Remembered in the space's line.
@(private = "file")
view_stack_minimise :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, on: bool) {
	if side_fold_set(&sp.mem.fold[e], on) { view_space_remember(vs, sp) }
	vs.version += 1
	if sp.state != nil { sp.state.anim_busy = true }
}

// A side zone collapsed whose views state a rail width (View_Options.rail_em): each stack's shown view built in its
// compact form (View.rail), the stacks one under the other. The view draws its own marks and its zone's Restore
// (view_fold_button): the toolkit gives it the column and says it is minimised.
@(private = "file")
view_zone_rail_views :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, z: ^View_Zone_Lists, zone: ^Box, n: int) {
	push_parent(zone)
	defer pop_parent()
	for k in 0 ..< n {
		list := z[k][:]
		if len(list) == 0 { continue }
		shown := list[len(list) - 1]
		for r in list { if r.modal_name == sp.active[e][k] { shown = r } }
		next({width = fill(), height = fill(), axis = .Y})
		// (.Fits_Width: its width is the rail's; least-width.md)
		stack := build_box({.Clip, .Fits_Width}, fmt.tprintf("###view_stack_%d", k))
		sp.stacks[e][k], sp.stack_key[e][k] = stack.rect, stack.key
		push_parent(stack)
		view_panel_build(vs, sp, shown, rail = true)
		// (the toolkit's rail has no Restore for a compact form: its view places it, views.md, Minimise)
		when ODIN_DEBUG {
			if shown.kind.o.rail_em > 0 {
				assert(shown.fold_built == gs().build_index, "a view with rail_em calls ui.view_fold_button in its compact form")
			}
		}
		pop_parent()
		for r in list { view_header_menu(vs, r, .Panel) }
	}
}

// Inside a build: the fold button of the side zone that holds the view, where the view places it (a row it already
// has; views.md, Minimise): Minimise when the zone is expanded, Restore when it is collapsed, the same small icon. It
// acts as the strip's Minimise and the rail's Restore, and the view's strip then leaves its Minimise out. A view with
// View_Options.rail_em calls it in its compact form (View.rail): its zone's rail has no other Restore. Elsewhere (not
// a panel at the left or the right) it builds nothing and returns {}. A right click on it opens the view's menu (its
// moves, Maximise, Close: a lone panel's strip waits for a rest at its top edge). Its key: "###view_fold".
view_fold_button :: proc(v: ^View) -> Signal {
	if v == nil || v.record == nil || v.presentation != .Panel { return {} }
	r := v.record
	e := view_panel_place(r.machine).edge
	if e != .Left && e != .Right { return {} }
	vs := r.vs
	sp := view_space_of(vs, view_panel_place(r.machine).space)
	labels := view_labels(vs)
	collapsed := view_zone_collapsed(sp, e)
	r.fold_built = gs().build_index
	sig := side_fold_button("###view_fold", collapsed, e == .Right, labels.minimize, labels.restore, labels.menu_hint)
	if sig.clicked {
		view_zone_unmaximise(vs, sp, e)
		view_stack_minimise(vs, sp, e, !collapsed)
	}
	if sig.right_clicked && sig.box != nil { menu_open(view_menu_id(r), mouse_pos(), sig.box.key) }
	return sig
}

// The view's menu, for a panel: its stack's Minimise (or Restore, its zone folded) and Maximise (or Restore), the acts
// of the strip's buttons and of the fold button, by their own transitions. Minimise is absent at the centre (nowhere
// to fold to) and while the stack is maximised (two items would say "Restore").
@(private)
view_panel_menu_items :: proc(vs: ^Views, r: ^View_Record) {
	labels := view_labels(vs)
	place := view_panel_place(r.machine)
	sp := view_space_of(vs, place.space)
	if sp == nil { return }
	maxed := view_stack_maxed(sp, place.edge, place.stack)
	if place.edge != .Center && !maxed {
		folded := view_zone_collapsed(sp, place.edge)
		word, glyph := labels.minimize, lucide.MINUS
		if folded { word, glyph = labels.restore, place.edge == .Right ? lucide.PANEL_RIGHT_OPEN : lucide.PANEL_LEFT_OPEN }
		if menu_item(fmt.tprintf("%s###vm_minimise", word), icon = glyph, icon_font = lucide_icons()).clicked {
			view_stack_minimise(vs, sp, place.edge, !folded)
		}
	}
	word, glyph := labels.maximize, lucide.MAXIMIZE_2
	if maxed { word, glyph = labels.restore, lucide.MINIMIZE_2 }
	if menu_item(fmt.tprintf("%s###vm_maximise", word), icon = glyph, icon_font = lucide_icons()).clicked {
		view_stack_maximise(vs, sp, place.edge, place.stack, !maxed)
	}
}

// A right press on the free part of a panel's top area opens its view's menu (views.md, section 2.5, rule 3): the
// strip's free part when it shows, else the band at the body's top where a rest brings the strip. The top area is the
// body's too, so the press is the view's only when no clickable box lies under it (a tab, a body's button: theirs,
// at the release) and nothing took it in this build (a body's context_take, a field's menu). Called after the stack's
// strip and body are built.
@(private = "file")
view_panel_menu_press :: proc(r: ^View_Record, stack: ^Box, top: f32) {
	s := gs()
	if !s.pressed_any[.Right] || s.pressed_key[.Right] != 0 { return }
	p := s.press_pos[.Right]
	if p.y >= stack.rect.min.y + top { return }
	if !context_take(stack) { return }
	menu_open(view_menu_id(r), p, stack.key)
}

// One of a narrow stack's own buttons: a small icon, as the fold button ("###id": its key, as the caption button it
// stands for).
@(private = "file")
view_stack_icon :: proc(id, glyph, label: string) -> Signal { return side_icon_button(id, glyph, label) }

// A side zone collapsed (views.md, Minimise): a column one strip wide, its Restore at the top, then a button per view
// (its icon; its title as the tooltip), stack after stack. A view's button restores the zone with that view shown.
@(private = "file")
view_zone_rail :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, z: ^View_Zone_Lists, zone: ^Box, n: int) {
	em := font_size()
	labels := view_labels(vs)
	side := math.round(DOCK_TAB_EM * em)
	push_parent(zone)
	defer pop_parent()
	next({width = fill(), height = fill(), axis = .Y, cross = .Center})
	push_parent(build_box({}, "###view_rail"))
	defer pop_parent()
	spacer(px(em * SPACE_1))
	if view_header_icon("view_rail_restore", e == .Left ? lucide.PANEL_LEFT_OPEN : lucide.PANEL_RIGHT_OPEN, labels.restore, true) {
		view_stack_minimise(vs, sp, e, false)
	}
	for k in 0 ..< n {
		for r, i in z[k] {
			icon, icon_font := view_icon_shown(r)
			title := view_title_shown(r)
			if icon == "" { icon, icon_font = lucide.APP_WINDOW, lucide_icons() }   // (no icon of its own: a window's)
			spacer(px(em * SPACE_1))
			push_tags("ghost_button", "button", "weak")
			next({width = px(side), height = px(side), font = icon_font, font_size = em * 0.95, text_pad = 0, text_align = .Center, radius = em * 0.3})
			b := build_box({.Draw_Text, .No_Text_Trunc, .Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects}, fmt.tprintf("%s###view_rail_%v_%d_%d", icon, e, k, i))
			pop_tags()
			a11y_default(b, {role = .Button, name = title})
			sig := signal(b)
			// (in a folded rail the tooltip is the icon's only label: show it with zero delay)
			if sig.hovering { if tooltip() { tooltip_text(title) } }
			if sig.clicked {
				delete(sp.active[e][k], vs.allocator)
				sp.active[e][k] = strings.clone(r.modal_name, vs.allocator)
				view_stack_minimise(vs, sp, e, false)
			}
			if sig.right_clicked { menu_open(view_menu_id(r), mouse_pos(), b.key) }
		}
	}
	for k in 0 ..< n { for r in z[k] { view_header_menu(vs, r, .Panel) } }
}

// Whether a stack of `vs`'s space `name` is maximised (its strip's Maximise), and which.
views_space_maximised :: proc(vs: ^Views, name: string) -> (edge: View_Edge, stack: int, ok: bool) {
	sp, found := vs.spaces[name]
	if !found { return }
	x: View_Space_Max
	x, ok = sp.mem.max.?
	return x.edge, x.stack, ok
}

// The zones the maximise of the space `name` keeps (none: not maximised, or the whole space).
views_space_maximise_keeps :: proc(vs: ^Views, name: string) -> bit_set[View_Edge] {
	sp, found := vs.spaces[name]
	if !found { return {} }
	x, ok := sp.mem.max.?
	return ok ? x.keep : {}
}

// The program's Maximise of stack `stack` of zone `edge` of the space `name` (section 6.1d): it takes the space but
// the zones of `keep` ({.Left}: a sidebar stays). Remembered with the layout; the person turns it off as any.
views_space_maximise :: proc(vs: ^Views, name: string, edge: View_Edge, stack := 0, keep := bit_set[View_Edge]{}) {
	views_ready(vs)
	sp := view_space_of(vs, name)
	view_space_max_set(vs, sp, View_Space_Max{edge = edge, stack = clamp(stack, 0, VIEW_STACKS_MAX - 1), keep = keep})
}

// The space `name` maximised no more: its zones and its content as before.
views_space_restore :: proc(vs: ^Views, name: string) {
	views_ready(vs)
	sp := view_space_of(vs, name)
	if _, ok := sp.mem.max.?; ok { view_space_max_set(vs, sp, nil) }
}

// Whether stack `k` of zone `e` is the one maximised (or waits to be: at a start, before its views reopen).
@(private = "file")
view_stack_maxed :: proc(sp: ^View_Space, e: View_Edge, k: int) -> bool {
	x, ok := sp.mem.max.?
	return ok && x.edge == e && x.stack == k
}

// The person's Maximise (`on`) of stack `k` of zone `e`, keeping View_Dock_Options.maximise_keeps, or its Restore.
@(private = "file")
view_stack_maximise :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge, k: int, on: bool) {
	view_space_max_set(vs, sp, on ? View_Space_Max{edge = e, stack = k, keep = sp.defaults.maximise_keeps} : nil)
}

// A zone folded or minimised ends a maximise of one of its stacks (a kept zone's fold keeps it).
@(private = "file")
view_zone_unmaximise :: proc(vs: ^Views, sp: ^View_Space, e: View_Edge) {
	if x, ok := sp.mem.max.?; ok && x.edge == e { view_space_max_set(vs, sp, nil) }
}

@(private = "file")
view_space_max_set :: proc(vs: ^Views, sp: ^View_Space, x: Maybe(View_Space_Max)) {
	sp.mem.max, sp.max_seen = x, false
	view_space_remember(vs, sp)
	vs.version += 1
	if sp.state != nil { sp.state.anim_busy = true }
}

// The view as a panel: its body fills its stack (under the stack's strip, which holds its tabs and its controls:
// view_stack_strip; a lone panel's on hover, view_hover_strip); its keys while the focus is in it.
@(private = "file")
view_panel_build :: proc(vs: ^Views, sp: ^View_Space, r: ^View_Record, rail := false) {
	s := gs()
	k := r.kind
	r.flag, r.ending, r.tools, r.header = true, nil, 0, 0
	next({width = fill(), height = fill(), axis = .Y})
	// (its key its name's alone: a panel opened late is built at end_build first, then in its zone; its field keeps its
	// key, and the focus its first build gave it)
	s.key_rooted = true
	// (.Fits_Width: its width is its stack's, a split, never its content's; least-width.md)
	body := build_box({.Clip, .Fits_Width}, fmt.tprintf("###view_panel_%s", r.modal_name))
	r.panel = body.key
	r.roots[.Panel] = body.key
	r.pbuilt = s.build_index
	push_parent(body)
	v := View{id = k.id, instance = r.instance, presentation = .Panel, place = r.machine.place, shown = true, rail = rail, record = r}
	keys_root := s.view_keys_root
	s.view_keys_root = body.key
	k.build(&v, r.data)
	s.view_keys_root = keys_root
	pop_parent()
	inside := view_focus_inside(s, body.key)
	// (opened again: the focus to its first stop, unless it is in it already; view_apply)
	if r.focus_in {
		r.focus_in = false
		if !inside {
			if first := view_first_stop(body); first != 0 { s.focus_key, inside = first, true }
		}
	}
	if inside && r.flag && r.ending == nil {
		if key_press(.W, {.Ctrl}) {
			r.flag = false
		} else if key_press(.Escape) {
			// (an Escape it did not take: its stack maximised comes back to its size; else the focus goes back to the
			// content, the panel stays)
			if view_stack_maxed(sp, r.machine.place.edge, r.machine.place.stack) {
				view_space_max_set(vs, sp, nil)
			} else {
				s.focus_key = 0
			}
		}
	}
	view_build_ended(vs, r)
}

// Whether a lone panel shows its stack's strip (section 2.5, rule 2), by its state machine (View_Hover): armed while
// the pointer rests in the stack's top band (VIEW_HOVER_EDGE_EM, by the last layout) with no button down, shown after
// VIEW_HOVER_DWELL_MS there; then kept while the pointer is in the stack, a box of the strip is held (a tab dragged
// out) or the view's menu is open, and gone on Escape. Shown, it pushes the body down: no control of it lies over the
// body's. (A click on the strip ends it too: view_zone_fill, after the strip did its act.)
@(private = "file")
view_hover_strip :: proc(r: ^View_Record, stack: ^Box) -> bool {
	s := gs()
	em := font_size()
	a, p := stack.rect, mouse_pos()
	inside := s.mouse_valid && p.x >= a.min.x && p.x < a.max.x && p.y >= a.min.y && p.y < a.max.y
	switch r.hover {
	case .Shown:
		held := s.active_key[.Left] != 0 && view_key_within(s, s.active_key[.Left], key_from_string(stack.key, "###view_tabs"))
		keep := inside || held || menu_is_open(view_menu_id(r))
		// (peeked, not taken: an Escape the body reads still reaches it)
		if !keep || key_pressed_peek(.Escape) { r.hover = .Rest }
	case .Rest, .Armed:
		band := inside && p.y < a.min.y + em * VIEW_HOVER_EDGE_EM
		pressed := s.buttons_down != {} || s.pressed_any != {}
		if !band || pressed {
			r.hover = .Rest
			break
		}
		if r.hover == .Rest { r.hover, r.hover_since = .Armed, s.time_ms }
		waited := s.time_ms - r.hover_since
		if waited >= VIEW_HOVER_DWELL_MS {
			r.hover = .Shown
		} else {
			wake_within(s, max(1, int(VIEW_HOVER_DWELL_MS - waited) + WAKE_MARGIN_MS))   // (one frame at the deadline)
		}
	}
	return r.hover == .Shown
}

// Whether the box `k` is `root` or lies under it (a box of a strip on hover: held, or clicked).
@(private = "file")
view_key_within :: proc(s: ^State, k: Key, root: Key) -> bool {
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
		// (at the middle of the zone's span along its edge: a bottom zone under the content alone has its square under
		// the content's middle, section 6.1b)
		lo, hi := view_edge_span(sp, e)
		mid := math.round((lo + hi) * 0.5)
		switch e {
		case .Left:   at = {r.min.x + g + m * 0.5, mid}
		case .Right:  at = {r.max.x - g - m * 0.5, mid}
		case .Top:    at = {mid, r.min.y + g + m * 0.5}
		case .Bottom: at = {mid, r.max.y - g - m * 0.5}
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
			if !draw.rect_contains(sr, p) { continue }
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
				if draw.rect_contains(q.rect, p) { return q.target, true }
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
	// (a drop into a zone a maximise hides ends it: the view shows where it went. A maximise still waiting for its views
	// at a start ends at any drop: the person lays out the window, and a stale one would hide the content; section 6.1d)
	if sp, known := vs.spaces[place.space]; known {
		if x, maxed := sp.mem.max.?; maxed && (!sp.max_seen || (place.edge != x.edge && place.edge not_in x.keep)) { view_space_max_set(vs, sp, nil) }
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
	// (the centre: what the edges leave, the content's rect; a main zone's view opened late is built there)
	if e == .Center { return sp.middle.max.x > sp.middle.min.x ? sp.middle : r }
	length := e == .Left || e == .Right ? r.max.x - r.min.x : r.max.y - r.min.y
	ext := min(view_zone_px(sp, e, em, length), length * 0.4)
	// (along its edge, the span it would have: under the content alone in .Content, section 6.1b)
	lo, hi := view_edge_span(sp, e)
	#partial switch e {
	case .Left:   return {{r.min.x, lo}, {r.min.x + ext, hi}}
	case .Right:  return {{r.max.x - ext, lo}, {r.max.x, hi}}
	case .Top:    return {{lo, r.min.y}, {hi, r.min.y + ext}}
	case .Bottom: return {{lo, r.max.y - ext}, {hi, r.max.y}}
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
			#reverse for q, i in squares { if lit < 0 && draw.rect_contains(q.rect, p) { lit = i } }
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
	// (the content under a main view or a maximise is not seen: not an area)
	if sp.content != 0 && sp.has_content && !sp.content_hidden { append(&areas, sp.content) }
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

// The acts that do something for `r` where it is now. The palette's commands (views_commands) and the view's menu
// (view_header_menu) both read this one set: an act is in both or in neither, and a menu never shows it disabled.
@(private)
view_acts :: proc(vs: ^Views, r: ^View_Record) -> (acts: bit_set[View_Act]) {
	m := r.machine
	acts = {.Close}
	if r.kind.o.new_tab != nil { acts += {.New_Tab} }
	if m.as != .External && views_windows_ready(vs) { acts += {.Window} }
	if m.as != .Internal { acts += {.Float} }
	// (the frame's edges, when the owner window has a frame space: views_frame; not the edge the panel is at)
	if view_frame_built(vs, r.owner) {
		docked := m.as == .Panel && m.place.space == ""
		if !(docked && m.place.edge == .Left) { acts += {.Dock_Left} }
		if !(docked && m.place.edge == .Right) { acts += {.Dock_Right} }
		if !(docked && m.place.edge == .Bottom) { acts += {.Dock_Bottom} }
	}
	if !view_machine_at_home(m) { acts += {.Reattach} }
	return
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
		acts := view_acts(vs, r)
		if .New_Tab in acts && !(r.kind in new_tabs) {
			new_tabs[r.kind] = true
			// (the program's words, whole: no title in them)
			append(&cmds, Command{label = strings.clone(view_new_tab_label(vs, r.kind), allocator), group = group, icon = lucide.PLUS})
			append(&what, View_Command{id = r.kind.id, instance = r.instance, act = .New_Tab})
		}
		if .Window in acts { add(&cmds, &what, r, .Window, i18n.tr("Open %s in a window"), title, group, lucide.EXTERNAL_LINK, allocator) }
		if .Float in acts { add(&cmds, &what, r, .Float, i18n.tr("Float %s"), title, group, lucide.PICTURE_IN_PICTURE_2, allocator) }
		if .Dock_Left in acts { add(&cmds, &what, r, .Dock_Left, i18n.tr("Dock %s to the left"), title, group, lucide.PANEL_LEFT, allocator) }
		if .Dock_Right in acts { add(&cmds, &what, r, .Dock_Right, i18n.tr("Dock %s to the right"), title, group, lucide.PANEL_RIGHT, allocator) }
		if .Dock_Bottom in acts { add(&cmds, &what, r, .Dock_Bottom, i18n.tr("Dock %s to the bottom"), title, group, lucide.PANEL_BOTTOM, allocator) }
		if .Reattach in acts { add(&cmds, &what, r, .Reattach, i18n.tr("Re-attach %s"), title, group, lucide.UNDO_2, allocator) }
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

// What changes the list of views_commands: a view opened, closed, moved or retitled. The palette's moves source follows it.
views_version :: proc(vs: ^Views) -> u64 { return vs.version }

// The views' commands kept past the frame (the palette's moves source, a menu of the views). Made again by
// views_commands_update only when the views or the language changed.
View_Commands :: struct {
	commands:  []Command,
	acts:      []View_Command,
	made:      bool,
	version:   u64,   // the views' version they were made for
	language:  u32,
	owner:     ^State,   // the window whose views they are (nil: every view)
	allocator: runtime.Allocator,
}

// Makes `vc` again when the views of `vs` changed since (views_version) or the language did; true: they did. Cost: one
// pass over the open views, only then.
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
	return true
}

// Frees what views_commands_update made.
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
