package draw

import "core:math"

// Drawing several planes of one 3D rendering context (CSS transform-style: preserve-3d) in the order they hide each other.
//
// The planes are polygons in the space after the perspective divide, where the viewer looks along -z from infinity and planes
// stay planes (a projective map keeps them). When no two planes cut through each other, a painter's order from the sides
// planes lie on is enough (a plane wholly on the viewer's side of another is drawn after it; the depth of the middles and the
// paint order decide the rest), and each plane is drawn whole. When planes do cut each other (or hide each other in a cycle),
// the order does not exist: as Chromium's BspTree / DrawPolygon do, the planes are split along each other's planes into
// convex pieces, ordered back to front by a binary space partition for a viewer in front. A piece is not a new layer: the
// plane is drawn again from its own texture, once per piece, with the cuts that bound the piece (Plane_Draw.cuts: half-spaces
// tested per pixel, hard edges, so pieces of one plane fit without a seam or an overlap).

// One part of a plane item: a layer drawn through a matrix.
Plane_Part :: struct {
	layer: Plane_Layer,
	m:     Mat4,
	alpha: f32,
	o:     Plane_Draw,
}

// A plane of the context, to be drawn as its `parts` in order (the layer of the plane itself and of flat things that ride on it,
// all lying on the plane `geom` described by: its rect through `geom_m`).
Plane_Item :: struct {
	parts:  []Plane_Part,
	geom:   Plane_Layer,
	geom_m: Mat4,
	skip:   bool,   // seen from behind with backface-visibility: hidden: its layers are given back, nothing is drawn
}

// An item of a single layer.
plane_item :: proc(layer: Plane_Layer, m: Mat4, alpha := f32(1), o: Plane_Draw = {}, cull := false) -> Plane_Item {
	parts := make([]Plane_Part, 1, context.temp_allocator)
	parts[0] = Plane_Part{layer = layer, m = m, alpha = alpha, o = o}
	return Plane_Item{parts = parts, geom = layer, geom_m = m, skip = cull}
}

// Draws the items of a context in order, splitting those that cut through each other. The layers are given back afterwards
// (the ones kept by the cache stay).
draw_planes :: proc(c: ^Context, items: []Plane_Item) {
	defer for it in items { for p in it.parts { discard_plane(c, p.layer); discard_plane(c, p.o.shape) } }
	n := len(items)
	if n == 0 { return }
	if c.rec != nil { return }
	geos := make([]Geo, n, context.temp_allocator)
	for i in 0 ..< n {
		geos[i] = geo_of(items[i], i)
		if items[i].skip { geos[i].flat = true }   // hidden (backface-visibility): nothing of it is drawn, so it neither forces a split nor cuts the others
	}
	order := make([dynamic]int, 0, n, context.temp_allocator)
	split := false
	if n > 1 {
		for i in 0 ..< n {
			if split { break }
			for j in i + 1 ..< n {
				if planes_cross(&geos[i], &geos[j]) { split = true; break }
			}
		}
		if !split { split = !painter_order(geos, &order) }
	} else {
		append(&order, 0)
	}
	if !split {
		for i in order { draw_item(c, items[i], nil) }
		return
	}
	pieces := bsp_pieces(geos)
	for p in pieces { draw_item(c, items[p.item], p.cuts[:]) }
}

@(private)
draw_item :: proc(c: ^Context, it: Plane_Item, cuts: []Plane_Cut) {
	if it.skip { return }
	for p in it.parts {
		o := p.o
		o.cuts = cuts
		o.retain = true
		draw_plane(c, p.layer, p.m, p.alpha, o)
	}
}

////////////////////////////////
// Geometry

@(private)
TOL_DIST :: 0.02   // planes closer than this (in the units of the space after the divide: pixels) are the same plane

@(private)
Geo :: struct {
	seq:   int,
	pts:   [dynamic][2]f32,   // the plane's rect in its frame, cut to the part in front of the eye
	v:     [dynamic][3]f32,   // the same points after the divide
	m:     Mat4,
	n:     [3]f32,            // unit normal, n.z >= 0 (the viewer's side is the positive one)
	d:     f32,
	flat:  bool,              // seen edge-on, or not in front of the eye at all: nothing to see
	z:     f32,               // depth of the middle
}

@(private)
Bsp_Piece :: struct {
	item: int,
	pts:  [dynamic][2]f32,    // convex, in the item's plane frame
	cuts: [dynamic]Plane_Cut,
}

@(private)
geo_of :: proc(it: Plane_Item, seq: int) -> Geo {
	g := Geo{seq = seq, m = it.geom_m}
	pl := it.geom
	r0 := pl.origin
	r1 := pl.origin + Vec2{f32(pl.size.x), f32(pl.size.y)} / pl.scale
	corners := [4]Vec2{r0, {r1.x, r0.y}, r1, {r0.x, r1.y}}
	hs: [4][4]f32
	wmax: f32
	for k in 0 ..< 4 {
		hs[k] = mat4_apply(g.m, {corners[k].x, corners[k].y, 0})
		wmax = max(wmax, hs[k][3])
	}
	if !(wmax > 1e-9) { g.flat = true; return g }
	wmin := max(wmax * 1e-3, 1e-9)
	g.pts = make([dynamic][2]f32, 0, 6, context.temp_allocator)
	g.v = make([dynamic][3]f32, 0, 6, context.temp_allocator)
	// the rect cut by w >= wmin (an affine function of the frame position: edges stay straight)
	for k in 0 ..< 4 {
		a, b := hs[k], hs[(k + 1) % 4]
		pa, pb := corners[k], corners[(k + 1) % 4]
		if a[3] >= wmin { append(&g.pts, pa) }
		if (a[3] >= wmin) != (b[3] >= wmin) {
			t := (wmin - a[3]) / (b[3] - a[3])
			append(&g.pts, pa + (pb - pa) * t)
		}
	}
	for p in g.pts {
		h := mat4_apply(g.m, {p.x, p.y, 0})
		append(&g.v, [3]f32{h[0] / h[3], h[1] / h[3], h[2] / h[3]})
	}
	if len(g.pts) < 3 { g.flat = true; return g }
	// the plane through the three columns of the matrix that act on (x, y, 1): the null vector of the 3 x 4 matrix, so
	// n . (X, Y, Z) + d W = 0 for every point of the plane
	cx := [4]f32{g.m[0], g.m[1], g.m[2], g.m[3]}
	cy := [4]f32{g.m[4], g.m[5], g.m[6], g.m[7]}
	cw := [4]f32{g.m[12], g.m[13], g.m[14], g.m[15]}
	l: [4]f32
	for k in 0 ..< 4 {
		idx: [3]int
		j := 0
		for q in 0 ..< 4 { if q != k { idx[j] = q; j += 1 } }
		det := cx[idx[0]] * (cy[idx[1]] * cw[idx[2]] - cy[idx[2]] * cw[idx[1]]) -
		       cx[idx[1]] * (cy[idx[0]] * cw[idx[2]] - cy[idx[2]] * cw[idx[0]]) +
		       cx[idx[2]] * (cy[idx[0]] * cw[idx[1]] - cy[idx[1]] * cw[idx[0]])
		l[k] = k % 2 == 0 ? det : -det
	}
	ln := math.sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2])
	if ln < 1e-20 { g.flat = true; return g }
	l /= ln
	if l[2] < 0 { l = -l }
	g.n, g.d = {l[0], l[1], l[2]}, l[3]
	if abs(g.n.z) < 1e-4 { g.flat = true }
	for p in g.v { g.z += p.z }
	g.z /= f32(len(g.v))
	return g
}

@(private)
dist_to :: #force_inline proc(n: [3]f32, d: f32, p: [3]f32) -> f32 { return n.x * p.x + n.y * p.y + n.z * p.z + d }

// Range of the signed distances of the points of `a` to the plane of `b`.
@(private)
dist_range :: proc(a: ^Geo, b: ^Geo) -> (lo, hi: f32) {
	lo, hi = math.F32_MAX, -math.F32_MAX
	for p in a.v {
		x := dist_to(b.n, b.d, p)
		lo, hi = min(lo, x), max(hi, x)
	}
	return
}

// Do the two planes cut through each other: do their polygons share a segment of the line where the planes meet?
@(private)
planes_cross :: proc(a, b: ^Geo) -> bool {
	if a.flat || b.flat { return false }
	la, ha := dist_range(a, b)
	lb, hb := dist_range(b, a)
	if !(la < -TOL_DIST && ha > TOL_DIST && lb < -TOL_DIST && hb > TOL_DIST) { return false }
	dir := [3]f32{a.n.y * b.n.z - a.n.z * b.n.y, a.n.z * b.n.x - a.n.x * b.n.z, a.n.x * b.n.y - a.n.y * b.n.x}
	span :: proc(p: ^Geo, q: ^Geo, dir: [3]f32) -> (lo, hi: f32) {
		lo, hi = math.F32_MAX, -math.F32_MAX
		n := len(p.v)
		for k in 0 ..< n {
			u, w := p.v[k], p.v[(k + 1) % n]
			du, dw := dist_to(q.n, q.d, u), dist_to(q.n, q.d, w)
			if (du < 0) == (dw < 0) { continue }
			t := du / (du - dw)
			x := u + (w - u) * t
			s := x.x * dir.x + x.y * dir.y + x.z * dir.z
			lo, hi = min(lo, s), max(hi, s)
		}
		return
	}
	l1, h1 := span(a, b, dir)
	l2, h2 := span(b, a, dir)
	return min(h1, h2) - max(l1, l2) > TOL_DIST * math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
}

// Is `a` wholly on the viewer's side of the plane of `b` (1), wholly behind it (-1), or neither (0: they cut each other, are
// coplanar, or `b` is edge-on)?
@(private)
side_of :: proc(a, b: ^Geo) -> int {
	if a.flat || b.flat { return 0 }
	lo, hi := dist_range(a, b)
	if lo >= -TOL_DIST && hi <= TOL_DIST { return 0 }
	if lo >= -TOL_DIST { return 1 }
	if hi <= TOL_DIST { return -1 }
	return 0
}

// Does `a` have to be drawn after `b` (1), before it (-1), or does the geometry not say (0)?
@(private)
in_front :: proc(a, b: ^Geo) -> int {
	if r := side_of(a, b); r != 0 { return r }
	return -side_of(b, a)
}

// Painter's order without splitting: planes wholly in front of others after them; the farthest middle first among the rest.
// false: the geometry has a cycle (planes that hide each other in turn): no order exists.
@(private)
painter_order :: proc(g: []Geo, order: ^[dynamic]int) -> bool {
	n := len(g)
	// before[i * n + j]: i must be drawn before j (j is wholly in front of i's plane)
	before := make([]bool, n * n, context.temp_allocator)
	for i in 0 ..< n {
		for j in i + 1 ..< n {
			switch in_front(&g[i], &g[j]) {
			case 1: before[j * n + i] = true
			case -1: before[i * n + j] = true
			}
		}
	}
	done := make([]bool, n, context.temp_allocator)
	for _ in 0 ..< n {
		pick := -1
		for i in 0 ..< n {
			if done[i] { continue }
			free := true
			for j in 0 ..< n { if !done[j] && before[j * n + i] { free = false; break } }
			if !free { continue }
			if pick < 0 || g[i].z < g[pick].z || (g[i].z == g[pick].z && g[i].seq < g[pick].seq) { pick = i }
		}
		if pick < 0 { return false }
		done[pick] = true
		append(order, pick)
	}
	return true
}

////////////////////////////////
// The BSP

@(private)
Side :: enum u8 { Front, Back, On, Span }

// The pieces of all planes in drawing order (back to front for a viewer in front).
@(private)
bsp_pieces :: proc(g: []Geo) -> []Bsp_Piece {
	out := make([dynamic]Bsp_Piece, 0, len(g) * 2, context.temp_allocator)
	polys := make([dynamic]^Bsp_Piece, 0, len(g), context.temp_allocator)
	for i in 0 ..< len(g) {
		if g[i].flat { continue }
		p := new(Bsp_Piece, context.temp_allocator)
		p.item = i
		p.pts = make([dynamic][2]f32, 0, len(g[i].pts), context.temp_allocator)
		append(&p.pts, ..g[i].pts[:])
		p.cuts = make([dynamic]Plane_Cut, 0, 4, context.temp_allocator)
		append(&polys, p)
	}
	bsp_walk(g, polys, &out)
	return out[:]
}

@(private)
poly_side :: proc(g: []Geo, p: ^Bsp_Piece, s: ^Geo) -> Side {
	front, back := false, false
	gp := &g[p.item]
	for q in p.pts {
		h := mat4_apply(gp.m, {q.x, q.y, 0})
		f := dist_to(s.n, s.d, {h[0] / h[3], h[1] / h[3], h[2] / h[3]})
		if f > TOL_DIST { front = true } else if f < -TOL_DIST { back = true }
	}
	switch {
	case front && back: return .Span
	case front: return .Front
	case back: return .Back
	}
	return .On
}

// Splits a convex polygon (frame coordinates) by the plane of `s`.
@(private)
poly_split :: proc(g: []Geo, p: ^Bsp_Piece, s: ^Geo) -> (front, back: ^Bsp_Piece) {
	gp := &g[p.item]
	front, back = new(Bsp_Piece, context.temp_allocator), new(Bsp_Piece, context.temp_allocator)
	for q in ([2]^Bsp_Piece{front, back}) {
		q.item = p.item
		q.pts = make([dynamic][2]f32, 0, len(p.pts) + 2, context.temp_allocator)
		q.cuts = make([dynamic]Plane_Cut, 0, len(p.cuts) + 1, context.temp_allocator)
		append(&q.cuts, ..p.cuts[:])
	}
	append(&front.cuts, Plane_Cut{n = s.n, d = s.d})
	append(&back.cuts, Plane_Cut{n = -s.n, d = -s.d})
	// F = n . (X, Y, Z) + d W is affine in the frame: edges are cut at its zero, exactly
	fs := make([]f32, len(p.pts), context.temp_allocator)
	sd := make([]f32, len(p.pts), context.temp_allocator)
	for q, k in p.pts {
		h := mat4_apply(gp.m, {q.x, q.y, 0})
		fs[k] = s.n.x * h[0] + s.n.y * h[1] + s.n.z * h[2] + s.d * h[3]
		sd[k] = fs[k] / h[3]
	}
	n := len(p.pts)
	for k in 0 ..< n {
		a, b := k, (k + 1) % n
		sa := sd[a] > TOL_DIST ? 1 : (sd[a] < -TOL_DIST ? -1 : 0)
		sb := sd[b] > TOL_DIST ? 1 : (sd[b] < -TOL_DIST ? -1 : 0)
		if sa >= 0 { append(&front.pts, p.pts[a]) }
		if sa <= 0 { append(&back.pts, p.pts[a]) }
		if sa * sb < 0 {
			t := fs[a] / (fs[a] - fs[b])
			x := p.pts[a] + (p.pts[b] - p.pts[a]) * t
			append(&front.pts, x)
			append(&back.pts, x)
		}
	}
	return
}

@(private)
bsp_walk :: proc(g: []Geo, polys: [dynamic]^Bsp_Piece, out: ^[dynamic]Bsp_Piece) {
	if len(polys) == 0 { return }
	// the splitter: among the first few, the one that cuts the fewest others (then the earliest)
	best, best_cuts := 0, max(int)
	for i in 0 ..< min(len(polys), 8) {
		s := &g[polys[i].item]
		cuts := 0
		for q, j in polys {
			if j != i && poly_side(g, q, s) == .Span { cuts += 1 }
		}
		if cuts < best_cuts { best, best_cuts = i, cuts }
		if cuts == 0 { break }
	}
	sp := polys[best]
	s := &g[sp.item]
	front := make([dynamic]^Bsp_Piece, 0, len(polys), context.temp_allocator)
	back := make([dynamic]^Bsp_Piece, 0, len(polys), context.temp_allocator)
	on := make([dynamic]^Bsp_Piece, 0, 2, context.temp_allocator)
	for q, j in polys {
		if j == best { append(&on, q); continue }
		switch poly_side(g, q, s) {
		case .Front: append(&front, q)
		case .Back: append(&back, q)
		case .On: append(&on, q)
		case .Span:
			f, b := poly_split(g, q, s)
			if len(f.pts) >= 3 { append(&front, f) }
			if len(b.pts) >= 3 { append(&back, b) }
		}
	}
	bsp_walk(g, back, out)
	// coplanar pieces (the splitter's own, others lying on it): in paint order
	for i in 1 ..< len(on) {
		for j := i; j > 0 && g[on[j].item].seq < g[on[j - 1].item].seq; j -= 1 { on[j], on[j - 1] = on[j - 1], on[j] }
	}
	for q in on { bsp_emit(g, q, out) }
	bsp_walk(g, front, out)
}

// Records a piece: the cuts that do not bound it (they cut away nothing of it) are dropped, so that a piece needs few.
@(private)
bsp_emit :: proc(g: []Geo, p: ^Bsp_Piece, out: ^[dynamic]Bsp_Piece) {
	area: f32
	for k in 0 ..< len(p.pts) {
		a, b := p.pts[k], p.pts[(k + 1) % len(p.pts)]
		area += a.x * b.y - b.x * a.y
	}
	if abs(area) < 1e-3 { return }
	gp := &g[p.item]
	kept := make([dynamic]Plane_Cut, 0, len(p.cuts), context.temp_allocator)
	for cut in p.cuts {
		on_line := 0
		for q in p.pts {
			h := mat4_apply(gp.m, {q.x, q.y, 0})
			if abs(dist_to(cut.n, cut.d, {h[0] / h[3], h[1] / h[3], h[2] / h[3]})) <= TOL_DIST { on_line += 1 }
		}
		if on_line < 2 { continue }
		same := false   // the same plane met twice (coplanar splitters)
		for k in kept {
			if k.n.x * cut.n.x + k.n.y * cut.n.y + k.n.z * cut.n.z > 0.99999 && abs(k.d - cut.d) <= TOL_DIST { same = true; break }
		}
		if !same { append(&kept, cut) }
	}
	if len(kept) > MAX_PLANE_CUTS && bsp_emit_halves(g, p, kept[:], out) { return }
	if len(kept) > MAX_PLANE_CUTS { resize(&kept, MAX_PLANE_CUTS) }   // not reached: a convex polygon with that many sides can be halved
	append(out, Bsp_Piece{item = p.item, pts = p.pts, cuts = kept})
}

// A draw tests MAX_PLANE_CUTS cuts per pixel at most: a piece bounded by more is divided by a chord between two of its vertices into two
// convex pieces, the chord being one more cut for each (the plane through it, perpendicular to the plane of the piece), and each half is
// recorded in turn (it keeps only the cuts that still bound it). The halves of one plane fit without a seam or an overlap, as the pieces do.
@(private)
bsp_emit_halves :: proc(g: []Geo, p: ^Bsp_Piece, kept: []Plane_Cut, out: ^[dynamic]Bsp_Piece) -> bool {
	n := len(p.pts)
	if n < 4 { return false }
	gp := &g[p.item]
	pos := make([][3]f32, n, context.temp_allocator)
	for q, k in p.pts {
		h := mat4_apply(gp.m, {q.x, q.y, 0})
		pos[k] = {h[0] / h[3], h[1] / h[3], h[2] / h[3]}
	}
	on_cut := make([]bool, n, context.temp_allocator)   // the side from vertex k to the next lies on a cut
	total := 0
	for k in 0 ..< n {
		for cut in kept {
			if abs(dist_to(cut.n, cut.d, pos[k])) <= TOL_DIST && abs(dist_to(cut.n, cut.d, pos[(k + 1) % n])) <= TOL_DIST {
				on_cut[k] = true
				total += 1
				break
			}
		}
	}
	// the chord (i, j) that leaves the fewest sides on cuts on its busier side
	bi, bj, best := -1, -1, max(int)
	for i in 0 ..< n - 2 {
		sides := 0
		for j in i + 1 ..< n {
			if on_cut[j - 1] { sides += 1 }
			if j - i < 2 || n - (j - i) < 2 { continue }
			if w := max(sides, total - sides); w < best { bi, bj, best = i, j, w }
		}
	}
	if bi < 0 || best + 1 >= len(kept) { return false }
	ab := pos[bj] - pos[bi]
	nc := [3]f32{gp.n.y * ab.z - gp.n.z * ab.y, gp.n.z * ab.x - gp.n.x * ab.z, gp.n.x * ab.y - gp.n.y * ab.x}
	l := math.sqrt(nc.x * nc.x + nc.y * nc.y + nc.z * nc.z)
	if !(l > 1e-9) { return false }
	chord := Plane_Cut{n = nc / l}
	chord.d = -(chord.n.x * pos[bi].x + chord.n.y * pos[bi].y + chord.n.z * pos[bi].z)
	if dist_to(chord.n, chord.d, pos[bi + 1]) < 0 { chord = Plane_Cut{n = -chord.n, d = -chord.d} }
	for half in 0 ..< 2 {
		q := new(Bsp_Piece, context.temp_allocator)
		q.item = p.item
		q.pts = make([dynamic][2]f32, 0, n, context.temp_allocator)
		q.cuts = make([dynamic]Plane_Cut, 0, len(kept) + 1, context.temp_allocator)
		append(&q.cuts, ..kept)
		if half == 0 {
			append(&q.pts, ..p.pts[bi:bj + 1])
			append(&q.cuts, chord)
		} else {
			append(&q.pts, ..p.pts[bj:])
			append(&q.pts, ..p.pts[:bi + 1])
			append(&q.cuts, Plane_Cut{n = -chord.n, d = -chord.d})
		}
		bsp_emit(g, q, out)
	}
	return true
}
