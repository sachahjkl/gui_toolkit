// Text drawn by the Slug algorithm (Eric Lengyel, https://github.com/EricLengyel/Slug, MIT License, Copyright 2017 by
// Eric Lengyel): the coverage of a glyph is computed per pixel from its quadratic Bezier outline, with no bitmap. The
// reference shaders are pinned in font/slug_ref (commit and SHA-256 in PINNED.md); SlugRender, the root solvers and the
// dilation below are theirs, adapted: typed textures, the instance layout of rect.wgsl instead of five vertex attributes, an
// affine transform instead of an MVP matrix.
//
// This file is compiled after rect.wgsl (the two are concatenated: render/shaders.odin, tools/shaders): it uses its uniform
// buffers, the transform / slot tables, the clip shapes and the text correction, and draws the same Rect_Inst instances
// through its own entry points (vs_slug, ps_slug), so a glyph is transformed, clipped, faded and corrected exactly as an
// atlas glyph is. Nothing here is needed by rect.wgsl.
//
// A Slug instance (KIND_SLUG, see Rect_Inst):
//   dst     the glyph's box in the instance's units (local units under a transform): x0 y0 x1 y1, y down
//   src     the same box in em units, y up: x0 y0 x1 y1 (dst.x0 <-> src.x0, dst.y0 <-> src.y1)
//   colors  [0] the text color (linear, straight)
//   radii   band scale x, y and offset x, y (em coordinate -> band index)
//   extra   x: transform, y: clip, z: band max x | band max y << 8, w: glyph location in the band texture, x | y << 16
//
// Textures (a glyph's data lies in one row of each, see font/slug_build.odin):
//   curves, RGBA16F: texel j of a contour = (p1, p2) of curve j, texel j+1 = (p3, ...)
//   bands, RG16UI: (curve count, list offset) per horizontal band, then per vertical band, then the lists of curve locations

@group(1) @binding(3) var slug_curves: texture_2d<f32>;
@group(1) @binding(4) var slug_bands: texture_2d<u32>;

const kLogBandTextureWidth: u32 = 12u;

fn CalcRootCode(y1: f32, y2: f32, y3: f32) -> u32 {
	// Root eligibility of a sample-relative quadratic Bezier curve, from the signs of the y coordinates of its control points.
	let i1 = bitcast<u32>(y1) >> 31u;
	let i2 = bitcast<u32>(y2) >> 30u;
	let i3 = bitcast<u32>(y3) >> 29u;

	var shift = (i2 & 2u) | (i1 & ~2u);
	shift = (i3 & 4u) | (shift & ~4u);

	// Eligibility is returned in bits 0 and 8.
	return (0x2E74u >> shift) & 0x0101u;
}

fn SolveHorizPoly(p12: float4, p3: float2) -> float2 {
	// The values of t where the curve crosses y = 0, then its x coordinates there. The polynomial in t is
	// a t^2 - 2b t + c with a = p1.y - 2 p2.y + p3.y, b = p1.y - p2.y, c = p1.y; the discriminant is clamped to zero
	// (imaginary roots become a double root at the minimum).
	let a = p12.xy - p12.zw * 2.0 + p3;
	let b = p12.xy - p12.zw;
	let ra = 1.0 / a.y;
	let rb = 0.5 / b.y;

	let d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
	var t1 = (b.y - d) * ra;
	var t2 = (b.y + d) * ra;

	// nearly linear: solve -2b t + c = 0
	if (abs(a.y) < 1.0 / 65536.0) { t1 = p12.y * rb; t2 = t1; }

	return float2((a.x * t1 - b.x * 2.0) * t1 + p12.x, (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

fn SolveVertPoly(p12: float4, p3: float2) -> float2 {
	let a = p12.xy - p12.zw * 2.0 + p3;
	let b = p12.xy - p12.zw;
	let ra = 1.0 / a.x;
	let rb = 0.5 / b.x;

	let d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
	var t1 = (b.x - d) * ra;
	var t2 = (b.x + d) * ra;

	if (abs(a.x) < 1.0 / 65536.0) { t1 = p12.x * rb; t2 = t1; }

	return float2((a.y * t1 - b.y * 2.0) * t1 + p12.y, (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

fn CalcBandLoc(glyphLoc: vec2<i32>, offset: u32) -> vec2<i32> {
	// A glyph's lists do not cross a row in this renderer's cache; the wrap is kept for data laid out as the reference does.
	var bandLoc = vec2<i32>(glyphLoc.x + i32(offset), glyphLoc.y);
	bandLoc.y += bandLoc.x >> kLogBandTextureWidth;
	bandLoc.x &= (1 << kLogBandTextureWidth) - 1;
	return bandLoc;
}

fn CalcCoverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) -> f32 {
	// The coverages of the horizontal and vertical rays combined by their weights; absolute values make either winding
	// direction work. Nonzero fill rule.
	let coverage = max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0), min(abs(xcov), abs(ycov)));
	return saturate(coverage);
}

fn SlugRender(renderCoord: float2, bandTransform: float4, glyphData: vec4<i32>) -> f32 {
	// The pixel dimensions of the em square, per axis, from the derivatives of the em-space coordinate.
	let emsPerPixel = fwidth(renderCoord);
	let pixelsPerEm = 1.0 / emsPerPixel;

	var bandMax = glyphData.zw;
	bandMax.y &= 0x00FF;

	// The bands the pixel lies in: scale and offset of the render coordinates, clamped to [0, bandMax].
	let bandIndex = clamp(vec2<i32>(renderCoord * bandTransform.xy + bandTransform.zw), vec2<i32>(0, 0), bandMax);
	let glyphLoc = glyphData.xy;

	var xcov = 0.0;
	var xwgt = 0.0;

	// The horizontal band: how many curves touch it (x) and where their list is (y).
	let hbandData = textureLoad(slug_bands, vec2<i32>(glyphLoc.x + bandIndex.y, glyphLoc.y), 0).xy;
	let hbandLoc = CalcBandLoc(glyphLoc, hbandData.y);

	for (var curveIndex = 0; curveIndex < i32(hbandData.x); curveIndex++) {
		let curveLoc = vec2<i32>(textureLoad(slug_bands, vec2<i32>(hbandLoc.x + curveIndex, hbandLoc.y), 0).xy);

		// p1 and p2 of the curve in one texel, p3 in the first two channels of the next one, relative to the sample.
		let p12 = textureLoad(slug_curves, curveLoc, 0) - float4(renderCoord, renderCoord);
		let p3 = textureLoad(slug_curves, vec2<i32>(curveLoc.x + 1, curveLoc.y), 0).xy - renderCoord;

		// The curves are sorted by descending largest x: once one lies left of the pixel, so do the rest.
		if (max(max(p12.x, p12.z), p3.x) * pixelsPerEm.x < -0.5) { break; }

		let code = CalcRootCode(p12.y, p12.w, p3.y);
		if (code != 0u) {
			let r = SolveHorizPoly(p12, p3) * pixelsPerEm.x;

			if ((code & 1u) != 0u) {
				xcov += saturate(r.x + 0.5);
				xwgt = max(xwgt, saturate(1.0 - abs(r.x) * 2.0));
			}

			if (code > 1u) {
				xcov -= saturate(r.y + 0.5);
				xwgt = max(xwgt, saturate(1.0 - abs(r.y) * 2.0));
			}
		}
	}

	var ycov = 0.0;
	var ywgt = 0.0;

	// The vertical band follows the horizontal ones in the header.
	let vbandData = textureLoad(slug_bands, vec2<i32>(glyphLoc.x + bandMax.y + 1 + bandIndex.x, glyphLoc.y), 0).xy;
	let vbandLoc = CalcBandLoc(glyphLoc, vbandData.y);

	for (var curveIndex = 0; curveIndex < i32(vbandData.x); curveIndex++) {
		let curveLoc = vec2<i32>(textureLoad(slug_bands, vec2<i32>(vbandLoc.x + curveIndex, vbandLoc.y), 0).xy);
		let p12 = textureLoad(slug_curves, curveLoc, 0) - float4(renderCoord, renderCoord);
		let p3 = textureLoad(slug_curves, vec2<i32>(curveLoc.x + 1, curveLoc.y), 0).xy - renderCoord;

		// sorted by descending largest y
		if (max(max(p12.y, p12.w), p3.y) * pixelsPerEm.y < -0.5) { break; }

		let code = CalcRootCode(p12.x, p12.z, p3.x);
		if (code != 0u) {
			let r = SolveVertPoly(p12, p3) * pixelsPerEm.y;

			if ((code & 1u) != 0u) {
				ycov -= saturate(r.x + 0.5);
				ywgt = max(ywgt, saturate(1.0 - abs(r.x) * 2.0));
			}

			if (code > 1u) {
				ycov += saturate(r.y + 0.5);
				ywgt = max(ywgt, saturate(1.0 - abs(r.y) * 2.0));
			}
		}
	}

	return CalcCoverage(xcov, ycov, xwgt, ywgt);
}

// Dynamic dilation (reference vertex shader): the vertex moves along its normal so that the glyph's box grows by half a
// pixel on screen, whatever the matrix; returns the em-space coordinate of the moved vertex (xy) and its position (zw).
// pos.xy: the vertex, pos.zw: its normal (the direction away from the box); tex: its em coordinate; jac: em units per
// unit of pos (00 01 10 11); m0, m1, m3: rows of the matrix to clip space (x, y, w); dim: the viewport.
fn SlugDilate(pos: float4, tex: float4, jac: float4, m0: float4, m1: float4, m3: float4, dim: float2) -> float4 {
	let n = normalize(pos.zw);
	let s = dot(m3.xy, pos.xy) + m3.w;
	let t = dot(m3.xy, n);

	let u = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
	let v = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

	let s2 = s * s;
	let st = s * t;
	let uv = u * u + v * v;
	let d = pos.zw * (s2 * (st + sqrt(uv)) / max(uv - st * st, 1e-20));

	let vpos = pos.xy + d;
	return float4(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw), vpos);
}

struct SlugPS {
	@builtin(position) pos: float4,
	@location(0) tex: float2,                                 // em-space sample coordinates
	@location(1) @interpolate(flat) color: float4,            // straight, in the target's space
	@location(2) @interpolate(flat) banding: float4,
	@location(3) @interpolate(flat) glyph: vec4<i32>,         // location x y, band max x, band max y
	@location(4) @interpolate(flat) clip: u32,
	@location(5) @interpolate(flat) corr: float4,             // text correction: ls, ld, bd, 1 / (bs - bd)
	@location(6) @interpolate(flat) corr_meta: float2,        // contrast * ld, enabled
};

@vertex
fn vs_slug(i: VSIn) -> SlugPS {
	let corner = float2(f32(i.vid >> 1u), f32(i.vid & 1u));   // 0: (0,0) 1: (0,1) 2: (1,0) 3: (1,1) as a triangle strip
	var m = mat_make(float4(1.0, 0.0, 0.0, 1.0), float2(0.0, 0.0));
	if (is_retained()) {
		m = replay_mat();
		if (i.extra.x != 0u) {
			let s = slots[rp.base.x + i.extra.x];
			m = mat_mul(m, mat_make(s.abcd, s.ef.xy));
		}
	} else if (i.extra.x != 0u) {
		let x = xforms[i.extra.x];
		m = mat_make(x.abcd, x.ef.xy);
	}

	// the box corner, its outward normal, its em coordinate (em y is up, local y down)
	let lp = mix(i.dst.xy, i.dst.zw, corner);
	let nrm = corner * 2.0 - 1.0;
	let dsz = max(i.dst.zw - i.dst.xy, float2(1e-6));
	let esz = i.src.zw - i.src.xy;
	let em = float2(mix(i.src.x, i.src.z, corner.x), mix(i.src.w, i.src.y, corner.y));
	let jac = float4(esz.x / dsz.x, 0.0, 0.0, -esz.y / dsz.y);

	// local units -> clip space, as the rows the reference takes
	let t = m.ef - g.target_origin;
	let m0 = float4(2.0 * m.abcd.x / g.viewport_size.x, 2.0 * m.abcd.z / g.viewport_size.x, 0.0, 2.0 * t.x / g.viewport_size.x - 1.0);
	let m1 = float4(-2.0 * m.abcd.y / g.viewport_size.y, -2.0 * m.abcd.w / g.viewport_size.y, 0.0, 1.0 - 2.0 * t.y / g.viewport_size.y);
	let m3 = float4(0.0, 0.0, 0.0, 1.0);

	var o: SlugPS;
	let dil = SlugDilate(float4(lp, nrm), float4(em, 0.0, 0.0), jac, m0, m1, m3, g.viewport_size);
	let p = dil.zw;
	o.tex = dil.xy;
	o.pos = float4(p.x * m0.x + p.y * m0.y + m0.w, p.x * m1.x + p.y * m1.y + m1.w, 0.0, 1.0);

	o.banding = i.radii;
	o.glyph = vec4<i32>(i32(i.extra.w & 0xFFFFu), i32(i.extra.w >> 16u), i32(i.extra.z & 0xFFu), i32((i.extra.z >> 8u) & 0xFFu));
	o.clip = i.extra.y;

	var c = i.c0;
	c.a = c.a * rp.m1.z;   // the replay's alpha (1 for immediate instances)
	if (g.target_space == SPACE_SRGB) { c = float4(srgb_encode(c.rgb), c.a); }
	o.color = c;

	// the text correction of rect.wgsl's vs_main (Skia's SkMaskGamma): the text's luminance and the background guessed as
	// its opposite, prepared per glyph for slug_text_coverage
	o.corr = float4(0.0);
	o.corr_meta = float2(0.0);
	if (g.text_gamma != 0.0) {
		let s = text_from_luma(dot(float3(0.2126, 0.7152, 0.0722), text_to_luma3(srgb_encode(i.c0.rgb))));
		let d = 1.0 - s;
		if (abs(s - d) >= 1.0 / 256.0) {
			let ls = text_to_luma(s);
			let ld = text_to_luma(d);
			let bs = select(s, srgb_decode1(s), g.target_space == SPACE_LINEAR);
			let bd = select(d, srgb_decode1(d), g.target_space == SPACE_LINEAR);
			o.corr = float4(ls, ld, bd, 1.0 / (bs - bd));
			o.corr_meta = float2(g.text_contrast * ld, 1.0);
		}
	}
	return o;
}

// rect.wgsl's text_coverage on a Slug coverage (the exponent, then Skia's correction).
fn slug_text_coverage(a0: f32, i: SlugPS) -> f32 {
	var a = a0;
	if (g.text_exponent != 1.0) { a = pow(max(a, 0.0), g.text_exponent); }
	if (i.corr_meta.y < 0.5) { return a; }
	let boosted = a + (1.0 - a) * i.corr_meta.x * a;
	let lin = i.corr.x * boosted + (1.0 - boosted) * i.corr.y;
	var o = text_from_luma(lin);
	if (g.target_space == SPACE_LINEAR) { o = srgb_decode1(o); }
	return saturate((o - i.corr.z) * i.corr.w);
}

@fragment
fn ps_slug(i: SlugPS) -> @location(0) float4 {
	// derivatives first, before anything that can branch away
	let cov = SlugRender(i.tex, i.banding, i.glyph);
	var color = i.color;
	color.a = color.a * slug_text_coverage(cov, i);
	if (i.clip != 0u || rp.misc.y != 0u) { color.a = color.a * any_clip_coverage(i.pos.xy + g.target_origin, i.clip); }
	return color;
}
