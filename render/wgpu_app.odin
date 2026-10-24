package render

import "core:fmt"
import "core:sync"
import "core:time"
import "vendor:wgpu"

// Application shaders on the WebGPU backend (app_shader.odin): the module is rect.wgsl + app.wgsl + the application's WGSL, the
// vertex stage is rect.wgsl's vs_main, the fragment stage ps_app. Group 2 of the pipeline layout holds the draw's parameters and
// textures. One pipeline per (target format, blend mode), made when first needed.

@(private)
wgpu_app_shader_make :: proc(r: ^Renderer, d: ^App_Shader_Data) -> bool {
	g := &r.wg
	if g.device == nil { return false }
	src := app_module_source(d.wgsl, context.temp_allocator)
	errors := g.shared.errors
	sync.mutex_lock(&g_compile_lock)
	d.module = wgpu_module(g, d.name, src)
	sync.mutex_unlock(&g_compile_lock)
	if d.module == nil || g.shared.errors != errors {
		fmt.eprintfln("render: app shader %s: the WGSL was refused", d.name)
		if d.module != nil { wgpu.ShaderModuleRelease(d.module); d.module = nil }
		return false
	}
	return true
}

@(private)
wgpu_app_shader_release :: proc(r: ^Renderer, d: ^App_Shader_Data) {
	for p in d.pipes { wgpu.RenderPipelineRelease(p.pipe) }
	clear(&d.pipes)
	if d.module != nil { wgpu.ShaderModuleRelease(d.module); d.module = nil }
}

// After a device loss: the modules again (the pipelines are made when drawn).
@(private)
wgpu_app_shaders_recreate :: proc(r: ^Renderer) {
	for &d in r.apps {
		if d.live && !wgpu_app_shader_make(r, &d) { d.live = false }
	}
}

@(private)
wgpu_app_blend :: proc(mode: App_Blend) -> wgpu.BlendState {
	b := wgpu.BlendState{
		color = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
		alpha = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
	}
	switch mode {
	case .Normal:
	case .Add:      b.color.dstFactor = .One
	case .Screen:   b.color.dstFactor = .OneMinusSrc
	case .Multiply: b.color.srcFactor = .Dst
	}
	return b
}

@(private)
wgpu_app_pipeline :: proc(r: ^Renderer, d: ^App_Shader_Data, format: wgpu.TextureFormat, mode: App_Blend) -> wgpu.RenderPipeline {
	g := &r.wg
	sync.mutex_guard(&g.pipe_lock)
	for p in d.pipes { if p.format == format && p.blend == mode { return p.pipe } }
	t0 := time.tick_now()
	attrs := [?]wgpu.VertexAttribute{
		{format = .Float32x4, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = 16, shaderLocation = 1},
		{format = .Float32x4, offset = 32, shaderLocation = 2},
		{format = .Float32x4, offset = 48, shaderLocation = 3},
		{format = .Float32x4, offset = 64, shaderLocation = 4},
		{format = .Float32x4, offset = 80, shaderLocation = 5},
		{format = .Float32x4, offset = 96, shaderLocation = 6},
		{format = .Float32x4, offset = 112, shaderLocation = 7},
		{format = .Uint32x4, offset = 128, shaderLocation = 8},
	}
	vb := wgpu.VertexBufferLayout{stepMode = .Instance, arrayStride = size_of(Rect_Inst), attributeCount = len(attrs), attributes = raw_data(attrs[:])}
	blend := wgpu_app_blend(mode)
	target := wgpu.ColorTargetState{format = format, blend = &blend, writeMask = wgpu.ColorWriteMaskFlags_All}
	fs := wgpu.FragmentState{module = d.module, entryPoint = APP_PS_ENTRY, targetCount = 1, targets = &target}
	sync.mutex_lock(&g_compile_lock)
	pipe := wgpu.DeviceCreateRenderPipeline(g.device, &{
		label = "app", layout = g.pl_app,
		vertex = {module = d.module, entryPoint = "vs_main", bufferCount = 1, buffers = &vb},
		primitive = {topology = .TriangleStrip, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = 0xFFFFFFFF},
		fragment = &fs,
	})
	sync.mutex_unlock(&g_compile_lock)
	g.t_pipelines += time.duration_milliseconds(time.tick_since(t0)); g.n_pipelines += 1
	append(&d.pipes, App_Pipe{format, mode, pipe})
	return pipe
}

// Draws the instance of an application batch. Groups 0 and 1 are the frame's (set by the caller).
@(private)
wgpu_draw_app :: proc(r: ^Renderer, s: ^Submit, b: Batch, format: wgpu.TextureFormat, bound: ^wgpu.RenderPipeline) {
	f := s.f
	if b.app <= 0 || b.app > len(f.apps) { return }
	g := &r.wg
	a := f.apps[b.app - 1]
	d := app_shader_get(r, a.shader)
	if d == nil || d.module == nil || g.app_params.buf == nil { return }
	pipe := wgpu_app_pipeline(r, d, format, a.blend)
	if pipe == nil { return }
	e: [1 + MAX_APP_TEXTURES]wgpu.BindGroupEntry
	e[0] = {binding = 0, buffer = g.app_params.buf, size = wgpu.WHOLE_SIZE}
	for t, k in a.textures { e[1 + k] = {binding = u32(1 + k), textureView = tex_view(r, t, g.dummy_rgba_view)} }
	bg := wgpu.DeviceCreateBindGroup(g.device, &{label = "app", layout = g.bgl_app, entryCount = len(e), entries = raw_data(e[:])})
	append(&s.groups, bg)
	if pipe != bound^ { bound^ = pipe; wgpu.RenderPassEncoderSetPipeline(s.pass, pipe) }
	wgpu.RenderPassEncoderSetBindGroup(s.pass, 2, bg)
	wgpu.RenderPassEncoderDraw(s.pass, 4, 1, 0, u32(b.first))
}
