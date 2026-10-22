package render

import "core:mem"
import "vendor:directx/d3d11"

// The shaders, compiled ahead of time to DXBC (render/shaders/*.dxbc) and embedded: compiling the HLSL when the
// renderer starts took about 280 ms of every launch (D3DCompile of rect.hlsl dominates). tools/shaders writes the
// blobs from the sources; tests/shaders fails when a source changed and its blob was not written again.
// -define:RENDER_COMPILE_SHADERS=true compiles the sources at start-up instead (while editing the HLSL).
RENDER_COMPILE_SHADERS :: #config(RENDER_COMPILE_SHADERS, false)

SHADER_SOURCE :: #load("rect.hlsl", string)
FILTER_SOURCE :: #load("filter.hlsl", string)
// The Slug text shaders use the helpers of rect.hlsl (transforms, clips, text correction): one source, rect.hlsl first.
SLUG_SOURCE :: SHADER_SOURCE + "\n" + #load("slug.hlsl", string)

Shader_Id :: enum u8 {
	Rect_VS,
	Rect_PS,
	Filter_VS,
	Filter_PS,
	Slug_VS,
	Slug_PS,
}

Shader_Desc :: struct {
	source: string,
	name:   cstring,   // the file name the compiler reports errors against
	entry:  cstring,
	target: cstring,
	file:   string,    // render/shaders/<file>: the compiled blob
	blob:   []u8,      // what was compiled ahead of time
}

SHADERS := [Shader_Id]Shader_Desc{
	.Rect_VS   = {SHADER_SOURCE, "rect.hlsl", "vs_main", "vs_5_0", "rect_vs.dxbc", #load("shaders/rect_vs.dxbc")},
	.Rect_PS   = {SHADER_SOURCE, "rect.hlsl", "ps_main", "ps_5_0", "rect_ps.dxbc", #load("shaders/rect_ps.dxbc")},
	.Filter_VS = {FILTER_SOURCE, "filter.hlsl", "vs_fx", "vs_5_0", "filter_vs.dxbc", #load("shaders/filter_vs.dxbc")},
	.Filter_PS = {FILTER_SOURCE, "filter.hlsl", "ps_fx", "ps_5_0", "filter_ps.dxbc", #load("shaders/filter_ps.dxbc")},
	.Slug_VS   = {SLUG_SOURCE, "rect.hlsl+slug.hlsl", "vs_slug", "vs_5_0", "slug_vs.dxbc", #load("shaders/slug_vs.dxbc")},
	.Slug_PS   = {SLUG_SOURCE, "rect.hlsl+slug.hlsl", "ps_slug", "ps_5_0", "slug_ps.dxbc", #load("shaders/slug_ps.dxbc")},
}

// Compiles a shader from its source (tools/shaders, tests/shaders, RENDER_COMPILE_SHADERS). The bytes are a copy in
// `allocator`.
shader_compile :: proc(id: Shader_Id, allocator := context.allocator) -> (code: []u8, ok: bool) {
	d := SHADERS[id]
	blob := compile(d.source, d.entry, d.target, d.name) or_return
	defer blob->Release()
	src := mem.slice_ptr(cast([^]u8)blob->GetBufferPointer(), int(blob->GetBufferSize()))
	code = make([]u8, len(src), allocator)
	copy(code, src)
	return code, true
}

// The code of a shader for the device: the embedded blob, or the source compiled now (RENDER_COMPILE_SHADERS).
// Release the blob with shader_code_done.
@(private)
shader_code :: proc(id: Shader_Id) -> (code: []u8, blob: ^d3d11.IBlob, ok: bool) {
	when RENDER_COMPILE_SHADERS {
		d := SHADERS[id]
		blob = compile(d.source, d.entry, d.target, d.name) or_return
		return mem.slice_ptr(cast([^]u8)blob->GetBufferPointer(), int(blob->GetBufferSize())), blob, true
	} else {
		code = SHADERS[id].blob
		return code, nil, len(code) > 0
	}
}

@(private)
shader_code_done :: proc(blob: ^d3d11.IBlob) {
	if blob != nil { blob->Release() }
}
