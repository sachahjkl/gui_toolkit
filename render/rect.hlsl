// One instanced quad draws every primitive: filled / bordered / soft rounded rects (signed distance field),
// glyphs (atlas coverage) and images (RGBA textures). Colors arrive in LINEAR space and the render target view is
// sRGB, so blending happens in linear space (same choice as raddebugger).
//
// Transforms: an instance with a transform index (extra.x != 0) has its rect in a local space; the vertex shader maps
// the 4 corners to the screen through the 2D affine matrix and grows the quad by 1 screen pixel so the antialiased
// edge is not cut by rasterization. The pixel shader evaluates the rounded-rect distance in local space and converts
// it to screen pixels with the derivatives of the local position (exact for an affine map), so rotated, skewed and
// scaled shapes keep a 1 px antialiased edge.
//
// Layers (draw.push_layer): the same shader draws into an offscreen target whose texel (0, 0) is the screen pixel
// 	arget_origin; positions arrive in screen pixels and are moved by it, clip shapes are evaluated back in screen
// pixels. The layer is then composited as an image with FLAG_LAYER (texels fetched one for one, never filtered).

#define KIND_SHAPE 0
#define KIND_GLYPH 1
#define KIND_IMAGE 2
#define FLAG_TILE 1
#define FLAG_LAYER 2
#define FLAG_CIRCLE 4      // circular corners whatever the renderer's corner shape (web content)
#define FLAG_SCREEN 8      // image texels are screen pixels: texel 0 = screen pixel src.xy, src.zw texels valid
#define FLAG_BLEND 16      // layer composite through the blend mode in bits 8..15, against `backdrop`
#define BLEND_SHIFT 8
#define CLIP_RRECT 0
#define CLIP_ELLIPSE 1
#define CLIP_POLYGON 2
#define CLIP_CIRCLE 1      // ClipShape.flags: circular corners, for a clip shape
#define CLIP_EVENODD 2
#define MAX_CLIP_DEPTH 8
#define MAX_POLYGON_POINTS 4096

#define BLEND_NORMAL 0
#define BLEND_MULTIPLY 1
#define BLEND_SCREEN 2
#define BLEND_OVERLAY 3
#define BLEND_DARKEN 4
#define BLEND_LIGHTEN 5
#define BLEND_COLOR_DODGE 6
#define BLEND_COLOR_BURN 7
#define BLEND_HARD_LIGHT 8
#define BLEND_SOFT_LIGHT 9
#define BLEND_DIFFERENCE 10
#define BLEND_EXCLUSION 11
#define BLEND_HUE 12
#define BLEND_SATURATION 13
#define BLEND_COLOR 14
#define BLEND_LUMINOSITY 15
#define BLEND_PLUS_DARKER 16
#define BLEND_PLUS_LIGHTER 17

cbuffer Globals : register(b0)
{
	float2 viewport_size;
	float  corner_n;       // corner shape exponent: 2 = circular arcs, > 2 = superellipse ("squircle", continuous curvature)
	float  corner_boost;   // radius multiplier that keeps squircle corners visually as round as the circular ones
	float2 target_origin;  // screen pixel at (0, 0) of the render target: (0, 0) for the frame, the corner of a layer
	float2 _pad;
};

// x' = a*x + c*y + e, y' = b*x + d*y + f
struct Xform
{
	float4 abcd;
	float4 ef;             // e f, unused, unused
};

// clip shape: `inv` (+ `t`) maps screen pixels to the clip's local space
struct ClipShape
{
	float4 inv;            // a b c d
	float2 t;              // e f
	float  px;             // screen pixels per local unit
	uint   parent;         // enclosing clip, 0 = none
	float2 center;
	float2 half_size;      // ellipse: radii
	float4 radii;          // rounded rect: top-left, bottom-left, top-right, bottom-right
	uint   kind;           // CLIP_RRECT, CLIP_ELLIPSE, CLIP_POLYGON
	uint   first;          // polygon: its vertices in `points`
	uint   count;
	uint   flags;          // CLIP_CIRCLE, CLIP_EVENODD
};

Texture2D<float>  atlas : register(t0);
Texture2D<float4> image : register(t1);   // premultiplied, sRGB-decoded by the sampler
StructuredBuffer<Xform> xforms : register(t2);
StructuredBuffer<ClipShape> clips : register(t3);
StructuredBuffer<float2> points : register(t4);
Texture2D<float4> backdrop : register(t5);   // FLAG_BLEND: what the target held under the composite (linear premultiplied)
SamplerState samp      : register(s0);     // atlas
SamplerState samp_img  : register(s1);     // images, clamp
SamplerState samp_wrap : register(s2);     // images, repeat

struct VSIn
{
	float4 dst   : DST;      // x0 y0 x1 y1 in pixels (local units with a transform)
	float4 src   : SRC;      // u0 v0 u1 v1 in texels
	float4 c0    : C0;       // corner colors: top-left, bottom-left, top-right, bottom-right
	float4 c1    : C1;
	float4 c2    : C2;
	float4 c3    : C3;
	float4 radii : RADII;    // top-left, bottom-left, top-right, bottom-right
	float4 style : STYLE;    // border thickness, softness, kind, texture size
	uint4 extra  : EXTRA;    // transform index, clip index, flags, unused
	uint vid     : SV_VertexID;
};

struct PSIn
{
	float4 pos : SV_Position;
	float2 rect_pos : RECT_POS;                 // from the rect center (pixels, or local units with a transform)
	nointerpolation float2 half_size : HALF;
	float2 uv : UV;
	float4 color : COLOR;
	nointerpolation float4 radii : RADII;
	nointerpolation float4 style : STYLE;
	nointerpolation float4 src : SRCRECT;       // like uv: normalized for glyphs, texels for images
	nointerpolation uint4 extra : EXTRA;
};

PSIn vs_main(VSIn i)
{
	float2 corner = float2(i.vid >> 1, i.vid & 1);   // 0: (0,0) 1: (0,1) 2: (1,0) 3: (1,1) as a triangle strip
	float2 size = i.dst.zw - i.dst.xy;
	float2 t = corner;                               // position across the rect (0..1, beyond when grown)
	float2 pix;
	if (i.extra.x != 0)
	{
		Xform m = xforms[i.extra.x];
		float det = m.abcd.x * m.abcd.w - m.abcd.y * m.abcd.z;
		// local margin that is 1 px on screen, measured perpendicular to each pair of sides
		float2 grow = abs(det) > 1e-12 ? float2(length(m.abcd.zw), length(m.abcd.xy)) / abs(det) : 0;
		t += (corner * 2 - 1) * grow / max(abs(size), 1e-6);
		float2 lp = i.dst.xy + t * size;
		pix = float2(m.abcd.x * lp.x + m.abcd.z * lp.y + m.ef.x, m.abcd.y * lp.x + m.abcd.w * lp.y + m.ef.y);
	}
	else
	{
		pix = lerp(i.dst.xy, i.dst.zw, corner);
	}
	PSIn o;
	pix -= target_origin;
	o.pos = float4(pix.x / viewport_size.x * 2 - 1, 1 - pix.y / viewport_size.y * 2, 0, 1);
	o.rect_pos = (t - 0.5) * size;
	o.half_size = size * 0.5;
	float tex = max(i.style.w, 1);
	o.uv = lerp(i.src.xy, i.src.zw, t) / tex;
	o.src = i.src / tex;
	o.color = (i.vid == 0) ? i.c0 : ((i.vid == 1) ? i.c1 : ((i.vid == 2) ? i.c2 : i.c3));
	o.radii = i.radii;
	o.style = i.style;
	o.extra = i.extra;
	return o;
}

// Rounded-rect distance. With corner_n > 2 the corner is a superellipse: its curvature ramps up from the straight
// edge instead of jumping (the visible kink where a circular arc meets a straight side). The p-norm is not an exact
// distance, but close enough for 1 px antialiasing. `dir`: direction of the distance gradient (local space).
// the corner shape of the primitive being shaded: the renderer's, or circular (FLAG_CIRCLE / CLIP_CIRCLE)
static float shape_n;
static float shape_boost;

void use_corner_shape(bool circle)
{
	shape_n = circle ? 2 : corner_n;
	shape_boost = circle ? 1 : corner_boost;
}

float rect_sdf_dir(float2 p, float2 half_size, float r, out float2 dir)
{
	r = min(r * shape_boost, min(half_size.x, half_size.y));
	float2 d = abs(p) - half_size + r;
	float2 q = max(d, 0);
	float outside = shape_n > 2.01 ? pow(pow(max(q.x, 1e-6), shape_n) + pow(max(q.y, 1e-6), shape_n), 1.0 / shape_n) : length(q);
	dir = (q.x > 0 && q.y > 0) ? normalize(q) : (d.x > d.y ? float2(1, 0) : float2(0, 1));
	dir *= float2(p.x < 0 ? -1 : 1, p.y < 0 ? -1 : 1);
	return min(max(d.x, d.y), 0) + outside - r;
}

float rect_sdf(float2 p, float2 half_size, float r)
{
	float2 dir;
	return rect_sdf_dir(p, half_size, r, dir);
}

// A local-space distance in screen pixels: divided by how much it changes per pixel along its gradient.
float to_px(float s, float2 dir, float2 dpx, float2 dpy)
{
	return s / max(length(float2(dot(dir, dpx), dot(dir, dpy))), 1e-6);
}

float corner_radius(float2 p, float4 radii)
{
	return (p.x < 0) ? ((p.y < 0) ? radii.x : radii.y) : ((p.y < 0) ? radii.z : radii.w);
}

// Approximate signed distance to an ellipse of radii `r` (exact for a circle): the implicit function divided by its
// gradient, accurate near the edge, which is all antialiasing needs.
float ellipse_sdf(float2 p, float2 r)
{
	r = max(r, 1e-4);
	if (abs(r.x - r.y) < 1e-4) return length(p) - r.x;
	float k0 = length(p / r);
	float k1 = length(p / (r * r));
	return k1 > 1e-6 ? k0 * (k0 - 1) / k1 : -min(r.x, r.y);
}

// Signed distance to a polygon (negative inside), with the nonzero or even-odd rule.
float polygon_sdf(float2 p, uint first, uint count, bool evenodd)
{
	count = min(count, MAX_POLYGON_POINTS);
	if (count < 3) return 1e9;
	float d = 1e30;
	int winding = 0;
	float2 a = points[first + count - 1];
	[loop] for (uint i = 0; i < count; i++)
	{
		float2 b = points[first + i];
		float2 e = b - a, w = p - a;
		float2 q = w - e * saturate(dot(w, e) / max(dot(e, e), 1e-12));
		d = min(d, dot(q, q));
		float side = e.x * w.y - e.y * w.x;
		if (a.y <= p.y) { if (b.y > p.y && side > 0) winding++; }
		else if (b.y <= p.y && side < 0) winding--;
		a = b;
	}
	bool inside = evenodd ? (winding & 1) != 0 : winding != 0;
	return inside ? -sqrt(d) : sqrt(d);
}

// Coverage of the (nested) clip shapes at a screen position.
float clip_coverage(float2 screen, uint idx)
{
	float coverage = 1;
	[loop] for (int k = 0; k < MAX_CLIP_DEPTH && idx != 0; k++)
	{
		ClipShape c = clips[idx];
		float2 lp = float2(c.inv.x * screen.x + c.inv.z * screen.y + c.t.x, c.inv.y * screen.x + c.inv.w * screen.y + c.t.y);
		float s;
		if (c.kind == CLIP_ELLIPSE) s = ellipse_sdf(lp - c.center, c.half_size);
		else if (c.kind == CLIP_POLYGON) s = polygon_sdf(lp, c.first, c.count, (c.flags & CLIP_EVENODD) != 0);
		else
		{
			use_corner_shape((c.flags & CLIP_CIRCLE) != 0);
			lp -= c.center;
			s = rect_sdf(lp, c.half_size, corner_radius(lp, c.radii));
		}
		coverage *= saturate(0.5 - s * c.px);
		idx = c.parent;
	}
	return coverage;
}

////////////////////////////////
// Blend modes (CSS Compositing 1 §10), on straight sRGB colors as browsers compute them.

float3 srgb_encode(float3 c)
{
	c = saturate(c);
	return (c <= 0.0031308) ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float3 srgb_decode(float3 c)
{
	c = saturate(c);
	return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float blend_channel(float b, float s, uint mode)
{
	switch (mode)
	{
	case BLEND_MULTIPLY: return b * s;
	case BLEND_SCREEN: return b + s - b * s;
	case BLEND_OVERLAY: return b <= 0.5 ? s * 2 * b : s + (2 * b - 1) - s * (2 * b - 1);
	case BLEND_DARKEN: return min(b, s);
	case BLEND_LIGHTEN: return max(b, s);
	case BLEND_COLOR_DODGE: return b <= 0 ? 0 : (s >= 1 ? 1 : min(1, b / (1 - s)));
	case BLEND_COLOR_BURN: return b >= 1 ? 1 : (s <= 0 ? 0 : 1 - min(1, (1 - b) / s));
	case BLEND_HARD_LIGHT: return s <= 0.5 ? b * 2 * s : b + (2 * s - 1) - b * (2 * s - 1);
	case BLEND_SOFT_LIGHT:
	{
		if (s <= 0.5) return b - (1 - 2 * s) * b * (1 - b);
		float d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : sqrt(b);
		return b + (2 * s - 1) * (d - b);
	}
	case BLEND_DIFFERENCE: return abs(b - s);
	case BLEND_EXCLUSION: return b + s - 2 * b * s;
	}
	return s;
}

float lum(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }

float3 clip_color(float3 c)
{
	float l = lum(c);
	float n = min(c.r, min(c.g, c.b));
	float x = max(c.r, max(c.g, c.b));
	if (n < 0) c = l + (c - l) * l / max(l - n, 1e-6);
	if (x > 1) c = l + (c - l) * (1 - l) / max(x - l, 1e-6);
	return c;
}

float3 set_lum(float3 c, float l) { return clip_color(c + (l - lum(c))); }

float sat(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }

float3 set_sat(float3 c, float s)
{
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	return mx > mn ? (c - mn) * s / (mx - mn) : 0;
}

float3 blend_color(float3 b, float3 s, uint mode)
{
	switch (mode)
	{
	case BLEND_HUE: return set_lum(set_sat(s, sat(b)), lum(b));
	case BLEND_SATURATION: return set_lum(set_sat(b, sat(s)), lum(b));
	case BLEND_COLOR: return set_lum(s, lum(b));
	case BLEND_LUMINOSITY: return set_lum(b, lum(s));
	}
	return float3(blend_channel(b.r, s.r, mode), blend_channel(b.g, s.g, mode), blend_channel(b.b, s.b, mode));
}

// Source (the layer) over backdrop through `mode`; both and the result are linear premultiplied.
float4 blend_composite(float4 src, float4 dst, uint mode)
{
	float as = saturate(src.a), ab = saturate(dst.a);
	float3 cs = as > 0 ? srgb_encode(src.rgb / as) : 0;
	float3 cb = ab > 0 ? srgb_encode(dst.rgb / ab) : 0;
	float ao;
	float3 co;   // premultiplied sRGB
	if (mode == BLEND_PLUS_LIGHTER)
	{
		ao = min(1, as + ab);
		co = min(1, cs * as + cb * ab);
	}
	else if (mode == BLEND_PLUS_DARKER)
	{
		ao = min(1, as + ab);
		co = max(0, ao - (as - cs * as) - (ab - cb * ab));
	}
	else
	{
		float3 mixed = (1 - ab) * cs + ab * saturate(blend_color(cb, cs, mode));
		ao = as + ab * (1 - as);
		co = as * mixed + (1 - as) * ab * cb;
	}
	if (ao <= 0) return 0;
	return float4(srgb_decode(co / ao) * ao, ao);
}

float4 ps_main(PSIn i) : SV_Target
{
	float2 p = i.rect_pos;
	// derivatives first, outside any branch: local units per screen pixel (constant per primitive), texture LOD
	float2 dpx = ddx(p), dpy = ddy(p);
	float2 duvx = ddx(i.uv), duvy = ddy(i.uv);
	bool xf = i.extra.x != 0;
	uint kind = (uint)(i.style.z + 0.5);
	use_corner_shape((i.extra.z & FLAG_CIRCLE) != 0);
	float4 color = i.color;
	float2 dir;
	float2 screen = i.pos.xy + target_origin;
	if (i.extra.z & FLAG_BLEND)
	{
		// the layer's texel and what lay under it; the batch writes the result (no hardware blending)
		float4 s = image.Load(int3(int2(floor(i.uv)), 0)) * color.a;
		float4 d = backdrop.Load(int3(int2(floor(screen - i.radii.xy)), 0));
		float4 o = blend_composite(s, d, (i.extra.z >> BLEND_SHIFT) & 0xff);
		float cov = i.extra.y != 0 ? clip_coverage(screen, i.extra.y) : 1;
		return lerp(d, o, cov);
	}
	if (kind == KIND_GLYPH)
	{
		// coverage from the atlas, kept inside the glyph's cell (a transformed quad is grown past it)
		float h = 0.5 / max(i.style.w, 1);
		color.a *= atlas.SampleGrad(samp, clamp(i.uv, i.src.xy + h, i.src.zw - h), duvx, duvy);
		if (xf) { color.a *= saturate(0.5 - to_px(rect_sdf_dir(p, i.half_size, 0, dir), dir, dpx, dpy)); }
	}
	else
	{
		if (kind == KIND_IMAGE)
		{
			float2 dim;
			image.GetDimensions(dim.x, dim.y);
			float2 uv = i.uv / dim;
			float4 texel;
			// a layer is composited pixel for pixel: fetch, never filter (filter weights would leak the transparent
			// texels around its edges)
			if (i.extra.z & FLAG_LAYER) { texel = image.Load(int3(int2(floor(i.uv)), 0)); }
			else if (i.extra.z & FLAG_SCREEN)
			{
				int2 tc = clamp(int2(floor(screen - i.src.xy)), 0, max(int2(i.src.zw) - 1, 0));
				texel = image.Load(int3(tc, 0));
			}
			else if (i.extra.z & FLAG_TILE) { texel = image.SampleGrad(samp_wrap, uv, duvx / dim, duvy / dim); }
			else
			{
				float2 h = 0.5 / dim;   // never filter in texels outside the source rect (sprite sheets)
				texel = image.SampleGrad(samp_img, clamp(uv, i.src.xy / dim + h, i.src.zw / dim - h), duvx / dim, duvy / dim);
			}
			color.rgb *= texel.rgb / max(texel.a, 1e-6);   // stored premultiplied, blended straight
			color.a *= texel.a;
		}
		float r = corner_radius(p, i.radii);
		float border = i.style.x;
		float soft = i.style.y;
		float coverage;
		if (soft > 1.0)
		{
			// soft shape (shadows, glows): the edge fades over 2*soft pixels inside the rect
			float s = rect_sdf(p, i.half_size - soft * 2, max(r - soft * 2, 0));
			coverage = 1 - smoothstep(0, soft * 2, s);
		}
		else
		{
			float s = rect_sdf_dir(p, i.half_size, r, dir);
			if (xf) { s = to_px(s, dir, dpx, dpy); }
			coverage = saturate(0.5 - s);
			if (border > 0)
			{
				float inner = rect_sdf_dir(p, i.half_size - border, max(r - border, 0), dir);
				if (xf) { inner = to_px(inner, dir, dpx, dpy); }
				coverage *= saturate(inner + 0.5);
			}
		}
		color.a *= coverage;
	}
	if (i.extra.y != 0) { color.a *= clip_coverage(screen, i.extra.y); }
	return color;
}
