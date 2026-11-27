package debug

// A program's value over time (src/md/features/curve-editor.md): keys with Bézier handles, evaluated in every build. The
// program owns its curves and its clock; the debug window edits them (curve_editor.odin), a release only plays them.
//
//   d.play.time = debug.playback_step(&d.play, dt, debug.curve_span(d.hover))
//   height := debug.curve_eval(d.hover, d.play.time)

import "core:fmt"
import "core:math"
import "core:strings"
import "../ui"

// The keys a curve holds at most.
CURVE_KEYS_MAX :: 32

// How a curve goes from a key to the next.
Curve_Interp :: enum u8 {
	Bezier,     // the cubic through the key's out handle and the next key's in handle (the zero value)
	Linear,
	Constant,   // the key's value until the next key
}

Curve_Key :: struct {
	time:       f32,
	value:      f32,
	in_handle:  [2]f32,          // the control point before the key: (time <= 0, value) from it
	out_handle: [2]f32,          // the control point after the key: (time >= 0, value) from it
	interp:     Curve_Interp,    // of the segment from this key to the next
	broken:     bool,            // its handles move apart; else a drag of one turns the other (aligned)
}

// A value over time: the first `count` keys, sorted by time. Plain data: a constant of the program, printed by the debug
// window's Print (curve_text) to paste back.
Curve :: struct {
	count: int,
	keys:  [CURVE_KEYS_MAX]Curve_Key,
}

// Where a curve, or several, is played: the program's clock, stepped by the program (playback_step) and shown, played,
// paused and scrubbed by the debug window's editor.
Playback :: struct {
	time:   f32,
	speed:  f32,    // 0: 1 (a zero Playback plays at its pace)
	paused: bool,
	once:   bool,   // stops at the end; else loops
}

// The value of `c` at `t`: the first key's before it, the last key's after it, 0 without a key. Between two keys, the
// left key's interpolation. O(log keys).
curve_eval :: proc(c: Curve, t: f32) -> f32 {
	n := clamp(c.count, 0, CURVE_KEYS_MAX)
	if n == 0 { return 0 }
	if !(t > c.keys[0].time) { return c.keys[0].value }   // (a NaN too)
	if t >= c.keys[n - 1].time { return c.keys[n - 1].value }
	lo, hi := 0, n - 1   // keys[lo].time <= t < keys[hi].time
	for hi - lo > 1 {
		m := (lo + hi) / 2
		if c.keys[m].time <= t { lo = m } else { hi = m }
	}
	return segment_eval(c.keys[lo], c.keys[lo + 1], t)
}

// The values of several curves at `t` (a vector's channels).
curves_eval :: proc(cs: [$N]Curve, t: f32) -> (v: [N]f32) {
	for i in 0 ..< N { v[i] = curve_eval(cs[i], t) }
	return
}

// The time from the first key to the last: what a Playback loops over. {0, 0} without a key.
curve_span :: proc(c: Curve) -> [2]f32 {
	n := clamp(c.count, 0, CURVE_KEYS_MAX)
	if n == 0 { return {} }
	return {c.keys[0].time, c.keys[n - 1].time}
}

// The span of several curves together: from the earliest key to the latest.
curves_span :: proc(cs: []Curve) -> (span: [2]f32) {
	first := true
	for c in cs {
		if c.count <= 0 { continue }
		s := curve_span(c)
		if first { span, first = s, false } else { span = {min(span[0], s[0]), max(span[1], s[1])} }
	}
	return
}

// One frame of `p`: its time moves by `dt` seconds at its speed, unless paused, and loops over `span` (once: stops at its
// end). A span of no length leaves the time where it goes. Returns the time.
playback_step :: proc(p: ^Playback, dt: f32, span: [2]f32) -> f32 {
	if p.paused { return p.time }
	p.time += dt * (p.speed == 0 ? 1 : p.speed)
	from, to := span[0], span[1]
	if to > from {
		if p.once {
			p.time = clamp(p.time, from, to)
		} else if p.time >= to || p.time < from {
			length := to - from
			p.time = from + (p.time - from) - math.floor((p.time - from) / length) * length
		}
	}
	return p.time
}

// Puts `k` among the keys at its time (after a key of the same time); its index, or -1 when the curve is full.
curve_insert :: proc(c: ^Curve, k: Curve_Key) -> int {
	n := clamp(c.count, 0, CURVE_KEYS_MAX)
	if n >= CURVE_KEYS_MAX { return -1 }
	at := n
	for i in 0 ..< n { if c.keys[i].time > k.time { at = i; break } }
	for i := n; i > at; i -= 1 { c.keys[i] = c.keys[i - 1] }
	c.keys[at] = k
	c.count = n + 1
	return at
}

// Takes key `i` away.
curve_remove :: proc(c: ^Curve, i: int) {
	n := clamp(c.count, 0, CURVE_KEYS_MAX)
	if i < 0 || i >= n { return }
	for j in i ..< n - 1 { c.keys[j] = c.keys[j + 1] }
	c.keys[n - 1] = {}
	c.count = n - 1
}

// Gives key `i` smooth handles: the slope from its left neighbour to its right one (flat at an end), each handle a third
// of its segment long.
curve_smooth :: proc(c: ^Curve, i: int) {
	n := clamp(c.count, 0, CURVE_KEYS_MAX)
	if i < 0 || i >= n { return }
	k := &c.keys[i]
	left := i > 0 ? k.time - c.keys[i - 1].time : 0
	right := i < n - 1 ? c.keys[i + 1].time - k.time : 0
	slope: f32
	if i > 0 && i < n - 1 && left + right > 0 { slope = (c.keys[i + 1].value - c.keys[i - 1].value) / (left + right) }
	k.in_handle = {-left / 3, -left / 3 * slope}
	k.out_handle = {right / 3, right / 3 * slope}
	k.broken = false
}

// A segment's value at `t`, a.time <= t < b.time.
@(private)
segment_eval :: proc(a, b: Curve_Key, t: f32) -> f32 {
	dt := b.time - a.time
	if dt <= 0 { return b.value }
	switch a.interp {
	case .Constant: return a.value
	case .Linear:   return a.value + (b.value - a.value) * (t - a.time) / dt
	case .Bezier:
		o := handle_within(a.out_handle, dt, false)
		h := handle_within(b.in_handle, dt, true)
		u := ui.bezier_param(o.x / dt, 1 + h.x / dt, (t - a.time) / dt)
		w := 1 - u
		return w * w * w * a.value + 3 * w * w * u * (a.value + o.y) + 3 * w * u * u * (b.value + h.y) + u * u * u * b.value
	}
	return a.value
}

// A handle held to its side of the key and to its segment's length, its slope kept: the cubic's time then grows with its
// parameter, and a time has one value.
@(private)
handle_within :: proc(h: [2]f32, dt: f32, before: bool) -> [2]f32 {
	x := before ? min(h.x, 0) : max(h.x, 0)
	y := h.y
	if abs(x) > dt {
		k := dt / abs(x)
		x, y = x * k, y * k
	}
	return {x, y}
}

////////////////////////////////
// Odin source

// `c` as Odin source, to paste back (temp allocator): `debug.Curve{count = 2, keys = {0 = {time = 0, value = 1}, ...}}`.
// A key writes its time and its value, then what is not zero. Works in a release build too.
curve_text :: proc(c: Curve) -> string {
	b := strings.builder_make(context.temp_allocator)
	curve_write(&b, c, "debug.Curve")
	return strings.to_string(b)
}

// Several curves (a vector's channels) as Odin source: `[3]debug.Curve{{count = ...}, ...}`.
curves_text :: proc(cs: []Curve) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "[%d]debug.Curve{{", len(cs))
	for c, i in cs {
		if i > 0 { strings.write_string(&b, ", ") }
		curve_write(&b, c, "")
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// A curve's literal, after `name` ("": a field's or an item's, typed by where it goes).
@(private)
curve_write :: proc(b: ^strings.Builder, c: Curve, name: string) {
	n := clamp(c.count, 0, CURVE_KEYS_MAX)
	fmt.sbprintf(b, "%s{{count = %d", name, n)
	if n > 0 {
		// (Odin takes no array literal shorter than its array: the keys by index)
		strings.write_string(b, ", keys = {")
		for i in 0 ..< n {
			k := c.keys[i]
			if i > 0 { strings.write_string(b, ", ") }
			fmt.sbprintf(b, "%d = {{time = %s, value = %s", i, number_odin(k.time), number_odin(k.value))
			if k.in_handle != {} { fmt.sbprintf(b, ", in_handle = {{%s, %s}}", number_odin(k.in_handle.x), number_odin(k.in_handle.y)) }
			if k.out_handle != {} { fmt.sbprintf(b, ", out_handle = {{%s, %s}}", number_odin(k.out_handle.x), number_odin(k.out_handle.y)) }
			if k.interp != .Bezier { fmt.sbprintf(b, ", interp = .%v", k.interp) }
			if k.broken { strings.write_string(b, ", broken = true") }
			strings.write_byte(b, '}')
		}
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, '}')
}

// An f32 as Odin reads it back to the same f32: its shortest digits (no "-0", no exponent Odin would refuse).
@(private)
number_odin :: proc(v: f32) -> string {
	if v == 0 { return "0" }
	return fmt.tprintf("%v", v)
}
