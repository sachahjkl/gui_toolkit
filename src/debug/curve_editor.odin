package debug

// The curve editor and the easing editor of the debug window (src/md/features/curve-editor.md): a program's curves
// (curve.odin) drawn over a grid, their keys and handles dragged, played on the program's clock; a cubic-bezier's two
// handles. The calls are items of a panel as the others (values.odin): a row in the window, an entry of a tool's list,
// the target of a tool's set.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "../ascii"
import "../draw"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
import "../platform"
import tk_json "../json"
import undo "../undo"
import "../ui"

_ :: font

// §debug.curve("hover", &d.hover, &d.play)§: the curve, edited in the panel, its playhead the program's Playback (nil:
// the editor's own). True when a key changed, by the person or a tool.
curve :: proc(label: string, c: ^Curve, play: ^Playback = nil) -> (changed: bool) {
	when ENABLED { return curves_any(label, ([^]Curve)(c)[:1], play, "x") } else { return false }
}

// Several curves edited together (a vector's channels, CURVE_CHANNELS_MAX at most), each in its axis's colour and named
// by a letter of §names§ ("xyzw", "rgba").
curves :: proc(label: string, cs: []Curve, play: ^Playback = nil, names := "xyzw") -> (changed: bool) {
	when ENABLED { return curves_any(label, cs, play, names) } else { return false }
}

// §debug.easing("land", &d.land)§: a cubic-bezier from (0, 0) to (1, 1), its two handles dragged, the toolkit's easings as
// presets (ui.ease_bezier). The program plays it with ui.cubic_bezier_at or ui.tween_curve.
easing :: proc(label: string, e: ^ui.Cubic_Bezier) -> (changed: bool) {
	when ENABLED { return easing_any(label, e) } else { return false }
}

// Where the point §at§ (time, value) of the curve item at §path§ is drawn in the window, by the item's last layout: for a
// test's pointer or a tool's click. ok false: the item was never shown.
curve_screen :: proc(s: ^ui.State, path: string, at: [2]f32) -> (pos: [2]f32, ok: bool) {
	when ENABLED {
		sf := surface_of(s)
		if sf == nil { return }
		e := sf.curve_edits[path_root(path)] or_else nil
		if e == nil || !plot_usable(e.plot) { return }
		return to_screen(e.lo, e.hi, e.plot, at), true
	}
	return
}

// The middle of channel `channel`'s letter in the graph's corner of the curve item at `path` (a click there shows or hides
// the channel), by the last layout. ok false: never shown, or a single channel (no letters).
curve_channel_at :: proc(s: ^ui.State, path: string, channel: int) -> (pos: [2]f32, ok: bool) {
	when ENABLED {
		sf := surface_of(s)
		if sf == nil { return }
		e := sf.curve_edits[path_root(path)] or_else nil
		if e == nil || !plot_usable(e.plot) || e.legend_n <= channel { return }
		c := legend_cell(e.plot, e.legend_n, channel, e.legend_h)
		return (c.min + c.max) * 0.5, true
	}
	return
}

// The channels a curve item edits at most.
CURVE_CHANNELS_MAX :: 4

// The graph's height, in dense rows; the curve sampled every this many pixels.
@(private) CURVE_GRAPH_ROWS :: 9
@(private) CURVE_SAMPLE_PX :: 2
// The undo steps an item keeps.
@(private) CURVE_UNDO_MAX :: 50
// A press moves this many logical pixels before it drags.
@(private) CURVE_DRAG_PX :: 3
// What a notch of the wheel scales the view by.
@(private) CURVE_ZOOM_STEP :: 1.15
// A key's half side, a handle's reach for the pointer, the values' ruler's width, the least gaps between the grid's
// labels: in the text's sizes.
@(private) CURVE_KEY_EM :: 0.3
@(private) CURVE_HIT_EM :: 0.6
@(private) CURVE_TIME_GAP_EM :: 4.5
@(private) CURVE_VALUE_GAP_EM :: 2.2
// The room framing keeps around the keys, a share of their span (time, value).
@(private) CURVE_FRAME_MARGIN :: [2]f32{0.06, 0.15}
// The easing's graph, in dense rows; the values its square shows (an overshoot within them); its preview's period, s.
@(private) EASING_ROWS :: 3
@(private) EASING_LO :: -0.35
@(private) EASING_HI :: 1.35
@(private) EASING_PERIOD :: 1.4

// An item's editor, kept by the surface by the item's path while the program runs.
@(private)
Curve_Edit :: struct {
	lo, hi:        [2]f32,   // the view: the (time, value) at the graph's bottom left and top right
	framed:        bool,
	plot:          ui.Rect,  // the graph's area for the curves, by the last layout
	hidden:        bit_set[0 ..< CURVE_CHANNELS_MAX],
	selected:      [CURVE_CHANNELS_MAX]bit_set[0 ..< CURVE_KEYS_MAX],
	gesture:       Curve_Gesture,
	base:          Curve_Step,   // the curves at the gesture's start
	base_selected: [CURVE_CHANNELS_MAX]bit_set[0 ..< CURVE_KEYS_MAX],
	history:       undo.Stack(Curve_Step),
	own:           Playback,     // the playhead when the program gives none
	stepped:       u64,          // the build that stepped §own§
	field:         string,       // the field whose change took the last undo step (a constant)
	field_free:    bool,         // the button was up since: its next change is a new step
	width:         f32,          // the graph's width by the last layout: the rows' columns are cut from it
	names:         string,       // the channels' letters this frame ("": one channel, no legend)
	ruler_w:       f32,          // the values' ruler's width: its longest number's
	legend_n:      int,          // the channels' letters shown, and their cell's side (for curve_channel_at)
	legend_h:      f32,
}

@(private)
Curve_Step :: struct {
	curves: [CURVE_CHANNELS_MAX]Curve,
	n:      int,
}

@(private)
Curve_Gesture_Kind :: enum u8 { None, Move, Handle, Band, Pan, Scrub }

@(private)
Curve_Gesture :: struct {
	kind:           Curve_Gesture_Kind,
	press:          [2]f32,   // where it started, in the window
	channel, key:   int,      // the key pressed (Move), the handle's key (Handle)
	out:            bool,     // Handle: the key's out handle
	moved:          bool,
	additive:       bool,     // Band: Shift or Ctrl, the selection kept
	collapse:       bool,     // Move: a click on a key of a selection, not dragged, selects it alone
	toggle:         bool,     // Move: a Shift or Ctrl click on a key selected, not dragged, takes it away
	view_lo, view_hi: [2]f32, // Pan: the view at the press
}

@(private)
Curve_Hit_Kind :: enum u8 { None, Key, Handle, Ruler }

@(private)
Curve_Hit :: struct {
	kind:         Curve_Hit_Kind,
	channel, key: int,
	out:          bool,
}

@(private)
curve_edit_of :: proc(sf: ^Surface, key: u64) -> ^Curve_Edit {
	if e, ok := sf.curve_edits[key]; ok { return e }
	e := new(Curve_Edit, sf.allocator)
	e.history.undo.allocator, e.history.redo.allocator = sf.allocator, sf.allocator
	// (paused until the person plays it: a playhead that plays asks for a frame after another)
	e.own.paused = true
	sf.curve_edits[key] = e
	return e
}

@(private)
curve_edit_free :: proc(sf: ^Surface, e: ^Curve_Edit) {
	undo.destroy(&e.history, nil)
	free(e, sf.allocator)
}

////////////////////////////////
// The item

@(private)
curves_any :: proc(label: string, curves_in: []Curve, play: ^Playback, names: string) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	cs := curves_in[:min(len(curves_in), CURVE_CHANNELS_MAX)]
	if len(cs) == 0 { return }
	switch p.kind {
	case .Build:
		changed = curve_editor(p, label, key, cs, play, names)
	case .List:
		list_open(p, label, "curve")
		strings.write_string(p.sb, `,"value":[`)
		for c, ci in cs {
			if ci > 0 { strings.write_byte(p.sb, ',') }
			curve_json(p.sb, c)
		}
		fmt.sbprintf(p.sb, `],"channels":%s,"keysMax":%d}`, tk_json.quote(channel_names(names, len(cs))), CURVE_KEYS_MAX)
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		parsed, err := curves_parse(p.text, len(cs))
		if err != "" { p.err = err; return }
		for i in 0 ..< len(cs) { cs[i] = parsed[i] }
		changed = true
	}
	return
}

// The editor's rows: its head, the graph, the transport, the key selected.
@(private)
curve_editor :: proc(p: ^Pass, label: string, key: u64, cs: []Curve, play: ^Playback, names: string) -> (changed: bool) {
	sf := p.surface
	s := sf.state
	e := curve_edit_of(sf, key)
	n := len(cs)
	// (a count past the array, the program's own mistake, would index past it in every loop of the editor)
	for &c in cs { c.count = clamp(c.count, 0, CURVE_KEYS_MAX) }
	for ch in n ..< CURVE_CHANNELS_MAX { e.selected[ch] = {} }
	for ch in 0 ..< n { e.selected[ch] &= keys_set(cs[ch].count) }
	pb := play
	if pb == nil {
		pb = &e.own
		if e.stepped != s.build_index {
			e.stepped = s.build_index
			playback_step(pb, s.dt, curves_span(cs))
		}
	}
	if !pb.paused { ui.keep_animating() }
	if !e.framed { curve_frame(e, cs); e.framed = true }
	if .Left not_in s.buttons_down { e.field_free = true }
	h := ui.dense_row_height()
	gap := ui.dense_gap()
	colors := channel_colors()

	// Two rows around the graph share their columns (debug-panel.md, "A dense look": aligned without losing room): two
	// glyphs, then two numbers of one width, then the row's end. The head: play, loop, the playhead's time, the speed,
	// frame all, Print. Under the graph, with a key selected: smooth, broken, its time, its value, its interpolation.
	// The channels' letters are in the graph's corner: a row of three letters was a row of nothing.
	kinds := []string{i18n.tr("Bézier"), i18n.tr("Linear"), i18n.tr("Constant")}
	cells := 2 * h
	end := max(cells, ui.dropdown_width(kinds))
	number_w: f32 = 0
	if e.width > 0 {
		label_w := row_label_width(p, label)
		number_w = math.floor((e.width - label_w - 2 * cells - end - 6 * gap) / 2)
	}
	number_next :: proc(w: f32) { ui.next({width = w > 0 ? ui.px(w) : ui.fill(), height = ui.pct(1)}) }
	if row_start(p, label, key) {
		if tool_button(widget_id(key, "play"), pb.paused ? lucide.PLAY : lucide.PAUSE, pb.paused ? i18n.tr("Play (Space)") : i18n.tr("Pause (Space)")) { pb.paused = !pb.paused }
		if tool_button(widget_id(key, "loop"), lucide.REPEAT, pb.once ? i18n.tr("Plays once: loop it") : i18n.tr("Loops: play it once"), lit = !pb.once) { pb.once = !pb.once }
		ui.spacer(ui.px(gap))
		t := f64(pb.time)
		number_next(number_w)
		if ui.drag_number(widget_id(key, "now"), &t, step = 0.001, o = {speed = f64(view_per_px(e).x)}) { pb.time = f32(t) }
		ui.spacer(ui.px(gap))
		speed := f64(pb.speed == 0 ? 1 : pb.speed)
		// (the speed takes what the row's end leaves: its left edge is the value's under it)
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.drag_number(widget_id(key, "speed"), &speed, lo = 0.05, hi = 4, step = 0.05) { pb.speed = f32(speed) }
		ui.spacer(ui.px(gap))
		if tool_button(widget_id(key, "frame"), lucide.SCAN, i18n.tr("Frame all keys (F)")) { curve_frame(e, cs) }
		if tool_button(widget_id(key, "print"), lucide.COPY, i18n.tr("Print as Odin source, and copy it")) {
			text := n == 1 ? curve_text(cs[0]) : curves_text(cs)
			fmt.println(text)
			ui.window_clipboard_set(text)
		}
	}

	// the graph, its channels' letters in its corner
	ui.spacer(ui.px(gap))
	ui.next({width = ui.fill(), height = ui.px(math.round(h * CURVE_GRAPH_ROWS)), axis = .X})
	g := ui.build_box({.Clickable, .Focusable, .Scroll_Self, .Clip, .Middle_Click, .Ctrl_Wheel, .Draw_Focus_Ring}, widget_id(key, "graph"))
	e.width = g.rect.max.x - g.rect.min.x
	e.names = n > 1 ? channel_names(names, n) : ""
	e.legend_n, e.legend_h = len(e.names), h
	if graph_input(s, e, g, cs, pb) { changed = true }
	graph_prepare(e, g, cs, pb, colors)
	ui.a11y_default(g, {role = .Group, name = label, role_description = i18n.tr("curve")})
	// (the letters are boxes of their own, check boxes for a screen reader and stops of Tab, Space toggles one: drawn in
	// the graph's corner by graph_draw, where legend_cell puts them)
	if e.legend_n > 0 {
		ui.push_parent(g)
		defer ui.pop_parent()
		ui.spacer(ui.fill())
		for i in 0 ..< e.legend_n {
			ui.next({width = ui.px(h), height = ui.px(h)})
			b := ui.build_box({.Clickable, .Focusable, .Draw_Focus_Ring}, widget_id(key, fmt.tprintf("channel%d", i)))
			if ui.signal(b).clicked {
				if i in e.hidden { e.hidden -= {i} } else { e.hidden += {i}; e.selected[i] = {} }
			}
			ui.a11y_default(b, {role = .Check_Box, name = e.names[i:i + 1], role_description = i18n.tr("channel"), toggled = i in e.hidden ? .False : .True})
		}
	}

	// the keys selected: the first one's time and value (a change moves them all by as much), their interpolation, their
	// handles smoothed, broken or aligned
	if ch, ki := first_selected(e, cs); ch >= 0 {
		k := cs[ch].keys[ki]
		if sub_row(p, i18n.tr("key"), widget_id(key, "key")) {
			if tool_button(widget_id(key, "smooth"), lucide.SPLINE, i18n.tr("Smooth handles")) {
				step_push(e, cs)
				for c, ci in cs { for i in 0 ..< c.count { if i in e.selected[ci] { curve_smooth(&cs[ci], i) } } }
				changed = true
			}
			if tool_button(widget_id(key, "broken"), k.broken ? lucide.UNLINK : lucide.LINK, k.broken ? i18n.tr("Handles broken: align them") : i18n.tr("Handles aligned: break them"), lit = k.broken) {
				step_push(e, cs)
				for c, ci in cs { for i in 0 ..< c.count { if i in e.selected[ci] { cs[ci].keys[i].broken = !k.broken } } }
				changed = true
			}
			ui.spacer(ui.px(gap))
			per := view_per_px(e)
			t, v := f64(k.time), f64(k.value)
			number_next(number_w)
			if ui.drag_number(widget_id(key, "key_time"), &t, step = 0.001, o = {speed = f64(per.x), mark = colors[ch]}) {
				field_step(e, cs, "key_time")
				keys_shift(e, cs, {f32(t) - k.time, 0})
				changed = true
			}
			ui.spacer(ui.px(gap))
			ui.next({width = ui.fill(), height = ui.pct(1)})
			if ui.drag_number(widget_id(key, "key_value"), &v, step = f64(value_step(e)), o = {speed = f64(per.y)}) {
				field_step(e, cs, "key_value")
				keys_shift(e, cs, {0, f32(v) - k.value})
				changed = true
			}
			ui.spacer(ui.px(gap))
			chosen := int(k.interp)
			ui.next({width = ui.px(end), height = ui.pct(1)})
			if ui.dropdown(widget_id(key, "interp"), kinds, &chosen) && chosen != int(k.interp) {
				step_push(e, cs)
				for c, ci in cs { for i in 0 ..< c.count { if i in e.selected[ci] { cs[ci].keys[i].interp = Curve_Interp(chosen) } } }
				changed = true
			}
		}
	}
	return
}

// A row of the editor under its head: a label in the panel's column, its fields after it.
@(private, require_results, deferred_out = row_end)
sub_row :: proc(p: ^Pass, label, id: string) -> bool {
	ui.spacer(ui.px(ui.dense_gap()))
	ui.dense_row_open(label, id, row_label_width(p, label))
	return true
}

// A glyph's button of a dense row.
@(private)
tool_button :: proc(id, icon, tip: string, lit := false) -> bool {
	h := ui.dense_row_height()
	ui.next({width = ui.px(h), height = ui.px(h)})
	return ui.button(id, icon = icon, o = {icon_font = ui.lucide_icons(), face = .Ghost, tip = tip, lit = lit}).clicked
}

// The channels' colours: the axes' hues, as drag_vector's marks.
@(private)
channel_colors :: proc() -> (c: [CURVE_CHANNELS_MAX]ui.Color) {
	HUES :: [CURVE_CHANNELS_MAX]ui.Hue{.Red, .Green, .Blue, .Purple}
	hues := HUES
	for h, i in hues { c[i] = ui.hue(h) }
	return
}

// The channels' letters: §names§ cut or completed to §n§ ("xyzw"'s).
@(private)
channel_names :: proc(names: string, n: int) -> string {
	if len(names) >= n { return names[:n] }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, names)
	axes := "xyzw"
	for i in len(names) ..< n { strings.write_byte(&b, axes[i]) }
	return strings.to_string(b)
}

@(private)
keys_set :: proc(count: int) -> (s: bit_set[0 ..< CURVE_KEYS_MAX]) {
	for i in 0 ..< clamp(count, 0, CURVE_KEYS_MAX) { s += {i} }
	return
}

@(private)
first_selected :: proc(e: ^Curve_Edit, cs: []Curve) -> (channel, key: int) {
	for c, ch in cs {
		for i in 0 ..< c.count { if i in e.selected[ch] { return ch, i } }
	}
	return -1, -1
}

////////////////////////////////
// The view

@(private)
plot_usable :: proc(r: ui.Rect) -> bool { return r.max.x - r.min.x >= 4 && r.max.y - r.min.y >= 4 }

// The graph's area for the curves: the box less the values' ruler at its left and the time's under it.
@(private)
plot_of :: proc(r: ui.Rect, ruler_w, ruler_h: f32) -> ui.Rect { return {{r.min.x + ruler_w, r.min.y}, {r.max.x, r.max.y - ruler_h}} }

@(private)
to_screen :: proc(lo, hi: [2]f32, plot: ui.Rect, p: [2]f32) -> [2]f32 {
	w := plot.max - plot.min
	return {plot.min.x + (p.x - lo.x) / (hi.x - lo.x) * w.x, plot.max.y - (p.y - lo.y) / (hi.y - lo.y) * w.y}
}

@(private)
to_curve :: proc(lo, hi: [2]f32, plot: ui.Rect, s: [2]f32) -> [2]f32 {
	w := plot.max - plot.min
	return {lo.x + (s.x - plot.min.x) / w.x * (hi.x - lo.x), lo.y + (plot.max.y - s.y) / w.y * (hi.y - lo.y)}
}

// What a logical pixel is in time and value, by the last layout (a field's drag moves as the graph's).
@(private)
view_per_px :: proc(e: ^Curve_Edit) -> [2]f32 {
	if !plot_usable(e.plot) { return {0.01, 0.01} }
	w := (e.plot.max - e.plot.min) / ui.scale()
	return (e.hi - e.lo) / w
}

// The step a value's field rounds to: a thousandth of the view's height, a power of ten.
@(private)
value_step :: proc(e: ^Curve_Edit) -> f32 {
	span := e.hi.y - e.lo.y
	if span <= 0 { return 0.001 }
	return f32(math.pow(10, math.floor(math.log10(f64(span))) - 3))
}

// The view around every key shown (none: 0..1 both ways).
@(private)
curve_frame :: proc(e: ^Curve_Edit, cs: []Curve) {
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{-max(f32), -max(f32)}
	any := false
	for c, ch in cs {
		if ch in e.hidden { continue }
		for i in 0 ..< clamp(c.count, 0, CURVE_KEYS_MAX) {
			k := c.keys[i]
			lo = {min(lo.x, k.time), min(lo.y, k.value)}
			hi = {max(hi.x, k.time), max(hi.y, k.value)}
			any = true
		}
	}
	if !any { e.lo, e.hi = {0, 0}, {1, 1}; return }
	if hi.x - lo.x < 1e-4 { lo.x -= 0.5; hi.x += 0.5 }
	if hi.y - lo.y < 1e-4 { lo.y -= 1; hi.y += 1 }
	m := (hi - lo) * CURVE_FRAME_MARGIN
	e.lo, e.hi = lo - m, hi + m
}

// The grid's step over §span§ shown in §px§ pixels: 1, 2 or 5 times a power of ten, at least §least§ pixels apart.
@(private)
grid_step :: proc(span, px, least: f32) -> f32 {
	if !(span > 0) || !(px > 0) { return 1 }
	raw := f64(span * least / px)
	mag := math.pow(10, math.floor(math.log10(raw)))
	for m in ([]f64{1, 2, 5}) { if m * mag >= raw { return f32(m * mag) } }
	return f32(10 * mag)
}

////////////////////////////////
// The graph's input

@(private)
graph_input :: proc(s: ^ui.State, e: ^Curve_Edit, g: ^ui.Box, cs: []Curve, pb: ^Playback) -> (changed: bool) {
	e.ruler_w = value_ruler_width(e, g.rect)
	e.plot = plot_of(g.rect, e.ruler_w, ui.dense_row_height())
	sig := ui.signal(g)
	if !plot_usable(e.plot) { return }
	plot := e.plot
	mouse := s.mouse

	// the wheel zooms about the pointer: Ctrl the time only, Shift the value only
	if sig.scrolled != {} {
		d := sig.scrolled.y != 0 ? sig.scrolled.y : sig.scrolled.x
		k := f32(math.pow(CURVE_ZOOM_STEP, f64(d)))
		at := to_curve(e.lo, e.hi, plot, mouse)
		for axis in 0 ..< 2 {
			if axis == 0 && .Shift in sig.mods { continue }
			if axis == 1 && .Ctrl in sig.mods { continue }
			lo, hi := at[axis] - (at[axis] - e.lo[axis]) * k, at[axis] + (e.hi[axis] - at[axis]) * k
			if hi - lo > 1e-5 && hi - lo < 1e9 { e.lo[axis], e.hi[axis] = lo, hi }
		}
	}

	if s.pressed_key[.Middle] == g.key && e.gesture.kind == .None {
		e.gesture = {kind = .Pan, press = s.press_pos[.Middle], view_lo = e.lo, view_hi = e.hi}
	}
	if sig.pointer_pressed && e.gesture.kind == .None {
		at := s.press_pos[.Left]
		h := curve_hit(e, plot, g.rect, cs, at)
		if sig.double_clicked && h.kind == .None {
			if key_add(e, cs, at) { changed = true }
		} else {
			graph_press(e, cs, pb, h, at, sig.mods)
		}
	}
	if graph_follow(s, e, g, cs, pb) { changed = true }

	if sig.focused && e.gesture.kind == .None {
		if ui.key_press(.Delete) || ui.key_press(.Backspace) { if keys_delete(e, cs) { changed = true } }
		if ui.key_press(.A, {.Ctrl}) {
			for c, ch in cs { e.selected[ch] = ch in e.hidden ? {} : keys_set(c.count) }
		}
		if ui.key_press(.F) { curve_frame(e, cs) }
		if ui.key_press(.Z, {.Ctrl}) { if curve_undo(e, cs, false) { changed = true } }
		if ui.key_press(.Z, {.Ctrl, .Shift}) || ui.key_press(.Y, {.Ctrl}) { if curve_undo(e, cs, true) { changed = true } }
		if ui.key_press(.Escape) { e.selected = {} }
	}
	// (Space or Enter on the graph: its keyboard click)
	if sig.clicked && !sig.pointer_clicked { pb.paused = !pb.paused }
	if e.gesture.kind != .None { ui.keep_animating() }
	return
}

// What is under §at§: a handle of a key selected first, then a key, then the time's ruler.
@(private)
curve_hit :: proc(e: ^Curve_Edit, plot, box: ui.Rect, cs: []Curve, at: [2]f32) -> (hit: Curve_Hit) {
	reach := ui.font_size() * CURVE_HIT_EM
	best := reach * reach
	near :: proc(a, b: [2]f32) -> f32 { d := a - b; return d.x * d.x + d.y * d.y }
	for c, ch in cs {
		if ch in e.hidden { continue }
		for i in 0 ..< c.count {
			if i not_in e.selected[ch] { continue }
			k := c.keys[i]
			for out in ([]bool{false, true}) {
				if !handle_shown(c, i, out) { continue }
				hp := out ? k.out_handle : k.in_handle
				if d := near(to_screen(e.lo, e.hi, plot, {k.time + hp.x, k.value + hp.y}), at); d < best {
					best, hit = d, {kind = .Handle, channel = ch, key = i, out = out}
				}
			}
		}
	}
	if hit.kind != .None { return }
	best = reach * reach
	for c, ch in cs {
		if ch in e.hidden { continue }
		for i in 0 ..< c.count {
			k := c.keys[i]
			if d := near(to_screen(e.lo, e.hi, plot, {k.time, k.value}), at); d < best {
				best, hit = d, {kind = .Key, channel = ch, key = i}
			}
		}
	}
	if hit.kind == .None && at.y >= plot.max.y && at.y < box.max.y && at.x >= plot.min.x { hit.kind = .Ruler }
	return
}

// The channels' letter §i§ of §n§ in the graph's top right corner: a cell §h§ wide and high.
@(private)
legend_cell :: proc(plot: ui.Rect, n, i: int, h: f32) -> ui.Rect {
	x := plot.max.x - f32(n - i) * h
	return {{x, plot.min.y}, {x + h, plot.min.y + h}}
}

// The values' ruler as wide as its longest number (the view's lowest and highest grid lines) and a little inset.
@(private)
value_ruler_width :: proc(e: ^Curve_Edit, box: ui.Rect) -> f32 {
	em := ui.font_size()
	size := math.round(em * 0.9)
	digit := ui.text_width(ui.mono_font(), size, "0")
	plot_h := box.max.y - box.min.y - ui.dense_row_height()
	sy := grid_step(e.hi.y - e.lo.y, plot_h, em * CURVE_VALUE_GAP_EM)
	longest := 1
	for v in ([]f32{math.ceil(e.lo.y / sy) * sy, math.floor(e.hi.y / sy) * sy}) { longest = max(longest, len(grid_label(v, sy))) }
	return math.ceil(f32(longest) * digit + em * 0.6)
}

// Whether key §i§ has its in (or out) handle: the segment on that side is a Bézier.
@(private)
handle_shown :: proc(c: Curve, i: int, out: bool) -> bool {
	if out { return i < c.count - 1 && c.keys[i].interp == .Bezier }
	return i > 0 && c.keys[i - 1].interp == .Bezier
}

@(private)
graph_press :: proc(e: ^Curve_Edit, cs: []Curve, pb: ^Playback, h: Curve_Hit, at: [2]f32, mods: platform.Modifiers) {
	additive := .Shift in mods || .Ctrl in mods
	switch h.kind {
	case .Ruler:
		e.gesture = {kind = .Scrub, press = at}
		pb.time = to_curve(e.lo, e.hi, e.plot, at).x
	case .Handle:
		e.base = step_of(cs)
		e.base_selected = e.selected
		e.gesture = {kind = .Handle, press = at, channel = h.channel, key = h.key, out = h.out}
	case .Key:
		// (Shift or Ctrl on a key selected takes it away at the release, if it did not drag: Shift held from the press
		// constrains a drag of the selection)
		sel := &e.selected[h.channel]
		was := h.key in sel^
		if !was {
			if !additive { e.selected = {} }
			e.selected[h.channel] += {h.key}
		}
		e.base = step_of(cs)
		e.base_selected = e.selected
		e.gesture = {kind = .Move, press = at, channel = h.channel, key = h.key, collapse = was && !additive, toggle = was && additive}
	case .None:
		e.gesture = {kind = .Band, press = at, additive = additive}
	}
}

// A gesture under way: each frame from the curves at its start, so that nothing drifts and Escape puts them back.
@(private)
graph_follow :: proc(s: ^ui.State, e: ^Curve_Edit, g: ^ui.Box, cs: []Curve, pb: ^Playback) -> (changed: bool) {
	gs := &e.gesture
	if gs.kind == .None { return }
	plot := e.plot
	mouse := s.mouse
	held := s.active_key[.Left] == g.key
	threshold := CURVE_DRAG_PX * ui.scale()
	if gs.kind != .Pan && gs.kind != .Scrub && held && ui.focus_key() == g.key && ui.key_press(.Escape) {
		// (a band has no curves of its own at its start: e.base is the last move's)
		if gs.kind == .Move || gs.kind == .Handle {
			if gs.moved { restore(e, cs, e.base); changed = true }
			e.selected = e.base_selected
		}
		gs^ = {}
		return
	}
	if !gs.moved {
		d := mouse - gs.press
		if d.x * d.x + d.y * d.y >= threshold * threshold {
			gs.moved = true
			if gs.kind == .Move || gs.kind == .Handle { undo.push(&e.history, e.base, CURVE_UNDO_MAX, nil) }
		}
	}
	switch gs.kind {
	case .None:
	case .Pan:
		if s.active_key[.Middle] != g.key { gs^ = {}; break }
		d := mouse - gs.press
		w := plot.max - plot.min
		span := gs.view_hi - gs.view_lo
		shift := [2]f32{-d.x / w.x * span.x, d.y / w.y * span.y}
		e.lo, e.hi = gs.view_lo + shift, gs.view_hi + shift
	case .Scrub:
		if !held { gs^ = {}; break }
		pb.time = to_curve(e.lo, e.hi, plot, mouse).x
	case .Move:
		if !held {
			if !gs.moved && gs.collapse {
				e.selected = {}
				e.selected[gs.channel] = {gs.key}
			}
			if !gs.moved && gs.toggle { e.selected[gs.channel] -= {gs.key} }
			gs^ = {}
			break
		}
		if !gs.moved { break }
		d := to_curve(e.lo, e.hi, plot, mouse) - to_curve(e.lo, e.hi, plot, gs.press)
		// Shift: the main direction only
		if .Shift in s.mods {
			if abs(mouse.x - gs.press.x) >= abs(mouse.y - gs.press.y) { d.y = 0 } else { d.x = 0 }
		}
		// Ctrl: the key pressed lands on the grid
		if .Ctrl in s.mods {
			k0 := e.base.curves[gs.channel].keys[gs.key]
			w := plot.max - plot.min
			em := ui.font_size()
			step := [2]f32{grid_step(e.hi.x - e.lo.x, w.x, em * CURVE_TIME_GAP_EM), grid_step(e.hi.y - e.lo.y, w.y, em * CURVE_VALUE_GAP_EM)}
			from := [2]f32{k0.time, k0.value}
			for axis in 0 ..< 2 {
				if d[axis] == 0 && .Shift in s.mods { continue }
				d[axis] = math.round((from[axis] + d[axis]) / step[axis]) * step[axis] - from[axis]
			}
		}
		keys_move(e, cs, d)
		changed = true
	case .Handle:
		if !held { gs^ = {}; break }
		if !gs.moved { break }
		handle_drag(e, cs, gs^, to_curve(e.lo, e.hi, plot, mouse), s.mods)
		changed = true
	case .Band:
		if held { break }
		if gs.moved {
			a, b := to_curve(e.lo, e.hi, plot, gs.press), to_curve(e.lo, e.hi, plot, mouse)
			lo := [2]f32{min(a.x, b.x), min(a.y, b.y)}
			hi := [2]f32{max(a.x, b.x), max(a.y, b.y)}
			if !gs.additive { e.selected = {} }
			for c, ch in cs {
				if ch in e.hidden { continue }
				for i in 0 ..< c.count {
					k := c.keys[i]
					if k.time >= lo.x && k.time <= hi.x && k.value >= lo.y && k.value <= hi.y { e.selected[ch] += {i} }
				}
			}
		} else if !gs.additive {
			e.selected = {}
		}
		gs^ = {}
	}
	return
}

// The keys selected at the gesture's start moved by §d§ from where they were, then sorted, their selection with them.
@(private)
keys_move :: proc(e: ^Curve_Edit, cs: []Curve, d: [2]f32) {
	for ch in 0 ..< len(cs) {
		sel := e.base_selected[ch]
		if sel == {} { continue }
		c := e.base.curves[ch]
		for i in 0 ..< c.count { if i in sel { c.keys[i].time += d.x; c.keys[i].value += d.y } }
		e.selected[ch] = keys_sort(&c, sel)
		cs[ch] = c
	}
}

// The keys selected moved by §d§ from where they are (a field's change).
@(private)
keys_shift :: proc(e: ^Curve_Edit, cs: []Curve, d: [2]f32) {
	for ch in 0 ..< len(cs) {
		sel := e.selected[ch]
		if sel == {} { continue }
		c := &cs[ch]
		for i in 0 ..< c.count { if i in sel { c.keys[i].time += d.x; c.keys[i].value += d.y } }
		e.selected[ch] = keys_sort(c, sel)
	}
}

// Sorts the keys by time (stable: a key keeps its place among those of its time) and gives the selection's new indices.
@(private)
keys_sort :: proc(c: ^Curve, sel: bit_set[0 ..< CURVE_KEYS_MAX]) -> (out: bit_set[0 ..< CURVE_KEYS_MAX]) {
	n := clamp(c.count, 0, CURVE_KEYS_MAX)
	on: [CURVE_KEYS_MAX]bool
	for i in 0 ..< n { on[i] = i in sel }
	for i in 1 ..< n {
		k, s := c.keys[i], on[i]
		j := i
		for j > 0 && c.keys[j - 1].time > k.time {
			c.keys[j], on[j] = c.keys[j - 1], on[j - 1]
			j -= 1
		}
		c.keys[j], on[j] = k, s
	}
	for i in 0 ..< n { if on[i] { out += {i} } }
	return
}

// A handle dragged to §to§ (time, value): held to its side and its segment; Shift flat; aligned, the other handle turns
// with it, unless the key's handles are broken (Alt breaks them).
@(private)
handle_drag :: proc(e: ^Curve_Edit, cs: []Curve, g: Curve_Gesture, to: [2]f32, mods: platform.Modifiers) {
	c := &cs[g.channel]
	if g.key >= c.count { return }
	k0 := e.base.curves[g.channel].keys[g.key]
	left := g.key > 0 ? k0.time - c.keys[g.key - 1].time : 0
	right := g.key < c.count - 1 ? c.keys[g.key + 1].time - k0.time : 0
	p := to - {k0.time, k0.value}
	p.x = g.out ? clamp(p.x, 0, right) : clamp(p.x, -left, 0)
	if .Shift in mods { p.y = 0 }
	k := k0
	k.broken = k0.broken || .Alt in mods
	if g.out { k.out_handle = p } else { k.in_handle = p }
	if !k.broken {
		other := g.out ? &k.in_handle : &k.out_handle
		room := g.out ? left : right
		// (an aligned handle of no length takes the dragged one's, within its segment)
		if other.x == 0 && other.y == 0 { other.x = g.out ? -min(p.x, room) : min(-p.x, room) }
		if p.x != 0 {
			other.y = other.x * p.y / p.x
		} else {
			length := math.sqrt(other.x * other.x + other.y * other.y)
			other^ = {0, p.y > 0 ? -length : length}
		}
	}
	c.keys[g.key] = k
}

// A double click on nothing: a key there, on the channel whose curve passes nearest, its handles smooth, selected.
@(private)
key_add :: proc(e: ^Curve_Edit, cs: []Curve, at: [2]f32) -> bool {
	p := to_curve(e.lo, e.hi, e.plot, at)
	best, channel := max(f32), -1
	for c, ch in cs {
		if ch in e.hidden || c.count >= CURVE_KEYS_MAX { continue }
		y := to_screen(e.lo, e.hi, e.plot, {p.x, curve_eval(c, p.x)}).y
		if d := abs(y - at.y); d < best { best, channel = d, ch }
	}
	if channel < 0 { return false }
	step_push(e, cs)
	c := &cs[channel]
	k := Curve_Key{time = p.x, value = p.y}
	// (the segment it splits keeps its kind)
	for i := c.count - 1; i >= 0; i -= 1 { if c.keys[i].time <= p.x { k.interp = c.keys[i].interp; break } }
	i := curve_insert(c, k)
	curve_smooth(c, i)
	e.selected = {}
	e.selected[channel] = {i}
	return true
}

@(private)
keys_delete :: proc(e: ^Curve_Edit, cs: []Curve) -> bool {
	any := false
	for ch in 0 ..< len(cs) { if e.selected[ch] != {} { any = true } }
	if !any { return false }
	step_push(e, cs)
	for ch in 0 ..< len(cs) {
		for i := cs[ch].count - 1; i >= 0; i -= 1 { if i in e.selected[ch] { curve_remove(&cs[ch], i) } }
	}
	e.selected = {}
	return true
}

////////////////////////////////
// Undo

@(private)
step_of :: proc(cs: []Curve) -> (s: Curve_Step) {
	s.n = len(cs)
	for c, i in cs { s.curves[i] = c }
	return
}

@(private)
restore :: proc(e: ^Curve_Edit, cs: []Curve, s: Curve_Step) {
	for i in 0 ..< min(len(cs), s.n) { cs[i] = s.curves[i] }
}

@(private)
step_push :: proc(e: ^Curve_Edit, cs: []Curve) {
	undo.push(&e.history, step_of(cs), CURVE_UNDO_MAX, nil)
	e.field = ""
}

// A field's change: one step per field and drag (a new field, or the button let go since).
@(private)
field_step :: proc(e: ^Curve_Edit, cs: []Curve, field: string) {
	if e.field != field || e.field_free { undo.push(&e.history, step_of(cs), CURVE_UNDO_MAX, nil) }
	e.field, e.field_free = field, false
}

@(private)
curve_undo :: proc(e: ^Curve_Edit, cs: []Curve, again: bool) -> bool {
	now := step_of(cs)
	back: Curve_Step
	ok: bool
	if again { back, ok = undo.redo(&e.history, now) } else { back, ok = undo.undo(&e.history, now) }
	if !ok { return false }
	restore(e, cs, back)
	e.selected = {}
	e.field = ""
	return true
}

////////////////////////////////
// Drawing

// What the graph's draw needs, copied into the frame's arena: no pointer of the program is kept past its procedure.
@(private)
Curve_Draw :: struct {
	step:      Curve_Step,
	hidden:    bit_set[0 ..< CURVE_CHANNELS_MAX],
	selected:  [CURVE_CHANNELS_MAX]bit_set[0 ..< CURVE_KEYS_MAX],
	colors:    [CURVE_CHANNELS_MAX]ui.Color,
	lo, hi:    [2]f32,
	time:      f32,
	band:      bool,
	band_from, band_to: [2]f32,
	ground, rule, grid, zero, ink, label, accent: ui.Color,
	mono:      font.Font_Id,
	size, em, sc, digit: f32,
	ruler_w, ruler_h: f32,
	names:     [CURVE_CHANNELS_MAX]u8,   // the legend's letters
	legend:    int,
}

@(private)
graph_prepare :: proc(e: ^Curve_Edit, g: ^ui.Box, cs: []Curve, pb: ^Playback, colors: [CURVE_CHANNELS_MAX]ui.Color) {
	em := ui.font_size()
	d := ui.frame_new(Curve_Draw)
	d.step = step_of(cs)
	d.hidden, d.selected, d.colors = e.hidden, e.selected, colors
	d.lo, d.hi, d.time = e.lo, e.hi, pb.time
	if e.gesture.kind == .Band && e.gesture.moved {
		d.band, d.band_from, d.band_to = true, e.gesture.press, ui.mouse_pos()
	}
	ui.push_tags("input")
	d.ground = ui.color("background")
	d.rule = ui.color("border")
	d.ink = ui.color("text")
	ui.pop_tags()
	ui.push_tags("weak")
	weak := ui.color("text")
	ui.pop_tags()
	// (a dense label's rule: the weak ink moved until it reads at 4.5:1 on the graph)
	d.label = ui.readable(weak, d.ground, 4.5)
	d.grid = d.rule
	d.grid.a *= 0.55
	d.zero = d.label
	d.zero.a *= 0.6
	d.accent = ui.color("accent")
	d.mono = ui.mono_font()
	d.size = math.round(em * 0.9)
	d.em, d.sc = em, ui.scale()
	d.digit = ui.text_width(d.mono, d.size, "0")
	d.ruler_w, d.ruler_h = e.ruler_w, ui.dense_row_height()
	d.legend = len(e.names)
	for i in 0 ..< d.legend { d.names[i] = e.names[i] }
	g.custom, g.custom_user = graph_draw, d
}

@(private)
graph_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Curve_Draw)(user)
	r := b.rect
	plot := plot_of(r, d.ruler_w, d.ruler_h)
	if !plot_usable(plot) || !(d.hi.x > d.lo.x) || !(d.hi.y > d.lo.y) { return }
	hair := max(1, math.round(d.sc))
	w := plot.max - plot.min
	draw.rect(dc, r, d.ground)
	draw.push_clip(dc, r)
	defer draw.pop_clip(dc)
	text_y :: proc(d: ^Curve_Draw, middle: f32) -> f32 { return math.round(middle + d.size * 0.36) }

	// the grid, its lines numbered on the rulers (a bounded count: what fits the pixels)
	sx := grid_step(d.hi.x - d.lo.x, w.x, d.em * CURVE_TIME_GAP_EM)
	first := math.ceil(f64(d.lo.x) / f64(sx))
	for i in 0 ..< int(w.x / (d.em * CURVE_TIME_GAP_EM) * 3) + 3 {
		t := f32((first + f64(i)) * f64(sx))
		if t > d.hi.x { break }
		x := math.round(to_screen(d.lo, d.hi, plot, {t, 0}).x)
		draw.rect(dc, {{x, plot.min.y}, {x + hair, plot.max.y}}, abs(t) < sx * 1e-3 ? d.zero : d.grid)
		words := grid_label(t, sx)
		half := f32(len(words)) * d.digit * 0.5
		if x - half >= plot.min.x && x + half <= r.max.x {
			draw.text(dc, d.mono, d.size, {math.round(x - half), text_y(d, plot.max.y + d.ruler_h * 0.5)}, d.label, words)
		}
	}
	sy := grid_step(d.hi.y - d.lo.y, w.y, d.em * CURVE_VALUE_GAP_EM)
	first = math.ceil(f64(d.lo.y) / f64(sy))
	for i in 0 ..< int(w.y / (d.em * CURVE_VALUE_GAP_EM) * 3) + 3 {
		v := f32((first + f64(i)) * f64(sy))
		if v > d.hi.y { break }
		y := math.round(to_screen(d.lo, d.hi, plot, {0, v}).y)
		draw.rect(dc, {{plot.min.x, y}, {plot.max.x, y + hair}}, abs(v) < sy * 1e-3 ? d.zero : d.grid)
		words := grid_label(v, sy)
		if y - d.size * 0.5 >= r.min.y && y + d.size * 0.5 <= plot.max.y {
			draw.text(dc, d.mono, d.size, {math.round(plot.min.x - d.em * 0.3 - f32(len(words)) * d.digit), text_y(d, y)}, d.label, words)
		}
	}
	draw.rect(dc, {{plot.min.x, r.min.y}, {plot.min.x + hair, plot.max.y}}, d.rule)
	draw.rect(dc, {{plot.min.x, plot.max.y}, {r.max.x, plot.max.y + hair}}, d.rule)

	draw.push_clip(dc, plot)
	// the curves: a point every CURVE_SAMPLE_PX of the width, whatever the keys
	count := int(w.x / (CURVE_SAMPLE_PX * d.sc)) + 2
	points := make([]draw.Vec2, count, context.temp_allocator)
	for ch in 0 ..< d.step.n {
		if ch in d.hidden { continue }
		c := d.step.curves[ch]
		for i in 0 ..< count {
			x := min(plot.min.x + f32(i) * CURVE_SAMPLE_PX * d.sc, plot.max.x)
			t := to_curve(d.lo, d.hi, plot, {x, 0}).x
			y := to_screen(d.lo, d.hi, plot, {0, curve_eval(c, t)}).y
			points[i] = {x, clamp(y, plot.min.y - w.y, plot.max.y + w.y)}
		}
		draw.polyline(dc, points, math.round(1.5 * d.sc), d.colors[ch])
	}
	// the keys, the handles of those selected
	kr := math.round(d.em * CURVE_KEY_EM)
	for ch in 0 ..< d.step.n {
		if ch in d.hidden { continue }
		c := d.step.curves[ch]
		for i in 0 ..< c.count {
			k := c.keys[i]
			at := to_screen(d.lo, d.hi, plot, {k.time, k.value})
			if at.x < plot.min.x - kr * 8 || at.x > plot.max.x + kr * 8 { continue }
			at = {math.round(at.x), math.round(at.y)}
			if i in d.selected[ch] {
				for out in ([]bool{false, true}) {
					if !handle_shown(c, i, out) { continue }
					hp := out ? k.out_handle : k.in_handle
					end := to_screen(d.lo, d.hi, plot, {k.time + hp.x, k.value + hp.y})
					draw.line(dc, at, end, hair, d.label)
					draw.rect(dc, {end - kr * 0.8, end + kr * 0.8}, d.ink, kr)
					draw.rect(dc, {end - kr * 0.8 + hair, end + kr * 0.8 - hair}, d.accent, kr)
				}
				draw.rect(dc, {at - kr - hair, at + kr + hair}, d.ink)
				draw.rect(dc, {at - kr + hair, at + kr - hair}, d.accent)
			} else {
				draw.rect(dc, {at - kr, at + kr}, d.ground)
				draw.rect(dc, {at - kr + hair, at + kr - hair}, d.colors[ch])
			}
		}
	}
	// the channels' letters in the corner: shown in their colour, hidden in the labels' and struck
	for i in 0 ..< d.legend {
		cell := legend_cell(plot, d.legend, i, d.ruler_h)
		draw.rect(dc, cell, d.ground)
		ink := i in d.hidden ? d.label : d.colors[i]
		middle := (cell.min.y + cell.max.y) * 0.5
		draw.text(dc, d.mono, d.size, {math.round((cell.min.x + cell.max.x - d.digit) * 0.5), text_y(d, middle)}, ink, string(d.names[i:i + 1]))
		if i in d.hidden { draw.rect(dc, {{cell.min.x + d.digit * 0.4, math.round(middle)}, {cell.max.x - d.digit * 0.4, math.round(middle) + hair}}, d.label) }
	}
	if d.band {
		lo := [2]f32{min(d.band_from.x, d.band_to.x), min(d.band_from.y, d.band_to.y)}
		hi := [2]f32{max(d.band_from.x, d.band_to.x), max(d.band_from.y, d.band_to.y)}
		fill := d.accent
		fill.a *= 0.14
		draw.rect(dc, {lo, hi}, fill)
		draw.rect(dc, {lo, hi}, d.accent, 0, hair)
	}
	draw.pop_clip(dc)

	// the playhead across the graph, its grip at the top (the ruler's numbers stay whole)
	x := math.round(to_screen(d.lo, d.hi, plot, {d.time, 0}).x)
	if x >= plot.min.x && x <= plot.max.x {
		draw.rect(dc, {{x, plot.min.y}, {x + hair, plot.max.y}}, d.accent)
		m := math.round(d.em * 0.3)
		draw.rect(dc, {{x - m, plot.min.y}, {x + hair + m, plot.min.y + m * 1.5}}, d.accent)
	}
}

// A grid line's number: as many decimals as its step has.
@(private)
grid_label :: proc(v, step: f32) -> string {
	decimals := max(0, int(-math.floor(math.log10(f64(step)) + 1e-6)))
	x := abs(v) < step * 1e-3 ? 0 : v
	return fmt.tprintf(fmt.tprintf("%%.%df", decimals), x)
}

////////////////////////////////
// The tools' form: JSON

@(private)
curve_json :: proc(sb: ^strings.Builder, c: Curve) {
	f := type_info_of(f32)
	strings.write_byte(sb, '[')
	for i in 0 ..< clamp(c.count, 0, CURVE_KEYS_MAX) {
		k := c.keys[i]
		if i > 0 { strings.write_byte(sb, ',') }
		fmt.sbprintf(sb, `{{"time":%s,"value":%s,"in_handle":[%s,%s],"out_handle":[%s,%s],"interp":%q,"broken":%v}}`,
			json_number(f64(k.time), f), json_number(f64(k.value), f), json_number(f64(k.in_handle.x), f), json_number(f64(k.in_handle.y), f),
			json_number(f64(k.out_handle.x), f), json_number(f64(k.out_handle.y), f), interp_name(k.interp), k.broken)
	}
	strings.write_byte(sb, ']')
}

@(private)
interp_name :: proc(i: Curve_Interp) -> string {
	switch i {
	case .Bezier:   return "bezier"
	case .Linear:   return "linear"
	case .Constant: return "constant"
	}
	return "bezier"
}

// A tool's keys: a list of §n§ channels, each a list of keys (one channel: its list alone). A key's fields are Print's
// (CURVE_KEY_FIELDS); a missing one is its zero, another is refused. The keys are sorted; more than CURVE_KEYS_MAX, or a
// number not finite, is refused.
@(private)
curves_parse :: proc(text: string, n: int) -> (out: [CURVE_CHANNELS_MAX]Curve, err: string) {
	// (the devtools give an empty JSON list as "", as an empty list of numbers: no key)
	v, perr := json.parse_string(strings.trim_space(text) == "" ? "[]" : text, allocator = context.temp_allocator)
	if perr != .None { return out, fmt.tprintf("not a list of keys (JSON): %v", perr) }
	list, ok := v.(json.Array)
	if !ok { return out, "a list of keys, or a list of channels each a list of keys" }
	channels := make([dynamic]json.Array, context.temp_allocator)
	flat := len(list) == 0
	if len(list) > 0 { _, flat = list[0].(json.Object) }
	if flat {
		append(&channels, list)
	} else {
		for x in list {
			a, aok := x.(json.Array)
			if !aok { return out, "a channel is a list of keys" }
			append(&channels, a)
		}
	}
	if len(channels) != n { return out, fmt.tprintf("%d channels, not %d", n, len(channels)) }
	for keys, ch in channels {
		if len(keys) > CURVE_KEYS_MAX { return out, fmt.tprintf("%d keys at most, not %d", CURVE_KEYS_MAX, len(keys)) }
		for x in keys {
			o, ook := x.(json.Object)
			if !ook { return out, "a key is an object: {" + CURVE_KEY_FIELDS + "}" }
			for name in o {
				known := false
				for f in strings.split(CURVE_KEY_FIELDS, ", ", context.temp_allocator) { if f == name { known = true } }
				if !known { return out, fmt.tprintf("no key field %q (%s)", name, CURVE_KEY_FIELDS) }
			}
			k: Curve_Key
			k.time = key_number(o, "time", &err)
			k.value = key_number(o, "value", &err)
			k.in_handle = key_pair(o, "in_handle", &err)
			k.out_handle = key_pair(o, "out_handle", &err)
			if iv, has := o["interp"]; has {
				s, sok := iv.(json.String)
				switch sok ? ascii.lower(s) : "" {
				case "bezier":   k.interp = .Bezier
				case "linear":   k.interp = .Linear
				case "constant": k.interp = .Constant
				case: err = fmt.tprintf("interp: bezier, linear or constant, not %v", iv)
				}
			}
			if bv, has := o["broken"]; has {
				b, bok := bv.(json.Boolean)
				if !bok { err = "broken: true or false" }
				k.broken = b
			}
			if err != "" { return }
			k.in_handle.x, k.out_handle.x = min(k.in_handle.x, 0), max(k.out_handle.x, 0)
			curve_insert(&out[ch], k)
		}
	}
	return
}

// A key's fields in a tool's JSON: Print's names (curve_text), one set of names for both.
CURVE_KEY_FIELDS :: "time, value, in_handle, out_handle, interp, broken"

@(private)
key_number :: proc(o: json.Object, name: string, err: ^string) -> f32 {
	v, ok := o[name]
	if !ok { return 0 }
	x, xok := json_f64(v)
	if !xok { err^ = fmt.tprintf("%s: a finite number", name) }
	return f32(x)
}

@(private)
key_pair :: proc(o: json.Object, name: string, err: ^string) -> (p: [2]f32) {
	v, ok := o[name]
	if !ok { return }
	a, aok := v.(json.Array)
	if !aok || len(a) != 2 { err^ = fmt.tprintf("%s: two numbers [time, value]", name); return }
	for i in 0 ..< 2 {
		x, xok := json_f64(a[i])
		if !xok { err^ = fmt.tprintf("%s: two finite numbers", name); return }
		p[i] = f32(x)
	}
	return
}

@(private)
json_f64 :: proc(v: json.Value) -> (f64, bool) {
	x: f64
	#partial switch n in v {
	case json.Integer: x = f64(n)
	case json.Float:   x = n
	case: return 0, false
	}
	if math.is_nan(x) || math.is_inf(x) || abs(x) > f64(max(f32)) { return 0, false }
	return x, true
}

////////////////////////////////
// The easing editor

// The easing presets: the toolkit's own (ui.Ease), by name.
@(private)
easing_presets :: proc() -> [len(ui.Ease)]ui.Cubic_Bezier {
	out: [len(ui.Ease)]ui.Cubic_Bezier
	for e in ui.Ease { out[int(e)] = ui.ease_bezier(e) }
	return out
}

@(private)
easing_any :: proc(label: string, c: ^ui.Cubic_Bezier) -> (changed: bool) {
	p, key, here := item(label)
	if !here { return }
	switch p.kind {
	case .Build:
		changed = easing_editor(p, label, key, c)
	case .List:
		list_open(p, label, "easing")
		f := type_info_of(f32)
		fmt.sbprintf(p.sb, `,"value":[%s,%s,%s,%s],"presets":[`, json_number(f64(c.x1), f), json_number(f64(c.y1), f), json_number(f64(c.x2), f), json_number(f64(c.y2), f))
		for e in ui.Ease {
			if int(e) > 0 { strings.write_byte(p.sb, ',') }
			fmt.sbprintf(p.sb, "%q", fmt.tprint(e))
		}
		strings.write_string(p.sb, "]}")
	case .Apply:
		if p.press { p.err = "a value: set it"; return }
		// (a preset by its name in the code, "In_Out", or as the list shows it, "In out")
		want, _ := strings.replace_all(strings.trim_prefix(strings.trim_space(p.text), "."), "_", " ", context.temp_allocator)
		for e in ui.Ease {
			name, _ := strings.replace_all(fmt.tprint(e), "_", " ", context.temp_allocator)
			if ascii.equal_fold(name, want) { c^ = ui.ease_bezier(e); return true }
		}
		n := numbers_of(want)
		if len(n) != 4 { p.err = fmt.tprintf("four numbers (x1, y1, x2, y2) or a preset's name, not %q", p.text); return }
		c^ = {f32(clamp(n[0], 0, 1)), f32(n[1]), f32(clamp(n[2], 0, 1)), f32(n[3])}
		changed = true
	}
	return
}

@(private)
easing_editor :: proc(p: ^Pass, label: string, key: u64, c: ^ui.Cubic_Bezier) -> (changed: bool) {
	sf := p.surface
	s := sf.state
	h := ui.dense_row_height()
	gap := ui.dense_gap()
	presets := easing_presets()
	names := make([]string, len(presets) + 1, context.temp_allocator)
	chosen := len(presets)
	for e, i in ui.Ease {
		names[i] = easing_word(e)
		if presets[i] == c^ { chosen = i }
	}
	names[len(presets)] = i18n.tr("Custom")
	// One row: the label, the square as tall as the three rows beside it (the presets and Print, then the handles'
	// numbers): no row of its own for the head, no room under the numbers
	side := EASING_ROWS * h + (EASING_ROWS - 1) * gap
	if row_start(p, label, key, side) {
		ui.next({width = ui.px(side), height = ui.px(side)})
		// (no Tab stop: its four numbers are the keyboard's way to the same handles)
		g := ui.build_box({.Clickable}, widget_id(key, "graph"))
		input, hovering := easing_input(s, sf, key, g, c)
		if input { changed = true }
		easing_prepare(g, c^, easing_preview(sf, s, key, c^, hovering))
		ui.a11y_default(g, {role = .Group, name = label, role_description = i18n.tr("easing")})
		ui.spacer(ui.px(gap))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = widget_id(key, "fields")) {
			ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
			if ui.row(.Center, id = widget_id(key, "head")) {
				was := chosen
				ui.next({width = ui.fill(), height = ui.pct(1)})
				if ui.dropdown(widget_id(key, "preset"), names, &chosen) && chosen != was && chosen < len(presets) {
					c^ = presets[chosen]
					changed = true
				}
				if tool_button(widget_id(key, "print"), lucide.COPY, i18n.tr("Print as Odin source, and copy it")) {
					text := fmt.tprintf("ui.Cubic_Bezier{{%s, %s, %s, %s}}", number_odin(c.x1), number_odin(c.y1), number_odin(c.x2), number_odin(c.y2))
					fmt.println(text)
					ui.window_clipboard_set(text)
				}
			}
			for i in 0 ..< 2 {
				x := i == 0 ? &c.x1 : &c.x2
				y := i == 0 ? &c.y1 : &c.y2
				ui.spacer(ui.px(gap))
				ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
				if ui.row(.Center, id = widget_id(key, fmt.tprintf("p%d", i + 1))) {
					xv, yv := f64(x^), f64(y^)
					ui.next({width = ui.fill(), height = ui.pct(1)})
					if ui.drag_number(widget_id(key, fmt.tprintf("x%d", i + 1)), &xv, lo = 0, hi = 1, step = 0.01) { x^ = f32(xv); changed = true }
					ui.spacer(ui.px(gap))
					ui.next({width = ui.fill(), height = ui.pct(1)})
					if ui.drag_number(widget_id(key, fmt.tprintf("y%d", i + 1)), &yv, step = 0.01) { y^ = f32(yv); changed = true }
				}
			}
		}
	}
	return
}

// The square's mapping: EASING_LO..EASING_HI both ways.
@(private)
easing_screen :: proc(r: ui.Rect, p: [2]f32) -> [2]f32 { return to_screen({EASING_LO, EASING_LO}, {EASING_HI, EASING_HI}, r, p) }

// Where the preview's dot is (0..1 of its period): it runs while the pointer is on the square and for one period after
// the curve changed (a drag, a field, a preset, a tool), then rests at its end and asks for no frame. One easing
// previews at a time.
@(private)
easing_preview :: proc(sf: ^Surface, s: ^ui.State, key: u64, c: ui.Cubic_Bezier, hovering: bool) -> f32 {
	seen, known := sf.easing_seen[key]
	changed := known && seen != c
	if !known || changed { sf.easing_seen[key] = c }
	playing := sf.easing_anim_key == key
	if playing && sf.easing_anim_build != s.build_index {
		sf.easing_anim_build = s.build_index
		// (a frame after a rest has the rest as its dt: the dot does not jump past its period)
		sf.easing_anim_t += f64(min(s.dt, 0.1))
	}
	if (hovering || changed) && !playing {
		sf.easing_anim_key, sf.easing_anim_t, sf.easing_anim_end, sf.easing_anim_build = key, 0, 0, s.build_index
		playing = true
	}
	if changed { sf.easing_anim_end = sf.easing_anim_t + EASING_PERIOD }
	if playing && !hovering && sf.easing_anim_t >= max(sf.easing_anim_end, EASING_PERIOD) {
		sf.easing_anim_key = 0
		playing = false
	}
	if !playing { return 1 }
	ui.keep_animating()
	return f32(math.mod(sf.easing_anim_t, EASING_PERIOD) / EASING_PERIOD)
}

// A preset's name as the list shows it, in the person's language.
@(private)
easing_word :: proc(e: ui.Ease) -> string {
	switch e {
	case .Linear:     return i18n.tr("Linear")
	case .Out:        return i18n.tr("Out")
	case .In_Out:     return i18n.tr("In out")
	case .Sine:       return i18n.tr("Sine")
	case .Emphasized: return i18n.tr("Emphasized")
	}
	return ""
}

// A handle dragged; and whether the pointer is on the square.
@(private)
easing_input :: proc(s: ^ui.State, sf: ^Surface, key: u64, g: ^ui.Box, c: ^ui.Cubic_Bezier) -> (changed, hovering: bool) {
	r := g.rect
	sig := ui.signal(g)
	hovering = sig.hovering
	if !plot_usable(r) { return }
	if sig.pointer_pressed {
		at := s.press_pos[.Left]
		reach := ui.font_size() * CURVE_HIT_EM * 1.4
		sf.easing_key, sf.easing_handle = 0, 0
		best := reach * reach
		for i in 1 ..= 2 {
			hp := i == 1 ? [2]f32{c.x1, c.y1} : [2]f32{c.x2, c.y2}
			d := easing_screen(r, hp) - at
			if d2 := d.x * d.x + d.y * d.y; d2 < best { best, sf.easing_key, sf.easing_handle = d2, key, i }
		}
	}
	if sf.easing_key != key { return }
	if s.active_key[.Left] != g.key { sf.easing_key = 0; return }
	p := to_curve({EASING_LO, EASING_LO}, {EASING_HI, EASING_HI}, r, s.mouse)
	p = {clamp(p.x, 0, 1), clamp(p.y, -1, 2)}
	p = {math.round(p.x * 1000) / 1000, math.round(p.y * 1000) / 1000}
	if sf.easing_handle == 1 { c.x1, c.y1 = p.x, p.y } else { c.x2, c.y2 = p.x, p.y }
	changed = true
	return
}

@(private)
Easing_Draw :: struct {
	curve:  ui.Cubic_Bezier,
	t:      f32,   // the preview's place in its period, 0..1
	ground, rule, grid, label, ink, accent, line: ui.Color,
	sc, em: f32,
}

@(private)
easing_prepare :: proc(g: ^ui.Box, c: ui.Cubic_Bezier, t: f32) {
	d := ui.frame_new(Easing_Draw)
	d.curve, d.t = c, t
	ui.push_tags("input")
	d.ground, d.rule, d.ink = ui.color("background"), ui.color("border"), ui.color("text")
	ui.pop_tags()
	ui.push_tags("weak")
	d.label = ui.readable(ui.color("text"), d.ground, 4.5)
	ui.pop_tags()
	d.grid = d.rule
	d.grid.a *= 0.55
	d.accent = ui.color("accent")
	d.line = ui.hue(.Blue)
	d.sc, d.em = ui.scale(), ui.font_size()
	g.custom, g.custom_user = easing_draw, d
}

@(private)
easing_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Easing_Draw)(user)
	r := b.rect
	if !plot_usable(r) { return }
	hair := max(1, math.round(d.sc))
	draw.rect(dc, r, d.ground)
	draw.rect(dc, r, d.rule, 0, hair)
	draw.push_clip(dc, r)
	defer draw.pop_clip(dc)
	o := easing_screen(r, {0, 0})
	one := easing_screen(r, {1, 1})
	// the unit square, its diagonal (linear)
	draw.rect(dc, {{o.x, one.y}, {one.x + hair, o.y + hair}}, d.grid, 0, hair)
	draw.line(dc, o, one, hair, d.grid)
	// the curve, a point every CURVE_SAMPLE_PX of its width
	n := int((one.x - o.x) / (CURVE_SAMPLE_PX * d.sc)) + 2
	points := make([]draw.Vec2, n, context.temp_allocator)
	for i in 0 ..< n {
		x := f32(i) / f32(n - 1)
		u := ui.bezier_param(d.curve.x1, d.curve.x2, x)
		w := 1 - u
		y := 3 * w * w * u * d.curve.y1 + 3 * w * u * u * d.curve.y2 + u * u * u
		points[i] = easing_screen(r, {x, y})
	}
	draw.polyline(dc, points, math.round(1.5 * d.sc), d.line)
	// the handles
	kr := math.round(d.em * CURVE_KEY_EM)
	for i in 0 ..< 2 {
		from := i == 0 ? o : one
		end := easing_screen(r, i == 0 ? {d.curve.x1, d.curve.y1} : {d.curve.x2, d.curve.y2})
		draw.line(dc, from, end, hair, d.label)
		draw.rect(dc, {end - kr - hair, end + kr + hair}, d.ink, kr + hair)
		draw.rect(dc, {end - kr, end + kr}, d.accent, kr)
	}
	// the preview: a dot along the curve, and its place on the right edge
	t := clamp(d.t * 1.25, 0, 1)   // (a rest at its end before it starts again)
	at := easing_screen(r, {t, ui.cubic_bezier_at(d.curve, t)})
	dot := math.round(kr * 0.8)
	draw.rect(dc, {at - dot, at + dot}, d.accent, dot)
	edge := math.round(r.max.x - kr * 2)
	draw.rect(dc, {{edge - dot, at.y - dot}, {edge + dot, at.y + dot}}, d.accent, dot)
}
