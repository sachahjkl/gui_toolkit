package render

import "core:math"
import "core:os"
import "core:thread"
import turn "../turn"

// The CPU rasteriser of the CPU stage (cpu_stage.odin, src/md/infrastructure/cpu-first-frames.md): a frame's instances
// drawn as rect.wgsl's ps_main and slug.wgsl's ps_slug / ps_slug_dual draw them, pixel for pixel, with the same formulas.
// The frame is kept premultiplied in f32, in the target's values (linear light or sRGB), and blended as the pipelines
// blend (SrcAlpha, OneMinusSrcAlpha; per channel for text with colour stripes).
// What it does not draw (layers, filter passes, blend modes, planes, pictures, application shaders) leaves the frame
// inexact (Cpu_Stage.exact): the GPU's next frame shows it.

@(private) CR_SPACE_LINEAR :: 0
@(private) CR_SPACE_SRGB :: 1

@(private)
Cr_Mat :: struct { a, b, c, d, e, f: f32 }   // x' = a x + c y + e, y' = b x + d y + f

@(private)
cr_apply :: #force_inline proc "contextless" (m: Cr_Mat, p: [2]f32) -> [2]f32 {
	return {m.a * p.x + m.c * p.y + m.e, m.b * p.x + m.d * p.y + m.f}
}

@(private)
cr_invert :: proc "contextless" (m: Cr_Mat) -> (Cr_Mat, bool) {
	det := m.a * m.d - m.b * m.c
	if abs(det) < 1e-12 { return {}, false }
	id := 1 / det
	a, b, c, d := m.d * id, -m.b * id, -m.c * id, m.a * id
	return {a, b, c, d, -(a * m.e + c * m.f), -(b * m.e + d * m.f)}, true
}

// What every pixel of a frame reads: rect.wgsl's Globals.
@(private)
Cr_Globals :: struct {
	corner_n, corner_boost: f32,
	space:         u32,
	text_gamma, text_contrast, text_exponent: f32,
	dual:          bool,   // the frame blends text per colour stripe (Frame_Data.subpixel, the frame's own target)
	dual_atlas:    bool,   // ... atlas glyphs too: Direct3D 11's per-channel blend (rect_dual.wgsl); WebGPU averages them
}

@(private)
Cr :: struct {
	r:     ^Renderer,
	f:     ^Frame_Data,
	g:     Cr_Globals,
	px:    [][4]f32,
	w, h:  int,
	exact: bool,
	rows:  [2]int,   // the band this state draws: [first, end)
}

// Draws `f` into the CPU frame (cpu_frame_begin cleared it). The frame's own target only: false when something was
// left out.
@(private)
cpu_raster_frame :: proc(r: ^Renderer, f: Frame_Data) -> (exact: bool) {
	f := f
	sm := clamp(r.corner_smoothing, 0, 1)
	tg: f32
	switch r.text.curve {
	case .None: tg = 0
	case .Srgb: tg = -1
	case .Power: tg = max(r.text.gamma, TEXT_GAMMA_MIN)
	}
	g := Cr_Globals{
		corner_n = 2 + CORNER_N_SMOOTHING * sm, corner_boost = 1 + CORNER_BOOST_SMOOTHING * sm,
		space = u32(r.space), text_gamma = tg, text_contrast = r.text.contrast,
		text_exponent = max(r.text.coverage_exponent, TEXT_COVERAGE_EXPONENT_MIN),
		dual = f.subpixel,
		dual_atlas = f.subpixel && !USE_WGPU,
	}
	w, h := r.size.x, r.size.y
	if len(r.cpu.frame) < w * h || w <= 0 || h <= 0 { return false }
	// Bands of rows, one thread each: every band draws every instance clipped to its rows, so each pixel gets its
	// instances in their order. A frame of a few hundred thousand pixels takes milliseconds a band.
	if r.cpu.cores == 0 { r.cpu.cores = os.get_processor_core_count() }   // (once: the stage's first frame, or the shadow's)
	bands := clamp(min(r.cpu.cores, CR_BANDS_MAX), 1, max(h / CR_BAND_MIN_ROWS, 1))
	states: [CR_BANDS_MAX]Cr
	threads: [CR_BANDS_MAX]^thread.Thread
	for i in 0 ..< bands {
		states[i] = Cr{r = r, f = &f, g = g, px = r.cpu.frame[:], w = w, h = h, exact = true, rows = {h * i / bands, h * (i + 1) / bands}}
		if i > 0 { threads[i] = thread.create_and_start_with_poly_data(&states[i], cr_band_run) }
	}
	cr_band_run(&states[0])
	exact = states[0].exact
	for i in 1 ..< bands {
		if threads[i] == nil { cr_band_run(&states[i]) } else { thread.join(threads[i]); thread.destroy(threads[i]) }
		exact = exact && states[i].exact
	}
	return
}

// The most bands a frame is cut into, and the fewest rows a band has.
@(private) CR_BANDS_MAX :: 8
@(private) CR_BAND_MIN_ROWS :: 32

// One band's rows of the frame (Cr.rows): every batch of the frame target, in order.
@(private)
cr_band_run :: proc(s: ^Cr) {
	f := s.f
	for b in f.batches {
		if b.op > 0 {
			op := f.ops[b.op - 1]
			if op.kind != .Clear && op.kind != .Mips { s.exact = false }
			continue
		}
		if b.count == 0 { continue }
		if b.target != 0 || b.replay > 0 || b.app > 0 || b.backdrop != 0 { s.exact = false; continue }
		rc := [4]int{
			int(clamp(b.clip.x, 0, f32(s.w))), int(clamp(b.clip.y, 0, f32(s.h))),
			int(clamp(b.clip.z, 0, f32(s.w))), int(clamp(b.clip.w, 0, f32(s.h))),
		}
		rc[1], rc[3] = max(rc[1], s.rows[0]), min(rc[3], s.rows[1])
		if rc[2] <= rc[0] || rc[3] <= rc[1] { continue }
		end := min(b.first + b.count, len(f.insts))
		for i in b.first ..< end {
			inst := &f.insts[i]
			if u32(inst.use_tex + 0.5) == KIND_SLUG {
				cr_slug(s, inst, rc)
			} else {
				cr_inst(s, inst, b, rc)
			}
		}
	}
}

////////////////////////////////
// The shaders' helpers (rect.wgsl)

@(private)
cr_saturate :: #force_inline proc "contextless" (x: f32) -> f32 { return clamp(x, 0, 1) }

@(private)
cr_srgb_encode1 :: proc "contextless" (c0: f32) -> f32 {
	c := clamp(c0, 0, 1)
	return c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1.0 / 2.4) - 0.055
}

@(private)
cr_srgb_decode1 :: proc "contextless" (c0: f32) -> f32 {
	c := clamp(c0, 0, 1)
	return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
}

@(private)
cr_encode3 :: proc "contextless" (c: [3]f32) -> [3]f32 { return {cr_srgb_encode1(c.x), cr_srgb_encode1(c.y), cr_srgb_encode1(c.z)} }
@(private)
cr_decode3 :: proc "contextless" (c: [3]f32) -> [3]f32 { return {cr_srgb_decode1(c.x), cr_srgb_decode1(c.y), cr_srgb_decode1(c.z)} }

@(private)
cr_convert :: proc "contextless" (c: [3]f32, from, to: u32) -> [3]f32 {
	if from == to { return c }
	if to == CR_SPACE_SRGB { return cr_encode3(c) }
	return cr_decode3(c)
}

@(private)
cr_text_to_luma :: proc "contextless" (g: ^Cr_Globals, x: f32) -> f32 {
	return g.text_gamma < 0 ? cr_srgb_decode1(x) : math.pow(max(x, 0), g.text_gamma)
}

@(private)
cr_text_from_luma :: proc "contextless" (g: ^Cr_Globals, l: f32) -> f32 {
	return g.text_gamma < 0 ? cr_srgb_encode1(l) : math.pow(max(l, 0), 1 / g.text_gamma)
}

@(private)
cr_lerp_space :: #force_inline proc "contextless" (g: ^Cr_Globals, flags: u32) -> u32 {
	if flags & FLAG_LERP_SRGB != 0 { return CR_SPACE_SRGB }
	if flags & FLAG_LERP_LINEAR != 0 { return CR_SPACE_LINEAR }
	return g.space
}

// The text correction of the vertex shaders (Skia's SkMaskGamma), per glyph: ls, ld, bd, 1 / (bs - bd), and the contrast.
@(private)
Cr_Text :: struct { corr: [4]f32, contrast: f32, on: bool }

@(private)
cr_text_prepare :: proc "contextless" (g: ^Cr_Globals, c0: [4]f32) -> (t: Cr_Text) {
	if g.text_gamma == 0 { return }
	e := cr_encode3(c0.rgb)
	l3: [3]f32
	if g.text_gamma < 0 { l3 = cr_decode3(e) } else { for k in 0 ..< 3 { l3[k] = math.pow(max(e[k], 0), g.text_gamma) } }
	s := cr_text_from_luma(g, 0.2126 * l3.x + 0.7152 * l3.y + 0.0722 * l3.z)
	d := 1 - s
	if abs(s - d) < 1.0 / 256 { return }
	ls, ld := cr_text_to_luma(g, s), cr_text_to_luma(g, d)
	bs := g.space == CR_SPACE_LINEAR ? cr_srgb_decode1(s) : s
	bd := g.space == CR_SPACE_LINEAR ? cr_srgb_decode1(d) : d
	t.corr = {ls, ld, bd, 1 / (bs - bd)}
	t.contrast = g.text_contrast * ld
	t.on = true
	return
}

// rect.wgsl's text_coverage, slug.wgsl's slug_text_coverage.
@(private)
cr_text_coverage :: proc "contextless" (g: ^Cr_Globals, t: ^Cr_Text, a0: f32) -> f32 {
	a := a0
	if g.text_exponent != 1 { a = math.pow(max(a, 0), g.text_exponent) }
	if !t.on { return a }
	boosted := a + (1 - a) * t.contrast * a
	lin := t.corr.x * boosted + (1 - boosted) * t.corr.y
	o := cr_text_from_luma(g, lin)
	if g.space == CR_SPACE_LINEAR { o = cr_srgb_decode1(o) }
	return cr_saturate((o - t.corr.z) * t.corr.w)
}

// Rounded-rect distance (x) and its gradient's direction (y, z): rect_sdf_dir.
@(private)
cr_rect_sdf_dir :: proc "contextless" (p, half_size: [2]f32, r0, n, boost: f32) -> [3]f32 {
	r := min(r0 * boost, min(half_size.x, half_size.y))
	d := [2]f32{abs(p.x), abs(p.y)} - half_size + r
	q := [2]f32{max(d.x, 0), max(d.y, 0)}
	outside := math.sqrt(q.x * q.x + q.y * q.y)
	if n > 2.01 {
		outside = math.pow(math.pow(max(q.x, 1e-6), n) + math.pow(max(q.y, 1e-6), n), 1 / n)
	}
	dir: [2]f32
	if q.x > 0 && q.y > 0 {
		l := math.sqrt(q.x * q.x + q.y * q.y)
		dir = q / l
	} else if d.x > d.y {
		dir = {1, 0}
	} else {
		dir = {0, 1}
	}
	if p.x < 0 { dir.x = -dir.x }
	if p.y < 0 { dir.y = -dir.y }
	return {min(max(d.x, d.y), 0) + outside - r, dir.x, dir.y}
}

@(private)
cr_to_px :: #force_inline proc "contextless" (s: f32, dir, dpx, dpy: [2]f32) -> f32 {
	a := dir.x * dpx.x + dir.y * dpx.y
	b := dir.x * dpy.x + dir.y * dpy.y
	return s / max(math.sqrt(a * a + b * b), 1e-6)
}

@(private)
cr_corner_radius :: #force_inline proc "contextless" (p: [2]f32, radii: [4]f32) -> f32 {
	if p.x < 0 { return p.y < 0 ? radii.x : radii.y }
	return p.y < 0 ? radii.z : radii.w
}

@(private)
cr_ellipse_sdf :: proc "contextless" (p, r0: [2]f32) -> f32 {
	r := [2]f32{max(r0.x, 1e-4), max(r0.y, 1e-4)}
	if abs(r.x - r.y) < 1e-4 { return math.sqrt(p.x * p.x + p.y * p.y) - r.x }
	k0v := p / r
	k1v := p / (r * r)
	k0 := math.sqrt(k0v.x * k0v.x + k0v.y * k0v.y)
	k1 := math.sqrt(k1v.x * k1v.x + k1v.y * k1v.y)
	if k1 > 1e-6 { return k0 * (k0 - 1) / k1 }
	return -min(r.x, r.y)
}

@(private)
cr_winding_inside :: #force_inline proc "contextless" (winding: int, evenodd: bool) -> bool {
	return evenodd ? winding & 1 != 0 : winding != 0
}

// polygon_sdf: the distance to the edges where the fill changes (rect.wgsl explains the two passes).
@(private)
cr_polygon_sdf :: proc "contextless" (pts: [][2]f32, p: [2]f32, first, count0: u32, evenodd: bool) -> f32 {
	count := min(count0, 4096)
	if count < 3 || int(first + count) > len(pts) { return 1e9 }
	ps := pts[first:][:count]
	winding := 0
	a := ps[count - 1]
	starts := a.x > POLYGON_BREAK
	for b in ps {
		if b.x > POLYGON_BREAK { starts = true; continue }
		if starts { a = b; starts = false; continue }
		e := b - a
		w := p - a
		side := e.x * w.y - e.y * w.x
		if a.y <= p.y {
			if b.y > p.y && side > 0 { winding += 1 }
		} else if b.y <= p.y && side < 0 {
			winding -= 1
		}
		a = b
	}
	inside := cr_winding_inside(winding, evenodd)
	d: f32 = 1e30
	a = ps[count - 1]
	starts = a.x > POLYGON_BREAK
	for b in ps {
		if b.x > POLYGON_BREAK { starts = true; continue }
		if starts { a = b; starts = false; continue }
		e := b - a
		w := p - a
		side := e.x * w.y - e.y * w.x
		if side == 0 { side = -e.y }
		if side == 0 { side = e.x }
		if cr_winding_inside(winding - (side > 0 ? 1 : -1), evenodd) != inside {
			t := cr_saturate((w.x * e.x + w.y * e.y) / max(e.x * e.x + e.y * e.y, 1e-12))
			q := w - e * t
			d = min(d, q.x * q.x + q.y * q.y)
		}
		a = b
	}
	return inside ? -math.sqrt(d) : math.sqrt(d)
}

@(private)
cr_clip_sdf :: proc "contextless" (s: ^Cr, c: ^Clip_Data, lp: [2]f32) -> f32 {
	if c.kind == CLIP_ELLIPSE { return cr_ellipse_sdf(lp - c.center, c.half_size) }
	if c.kind == CLIP_POLYGON { return cr_polygon_sdf(s.f.points, lp, c.first, c.count, c.flags & CLIP_EVENODD != 0) }
	circle := c.flags & CLIP_CIRCLE != 0
	q := lp - c.center
	return cr_rect_sdf_dir(q, c.half_size, cr_corner_radius(q, c.radii), circle ? 2 : s.g.corner_n, circle ? 1 : s.g.corner_boost).x
}

// clip_coverage: the nested clip shapes of the frame's table at a screen position.
@(private)
cr_clip_coverage :: proc "contextless" (s: ^Cr, screen: [2]f32, idx0: u32) -> f32 {
	coverage: f32 = 1
	idx := idx0
	for k := 0; k < MAX_CLIP_DEPTH && idx != 0 && int(idx) < len(s.f.clips); k += 1 {
		c := &s.f.clips[idx]
		lp := [2]f32{c.inv[0] * screen.x + c.inv[2] * screen.y + c.inv[4], c.inv[1] * screen.x + c.inv[3] * screen.y + c.inv[5]}
		coverage *= cr_saturate(0.5 - cr_clip_sdf(s, c, lp) * c.px)
		idx = c.parent
	}
	return coverage
}

////////////////////////////////
// Gradients

@(private)
cr_grad :: #force_inline proc "contextless" (s: ^Cr, k: u32) -> [4]f32 {
	if int(k) >= len(s.f.grads) { return {} }
	return s.f.grads[k]
}

@(private)
cr_oklab_to_linear :: proc "contextless" (c: [3]f32) -> [3]f32 {
	l_ := c.x + 0.3963377774 * c.y + 0.2158037573 * c.z
	m_ := c.x - 0.1055613458 * c.y - 0.0638541728 * c.z
	s_ := c.x - 0.0894841775 * c.y - 1.2914855480 * c.z
	l, m, s := l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
	return {4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
	        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
	        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s}
}

@(private)
cr_lab_to_linear :: proc "contextless" (c: [3]f32) -> [3]f32 {
	fy := (c.x + 16) / 116
	fx := fy + c.y / 500
	fz := fy - c.z / 200
	e: f32 = 216.0 / 24389.0
	k: f32 = 24389.0 / 27.0
	x := fx * fx * fx > e ? fx * fx * fx : (116 * fx - 16) / k
	y := c.x > k * e ? fy * fy * fy : c.x / k
	z := fz * fz * fz > e ? fz * fz * fz : (116 * fz - 16) / k
	xyz := [3]f32{x * 0.3457 / 0.3585, y, z * (1 - 0.3457 - 0.3585) / 0.3585}
	d65 := [3]f32{ 0.9554734527042182 * xyz.x - 0.023098536874261423 * xyz.y + 0.0632593086610217 * xyz.z,
	              -0.028369706963208136 * xyz.x + 1.0099954580058226 * xyz.y + 0.021041398966943008 * xyz.z,
	               0.012314001688319899 * xyz.x - 0.020507696433477912 * xyz.y + 1.3303659366080753 * xyz.z}
	return { 3.2409699419045226 * d65.x - 1.537383177570094 * d65.y - 0.4986107602930034 * d65.z,
	        -0.9692436362808796 * d65.x + 1.8759675015077202 * d65.y + 0.04155505740717559 * d65.z,
	         0.05563007969699366 * d65.x - 0.20397695888897652 * d65.y + 1.0569715142428786 * d65.z}
}

@(private)
cr_hsl_to_srgb :: proc "contextless" (c: [3]f32) -> [3]f32 {
	h := c.x - 360 * math.floor(c.x / 360)
	a := c.y * min(c.z, 1 - c.z)
	out: [3]f32
	for n, i in ([3]f32{0, 8, 4}) {
		kv := math.mod(n + h / 30, 12)
		out[i] = c.z - a * max(-1, min(min(kv - 3, 9 - kv), 1))
	}
	return out
}

@(private)
cr_hwb_to_srgb :: proc "contextless" (c: [3]f32) -> [3]f32 {
	w, b := c.y, c.z
	if w + b >= 1 { g2 := w / (w + b); return {g2, g2, g2} }
	return cr_hsl_to_srgb({c.x, 1, 0.5}) * (1 - w - b) + w
}

// gradient_color: straight, in linear light or sRGB values (`srgb`).
@(private)
cr_gradient_color :: proc "contextless" (s: ^Cr, p: [2]f32, h: u32) -> (color: [4]f32, srgb, dither: bool) {
	hd := transmute([4]u32)cr_grad(s, h)
	flags, space := hd.x, hd.y
	n := min(hd.w, MAX_GRADIENT_STOPS)
	srgb = space == 0 || space == 6 || space == 7
	dither = flags & GRAD_DITHER != 0
	geom, tile, per := cr_grad(s, h + 1), cr_grad(s, h + 2), cr_grad(s, h + 3)
	q := p - tile.xy
	if tile.z > 0 {
		period := tile.z + per.x
		if flags & GRAD_REPEAT_X != 0 { q.x -= math.floor(q.x / period) * period }
		if q.x < 0 || q.x > tile.z { return }
	}
	if tile.w > 0 {
		period := tile.w + per.y
		if flags & GRAD_REPEAT_Y != 0 { q.y -= math.floor(q.y / period) * period }
		if q.y < 0 || q.y > tile.w { return }
	}
	t: f32
	switch flags & 0xff {
	case GRAD_RADIAL:
		v := (q - geom.xy) / [2]f32{max(abs(geom.z), 1e-4), max(abs(geom.w), 1e-4)}
		t = math.sqrt(v.x * v.x + v.y * v.y)
	case GRAD_CONIC:
		d := q - geom.xy
		a := math.atan2(d.x, -d.y)
		v := (a - geom.z) / 6.283185307179586
		t = v - math.floor(v)
	case:
		d := geom.zw - geom.xy
		t = ((q.x - geom.x) * d.x + (q.y - geom.y) * d.y) / max(d.x * d.x + d.y * d.y, 1e-12)
	}
	if flags & GRAD_REPEATING != 0 {
		span := per.w - per.z
		if span > 1e-6 { v := (t - per.z) / span; t = per.z + (v - math.floor(v)) * span }
	}
	s0 := h + GRAD_HEADER
	c: [4]f32
	if n <= 1 || t <= cr_grad(s, s0 + 1).x {
		c = cr_grad(s, s0)
	} else if t >= cr_grad(s, s0 + 2 * (n - 1) + 1).x {
		c = cr_grad(s, s0 + 2 * (n - 1))
	} else {
		k: u32 = 1
		for ; k < n - 1; k += 1 { if t < cr_grad(s, s0 + 2 * k + 1).x { break } }
		pa := cr_grad(s, s0 + 2 * (k - 1) + 1)
		pb := cr_grad(s, s0 + 2 * k + 1).x
		fr: f32 = 1
		if pb > pa.x { fr = (t - pa.x) / (pb - pa.x) }
		if pa.y >= 0 {
			hint := pa.y
			if hint <= 0 { fr = 1 } else if hint >= 1 { fr = fr >= 1 ? 1 : 0 } else { fr = math.pow(cr_saturate(fr), math.ln(f32(0.5)) / math.ln(hint)) }
		}
		ca, cb := cr_grad(s, s0 + 2 * (k - 1)), cr_grad(s, s0 + 2 * k)
		c = ca + (cb - ca) * fr
	}
	if c.a <= 1e-7 { return }
	v := c.rgb
	switch space {
	case 3, 5: v = {v.x / c.a, v.y / c.a, v.z}           // OKLCH, LCH: the hue is not premultiplied
	case 6, 7: v = {v.x, v.y / c.a, v.z / c.a}           // HSL, HWB
	case: v = v / c.a
	}
	rgb: [3]f32
	switch space {
	case 1: rgb = v
	case 2: rgb = cr_oklab_to_linear(v)
	case 3: s_h, c_h := turn.sincos(turn.from_degrees(v.z)); rgb = cr_oklab_to_linear({v.x, v.y * c_h, v.y * s_h})
	case 4: rgb = cr_lab_to_linear(v)
	case 5: s_h, c_h := turn.sincos(turn.from_degrees(v.z)); rgb = cr_lab_to_linear({v.x, v.y * c_h, v.y * s_h})
	case 6: rgb = cr_hsl_to_srgb(v)
	case 7: rgb = cr_hwb_to_srgb(v)
	case: rgb = v
	}
	color = {cr_saturate(rgb.x), cr_saturate(rgb.y), cr_saturate(rgb.z), cr_saturate(c.a)}
	return
}

@(private)
cr_dither_noise :: proc "contextless" (x, y: int) -> f32 {
	hsh := u32(x) * 1973 + u32(y) * 9277 + 26699
	hsh = (hsh ~ (hsh >> 13)) * 1274126177
	hsh = hsh ~ (hsh >> 16)
	a := f32(hsh & 0xffff) / 65535
	b := f32(hsh >> 16) / 65535
	return (a + b - 1) / 255
}

////////////////////////////////
// Shadows

@(private)
cr_erf :: proc "contextless" (x0: f32) -> f32 {
	s: f32 = x0 < 0 ? -1 : (x0 > 0 ? 1 : 0)
	x := abs(x0)
	t := 1 / (1 + 0.3275911 * x)
	y := 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
	return s * y
}

@(private)
cr_phi :: #force_inline proc "contextless" (x: f32) -> f32 { return 0.5 + 0.5 * cr_erf(x * 0.7071067811865476) }

@(private)
cr_arc_part :: proc "contextless" (p, center: [2]f32, r, sx, sy, sigma: f32) -> f32 {
	if r <= 0 { return 0 }
	s0 := sy * (p.y - 4 * sigma - center.y) / r
	s1 := sy * (p.y + 4 * sigma - center.y) / r
	lo := clamp(min(s0, s1), 0, 1)
	hi := clamp(max(s0, s1), 0, 1)
	if hi <= lo { return 0 }
	inv := 1 / sigma
	xa := sx < 0 ? center.x - r : center.x
	xb := sx < 0 ? center.x : center.x + r
	if (p.x - xa) * inv < -5 { return 0 }
	if (p.x - xb) * inv > 5 { return abs(cr_phi((p.y - (center.y + sy * r * lo)) * inv) - cr_phi((p.y - (center.y + sy * r * hi)) * inv)) }
	a0, a1 := math.asin(lo), math.asin(hi)
	SAMPLES :: 16
	hh := (a1 - a0) / SAMPLES
	acc: f32 = 0
	for k in 0 ..< SAMPLES {
		a := a0 + (f32(k) + 0.5) * hh
		sa, ca := math.sin(a), math.cos(a)
		dy := (p.y - (center.y + sy * r * sa)) * inv
		acc += math.exp(-0.5 * dy * dy) * cr_phi((p.x - (center.x + sx * r * ca)) * inv) * ca
	}
	return acc * hh * r * inv * 0.3989422804014327
}

@(private)
cr_blurred_rrect :: proc "contextless" (p0: [2]f32, rect, radii: [4]f32, sigma: f32) -> f32 {
	c := (rect.xy + rect.zw) * 0.5
	hs := [2]f32{max((rect.z - rect.x) * 0.5, 0), max((rect.w - rect.y) * 0.5, 0)}
	if hs.x <= 0 || hs.y <= 0 { return 0 }
	p := p0 - c
	m := min(hs.x, hs.y)
	r := [4]f32{min(max(radii.x, 0), m), min(max(radii.y, 0), m), min(max(radii.z, 0), m), min(max(radii.w, 0), m)}
	inv := 1 / sigma
	left := cr_phi((p.x + hs.x) * inv) * max(cr_phi((p.y + hs.y - r.x) * inv) - cr_phi((p.y - hs.y + r.y) * inv), 0) +
		cr_arc_part(p, {-hs.x + r.x, -hs.y + r.x}, r.x, -1, -1, sigma) +
		cr_arc_part(p, {-hs.x + r.y, hs.y - r.y}, r.y, -1, 1, sigma)
	right := cr_phi((p.x - hs.x) * inv) * max(cr_phi((p.y + hs.y - r.z) * inv) - cr_phi((p.y - hs.y + r.w) * inv), 0) +
		cr_arc_part(p, {hs.x - r.z, -hs.y + r.z}, r.z, 1, -1, sigma) +
		cr_arc_part(p, {hs.x - r.w, hs.y - r.w}, r.w, 1, 1, sigma)
	return cr_saturate(left - right)
}

@(private)
cr_rrect_coverage :: proc "contextless" (p: [2]f32, rect, radii: [4]f32, dpx, dpy: [2]f32) -> f32 {
	c := (rect.xy + rect.zw) * 0.5
	hs := [2]f32{max((rect.z - rect.x) * 0.5, 0), max((rect.w - rect.y) * 0.5, 0)}
	q := p - c
	sd := cr_rect_sdf_dir(q, hs, cr_corner_radius(q, radii), 2, 1)
	return cr_saturate(0.5 - cr_to_px(sd.x, sd.yz, dpx, dpy))
}

////////////////////////////////
// Textures

// The CPU copy of texture `t` and its size: nil when none is kept.
@(private)
cr_texels :: proc "contextless" (s: ^Cr, t: Texture) -> (texels: []u8, td: ^Texture_Data) {
	r := s.r
	if int(t) <= 0 || int(t) >= len(r.textures) || int(t) >= len(r.cpu.texels) { return nil, nil }
	return r.cpu.texels[int(t)], &r.textures[int(t)]
}

// A texel of an RGBA texture as the shader samples it: premultiplied, decoded from sRGB when stored so (linear space).
@(private)
cr_rgba_texel :: #force_inline proc "contextless" (texels: []u8, td: ^Texture_Data, x, y: int) -> [4]f32 {
	i := (y * td.w + x) * 4
	px := texels[i:][:4]
	if td.space == .Srgb { return {f32(px[0]) / 255, f32(px[1]) / 255, f32(px[2]) / 255, f32(px[3]) / 255} }
	return {cr_srgb_decode1(f32(px[0]) / 255), cr_srgb_decode1(f32(px[1]) / 255), cr_srgb_decode1(f32(px[2]) / 255), f32(px[3]) / 255}
}

// A bilinear sample at texel position `tc` (continuous, texels), clamped to the edge or wrapped.
@(private)
cr_rgba_bilinear :: proc "contextless" (texels: []u8, td: ^Texture_Data, tc: [2]f32, wrap: bool) -> [4]f32 {
	x := tc.x - 0.5
	y := tc.y - 0.5
	x0f, y0f := math.floor(x), math.floor(y)
	fx, fy := x - x0f, y - y0f
	x0, y0 := int(x0f), int(y0f)
	at :: proc "contextless" (v, n: int, wrap: bool) -> int {
		if wrap { m := v % n; return m < 0 ? m + n : m }
		return clamp(v, 0, n - 1)
	}
	xa, xb := at(x0, td.w, wrap), at(x0 + 1, td.w, wrap)
	ya, yb := at(y0, td.h, wrap), at(y0 + 1, td.h, wrap)
	t00 := cr_rgba_texel(texels, td, xa, ya)
	t10 := cr_rgba_texel(texels, td, xb, ya)
	t01 := cr_rgba_texel(texels, td, xa, yb)
	t11 := cr_rgba_texel(texels, td, xb, yb)
	return (t00 * (1 - fx) + t10 * fx) * (1 - fy) + (t01 * (1 - fx) + t11 * fx) * fy
}

@(private)
cr_r8_bilinear :: proc "contextless" (texels: []u8, td: ^Texture_Data, tc: [2]f32) -> f32 {
	x := tc.x - 0.5
	y := tc.y - 0.5
	x0f, y0f := math.floor(x), math.floor(y)
	fx, fy := x - x0f, y - y0f
	x0, y0 := clamp(int(x0f), 0, td.w - 1), clamp(int(y0f), 0, td.h - 1)
	x1, y1 := clamp(int(x0f) + 1, 0, td.w - 1), clamp(int(y0f) + 1, 0, td.h - 1)
	v :: #force_inline proc "contextless" (t: []u8, w, x, y: int) -> f32 { return f32(t[y * w + x]) / 255 }
	return (v(texels, td.w, x0, y0) * (1 - fx) + v(texels, td.w, x1, y0) * fx) * (1 - fy) + (v(texels, td.w, x0, y1) * (1 - fx) + v(texels, td.w, x1, y1) * fx) * fy
}

////////////////////////////////
// An instance of rect.wgsl

// Blends straight `c` (in the target's values) over the frame's pixel, as the pipelines do.
@(private)
cr_blend :: #force_inline proc "contextless" (dst: ^[4]f32, c: [4]f32) {
	a := cr_saturate(c.a)
	if a <= 0 { return }
	rgb := [3]f32{cr_saturate(c.r), cr_saturate(c.g), cr_saturate(c.b)}
	dst.rgb = rgb * a + dst.rgb * (1 - a)
	dst.a = a + dst.a * (1 - a)
}

@(private)
cr_inst :: proc(s: ^Cr, inst: ^Rect_Inst, b: Batch, rc: [4]int) {
	g := &s.g
	kind := u32(inst.use_tex + 0.5)
	flags := inst.flags
	if flags & (FLAG_PROJECT | FLAG_BLEND | FLAG_LAYER | FLAG_SCREEN) != 0 { s.exact = false; return }
	dst := inst.dst
	size := dst.zw - dst.xy
	if size.x == 0 || size.y == 0 { return }
	xf := inst.xform != 0
	m := Cr_Mat{1, 0, 0, 1, 0, 0}
	if xf {
		if int(inst.xform) >= len(s.f.xforms) { return }
		x := s.f.xforms[inst.xform].m
		m = {x[0], x[1], x[2], x[3], x[4], x[5]}
	}
	inv, ok := cr_invert(m)
	if !ok { return }
	// the quad: dst, grown by one screen pixel under a transform (vs_main)
	tmin, tmax := [2]f32{0, 0}, [2]f32{1, 1}
	if xf {
		det := m.a * m.d - m.b * m.c
		grow := [2]f32{math.sqrt(m.c * m.c + m.d * m.d), math.sqrt(m.a * m.a + m.b * m.b)} / abs(det)
		gt := grow / [2]f32{max(abs(size.x), 1e-6), max(abs(size.y), 1e-6)}
		tmin, tmax = -gt, 1 + gt
	}
	// the pixels whose centre is in the quad (a bounding box, then a test per pixel under a transform)
	x0, y0, x1, y1: int
	if xf {
		lo, hi := [2]f32{1e30, 1e30}, [2]f32{-1e30, -1e30}
		for c in ([4][2]f32{{tmin.x, tmin.y}, {tmax.x, tmin.y}, {tmin.x, tmax.y}, {tmax.x, tmax.y}}) {
			p := cr_apply(m, dst.xy + c * size)
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
		x0, y0 = int(math.floor(lo.x)), int(math.floor(lo.y))
		x1, y1 = int(math.ceil(hi.x)), int(math.ceil(hi.y))
	} else {
		lx, hx := min(dst.x, dst.z), max(dst.x, dst.z)
		ly, hy := min(dst.y, dst.w), max(dst.y, dst.w)
		x0, x1 = int(math.ceil(lx - 0.5)), int(math.ceil(hx - 0.5))
		y0, y1 = int(math.ceil(ly - 0.5)), int(math.ceil(hy - 0.5))
	}
	x0, y0 = max(x0, rc[0]), max(y0, rc[1])
	x1, y1 = min(x1, rc[2]), min(y1, rc[3])
	if x1 <= x0 || y1 <= y0 { return }

	// derivatives (constant per primitive): local units per screen pixel
	dpx := [2]f32{1, 0}
	dpy := [2]f32{0, 1}
	if xf { dpx, dpy = {inv.a, inv.b}, {inv.c, inv.d} }
	tex := max(inst.tex_size, 1)
	ssz := inst.src.zw - inst.src.xy
	uvx := dpx * ssz / size / tex
	uvy := dpy * ssz / size / tex
	srcn := inst.src / tex
	// the corner colours, premultiplied, in the interpolation's values (vs_main)
	lerp := cr_lerp_space(g, flags)
	cs: [4][4]f32
	for k in 0 ..< 4 {
		c := kind >= KIND_GRADIENT ? inst.colors[0] : inst.colors[k]
		if lerp == CR_SPACE_SRGB { c.rgb = cr_encode3(c.rgb) }
		cs[k] = {c.r * c.a, c.g * c.a, c.b * c.a, c.a}
	}
	flat := cs[0] == cs[1] && cs[0] == cs[2] && cs[0] == cs[3]
	circle := flags & FLAG_CIRCLE != 0
	shape_n := circle ? 2 : g.corner_n
	shape_boost := circle ? 1 : g.corner_boost
	tex_space: u32 = flags & FLAG_TEX_SRGB != 0 ? CR_SPACE_SRGB : CR_SPACE_LINEAR
	text: Cr_Text
	if kind == KIND_GLYPH { text = cr_text_prepare(g, inst.colors[0]) }
	atlas, atlas_td := cr_texels(s, b.tex)
	image, image_td := cr_texels(s, b.image)
	if kind == KIND_GLYPH && atlas == nil { s.exact = false; return }
	if kind == KIND_IMAGE && image == nil { s.exact = false; return }
	half := size * 0.5
	// (a plain shape: a pixel more than one pixel inside its straight parts has coverage 1, or 0 inside a ring's hole,
	// with no distance to compute)
	plain := kind == KIND_SHAPE && !xf && inst.soft <= 1 && flat && inst.clip == 0
	hx, hy := abs(half.x), abs(half.y)
	rmax := min(max(inst.radii.x, inst.radii.y, inst.radii.z, inst.radii.w) * shape_boost, min(hx, hy))
	bx, by := hx - inst.border, hy - inst.border
	rin := min(max(max(inst.radii.x, inst.radii.y, inst.radii.z, inst.radii.w) - inst.border, 0) * shape_boost, max(min(bx, by), 0))
	for y in y0 ..< y1 {
		row := s.px[y * s.w:]
		for x in x0 ..< x1 {
			screen := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			t: [2]f32
			if xf {
				lp := cr_apply(inv, screen)
				t = (lp - dst.xy) / size
				if t.x < tmin.x || t.x > tmax.x || t.y < tmin.y || t.y > tmax.y { continue }
			} else {
				t = (screen - dst.xy) / size
			}
			p := (t - 0.5) * size
			lpos := inst.dst.xy + t * size
			uv := (inst.src.xy + t * ssz) / tex
			// the colour at this pixel: the strip's two triangles (v1-v2 is their diagonal)
			col := cs[0]
			if !flat {
				u := (t - tmin) / (tmax - tmin)
				if u.x + u.y <= 1 {
					col = cs[0] + (cs[2] - cs[0]) * u.x + (cs[1] - cs[0]) * u.y
				} else {
					col = cs[3] + (cs[1] - cs[3]) * (1 - u.x) + (cs[2] - cs[3]) * (1 - u.y)
				}
			}
			color: [4]f32
			lcd := [3]f32{1, 1, 1}   // (a pixel's share per colour stripe: rect.wgsl's lcd_weight)
			if col.a > 0 { color = {col.r / col.a, col.g / col.a, col.b / col.a, col.a} } else { color = {0, 0, 0, col.a} }
			color.rgb = cr_convert(color.rgb, lerp, g.space)
			if kind == KIND_SHADOW {
				sigma := inst.colors[3].x
				sflags := u32(inst.colors[3].y + 0.5)
				ld := math.sqrt(dpx.x * dpx.x + dpx.y * dpx.y)
				ly := math.sqrt(dpy.x * dpy.x + dpy.y * dpy.y)
				px_per_unit := 1 / max(math.sqrt(ld * ld + ly * ly) * 0.7071067811865476, 1e-6)
				other: f32 = 0
				if sflags & (SHADOW_INSET | SHADOW_HOLE) != 0 { other = cr_rrect_coverage(lpos, inst.colors[1], inst.colors[2], dpx, dpy) }
				keep := sflags & SHADOW_INSET != 0 ? other : 1 - other
				if keep <= 0 { continue }
				mask := sigma * px_per_unit < 0.33 ? cr_rrect_coverage(lpos, inst.src, inst.radii, dpx, dpy) : cr_blurred_rrect(lpos, inst.src, inst.radii, sigma)
				mask = sflags & SHADOW_INSET != 0 ? keep * (1 - mask) : keep * mask
				color.a *= mask
				if inst.clip != 0 { color.a *= cr_clip_coverage(s, screen, inst.clip) }
				cr_blend(&row[x], color)
				continue
			}
			dither := false
			if kind == KIND_GRADIENT {
				gc, gs, gd := cr_gradient_color(s, lpos, inst.aux)
				dither = gd
				color = {0, 0, 0, color.a * gc.a}
				color.rgb = cr_convert(gc.rgb, gs ? CR_SPACE_SRGB : CR_SPACE_LINEAR, g.space)
			}
			if kind == KIND_GLYPH {
				if flags & FLAG_LCD != 0 && !xf {
					page := tex
					tt := uv * page
					s0 := srcn.xy * page
					s1 := srcn.zw * page
					gx := int(min(s0.x + math.floor((tt.x - s0.x) / 3) * 3, s1.x - 3))
					gy := int(clamp(math.floor(tt.y), s0.y, s1.y - 1))
					c3: [3]f32
					for k in 0 ..< 3 {
						xx := clamp(gx + k, 0, atlas_td.w - 1)
						yy := clamp(gy, 0, atlas_td.h - 1)
						c3[k] = cr_text_coverage(g, &text, f32(atlas[yy * atlas_td.w + xx]) / 255)
					}
					mean := (c3.x + c3.y + c3.z) / 3
					if g.dual_atlas { lcd = c3 / max(mean, 1.0 / 1024) }
					color.a *= mean
				} else {
					h := 0.5 / tex
					cu := [2]f32{clamp(uv.x, srcn.x + h, srcn.z - h), clamp(uv.y, srcn.y + h, srcn.w - h)}
					color.a *= cr_text_coverage(g, &text, cr_r8_bilinear(atlas, atlas_td, cu * [2]f32{f32(atlas_td.w), f32(atlas_td.h)}))
				}
				if xf {
					sd := cr_rect_sdf_dir(p, half, 0, shape_n, shape_boost)
					color.a *= cr_saturate(0.5 - cr_to_px(sd.x, sd.yz, dpx, dpy))
				}
			} else {
				if kind == KIND_IMAGE {
					dim := [2]f32{f32(image_td.w), f32(image_td.h)}
					texel: [4]f32
					nearest := flags & FLAG_IMAGE_NEAREST != 0 || (flags & FLAG_IMAGE_PIXELATED != 0 && max(uvx.x * uvx.x + uvx.y * uvx.y, uvy.x * uvy.x + uvy.y * uvy.y) <= 1.001)
					if nearest {
						tc: [2]int
						if flags & FLAG_TILE != 0 {
							wx := uv.x - math.floor(uv.x / dim.x) * dim.x
							wy := uv.y - math.floor(uv.y / dim.y) * dim.y
							tc = {clamp(int(wx), 0, image_td.w - 1), clamp(int(wy), 0, image_td.h - 1)}
						} else {
							lo := [2]int{clamp(int(math.floor(min(inst.src.x, inst.src.z))), 0, image_td.w - 1), clamp(int(math.floor(min(inst.src.y, inst.src.w))), 0, image_td.h - 1)}
							hi := [2]int{clamp(int(math.ceil(max(inst.src.x, inst.src.z))) - 1, lo.x, image_td.w - 1), clamp(int(math.ceil(max(inst.src.y, inst.src.w))) - 1, lo.y, image_td.h - 1)}
							tc = {clamp(int(math.floor(uv.x)), lo.x, hi.x), clamp(int(math.floor(uv.y)), lo.y, hi.y)}
						}
						texel = cr_rgba_texel(image, image_td, tc.x, tc.y)
					} else if flags & FLAG_TILE != 0 {
						texel = cr_rgba_bilinear(image, image_td, uv, true)
					} else {
						// never filter in texels outside the source rect (sprite sheets)
						lo := inst.src.xy + 0.5
						hi := inst.src.zw - 0.5
						texel = cr_rgba_bilinear(image, image_td, {clamp(uv.x, min(lo.x, hi.x), max(lo.x, hi.x)), clamp(uv.y, min(lo.y, hi.y), max(lo.y, hi.y))}, false)
					}
					straight: [3]f32
					if texel.a > 0 { straight = texel.rgb / texel.a }
					color = {color.r, color.g, color.b, color.a * texel.a}
					color.rgb *= cr_convert(straight, tex_space, g.space)
				}
				if plain {
					ax, ay := abs(p.x), abs(p.y)
					if inst.border <= 0 {
						if (ax <= hx - 1 && ay <= hy - rmax - 1) || (ax <= hx - rmax - 1 && ay <= hy - 1) { cr_blend(&row[x], color); continue }
					} else if (ax <= bx - 1 && ay <= by - rin - 1) || (ax <= bx - rin - 1 && ay <= by - 1) {
						continue
					}
				}
				r := cr_corner_radius(p, inst.radii)
				border, soft := inst.border, inst.soft
				coverage: f32
				if soft > 1 {
					sd := cr_rect_sdf_dir(p, half - soft * 2, max(r - soft * 2, 0), shape_n, shape_boost).x
					e := clamp(sd / (soft * 2), 0, 1)
					coverage = 1 - e * e * (3 - 2 * e)
				} else {
					sd := cr_rect_sdf_dir(p, half, r, shape_n, shape_boost)
					d := sd.x
					if xf { d = cr_to_px(d, sd.yz, dpx, dpy) }
					coverage = cr_saturate(0.5 - d)
					if border > 0 {
						id := cr_rect_sdf_dir(p, half - border, max(r - border, 0), shape_n, shape_boost)
						inner := id.x
						if xf { inner = cr_to_px(inner, id.yz, dpx, dpy) }
						coverage *= cr_saturate(inner + 0.5)
						coverage = cr_edge_like_srgb(g, coverage, color.rgb, inst.src * tex)
					}
				}
				color.a *= coverage
			}
			if inst.clip != 0 { color.a *= cr_clip_coverage(s, screen, inst.clip) }
			if dither && color.a > 0 {
				nz := cr_dither_noise(x, y)
				if g.space == CR_SPACE_SRGB {
					color.rgb = {cr_saturate(color.r + nz), cr_saturate(color.g + nz), cr_saturate(color.b + nz)}
				} else {
					e := cr_encode3(color.rgb)
					color.rgb = cr_decode3(e + nz)
				}
			}
			if lcd != {1, 1, 1} {
				// (rect_dual.wgsl's blend: the colour by a factor per channel, the alpha by its own)
				a := cr_saturate(color.a)
				fac := [3]f32{cr_saturate(a * lcd.x), cr_saturate(a * lcd.y), cr_saturate(a * lcd.z)}
				px := &row[x]
				px.rgb = [3]f32{cr_saturate(color.r), cr_saturate(color.g), cr_saturate(color.b)} * fac + px.rgb * ([3]f32{1, 1, 1} - fac)
				px.a = a + px.a * (1 - a)
				continue
			}
			cr_blend(&row[x], color)
		}
	}
}

// edge_like_srgb: a ring's edge in a linear target weighed as a browser's in sRGB values over the backdrop `bd`.
@(private)
cr_edge_like_srgb :: proc "contextless" (g: ^Cr_Globals, c: f32, fg: [3]f32, bd: [4]f32) -> f32 {
	if g.space != CR_SPACE_LINEAR || bd.a <= 0 || c <= 0 || c >= 1 { return c }
	yf := cr_saturate(0.2126 * fg.x + 0.7152 * fg.y + 0.0722 * fg.z)
	yb := cr_saturate(0.2126 * bd.x + 0.7152 * bd.y + 0.0722 * bd.z)
	if abs(yf - yb) < 1e-4 { return c }
	sf, sb := cr_srgb_encode1(yf), cr_srgb_encode1(yb)
	want := cr_srgb_decode1(sb + c * (sf - sb))
	return cr_saturate((want - yb) / (yf - yb))
}

////////////////////////////////
// A glyph of slug.wgsl

@(private)
Cr_Slug :: struct {
	curves: []u8,   // RGBA16F texels
	bands:  []u8,   // RG16UI texels
	w:      int,    // texels per row of both
	rows:   int,
}

@(private)
cr_curve :: #force_inline proc "contextless" (sl: ^Cr_Slug, x, y: int) -> [4]f32 {
	if x < 0 || y < 0 || x >= sl.w || y >= sl.rows { return {} }
	h := ([^]f16)(raw_data(sl.curves))[(y * sl.w + x) * 4:][:4]
	return {f32(h[0]), f32(h[1]), f32(h[2]), f32(h[3])}
}

@(private)
cr_band :: #force_inline proc "contextless" (sl: ^Cr_Slug, x, y: int) -> [2]u32 {
	if x < 0 || y < 0 || x >= sl.w || y >= sl.rows { return {} }
	v := ([^]u16)(raw_data(sl.bands))[(y * sl.w + x) * 2:][:2]
	return {u32(v[0]), u32(v[1])}
}

@(private)
cr_root_code :: #force_inline proc "contextless" (y1, y2, y3: f32) -> u32 {
	i1 := transmute(u32)y1 >> 31
	i2 := transmute(u32)y2 >> 30
	i3 := transmute(u32)y3 >> 29
	shift := (i2 & 2) | (i1 & ~u32(2))
	shift = (i3 & 4) | (shift & ~u32(4))
	return (0x2E74 >> shift) & 0x0101
}

@(private)
cr_solve_horiz :: proc "contextless" (p12: [4]f32, p3: [2]f32) -> [2]f32 {
	a := p12.xy - p12.zw * 2 + p3
	b := p12.xy - p12.zw
	ra := 1 / a.y
	rb := 0.5 / b.y
	d := math.sqrt(max(b.y * b.y - a.y * p12.y, 0))
	t1 := (b.y - d) * ra
	t2 := (b.y + d) * ra
	if abs(a.y) < 1.0 / 65536 { t1 = p12.y * rb; t2 = t1 }
	return {(a.x * t1 - b.x * 2) * t1 + p12.x, (a.x * t2 - b.x * 2) * t2 + p12.x}
}

@(private)
cr_solve_vert :: proc "contextless" (p12: [4]f32, p3: [2]f32) -> [2]f32 {
	a := p12.xy - p12.zw * 2 + p3
	b := p12.xy - p12.zw
	ra := 1 / a.x
	rb := 0.5 / b.x
	d := math.sqrt(max(b.x * b.x - a.x * p12.x, 0))
	t1 := (b.x - d) * ra
	t2 := (b.x + d) * ra
	if abs(a.x) < 1.0 / 65536 { t1 = p12.x * rb; t2 = t1 }
	return {(a.y * t1 - b.y * 2) * t1 + p12.y, (a.y * t2 - b.y * 2) * t2 + p12.y}
}

@(private) CR_LOG_BAND_TEXTURE_WIDTH :: 12

@(private)
cr_band_loc :: #force_inline proc "contextless" (glyph: [2]int, offset: u32) -> [2]int {
	loc := [2]int{glyph.x + int(offset), glyph.y}
	loc.y += loc.x >> CR_LOG_BAND_TEXTURE_WIDTH
	loc.x &= (1 << CR_LOG_BAND_TEXTURE_WIDTH) - 1
	return loc
}

// SlugRender: the coverage of a sample at em coordinate `rc`.
@(private)
cr_slug_render :: proc "contextless" (sl: ^Cr_Slug, rc: [2]f32, band: [4]f32, glyph: [2]int, band_max0: [2]int, ppe: [2]f32, dk2: [2]f32) -> f32 {
	band_max := [2]int{band_max0.x, band_max0.y & 0xFF}
	bi := [2]int{clamp(int(rc.x * band.x + band.z), 0, band_max.x), clamp(int(rc.y * band.y + band.w), 0, band_max.y)}
	// (WGSL's vec2<i32>(f) truncates toward zero, as int() does; the clamp then holds negatives at 0)
	dk := dk2.x
	xcov, xwgt: f32
	hb := cr_band(sl, glyph.x + bi.y, glyph.y)
	hloc := cr_band_loc(glyph, hb.y)
	for ci in 0 ..< int(hb.x) {
		cl := cr_band(sl, hloc.x + ci, hloc.y)
		c0 := cr_curve(sl, int(cl.x), int(cl.y))
		p12 := c0 - [4]f32{rc.x, rc.y, rc.x, rc.y}
		p3 := cr_curve(sl, int(cl.x) + 1, int(cl.y)).xy - rc
		if max(max(p12.x, p12.z), p3.x) * ppe.x < -0.5 - abs(dk) { break }
		code := cr_root_code(p12.y, p12.w, p3.y)
		if code != 0 {
			r := cr_solve_horiz(p12, p3) * ppe.x
			if code & 1 != 0 {
				xcov += cr_saturate(r.x + 0.5 + dk)
				xwgt = max(xwgt, cr_saturate(1 - abs(r.x + dk) * 2))
			}
			if code > 1 {
				xcov -= cr_saturate(r.y + 0.5 - dk)
				xwgt = max(xwgt, cr_saturate(1 - abs(r.y - dk) * 2))
			}
		}
	}
	dk = dk2.y
	ycov, ywgt: f32
	vb := cr_band(sl, glyph.x + band_max.y + 1 + bi.x, glyph.y)
	vloc := cr_band_loc(glyph, vb.y)
	for ci in 0 ..< int(vb.x) {
		cl := cr_band(sl, vloc.x + ci, vloc.y)
		c0 := cr_curve(sl, int(cl.x), int(cl.y))
		p12 := c0 - [4]f32{rc.x, rc.y, rc.x, rc.y}
		p3 := cr_curve(sl, int(cl.x) + 1, int(cl.y)).xy - rc
		if max(max(p12.y, p12.w), p3.y) * ppe.y < -0.5 - abs(dk) { break }
		code := cr_root_code(p12.x, p12.z, p3.x)
		if code != 0 {
			r := cr_solve_vert(p12, p3) * ppe.y
			if code & 1 != 0 {
				ycov -= cr_saturate(r.x + 0.5 - dk)
				ywgt = max(ywgt, cr_saturate(1 - abs(r.x - dk) * 2))
			}
			if code > 1 {
				ycov += cr_saturate(r.y + 0.5 + dk)
				ywgt = max(ywgt, cr_saturate(1 - abs(r.y + dk) * 2))
			}
		}
	}
	cov := max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536), min(abs(xcov), abs(ycov)))
	return cr_saturate(cov)
}

@(private)
cr_slug :: proc(s: ^Cr, inst: ^Rect_Inst, rc: [4]int) {
	g := &s.g
	curves, ctd := cr_texels(s, s.f.slug_curves)
	bands, btd := cr_texels(s, s.f.slug_bands)
	if curves == nil || bands == nil { s.exact = false; return }
	sl := Cr_Slug{curves = curves, bands = bands, w = ctd.w, rows = min(ctd.h, btd.h)}
	xf := inst.xform != 0
	m := Cr_Mat{1, 0, 0, 1, 0, 0}
	if xf {
		if int(inst.xform) >= len(s.f.xforms) { return }
		x := s.f.xforms[inst.xform].m
		m = {x[0], x[1], x[2], x[3], x[4], x[5]}
	}
	inv, ok := cr_invert(m)
	if !ok { return }
	dst := inst.dst
	dsz := [2]f32{max(dst.z - dst.x, 1e-6), max(dst.w - dst.y, 1e-6)}
	esz := inst.src.zw - inst.src.xy
	// em per local unit (y up), then per screen pixel through the inverse
	jx := esz.x / dsz.x
	jy := -esz.y / dsz.y
	ex := [2]f32{inv.a * jx, inv.b * jy}   // d em / d screen x
	ey := [2]f32{inv.c * jx, inv.d * jy}   // d em / d screen y
	e := [2]f32{abs(ex.x) + abs(ey.x), abs(ex.y) + abs(ey.y)}   // fwidth
	if e.x <= 0 || e.y <= 0 { return }
	ppe := 1 / e
	// the box grown by half a screen pixel (SlugDilate) in local units
	gx := 0.5 * math.sqrt(inv.a * inv.a + inv.c * inv.c)
	gy := 0.5 * math.sqrt(inv.b * inv.b + inv.d * inv.d)
	if xf {
		// (the dilation is along each corner's normal on the screen: bounded by a pixel's half diagonal)
		gx = max(gx, 0.7072 * math.sqrt(inv.a * inv.a + inv.b * inv.b))
		gy = max(gy, 0.7072 * math.sqrt(inv.c * inv.c + inv.d * inv.d))
	}
	lo := dst.xy - [2]f32{gx, gy}
	hi := dst.zw + [2]f32{gx, gy}
	x0, y0, x1, y1: int
	if xf {
		blo, bhi := [2]f32{1e30, 1e30}, [2]f32{-1e30, -1e30}
		for c in ([4][2]f32{{lo.x, lo.y}, {hi.x, lo.y}, {lo.x, hi.y}, {hi.x, hi.y}}) {
			p := cr_apply(m, c)
			blo = {min(blo.x, p.x), min(blo.y, p.y)}
			bhi = {max(bhi.x, p.x), max(bhi.y, p.y)}
		}
		x0, y0, x1, y1 = int(math.floor(blo.x)), int(math.floor(blo.y)), int(math.ceil(bhi.x)), int(math.ceil(bhi.y))
	} else {
		x0, x1 = int(math.ceil(lo.x - 0.5)), int(math.ceil(hi.x - 0.5))
		y0, y1 = int(math.ceil(lo.y - 0.5)), int(math.ceil(hi.y - 0.5))
	}
	x0, y0 = max(x0, rc[0]), max(y0, rc[1])
	x1, y1 = min(x1, rc[2]), min(y1, rc[3])
	if x1 <= x0 || y1 <= y0 { return }
	glyph := [2]int{int(inst.aux & 0xFFFF), int(inst.aux >> 16)}
	band_max := [2]int{int(inst.flags & 0xFF), int((inst.flags >> 8) & 0xFF)}
	small := inst.colors[1]
	if m.b != 0 || m.c != 0 { small.z = 0 }
	dk := [2]f32{small.x + small.w, small.x}
	color := inst.colors[0]
	if g.space == CR_SPACE_SRGB { color.rgb = cr_encode3(color.rgb) }
	text := cr_text_prepare(g, inst.colors[0])
	dual := g.dual
	for y in y0 ..< y1 {
		row := s.px[y * s.w:]
		for x in x0 ..< x1 {
			screen := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			lp := cr_apply(inv, screen)
			if lp.x < lo.x || lp.x > hi.x || lp.y < lo.y || lp.y > hi.y { continue }
			tex := [2]f32{inst.src.x + (lp.x - dst.x) * jx, inst.src.w + (lp.y - dst.y) * jy}
			if dual {
				side := small.z / 3
				stripe :: proc "contextless" (sl: ^Cr_Slug, inst: ^Rect_Inst, tex: [2]f32, dx: f32, e, ppe: [2]f32, glyph, band_max: [2]int, dk: [2]f32, small: [4]f32) -> f32 {
					if small.y > 0.5 {
						return 0.5 * (cr_slug_render(sl, tex + [2]f32{dx - 0.25, -0.25} * e, inst.radii, glyph, band_max, ppe * 2, dk * 2) +
						              cr_slug_render(sl, tex + [2]f32{dx + 0.25, 0.25} * e, inst.radii, glyph, band_max, ppe * 2, dk * 2))
					}
					return cr_slug_render(sl, tex + [2]f32{dx, 0} * e, inst.radii, glyph, band_max, ppe, dk)
				}
				mid := stripe(&sl, inst, tex, 0, e, ppe, glyph, band_max, dk, small)
				c3 := [3]f32{mid, mid, mid}
				if side != 0 {
					c3.x = stripe(&sl, inst, tex, -side, e, ppe, glyph, band_max, dk, small)
					c3.z = stripe(&sl, inst, tex, side, e, ppe, glyph, band_max, dk, small)
				}
				c3 = {cr_text_coverage(g, &text, c3.x), cr_text_coverage(g, &text, c3.y), cr_text_coverage(g, &text, c3.z)}
				a := color.a
				if inst.clip != 0 { a *= cr_clip_coverage(s, screen, inst.clip) }
				if a <= 0 || (c3.x <= 0 && c3.y <= 0 && c3.z <= 0) { continue }
				fac := [4]f32{cr_saturate(a * c3.x), cr_saturate(a * c3.y), cr_saturate(a * c3.z), cr_saturate(a * (c3.x + c3.y + c3.z) / 3)}
				px := &row[x]
				rgb := [3]f32{cr_saturate(color.r), cr_saturate(color.g), cr_saturate(color.b)}
				px.rgb = rgb * fac.rgb + px.rgb * ([3]f32{1, 1, 1} - fac.rgb)
				// (the alpha keeps the pipelines' blend: One, OneMinusSrcAlpha, the output's alpha being fac.a)
				px.a = fac.a + px.a * (1 - fac.a)
				continue
			}
			cov: f32
			if small.y > 0.5 {
				cov = 0.25 * (cr_slug_render(&sl, tex + [2]f32{-0.125, -0.375} * e, inst.radii, glyph, band_max, ppe * 2, dk * 2) +
				              cr_slug_render(&sl, tex + [2]f32{0.375, -0.125} * e, inst.radii, glyph, band_max, ppe * 2, dk * 2) +
				              cr_slug_render(&sl, tex + [2]f32{0.125, 0.375} * e, inst.radii, glyph, band_max, ppe * 2, dk * 2) +
				              cr_slug_render(&sl, tex + [2]f32{-0.375, 0.125} * e, inst.radii, glyph, band_max, ppe * 2, dk * 2))
			} else {
				cov = cr_slug_render(&sl, tex, inst.radii, glyph, band_max, ppe, dk)
			}
			if cov <= 0 { continue }
			c := color
			c.a *= cr_text_coverage(g, &text, cov)
			if inst.clip != 0 { c.a *= cr_clip_coverage(s, screen, inst.clip) }
			cr_blend(&row[x], c)
		}
	}
}
