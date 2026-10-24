// The frame of an application shader (draw.app_shader, render.create_app_shader). The module the backends compile is
//     rect.wgsl  +  this file  +  the application's WGSL
// concatenated in that order (shaders.odin: app_module_source), so the application's code sees everything rect.wgsl declares
// (the samplers `samp`, `samp_img` (trilinear, clamp) and `samp_wrap` (trilinear, repeat), the transforms, the clips...) and
// only has to define
//
//     fn app_shade(a: AppIn) -> vec4<f32>
//
// which returns the color of one pixel of the rectangle: LINEAR light, STRAIGHT alpha (not premultiplied). The vertex stage is
// rect.wgsl's vs_main, so the rectangle follows the transforms, the corner radii and the clips exactly as `draw.rect` does; the
// entry point below multiplies the result by the coverage of the (rounded) rectangle and of the clips, by the tint and the alpha
// stack of the draw call, converts it to the blend space of the target, and the blend mode of the draw (normal, add, screen,
// multiply: fixed-function blending of the premultiplied result) mixes it with what lies under.
//
// Per-draw data (draw.app_shader's `params`) is read with app_param(k): the k-th vec4 of the draw. The textures of the draw
// are app_tex0 .. app_tex3 (texture_2d<f32>; a slot the draw did not fill is a 1 x 1 transparent texture). Sample them with
// textureSample (a mipmapped data texture with samp_img / samp_wrap) or textureSampleLevel, and with textureLoad.
// app_shade runs in uniform control flow: derivatives and textureSample are allowed anywhere in it.

@group(2) @binding(0) var<storage, read> app_params: array<float4>;
@group(2) @binding(1) var app_tex0: texture_2d<f32>;
@group(2) @binding(2) var app_tex1: texture_2d<f32>;
@group(2) @binding(3) var app_tex2: texture_2d<f32>;
@group(2) @binding(4) var app_tex3: texture_2d<f32>;

var<private> app_base: u32;

fn app_param(k: u32) -> float4 { return app_params[app_base + k]; }

struct AppIn {
	uv: float2,       // position in the rectangle: (0, 0) top-left, (1, 1) bottom-right (outside 0..1 on the antialiased rim)
	pos: float2,      // the same in local units (what the application drew the rectangle in), from the top-left corner
	size: float2,     // size of the rectangle, local units
	px: f32,          // screen pixels per local unit (the scale the transforms give the rectangle)
	frag: float2,     // the pixel in the render target (a layer is its own target)
	space: u32,       // blend space of the target: 0 linear, 1 sRGB (the color returned is linear either way)
};

@fragment
fn ps_app(i: PSIn) -> @location(0) float4 {
	// derivatives first, outside any branch
	let p = i.rect_pos;
	let dpx = dpdx(p);
	let dpy = dpdy(p);
	let xf = i.extra.x != 0u;
	use_corner_shape((i.extra.z & FLAG_CIRCLE) != 0u);
	app_base = i.extra.w;

	let size = i.half_size * 2.0;
	var a: AppIn;
	a.uv = p / max(size, float2(1e-6)) + 0.5;
	a.pos = p + i.half_size;
	a.size = size;
	a.px = 1.0 / max(sqrt(abs(dpx.x * dpy.y - dpx.y * dpy.x)), 1e-6);
	a.frag = i.pos.xy;
	a.space = g.target_space;
	var c = app_shade(a);

	// the rounded rectangle's own coverage (rect.wgsl, ps_main), then the clips around it
	let sd = rect_sdf_dir(p, i.half_size, corner_radius(p, i.radii));
	var s = sd.x;
	if (xf) { s = to_px(s, sd.yz, dpx, dpy); }
	var coverage = saturate(0.5 - s);
	let screen = i.pos.xy + g.target_origin;
	if (i.extra.y != 0u || rp.misc.y != 0u) { coverage = coverage * any_clip_coverage(screen, i.extra.y); }

	// the tint (straight, linear) and the alpha stack ride in the instance color
	var tint = i.color;
	if (tint.a > 0.0) { tint = float4(tint.rgb / tint.a, tint.a); } else { tint = float4(0.0, 0.0, 0.0, 0.0); }
	tint = float4(convert_space(tint.rgb, g.target_space, SPACE_LINEAR), tint.a);   // (vs_main encoded it for the target)
	let rgb = convert_space(max(c.rgb, float3(0.0)) * tint.rgb, SPACE_LINEAR, g.target_space);
	let alpha = saturate(c.a) * tint.a * coverage;
	return float4(rgb * alpha, alpha);
}
