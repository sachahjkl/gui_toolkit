// Slug text with a coverage per colour stripe (after rect.wgsl and slug.wgsl), for a target that keeps a blend factor per channel.
// The coverage of a sample is over a box a pixel wide: taken a third of a pixel to each side, it is three stripes each filtered
// over their neighbours, what keeps the colours of the edges faint. No filter of its own.

struct Slug_Dual_Out {
	@location(0) @blend_src(0) color: float4,
	@location(0) @blend_src(1) factor: float4,
};

// The coverage around the pixel's centre moved by `dx` pixels. Small text: two samples over half-pixel boxes, side by side, which
// together span the same pixel's width (ps_slug's four, for each stripe, would be twelve).
fn slug_stripe(i: SlugPS, dx: f32, e: float2, ppe: float2) -> f32 {
	if (i.small.y > 0.5) {
		return 0.5 * (SlugRender(i.tex + float2(dx - 0.25, -0.25) * e, i.banding, i.glyph, ppe * 2.0, slug_dk(i) * 2.0) +
		              SlugRender(i.tex + float2(dx + 0.25,  0.25) * e, i.banding, i.glyph, ppe * 2.0, slug_dk(i) * 2.0));
	}
	return SlugRender(i.tex + float2(dx, 0.0) * e, i.banding, i.glyph, ppe, slug_dk(i));
}

@fragment
fn ps_slug_dual(i: SlugPS) -> Slug_Dual_Out {
	// derivatives first, before anything that can branch away
	let e = fwidth(i.tex);
	let ppe = 1.0 / e;
	let side = i.small.z / 3.0;   // (the first stripe is at -1/3 of a pixel, -: blue first. 0: not along the pixels' rows)
	var c3 = float3(slug_stripe(i, 0.0, e, ppe));
	if (side != 0.0) {
		c3.x = slug_stripe(i, -side, e, ppe);
		c3.z = slug_stripe(i, side, e, ppe);
	}
	c3 = float3(slug_text_coverage(c3.x, i), slug_text_coverage(c3.y, i), slug_text_coverage(c3.z, i));
	var a = i.color.a;
	if (i.clip != 0u || rp.misc.y != 0u) { a = a * any_clip_coverage(i.pos.xy + g.target_origin, i.clip); }
	var o: Slug_Dual_Out;
	o.factor = float4(a * c3, a * (c3.x + c3.y + c3.z) / 3.0);
	o.color = float4(i.color.rgb, o.factor.a);
	return o;
}
