#+build windows
package render

import "core:fmt"
import "core:mem"
import "core:strings"
import win "core:sys/windows"
import "vendor:directx/d3d11"

// Direct3D 11 side of application shaders (app_shader.odin has the shared types and the create / destroy bookkeeping):
// compiling the HLSL naga wrote, the pixel shaders, the per-mode blend states, the draw and the empty texture. Built
// only for the Direct3D backend (`!USE_WGPU`); the wgpu side is wgpu_app.odin.
when !USE_WGPU {

// Compiles the pixel shader of an application module from the HLSL naga wrote for it (tools/shaders). The bytes are in `allocator`.
compile_app_hlsl :: proc(hlsl: string, allocator := context.allocator) -> (code: []u8, ok: bool) {
	blob := compile(hlsl, APP_PS_ENTRY, "ps_5_0", "app.hlsl") or_return
	defer blob->Release()
	src := mem.slice_ptr(cast([^]u8)blob->GetBufferPointer(), int(blob->GetBufferSize()))
	code = make([]u8, len(src), allocator)
	copy(code, src)
	return code, true
}

@(private)
d3d_app_shader_make :: proc(r: ^Renderer, d: ^App_Shader_Data, hash: string) -> bool {
	if len(d.dxbc) == 0 {
		fmt.eprintfln("render: app shader %s: no Direct3D 11 pixel shader (run tools/shaders -- app)", d.name)
		return false
	}
	want := app_module_hash(d.wgsl, context.temp_allocator)
	if strings.trim_space(hash) != want {
		fmt.eprintfln("render: app shader %s: the compiled pixel shader was built from other sources (%s, now %s): run tools/shaders -- app", d.name, strings.trim_space(hash), want)
		return false
	}
	return d3d_app_ps_create(r, d)
}

@(private)
d3d_app_ps_create :: proc(r: ^Renderer, d: ^App_Shader_Data) -> bool {
	if len(d.dxbc) == 0 {
		fmt.eprintfln("render: app shader %s: no pixel shader to make", d.name)
		return false
	}
	if win.FAILED(r.device->CreatePixelShader(raw_data(d.dxbc), uint(len(d.dxbc)), nil, &d.ps)) || d.ps == nil {
		fmt.eprintfln("render: app shader %s: the device refused the pixel shader", d.name)
		d.ps = nil
		return false
	}
	return true
}

@(private)
d3d_app_shader_release :: proc(d: ^App_Shader_Data) {
	if d.ps != nil { d.ps->Release(); d.ps = nil }
}

// After a device loss: the pixel shaders again, from their blobs.
@(private)
d3d_app_shaders_recreate :: proc(r: ^Renderer) {
	for &d in r.apps {
		if d.live { d3d_app_ps_create(r, &d) }   // (a failure leaves it unready: its handle stays reserved, see app_shader_ready)
	}
}

// The blend states of the four modes (premultiplied results).
@(private)
d3d_app_blend_states :: proc(r: ^Renderer) {
	for mode in App_Blend {
		bd := d3d11.BLEND_DESC{}
		rt := d3d11.RENDER_TARGET_BLEND_DESC{
			BlendEnable = true, BlendOp = .ADD, BlendOpAlpha = .ADD,
			SrcBlendAlpha = .ONE, DestBlendAlpha = .INV_SRC_ALPHA,
			RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
		}
		switch mode {
		case .Normal:   rt.SrcBlend, rt.DestBlend = .ONE, .INV_SRC_ALPHA
		case .Add:      rt.SrcBlend, rt.DestBlend = .ONE, .ONE
		case .Screen:   rt.SrcBlend, rt.DestBlend = .ONE, .INV_SRC_COLOR
		case .Multiply: rt.SrcBlend, rt.DestBlend = .DEST_COLOR, .INV_SRC_ALPHA
		}
		bd.RenderTarget[0] = rt
		r.device->CreateBlendState(&bd, &r.app_blend[mode])
	}
}

// Draws the instance of an application batch with its shader, textures and parameters; the main pipeline's state is put back.
@(private)
d3d_draw_app :: proc(r: ^Renderer, f: Frame_Data, b: Batch) {
	if b.app <= 0 || b.app > len(f.apps) { return }
	a := f.apps[b.app - 1]
	d := app_shader_get(r, a.shader)
	if d == nil || d.ps == nil || r.app_params_view == nil || r.app_blend[a.blend] == nil { return }
	if r.slug.on { slug_select(r, false) }
	views: [1 + MAX_APP_TEXTURES]^d3d11.IShaderResourceView
	views[0] = r.app_params_view
	for t, k in a.textures { views[1 + k] = texture_view(r, t) != nil ? texture_view(r, t) : r.app_empty_view }
	r.ctx->PSSetShaderResources(APP_PARAMS_REGISTER, u32(len(views)), &views[0])
	r.ctx->PSSetShader(d.ps, nil, 0)
	r.ctx->OMSetBlendState(r.app_blend[a.blend], nil, ~u32(0))
	r.ctx->DrawInstanced(4, 1, 0, u32(b.first))
	none: [1 + MAX_APP_TEXTURES]^d3d11.IShaderResourceView
	r.ctx->PSSetShaderResources(APP_PARAMS_REGISTER, u32(len(none)), &none[0])
	r.ctx->PSSetShader(r.ps, nil, 0)
	r.ctx->OMSetBlendState(r.blend, nil, ~u32(0))
}

// A 1 x 1 transparent texture for the slots a draw leaves empty (made with the pipeline).
@(private)
d3d_app_empty_texture :: proc(r: ^Renderer) {
	desc := d3d11.TEXTURE2D_DESC{
		Width = 1, Height = 1, MipLevels = 1, ArraySize = 1, Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}
	zero: [4]u8
	init := d3d11.SUBRESOURCE_DATA{pSysMem = &zero[0], SysMemPitch = 4}
	if r.device->CreateTexture2D(&desc, &init, &r.app_empty_tex) == 0 && r.app_empty_tex != nil {
		r.device->CreateShaderResourceView(r.app_empty_tex, nil, &r.app_empty_view)
	}
}

@(private)
d3d_app_objects_release :: proc(r: ^Renderer) {
	for &s in r.app_blend { if s != nil { s->Release(); s = nil } }
	if r.app_params_view != nil { r.app_params_view->Release(); r.app_params_view = nil }
	if r.app_params_buf != nil { r.app_params_buf->Release(); r.app_params_buf = nil }
	r.app_params_cap = 0
	if r.app_empty_view != nil { r.app_empty_view->Release(); r.app_empty_view = nil }
	if r.app_empty_tex != nil { r.app_empty_tex->Release(); r.app_empty_tex = nil }
	for &d in r.apps { d3d_app_shader_release(&d) }
}

}   // when !USE_WGPU
