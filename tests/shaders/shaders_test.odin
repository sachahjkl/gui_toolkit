package tests_shaders

import "core:slice"
import "core:testing"
import "../../render"

// The embedded blobs are what the sources compile to: an edited .hlsl needs `odin run tools/shaders`.
@(test)
blobs_match_sources :: proc(t: ^testing.T) {
	for d, id in render.SHADERS {
		code, ok := render.shader_compile(id, context.temp_allocator)
		testing.expectf(t, ok, "%s %s does not compile", d.name, d.entry)
		testing.expectf(t, len(d.blob) > 0 && slice.equal(code, d.blob), "render/shaders/%s is stale: run odin run tools/shaders", d.file)
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