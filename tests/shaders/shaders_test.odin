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
