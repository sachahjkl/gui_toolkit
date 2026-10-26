package font

import "core:math"

// Simulated bold and oblique for faces the native backend reads (DirectWrite draws its own): what DirectWrite does,
// measured on its outlines and advances (tests/text_backends):
//   bold:    every glyph's advance grows by round(upem / 50) design units; its outline is emboldened by that much to the
//            right and floor(upem / 50) upward (each stroke grows on its right / top side, the bottom-left stays put);
//   oblique: the outline is sheared by OBLIQUE_SKEW (x += y * skew, about 18.8 degrees); advances do not change.

OBLIQUE_SKEW :: 0.33985

// Extra advance of a glyph of a simulated bold face, in design units.
sim_bold_advance :: proc(f: ^Font) -> f32 {
	if .Bold not_in f.sims { return 0 }
	return math.round(f.upem / 50)
}

// Applies the face's simulations to an outline in em units (y up).
sim_outline :: proc(f: ^Font, o: ^Outline) {
	if f.sims == {} || len(o.quads) == 0 { return }
	if .Bold in f.sims {
		outline_embolden(o, math.round(f.upem / 50) / f.upem, math.floor(f.upem / 50) / f.upem)
	}
	if .Oblique in f.sims {
		for &q in o.quads { for &p in q.p { p.x += p.y * OBLIQUE_SKEW } }
	}
	outline_bounds(o)
}

// Applies the face's simulations to a glyph's design box.
sim_box :: proc(f: ^Font, b: ^Glyph_Box) {
	if .Bold in f.sims {
		b.advance += math.round(f.upem / 50)
		if !b.empty { b.x_max += math.round(f.upem / 50); b.y_max += math.floor(f.upem / 50) }
	}
	if .Oblique in f.sims && !b.empty {
		x0 := min(b.x_min + b.y_min * OBLIQUE_SKEW, b.x_min + b.y_max * OBLIQUE_SKEW)
		x1 := max(b.x_max + b.y_min * OBLIQUE_SKEW, b.x_max + b.y_max * OBLIQUE_SKEW)
		b.x_min, b.x_max = x0, x1
	}
}

// Emboldens an outline (em units, y up) by `xs` horizontally and `ys` vertically: every point moves outward along the
// miter of its two edges by half the strength, then the whole outline moves by half of it, so that strokes grow on
// their right and top sides (FreeType's FT_Outline_EmboldenXY and translation, which DirectWrite matches). Control
// points move with their on-curve neighbours' rule (the control polygon is offset), which keeps quadratic curves smooth.
outline_embolden :: proc(o: ^Outline, xs, ys: f32) {
	if len(o.quads) == 0 { return }
	// orientation of the whole outline (shoelace on the control polygons): the outward normal side
	area: f32
	for q in o.quads {
		area += q.p[0].x * q.p[1].y - q.p[1].x * q.p[0].y
		area += q.p[1].x * q.p[2].y - q.p[2].x * q.p[1].y
	}
	cw := area < 0
	outward :: proc(d: [2]f32, cw: bool) -> [2]f32 {
		l := math.sqrt(d.x * d.x + d.y * d.y)
		if l < 1e-9 { return {} }
		n := cw ? [2]f32{-d.y, d.x} : [2]f32{d.y, -d.x}
		return n / l
	}
	start := 0
	for end in o.ends {
		quads := o.quads[start:end]
		n := len(quads)
		if n == 0 { start = end; continue }
		// the contour's polygon: p0 and control point of each quad (a line's control point is its end: skipped)
		pts := make([dynamic][2]f32, 0, 2 * n, context.temp_allocator)
		Ref :: struct { q, k: int }
		refs := make([dynamic]Ref, 0, 2 * n, context.temp_allocator)
		for q, i in quads {
			append(&pts, q.p[0]); append(&refs, Ref{i, 0})
			if q.p[1] != q.p[2] && q.p[1] != q.p[0] { append(&pts, q.p[1]); append(&refs, Ref{i, 1}) }
		}
		m := len(pts)
		moved := make([][2]f32, m, context.temp_allocator)
		for i in 0 ..< m {
			cur := pts[i]
			// neighbours that are not the same point
			pi := (i + m - 1) % m
			for k := 0; k < m && pts[pi] == cur; k += 1 { pi = (pi + m - 1) % m }
			ni := (i + 1) % m
			for k := 0; k < m && pts[ni] == cur; k += 1 { ni = (ni + 1) % m }
			e_in, e_out := cur - pts[pi], pts[ni] - cur
			l_in, l_out := math.sqrt(e_in.x * e_in.x + e_in.y * e_in.y), math.sqrt(e_out.x * e_out.x + e_out.y * e_out.y)
			n_in := outward(e_in, cw)
			n_out := outward(e_out, cw)
			d := 1 + n_in.x * n_out.x + n_in.y * n_out.y
			shift: [2]f32
			if d > 1 - 0.9375 && l_in > 0 && l_out > 0 {   // a turn of less than about 160 degrees (FreeType's rule)
				sum := n_in + n_out
				// the miter, but no longer than the shorter edge allows (collapsing segments)
				u_in, u_out := e_in / l_in, e_out / l_out
				q := u_out.x * u_in.y - u_out.y * u_in.x
				if cw { q = -q }
				l := min(l_in, l_out)
				hx, hy := xs * 0.5, ys * 0.5
				shift.x = hx * q <= l * d ? sum.x * hx / d : sum.x * l / q
				shift.y = hy * q <= l * d ? sum.y * hy / d : sum.y * l / q
			}
			moved[i] = cur + shift + {xs * 0.5, ys * 0.5}
		}
		// write back: each quad's start, its control point (or, for a line, its end = the next start), its end
		for r, i in refs {
			if r.k == 0 { quads[r.q].p[0] = moved[i] } else { quads[r.q].p[1] = moved[i] }
		}
		has_ctrl := make([]bool, n, context.temp_allocator)
		for r in refs { if r.k == 1 { has_ctrl[r.q] = true } }
		for qi in 0 ..< n {
			nxt := quads[(qi + 1) % n].p[0]
			if !has_ctrl[qi] { quads[qi].p[1] = nxt }
			quads[qi].p[2] = nxt
		}
		start = end
	}
}
