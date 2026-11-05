// The instanced-quad pixel shader for a target that keeps a blend factor per channel (after rect.wgsl): text with a coverage per
// colour stripe. The second colour is what the first is blended by: anything else has its alpha there on all three channels,
// which is what blending by the alpha does. Direct3D 11 only. `rect_shade` is rect.wgsl's ps_main, as a function in this module
// (shaders.odin: module_source).

struct Dual_Out {
	@location(0) @blend_src(0) color: float4,
	@location(0) @blend_src(1) factor: float4,
};

@fragment
fn ps_main_dual(i: PSIn) -> Dual_Out {
	var o: Dual_Out;
	o.color = rect_shade(i);
	o.factor = float4(o.color.a * lcd_weight, o.color.a);
	return o;
}
