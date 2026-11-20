package ui

// The wheel picker: a column of values on a drum, the row under the band in the middle the value
// (src/md/features/wheel-picker.md). ui.wheel takes a short list of labels, ui.wheel_number a range of integers,
// ui.wheels puts drums side by side under one band. A field of parts shows them in its popover (parts_field.odin).
//
//	ui.wheel_number("###minutes", &app.minutes, 0, 59, format = "%02d", o = {wrap = true, unit = "min"})
//
//	if ui.wheels("###lock") {
//		ui.wheel_number("###h", &h, 0, 23, o = {unit = "h"})
//		ui.wheel_number("###m", &m, 0, 59, format = "%02d", o = {wrap = true, unit = "min"})
//	}

import "core:fmt"
import "core:math"
import "core:strings"
import "../ascii"
import "../draw"
import "../font"

// The height of a drum in rows, and of a row in ems.
WHEEL_ROWS :: 5
@(private = "file") WHEEL_ROW_EM :: 2.0
// The room on each side of the labels, and between the labels and the unit, in ems.
@(private = "file") WHEEL_PAD_EM :: 0.9
@(private = "file") WHEEL_UNIT_GAP_EM :: 0.35
// The band's inset from the drum's edges, in ems.
@(private = "file") WHEEL_BAND_INSET_EM :: 0.25
// The spring that carries the drum to its row after a notch, a key, a click or a slow release: stiff, a hint of a
// detent.
@(private = "file") WHEEL_SNAP_OMEGA :: 20.0
@(private = "file") WHEEL_SNAP_DAMPING :: 0.72
// A throw: it goes as far as its speed covers in this time (s), then glides there on a cubic ease-out that starts at
// the hand's speed and lasts what that takes, within these bounds (s). Slower than this (rows per s) is no throw.
WHEEL_THROW_S :: 0.3
@(private = "file") WHEEL_GLIDE_LEAST_S :: 0.25
@(private = "file") WHEEL_GLIDE_MOST_S :: 1.4
@(private = "file") WHEEL_THROW_SPEED :: 3.0
// The longest step of the spring's integration (s): stable whatever a late frame's dt.
@(private = "file") WHEEL_STEP_S :: 1.0 / 480
// Settled: this close to the row (rows) and this slow (rows per s).
@(private = "file") WHEEL_SETTLED_ROWS :: 2e-3
@(private = "file") WHEEL_SETTLED_SPEED :: 5e-2
// A drag's speed: the time constant of its average (s); a hand still this long before it lets go throws nothing (ms).
@(private = "file") WHEEL_SPEED_AVERAGE_S :: 0.045
@(private = "file") WHEEL_STILL_MS :: 70
// A press that moves less than this (px) is a click.
@(private = "file") WHEEL_CLICK_PX :: 4
// Past an end, a drag moves the drum by this share of the hand's motion.
@(private = "file") WHEEL_STRETCH :: 0.32
// The touchpad's fractions of a notch are rounded to a row once no more come for this long (ms).
@(private = "file") WHEEL_ROUND_MS :: 110
// The tick of a row crossing the band: how long the band's rim stays lit (ms), and how bright.
@(private = "file") WHEEL_TICK_MS :: 140
@(private = "file") WHEEL_TICK_ALPHA :: 0.55
// Type-ahead: keys typed this close (ms) add to the search, then it starts again.
@(private = "file") WHEEL_TYPE_MS :: 900
// The rows the Page keys move by.
@(private = "file") WHEEL_PAGE :: 5
// The machined band's face, toward the accent (as a segmented control's key).
@(private = "file") WHEEL_BAND_ACCENT :: 0.1
// The flat band's face, from the well toward the text, and its edge's alpha of the accent.
@(private = "file") WHEEL_BAND_TINT :: 0.09
@(private = "file") WHEEL_BAND_EDGE :: 0.45
// The drum's top and bottom fade into the well (its alpha at the edges, and where the fade ends, of the height): the
// rows turn away out of sight instead of being cut by the edge.
@(private = "file") WHEEL_SHADE_ALPHA :: 0.85
@(private = "file") WHEEL_SHADE_REACH :: 0.3

Wheel_Options :: struct {
	rows:               int,    // its height in rows (0: WHEEL_ROWS); in ui.wheels, the group's
	wrap:               bool,   // the last row is followed by the first (minutes: 59, 00, 01)
	unit:               string, // a word after the value, at the band ("min"); "": none
	// The wheel turns it only once it has the keyboard: a drum in a long page that scrolls, which the wheel scrolls past
	// (false: whenever the pointer is over it, the drum's main input).
	wheel_when_focused: bool,
	disabled:           bool,
}

// What a drum keeps between builds (State.wheels).
@(private)
Wheel_Memory :: struct {
	pos, speed:   f64,   // the row at the band (fractional while it turns), rows per second
	target:       f64,   // the row the spring heads to (a fraction while a touchpad's deltas add up)
	omega, zeta:  f64,   // the spring of the motion under way
	// a throw's glide: from where, how long it lasts and how far it is (s); 0 long: none (the spring moves it)
	glide_from:   f64,
	glide_s, glide_t: f64,
	rest:         int,   // the row the program was given (or gave)
	shown:        int,   // the row at the band at the last build: a new one is a tick
	tick_ms:      f64,
	wheel_ms:     f64,   // the last wheel delta
	grab_pos:     f64,
	grab_y:       f32,
	move_ms:      f64,   // the last move of a held drum
	held, dragged: bool,
	typed:        [16]u8,
	typed_n:      int,
	typed_ms:     f64,
	seen:         u64,
}

// The text of the rows: `labels`, or `lo + i * step` in `format`.
@(private = "file")
Wheel_Rows :: struct {
	labels:      []string,
	lo, step:    int,
	format:      string,
	count:       int,
}

@(private = "file")
wheel_label :: proc(r: Wheel_Rows, i: int) -> string {
	if r.labels != nil { return r.labels[i] }
	return fmt.aprintf(r.format, r.lo + i * r.step, allocator = frame_allocator())
}

// A row drawn: its distance from the band (rows) and its text.
@(private = "file")
Wheel_Row :: struct {
	d:    f32,
	text: string,
}

@(private = "file")
Wheel_Draw :: struct {
	rows:         []Wheel_Row,
	row_h:        f32,
	pad, label_w: f32,
	right:        bool,   // labels to the right of their column (numbers: their units line up)
	unit:         string,
	unit_x:       f32,    // from the box's left
	font:         font.Font_Id,
	size:         f32,
	weak, on_band: Color,
	band:         ^Wheel_Band,   // nil: the group draws it
}

// The well, the shade and the band: a drum's own, or a group's across its drums.
@(private = "file")
Wheel_Band :: struct {
	row_h:        f32,
	rows:         int,
	radius:       f32,
	inset:        f32,
	machined:     bool,
	well, face, accent, text: Color,
	focus:        f32,
	tick:         f32,
}

// A drum of `labels`: `index` is the row at the band. True when the drum came to rest on another row than `index`
// (then `index` is that row); a drum that turns gives no change until it rests. A new `index` from the program turns the
// drum to it. The wheel (a touchpad's fractions too), a drag and a throw, a click on a row, Up / Down, Page Up / Page
// Down, Home / End and a label's first letters typed move it; a screen reader sees a spin button.
wheel :: proc(id: string, labels: []string, index: ^int, o := Wheel_Options{}) -> (changed: bool) {
	if len(labels) == 0 { return false }
	st := top_style()
	widest: f32
	for l in labels { widest = max(widest, text_width(st.font, st.font_size, l)) }
	return wheel_of(id, {labels = labels, count = len(labels)}, widest, false, index, o)
}

// A drum of the integers `lo` to `hi` by `step`, each in `format` ("%02d": 00 to 59). `value` is one of them (another is
// taken to the nearest). As ui.wheel otherwise; only the rows drawn are formatted.
wheel_number :: proc(id: string, value: ^int, lo, hi: int, step := 1, format := "%d", o := Wheel_Options{}) -> (changed: bool) {
	k := max(step, 1)
	n := max((hi - lo) / k + 1, 1)
	st := top_style()
	widest: f32
	for v in ([2]int{lo, lo + (n - 1) * k}) { widest = max(widest, text_width(st.font, st.font_size, fmt.tprintf(format, v))) }
	// (a middle value can be wider than both ends: 8 than 1 and 9, in a face without tabular digits)
	widest = max(widest, text_width(st.font, st.font_size, fmt.tprintf(format, 88)) if hi >= 88 else 0)
	i := clamp(int(math.round(f64(value^ - lo) / f64(k))), 0, n - 1)
	r := Wheel_Rows{lo = lo, step = k, format = format, count = n}
	if wheel_of(id, r, widest, true, &i, o) {
		value^ = lo + i * k
		return true
	}
	return false
}

// `if ui.wheels(id) { ... }`: drums side by side under one band, read as one value (hours and minutes). The drums take
// the group's height (`rows`; 0: WHEEL_ROWS). One focus ring around them while one has the keyboard.
@(require_results, deferred_none = pop_parent)
wheels :: proc(id: string, rows := 0) -> bool {
	em := font_size()
	g := frame_new(Wheel_Band)
	wheel_band_of(g, rows > 0 ? rows : WHEEL_ROWS, em)
	set_next_axis(.X, .Center)
	next_default({width = children_sum(), height = px(f32(g.rows) * g.row_h)})
	// (the well shows the focus: a ring of its own drew a second edge around it)
	b := build_box({.Focus_Within}, id)
	g.radius = max(b.radius, rad(em * 0.4))
	b.custom, b.custom_user = wheels_draw, g
	push_parent(b)
	return true
}

@(private = "file")
wheel_of :: proc(id: string, r: Wheel_Rows, widest: f32, right: bool, index: ^int, o: Wheel_Options) -> (changed: bool) {
	s := gs()
	em := font_size()
	st := top_style()
	n := r.count
	group := wheel_group(parent_box())
	own: ^Wheel_Band
	if group == nil {
		own = frame_new(Wheel_Band)
		wheel_band_of(own, o.rows > 0 ? o.rows : WHEEL_ROWS, em)
	}
	band := group != nil ? group : own
	row_h := band.row_h
	pad := math.round(em * WHEEL_PAD_EM)
	label_w := math.ceil(widest)
	unit_w := o.unit != "" ? text_width(st.font, st.font_size, o.unit) : 0
	unit_gap := o.unit != "" ? math.round(em * WHEEL_UNIT_GAP_EM) : 0
	next_default({width = px(pad * 2 + label_w + unit_gap + math.ceil(unit_w)), height = px(f32(band.rows) * row_h)})
	flags: Box_Flags = {.Clickable, .Focusable}
	if o.disabled { flags += {.Disabled} }
	b := build_box(flags, id)
	sig := signal(b)

	want := clamp(index^, 0, n - 1)
	m, kept := &s.wheels[b.key]
	if !kept {
		s.wheels[b.key] = {pos = f64(want), target = f64(want), rest = want, shown = want, tick_ms = -WHEEL_TICK_MS, omega = WHEEL_SNAP_OMEGA, zeta = WHEEL_SNAP_DAMPING}
		m = &s.wheels[b.key]
	}
	m.seen = s.build_index
	now := s.time_ms
	h := f32(band.rows) * row_h
	R := h * 0.5
	step := f64(row_h / R)   // the angle between two rows

	// the program chose another row: the drum turns to it, nothing is given back
	if want != m.rest && !m.held {
		m.rest = want
		wheel_aim(m, wheel_nearest(m.target, want, n, o.wrap), WHEEL_SNAP_OMEGA, WHEEL_SNAP_DAMPING)
	}

	if !o.disabled {
		// a drag follows the hand; a release throws, or a press that did not move is a click on a row
		if sig.pointer_pressed && !m.held {
			m.held, m.dragged = true, false
			m.grab_pos, m.grab_y, m.speed, m.move_ms = m.pos, s.mouse.y, 0, now
		}
		if m.held && sig.dragging {
			dy := s.mouse.y - m.grab_y
			if abs(dy) > WHEEL_CLICK_PX * scale() { m.dragged = true }
			if m.dragged {
				p := m.grab_pos - f64(dy / row_h)
				if !o.wrap {
					if p < 0 { p *= WHEEL_STRETCH }
					if p > f64(n - 1) { p = f64(n - 1) + (p - f64(n - 1)) * WHEEL_STRETCH }
				}
				if p != m.pos {
					if s.dt > 0 {
						k := 1 - math.exp(-f64(s.dt) / WHEEL_SPEED_AVERAGE_S)
						m.speed += ((p - m.pos) / f64(s.dt) - m.speed) * k
					}
					m.pos, m.target, m.move_ms = p, p, now
				}
			}
		} else if m.held {
			m.held = false
			if m.dragged {
				if now - m.move_ms > WHEEL_STILL_MS { m.speed = 0 }
				to := wheel_bound(math.round(m.pos + m.speed * WHEEL_THROW_S), n, o.wrap)
				wheel_aim(m, to, WHEEL_SNAP_OMEGA, WHEEL_SNAP_DAMPING)
				// (a cubic ease-out starts at three times its mean speed: the time that makes it start at the hand's)
				dist := to - m.pos
				if abs(m.speed) >= WHEEL_THROW_SPEED && dist * m.speed > 0 {
					m.glide_from, m.glide_t = m.pos, 0
					m.glide_s = clamp(3 * dist / m.speed, WHEEL_GLIDE_LEAST_S, WHEEL_GLIDE_MOST_S)
				}
			} else {
				// (the row under the pointer, through the cylinder: its angle from the band)
				y := clamp((s.mouse.y - (b.rect.min.y + R)) / R, -0.999, 0.999)
				d := math.asin(f64(y)) / step
				wheel_aim(m, wheel_bound(math.round(m.target + d), n, o.wrap), WHEEL_SNAP_OMEGA, WHEEL_SNAP_DAMPING)
			}
		}

		// the wheel: a notch is a row; fractions add up and round once they stop
		if !o.wheel_when_focused || sig.focused {
			b.flags += {.Scroll_Self}   // (read by the next frame's hit test)
		} else {
			b.flags -= {.Scroll_Self}
		}
		if s.scroll_key == b.key && !m.held {
			if dl := f64(s.scroll_delta.y + s.scroll_delta.x); dl != 0 {
				wheel_aim(m, wheel_bound(m.target + dl, n, o.wrap, whole = false), WHEEL_SNAP_OMEGA, WHEEL_SNAP_DAMPING)
				m.wheel_ms = now
			}
		}
		if !m.held && m.target != math.round(m.target) && now - m.wheel_ms >= WHEEL_ROUND_MS {
			m.target = math.round(m.target)
		}

		if sig.focused && !m.held {
			at := math.round(m.target)
			to := at
			if key_press(.Up) { to -= 1 }
			if key_press(.Down) { to += 1 }
			if key_press(.Page_Up) { to -= WHEEL_PAGE }
			if key_press(.Page_Down) { to += WHEEL_PAGE }
			if key_press(.Home) { to = wheel_nearest(at, 0, n, o.wrap) }
			if key_press(.End) { to = wheel_nearest(at, n - 1, n, o.wrap) }
			if i, ok := wheel_typed(m, r, now); ok { to = wheel_nearest(at, i, n, o.wrap) }
			if to != at { wheel_aim(m, wheel_bound(to, n, o.wrap), WHEEL_SNAP_OMEGA, WHEEL_SNAP_DAMPING) }
		}
		if v, ok := a11y_numeric_request(b.key, f32(wheel_index(m.target, n, o.wrap)), 1); ok {
			wheel_aim(m, wheel_nearest(m.target, clamp(int(v), 0, n - 1), n, o.wrap), WHEEL_SNAP_OMEGA, WHEEL_SNAP_DAMPING)
		}
	}

	// the motion
	if !m.held {
		if s.anim_rate == 0 {
			m.pos, m.speed, m.glide_s = m.target, 0, 0
		} else if m.glide_s > 0 {
			m.glide_t += f64(s.dt)
			m.pos, m.speed = wheel_glide(m.glide_from, m.target, m.glide_t / m.glide_s, m.glide_s)
			if m.glide_t >= m.glide_s { m.glide_s = 0 }
		} else {
			m.pos, m.speed = wheel_spring(m.pos, m.speed, m.target, m.omega, m.zeta, f64(s.dt))
		}
	}
	moving := m.held || m.pos != m.target || m.target != math.round(m.target)
	if moving && !m.held { s.anim_busy = true }

	// at rest on another row: the program's value
	if !moving {
		i := wheel_index(m.target, n, o.wrap)
		if o.wrap { m.pos, m.target = f64(i), f64(i) }
		if i != m.rest {
			m.rest = i
			index^ = i
			changed = true
		}
	}

	// the tick: a row crossed the band
	at := wheel_index(math.round(m.pos), n, o.wrap)
	if at != m.shown {
		m.shown = at
		m.tick_ms = now
	}
	tick := s.anim_rate == 0 ? 0 : clamp(1 - f32(now - m.tick_ms) / WHEEL_TICK_MS, 0, 1)
	if tick > 0 { s.anim_busy = true }
	band.tick = max(band.tick, tick)
	if own != nil { own.radius = max(b.radius, rad(em * 0.4)) }

	// the rows drawn: those less than a quarter turn from the band
	d := frame_new(Wheel_Draw)
	d.row_h, d.pad, d.label_w, d.right, d.band = row_h, pad, label_w, right, own
	d.unit, d.unit_x = o.unit, pad + label_w + unit_gap
	d.font, d.size = st.font, st.font_size
	push_tags("weak")
	d.weak = color("text")
	pop_tags()
	d.on_band = color("text")
	reach := int(math.ceil(math.PI * 0.5 / step))
	rows := make([dynamic]Wheel_Row, 0, 2 * reach + 2, frame_allocator())
	first := int(math.floor(m.pos))
	for i in first - reach ..= first + reach + 1 {
		if !o.wrap && (i < 0 || i >= n) { continue }
		off := f64(i) - m.pos
		if abs(off * step) >= math.PI * 0.5 { continue }
		append(&rows, Wheel_Row{f32(off), wheel_label(r, wheel_index(f64(i), n, o.wrap))})
	}
	d.rows = rows[:]
	b.custom, b.custom_user = wheel_draw, d

	i := wheel_index(m.target, n, o.wrap)
	text := wheel_label(r, i)
	a11y_default(b, {role = .Spin_Button, numeric = f64(i), min = 0, max = f64(n - 1), step = 1, value = o.unit != "" ? fmt.tprintf("%s %s", text, o.unit) : text})
	return
}

// Starts a motion to row `to` (a whole row, or a fraction of a touchpad's) on a spring of `omega` (rad/s) and `zeta`.
@(private = "file")
wheel_aim :: proc(m: ^Wheel_Memory, to, omega, zeta: f64) {
	m.target, m.omega, m.zeta = to, omega, zeta
	// (a new aim takes over from a glide at the speed the glide has: the spring starts from it)
	m.glide_s = 0
}

// Where a glide from `from` to `to` is at `t` (0..1) of its `seconds`, and its speed (rows per s): a cubic ease-out, at
// `to` with no speed from t = 1 on.
@(private)
wheel_glide :: proc(from, to, t, seconds: f64) -> (pos, speed: f64) {
	if t >= 1 { return to, 0 }
	u := 1 - max(t, 0)
	return from + (to - from) * (1 - u * u * u), (to - from) * 3 * u * u / seconds
}

// The row `to` within the drum: a bounded drum's first or last at most (rounded unless `whole` is false); a wrapped one
// is not bounded.
@(private)
wheel_bound :: proc(to: f64, n: int, wrap: bool, whole := true) -> f64 {
	v := whole ? math.round(to) : to
	return wrap ? v : clamp(v, 0, f64(n - 1))
}

// The index of the row at `pos` (rounded): a wrapped drum's modulo its rows.
@(private)
wheel_index :: proc(pos: f64, n: int, wrap: bool) -> int {
	i := int(math.round(pos))
	return wrap ? ((i % n) + n) % n : clamp(i, 0, n - 1)
}

// The position of row `i` nearest `from`: on a wrapped drum, the shorter way round.
@(private)
wheel_nearest :: proc(from: f64, i, n: int, wrap: bool) -> f64 {
	if !wrap { return f64(i) }
	base := math.round(from)
	d := (i - wheel_index(base, n, true)) %% n
	if d > n / 2 { d -= n }
	return base + f64(d)
}

// One frame of a damped spring from `pos` at `speed` toward `target` (rows; rows per second), `dt` seconds long, in
// steps of WHEEL_STEP_S at most. Settled, it is exactly at `target` with no speed.
@(private)
wheel_spring :: proc(pos, speed, target, omega, zeta, dt: f64) -> (p, v: f64) {
	p, v = pos, speed
	left := dt
	for left > 0 {
		h := min(left, WHEEL_STEP_S)
		a := -omega * omega * (p - target) - 2 * zeta * omega * v
		v += a * h
		p += v * h
		left -= h
	}
	if abs(p - target) < WHEEL_SETTLED_ROWS && abs(v) < WHEEL_SETTLED_SPEED { return target, 0 }
	return
}

// The row whose label starts with what was typed (letters and digits; a number's leading zeros may be left out), keys
// typed within WHEEL_TYPE_MS of each other.
@(private = "file")
wheel_typed :: proc(m: ^Wheel_Memory, r: Wheel_Rows, now: f64) -> (index: int, ok: bool) {
	s := gs()
	if len(s.typed) == 0 { return }
	if now - m.typed_ms > WHEEL_TYPE_MS { m.typed_n = 0 }
	for c in s.typed {
		if c >= 0x80 || c <= ' ' || m.typed_n >= len(m.typed) { continue }
		m.typed[m.typed_n] = u8(c) | 0x20 if c >= 'A' && c <= 'Z' else u8(c)
		m.typed_n += 1
	}
	m.typed_ms = now
	if m.typed_n == 0 { return }
	want := string(m.typed[:m.typed_n])
	for i in 0 ..< r.count {
		l := wheel_label(r, i)
		if ascii.has_prefix_fold(l, want) || ascii.has_prefix_fold(strings.trim_left(l, "0"), want) { return i, true }
	}
	return
}

// The group a drum is built in (its parent is the group's box), or nil.
@(private = "file")
wheel_group :: proc(p: ^Box) -> ^Wheel_Band {
	if p == nil || p.custom != wheels_draw { return nil }
	return (^Wheel_Band)(p.custom_user)
}

@(private = "file")
wheel_band_of :: proc(g: ^Wheel_Band, rows: int, em: f32) {
	g.rows = max(rows, 3)
	g.row_h = math.round(em * WHEEL_ROW_EM)
	g.inset = math.round(em * WHEEL_BAND_INSET_EM)
	g.machined = machined()
	g.well, g.face, g.accent, g.text = color("well"), color("background"), color("accent"), color("text")
}

@(private = "file")
wheels_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	g := (^Wheel_Band)(user)
	g.focus = b.focus_t
	wheel_band_draw(dc, b.rect, g)
}

// The well, the band at its middle and the shade of the cylinder at its edges.
@(private = "file")
wheel_band_draw :: proc(dc: ^draw.Context, r: Rect, g: ^Wheel_Band) {
	machined_well(dc, r, g.radius, g.well, g.focus, g.accent)
	cy := math.round((r.min.y + r.max.y) * 0.5)
	half := math.round(g.row_h * 0.5)
	band := Rect{{r.min.x + g.inset, cy - half}, {r.max.x - g.inset, cy + half}}
	radius := max(concentric_radius(radius_drawn(gs(), g.radius), g.inset), px1())
	if g.machined {
		machined_bevel(dc, band, radius, draw.mix(g.face, g.accent, WHEEL_BAND_ACCENT), 0, 0, glow = g.accent)
	} else {
		// (a tint of the well toward the text and an edge of the accent, not the accent: the value is read in the text's
		// colour, as on a lens over the drum, on a light theme as on a dark one)
		paint_rect(dc, band, draw.mix(g.well, g.text, WHEEL_BAND_TINT), radius)
		draw.rect(dc, band, with_alpha(g.accent, WHEEL_BAND_EDGE), radius, px1())
	}
	if g.tick > 0 { draw.rect(dc, band, with_alpha(g.accent, WHEEL_TICK_ALPHA * g.tick), radius, 1.5 * px1()) }
}

// The shade over the rows: the drum's top and bottom turn away from the light.
@(private = "file")
wheel_shade :: proc(dc: ^draw.Context, r, well: Rect, radius: f32, base: Color) {
	h := r.max.y - r.min.y
	dark := with_alpha(base, WHEEL_SHADE_ALPHA)
	clear := with_alpha(base, 0)
	stops := [4]draw.Gradient_Stop{{color = dark, pos = 0}, {color = clear, pos = WHEEL_SHADE_REACH}, {color = clear, pos = 1 - WHEEL_SHADE_REACH}, {color = dark, pos = 1}}
	rr := radius_drawn(gs(), radius)
	draw.push_clip_rounded(dc, well, {rr, rr, rr, rr})
	draw.gradient(dc, r, {kind = .Linear, start = {0, 0}, end = {0, h}, stops = stops[:]})
	draw.pop_clip(dc)
}

@(private = "file")
wheel_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Wheel_Draw)(user)
	r := b.rect
	if d.band != nil {
		d.band.focus = b.focus_t
		wheel_band_draw(dc, r, d.band)
	}
	cy := math.round((r.min.y + r.max.y) * 0.5)
	R := (r.max.y - r.min.y) * 0.5
	step := d.row_h / R
	half := math.round(d.row_h * 0.5)
	m := font.metrics(gs().fonts, d.font, d.size)
	base := (m.ascent - m.descent) * 0.5
	above := Rect{r.min, {r.max.x, cy - half}}
	band := Rect{{r.min.x, cy - half}, {r.max.x, cy + half}}
	below := Rect{{r.min.x, cy + half}, r.max}
	// (each row twice, cut by the band: weak outside it, the band's colour inside, so a row changes colour along a line)
	for part, k in ([3]Rect{above, below, band}) {
		ink := k == 2 ? d.on_band : d.weak
		draw.push_clip(dc, part)
		for row in d.rows {
			a := row.d * step
			c := math.cos(a)
			if c <= 0 { continue }
			y := cy + R * math.sin(a)
			w := text_width(d.font, d.size, row.text)
			x := r.min.x + d.pad + (d.right ? d.label_w - w : (d.label_w - w) * 0.5)
			at := Vec2{math.round(x), y + base * c}
			draw.push_transform(dc, draw.affine_around(draw.affine_scale({1, c}), at))
			draw.text(dc, d.font, d.size, at, with_alpha(ink, c), row.text)
			draw.pop_transform(dc)
		}
		if k == 2 && d.unit != "" { draw.text(dc, d.font, d.size, {math.round(r.min.x + d.unit_x), math.round(cy + base)}, ink, d.unit) }
		draw.pop_clip(dc)
	}
	if d.band != nil {
		wheel_shade(dc, r, r, d.band.radius, d.band.well)
	} else if g := wheel_group(b.parent); g != nil {
		// (the group's fade spans its drums: each drum fades its own part, cut by the group's corners)
		wheel_shade(dc, r, b.parent.rect, g.radius, g.well)
	}
}

// The drums this build did not build.
@(private)
wheel_trim :: proc(s: ^State) {
	dead := make([dynamic]Key, context.temp_allocator)
	for k, m in s.wheels { if m.seen != s.build_index { append(&dead, k) } }
	for k in dead { delete_key(&s.wheels, k) }
}
