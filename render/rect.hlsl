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
#define CLIP_CIRCLE 0x80000000u   // ClipShape.parent: same, for a clip shape
#define MAX_CLIP_DEPTH 8

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

// rounded-rect clip: `inv` (+ `t`) maps screen pixels to the clip's local space
struct ClipShape
{
	float4 inv;            // a b c d
	float2 t;              // e f
	float  px;             // screen pixels per local unit
	uint   parent;         // enclosing clip, 0 = none
	float2 center;
	float2 half_size;
	float4 radii;          // top-left, bottom-left, top-right, bottom-right
};

Texture2D<float>  atlas : register(t0);
Texture2D<float4> image : register(t1);   // premultiplied, sRGB-decoded by the sampler
StructuredBuffer<Xform> xforms : register(t2);
StructuredBuffer<ClipShape> clips : register(t3);
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

// Coverage of the (nested) rounded clip shapes at a screen position.
float clip_coverage(float2 screen, uint idx)
{
	float coverage = 1;
	[loop] for (int k = 0; k < MAX_CLIP_DEPTH && idx != 0; k++)
	{
		ClipShape c = clips[idx];
		use_corner_shape((c.parent & CLIP_CIRCLE) != 0);
		float2 lp = float2(c.inv.x * screen.x + c.inv.z * screen.y + c.t.x, c.inv.y * screen.x + c.inv.w * screen.y + c.t.y) - c.center;
		coverage *= saturate(0.5 - rect_sdf(lp, c.half_size, corner_radius(lp, c.radii)) * c.px);
		idx = c.parent & ~CLIP_CIRCLE;
	}
	return coverage;
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
	if (i.extra.y != 0) { color.a *= clip_coverage(i.pos.xy + target_origin, i.extra.y); }
	return color;
}
