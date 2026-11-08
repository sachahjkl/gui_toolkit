package tk_paint

import "core:math"

Verb :: enum u8 {
	Move,    // one point: a new figure
	Line,    // one point
	Cubic,   // two control points, then the end
	Close,   // no point: back to the figure's first point
}

// Figures of lines and cubic Béziers (a quadratic Bézier, an arc and an ellipse become cubics, as in GDI+). The zero
// value is an empty path that allocates from context.allocator.
Path :: struct {
	verbs:  [dynamic]Verb,
	points: [dynamic][2]f32,
	open:   bool,   // a figure is begun and not closed: the next line or arc continues it
}

path_destroy :: proc(p: ^Path) {
	delete(p.verbs)
	delete(p.points)
	p^ = {}
}

path_clone :: proc(p: Path, allocator := context.allocator) -> Path {
	out := Path{verbs = make([dynamic]Verb, 0, len(p.verbs), allocator), points = make([dynamic][2]f32, 0, len(p.points), allocator), open = p.open}
	append(&out.verbs, ..p.verbs[:])
	append(&out.points, ..p.points[:])
	return out
}

move_to :: proc(p: ^Path, x, y: f32) {
	append(&p.verbs, Verb.Move)
	append(&p.points, [2]f32{x, y})
	p.open = true
}

// A line from the current point; with no figure begun, the start of one.
line_to :: proc(p: ^Path, x, y: f32) {
	if !p.open { move_to(p, x, y); return }
	append(&p.verbs, Verb.Line)
	append(&p.points, [2]f32{x, y})
}

cubic_to :: proc(p: ^Path, c1x, c1y, c2x, c2y, x, y: f32) {
	if !p.open { s := last_point(p^); move_to(p, s.x, s.y) }
	append(&p.verbs, Verb.Cubic)
	append(&p.points, [2]f32{c1x, c1y}, [2]f32{c2x, c2y}, [2]f32{x, y})
}

quad_to :: proc(p: ^Path, cx, cy, x, y: f32) {
	s := last_point(p^)
	c := [2]f32{cx, cy}
	c1 := s + (c - s) * (2.0 / 3)
	c2 := [2]f32{x, y} + (c - [2]f32{x, y}) * (2.0 / 3)
	cubic_to(p, c1.x, c1.y, c2.x, c2.y, x, y)
}

// Ends the figure with a line back to its first point.
close :: proc(p: ^Path) {
	if !p.open { return }
	append(&p.verbs, Verb.Close)
	p.open = false
}

@(private)
last_point :: proc(p: Path) -> [2]f32 {
	return len(p.points) > 0 ? p.points[len(p.points) - 1] : {}
}

// An arc of the ellipse in the box (x, y, w, h), from `start` degrees, `sweep` degrees long (positive: clockwise on a canvas).
// The angles are those of GDI+'s AddArc: the direction from the centre, not the ellipse's parameter. A begun figure gets a
// line to the arc's start; else the arc begins one.
arc :: proc(p: ^Path, x, y, w, h, start, sweep: f32) {
	rx, ry := w / 2, h / 2
	cx, cy := x + rx, y + ry
	t0 := parameter(math.to_radians(start), rx, ry)
	t1: f32
	if abs(sweep) >= 360 {
		t1 = t0 + math.to_radians(sweep)
	} else {
		d := parameter(math.to_radians(start + sweep), rx, ry) - t0
		for sweep > 0 && d <= 0 { d += math.TAU }
		for sweep < 0 && d >= 0 { d -= math.TAU }
		if sweep == 0 { d = 0 }
		t1 = t0 + d
	}
	on :: proc(cx, cy, rx, ry, t: f32) -> [2]f32 { return {cx + rx * math.cos(t), cy + ry * math.sin(t)} }
	s := on(cx, cy, rx, ry, t0)
	line_to(p, s.x, s.y)
	// at most a quarter turn per Bézier
	n := max(1, int(math.ceil(abs(t1 - t0) / (math.PI / 2) - 1e-4)))
	step := (t1 - t0) / f32(n)
	k := 4.0 / 3 * math.tan(step / 4)
	for i in 0 ..< n {
		a := t0 + step * f32(i)
		b := a + step
		pa, pb := on(cx, cy, rx, ry, a), on(cx, cy, rx, ry, b)
		da := [2]f32{-rx * math.sin(a), ry * math.cos(a)}
		db := [2]f32{-rx * math.sin(b), ry * math.cos(b)}
		c1, c2 := pa + da * k, pb - db * k
		cubic_to(p, c1.x, c1.y, c2.x, c2.y, pb.x, pb.y)
	}
}

// The ellipse's parameter for the direction `angle` from its centre.
@(private = "file")
parameter :: proc(angle, rx, ry: f32) -> f32 {
	if rx == ry { return angle }
	return math.atan2(rx * math.sin(angle), ry * math.cos(angle)) + math.floor((angle + math.PI) / math.TAU) * math.TAU
}

// A rectangle with corners of radius r, clockwise from the top left corner's arc, as a closed figure of its own.
round_rect :: proc(p: ^Path, x, y, w, h, r: f32) {
	start_figure(p)
	d := 2 * r
	arc(p, x, y, d, d, 180, 90)
	arc(p, x + w - d, y, d, d, 270, 90)
	arc(p, x + w - d, y + h - d, d, d, 0, 90)
	arc(p, x, y + h - d, d, d, 90, 90)
	close(p)
}

// A rectangle, clockwise from its top left corner, as a closed figure of its own.
rect :: proc(p: ^Path, x, y, w, h: f32) {
	start_figure(p)
	move_to(p, x, y)
	line_to(p, x + w, y)
	line_to(p, x + w, y + h)
	line_to(p, x, y + h)
	close(p)
}

// Ends the current figure without closing it: the next line or arc begins another (GDI+'s StartFigure).
start_figure :: proc(p: ^Path) { p.open = false }

// The ellipse in the box (x, y, w, h), as a closed figure of four Béziers of its own (GDI+'s AddEllipse).
ellipse :: proc(p: ^Path, x, y, w, h: f32) {
	start_figure(p)
	arc(p, x, y, w, h, 0, 360)
	close(p)
}

// A closed figure of its own through `points`.
polygon :: proc(p: ^Path, points: [][2]f32) {
	start_figure(p)
	for q in points { line_to(p, q.x, q.y) }
	close(p)
}

// Every point of the path through `m`.
path_transform :: proc(p: ^Path, m: Matrix) {
	for &q in p.points { q = apply(m, q) }
}

// The figures as polygons: the points through `m`, each curve cut in lines that stray at most `tolerance` from it.
@(private)
flatten :: proc(p: Path, m: Matrix, tolerance: f32, points: ^[dynamic][2]f32, contours: ^[dynamic]Contour) {
	finish :: proc(points: ^[dynamic][2]f32, contours: ^[dynamic]Contour, closed: bool) {
		if len(contours) == 0 { return }
		c := &contours[len(contours) - 1]
		c.count = len(points) - c.start
		c.closed = closed
	}
	at := 0
	for v in p.verbs {
		switch v {
		case .Move:
			if len(contours) > 0 && contours[len(contours) - 1].count == 0 { finish(points, contours, false) }
			append(contours, Contour{start = len(points)})
			append(points, apply(m, p.points[at]))
			at += 1
		case .Line:
			append(points, apply(m, p.points[at]))
			at += 1
		case .Cubic:
			p0 := points[len(points) - 1]
			p1, p2, p3 := apply(m, p.points[at]), apply(m, p.points[at + 1]), apply(m, p.points[at + 2])
			at += 3
			// the second differences bound the distance from the chords (Wang's formula)
			dd := max(length(p0 - 2 * p1 + p2), length(p1 - 2 * p2 + p3))
			n := clamp(int(math.ceil(math.sqrt(dd * 0.75 / tolerance))), 1, 4096)
			for i in 1 ..= n {
				t := f32(i) / f32(n)
				u := 1 - t
				append(points, p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t))
			}
		case .Close:
			finish(points, contours, true)
		}
	}
	if len(contours) > 0 && contours[len(contours) - 1].count == 0 { finish(points, contours, false) }
}

@(private)
length :: proc(v: [2]f32) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }
