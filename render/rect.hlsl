// One instanced quad draws every primitive: filled / bordered / soft rounded rects (signed distance field),
// glyphs (atlas coverage) and images (RGBA textures).
//
// Blend spaces: colors arrive LINEAR (straight alpha). Each target has a blend space (target_space): in Linear the
// shader outputs linear colors and the frame's render target view is sRGB, so the hardware blends in linear light
// (raddebugger's choice); in Srgb the shader outputs sRGB-encoded values into a UNORM view, so blending, antialiased
// edges and interpolation happen on encoded values, as web browsers do. Corner colors are interpolated premultiplied,
// in the target's space unless FLAG_LERP_SRGB / FLAG_LERP_LINEAR asks for another one (CSS gradients interpolate in
// sRGB whatever the compositor does). Image texels carry their own space (FLAG_TEX_SRGB) and are converted when it
// differs from the target's.
//
// Transforms: an instance with a transform index (extra.x != 0) has its rect in a local space; the vertex shader maps
// the 4 corners to the screen through the 2D affine matrix and grows the quad by 1 screen pixel so the antialiased
// edge is not cut by rasterization. The pixel shader evaluates the rounded-rect distance in local space and converts
// it to screen pixels with the derivatives of the local position (exact for an affine map), so rotated, skewed and
// scaled shapes keep a 1 px antialiased edge.
//
// Layers (draw.push_layer): the same shader draws into an offscreen target whose texel (0, 0) is the screen pixel
// target_origin; positions arrive in screen pixels and are moved by it, clip shapes are evaluated back in screen
// pixels. The layer is then composited as an image with FLAG_LAYER (texels fetched one for one, never filtered).
//
// Pictures (draw.Picture, retained): their instances live in a heap that persists across frames, in the picture's own
// space. A replay (constant buffer b2) gives the matrix L from that space to the screen, an alpha, the clip shape
// around the replay and where the picture's tables start in the retained heaps. An instance's transform index is then
// a slot of the picture (t7: its matrix to the picture's space, rewritten when it moves): the instance is drawn
// through L * slot. When that product is a uniform scale + translation the vertex shader bakes it exactly as draw
// bakes it on the CPU for immediate instances (same arithmetic, same pixels); otherwise the transformed path is used.
// Picture clips (t8) lie in the space of a slot, chained to the clips around the replay.
//
// Gradients (KIND_GRADIENT) are evaluated per pixel from a table (t6 for the frame, t10 for pictures); shadows
// (KIND_SHADOW) are the analytic gaussian blur of a rounded rect (exact in x with erf, integrated numerically in y
// over the rows of the corners only). Both are evaluated in the instance's own units (`lpos`), before any baking.

#define KIND_SHAPE 0
#define KIND_GLYPH 1
#define KIND_IMAGE 2
#define KIND_GRADIENT 3
#define KIND_SHADOW 4
#define SHADOW_INSET 1
#define SHADOW_HOLE 2
#define GRAD_LINEAR 0
#define GRAD_RADIAL 1
#define GRAD_CONIC 2
#define GRAD_REPEATING 0x100
#define GRAD_DITHER 0x200
#define GRAD_REPEAT_X 0x400
#define GRAD_REPEAT_Y 0x800
#define GRAD_HEADER 4
#define MAX_GRADIENT_STOPS 256
#define GSPACE_SRGB 0
#define GSPACE_LINEAR 1
#define GSPACE_OKLAB 2
#define GSPACE_OKLCH 3
#define GSPACE_LAB 4
#define GSPACE_LCH 5
#define GSPACE_HSL 6
#define GSPACE_HWB 7
#define FLAG_TILE 1
#define FLAG_LAYER 2
#define FLAG_CIRCLE 4      // circular corners whatever the renderer's corner shape (web content)
#define FLAG_SCREEN 8      // image texels are screen pixels: texel 0 = screen pixel src.xy, src.zw texels valid
#define FLAG_BLEND 16      // layer composite through the blend mode in bits 8..15, against `backdrop`
#define FLAG_TEX_SRGB 32   // image texels are premultiplied sRGB values (else premultiplied linear)
#define FLAG_LERP_SRGB 64  // corner colors interpolate in sRGB
#define FLAG_LERP_LINEAR 128 // corner colors interpolate in linear light
#define FLAG_SCALED 0x10000  // layer / backdrop texture holds the image reduced: sampled bilinearly
#define FLAG_MATRIX 0x20000  // color matrices on the layer / backdrop texel: gradient table entry `aux`
#define BLEND_SHIFT 8
#define SPACE_LINEAR 0
#define SPACE_SRGB 1
#define CLIP_RRECT 0
#define CLIP_ELLIPSE 1
#define CLIP_POLYGON 2
#define CLIP_CIRCLE 1      // ClipShape.flags: circular corners, for a clip shape
#define CLIP_EVENODD 2
#define CLIP_SCISSOR 4     // picture clip also cut by the scissor: skipped under a uniform scale + translation
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
	uint   target_space;   // SPACE_LINEAR or SPACE_SRGB: what the target holds and blends in
	float  text_gamma;     // render.Text_Rendering
	float  text_contrast;
	float  text_exponent;
	float2 _pad;
};

// The picture being replayed (render.Replay); identity, alpha 1 and rp_misc.x = 0 for immediate instances.
cbuffer Replay : register(b2)
{
	float4 rp_m0;          // L (picture space -> screen pixels): a b c d
	float4 rp_m1;          // e f, alpha, unused
	float4 rp_i0;          // L^-1: a b c d
	float4 rp_i1;          // e f
	uint4  rp_base;        // first slot, clip, point and gradient entry of the picture in the retained heaps
	uint4  rp_misc;        // x: 1 = retained instances; y: clip shape around the replay (frame table), 0 = none
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
	uint   flags;          // CLIP_CIRCLE, CLIP_EVENODD, CLIP_SCISSOR
	uint   xform;          // picture clips: the slot whose space the shape lies in (0 = the picture's space)
	uint3  _pad2;
};

// A transform slot of a picture: to the picture's space, and back.
struct Slot
{
	float4 abcd;
	float4 ef;
	float4 inv_abcd;
	float4 inv_ef;
};

Texture2D<float>  atlas : register(t0);
Texture2D<float4> image : register(t1);   // premultiplied, sRGB-decoded by the sampler
StructuredBuffer<Xform> xforms : register(t2);
StructuredBuffer<ClipShape> clips : register(t3);
StructuredBuffer<float2> points : register(t4);
Texture2D<float4> backdrop : register(t5);   // FLAG_BLEND: what the target held under the composite (linear premultiplied)
StructuredBuffer<float4> grads : register(t6);       // gradient table of the frame
StructuredBuffer<Slot> slots : register(t7);         // retained heaps (pictures)
StructuredBuffer<ClipShape> rclips : register(t8);
StructuredBuffer<float2> rpoints : register(t9);
StructuredBuffer<float4> rgrads : register(t10);
SamplerState samp      : register(s0);     // atlas
SamplerState samp_img  : register(s1);     // images, clamp
SamplerState samp_wrap : register(s2);     // images, repeat
SamplerState samp_border : register(s3);   // reduced filter results: bilinear, transparent outside the texture

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
	nointerpolation uint4 extra : EXTRA;        // x: 1 = transformed path, y: clip, z: flags, w: aux
	float2 lpos : LPOS;                         // position in the instance's own units (gradients, shadows)
	nointerpolation float4 p0 : PARAM0;         // colors[1..3] of gradient and shadow instances
	nointerpolation float4 p1 : PARAM1;
	nointerpolation float4 p2 : PARAM2;
};

// A 2D affine map (x' = a x + c y + e, y' = b x + d y + f).
struct Mat
{
	float4 abcd;
	float2 ef;
};

Mat mat_make(float4 abcd, float2 ef) { Mat m; m.abcd = abcd; m.ef = ef; return m; }

// m after n
Mat mat_mul(Mat m, Mat n)
{
	Mat o;
	o.abcd = float4(m.abcd.x * n.abcd.x + m.abcd.z * n.abcd.y, m.abcd.y * n.abcd.x + m.abcd.w * n.abcd.y,
	                m.abcd.x * n.abcd.z + m.abcd.z * n.abcd.w, m.abcd.y * n.abcd.z + m.abcd.w * n.abcd.w);
	o.ef = float2(m.abcd.x * n.ef.x + m.abcd.z * n.ef.y + m.ef.x, m.abcd.y * n.ef.x + m.abcd.w * n.ef.y + m.ef.y);
	return o;
}

float2 mat_apply(Mat m, float2 p) { return float2(m.abcd.x * p.x + m.abcd.z * p.y + m.ef.x, m.abcd.y * p.x + m.abcd.w * p.y + m.ef.y); }

// uniform positive scale + translation: what draw bakes on the CPU (draw.affine_is_scale_translate)
bool mat_simple(Mat m) { return m.abcd.y == 0 && m.abcd.z == 0 && m.abcd.x == m.abcd.w && m.abcd.x > 0; }

float mat_scale(Mat m) { return sqrt(abs(m.abcd.x * m.abcd.w - m.abcd.y * m.abcd.z)); }

Mat replay_mat() { return mat_make(rp_m0, rp_m1.xy); }
Mat replay_inv() { return mat_make(rp_i0, rp_i1.xy); }
bool is_retained() { return rp_misc.x != 0; }

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

float srgb_decode1(float c) { return srgb_decode(float3(c, c, c)).x; }

// A straight color from one space to the other.
float3 convert_space(float3 c, uint from, uint to)
{
	if (from == to) return c;
	return to == SPACE_SRGB ? srgb_encode(c) : srgb_decode(c);
}

// A premultiplied color from one space to the other.
float4 convert_premul(float4 c, uint from, uint to)
{
	if (from == to || c.a <= 0) return from == to ? c : 0;
	return float4(convert_space(c.rgb / c.a, from, to) * c.a, c.a);
}

// The text correction's curve (text_gamma: < 0 the sRGB transfer function, > 0 a power) from encoded values to luma
// and back.
float text_to_luma(float x) { return text_gamma < 0 ? srgb_decode1(x) : pow(max(x, 0), text_gamma); }
float3 text_to_luma3(float3 x) { return text_gamma < 0 ? srgb_decode(x) : pow(max(x, 0), text_gamma); }
float text_from_luma(float l) { return text_gamma < 0 ? srgb_encode(float3(l, l, l)).x : pow(max(l, 0), 1 / text_gamma); }

// Where an instance's corner colors are interpolated.
uint lerp_space(uint flags)
{
	if (flags & FLAG_LERP_SRGB) return SPACE_SRGB;
	if (flags & FLAG_LERP_LINEAR) return SPACE_LINEAR;
	return target_space;
}

PSIn vs_main(VSIn i)
{
	float2 corner = float2(i.vid >> 1, i.vid & 1);   // 0: (0,0) 1: (0,1) 2: (1,0) 3: (1,1) as a triangle strip
	uint kind = (uint)(i.style.z + 0.5);
	float4 dst = i.dst;
	float4 radii = i.radii;
	float4 style = i.style;
	bool xf = false;
	Mat m = mat_make(float4(1, 0, 0, 1), float2(0, 0));
	if (is_retained())
	{
		// picture space -> screen, through the instance's slot
		m = replay_mat();
		if (i.extra.x != 0)
		{
			Slot s = slots[rp_base.x + i.extra.x];
			m = mat_mul(m, mat_make(s.abcd, s.ef.xy));
		}
		if (mat_simple(m))
		{
			// baked as draw bakes uniform scale + translation on the CPU (rect_corners, text, image_inst)
			float k = m.abcd.x;
			dst = float4(dst.x * k + m.ef.x, dst.y * k + m.ef.y, dst.z * k + m.ef.x, dst.w * k + m.ef.y);
			if (kind != KIND_SHADOW) radii *= k;
			style.x *= k;
			if (style.y > 1) style.y *= k;
		}
		else xf = true;
	}
	else if (i.extra.x != 0)
	{
		Xform x = xforms[i.extra.x];
		m = mat_make(x.abcd, x.ef.xy);
		xf = true;
	}
	float2 size = dst.zw - dst.xy;
	float2 t = corner;                               // position across the rect (0..1, beyond when grown)
	float2 pix;
	if (xf)
	{
		float det = m.abcd.x * m.abcd.w - m.abcd.y * m.abcd.z;
		// local margin that is 1 px on screen, measured perpendicular to each pair of sides
		float2 grow = abs(det) > 1e-12 ? float2(length(m.abcd.zw), length(m.abcd.xy)) / abs(det) : 0;
		t += (corner * 2 - 1) * grow / max(abs(size), 1e-6);
		float2 lp = dst.xy + t * size;
		pix = mat_apply(m, lp);
	}
	else
	{
		pix = lerp(dst.xy, dst.zw, corner);
	}
	PSIn o;
	pix -= target_origin;
	o.pos = float4(pix.x / viewport_size.x * 2 - 1, 1 - pix.y / viewport_size.y * 2, 0, 1);
	o.rect_pos = (t - 0.5) * size;
	o.half_size = size * 0.5;
	o.lpos = i.dst.xy + t * (i.dst.zw - i.dst.xy);
	float tex = max(style.w, 1);
	o.uv = lerp(i.src.xy, i.src.zw, t) / tex;
	o.src = i.src / tex;
	// gradients and shadows have one color; their other "colors" are parameters
	float4 c = (kind >= KIND_GRADIENT || i.vid == 0) ? i.c0 : ((i.vid == 1) ? i.c1 : ((i.vid == 2) ? i.c2 : i.c3));
	c.a *= rp_m1.z;   // the replay's alpha (1 for immediate instances)
	if (lerp_space(i.extra.z) == SPACE_SRGB) c.rgb = srgb_encode(c.rgb);
	o.color = float4(c.rgb * c.a, c.a);   // premultiplied: a transparent corner does not drag the others' hue to black
	o.radii = radii;
	o.style = style;
	o.extra = uint4(xf ? 1 : 0, i.extra.yzw);
	o.p0 = i.c1;
	o.p1 = i.c2;
	o.p2 = i.c3;
	if (kind == KIND_GLYPH)
	{
		// Skia's text correction (SkMaskGamma), per glyph: the text's luminance s (sRGB-encoded) and the background
		// guessed as its opposite d = 1 - s, as luma through the text curve (Ls, Ld) and as the target blends them
		// (bs, bd). The pixel shader boosts and re-blends the coverage with them.
		o.style.y = 0;
		if (text_gamma != 0)
		{
			float s = text_from_luma(dot(float3(0.2126, 0.7152, 0.0722), text_to_luma3(srgb_encode(i.c0.rgb))));
			float d = 1 - s;
			if (abs(s - d) >= 1.0 / 256)
			{
				float ls = text_to_luma(s), ld = text_to_luma(d);
				float bs = target_space == SPACE_LINEAR ? srgb_decode1(s) : s;
				float bd = target_space == SPACE_LINEAR ? srgb_decode1(d) : d;
				o.radii = float4(ls, ld, bd, 1 / (bs - bd));
				o.style.x = text_contrast * ld;   // the contrast fades out as the guessed background gets dark
				o.style.y = 1;
			}
		}
	}
	return o;
}

// Glyph coverage to alpha (render.Text_Rendering): exponent, then Skia's correction prepared by the vertex shader.
float text_coverage(float a, PSIn i)
{
	if (text_exponent != 1) a = pow(max(a, 0), text_exponent);
	if (i.style.y < 0.5) return a;
	float boosted = a + (1 - a) * i.style.x * a;
	float lin = i.radii.x * boosted + (1 - boosted) * i.radii.y;   // the blend wanted, through the text curve
	float o = text_from_luma(lin);                                 // back to encoded values
	if (target_space == SPACE_LINEAR) o = srgb_decode1(o);
	return saturate((o - i.radii.z) * i.radii.w);                   // the coverage the target's blend needs for it
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

// A polygon vertex: from the frame's table, or from the retained heap (a picture's clip).
float2 point_at(bool ret, uint k) { return ret ? rpoints[rp_base.z + k] : points[k]; }

// Signed distance to a polygon (negative inside), with the nonzero or even-odd rule.
float polygon_sdf(float2 p, uint first, uint count, bool evenodd, bool ret)
{
	count = min(count, MAX_POLYGON_POINTS);
	if (count < 3) return 1e9;
	float d = 1e30;
	int winding = 0;
	float2 a = point_at(ret, first + count - 1);
	[loop] for (uint i = 0; i < count; i++)
	{
		float2 b = point_at(ret, first + i);
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

// Signed distance of a clip shape at `lp` (its local space).
float clip_sdf(ClipShape c, float2 lp, bool ret)
{
	if (c.kind == CLIP_ELLIPSE) return ellipse_sdf(lp - c.center, c.half_size);
	if (c.kind == CLIP_POLYGON) return polygon_sdf(lp, c.first, c.count, (c.flags & CLIP_EVENODD) != 0, ret);
	use_corner_shape((c.flags & CLIP_CIRCLE) != 0);
	lp -= c.center;
	return rect_sdf(lp, c.half_size, corner_radius(lp, c.radii));
}

// Coverage of the (nested) clip shapes of the frame's table at a screen position.
float clip_coverage(float2 screen, uint idx)
{
	float coverage = 1;
	[loop] for (int k = 0; k < MAX_CLIP_DEPTH && idx != 0; k++)
	{
		ClipShape c = clips[idx];
		float2 lp = float2(c.inv.x * screen.x + c.inv.z * screen.y + c.t.x, c.inv.y * screen.x + c.inv.w * screen.y + c.t.y);
		coverage *= saturate(0.5 - clip_sdf(c, lp, false) * c.px);
		idx = c.parent;
	}
	return coverage;
}

// Coverage of a picture's clips (each in the space of its slot, through the replay's matrix), then of the clips
// around the replay.
float retained_clip_coverage(float2 screen, uint idx)
{
	float coverage = 1;
	Mat l = replay_mat();
	float2 q = mat_apply(replay_inv(), screen);   // picture space
	[loop] for (int k = 0; k < MAX_CLIP_DEPTH && idx != 0; k++)
	{
		ClipShape c = rclips[rp_base.y + idx];
		Mat to_screen = l;
		float2 lp = q;
		if (c.xform != 0)
		{
			Slot s = slots[rp_base.x + c.xform];
			to_screen = mat_mul(l, mat_make(s.abcd, s.ef.xy));
			lp = mat_apply(mat_make(s.inv_abcd, s.inv_ef.xy), q);
		}
		// a plain rect under a uniform scale + translation: the scissor already cut it exactly (as push_clip does)
		if (!((c.flags & CLIP_SCISSOR) != 0 && mat_simple(to_screen)))
		{
			coverage *= saturate(0.5 - clip_sdf(c, lp, true) * mat_scale(to_screen));
		}
		idx = c.parent;
	}
	return coverage * clip_coverage(screen, rp_misc.y);
}

float any_clip_coverage(float2 screen, uint idx)
{
	return is_retained() ? retained_clip_coverage(screen, idx) : clip_coverage(screen, idx);
}

////////////////////////////////
// Gradients (CSS Images 4): see render.Gradient_Header in render.odin for the table layout.

float4 grad_entry(uint k) { return is_retained() ? rgrads[rp_base.w + k] : grads[k]; }

float3 oklab_to_linear(float3 c)
{
	float l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
	float m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
	float s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
	float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
	return float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
	             -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
	             -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

// CIE Lab (D50) to linear sRGB (D65, Bradford adaptation), as CSS Color 4.
float3 lab_to_linear(float3 c)
{
	float fy = (c.x + 16) / 116, fx = fy + c.y / 500, fz = fy - c.z / 200;
	const float e = 216.0 / 24389, k = 24389.0 / 27;
	float x = fx * fx * fx > e ? fx * fx * fx : (116 * fx - 16) / k;
	float y = c.x > k * e ? fy * fy * fy : c.x / k;
	float z = fz * fz * fz > e ? fz * fz * fz : (116 * fz - 16) / k;
	float3 xyz = float3(x * 0.3457 / 0.3585, y, z * (1 - 0.3457 - 0.3585) / 0.3585);   // D50 white
	float3 d65 = float3( 0.9554734527042182 * xyz.x - 0.023098536874261423 * xyz.y + 0.0632593086610217 * xyz.z,
	                    -0.028369706963208136 * xyz.x + 1.0099954580058226 * xyz.y + 0.021041398966943008 * xyz.z,
	                     0.012314001688319899 * xyz.x - 0.020507696433477912 * xyz.y + 1.3303659366080753 * xyz.z);
	return float3( 3.2409699419045226 * d65.x - 1.537383177570094 * d65.y - 0.4986107602930034 * d65.z,
	              -0.9692436362808796 * d65.x + 1.8759675015077202 * d65.y + 0.04155505740717559 * d65.z,
	               0.05563007969699366 * d65.x - 0.20397695888897652 * d65.y + 1.0569715142428786 * d65.z);
}

// HSL (hue in degrees, s and l 0..1) to sRGB values.
float3 hsl_to_srgb(float3 c)
{
	float h = c.x - 360 * floor(c.x / 360);
	float3 k = fmod(float3(0, 8, 4) + h / 30, 12);
	float a = c.y * min(c.z, 1 - c.z);
	return c.z - a * max(-1, min(min(k - 3, 9 - k), 1));
}

float3 hwb_to_srgb(float3 c)
{
	float w = c.y, b = c.z;
	if (w + b >= 1) { float g = w / (w + b); return float3(g, g, g); }
	return hsl_to_srgb(float3(c.x, 1, 0.5)) * (1 - w - b) + w;
}

// The color of gradient `h` at instance position `p`: straight, in linear light or sRGB values (`srgb_out`).
float4 gradient_color(float2 p, uint h, out bool srgb_out, out bool dither)
{
	uint4 hd = asuint(grad_entry(h));
	uint flags = hd.x;
	uint space = hd.y;
	uint n = min(hd.w, MAX_GRADIENT_STOPS);
	srgb_out = space == GSPACE_SRGB || space == GSPACE_HSL || space == GSPACE_HWB;
	dither = (flags & GRAD_DITHER) != 0;
	float4 geom = grad_entry(h + 1);
	float4 tile = grad_entry(h + 2);
	float4 per = grad_entry(h + 3);
	float2 q = p - tile.xy;
	if (tile.z > 0)
	{
		float period = tile.z + per.x;
		if (flags & GRAD_REPEAT_X) q.x -= floor(q.x / period) * period;
		if (q.x < 0 || q.x > tile.z) return 0;
	}
	if (tile.w > 0)
	{
		float period = tile.w + per.y;
		if (flags & GRAD_REPEAT_Y) q.y -= floor(q.y / period) * period;
		if (q.y < 0 || q.y > tile.w) return 0;
	}
	float t;
	uint kind = flags & 0xff;
	if (kind == GRAD_RADIAL)
	{
		t = length((q - geom.xy) / max(abs(geom.zw), 1e-4));
	}
	else if (kind == GRAD_CONIC)
	{
		float2 d = q - geom.xy;
		float a = atan2(d.x, -d.y);   // clockwise from up
		t = frac((a - geom.z) / 6.283185307179586);
	}
	else
	{
		float2 d = geom.zw - geom.xy;
		t = dot(q - geom.xy, d) / max(dot(d, d), 1e-12);
	}
	if (flags & GRAD_REPEATING)
	{
		float span = per.w - per.z;
		if (span > 1e-6) t = per.z + frac((t - per.z) / span) * span;
	}
	uint s0 = h + GRAD_HEADER;
	float4 c;
	if (n <= 1 || t <= grad_entry(s0 + 1).x) c = grad_entry(s0);
	else if (t >= grad_entry(s0 + 2 * (n - 1) + 1).x) c = grad_entry(s0 + 2 * (n - 1));
	else
	{
		uint k = 1;
		[loop] for (; k < n - 1; k++) { if (t < grad_entry(s0 + 2 * k + 1).x) break; }
		float4 pa = grad_entry(s0 + 2 * (k - 1) + 1);
		float pb = grad_entry(s0 + 2 * k + 1).x;
		float f = pb > pa.x ? (t - pa.x) / (pb - pa.x) : 1;
		if (pa.y >= 0)
		{
			// transition hint (CSS Images 4 Â§3.5.3): the midpoint color sits at fraction pa.y of the interval
			float hint = pa.y;
			if (hint <= 0) f = 1;
			else if (hint >= 1) f = f >= 1 ? 1 : 0;
			else f = pow(saturate(f), log(0.5) / log(hint));
		}
		c = lerp(grad_entry(s0 + 2 * (k - 1)), grad_entry(s0 + 2 * k), f);
	}
	if (c.a <= 1e-7) return 0;
	float3 v = c.rgb;
	// premultiplied: divide every component but a polar space's hue
	if (space == GSPACE_OKLCH || space == GSPACE_LCH) v.xy /= c.a;
	else if (space == GSPACE_HSL || space == GSPACE_HWB) v.yz /= c.a;
	else v /= c.a;
	float3 rgb;
	switch (space)
	{
	case GSPACE_LINEAR: rgb = v; break;
	case GSPACE_OKLAB: rgb = oklab_to_linear(v); break;
	case GSPACE_OKLCH: { float hr = radians(v.z); rgb = oklab_to_linear(float3(v.x, v.y * cos(hr), v.y * sin(hr))); break; }
	case GSPACE_LAB: rgb = lab_to_linear(v); break;
	case GSPACE_LCH: { float hr = radians(v.z); rgb = lab_to_linear(float3(v.x, v.y * cos(hr), v.y * sin(hr))); break; }
	case GSPACE_HSL: rgb = hsl_to_srgb(v); break;
	case GSPACE_HWB: rgb = hwb_to_srgb(v); break;
	default: rgb = v; break;
	}
	return float4(saturate(rgb), saturate(c.a));
}

// Triangular noise of +-1 level of 8 bits at a screen pixel (dithering of gradients).
float dither_noise(float2 screen)
{
	uint2 p = uint2(screen);
	uint hsh = p.x * 1973u + p.y * 9277u + 26699u;
	hsh = (hsh ^ (hsh >> 13)) * 1274126177u;
	hsh ^= hsh >> 16;
	float a = float(hsh & 0xffffu) / 65535.0, b = float(hsh >> 16) / 65535.0;
	return (a + b - 1) / 255.0;
}

////////////////////////////////
// Shadows: a gaussian of standard deviation `sigma` over a rounded rect. Along x the integral is exact (erf); along y
// the rows of the straight middle part are exact too (the box is a product of two intervals there), the rows of the
// corners are integrated with the midpoint rule over the part of the kernel that matters.

float erf_approx(float x)
{
	// Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7)
	float s = sign(x);
	x = abs(x);
	float t = 1 / (1 + 0.3275911 * x);
	float y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
	return s * y;
}

// The standard normal cumulative distribution.
float Phi(float x) { return 0.5 + 0.5 * erf_approx(x * 0.7071067811865476); }

// The blur is (left part) - (right part): the gaussian-weighted integral over the rows of Phi((p.x - left edge) / sigma)
// minus the same with the right edge. Each edge is straight except along two corner arcs, so each part is a product of
// two Phi on its straight stretch plus one integral per arc. An arc is integrated over its angle (y = cy + sy r sin a,
// x = cx + sx r cos a): smooth there (along y the edge has a square-root singularity), sampled only where the gaussian
// in y matters.
#define SHADOW_SAMPLES 16

float arc_part(float2 p, float2 center, float r, float sx, float sy, float sigma)
{
	if (r <= 0) return 0;
	// sin a for the rows within 4 sigma of p
	float s0 = sy * (p.y - 4 * sigma - center.y) / r, s1 = sy * (p.y + 4 * sigma - center.y) / r;
	float lo = clamp(min(s0, s1), 0, 1), hi = clamp(max(s0, s1), 0, 1);
	if (hi <= lo) return 0;
	float inv = 1 / sigma;
	// the edge of these rows lies within [center.x - r, center.x] or [center.x, center.x + r]: far from it, Phi is 0 or 1
	float xa = sx < 0 ? center.x - r : center.x, xb = sx < 0 ? center.x : center.x + r;
	if ((p.x - xa) * inv < -5) return 0;
	if ((p.x - xb) * inv > 5) return abs(Phi((p.y - (center.y + sy * r * lo)) * inv) - Phi((p.y - (center.y + sy * r * hi)) * inv));
	float a0 = asin(lo), a1 = asin(hi);
	float h = (a1 - a0) / SHADOW_SAMPLES;
	float acc = 0;
	[loop] for (int k = 0; k < SHADOW_SAMPLES; k++)
	{
		float a = a0 + (k + 0.5) * h;
		float sa, ca;
		sincos(a, sa, ca);
		float dy = (p.y - (center.y + sy * r * sa)) * inv;
		acc += exp(-0.5 * dy * dy) * Phi((p.x - (center.x + sx * r * ca)) * inv) * ca;
	}
	return acc * h * r * inv * 0.3989422804014327;
}

// The blurred coverage of a rounded rect (x0 y0 x1 y1, radii tl bl tr br) at p.
float blurred_rrect(float2 p, float4 rect, float4 radii, float sigma)
{
	float2 c = (rect.xy + rect.zw) * 0.5;
	float2 hs = max((rect.zw - rect.xy) * 0.5, 0);
	if (hs.x <= 0 || hs.y <= 0) return 0;
	p -= c;
	float4 r = min(max(radii, 0), min(hs.x, hs.y));
	float inv = 1 / sigma;
	// left edge: straight between the top-left and bottom-left arcs
	float left = Phi((p.x + hs.x) * inv) * max(Phi((p.y + hs.y - r.x) * inv) - Phi((p.y - hs.y + r.y) * inv), 0)
		+ arc_part(p, float2(-hs.x + r.x, -hs.y + r.x), r.x, -1, -1, sigma)
		+ arc_part(p, float2(-hs.x + r.y, hs.y - r.y), r.y, -1, 1, sigma);
	float right = Phi((p.x - hs.x) * inv) * max(Phi((p.y + hs.y - r.z) * inv) - Phi((p.y - hs.y + r.w) * inv), 0)
		+ arc_part(p, float2(hs.x - r.z, -hs.y + r.z), r.z, 1, -1, sigma)
		+ arc_part(p, float2(hs.x - r.w, hs.y - r.w), r.w, 1, 1, sigma);
	return saturate(left - right);
}

// Antialiased coverage of a rounded rect (x0 y0 x1 y1, radii tl bl tr br, circular corners) at p, in units whose
// screen rate of change is given by dpx / dpy.
float rrect_coverage(float2 p, float4 rect, float4 radii, float2 dpx, float2 dpy)
{
	float2 c = (rect.xy + rect.zw) * 0.5;
	float2 hs = max((rect.zw - rect.xy) * 0.5, 0);
	float2 dir;
	use_corner_shape(true);
	float2 q = p - c;
	float s = rect_sdf_dir(q, hs, corner_radius(q, radii), dir);
	return saturate(0.5 - to_px(s, dir, dpx, dpy));
}

////////////////////////////////
// Blend modes (CSS Compositing 1 Â§10), on straight sRGB colors as browsers compute them.

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

// Source (the layer) over backdrop through `mode`; both and the result are premultiplied in the target's space (the
// formulas run on straight sRGB values: converted in and out only for a linear target).
float4 blend_composite(float4 src, float4 dst, uint mode)
{
	float as = saturate(src.a), ab = saturate(dst.a);
	float3 cs = as > 0 ? convert_space(src.rgb / as, target_space, SPACE_SRGB) : 0;
	float3 cb = ab > 0 ? convert_space(dst.rgb / ab, target_space, SPACE_SRGB) : 0;
	cs = saturate(cs);
	cb = saturate(cb);
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
	return float4(convert_space(saturate(co / ao), SPACE_SRGB, target_space) * ao, ao);
}

// The texel of a layer composite (FLAG_LAYER: at uv, texels of the layer) or a backdrop (FLAG_SCREEN: at the screen
// pixel) as a filter chain left it: fetched one for one, or sampled bilinearly from a reduced image (FLAG_SCALED), then
// through its color matrices (FLAG_MATRIX: a Color pass done here instead of in a target of its own). `space` is the
// texel's space, sRGB after the matrices.
float4 layer_texel(PSIn i, float2 screen, inout uint space)
{
	uint flags = i.extra.z;
	float2 dim;
	image.GetDimensions(dim.x, dim.y);
	float4 t;
	if (flags & FLAG_SCREEN)
	{
		if (flags & FLAG_SCALED)
		{
			// edges repeat (a backdrop); tex_size (style.w) is the scale
			float2 tc = clamp((screen - i.src.xy) * i.style.w, 0.5, max(i.src.zw - 0.5, 0.5));
			t = image.SampleLevel(samp_border, tc / dim, 0);
		}
		else
		{
			int2 tc = clamp(int2(floor(screen - i.src.xy)), 0, max(int2(i.src.zw) - 1, 0));
			t = image.Load(int3(tc, 0));
		}
	}
	else if (flags & FLAG_SCALED)
	{
		// transparent past the reduced image (its ring, the texture's border)
		t = image.SampleLevel(samp_border, min(i.uv, i.src.zw + 0.5) / dim, 0);
	}
	else
	{
		t = image.Load(int3(int2(floor(i.uv)), 0));
	}
	if (flags & FLAG_MATRIX)
	{
		uint base = i.extra.w;
		uint n = min((uint)(grads[base].x + 0.5), 8);
		float4 v = float4(t.a > 0 ? convert_space(t.rgb / t.a, space, SPACE_SRGB) : 0, t.a);
		for (uint k = 0; k < n; k++)
		{
			uint e = base + 1 + k * 5;
			v = saturate(float4(dot(grads[e], v), dot(grads[e + 1], v), dot(grads[e + 2], v), dot(grads[e + 3], v)) + grads[e + 4]);
		}
		t = float4(v.rgb * v.a, v.a);
		space = SPACE_SRGB;
	}
	return t;
}

float4 ps_main(PSIn i) : SV_Target
{
	float2 p = i.rect_pos;
	// derivatives first, outside any branch: local units per screen pixel (constant per primitive), texture LOD
	float2 dpx = ddx(p), dpy = ddy(p);
	float2 duvx = ddx(i.uv), duvy = ddy(i.uv);
	float2 ldx = ddx(i.lpos), ldy = ddy(i.lpos);   // instance units per screen pixel (gradients, shadows)
	bool xf = i.extra.x != 0;
	uint kind = (uint)(i.style.z + 0.5);
	use_corner_shape((i.extra.z & FLAG_CIRCLE) != 0);
	// straight color in the target's space
	float4 color = i.color;
	color.rgb = color.a > 0 ? color.rgb / color.a : 0;
	color.rgb = convert_space(color.rgb, lerp_space(i.extra.z), target_space);
	uint tex_space = (i.extra.z & FLAG_TEX_SRGB) ? SPACE_SRGB : SPACE_LINEAR;
	float2 dir;
	float2 screen = i.pos.xy + target_origin;
	bool clipped = i.extra.y != 0 || rp_misc.y != 0;
	if (i.extra.z & FLAG_BLEND)
	{
		// the layer's texel and what lay under it; the batch writes the result (no hardware blending)
		uint ls = tex_space;
		float4 s = layer_texel(i, screen, ls);
		s = convert_premul(s, ls, target_space) * color.a;
		float4 d = backdrop.Load(int3(int2(floor(screen - i.radii.xy)), 0));
		float4 o = blend_composite(s, d, (i.extra.z >> BLEND_SHIFT) & 0xff);
		float cov = clipped ? any_clip_coverage(screen, i.extra.y) : 1;
		return lerp(d, o, cov);
	}
	float2 lp = i.lpos;
	if (kind == KIND_SHADOW)
	{
		float sigma = i.p2.x;
		uint sflags = (uint)(i.p2.y + 0.5);
		// below a third of a screen pixel the blur is invisible: the shape's antialiased coverage
		float px_per_unit = 1 / max(length(float2(length(ldx), length(ldy))) * 0.7071067811865476, 1e-6);
		// the other rect first: where it hides everything (inside the box of an outer shadow, outside the padding box of
		// an inset one), nothing to blur
		float other = (sflags & (SHADOW_INSET | SHADOW_HOLE)) ? rrect_coverage(lp, i.p0, i.p1, ldx, ldy) : 0;
		float keep = (sflags & SHADOW_INSET) ? other : 1 - other;
		if (keep <= 0) discard;
		float mask = sigma * px_per_unit < 0.33 ? rrect_coverage(lp, i.src, i.radii, ldx, ldy) : blurred_rrect(lp, i.src, i.radii, sigma);
		mask = (sflags & SHADOW_INSET) ? keep * (1 - mask) : keep * mask;
		color.a *= mask;
		if (clipped) color.a *= any_clip_coverage(screen, i.extra.y);
		return color;
	}
	bool dither = false;
	if (kind == KIND_GRADIENT)
	{
		bool srgb_out;
		float4 g = gradient_color(lp, i.extra.w, srgb_out, dither);
		color.rgb = convert_space(g.rgb, srgb_out ? SPACE_SRGB : SPACE_LINEAR, target_space);
		color.a *= g.a;
	}
	if (kind == KIND_GLYPH)
	{
		// coverage from the atlas, kept inside the glyph's cell (a transformed quad is grown past it)
		float h = 0.5 / max(i.style.w, 1);
		color.a *= text_coverage(atlas.SampleGrad(samp, clamp(i.uv, i.src.xy + h, i.src.zw - h), duvx, duvy), i);
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
			if (i.extra.z & (FLAG_LAYER | FLAG_SCREEN)) { texel = layer_texel(i, screen, tex_space); }
			else if (i.extra.z & FLAG_TILE) { texel = image.SampleGrad(samp_wrap, uv, duvx / dim, duvy / dim); }
			else
			{
				float2 h = 0.5 / dim;   // never filter in texels outside the source rect (sprite sheets)
				texel = image.SampleGrad(samp_img, clamp(uv, i.src.xy / dim + h, i.src.zw / dim - h), duvx / dim, duvy / dim);
			}
			// stored premultiplied, blended straight
			color.rgb *= convert_space(texel.a > 0 ? texel.rgb / texel.a : 0, tex_space, target_space);
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
	if (clipped) { color.a *= any_clip_coverage(screen, i.extra.y); }
	if (dither && color.a > 0)
	{
		// against banding: noise in the target's 8-bit encoding
		float n = dither_noise(screen);
		color.rgb = target_space == SPACE_SRGB ? saturate(color.rgb + n) : srgb_decode(srgb_encode(color.rgb) + n);
	}
	return color;
}
