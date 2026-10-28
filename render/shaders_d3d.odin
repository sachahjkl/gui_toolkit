#+build windows
package render

import "core:mem"
import "vendor:directx/d3d11"

// Direct3D compilation of the embedded HLSL (shaders.odin has the WGSL sources and the tables). Built only for the
// Direct3D backend (`!USE_WGPU`): the wgpu backend compiles the WGSL as it is (wgpu_module).
when !USE_WGPU {

// Compiles HLSL text (tools/shaders for the HLSL it just wrote, tests/shaders). The bytes are a copy in `allocator`.
compile_hlsl :: proc(source: string, id: Shader_Id, allocator := context.allocator) -> (code: []u8, ok: bool) {
	d := SHADERS[id]
	blob := compile(source, d.entry, d.target, d.name) or_return
	defer blob->Release()
	src := mem.slice_ptr(cast([^]u8)blob->GetBufferPointer(), int(blob->GetBufferSize()))
	code = make([]u8, len(src), allocator)
	copy(code, src)
	return code, true
}

// Compiles a shader from the embedded HLSL (tests/shaders).
shader_compile :: proc(id: Shader_Id, allocator := context.allocator) -> (code: []u8, ok: bool) {
	return compile_hlsl(MODULES[SHADERS[id].module].hlsl, id, allocator)
}

// The code of a shader for the device: the embedded blob, or the HLSL compiled now (RENDER_COMPILE_SHADERS).
// Release the blob with shader_code_done.
@(private)
shader_code :: proc(id: Shader_Id) -> (code: []u8, blob: ^d3d11.IBlob, ok: bool) {
	when RENDER_COMPILE_SHADERS {
		d := SHADERS[id]
		blob = compile(MODULES[d.module].hlsl, d.entry, d.target, d.name) or_return
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

}   // when !USE_WGPU
