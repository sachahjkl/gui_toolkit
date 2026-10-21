// Text drawn by the Slug algorithm (Eric Lengyel, https://github.com/EricLengyel/Slug, MIT License, Copyright 2017 by
// Eric Lengyel): the coverage of a glyph is computed per pixel from its quadratic Bézier outline, with no bitmap. The
// reference shaders are pinned in font/slug_ref (commit and SHA-256 in PINNED.md); SlugRender, the root solvers and the
// dilation below are theirs, adapted: typed textures, the instance layout of rect.hlsl instead of five vertex attributes, an
// affine transform instead of an MVP matrix.
//
// This file is compiled after rect.hlsl (render/shaders.odin concatenates them): it uses its constant buffers, the
// transform / slot tables, the clip shapes and the text correction, and draws the same Rect_Inst instances through its own
// entry points (vs_slug, ps_slug), so a glyph is transformed, clipped, faded and corrected exactly as an atlas glyph is.
// Nothing here is needed by rect.hlsl.
//
// A Slug instance (KIND_SLUG, see Rect_Inst):
//   dst     the glyph's box in the instance's units (local units under a transform): x0 y0 x1 y1, y down
//   src     the same box in em units, y up: x0 y0 x1 y1 (dst.x0 <-> src.x0, dst.y0 <-> src.y1)
//   colors  [0] the text color (linear, straight)
//   radii   band scale x, y and offset x, y (em coordinate -> band index)
//   extra   x: transform, y: clip, z: band max x | band max y << 8, w: glyph location in the band texture, x | y << 16
//
// Textures (a glyph's data lies in one row of each, see font/slug_build.odin):
//   t11 curves, RGBA16F: texel j of a contour = (p1, p2) of curve j, texel j+1 = (p3, ...)
//   t12 bands, RG16UI: (curve count, list offset) per horizontal band, then per vertical band, then the lists of curve locations

#define kLogBandTextureWidth 12

Texture2D<float4> slug_curves : register(t11);
Texture2D<uint2> slug_bands : register(t12);

uint CalcRootCode(float y1, float y2, float y3)
{
	// Root eligibility of a sample-relative quadratic Bézier curve, from the signs of the y coordinates of its control points.
	uint i1 = asuint(y1) >> 31U;
	uint i2 = asuint(y2) >> 30U;
	uint i3 = asuint(y3) >> 29U;

	uint shift = (i2 & 2U) | (i1 & ~2U);
	shift = (i3 & 4U) | (shift & ~4U);

	// Eligibility is returned in bits 0 and 8.
	return ((0x2E74U >> shift) & 0x0101U);
}

float2 SolveHorizPoly(float4 p12, float2 p3)
{
	// The values of t where the curve crosses y = 0, then its x coordinates there. The polynomial in t is
	// a t^2 - 2b t + c with a = p1.y - 2 p2.y + p3.y, b = p1.y - p2.y, c = p1.y; the discriminant is clamped to zero
	// (imaginary roots become a double root at the minimum).
	float2 a = p12.xy - p12.zw * 2.0 + p3;
	float2 b = p12.xy - p12.zw;
	float ra = 1.0 / a.y;
	float rb = 0.5 / b.y;

	float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
	float t1 = (b.y - d) * ra;
	float t2 = (b.y + d) * ra;

	// nearly linear: solve -2b t + c = 0
	if (abs(a.y) < 1.0 / 65536.0) t1 = t2 = p12.y * rb;

	return (float2((a.x * t1 - b.x * 2.0) * t1 + p12.x, (a.x * t2 - b.x * 2.0) * t2 + p12.x));
}

float2 SolveVertPoly(float4 p12, float2 p3)
{
	float2 a = p12.xy - p12.zw * 2.0 + p3;
	float2 b = p12.xy - p12.zw;
	float ra = 1.0 / a.x;
	float rb = 0.5 / b.x;

	float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
	float t1 = (b.x - d) * ra;
	float t2 = (b.x + d) * ra;

	if (abs(a.x) < 1.0 / 65536.0) t1 = t2 = p12.x * rb;

	return (float2((a.y * t1 - b.y * 2.0) * t1 + p12.y, (a.y * t2 - b.y * 2.0) * t2 + p12.y));
}

int2 CalcBandLoc(int2 glyphLoc, uint offset)
{
	// A glyph's lists do not cross a row in this renderer's cache; the wrap is kept for data laid out as the reference does.
	int2 bandLoc = int2(glyphLoc.x + int(offset), glyphLoc.y);
	bandLoc.y += bandLoc.x >> kLogBandTextureWidth;
	bandLoc.x &= (1 << kLogBandTextureWidth) - 1;
	return (bandLoc);
}

float CalcCoverage(float xcov, float ycov, float xwgt, float ywgt)
{
	// The coverages of the horizontal and vertical rays combined by their weights; absolute values make either winding
	// direction work. Nonzero fill rule.
	float coverage = max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0), min(abs(xcov), abs(ycov)));
	return saturate(coverage);
}

float SlugRender(float2 renderCoord, float4 bandTransform, int4 glyphData)
{
	int curveIndex;

	// The pixel dimensions of the em square, per axis, from the derivatives of the em-space coordinate.
	float2 emsPerPixel = fwidth(renderCoord);
	float2 pixelsPerEm = 1.0 / emsPerPixel;

	int2 bandMax = glyphData.zw;
	bandMax.y &= 0x00FF;

	// The bands the pixel lies in: scale and offset of the render coordinates, clamped to [0, bandMax].
	int2 bandIndex = clamp(int2(renderCoord * bandTransform.xy + bandTransform.zw), int2(0, 0), bandMax);
	int2 glyphLoc = glyphData.xy;

	float xcov = 0.0;
	float xwgt = 0.0;

	// The horizontal band: how many curves touch it (x) and where their list is (y).
	uint2 hbandData = slug_bands.Load(int3(glyphLoc.x + bandIndex.y, glyphLoc.y, 0)).xy;
	int2 hbandLoc = CalcBandLoc(glyphLoc, hbandData.y);

	[loop] for (curveIndex = 0; curveIndex < int(hbandData.x); curveIndex++)
	{
		int2 curveLoc = int2(slug_bands.Load(int3(hbandLoc.x + curveIndex, hbandLoc.y, 0)).xy);

		// p1 and p2 of the curve in one texel, p3 in the first two channels of the next one, relative to the sample.
		float4 p12 = slug_curves.Load(int3(curveLoc, 0)) - float4(renderCoord, renderCoord);
		float2 p3 = slug_curves.Load(int3(curveLoc.x + 1, curveLoc.y, 0)).xy - renderCoord;

		// The curves are sorted by descending largest x: once one lies left of the pixel, so do the rest.
		if (max(max(p12.x, p12.z), p3.x) * pixelsPerEm.x < -0.5) break;

		uint code = CalcRootCode(p12.y, p12.w, p3.y);
		if (code != 0U)
		{
			float2 r = SolveHorizPoly(p12, p3) * pixelsPerEm.x;

			if ((code & 1U) != 0U)
			{
				xcov += saturate(r.x + 0.5);
				xwgt = max(xwgt, saturate(1.0 - abs(r.x) * 2.0));
			}

			if (code > 1U)
			{
				xcov -= saturate(r.y + 0.5);
				xwgt = max(xwgt, saturate(1.0 - abs(r.y) * 2.0));
			}
		}
	}

	float ycov = 0.0;
	float ywgt = 0.0;

	// The vertical band follows the horizontal ones in the header.
	uint2 vbandData = slug_bands.Load(int3(glyphLoc.x + bandMax.y + 1 + bandIndex.x, glyphLoc.y, 0)).xy;
	int2 vbandLoc = CalcBandLoc(glyphLoc, vbandData.y);

	[loop] for (curveIndex = 0; curveIndex < int(vbandData.x); curveIndex++)
	{
		int2 curveLoc = int2(slug_bands.Load(int3(vbandLoc.x + curveIndex, vbandLoc.y, 0)).xy);
		float4 p12 = slug_curves.Load(int3(curveLoc, 0)) - float4(renderCoord, renderCoord);
		float2 p3 = slug_curves.Load(int3(curveLoc.x + 1, curveLoc.y, 0)).xy - renderCoord;

		// sorted by descending largest y
		if (max(max(p12.y, p12.w), p3.y) * pixelsPerEm.y < -0.5) break;

		uint code = CalcRootCode(p12.x, p12.z, p3.x);
		if (code != 0U)
		{
			float2 r = SolveVertPoly(p12, p3) * pixelsPerEm.y;

			if ((code & 1U) != 0U)
			{
				ycov -= saturate(r.x + 0.5);
				ywgt = max(ywgt, saturate(1.0 - abs(r.x) * 2.0));
			}

			if (code > 1U)
			{
				ycov += saturate(r.y + 0.5);
				ywgt = max(ywgt, saturate(1.0 - abs(r.y) * 2.0));
			}
		}
	}

	return (CalcCoverage(xcov, ycov, xwgt, ywgt));
}

// Dynamic dilation (reference vertex shader): the vertex moves along its normal so that the glyph's box grows by half a
// pixel on screen, whatever the matrix; returns the em-space coordinate of the moved vertex and its position in `vpos`.
// pos.xy: the vertex, pos.zw: its normal (the direction away from the box); tex: its em coordinate; jac: em units per
// unit of pos (00 01 10 11); m0, m1, m3: rows of the matrix to clip space (x, y, w); dim: the viewport.
float2 SlugDilate(float4 pos, float4 tex, float4 jac, float4 m0, float4 m1, float4 m3, float2 dim, out float2 vpos)
{
	float2 n = normalize(pos.zw);
	float s = dot(m3.xy, pos.xy) + m3.w;
	float t = dot(m3.xy, n);

	float u = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
	float v = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

	float s2 = s * s;
	float st = s * t;
	float uv = u * u + v * v;
	float2 d = pos.zw * (s2 * (st + sqrt(uv)) / max(uv - st * st, 1e-20));

	vpos = pos.xy + d;
	return (float2(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw)));
}

struct SlugPS
{
	float4 pos : SV_Position;
	float2 tex : SLUG_TEX;                              // em-space sample coordinates
	nointerpolation float4 color : SLUG_COLOR;          // straight, in the target's space
	nointerpolation float4 banding : SLUG_BAND;
	nointerpolation int4 glyph : SLUG_GLYPH;            // location x y, band max x, band max y
	nointerpolation uint clip : SLUG_CLIP;
	nointerpolation float4 corr : SLUG_CORR;            // text correction: ls, ld, bd, 1 / (bs - bd)
	nointerpolation float2 corr_meta : SLUG_CORRM;      // contrast * ld, enabled
};

SlugPS vs_slug(VSIn i)
{
	float2 corner = float2(i.vid >> 1, i.vid & 1);   // 0: (0,0) 1: (0,1) 2: (1,0) 3: (1,1) as a triangle strip
	Mat m = mat_make(float4(1, 0, 0, 1), float2(0, 0));
	if (is_retained())
	{
		m = replay_mat();
		if (i.extra.x != 0)
		{
			Slot s = slots[rp_base.x + i.extra.x];
			m = mat_mul(m, mat_make(s.abcd, s.ef.xy));
		}
	}
	else if (i.extra.x != 0)
	{
		Xform x = xforms[i.extra.x];
		m = mat_make(x.abcd, x.ef.xy);
	}

	// the box corner, its outward normal, its em coordinate (em y is up, local y down)
	float2 lp = lerp(i.dst.xy, i.dst.zw, corner);
	float2 nrm = corner * 2 - 1;
	float2 dsz = max(i.dst.zw - i.dst.xy, 1e-6);
	float2 esz = i.src.zw - i.src.xy;
	float2 em = float2(lerp(i.src.x, i.src.z, corner.x), lerp(i.src.w, i.src.y, corner.y));
	float4 jac = float4(esz.x / dsz.x, 0, 0, -esz.y / dsz.y);

	// local units -> clip space, as the rows the reference takes
	float2 t = m.ef - target_origin;
	float4 m0 = float4(2 * m.abcd.x / viewport_size.x, 2 * m.abcd.z / viewport_size.x, 0, 2 * t.x / viewport_size.x - 1);
	float4 m1 = float4(-2 * m.abcd.y / viewport_size.y, -2 * m.abcd.w / viewport_size.y, 0, 1 - 2 * t.y / viewport_size.y);
	float4 m3 = float4(0, 0, 0, 1);

	SlugPS o;
	float2 p;
	o.tex = SlugDilate(float4(lp, nrm), float4(em, 0, 0), jac, m0, m1, m3, viewport_size, p);
	o.pos = float4(p.x * m0.x + p.y * m0.y + m0.w, p.x * m1.x + p.y * m1.y + m1.w, 0, 1);

	o.banding = i.radii;
	o.glyph = int4(i.extra.w & 0xFFFF, i.extra.w >> 16, i.extra.z & 0xFF, (i.extra.z >> 8) & 0xFF);
	o.clip = i.extra.y;

	float4 c = i.c0;
	c.a *= rp_m1.z;   // the replay's alpha (1 for immediate instances)
	if (target_space == SPACE_SRGB) c.rgb = srgb_encode(c.rgb);
	o.color = c;

	// the text correction of rect.hlsl's vs_main (Skia's SkMaskGamma): the text's luminance and the background guessed as
	// its opposite, prepared per glyph for slug_text_coverage
	o.corr = float4(0, 0, 0, 0);
	o.corr_meta = float2(0, 0);
	if (text_gamma != 0)
	{
		float s = text_from_luma(dot(float3(0.2126, 0.7152, 0.0722), text_to_luma3(srgb_encode(i.c0.rgb))));
		float d = 1 - s;
		if (abs(s - d) >= 1.0 / 256)
		{
			float ls = text_to_luma(s), ld = text_to_luma(d);
			float bs = target_space == SPACE_LINEAR ? srgb_decode1(s) : s;
			float bd = target_space == SPACE_LINEAR ? srgb_decode1(d) : d;
			o.corr = float4(ls, ld, bd, 1 / (bs - bd));
			o.corr_meta = float2(text_contrast * ld, 1);
		}
	}
	return o;
}

// rect.hlsl's text_coverage on a Slug coverage (the exponent, then Skia's correction).
float slug_text_coverage(float a, SlugPS i)
{
	if (text_exponent != 1) a = pow(max(a, 0), text_exponent);
	if (i.corr_meta.y < 0.5) return a;
	float boosted = a + (1 - a) * i.corr_meta.x * a;
	float lin = i.corr.x * boosted + (1 - boosted) * i.corr.y;
	float o = text_from_luma(lin);
	if (target_space == SPACE_LINEAR) o = srgb_decode1(o);
	return saturate((o - i.corr.z) * i.corr.w);
}

float4 ps_slug(SlugPS i) : SV_Target
{
	// derivatives first, before anything that can branch away
	float cov = SlugRender(i.tex, i.banding, i.glyph);
	float4 color = i.color;
	color.a *= slug_text_coverage(cov, i);
	if (i.clip != 0 || rp_misc.y != 0) { color.a *= any_clip_coverage(i.pos.xy + target_origin, i.clip); }
	return color;
}
