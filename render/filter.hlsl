// Filter passes (CSS Filter Effects 1): one full-screen triangle per pass over the destination region. Texel t of the
// destination is screen pixel dst_origin + (t + 0.5) / dst_scale; sources are sampled at the same screen point
// (bilinear, transparent outside the texture). A pass writes its region plus a ring of one transparent texel past its
// right and bottom edges, and reads sources no further than their ring: what lies beyond (a pooled texture is not
// cleared) is never seen. Colors are processed as browsers do, in sRGB on premultiplied values; PASS_IN_LINEAR /
// PASS_OUT_LINEAR convert at the ends of a chain.

#define MODE_COLOR 0
#define MODE_BLUR 1
#define MODE_DOWNSAMPLE 2
#define MODE_SHADOW 3
#define MODE_MASK 4
#define PASS_IN_LINEAR 1
#define PASS_OUT_LINEAR 2
#define PASS_CLAMP 4
#define PASS_SRC2_LINEAR 8
#define PASS_MASK_LUMINANCE 16
#define PASS_MASK_DEST 32
#define PASS_MASK_APPLY 64
#define MASK_OP_SHIFT 8
#define MAX_TAPS 64
#define MAX_MATRICES 8

cbuffer PassConstants : register(b1)
{
	float2 src_origin; float src_scale; uint mode;
	float2 src_size; float2 src_dim;
	float2 dst_origin; float dst_scale; uint flags;
	float2 src2_origin; float src2_scale; uint taps;
	float2 src2_size; float2 src2_dim;
	float2 dir; float2 offset;
	float4 color;
	uint matrix_count; float2 dst_size; float factor;
	float4 tap[MAX_TAPS / 2];
	float4 m[MAX_MATRICES * 5];
};

Texture2D<float4> src  : register(t0);
Texture2D<float4> src2 : register(t1);
SamplerState samp : register(s0);   // bilinear, border = transparent

float4 vs_fx(uint vid : SV_VertexID) : SV_Position
{
	float2 p = float2((vid << 1) & 2, vid & 2);
	return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}

float3 encode(float3 c)
{
	c = saturate(c);
	return (c <= 0.0031308) ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float3 decode(float3 c)
{
	c = saturate(c);
	return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float4 to_srgb(float4 c)
{
	if (c.a <= 0) return 0;
	return float4(encode(c.rgb / c.a) * c.a, c.a);
}

float4 to_linear(float4 c)
{
	if (c.a <= 0) return 0;
	return float4(decode(c.rgb / c.a) * c.a, c.a);
}

// A source texel position (continuous, in texels) sampled: with PASS_CLAMP kept inside the valid region (edges
// repeat), else kept within the transparent ring past it (left and top: the texture's own border).
float4 sample_at(Texture2D<float4> t, float2 tc, float2 size, float2 dim, bool lin)
{
	if (flags & PASS_CLAMP) tc = clamp(tc, 0.5, max(size - 0.5, 0.5));
	else tc = min(tc, size + 0.5);
	float4 c = t.SampleLevel(samp, tc / dim, 0);
	return lin ? to_srgb(c) : c;
}

float4 ps_fx(float4 pos : SV_Position) : SV_Target
{
	if (any(pos.xy > dst_size)) return 0;   // the ring
	float2 p = dst_origin + pos.xy / dst_scale;   // screen point of this texel's center
	float2 tc = (p - src_origin) * src_scale;
	bool lin = (flags & PASS_IN_LINEAR) != 0;
	float4 c = 0;
	if (mode == MODE_BLUR)
	{
		for (uint i = 0; i < taps && i < MAX_TAPS; i++)
		{
			float4 tp = tap[i / 2];
			float2 ow = (i & 1) ? tp.zw : tp.xy;
			if (i == 0) c += ow.y * sample_at(src, tc, src_size, src_dim, lin);
			else c += ow.y * (sample_at(src, tc + dir * ow.x, src_size, src_dim, lin) + sample_at(src, tc - dir * ow.x, src_size, src_dim, lin));
		}
	}
	else if (mode == MODE_DOWNSAMPLE)
	{
		// a factor x factor box: bilinear taps centered between texel pairs, (factor / 2)^2 of them
		uint n = (uint)(factor * 0.5 + 0.5);
		float first = 1 - (float)n;
		for (uint y = 0; y < n; y++)
		{
			for (uint x = 0; x < n; x++)
			{
				c += sample_at(src, tc + float2(first + 2 * x, first + 2 * y), src_size, src_dim, lin);
			}
		}
		c /= (float)(n * n);
	}
	else if (mode == MODE_SHADOW)
	{
		float a = sample_at(src, (p - offset - src_origin) * src_scale, src_size, src_dim, false).a;
		float4 o = sample_at(src2, (p - src2_origin) * src2_scale, src2_size, src2_dim, (flags & PASS_SRC2_LINEAR) != 0);
		float4 sh = float4(color.rgb * color.a, color.a) * a;
		c = o + sh * (1 - o.a);
	}
	else if (mode == MODE_MASK)
	{
		// src2: a mask layer (premultiplied sRGB); its coverage is its alpha, or its luminance (CSS Masking 1 §7.1:
		// the luminance of the straight color times the alpha, i.e. of the premultiplied color)
		float4 m = sample_at(src2, (p - src2_origin) * src2_scale, src2_size, src2_dim, (flags & PASS_SRC2_LINEAR) != 0);
		float s = (flags & PASS_MASK_LUMINANCE) ? saturate(dot(m.rgb, float3(0.2125, 0.7154, 0.0721))) : m.a;
		if (flags & PASS_MASK_APPLY)
		{
			// src: the masked content, in whatever space it is (scaling premultiplied color commutes with it), maybe
			// reduced (a large blur last); read no further than its ring
			c = sample_at(src, tc, src_size, src_dim, false) * s;
		}
		else
		{
			// src: the mask layers below, composited so far (mask-composite: add, subtract, intersect, exclude)
			float r = s;
			if (flags & PASS_MASK_DEST)
			{
				float d = sample_at(src, tc, src_size, src_dim, false).a;
				uint op = (flags >> MASK_OP_SHIFT) & 3;
				if (op == 0) r = s + d * (1 - s);
				else if (op == 1) r = s * (1 - d);
				else if (op == 2) r = s * d;
				else r = s * (1 - d) + d * (1 - s);
			}
			c = float4(r, r, r, r);
		}
		return c;
	}
	else
	{
		c = sample_at(src, tc, src_size, src_dim, lin);
		if (mode == MODE_COLOR && matrix_count > 0)
		{
			float4 v = float4(c.a > 0 ? c.rgb / c.a : 0, c.a);
			for (uint k = 0; k < matrix_count && k < MAX_MATRICES; k++)
			{
				v = saturate(float4(dot(m[k * 5], v), dot(m[k * 5 + 1], v), dot(m[k * 5 + 2], v), dot(m[k * 5 + 3], v)) + m[k * 5 + 4]);
			}
			c = float4(v.rgb * v.a, v.a);
		}
	}
	if (flags & PASS_OUT_LINEAR) c = to_linear(c);
	return c;
}
