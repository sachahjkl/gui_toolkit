#+build linux
package render

// OpenGL through wgpu's GL backend, when Vulkan gives no adapter (src/md/infrastructure/no-graphics.md, "The GL
// fallback"). wgpu's GL backend makes its EGL display at instance creation, so the instance needs the window's display
// connection: a GL instance is of one connection (or of none: EGL surfaceless, offscreen only).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "vendor:wgpu"
import "../platform"

WGPU_GL_FALLBACK :: WGPU_BACKEND == "vulkan"

// TOOLKIT_WGPU_BACKEND=gl in the environment: the GL backend whatever Vulkan has (a test, a machine whose Vulkan driver
// exists but misbehaves). Read once: every renderer of the process uses the same backend.
@(private)
wgpu_gl_forced :: proc() -> bool {
	@(static) state: int   // 0: unknown, 1: off, 2: on (the process's: atomic, every thread reads the same environment)
	s := sync.atomic_load(&state)
	if s == 0 {
		v := os.get_env("TOOLKIT_WGPU_BACKEND", context.temp_allocator)
		s = v == "gl" ? 2 : 1
		if v != "" && v != "gl" && v != WGPU_BACKEND {
			fmt.eprintfln("render: TOOLKIT_WGPU_BACKEND=%s is not known (gl or %s): %s is used", v, WGPU_BACKEND, WGPU_BACKEND)
		}
		sync.atomic_store(&state, s)
	}
	return s == 2
}

// The display a GL instance is made for: the window's Wayland display; on X11 `xlib`, an Xlib connection of the
// instance's own to the window's server, and its `screen` (wgpu-hal 29's EGL takes an Xlib display only: its XCB case is
// a todo!(), a panic; the toolkit's own connection is XCB's). None (an offscreen renderer): EGL surfaceless in Mesa,
// which draws but presents to no window.
@(private)
wgpu_gl_display :: proc(h: platform.Surface_Handles, xlib: rawptr, screen: i32) -> wgpu.NativeDisplayHandle {
	d: wgpu.NativeDisplayHandle
	switch h.backend {
	case .Wayland:
		d.type = .Wayland
		d.wayland.display = h.display
	case .X11:
		d.type = .Xlib
		d.xlib.display = xlib
		d.xlib.screen = screen
	case .Windows, .None:
	}
	return d
}

// What the renderer needs of a GL adapter that WebGPU's defaults give on Vulkan, by the adapter's limits. "" when it has
// all of it. The counts are of the bind group layouts of wgpu_init_pipeline: a fragment shader binds the seven storage
// tables of group 0 and an application shader's parameters (eight), the five textures of group 1 and an application
// shader's four (nine).
@(private)
wgpu_gl_lacks :: proc(l: wgpu.Limits) -> string {
	switch {
	case l.maxStorageBuffersPerShaderStage < 8:   return "fewer than 8 storage buffers in a shader stage"
	case l.maxStorageBufferBindingSize < 1 << 27: return "storage buffers smaller than 128 MiB"
	case l.maxSampledTexturesPerShaderStage < 9:  return "fewer than 9 textures in a shader stage"
	case l.maxSamplersPerShaderStage < 3:         return "fewer than 3 samplers in a shader stage"
	case l.maxBindGroups < 3:                     return "fewer than 3 bind groups"
	case l.maxDynamicUniformBuffersPerPipelineLayout < 2: return "fewer than 2 dynamic uniform buffers"
	case l.maxUniformBufferBindingSize < PASS_CONSTANTS_SIZE: return "uniform buffers too small"
	case l.minUniformBufferOffsetAlignment > ARENA_ALIGN: return "a uniform offset alignment over 256 bytes"
	case l.maxInterStageShaderVariables < 14:     return "fewer than 14 values between the shader stages"
	}
	return ""
}

// What the limits do not say, asked of the device itself: storage buffers in a vertex shader (wgpu's downlevel flag
// VERTEX_STORAGE, which the C API does not report) and a half-float target to draw into (layers are RGBA16Float; GLES
// draws into one only with EXT_color_buffer_half_float or EXT_color_buffer_float). The objects are made inside an error
// scope: a refusal is wgpu's validation error, not a panic. "" when the device takes both. The text lives in `buf`.
@(private)
wgpu_gl_probe :: proc(g: ^Wgpu_State, buf: []u8) -> string {
	wgpu_gl_scope_push(g)
	entry := bgl_buffer(0, {.Vertex}, .ReadOnlyStorage, false, 0)
	bgl := wgpu.DeviceCreateBindGroupLayout(g.device, &{label = "GL probe", entryCount = 1, entries = &entry})
	tex := wgpu.DeviceCreateTexture(g.device, &{
		label = "GL probe", usage = {.RenderAttachment, .TextureBinding}, dimension = ._2D, size = {1, 1, 1},
		format = .RGBA16Float, mipLevelCount = 1, sampleCount = 1,
	})
	inner: [INIT_DETAIL_BYTES]u8   // (not `buf`: the sentence below is written there from it)
	why := wgpu_gl_scope_pop(g, inner[:])
	if tex != nil { wgpu.TextureRelease(tex) }
	if bgl != nil { wgpu.BindGroupLayoutRelease(bgl) }
	if why == "" { return "" }
	return fmt.bprintf(buf, "no storage buffers in vertex shaders or no half-float targets (%s)", why)
}

// The pipelines every frame uses, made on the GL device before anything is submitted, inside error scopes. The limits
// and the probe are not enough: wgpu-hal can report storage buffers that naga's GLSL cannot reach. On Mesa it makes a
// desktop GL context, takes storage buffers from GL_ARB_shader_storage_buffer_object, and naga then writes GLSL of the
// context's version, which below 4.00 has no buffer blocks: DeviceCreateRenderPipeline fails ("The selected version
// doesn't support Features(BUFFER_STORAGE | DYNAMIC_ARRAY_SIZE)"), and wgpu-native ends the process at the first
// QueueSubmit that sets the pipeline. "" when every one is made; the text lives in `buf`. The pipelines stay in the
// renderer's lists: the pre-warming thread, started after this, finds them made.
@(private)
wgpu_gl_pipelines :: proc(r: ^Renderer, buf: []u8) -> string {
	g := &r.wg
	wgpu_gl_scope_push(g)
	wgpu_pipeline(r, g.view_format, false)            // the frame's shapes and images
	wgpu_pipeline(r, g.view_format, true)             // what a blend composites
	wgpu_slug_pipeline(r, g.view_format, false)       // text
	wgpu_pipeline(r, .RGBA16Float, false)             // a layer's content
	wgpu_fx_pipeline(r, .RGBA16Float)                 // its filters
	wgpu_mip_pipeline(r, g.surface_format, true)      // the kept target drawn to the surface (every GL window frame)
	if g.can_dual { wgpu_slug_pipeline(r, g.view_format, false, true) }   // text per colour stripe (rect + slug + slug_dual)
	inner: [INIT_DETAIL_BYTES]u8   // (not `buf`: the sentence below is written there from it)
	why := wgpu_gl_scope_pop(g, inner[:])
	if why == "" { return "" }
	return fmt.bprintf(buf, "shaders it cannot compile (%s)", why)
}

// One error scope, for validation errors. wgpu-native 29 takes Validation and OutOfMemory only (an Internal filter is a
// panic in wgpuDevicePushErrorScope), and it reports naga's failed translation as a validation error.
@(private)
wgpu_gl_scope_push :: proc(g: ^Wgpu_State) {
	wgpu.DevicePushErrorScope(g.device, .Validation)
}

// Pops the scope of wgpu_gl_scope_push and waits for its answer (bounded). The first error's words, in `buf`; "" when
// there was none.
@(private)
wgpu_gl_scope_pop :: proc(g: ^Wgpu_State, buf: []u8) -> string {
	Pop :: struct { done: int, why: [INIT_DETAIL_BYTES]u8, why_len: int }
	// (on the heap: an answer that comes after the wait gave up, at a later InstanceProcessEvents, writes into it; it is
	// then left, not freed)
	p := new(Pop, runtime.heap_allocator())
	popped :: proc "c" (status: wgpu.PopErrorScopeStatus, type: wgpu.ErrorType, message: wgpu.StringView, u1, u2: rawptr) {
		p := (^Pop)(u1)
		if (status != .Success || type != .NoError) && p.why_len == 0 {
			context = runtime.default_context()
			p.why_len = copy(p.why[:], status != .Success ? "the error scope was not answered" : wgpu_failure_reason(string(message), "gl"))
		}
		p.done += 1
	}
	wgpu.DevicePopErrorScope(g.device, {mode = .AllowProcessEvents, callback = popped, userdata1 = p})
	for tries := 0; p.done < 1 && tries < WAIT_REQUEST_MAX_TRIES; tries += 1 {
		wgpu.InstanceProcessEvents(g.instance)
		if p.done < 1 { thread_sleep_1ms() }
	}
	if p.done < 1 { return fmt.bprintf(buf, "no answer from its device") }
	defer free(p, runtime.heap_allocator())
	if p.why_len == 0 { return "" }
	return fmt.bprintf(buf, "%s", string(p.why[:p.why_len]))
}

// The GL variant of a module's WGSL. naga's GLSL writer combines each texture with one sampler (a GLSL sampler2D is
// both), per entry point, and refuses a texture sampled through two ("A image was used with multiple samplers"). Of the
// WGSL the renderer compiles on wgpu, only rect.wgsl does that: `image` clamps (samp_img) and repeats (samp_wrap, a
// tiled image, FLAG_TILE), both trilinear. `atlas` has `samp` alone, `backdrop` and the Slug textures only textureLoad;
// filter.wgsl, mip.wgsl and video.wgsl give each texture one sampler; canvas.wgsl is Direct3D 11's only. So on GL every
// sampling of `image` goes through `samp_image` (group 1, binding 5), the batch's sampler: s_wrap for a batch of tiled
// images, s_img otherwise (walk_bind; gt:draw starts a new batch where the mode changes, image_wrap_splits_batches).
// Every module that holds rect.wgsl gets it: rect, Slug, its dual variant, the application shaders (whose own code keeps
// rect.wgsl's group-0 samplers). Text replacement, not a define: WGSL has no preprocessor, and an `override` cannot
// choose a sampler. `owned`: the result was allocated with `allocator`. A module without rect.wgsl comes back as it is.
@(private)
wgpu_gl_source :: proc(code: string, allocator: runtime.Allocator) -> (source: string, owned: bool) {
	IMAGE_DECL :: "@group(1) @binding(1) var image: texture_2d<f32>;"
	if !strings.contains(code, IMAGE_DECL) { return code, false }
	edits := [?][2]string{
		{"(image, samp_img,", "(image, samp_image,"},
		{"(image, samp_wrap,", "(image, samp_image,"},
		{IMAGE_DECL, IMAGE_DECL + "\n@group(1) @binding(5) var samp_image: sampler;   // (GL: wgpu_gl_source)"},
	}
	source = code
	for e in edits {
		next, allocated := strings.replace_all(source, e[0], e[1], allocator)
		if allocated {
			if owned { delete(source, allocator) }
			source, owned = next, true
		}
	}
	return
}
