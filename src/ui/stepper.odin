package ui

// The stepper: the stages of a long work as nodes joined by connectors, each pending, under way, done, failed or skipped
// (src/md/features/stepper.md). The program gives the states at each build; the stepper animates the changes.
//
//   steps := []ui.Stepper_Step{{label = "Unpack", state = .Done}, {label = "Install", state = .Active}, {label = "Check"}}
//   ui.stepper("###install_steps", steps)

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import "../font"
import "../i18n"

Stepper_State :: enum u8 {
	Pending,   // not started: a hollow ring (its number with `numbers`)
	Active,    // under way: the spinner's arc turns on the ring
	Done,      // a disc of the success hue, its check drawn in
	Failed,    // a disc of the danger hue, its cross drawn in
	Skipped,   // not needed: a ring and a dash, weak
}

// One step. `color` wins over `tone`, which wins over the colour of its state.
Stepper_Step :: struct {
	label:  string,           // under (or beside) its node ("" none)
	detail: string,           // a second line, smaller and weak ("" none)
	state:  Stepper_State,
	tone:   Maybe(Intent),    // its words in an intent's hue, readable on the page
	color:  Maybe(Color),     // its words in this colour
	tip:    string,           // a tooltip on its node ("" none)
}

// Where the steps go, from the first to the last.
Stepper_Direction :: enum u8 { Right, Down, Left, Up }

// Where the words go. Below and After are the same side (after the nodes across the stepper), Above and Before the
// other; Auto: Below for a horizontal stepper, After for a vertical one.
Stepper_Labels :: enum u8 { Auto, Below, Above, After, Before }

// The colours of the nodes (nil: the palette's: the accent, the success and danger hues).
Stepper_Colors :: struct {
	active, done, failed: Maybe(Color),
}

Stepper_Options :: struct {
	direction: Stepper_Direction,
	labels:    Stepper_Labels,
	compact:   bool,             // the nodes alone: each step's words go to its node's tooltip
	numbers:   bool,             // a pending node shows its number
	node:      f32,              // a node's size, in pixels (0: STEPPER_NODE_EM of the font size)
	thickness: f32,              // a connector's, in pixels (0: from the node's size)
	colors:    Stepper_Colors,
	name:      string,           // what a screen reader calls it ("" none: its value says the step)
}

// What a node draws (stepper_look).
Stepper_Mark :: enum u8 { None, Number, Check, Cross, Dash }

Stepper_Look :: struct {
	ring:  bool,           // a hollow ring
	arc:   bool,           // the spinner's arc, turning on the ring
	disc:  f32,            // the filled disc's size, a share of the node's (0: none; a little over 1 while it pops)
	mark:  Stepper_Mark,
	drawn: f32,            // how much of the mark's stroke is drawn, 0..1
	fill:  f32,            // how much of the connector after the node is filled, 0..1
}

Stepper_Result :: struct {
	box:     ^Box,
	looks:   []Stepper_Look,   // each step's, in the order of the steps (this frame's memory)
	hovered: int,              // the step whose node is under the pointer (-1: none)
}

// Where the steps are: `finished` done or skipped of `total`; `current` the first active step, else the first failed,
// else the first pending (-1: every step finished).
Stepper_Progress :: struct {
	finished, total, current: int,
	busy: bool,   // a step is active
}

STEPPER_NODE_EM :: 1.5
STEPPER_MARK_MS :: 520     // a mark's time: the disc pops, then its stroke is drawn
STEPPER_FILL_MS :: 420     // a connector's fill, along it

@(private = "file") STEPPER_POP_SHARE :: 0.5          // of the mark's time: the disc's pop
@(private = "file") STEPPER_STROKE_FROM :: 0.3        // of the mark's time: where the stroke starts
@(private = "file") STEPPER_OVERSHOOT :: 1.1          // the pop's ease out back: about 5 % over its size
@(private = "file") STEPPER_THICKNESS :: 0.085        // a connector's, of the node's size
@(private = "file") STEPPER_RING :: 0.09              // a ring's, of the node's size
@(private = "file") STEPPER_STROKE :: 0.11            // a mark's stroke, of the node's size
@(private = "file") STEPPER_GAP_EM :: 0.25            // between a node and its connector
@(private = "file") STEPPER_WORDS_GAP_EM :: 0.4       // between the nodes and their words
@(private = "file") STEPPER_RUN_EM :: 1.9             // between a vertical stepper's nodes, at least: its connector's room and its gaps
@(private = "file") STEPPER_DETAIL :: 0.86            // the detail's size, of the font's
@(private = "file") STEPPER_NUMBER :: 0.5             // a number's size, of the node's
@(private = "file") STEPPER_DONE_TINT :: 0.45         // done words: the text this far toward the success hue
@(private = "file") STEPPER_TRACK_ALPHA :: 0.3        // an active node's ring under its arc
@(private = "file") STEPPER_WEAK_RING_ALPHA :: 0.6
@(private = "file") STEPPER_ARC :: 0.3                // of a turn
@(private = "file") STEPPER_TURN_MS :: 900            // the spinner's
@(private = "file") STEPPER_MARK_SALT :: 0x57e9_0000
@(private = "file") STEPPER_FILL_SALT :: 0x57e9_f111
@(private = "file") STEPPER_TIP_SALT :: 0x57e9_7179

// The marks, in a node of radius 1 (y down).
@(private = "file") CHECK_PATH :: [2][2]Vec2{{{-0.42, 0.02}, {-0.13, 0.31}}, {{-0.13, 0.31}, {0.43, -0.27}}}
@(private = "file") CROSS_PATH :: [2][2]Vec2{{{-0.3, -0.3}, {0.3, 0.3}}, {{0.3, -0.3}, {-0.3, 0.3}}}
@(private = "file") DASH_PATH :: [1][2]Vec2{{{-0.36, 0}, {0.36, 0}}}

stepper_progress :: proc(steps: []Stepper_Step) -> (p: Stepper_Progress) {
	p.total = len(steps)
	p.current = -1
	failed, pending := -1, -1
	for st, i in steps {
		switch st.state {
		case .Done, .Skipped: p.finished += 1
		case .Active:  if !p.busy { p.busy, p.current = true, i }
		case .Failed:  if failed < 0 { failed = i }
		case .Pending: if pending < 0 { pending = i }
		}
	}
	if p.current < 0 { p.current = failed >= 0 ? failed : pending }
	return
}

// The share of the steps finished, 0..1 (0 when there is none).
stepper_fraction :: proc(p: Stepper_Progress) -> f32 {
	return p.total > 0 ? f32(p.finished) / f32(p.total) : 0
}

// What a screen reader says of it: "Step 2 of 4: Install, in progress", "Every step is done".
stepper_spoken :: proc(steps: []Stepper_Step, allocator := context.temp_allocator) -> string {
	p := stepper_progress(steps)
	if p.total == 0 { return "" }
	if p.current < 0 { return strings.clone(i18n.tr("Every step is done"), allocator) }
	st := steps[p.current]
	word: string
	#partial switch st.state {
	case .Active: word = i18n.tr("in progress")
	case .Failed: word = i18n.tr("failed")
	case:         word = i18n.tr("waiting")
	}
	head := fmt.tprintf(i18n.tr("Step %d of %d"), p.current + 1, p.total)
	if st.label == "" { return fmt.aprintf("%s, %s", head, word, allocator = allocator) }
	return fmt.aprintf("%s: %s, %s", head, st.label, word, allocator = allocator)
}

// What a node of `state` draws, its mark's clock at `mark_t` and its connector's at `fill_t` (0..1 each: 1 settled).
stepper_look :: proc(state: Stepper_State, mark_t, fill_t: f32, numbers := false) -> (l: Stepper_Look) {
	switch state {
	case .Pending:
		l.ring = true
		if numbers { l.mark, l.drawn = .Number, 1 }
	case .Active:
		l.ring, l.arc = true, true
	case .Done, .Failed:
		l.disc = stepper_pop(mark_t)
		l.mark = state == .Done ? .Check : .Cross
		l.drawn = stepper_stroke(mark_t)
	case .Skipped:
		l.ring, l.mark = true, .Dash
		l.drawn = stepper_stroke(mark_t)
	}
	if state == .Done {
		f := clamp(fill_t, 0, 1)
		l.fill = f * f * (3 - 2 * f)
	}
	return
}

// The disc's size at `t` of the mark's time: ease out back over the pop's share, then 1.
@(private = "file")
stepper_pop :: proc(t: f32) -> f32 {
	u := clamp(t / STEPPER_POP_SHARE, 0, 1)
	if u <= 0 { return 0 }   // (the formula's 0 there is a rounding's speck: a dot)
	if u >= 1 { return 1 }
	k: f32 = STEPPER_OVERSHOOT
	v := u - 1
	return 1 + (k + 1) * v * v * v + k * v * v
}

// The stroke drawn at `t` of the mark's time: ease out cubic from STEPPER_STROKE_FROM.
@(private = "file")
stepper_stroke :: proc(t: f32) -> f32 {
	u := clamp((t - STEPPER_STROKE_FROM) / (1 - STEPPER_STROKE_FROM), 0, 1)
	v := 1 - u
	return 1 - v * v * v
}

// The share of `ms` since `key` was first asked for, by the builds' dt (tween's clock: a session's advance steps it);
// `settled`: a key asked for the first time is at its end. Asks for frames until it is; with animations off, at once.
@(private = "file")
stepper_clock :: proc(key: Key, ms: f32, settled: bool) -> f32 {
	s := gs()
	a, found := s.anims[key]
	if !found {
		a.elapsed_s = settled ? ms / 1000 : 0   // (this frame is its start: the time since the last one is not part of it)
	} else if a.elapsed_s * 1000 < ms {
		a.elapsed_s += s.dt
	}
	if s.anim_rate == 0 { a.elapsed_s = max(a.elapsed_s, ms / 1000) }
	a.last_build = s.build_index
	s.anims[key] = a
	p := min(a.elapsed_s * 1000 / ms, 1)
	if p < 1 { s.anim_busy = true }
	return p
}

// A row (Right, Left) or a column (Down, Up) of `steps`, their words beside the nodes unless `o.compact`. Its width is
// `next`'s (else its parent's), its height its content's. A horizontal stepper gives each step an equal column, its node
// in the middle, its words wrapped in it; a vertical one gives each a row, its label cut with its whole text in a
// tooltip, its detail wrapped. A screen reader hears one progress indicator: the step under way in words, the share
// finished as its value.
stepper :: proc(id: string, steps: []Stepper_Step, o := Stepper_Options{}) -> (r: Stepper_Result) {
	s := gs()
	em := font_size()
	n := len(steps)
	r.hovered = -1
	horizontal := o.direction == .Right || o.direction == .Left
	reversed := o.direction == .Left || o.direction == .Up
	node := o.node > 0 ? o.node : math.round(em * STEPPER_NODE_EM)
	thick := o.thickness > 0 ? o.thickness : max(math.round(node * STEPPER_THICKNESS), math.round(1.5 * s.scale))
	side := o.labels
	if side == .Auto { side = horizontal ? .Below : .After }
	words_first := side == .Above || side == .Before
	words := false
	if !o.compact {
		for st in steps { if st.label != "" || st.detail != "" { words = true; break } }
	}

	next_default({width = fill(), height = children_sum()})
	set_next_axis(.Y)
	r.box = build_box({}, id)
	r.looks = make([]Stepper_Look, n, frame_allocator())
	nodes := make([]^Box, n, frame_allocator())
	pal := stepper_palette(o.colors)

	if parent(r.box) {
		if horizontal {
			cell := pct(1 / f32(max(n, 1)))
			if words && words_first {
				stepper_words_row(steps, reversed, cell, true, pal)
				spacer(px(em * STEPPER_WORDS_GAP_EM))
			}
			next({width = pct(1), height = px(node)})
			if row(.Center, {}, "###stepper_nodes") {
				for k in 0 ..< n {
					i := reversed ? n - 1 - k : k
					next({width = cell, height = pct(1)})
					if column(.Center, {}, fmt.tprintf("###stepper_cell%d", i)) {
						nodes[i], r.looks[i] = stepper_node(steps[i], i, node, thick, o, pal, &r.hovered)
					}
				}
			}
			if words && !words_first {
				spacer(px(em * STEPPER_WORDS_GAP_EM))
				stepper_words_row(steps, reversed, cell, false, pal)
			}
		} else {
			for k in 0 ..< n {
				i := reversed ? n - 1 - k : k
				next({width = pct(1), height = children_sum()})
				if row(.Start, {}, fmt.tprintf("###stepper_step%d", i)) {
					if words && words_first {
						stepper_words_beside(steps[i], node, .Right, pal)
						spacer(px(em * STEPPER_WORDS_GAP_EM * 1.5))
					}
					next({width = px(node), height = children_sum()})
					if column(.Center, {}, "###stepper_rail") {
						nodes[i], r.looks[i] = stepper_node(steps[i], i, node, thick, o, pal, &r.hovered)
						if k < n - 1 { spacer(px(em * STEPPER_RUN_EM)) }
					}
					if words && !words_first {
						spacer(px(em * STEPPER_WORDS_GAP_EM * 1.5))
						stepper_words_beside(steps[i], node, .Left, pal)
					}
				}
			}
		}
	}

	d := frame_new(Stepper_Draw)
	d.nodes, d.looks = nodes, r.looks
	d.thick, d.gap = thick, math.round(em * STEPPER_GAP_EM)
	d.track, d.fill = color("border"), pal.done
	r.box.custom, r.box.custom_user = stepper_draw, d

	p := stepper_progress(steps)
	a11y_default(r.box, {role = .Progress_Indicator, name = o.name, value = stepper_spoken(steps, frame_allocator()),
		numeric = f64(stepper_fraction(p) * 100), min = 0, max = 100, read_only = true, busy = p.busy, no_children = true})
	return
}

// The colours of this build: the options', else the palette's.
@(private = "file")
Stepper_Palette :: struct { text, weak, page, active, done, failed: Color }

@(private = "file")
stepper_palette :: proc(c: Stepper_Colors) -> (p: Stepper_Palette) {
	p.text, p.weak, p.page = color("text"), color("weak text"), color("background")
	p.page.a = 1
	p.active = c.active.? or_else color("accent")
	// (a hue is a face here, as a dot's: opaque whatever the palette's alpha)
	if v, ok := c.done.?; ok { p.done = v } else { p.done = hue_color(.Green); p.done.a = 1 }
	if v, ok := c.failed.?; ok { p.failed = v } else { p.failed = hue_color(.Red); p.failed.a = 1 }
	return
}

// The colour of a step's words: its own, its tone's, else its state's.
@(private = "file")
stepper_words_color :: proc(st: Stepper_Step, pal: Stepper_Palette) -> Color {
	if c, ok := st.color.?; ok { return c }
	if t, ok := st.tone.?; ok {
		if t == .Neutral { return pal.text }
		return shade_on(hue_color(intent_hue(t)), pal.page, 4.5)
	}
	switch st.state {
	case .Pending, .Skipped: return pal.weak
	case .Active:            return pal.text
	case .Done:              return draw.mix(pal.text, shade_on(pal.done, pal.page, 4.5), STEPPER_DONE_TINT)
	case .Failed:            return shade_on(pal.failed, pal.page, 4.5)
	}
	return pal.text
}

// The words of a horizontal stepper: one column per step, as wide as the node's, the words wrapped and centred in it.
// Above the nodes (`first`), the columns meet the nodes at their bottom.
@(private = "file")
stepper_words_row :: proc(steps: []Stepper_Step, reversed: bool, cell: Size, first: bool, pal: Stepper_Palette) {
	em := font_size()
	n := len(steps)
	next({width = pct(1), height = children_sum()})
	if row(first ? .End : .Start, {}, "###stepper_words") {
		for k in 0 ..< n {
			i := reversed ? n - 1 - k : k
			st := steps[i]
			next({width = cell, height = children_sum()})
			if column(.Center, {.Clip}, fmt.tprintf("###stepper_words%d", i)) {
				if st.label != "" {
					next({width = pct(1), text_align = .Center, text_pad = math.round(em * 0.3), fg = stepper_words_color(st, pal)})
					paragraph(fmt.tprintf("%s###label", text_shown(st.label)), selectable = false)
				}
				if st.detail != "" {
					next({width = pct(1), text_align = .Center, text_pad = math.round(em * 0.3), font_size = math.round(em * STEPPER_DETAIL), fg = pal.weak})
					paragraph(fmt.tprintf("%s###detail", text_shown(st.detail)), selectable = false)
				}
			}
		}
	}
}

// The words of a vertical stepper's step, beside its node: the label on one line level with the node (cut, its whole
// text in a tooltip), the detail wrapped under it.
@(private = "file")
stepper_words_beside :: proc(st: Stepper_Step, node: f32, align: Text_Align, pal: Stepper_Palette) {
	em := font_size()
	next({width = fill(), height = children_sum()})
	if column(align == .Right ? .End : .Start, {.Clip}, "###stepper_words") {
		next({width = pct(1), height = px(node), text_align = align, text_pad = 0, fg = stepper_words_color(st, pal)})
		label_tip(fmt.tprintf("%s###label", text_shown(st.label)))
		if st.detail != "" {
			next({width = pct(1), text_align = align, text_pad = 0, font_size = math.round(em * STEPPER_DETAIL), fg = pal.weak})
			paragraph(fmt.tprintf("%s###detail", text_shown(st.detail)), selectable = false)
		}
	}
}

// A node: its box, its clocks, its tooltip.
@(private = "file")
stepper_node :: proc(st: Stepper_Step, i: int, node, thick: f32, o: Stepper_Options, pal: Stepper_Palette, hovered: ^int) -> (b: ^Box, l: Stepper_Look) {
	s := gs()
	next({width = px(node), height = px(node)})
	b = build_box({}, "###stepper_node")
	fresh := b.first_build == s.build_index
	mark_t: f32 = 1
	if st.state == .Done || st.state == .Failed || st.state == .Skipped {
		mark_t = stepper_clock(key_from_u64(b.key, STEPPER_MARK_SALT + u64(st.state)), STEPPER_MARK_MS, fresh)
	}
	fill_t: f32 = 0
	if st.state == .Done { fill_t = stepper_clock(key_from_u64(b.key, STEPPER_FILL_SALT), STEPPER_FILL_MS, fresh) }
	l = stepper_look(st.state, mark_t, fill_t, o.numbers)

	d := frame_new(Stepper_Node_Draw)
	d.look = l
	d.ring_size = max(math.round(node * STEPPER_RING), math.round(1.5 * s.scale))
	d.stroke = max(node * STEPPER_STROKE, 1.5 * s.scale)
	switch st.state {
	case .Pending:
		d.ring = pal.weak
		d.ring.a *= STEPPER_WEAK_RING_ALPHA
		d.ink = pal.weak
	case .Active:
		d.ring = pal.active
		d.ring.a *= STEPPER_TRACK_ALPHA
		d.arc = pal.active
		d.phase = s.anim_rate != 0 ? f32(math.mod(s.time_ms, STEPPER_TURN_MS) / STEPPER_TURN_MS) : 0
		if s.anim_rate != 0 { s.anim_busy = true }
	case .Done:
		d.disc = pal.done
		d.ink = ink_on(pal.done)
	case .Failed:
		d.disc = pal.failed
		d.ink = ink_on(pal.failed)
	case .Skipped:
		d.ring = pal.weak
		d.ring.a *= STEPPER_WEAK_RING_ALPHA
		d.ink = pal.weak
	}
	if l.mark == .Number {
		d.number = fmt.aprintf("%d", i + 1, allocator = frame_allocator())
		d.font, d.font_size = top_style().font, math.round(node * STEPPER_NUMBER)
	}
	b.custom, b.custom_user = stepper_node_draw, d

	under := pointer_on(b)
	if under { hovered^ = i }
	tip := st.tip
	if o.compact {
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		for t in ([3]string{st.label, st.detail, st.tip}) { if t != "" { append(&parts, t) } }
		tip = strings.join(parts[:], "\n", context.temp_allocator)
	}
	stepper_tip(b, under, tip)
	return
}

// A tooltip once the pointer rests on `b`, on a timer of its own: a node takes no press (in a list's row, a press on
// it is the row's), so hovered_for never sees it.
@(private = "file")
stepper_tip :: proc(b: ^Box, under: bool, text: string) {
	s := gs()
	key := key_from_u64(b.key, STEPPER_TIP_SALT)
	if !under || text == "" {
		if key in s.timers { delete_key(&s.timers, key) }
		return
	}
	if _, waiting := s.timers[key]; !waiting { timer_set(key, f64(s.feel.tooltip_delay_ms)) }
	if timer_due(key) {
		if tooltip() { tooltip_text(text) }
	} else if t, ok := s.timers[key]; ok {
		wake_within(s, max(1, int(t.next_ms - s.time_ms) + WAKE_MARGIN_MS))
	}
}

@(private = "file")
Stepper_Draw :: struct {
	nodes:       []^Box,
	looks:       []Stepper_Look,
	thick, gap:  f32,
	track, fill: Color,
}

// The connectors, from the edge of each node to the edge of the next whatever the direction; the nodes draw over.
@(private = "file")
stepper_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Stepper_Draw)(user)
	for i in 0 ..< len(d.nodes) - 1 {
		a, z := d.nodes[i], d.nodes[i + 1]
		if a == nil || z == nil { continue }
		ca, cz := draw.rect_center(a.rect), draw.rect_center(z.rect)
		v := cz - ca
		length := math.sqrt(v.x * v.x + v.y * v.y)
		if length <= 0 { continue }
		dir := v / length
		ra := min(a.rect.max.x - a.rect.min.x, a.rect.max.y - a.rect.min.y) * 0.5
		rz := min(z.rect.max.x - z.rect.min.x, z.rect.max.y - z.rect.min.y) * 0.5
		// (a round end reaches half the thickness past its point)
		from := ca + dir * (ra + d.gap + d.thick * 0.5)
		to := cz - dir * (rz + d.gap + d.thick * 0.5)
		if (to.x - from.x) * dir.x + (to.y - from.y) * dir.y <= 0 { continue }
		f := d.looks[i].fill
		if f < 1 { draw.line(dc, from, to, d.thick, d.track) }
		if f > 0 { draw.line(dc, from, from + (to - from) * f, d.thick, d.fill) }
	}
}

@(private = "file")
Stepper_Node_Draw :: struct {
	look:            Stepper_Look,
	ring, arc, disc, ink: Color,
	ring_size, stroke, phase: f32,
	number:          string,
	font:            font.Font_Id,
	font_size:       f32,
}

@(private = "file")
stepper_node_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	s := gs()
	d := (^Stepper_Node_Draw)(user)
	l := d.look
	r := b.rect
	size := min(r.max.x - r.min.x, r.max.y - r.min.y)
	if size <= 0 { return }
	c := draw.rect_center(r)
	R := size * 0.5
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	if l.ring { draw.rect(dc, {c - R, c + R}, d.ring, R, d.ring_size) }
	if l.arc { arc_dots(dc, c, R - d.ring_size * 0.5, d.ring_size, d.phase - 0.25, STEPPER_ARC, d.arc) }
	if l.disc > 0 {
		rr := R * l.disc
		disc := Rect{c - rr, c + rr}
		// (glass paints a face as two halves: no disc)
		if s.theme != nil && s.theme.relief.face == .Gloss { draw.rect(dc, disc, d.disc, rr) } else { paint_rect_corners(dc, disc, d.disc, {rr, rr, rr, rr}, rim = false) }
	}
	switch l.mark {
	case .None:
	case .Number:
		if d.number != "" && d.font != 0 {
			m := font.metrics(s.fonts, d.font, d.font_size)
			w := font.text_width(s.fonts, d.font, d.font_size, d.number)
			draw.text(dc, d.font, d.font_size, {math.round(c.x - w * 0.5), math.round(c.y + (m.ascent - m.descent) * 0.5)}, d.ink, d.number)
		}
	case .Check:
		path := CHECK_PATH
		stepper_stroke_path(dc, path[:], l.drawn, c, R, d.stroke, d.ink)
	case .Cross:
		path := CROSS_PATH
		stepper_stroke_path(dc, path[:], l.drawn, c, R, d.stroke, d.ink)
	case .Dash:
		path := DASH_PATH
		stepper_stroke_path(dc, path[:], l.drawn, c, R, d.stroke, d.ink)
	}
}

// The first `drawn` of the length of `path` (segments in a node of radius 1), drawn in a node of radius `R` at `c`.
@(private = "file")
stepper_stroke_path :: proc(dc: ^draw.Context, path: [][2]Vec2, drawn: f32, c: Vec2, R, width: f32, color: Color) {
	if drawn <= 0 { return }
	total: f32
	for seg in path { v := seg[1] - seg[0]; total += math.sqrt(v.x * v.x + v.y * v.y) }
	left := total * min(drawn, 1)
	for seg in path {
		if left <= 0 { break }
		v := seg[1] - seg[0]
		length := math.sqrt(v.x * v.x + v.y * v.y)
		t := min(left / length, 1)
		draw.line(dc, c + seg[0] * R, c + (seg[0] + v * t) * R, width, color)
		left -= length
	}
}
