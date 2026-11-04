package ui

// Panes the user resizes, folds away and places (an inspector's sidebar, a drawer, a docked tool panel): the app keeps one
// `Pane` per split (its sizes, whether it is folded, where it goes), passes it by pointer and saves it when the result says
// so (or through `Pane_Options.on_save`); `pane_format` / `pane_parse` make it one line of text for a settings file.
//
//   * pane_split: the handle between the pane and the other side. Open, it is a splitter that resizes the pane from a few
//     em (PANE_MIN_EM) to all the room but a few em for the other side; a collapsible pane folds when dragged under half
//     its minimum, on a double click and on Enter. Folded, the handle is a strip (PANE_STRIP_EM) with a chevron: a click
//     (or Enter) brings the pane back at its size, a drag pulls it out to the pointer. Keyboard: a Tab stop, the arrows of
//     its axis resize, Home / End go to the limits. Accessible as a separator with the size as its value.
//   * pane_toggle: a chevron button for the pane's own header (or the other side's) that folds it and brings it back.
//   * pane_axis / pane_place_menu: the pane at the side (.X) or below (.Y), chosen by the user or by the room.
//   * menu_move_to: "Move to ..." items for a tab that may go to another strip.
//
// State machine (Pane.collapsed): Open -> Collapsed (snap under half the minimum, double click, Enter, pane_toggle);
// Collapsed -> Open (click, Enter, a drag past half the minimum, pane_toggle). A drag holds where it began
// (drag_store: the size, folded or not), so it can fold and unfold the pane as the pointer goes back and forth.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../draw"
import "../platform"

PANE_MIN_EM :: 3            // the smallest open pane, and what the other side keeps (em)
PANE_STRIP_EM :: 1.25       // a folded pane's strip, across the split (em)
PANE_SNAP_FRACTION :: 0.5   // a collapsible pane dragged under this fraction of its minimum folds
PANE_TOGGLE_EM :: 1.6       // pane_toggle's button (em, square)
PANE_CHEVRON_EM :: 1.4      // the chevron in the strip and the button (em)
PANE_TOOLTIP_DELAY_S :: 0.5
PANE_NO_LIMIT :: 1e6        // the largest size when the room is not known (logical px)
PANE_SIDE_MIN_EM :: 40      // pane_axis with .Auto: the pane goes at the side from this room on (em)

Pane_Side :: enum u8 { Before, After }    // the pane is before the handle (left, top) or after it (right, bottom)
Pane_Place :: enum u8 { Auto, Side, Below }
// The name of a place in `pane_format` text.
pane_place_name :: proc(pl: Pane_Place) -> string {
	switch pl {
	case .Auto:  return "auto"
	case .Side:  return "side"
	case .Below: return "below"
	}
	return ""
}

// The app's: what it saves.
Pane :: struct {
	size:      [Axis]f32,   // the open size across each orientation (logical px; 0: the default), kept while folded
	collapsed: bool,
	place:     Pane_Place,
}

Pane_Options :: struct {
	side:         Pane_Side,
	default_size: f32,    // logical px (0: twice the minimum); a double click goes back to it when not collapsible
	total:        f32,    // the room of the pane and the other side along the axis (logical px; 0: unknown)
	min_size:     f32,    // logical px (0: PANE_MIN_EM)
	min_other:    f32,    // logical px (0: PANE_MIN_EM)
	collapsible:  bool,
	title:        string, // the pane's name: the strip's tooltip and the handle's accessible name
	thickness:    f32,    // the open handle's grab area across it (frame px; 0: 5 logical px)
	no_keyboard:  bool,   // not a Tab stop
	on_save:      proc(user: rawptr, p: ^Pane),   // called when the user is done changing it (a drag ended, a fold, a key)
	user:         rawptr,
}

Pane_Result :: struct {
	using sig: Signal,   // the handle's (dragging: held)
	changed:   bool,     // the size or the fold changed this frame
	toggled:   bool,     // folded or brought back this frame
	finished:  bool,     // the user is done: the moment to save (on_save was called)
	size:      f32,      // the pane's size to lay out (logical px; 0: folded)
}

// The limits of the pane's size along `axis` (logical px): its minimum, and the room less what the other side keeps. The
// minimum wins when they cross.
pane_limits :: proc(opts: Pane_Options) -> (lo, hi: f32) {
	s := gs()
	em := font_size() / s.scale
	lo = opts.min_size > 0 ? opts.min_size : PANE_MIN_EM * em
	other := opts.min_other > 0 ? opts.min_other : PANE_MIN_EM * em
	hi = opts.total > 0 ? opts.total - other : PANE_NO_LIMIT
	if hi < lo { hi = lo }
	return
}

// The pane's size to lay out along `axis` (logical px; 0: folded): its own, in the limits; the default when it has none.
pane_extent :: proc(p: ^Pane, axis: Axis, opts := Pane_Options{}) -> f32 {
	if p.collapsed { return 0 }
	lo, hi := pane_limits(opts)
	sz := p.size[axis]
	if sz <= 0 { sz = opts.default_size > 0 ? opts.default_size : lo * 2 }
	return clamp(sz, lo, hi)
}

// The handle between the pane and the other side, along `axis` (.X: side by side, a vertical bar; .Y: stacked). The app
// builds the pane `pane_extent` wide (none when folded) before the handle (side .Before) or after it (.After). Its length
// fills the parent unless `next` sets it.
pane_split :: proc(id: string, axis: Axis, p: ^Pane, opts := Pane_Options{}) -> (res: Pane_Result) {
	s := gs()
	em := font_size()
	lo, hi := pane_limits(opts)
	was := p^
	open := pane_extent(p, axis, opts)
	across := p.collapsed ? math.round(PANE_STRIP_EM * em) : (opts.thickness > 0 ? opts.thickness : math.round(SPLITTER_THICKNESS_PX * s.scale))
	m := s.has_next ? s.next_mod : Style_Mod{}
	cur := axis == .X ? platform.Cursor.Resize_H : platform.Cursor.Resize_V
	if axis == .X {
		m.width = px(across)
		if m.height == nil { m.height = fill() }
	} else {
		m.height = px(across)
		if m.width == nil { m.width = fill() }
	}
	m.cursor = p.collapsed ? platform.Cursor.Arrow : cur
	next(m)
	flags := Box_Flags{.Clickable}
	if !opts.no_keyboard { flags += {.Focusable} }
	b: ^Box
	if tags("pane_strip") { b = build_box(flags, id) }   // (the folded strip's colours)
	enter := !opts.no_keyboard && s.focus_key == b.key && key_pressed_peek(.Return)   // (signal takes Enter as a click)
	res.sig = signal(b)
	step: f32 = SPLITTER_KEY_STEP_PX

	// a drag: from where it began, folded (0) or open
	prev := drag_load()   // (the press before this one: a double click whose first click was on the strip is no double click on the bar)
	if res.sig.pressed { drag_store({p.collapsed ? 0 : open, p.collapsed ? 1 : 0, 0, 0}) }
	if res.sig.dragging && res.sig.drag_delta != {} {
		s.cursor_request = cur
		d := (axis == .X ? res.sig.drag_delta.x : res.sig.drag_delta.y) / s.scale
		if opts.side == .After { d = -d }
		from := drag_load()
		want := from[0] + d
		if opts.collapsible && want < lo * PANE_SNAP_FRACTION {
			if !p.collapsed && from[1] == 0 { p.size[axis] = from[0] }   // (folded by a drag: it comes back at the size it had)
			p.collapsed = true
		} else {
			p.collapsed = false
			p.size[axis] = clamp(want, lo, hi)
		}
	}
	if res.sig.released { res.finished = true }
	switch {
	case enter && opts.collapsible:
		p.collapsed = !p.collapsed
	case enter && !p.collapsed && opts.default_size > 0:
		p.size[axis] = clamp(opts.default_size, lo, hi)
	case res.sig.clicked && p.collapsed && drag_load()[1] == 1 && drag_load()[2] == 0:   // a click on the strip (not a drag out of it)
		p.collapsed = false
	case res.sig.double_clicked && !p.collapsed && prev[1] == 0:
		if opts.collapsible {
			p.collapsed = true
			drag_store({0, 1, 1, 0})   // (the button is still down: a move from here pulls the pane out again; its release is no click)
		} else if opts.default_size > 0 {
			p.size[axis] = clamp(opts.default_size, lo, hi)
			drag_store({p.size[axis], 0, 0, 0})   // (the button is still down: a move from here starts at the default)
		}
	}
	if res.sig.focused && !opts.no_keyboard && !p.collapsed {
		dir: f32
		back, fwd: platform.Key = axis == .X ? .Left : .Up, axis == .X ? .Right : .Down
		for mods in ([]platform.Modifiers{{}, {.Ctrl}}) {
			k := .Ctrl in mods ? step / SPLITTER_CTRL_STEP_DIVISOR : step
			if key_press(back, mods) { dir -= k }
			if key_press(fwd, mods) { dir += k }
		}
		if opts.side == .After { dir = -dir }
		if dir != 0 { p.size[axis] = clamp(open + dir, lo, hi) }
		if key_press(.Home) { p.size[axis] = lo }
		if key_press(.End) { p.size[axis] = hi }
	}
	res.toggled = p.collapsed != was.collapsed
	res.changed = p.collapsed != was.collapsed || p.size != was.size
	if res.changed && !res.sig.dragging { res.finished = true }
	if res.finished && opts.on_save != nil { opts.on_save(opts.user, p) }
	res.size = pane_extent(p, axis, opts)

	d := frame_new(Pane_Draw)
	d.hot = res.sig.hovering || res.dragging || (res.sig.focused && s.focus_visible)
	d.split = {hot = d.hot, color = d.hot ? color("accent") : color("border"), line = max(math.round(s.scale), 1)}
	d.collapsed, d.axis, d.side = p.collapsed, axis, opts.side
	d.chevron = {t = pane_chevron_turns(axis, opts.side, false), color = d.hot ? color("accent") : color("text")}
	d.bg = color_from_tags(s, b.tags_key, "background")
	d.hover = state_fill(b, "hover_fill", d.bg)
	b.custom, b.custom_user = pane_draw, d
	if p.collapsed && opts.title != "" && hovered_for(res.sig, PANE_TOOLTIP_DELAY_S) { if tooltip() { tooltip_text(opts.title) } }
	info := A11y_Info{role = .Splitter, name = opts.title, numeric = f64(res.size), min = f64(lo), max = f64(hi),
		orientation = axis == .X ? Axis.Y : Axis.X, actions = opts.no_keyboard ? {} : {.Increment, .Decrement, .Set_Value}}
	if opts.collapsible { info.expanded = !p.collapsed }
	a11y_default(b, info)
	if v, ok := a11y_numeric_request(b.key, res.size, step); ok {
		p.collapsed = false
		p.size[axis] = clamp(v, lo, hi)
		res.size, res.changed, res.finished = p.size[axis], true, true
		if opts.on_save != nil { opts.on_save(opts.user, p) }
	}
	return
}

// A chevron button that folds the pane and brings it back (for a header next to it). Returns whether it did.
pane_toggle :: proc(id: string, axis: Axis, p: ^Pane, opts := Pane_Options{}) -> bool {
	em := font_size()
	m := gs().has_next ? gs().next_mod : Style_Mod{}
	if m.width == nil { m.width = px(math.round(PANE_TOGGLE_EM * em)) }
	if m.height == nil { m.height = px(math.round(PANE_TOGGLE_EM * em)) }
	next(m)
	b := build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Draw_Focus_Ring}, id)
	sig := signal(b)
	if sig.clicked {
		p.collapsed = !p.collapsed
		if opts.on_save != nil { opts.on_save(opts.user, p) }
	}
	d := frame_new(Chevron_Draw)
	d.t = pane_chevron_turns(axis, opts.side, !p.collapsed)
	d.color = sig.hovering ? color("accent") : color("text")
	b.custom, b.custom_user = proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
		c := draw.rect_center(b.rect)
		h := b.font_size * PANE_CHEVRON_EM * 0.5
		inner := b^
		inner.rect = {c - h, c + h}
		chevron_draw(&inner, user, dc)
	}, d
	verb := p.collapsed ? "Show" : "Hide"
	name := opts.title != "" ? fmt.tprintf("%s %s", verb, opts.title) : verb
	if hovered_for(sig, PANE_TOOLTIP_DELAY_S) { if tooltip() { tooltip_text(name) } }
	a11y_default(b, {role = .Button, name = name, expanded = !p.collapsed})
	return sig.clicked
}

// Where the pane goes: at the side (.X) or below (.Y); .Auto: at the side when the room is at least `side_min` wide
// (logical px; 0: PANE_SIDE_MIN_EM).
pane_axis :: proc(place: Pane_Place, room_w: f32, side_min: f32 = 0) -> Axis {
	switch place {
	case .Side:  return .X
	case .Below: return .Y
	case .Auto:
	}
	lim := side_min > 0 ? side_min : PANE_SIDE_MIN_EM * font_size() / gs().scale
	return room_w >= lim ? .X : .Y
}

// Menu items that place the pane (inside a ctx_menu or a menu_submenu): returns whether one was chosen.
pane_place_menu :: proc(p: ^Pane, labels := [Pane_Place]string{.Auto = "Auto", .Side = "At the side", .Below = "Below"}) -> (changed: bool) {
	for pl in Pane_Place {
		if menu_item(fmt.tprintf("%s###pane_place_%d", labels[pl], int(pl)), checked = p.place == pl).clicked && p.place != pl {
			p.place, changed = pl, true
		}
	}
	return
}

// "Move to <host>" items for something one of `hosts` holds (`current`): returns the host chosen (-1: none).
menu_move_to :: proc(hosts: []string, current: int) -> int {
	to := -1
	for h, i in hosts {
		if i == current { continue }
		if menu_item(fmt.tprintf("Move to %s###move_to_%d", h, i)).clicked { to = i }
	}
	return to
}

// "320 200 0 auto": the sizes across .X and .Y, folded, the place (temp allocator unless told otherwise).
pane_format :: proc(p: Pane, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%d %d %d %s", int(p.size[.X]), int(p.size[.Y]), p.collapsed ? 1 : 0, pane_place_name(p.place), allocator = allocator)
}

// The pane `pane_format` wrote; ok is false (and the pane zero: the defaults) when the text is not one.
pane_parse :: proc(text: string) -> (p: Pane, ok: bool) {
	f := strings.fields(text, context.temp_allocator)
	if len(f) != 4 { return }
	w, ok1 := strconv.parse_f32(f[0])
	h, ok2 := strconv.parse_f32(f[1])
	if !ok1 || !ok2 || w < 0 || h < 0 || (f[2] != "0" && f[2] != "1") { return }
	for pl in Pane_Place {
		if pane_place_name(pl) == f[3] { return {size = {.X = w, .Y = h}, collapsed = f[2] == "1", place = pl}, true }
	}
	return
}

// Quarter turns of the chevron (">" at 0) that points where the pane goes when it folds (`folding`) or comes back.
@(private)
pane_chevron_turns :: proc(axis: Axis, side: Pane_Side, folding: bool) -> f32 {
	// folding a pane after the handle points away from the handle: right (0) or down (1); one before it, left (2) or up (3)
	t: f32 = axis == .X ? 0 : 1
	if side == .Before { t += 2 }
	if !folding { t += 2 }
	return t
}

@(private)
Pane_Draw :: struct {
	split:     Splitter_Draw,
	chevron:   Chevron_Draw,
	hot, collapsed: bool,
	axis:      Axis,
	side:      Pane_Side,
	bg, hover: Color,     // the strip's ("pane_strip background"), and the theme's hover fill over it
}

// Open: the splitter's rule. Folded: the strip, its edge towards the other side, a chevron that points where the pane
// comes from.
@(private)
pane_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Pane_Draw)(user)
	if !d.collapsed { splitter_draw(b, &d.split, dc); return }
	r := b.rect
	draw.rect(dc, r, d.bg)
	if d.hot { draw.rect(dc, r, d.hover) }
	l := d.split.line
	edge := r
	switch {
	case d.axis == .X && d.side == .After:  edge.max.x = edge.min.x + l
	case d.axis == .X:                      edge.min.x = edge.max.x - l
	case d.side == .After:                  edge.max.y = edge.min.y + l
	case:                                   edge.min.y = edge.max.y - l
	}
	draw.rect(dc, edge, d.split.color)
	c := draw.rect_center(r)
	h := b.font_size * PANE_CHEVRON_EM * 0.5
	inner := b^
	inner.rect = {c - h, c + h}
	chevron_draw(&inner, &d.chevron, dc)
}
