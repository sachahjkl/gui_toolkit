package render

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:wgpu"

// Application shaders: a fragment function the application writes in WGSL, drawn over a rounded rectangle by draw.app_shader (see
// docs/shaders.md). The module is rect.wgsl + app.wgsl + the application's WGSL: the vertex stage, the transforms, the clips and the
// corner shapes are the renderer's own, the application only supplies `fn app_shade(a: AppIn) -> vec4<f32>`. WebGPU compiles the
// module as it is. Direct3D 11 needs the pixel shader as DXBC, produced offline from the same WGSL by naga and the HLSL compiler
// (`odin run tools/shaders -- app <name> <file.wgsl> <dir>`: <dir>/<name>.dxbc and <dir>/<name>.sha256); the toolkit checks the SHA-256
// of the module against the one the blob was built from, so a blob that is stale (the application's WGSL or the toolkit's rect.wgsl
// changed) is refused with a message instead of drawing garbage. The vertex shader of the D3D11 pipeline is the renderer's.

WGSL_APP :: #load("app.wgsl", string)

// group.binding = register of the resources of an application module (rect.wgsl's, then group 2): the parameters t13, the textures t14..t17.
APP_BINDINGS :: []string{
	"0.0=b0", "0.1=b2", "0.2=t2", "0.3=t3", "0.4=t4", "0.5=t6", "0.6=t7", "0.7=t8", "0.8=t9", "0.9=t10",
	"0.10=s0", "0.11=s1", "0.12=s2", "1.0=t0", "1.1=t1", "1.2=t5",
	"2.0=t13", "2.1=t14", "2.2=t15", "2.3=t16", "2.4=t17",
}
APP_PS_ENTRY :: "ps_app"
APP_PARAMS_REGISTER :: 13

KIND_APP :: 6   // a Rect_Inst drawn by an application shader (Batch.app says which; the instance's `aux` is the first vec4 of its parameters)

MAX_APP_TEXTURES :: 4
MAX_APP_PARAMS :: 64   // vec4 per draw

// How the result of an application shader is mixed with what lies under it (the result is premultiplied: rgb * a, a).
App_Blend :: enum u8 {
	Normal,     // over
	Add,        // dst + src: light (a glow adds its color, scaled by its alpha)
	Screen,     // src + dst - src * dst
	Multiply,   // src * dst + dst * (1 - src alpha)
}

App_Shader :: distinct int

App_Shader_Desc :: struct {
	name: string,    // for messages
	wgsl: string,    // the application's part of the module (defines app_shade); must stay valid as long as the shader lives
	dxbc: []u8,      // Direct3D 11: the pixel shader (ps_app) compiled from app_module_source(wgsl); must stay valid too
	hash: string,    // Direct3D 11: the SHA-256 of that source, as written next to the blob (checked against the wgsl)
}

// One draw of an application shader: Batch.app indexes Frame_Data.apps (+ 1). The batch is a single instance (KIND_APP).
App_Draw :: struct {
	shader:   App_Shader,
	textures: [MAX_APP_TEXTURES]Texture,   // 0: a transparent 1 x 1 texture
	blend:    App_Blend,
}

@(private)
App_Pipe :: struct {
	format: wgpu.TextureFormat,
	blend:  App_Blend,
	pipe:   wgpu.RenderPipeline,
}

@(private)
App_Shader_Data :: struct {
	name:   string,   // cloned
	wgsl:   string,
	dxbc:   []u8,
	ps:     ^d3d11.IPixelShader,
	module: wgpu.ShaderModule,
	pipes:  [dynamic]App_Pipe,
	live:   bool,
}

// The WGSL of an application module as naga and WebGPU read it.
app_module_source :: proc(app_wgsl: string, allocator := context.allocator) -> string {
	b := make([dynamic]u8, allocator)
	for s in ([]string{WGSL_RECT, WGSL_APP, app_wgsl}) {
		append(&b, s)
		append(&b, '\n')
	}
	return string(b[:])
}

// The SHA-256 of app_module_source(app_wgsl), in hex: what the blob of the shader records.
app_module_hash :: proc(app_wgsl: string, allocator := context.allocator) -> string {
	src := app_module_source(app_wgsl, context.temp_allocator)
	digest := hash.hash_string(.SHA256, src, context.temp_allocator)
	return string(hex.encode(digest, allocator))
}

// Compiles the pixel shader of an application module from the HLSL naga wrote for it (tools/shaders). The bytes are in `allocator`.
compile_app_hlsl :: proc(hlsl: string, allocator := context.allocator) -> (code: []u8, ok: bool) {
	blob := compile(hlsl, APP_PS_ENTRY, "ps_5_0", "app.hlsl") or_return
	defer blob->Release()
	src := mem.slice_ptr(cast([^]u8)blob->GetBufferPointer(), int(blob->GetBufferSize()))
	code = make([]u8, len(src), allocator)
	copy(code, src)
	return code, true
}

// Registers an application shader. 0 when it cannot be had: the source does not compile (WebGPU: the message names the error), or
// on Direct3D 11 the blob is missing, was built from other sources, or is refused by the device. Callers fall back to a drawing
// of their own then (draw.app_shader draws nothing for shader 0 and says so).
create_app_shader :: proc(r: ^Renderer, desc: App_Shader_Desc) -> App_Shader {
	d := App_Shader_Data{name = strings.clone(desc.name), wgsl = desc.wgsl, dxbc = desc.dxbc}
	ok: bool
	when USE_WGPU { ok = wgpu_app_shader_make(r, &d) } else { ok = d3d_app_shader_make(r, &d, desc.hash) }
	if !ok {
		delete(d.name)
		return 0
	}
	d.live = true
	if len(r.apps) == 0 { append(&r.apps, App_Shader_Data{}) }   // slot 0: "none"
	for &s, i in r.apps {
		if i > 0 && !s.live {
			s = d
			return App_Shader(i)
		}
	}
	append(&r.apps, d)
	return App_Shader(len(r.apps) - 1)
}

// Can the shader be drawn now? false for 0 and for a destroyed shader, and for one the device could not remake after a loss (or, on
// WebGPU, whose pipeline the device refused): such a handle stays reserved, and draws nothing, until destroy_app_shader; the caller
// draws its fallback (draw.app_shader says false).
app_shader_ready :: proc(r: ^Renderer, s: App_Shader) -> bool {
	d := app_shader_get(r, s)
	if d == nil { return false }
	when USE_WGPU { return d.module != nil } else { return d.ps != nil }
}

// Releases a shader of create_app_shader. The handle may be reused by a later one.
destroy_app_shader :: proc(r: ^Renderer, s: App_Shader) {
	if int(s) <= 0 || int(s) >= len(r.apps) || !r.apps[int(s)].live { return }
	d := &r.apps[int(s)]
	when USE_WGPU { wgpu_app_shader_release(r, d) } else { d3d_app_shader_release(d) }
	delete(d.name)
	delete(d.pipes)
	d^ = {}
}

// Releases every application shader (renderer teardown).
@(private)
app_shaders_destroy :: proc(r: ^Renderer) {
	for i in 1 ..< len(r.apps) { destroy_app_shader(r, App_Shader(i)) }
	delete(r.apps)
	r.apps = nil
}

@(private)
app_shader_get :: proc(r: ^Renderer, s: App_Shader) -> ^App_Shader_Data {
	if int(s) <= 0 || int(s) >= len(r.apps) || !r.apps[int(s)].live { return nil }
	return &r.apps[int(s)]
}

////////////////////////////////
// Direct3D 11

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
