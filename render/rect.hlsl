// One instanced quad draws every primitive: filled / bordered / soft rounded rects (signed distance field)
// and glyphs (atlas coverage). Colors arrive in LINEAR space and the render target view is sRGB, so blending
// happens in linear space (same choice as raddebugger).

cbuffer Globals : register(b0)
{
	float2 viewport_size;
	float2 _pad;
};

Texture2D<float> atlas : register(t0);
SamplerState samp : register(s0);

struct VSIn
{
	float4 dst   : DST;      // x0 y0 x1 y1 in pixels
	float4 src   : SRC;      // u0 v0 u1 v1 in texels
	float4 c0    : C0;       // corner colors: top-left, bottom-left, top-right, bottom-right
	float4 c1    : C1;
	float4 c2    : C2;
	float4 c3    : C3;
	float4 radii : RADII;    // top-left, bottom-left, top-right, bottom-right
	float4 style : STYLE;    // border thickness, softness, use texture, texture size
	uint vid     : SV_VertexID;
};

struct PSIn
{
	float4 pos : SV_Position;
	float2 rect_pos : RECT_POS;                 // pixels from the rect center
	nointerpolation float2 half_size : HALF;
	float2 uv : UV;
	float4 color : COLOR;
	nointerpolation float4 radii : RADII;
	nointerpolation float4 style : STYLE;
};

PSIn vs_main(VSIn i)
{
	float2 corner = float2(i.vid >> 1, i.vid & 1);   // 0: (0,0) 1: (0,1) 2: (1,0) 3: (1,1) as a triangle strip
	float2 pix = lerp(i.dst.xy, i.dst.zw, corner);
	float2 size = i.dst.zw - i.dst.xy;
	PSIn o;
	o.pos = float4(pix.x / viewport_size.x * 2 - 1, 1 - pix.y / viewport_size.y * 2, 0, 1);
	o.rect_pos = (corner - 0.5) * size;
	o.half_size = size * 0.5;
	float tex = max(i.style.w, 1);
	o.uv = lerp(i.src.xy, i.src.zw, corner) / tex;
	o.color = (i.vid == 0) ? i.c0 : ((i.vid == 1) ? i.c1 : ((i.vid == 2) ? i.c2 : i.c3));
	o.radii = i.radii;
	o.style = i.style;
	return o;
}

float rect_sdf(float2 p, float2 half_size, float r)
{
	float2 d = abs(p) - half_size + r;
	return min(max(d.x, d.y), 0) + length(max(d, 0)) - r;
}

float4 ps_main(PSIn i) : SV_Target
{
	float4 color = i.color;
	if (i.style.z > 0.5)
	{
		// glyph: coverage from the atlas, no shape math
		color.a *= atlas.Sample(samp, i.uv);
		return color;
	}
	float2 p = i.rect_pos;
	float r = (p.x < 0) ? ((p.y < 0) ? i.radii.x : i.radii.y) : ((p.y < 0) ? i.radii.z : i.radii.w);
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
		float s = rect_sdf(p, i.half_size, r);
		coverage = saturate(0.5 - s);
		if (border > 0)
		{
			float inner = rect_sdf(p, i.half_size - border, max(r - border, 0));
			coverage *= saturate(inner + 0.5);
		}
	}
	color.a *= coverage;
	return color;
}
