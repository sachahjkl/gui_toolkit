package ui

// A value of a few parts in one field, each typed or stepped on its own, with the parts' drums in a popover
// (src/md/features/wheel-picker.md): ui.duration_field ("1 h 30 min"), ui.parts_field for any parts (a time of day
// "07:30", a date).
//
//	ui.duration_field("###lock", &app.lock_seconds, least = 60)
//
//	parts := [2]ui.Field_Part{{hi = 23, format = "%02d", wrap = true}, {hi = 59, format = "%02d", before = ":", wrap = true}}
//	ui.parts_field("###alarm", parts[:], app.alarm[:])

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../ascii"

// One part of a field: an integer from `lo` to `hi` by `step` (0: 1) in `format` ("": "%d"), or one of `labels`
// (its index); `unit` after it ("h"), `before` it (":"). `wrap`: past `hi` comes `lo` (minutes), in the field and on
// its drum.
Field_Part :: struct {
	lo, hi, step: int,
	format:       string,
	labels:       []string,
	unit:         string,
	before:       string,
	wrap:         bool,
}

Parts_Field_Options :: struct {
	disabled: bool,
	// Whether its drums are shown, the program's (it opens them from elsewhere, or keeps them open in a picture); nil:
	// the field's own.
	open:     ^bool,
}

// What a parts field keeps between builds (State.parts_fields).
@(private)
Parts_Memory :: struct {
	active:   int,      // the part the keys change
	typed:    [8]u8,    // what was typed into it, since it became the active part or the last key that was no digit
	typed_n:  int,
	typed_ms: f64,
	open:     bool,     // its drums are shown
	seen:     u64,
}

// Keys typed this close (ms) add to the active part's text; later, they start it again.
@(private = "file") PARTS_TYPE_MS :: 1200
// The room around the parts and between a value and its unit, in ems.
@(private = "file") PARTS_LEAD_EM :: 0.6
@(private = "file") PARTS_UNIT_GAP_EM :: 0.25
@(private = "file") PARTS_ARROW_EM :: 0.85

// A field of `parts`, `values` one per part. A click opens the parts' drums below it (ui.wheels), on the part clicked;
// a click outside, Escape or Enter closes them. With the keyboard: Left / Right choose a part, Up / Down step it
// (Page Up / Page Down ten steps, Home / End its ends), digits typed replace it and go on to the next part once no more
// digit fits, a label's first letters choose it; Alt+Down or F4 open the drums. The wheel over a part steps it once the
// field has the keyboard. True when a value changed this frame.
parts_field :: proc(id: string, parts: []Field_Part, values: []int, o := Parts_Field_Options{}) -> (changed: bool) {
	s := gs()
	em := font_size()
	st := top_style()
	n := min(len(parts), len(values))
	if n == 0 { return false }
	widths := make([]f32, n, frame_allocator())
	lead := math.round(em * PARTS_LEAD_EM)
	unit_gap := math.round(em * PARTS_UNIT_GAP_EM)
	total := 2 * lead + em * (PARTS_ARROW_EM + 0.4)
	for p, i in parts[:n] {
		widths[i] = part_widest(p, st)
		total += widths[i]
		if p.unit != "" { total += unit_gap + text_width(st.font, st.font_size, p.unit) }
		if p.before != "" { total += text_width(st.font, st.font_size, p.before) }
		if i > 0 && p.before == "" { total += unit_gap * 2 }
	}
	if !s.has_next || s.next_mod.width == nil { next_default({width = px(math.ceil(total))}) }
	next_default({radius = em * shape_of(.Control)})

	push_tags("input")
	flags: Box_Flags = {.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Focus_Ring, .Sunken, .Draw_Hot_Effects}
	if o.disabled { flags += {.Disabled} }
	set_next_axis(.X, .Center)
	b := build_box(flags, id)
	pop_tags()
	b.cursor = .Hand
	sig := signal(b)
	m, kept := &s.parts_fields[b.key]
	if !kept {
		s.parts_fields[b.key] = {}
		m = &s.parts_fields[b.key]
	}
	m.seen = s.build_index
	m.active = clamp(m.active, 0, n - 1)
	if o.open != nil { m.open = o.open^ }
	defer if o.open != nil { o.open^ = m.open }
	now := s.time_ms
	popover_id := fmt.tprintf("###parts_drums_%x", u64(b.key))

	// the parts, each a box: the click finds its part by them, the active one is marked while the field has the keyboard
	part_boxes := make([]^Box, n, frame_allocator())
	if parent(b) {
		spacer(px(lead))
		for p, i in parts[:n] {
			if i > 0 && p.before == "" { spacer(px(unit_gap * 2)) }
			if p.before != "" {
				if tags("weak") { label_part(p.before, fmt.tprintf("###before%d", i), st) }
			}
			on := sig.focused && i == m.active
			next({width = px(widths[i]), height = pct(0.72), text_align = .Center, radius = em * 0.25, text_pad = 0})
			if on { next({bg = color("selection"), fg = color("selection text")}) }
			part_boxes[i] = build_box(on ? {.Draw_Text, .Draw_Background} : {.Draw_Text}, fmt.tprintf("%s###part%d", part_text(p, values[i]), i))
			if p.unit != "" {
				spacer(px(unit_gap))
				if tags("weak") { label_part(p.unit, fmt.tprintf("###unit%d", i), st) }
			}
		}
		spacer(fill())
		if tags("weak") { icon(m.open ? ICON_UP : ICON_DOWN, em * PARTS_ARROW_EM, nil, widget_icons()) }
		spacer(px(lead * 0.7))
	}

	if !o.disabled {
		// a press chooses the part under it (by last frame's boxes) and opens the drums
		if sig.pointer_pressed {
			for pb, i in part_boxes {
				if pb != nil && s.mouse.x >= pb.rect.min.x - unit_gap && (i == n - 1 || s.mouse.x < part_boxes[i + 1].rect.min.x - unit_gap) { m.active = i }
			}
			if s.mouse.x < part_boxes[0].rect.min.x { m.active = 0 }
			m.typed_n = 0
			m.open = true
		}
		if sig.focused {
			if key_press(.Left) && m.active > 0 { m.active -= 1; m.typed_n = 0 }
			if key_press(.Right) && m.active < n - 1 { m.active += 1; m.typed_n = 0 }
			p := parts[m.active]
			k := max(p.step, 1)
			count := part_count(p)
			at := part_row(p, values[m.active])
			to := at
			if key_press(.Up) { to += 1 }
			if key_press(.Down) { to -= 1 }
			if key_press(.Page_Up) { to += 10 }
			if key_press(.Page_Down) { to -= 10 }
			if key_press(.Home) { to = 0 }
			if key_press(.End) { to = count - 1 }
			if wn := wheel_steps(b, true); wn != 0 {
				// (the wheel steps the part under the pointer)
				for pb, i in part_boxes {
					if pb != nil && s.mouse.x >= pb.rect.min.x - unit_gap * 2 && s.mouse.x <= pb.rect.max.x + unit_gap * 2 && i != m.active {
						m.active, p, count = i, parts[i], part_count(parts[i])
						at = part_row(p, values[i])
						to = at
						k = max(p.step, 1)
					}
				}
				to += int(wn)
			}
			if to != at {
				m.typed_n = 0
				to = p.wrap ? ((to % count) + count) % count : clamp(to, 0, count - 1)
				if to != at {
					values[m.active] = p.labels != nil ? to : p.lo + to * k
					changed = true
				}
			}
			if v, next_part, ok := parts_typed(m, p, now); ok {
				if v != values[m.active] { values[m.active] = v; changed = true }
				if next_part && m.active < n - 1 { m.active += 1; m.typed_n = 0 }
			}
			if key_press(.Backspace) { m.typed_n = 0 }
			if !m.open && (key_press(.Down, {.Alt}) || key_press(.F4)) { m.open = true }
			else if m.open && (key_press(.Up, {.Alt}) || key_press(.F4) || key_press(.Return)) { m.open = false }
		}
		if m.open && (sig.focused || popover_focused(popover_id)) && key_press(.Escape) { m.open = false }
		if m.open && pressed_outside(b, popover_id) { m.open = false }
	} else {
		m.open = false
	}

	// the drums, each part's, under one band
	if m.open {
		if popover(popover_id, b.rect, b.rect.max.x - b.rect.min.x, .Below, align_right = false) {
			spacer(px(em * 0.5))
			next({width = children_sum(), height = children_sum(), axis = .X})
			if row(id = "###drums_row") {
				spacer(px(em * 0.5))
				if wheels("###drums") {
					for p, i in parts[:n] {
						did: bool
						wid := fmt.tprintf("###drum%d", i)
						if p.labels != nil {
							did = wheel(wid, p.labels, &values[i], {wrap = p.wrap, unit = p.unit})
						} else {
							did = wheel_number(wid, &values[i], p.lo, p.hi, max(p.step, 1), p.format != "" ? p.format : "%d", {wrap = p.wrap, unit = p.unit})
						}
						if part_boxes[i] == nil { continue }
						if did {
							changed = true
							m.active = i
							// (the part was built before its drum came to rest, with the value before: one frame of
							// it showed the old value between the drum's rows and the new one)
							part_boxes[i].text = part_text(p, values[i])
						} else if wm, ok := s.wheels[key_from_string(parent_box().key, wid)]; ok && wheel_index(wm.target, part_count(p), p.wrap) != wm.rest {
							// (turned by its own input, its part shows the row at its band: the value comes at rest. Not
							// while it turns to a value the keys set: the field has that value already)
							part_boxes[i].text = part_text(p, p.labels != nil ? wm.shown : p.lo + wm.shown * max(p.step, 1))
						}
					}
				}
				spacer(px(em * 0.5))
			}
			spacer(px(em * 0.5))
		}
	}

	a11y_default(b, {role = .Combo_Box, value = parts_spoken(parts[:n], values[:n]), expanded = m.open, popup = .Dialog, read_only = false})
	return
}

// The units of a duration field: a part each.
Duration_Unit :: enum u8 { Hours, Minutes, Seconds }
Duration_Units :: bit_set[Duration_Unit; u8]

// A duration in `seconds` as hours, minutes and seconds (`units`): "1 h 30 min". Minutes and seconds wrap; hours go
// from 0 to `most`'s (0: 23). The sum stays between `least` and `most` (0: no bound): with `least` one minute, 0 h 00 min
// becomes 0 h 01 min. `minute_step`: the minutes' rows (5: 00, 05...). As ui.parts_field otherwise.
duration_field :: proc(id: string, seconds: ^int, units := Duration_Units{.Hours, .Minutes}, least := 0, most := 0, minute_step := 1, o := Parts_Field_Options{}) -> (changed: bool) {
	parts, values, n := duration_parts(seconds^, units, most, minute_step)
	if !parts_field(id, parts[:n], values[:n], o) { return false }
	v := duration_of(values[:n], units)
	if least > 0 && v < least { v = least }
	if most > 0 && v > most { v = most }
	if v == seconds^ { return false }
	seconds^ = v
	return true
}

// The parts of a duration of `seconds` in `units`, and their values.
@(private)
duration_parts :: proc(seconds: int, units: Duration_Units, most, minute_step: int) -> (parts: [3]Field_Part, values: [3]int, n: int) {
	total := max(seconds, 0)
	h, m, sec := total / 3600, (total % 3600) / 60, total % 60
	if .Hours not_in units { m += h * 60; h = 0 }
	if .Minutes not_in units { sec += m * 60; m = 0 }
	ms := max(minute_step, 1)
	if .Hours in units {
		parts[n], values[n] = {hi = most > 0 ? most / 3600 : 23, unit = "h"}, h
		n += 1
	}
	if .Minutes in units {
		// (no hours: the minutes are the whole of it, not a clock's)
		top := .Hours in units ? 59 : max(most / 60, 59)
		parts[n], values[n] = {hi = top - top % ms, step = ms, format = "%02d", unit = "min", wrap = .Hours in units}, m - m % ms
		n += 1
	}
	if .Seconds in units {
		parts[n], values[n] = {hi = 59, format = "%02d", unit = "s", wrap = .Minutes in units}, sec
		n += 1
	}
	return
}

@(private)
duration_of :: proc(values: []int, units: Duration_Units) -> int {
	v, i := 0, 0
	if .Hours in units { v += values[i] * 3600; i += 1 }
	if .Minutes in units { v += values[i] * 60; i += 1 }
	if .Seconds in units { v += values[i] }
	return v
}

// The rows of a part, and the row of a value.
@(private = "file")
part_count :: proc(p: Field_Part) -> int {
	if p.labels != nil { return max(len(p.labels), 1) }
	return max((p.hi - p.lo) / max(p.step, 1) + 1, 1)
}

@(private = "file")
part_row :: proc(p: Field_Part, v: int) -> int {
	if p.labels != nil { return clamp(v, 0, len(p.labels) - 1) }
	return clamp((v - p.lo) / max(p.step, 1), 0, part_count(p) - 1)
}

@(private = "file")
part_text :: proc(p: Field_Part, v: int) -> string {
	if p.labels != nil { return p.labels[part_row(p, v)] }
	return fmt.aprintf(p.format != "" ? p.format : "%d", v, allocator = frame_allocator())
}

@(private = "file")
part_widest :: proc(p: Field_Part, st: ^Style) -> (w: f32) {
	if p.labels != nil {
		for l in p.labels { w = max(w, text_width(st.font, st.font_size, l)) }
	} else {
		f := p.format != "" ? p.format : "%d"
		for v in ([3]int{p.lo, p.hi, 88}) {
			if v == 88 && p.hi < 88 { continue }
			w = max(w, text_width(st.font, st.font_size, fmt.tprintf(f, v)))
		}
	}
	return math.ceil(w + font_size() * 0.3)
}

@(private = "file")
label_part :: proc(text, id: string, st: ^Style) {
	next({width = px(math.ceil(text_width(st.font, st.font_size, text))), height = pct(1), text_pad = 0})
	build_box({.Draw_Text}, fmt.tprintf("%s%s", text, id))
}

// What the keys typed this frame make of the active part: a number from its digits (the next part once no more digit
// fits), or the label its letters begin. ok: something was typed.
@(private = "file")
parts_typed :: proc(m: ^Parts_Memory, p: Field_Part, now: f64) -> (value: int, next_part, ok: bool) {
	s := gs()
	if len(s.typed) == 0 { return }
	if now - m.typed_ms > PARTS_TYPE_MS { m.typed_n = 0 }
	for c in s.typed {
		if c >= 0x80 || c <= ' ' { continue }
		if m.typed_n >= len(m.typed) { m.typed_n = 0 }
		m.typed[m.typed_n] = u8(c) | 0x20 if c >= 'A' && c <= 'Z' else u8(c)
		m.typed_n += 1
	}
	m.typed_ms = now
	if m.typed_n == 0 { return }
	text := string(m.typed[:m.typed_n])
	if p.labels != nil {
		for l, i in p.labels { if ascii.has_prefix_fold(l, text) { return i, false, true } }
		m.typed_n = 0
		return
	}
	digits, nok := strconv.parse_int(text, 10)
	if !nok {
		m.typed_n = 0
		return
	}
	k := max(p.step, 1)
	v := clamp(digits, p.lo, p.hi)
	v = p.lo + (v - p.lo) / k * k
	// (one more digit would pass the part's end, or as many digits as its end has: it is complete)
	full := digits * 10 > p.hi || m.typed_n >= len(fmt.tprintf("%d", p.hi))
	if full { m.typed_n = 0 }
	return v, full, true
}

// "1 h 30 min" for a screen reader.
@(private = "file")
parts_spoken :: proc(parts: []Field_Part, values: []int) -> string {
	b := strings.builder_make(frame_allocator())
	for p, i in parts {
		if i > 0 && p.before == "" { strings.write_byte(&b, ' ') }
		strings.write_string(&b, p.before)
		strings.write_string(&b, part_text(p, values[i]))
		if p.unit != "" { fmt.sbprintf(&b, " %s", p.unit) }
	}
	return strings.to_string(b)
}

// A press of this frame landed outside the field and its popover.
@(private = "file")
pressed_outside :: proc(field: ^Box, popover_id: string) -> bool {
	s := gs()
	hit: Key
	any_press := false
	for btn in s.pressed_any {
		if btn { any_press = true; break }
	}
	if !any_press { return false }
	for k in s.pressed_key { if k != 0 { hit = k; break } }
	hb := s.boxes[hit] if hit != 0 else nil
	if hb == nil { return true }
	if hb == field || is_descendant(hb, field) { return false }
	if p := s.boxes[key_from_string(s.root.key, popover_id)]; p != nil && (hb == p || is_descendant(hb, p)) { return false }
	return true
}

// The keyboard is in the popover (a drum has it).
@(private = "file")
popover_focused :: proc(popover_id: string) -> bool {
	s := gs()
	p := s.boxes[key_from_string(s.root.key, popover_id)]
	f := s.boxes[s.focus_key] if s.focus_key != 0 else nil
	return p != nil && f != nil && is_descendant(f, p)
}

// The fields this build did not build.
@(private)
parts_trim :: proc(s: ^State) {
	dead := make([dynamic]Key, context.temp_allocator)
	for k, m in s.parts_fields { if m.seen != s.build_index { append(&dead, k) } }
	for k in dead { delete_key(&s.parts_fields, k) }
}
