package tk_paint

import "core:math"

Paint_Kind :: enum u8 {
	Solid,
	Linear,   // along the line from `start` to `end`
	Radial,   // from `start` (the centre) out to `radius`
}

// Past the ends of a gradient.
Spread :: enum u8 {
	Pad,      // the end colours go on
	Repeat,   // the gradient starts again (GDI+'s WrapMode.Tile, the default of its LinearGradientBrush)
}

Stop :: struct {
	at:    f32,   // 0 to 1, rising from one stop to the next
	color: Color,
}

MAX_STOPS :: 8

// What fills a shape: a colour or a gradient. The points are in the coordinates of paths (before the canvas's transform).
// Colours between stops are interpolated without premultiplying, as GDI+ does.
Paint :: struct {
	kind:       Paint_Kind,
	color:      Color,   // Solid
	start, end: [2]f32,
	radius:     f32,
	spread:     Spread,
	stops:      [MAX_STOPS]Stop,
	stop_count: int,
}

solid :: proc(color: Color) -> Paint { return {kind = .Solid, color = color} }

// A gradient from `from` at `start` to `to` at `end`; more colours with `add_stop`.
linear :: proc(start, end: [2]f32, from, to: Color, spread := Spread.Pad) -> Paint {
	p := Paint{kind = .Linear, start = start, end = end, spread = spread}
	add_stop(&p, 0, from)
	add_stop(&p, 1, to)
	return p
}

// A gradient from `from` at `center` to `to` at `radius` from it.
radial :: proc(center: [2]f32, radius: f32, from, to: Color, spread := Spread.Pad) -> Paint {
	p := Paint{kind = .Radial, start = center, radius = radius, spread = spread}
	add_stop(&p, 0, from)
	add_stop(&p, 1, to)
	return p
}

// A stop placed among the others by its position (one at the same position goes after it). More than MAX_STOPS: ignored.
add_stop :: proc(p: ^Paint, at: f32, color: Color) {
	if p.stop_count >= MAX_STOPS { return }
	i := p.stop_count
	for i > 0 && p.stops[i - 1].at > at {
		p.stops[i] = p.stops[i - 1]
		i -= 1
	}
	p.stops[i] = {at, color}
	p.stop_count += 1
}

// Replaces the stops (GDI+'s InterpolationColors).
set_stops :: proc(p: ^Paint, stops: []Stop) {
	p.stop_count = 0
	for s in stops { add_stop(p, s.at, s.color) }
}

// The paint's colour at a point of path coordinates.
shade :: proc(p: Paint, at: [2]f32) -> Color {
	p := p
	t: f32
	switch p.kind {
	case .Solid:
		return p.color
	case .Linear:
		d := p.end - p.start
		dd := d.x * d.x + d.y * d.y
		if dd == 0 { return p.stops[p.stop_count - 1].color }
		q := at - p.start
		t = (q.x * d.x + q.y * d.y) / dd
	case .Radial:
		if p.radius <= 0 { return p.stops[p.stop_count - 1].color }
		t = length(at - p.start) / p.radius
	}
	switch p.spread {
	case .Pad:    t = clamp(t, 0, 1)
	case .Repeat: t -= math.floor(t)
	}
	s := p.stops[:p.stop_count]
	if len(s) == 0 { return {} }
	if t <= s[0].at { return s[0].color }
	for i in 1 ..< len(s) {
		if t > s[i].at { continue }
		span := s[i].at - s[i - 1].at
		f := span > 0 ? (t - s[i - 1].at) / span : 1
		return s[i - 1].color + (s[i].color - s[i - 1].color) * f
	}
	return s[len(s) - 1].color
}
