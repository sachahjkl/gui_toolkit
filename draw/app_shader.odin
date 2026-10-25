package draw

import "../render"

// Application shaders: a rounded rectangle filled by a fragment function the application wrote (render.create_app_shader, docs/shaders.md).
// It is drawn in order with everything else, under the current transform, clips, alpha and layers, like `rect`.

// Fills `r` (current local space) with `shader`. `params` are the vec4 values the shader reads with app_param(k) (at most
// render.MAX_APP_PARAMS), `textures` its app_tex0 .. app_tex3 (render.MAX_APP_TEXTURES; 0 or fewer: a transparent texel), `blend` how its
// result mixes with what lies under, `radii` the corners (top-left, bottom-left, top-right, bottom-right, like `rect_corners`), `tint` a
// linear color the result is multiplied by (the alpha stack applies too).
//
// Returns false, and draws nothing, when it cannot: `shader` is 0 (it failed to build: the caller draws its fallback), a picture is
// being recorded (an application shader is not recordable: its parameters change every frame; draw it around the replay), or
// there are too many parameters or textures.
//
// Inside a plane or a layer that is kept (`cache_key`), the result is part of the kept pixels: a shader that changes with time must
// change the key too (or the layer is not cached).
app_shader :: proc(c: ^Context, shader: render.App_Shader, r: Rect, params: []Vec4, textures: []render.Texture = nil,
                   blend := render.App_Blend.Normal, radii: [4]f32 = {}, tint: Color = WHITE) -> bool {
	if shader == 0 || c.rec != nil || len(params) > render.MAX_APP_PARAMS || len(textures) > render.MAX_APP_TEXTURES { return false }
	xf, alpha, shape := cur(c)
	close_batch(c)
	first := len(c.insts)
	col := tint
	col.a *= alpha
	inst := render.Rect_Inst{
		src = {0, 0, 1, 1}, colors = {col, col, col, col}, soft = 1, use_tex = render.KIND_APP, tex_size = 1, clip = shape,
		aux = u32(len(c.app_params)), flags = c.circular ? render.FLAG_CIRCLE : 0,
	}
	if xf.simple && xf.m.a == 1 {
		// a translation only: the rectangle's pixels are local units. Any scale goes through a transform, so that the shader's
		// pos, size and px stay in local units (a scale baked into the rectangle would make them pixels).
		o := Vec2{xf.m.e, xf.m.f}
		inst.dst = {r.min.x + o.x, r.min.y + o.y, r.max.x + o.x, r.max.y + o.y}
		inst.radii = radii
	} else {
		inst.dst = {r.min.x, r.min.y, r.max.x, r.max.y}
		inst.radii = radii
		inst.xform = gpu_xform(c, xf)
	}
	append(&c.insts, inst)
	for p in params { append(&c.app_params, p) }
	if len(params) == 0 { append(&c.app_params, Vec4{}) }
	d := render.App_Draw{shader = shader, blend = blend}
	for t, k in textures { d.textures[k] = t }
	append(&c.apps, d)
	cl := c.clips[len(c.clips) - 1]
	append(&c.batches, render.Batch{
		clip = {cl.rect.min.x, cl.rect.min.y, cl.rect.max.x, cl.rect.max.y}, first = first, count = 1, target = c.target,
		shape = cl.shape, app = len(c.apps),
	})
	start_batch(c)
	return true
}

Vec4 :: [4]f32
