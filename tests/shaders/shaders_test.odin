package tests_shaders

@(require) import "core:slice"
import "core:strings"
import "core:testing"
import "../../render"

// The shaders are written in WGSL (render/*.wgsl); the Direct3D 11 backend embeds the HLSL naga wrote from them and its DXBC.
// After editing a .wgsl file, `odin run tools/shaders` writes both again (CI also runs it with -check, which has naga write the HLSL again).


// The HLSL names the SHA-256 of the WGSL it was written from: an edited source whose HLSL was not written again fails here.
@(test)
hlsl_matches_wgsl :: proc(t: ^testing.T) {
	for desc, m in render.MODULES {
		want := render.module_header(m, context.temp_allocator)
		testing.expectf(t, strings.has_prefix(desc.hlsl, want),
			"render/shaders/%s is stale (it was not written from the current %v): run odin run tools/shaders", desc.file, desc.wgsl_files)
	}
}

// The embedded blobs are what the embedded HLSL compiles to (FXC, on the Direct3D 11 backend: the WebGPU backend has no such compiler to call).
@(test)
blobs_match_sources :: proc(t: ^testing.T) {
	when !render.USE_WGPU {
		for d, id in render.SHADERS {
			code, ok := render.shader_compile(id, context.temp_allocator)
			testing.expectf(t, ok, "%s %s does not compile", d.name, d.entry)
			testing.expectf(t, len(d.blob) > 0 && slice.equal(code, d.blob), "render/shaders/%s is stale: run odin run tools/shaders", d.file)
		}
	}
}

// What is embedded is compiled shader code (DXBC container: its magic, then the size it says it has).
@(test)
blobs_are_dxbc :: proc(t: ^testing.T) {
	for d in render.SHADERS {
		ok := len(d.blob) > 32 && string(d.blob[:4]) == "DXBC"
		if ok {
			size := int(d.blob[24]) | int(d.blob[25]) << 8 | int(d.blob[26]) << 16 | int(d.blob[27]) << 24
			ok = size == len(d.blob)
		}
		testing.expectf(t, ok, "render/shaders/%s is not a DXBC container", d.file)
	}
}
