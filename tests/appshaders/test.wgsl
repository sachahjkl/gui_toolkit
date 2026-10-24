// The shader of tests/appshaders: param 0 selects what it draws (x = mode), param 1 is a color.
//   mode 0  the color param 1 (linear, straight)
//   mode 1  a ramp: red = uv.x, green = uv.y, blue = param 1 .z
//   mode 2  texel 0 at uv, as it is stored (a data texture: no color conversion)
//   mode 3  the size of the rectangle in local units / 100, the scale in pixels per unit / 10, and 1
//   mode 4  texel 1 at uv, then texel 0 (the second texture replaces the first where it is opaque)
fn app_shade(a: AppIn) -> vec4<f32> {
	let mode = u32(app_param(0u).x + 0.5);
	let c = app_param(1u);
	if (mode == 1u) { return vec4<f32>(a.uv.x, a.uv.y, c.z, 1.0); }
	if (mode == 2u) { return textureSample(app_tex0, samp_img, a.uv); }
	if (mode == 3u) { return vec4<f32>(a.size.x / 100.0, a.size.y / 100.0, a.px / 10.0, 1.0); }
	if (mode == 4u) {
		let t1 = textureSample(app_tex1, samp_img, a.uv);
		let t0 = textureSample(app_tex0, samp_img, a.uv);
		return mix(t0, vec4<f32>(t1.rgb, 1.0), t1.a);
	}
	return c;
}
