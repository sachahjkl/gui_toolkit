package render

// (required: without CPU_FIRST the procedures below are empty)
@(require) import "base:runtime"
@(require) import "core:fmt"
import "core:os"
import "core:sync"
@(require) import "core:time"
@(require) import "vendor:wgpu"
@(require) import base "../base"
import "../platform"

// The CPU stage (src/md/infrastructure/cpu-first-frames.md): a renderer that has no device yet draws its first frame on
// the CPU and gives the pixels to the window through the platform. Its textures, heaps and settings are the renderer's
// from the start; the end of the stage gives them their GPU objects in the same slots, and the frame after the first
// one is drawn on the GPU.
//
//   init_window(cpu_first = true)   Active when the device made early is still being made, else the usual init
//   frame_begin/submit/end          the first frame: cleared, rasterised (cpu_raster.odin), shown (platform.show_pixels)
//   a frame at another size         on the CPU again (CPU_STAGE_FRAMES_MAX in all): the size a tiling compositor gives
//                                   the window it maps, which it shows only once a picture of that size comes
//   the next frame_begin            cpu_stage_end: waits for the device, makes the surface and the pipelines, moves the
//                                   textures and the heaps to the device; the frame is then drawn on the GPU
//
// TOOLKIT_CPU_SHADOW=1 keeps a CPU copy of what a GPU renderer is given, and draws each frame on the CPU too: a test
// compares the two pictures (cpu_shadow_pixels).

// The most frames of a stage: the first, and those at a size the window was given since (a tiling compositor's tile).
CPU_STAGE_FRAMES_MAX :: 3

// Off (-define:TOOLKIT_CPU_FIRST=false): no stage, no copies, no rasteriser in the program. Linux only: the platform shows
// pixels on Wayland and X11 (Windows: ROADMAP.md).
CPU_FIRST :: #config(TOOLKIT_CPU_FIRST, true) && USE_WGPU && ODIN_OS == .Linux

// What the renderer keeps on the CPU while a CPU rasteriser can read it.
Cpu_Stage :: struct {
	active:  bool,              // no device yet: frames are drawn on the CPU
	shadow:  bool,              // TOOLKIT_CPU_SHADOW: each GPU frame is drawn on the CPU too
	failed:  bool,              // the end of the stage failed (init_failure says why): the frames stay on the CPU
	window:  ^platform.Window,  // where the CPU frames are shown
	frames:  int,               // frames drawn in the stage
	drawn:   [2]int,            // the size of the last one
	shown:   bool,              // a CPU frame is on the window: drop_pixels after the first GPU present
	shown_at: u64,              // r.present.presents when the stage ended (the first GPU present is the next one)
	exact:   bool,              // the last CPU frame drew everything its Frame_Data asked (cpu_frame_exact)
	texels:  [dynamic][]u8,     // by texture id: the texels as the GPU stores them (nil: none kept)
	heaps:   [Heap_Kind][dynamic]u8,   // the retained heaps' contents, while the stage is active
	frame:   [dynamic][4]f32,   // the frame, premultiplied, in the blend space's values
	bgra:    [dynamic]u8,       // the frame encoded for the window (B, G, R, A, premultiplied)
	clear:   [4]f32,            // frame_begin's
	init:    Cpu_Stage_Init,    // what init_window was asked, for the end of the stage
}

@(private)
Cpu_Stage_Init :: struct {
	surface:     platform.Surface_Handles,
	transparent: bool,
	space:       Blend_Space,
}

// The renderer draws on the CPU: its first frame, before the device.
cpu_stage_active :: proc(r: ^Renderer) -> bool {
	when CPU_FIRST { return r.cpu.active } else { return false }
}

// The last frame drawn on the CPU had nothing it could not draw (no layer, filter, blend mode, picture, plane or
// application shader): the GPU's next frame shows the same picture.
cpu_frame_exact :: proc(r: ^Renderer) -> bool {
	when CPU_FIRST { return r.cpu.exact } else { return false }
}

// TOOLKIT_CPU_FIRST=0 turns the stage off; read once per process.
@(private)
cpu_first_wanted :: proc() -> bool {
	@(static) state: int   // 0: unknown, 1: off, 2: on (every thread reads the same environment)
	s := sync.atomic_load(&state)
	if s == 0 {
		s = os.get_env("TOOLKIT_CPU_FIRST", context.temp_allocator) == "0" ? 1 : 2
		sync.atomic_store(&state, s)
	}
	return s == 2
}

// TOOLKIT_CPU_SHADOW=1: a GPU renderer keeps CPU copies and draws each frame on the CPU too (tests).
@(private)
cpu_shadow_wanted :: proc() -> bool {
	return os.get_env("TOOLKIT_CPU_SHADOW", context.temp_allocator) == "1"
}

// Enters the stage when it can show something sooner: the device made early is still being made, and the window can
// show pixels. False: the caller makes the device now (init as before).
@(private)
cpu_stage_begin :: proc(r: ^Renderer, w: ^platform.Window, surface: platform.Surface_Handles, size: [2]int, transparent: bool, space: Blend_Space) -> bool {
	when !CPU_FIRST { return false } else {
		if w == nil || !cpu_first_wanted() || !platform.can_show_pixels(w) { return false }
		if device_preload_state() != .Creating { return false }
		// (a device is coming: its adapter is known in milliseconds. None: init fails now, with the no-graphics sentence
		// of a failed host_open. GL: the window makes its own device there, and its first frame would wait for its
		// pipelines at the start anyway, wgpu_gl_pipelines)
		if preload_adapter_wait() != .Vulkan { return false }
		// (what adapter_info says during the stage: the adapter that will draw)
		r.wg.adapter_name_len = copy(r.wg.adapter_name[:], preload.adapter_name[:preload.adapter_name_len])
		r.wg.backend_type, r.wg.cpu_adapter = preload.adapter_backend, preload.adapter_software
		r.cpu = {active = true, window = w, init = {surface = surface, transparent = transparent, space = space}}
		r.surface_handles = surface
		r.size = size
		r.transparent, r.transparent_asked = transparent, transparent
		r.space = space
		// (what wgpu_init_pipeline sets on a renderer's first slot: it keeps them, the slot being there)
		append(&r.textures, Texture_Data{})
		r.corner_smoothing = 1
		r.blur_sigma_limit = DEFAULT_BLUR_SIGMA_LIMIT
		r.text = text_rendering_default(space)
		r.id = sync.atomic_add(&renderer_ids, 1) + 1
		base.start_mark("render: CPU stage")
		return true
	}
}

// Ends the stage: the device (waited for), the surface, the pipelines, then the textures and heaps moved to it. False:
// no device (init_failure says why); the renderer stays on the CPU.
cpu_stage_end :: proc(r: ^Renderer) -> bool {
	when !CPU_FIRST { return true } else {
		if !r.cpu.active { return true }
		if r.cpu.failed { return false }
		in_ := r.cpu.init
		size := r.size
		if !wgpu_init(r, in_.surface, size, in_.transparent, in_.space) {
			if r.failure.error == .None { r.failure.error = .Failed }
			wgpu_prewarm_stop(&r.wg)
			wgpu_release_objects(r)
			wgpu_release_device(r)
			r.cpu.failed = true
			fmt.eprintln("render: the graphics device did not come: the frames stay on the CPU")
			return false
		}
		g := &r.wg
		for i in 1 ..< len(r.textures) {
			td := &r.textures[i]
			#partial switch td.kind {
			case .R8, .RGBA, .Slug_Curves, .Slug_Bands, .Data:
				if !wgpu_texture_objects(r, td) { fmt.eprintln("render: texture", i, "could not be made"); td^ = {kind = .Failed}; continue }
				if i < len(r.cpu.texels) && r.cpu.texels[i] != nil {
					bpp := cpu_texel_bytes(td)
					wgpu.QueueWriteTexture(g.queue, &{texture = td.wtex, mipLevel = 0, origin = {}, aspect = .All},
						raw_data(r.cpu.texels[i]), uint(len(r.cpu.texels[i])),
						&{offset = 0, bytesPerRow = u32(td.w * bpp), rowsPerImage = u32(td.h)}, &{u32(td.w), u32(td.h), 1})
				}
			}
		}
		for kind in Heap_Kind {
			h := &r.heaps[kind]
			if h.cap == 0 { continue }
			stride := HEAP_STRIDE[kind]
			h.wbuf = wgpu.DeviceCreateBuffer(g.device, &{label = "retained heap", usage = wgpu_heap_usage(kind), size = u64(h.cap * stride)})
			if h.wbuf == nil { continue }
			data := r.cpu.heaps[kind]
			if len(data) > 0 { wgpu.QueueWriteBuffer(g.queue, h.wbuf, 0, raw_data(data), uint(len(data))) }
		}
		wgpu_app_shaders_recreate(r)
		r.cpu.active = false
		r.cpu.shown_at = r.present.presents
		if !r.cpu.shadow { cpu_mirror_free(r) }
		for &h in r.cpu.heaps { delete(h); h = nil }
		base.start_mark("render: device after the CPU stage")
		return true
	}
}

// The bytes a texel takes in a texture's CPU copy (as the GPU stores it).
@(private)
cpu_texel_bytes :: proc(td: ^Texture_Data) -> int {
	#partial switch td.kind {
	case .R8: return 1
	case .RGBA, .Slug_Bands: return 4
	case .Slug_Curves: return TEXEL_BYTES_FP16
	case .Data: return td.data_format == .R8 ? 1 : 4
	}
	return 0
}

// Whether the renderer keeps CPU copies of what it is given now.
@(private)
cpu_mirroring :: #force_inline proc(r: ^Renderer) -> bool {
	when CPU_FIRST { return r.cpu.active || r.cpu.shadow } else { return false }
}

// A texture of the stage: a slot with no GPU object, its CPU copy zeroed.
@(private)
cpu_texture_add :: proc(r: ^Renderer, td: Texture_Data) -> Texture {
	when !CPU_FIRST { return 0 } else {
		if td.w <= 0 || td.h <= 0 { return 0 }
		t := add_texture(r, td)
		cpu_mirror_made(r, t)
		return t
	}
}

// A texture just made: its CPU copy, zeroed, when copies are kept.
@(private)
cpu_mirror_made :: proc(r: ^Renderer, t: Texture) {
	when CPU_FIRST {
		if t == 0 || !cpu_mirroring(r) { return }
		td := &r.textures[int(t)]
		bpp := cpu_texel_bytes(td)
		if bpp == 0 { return }
		for len(r.cpu.texels) <= int(t) { append(&r.cpu.texels, nil) }
		delete(r.cpu.texels[int(t)])
		r.cpu.texels[int(t)] = make([]u8, td.w * td.h * bpp)
	}
}

// A texture destroyed: its copy goes.
@(private)
cpu_mirror_gone :: proc(r: ^Renderer, t: Texture) {
	when CPU_FIRST {
		if int(t) <= 0 || int(t) >= len(r.cpu.texels) { return }
		delete(r.cpu.texels[int(t)])
		r.cpu.texels[int(t)] = nil
	}
}

// Rows written into a texture's copy: w x h texels at (x, y), `pitch` bytes apart in `pixels`.
@(private)
cpu_mirror_write :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: rawptr, pitch: int) {
	when CPU_FIRST {
		if int(t) <= 0 || int(t) >= len(r.cpu.texels) || r.cpu.texels[int(t)] == nil || pixels == nil { return }
		td := &r.textures[int(t)]
		bpp := cpu_texel_bytes(td)
		if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > td.w || y + h > td.h { return }
		dst := r.cpu.texels[int(t)]
		src := ([^]u8)(pixels)
		for row in 0 ..< h {
			copy(dst[((y + row) * td.w + x) * bpp:][:w * bpp], src[row * pitch:][:w * bpp])
		}
	}
}

@(private)
cpu_mirror_free :: proc(r: ^Renderer) {
	when CPU_FIRST {
		for t in r.cpu.texels { delete(t) }
		delete(r.cpu.texels)
		r.cpu.texels = nil
	}
}

// What the stage holds, released (destroy).
@(private)
cpu_stage_destroy :: proc(r: ^Renderer) {
	when CPU_FIRST {
		if r.cpu.active && device_preload_state() != .Not_Started { release_preloaded_device() }
		if r.cpu.shown && r.cpu.window != nil { platform.drop_pixels(r.cpu.window) }
		cpu_mirror_free(r)
		for &h in r.cpu.heaps { delete(h) }
		delete(r.cpu.frame)
		delete(r.cpu.bgra)
		r.cpu = {}
	}
}

// heap_grow during the stage: the heap's room on the CPU (the device's limits are not known: none).
@(private)
cpu_heap_grow :: proc(r: ^Renderer, kind: Heap_Kind, need: int) -> bool {
	h := &r.heaps[kind]
	ncap := max(h.cap * 2, h.cap + need, HEAP_MIN)
	old := h.cap
	h.cap = ncap
	when CPU_FIRST { runtime.resize(&r.cpu.heaps[kind], ncap * HEAP_STRIDE[kind]) }
	insert_free(h, old, ncap - old)
	return true
}

@(private)
cpu_heap_write :: proc(r: ^Renderer, kind: Heap_Kind, offset: int, data: rawptr, n: int) {
	when CPU_FIRST {
		h := &r.heaps[kind]
		stride := HEAP_STRIDE[kind]
		if n <= 0 || offset < 0 || offset + n > h.cap || len(r.cpu.heaps[kind]) < h.cap * stride { return }
		copy(r.cpu.heaps[kind][offset * stride:][:n * stride], ([^]u8)(data)[:n * stride])
	}
}

// frame_begin of the stage: the frame cleared to `clear` (linear, premultiplied), in the blend space's values.
@(private)
cpu_frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	when CPU_FIRST {
		c := clear
		if r.space == .Srgb && c.a > 0 {
			for k in 0 ..< 3 { c[k] = linear_to_srgb(c[k] / c.a) * c.a }
		}
		r.cpu.clear = c
		r.cpu.drawn = r.size
		r.opaque_frames = frame_opaque(clear)
		n := max(r.size.x, 0) * max(r.size.y, 0)
		runtime.resize(&r.cpu.frame, n)
		for &p in r.cpu.frame { p = c }
	}
}

// frame_end of the stage: the frame encoded and shown on the window. A present, as the GPU's are counted.
@(private)
cpu_frame_end :: proc(r: ^Renderer) {
	when CPU_FIRST {
		t0 := time.tick_now()
		cpu_encode_bgra(r)
		t1 := time.tick_now()
		// (counted shown or not: a window not on the screen yet must not keep the stage for ever)
		r.cpu.frames += 1
		if !platform.show_pixels(r.cpu.window, r.cpu.bgra[:], r.size, r.opaque_frames) { return }
		if r.cpu.shown && render_trace() {
			fmt.eprintfln("render: CPU frame %d (%dx%d) shown %.0f ms after the process started", r.cpu.frames, r.size.x, r.size.y, base.start_ms())
		}
		r.cpu.shown = true
		r.present.presents += 1
		r.present.input = {}
		if !r.first_present_noted {
			r.first_present_noted = true
			first := base.start_mark("render: first frame shown")
			if render_trace() {
				fmt.eprintfln("render: first present %.0f ms after the process started (on the CPU: encoded in %.2f ms, shown in %.2f ms)",
					base.start_ms(), time.duration_milliseconds(time.tick_diff(t0, t1)), time.duration_milliseconds(time.tick_since(t1)))
				if first { base.start_print() }
			}
		}
	}
}

// The first GPU present after a CPU frame shown: the window's CPU picture is not needed any more.
@(private)
cpu_after_present :: proc(r: ^Renderer) {
	when CPU_FIRST {
		if !r.cpu.shown || r.cpu.active || r.present.presents <= r.cpu.shown_at { return }
		r.cpu.shown = false
		platform.drop_pixels(r.cpu.window)
		base.start_mark("render: first frame on the GPU")
		if render_trace() { fmt.eprintfln("render: first GPU present %.0f ms after the process started (%d frames on the CPU before it)", base.start_ms(), r.cpu.frames) }
	}
}

// The frame as the window gets it: premultiplied B, G, R, A bytes, sRGB-encoded as an 8-bit frame stores them.
@(private)
cpu_encode_bgra :: proc(r: ^Renderer) {
	when CPU_FIRST {
		n := len(r.cpu.frame)
		runtime.resize(&r.cpu.bgra, n * 4)
		out := r.cpu.bgra[:]
		if r.space == .Srgb {
			for p, i in r.cpu.frame {
				out[i * 4 + 0] = cpu_unorm8(p.b)
				out[i * 4 + 1] = cpu_unorm8(p.g)
				out[i * 4 + 2] = cpu_unorm8(p.r)
				out[i * 4 + 3] = cpu_unorm8(p.a)
			}
		} else {
			enc := cpu_encode_table()
			for p, i in r.cpu.frame {
				out[i * 4 + 0] = enc[cpu_encode_index(p.b)]
				out[i * 4 + 1] = enc[cpu_encode_index(p.g)]
				out[i * 4 + 2] = enc[cpu_encode_index(p.r)]
				out[i * 4 + 3] = cpu_unorm8(p.a)
			}
		}
	}
}

// The CPU frame of a renderer with TOOLKIT_CPU_SHADOW (or in the stage) as read_pixels gives a frame: RGBA8,
// premultiplied, sRGB-encoded in a linear blend space. nil: none drawn.
cpu_shadow_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	when !CPU_FIRST { return nil } else {
		if len(r.cpu.frame) == 0 { return nil }
		cpu_encode_bgra(r)
		out := make([]u8, len(r.cpu.bgra), allocator)
		swap_red_blue(raw_data(out), raw_data(r.cpu.bgra), len(r.cpu.bgra) / 4)
		return out
	}
}

@(private)
cpu_unorm8 :: #force_inline proc "contextless" (v: f32) -> u8 { return u8(clamp(v, 0, 1) * 255 + 0.5) }

// sRGB encoding by a table of CPU_ENCODE_STEPS linear steps: exact to the byte for every step but the darkest, where the
// curve is steepest; there the step is made finer by the table's size.
@(private) CPU_ENCODE_STEPS :: 16384

@(private)
cpu_encode_index :: #force_inline proc "contextless" (v: f32) -> int {
	return int(clamp(v, 0, 1) * (CPU_ENCODE_STEPS - 1) + 0.5)
}

@(private)
cpu_encode_table :: proc() -> ^[CPU_ENCODE_STEPS]u8 {
	@(static) table: [CPU_ENCODE_STEPS]u8
	@(static) once: sync.Once
	sync.once_do(&once, proc() {
		for i in 0 ..< CPU_ENCODE_STEPS {
			table[i] = u8(clamp(linear_to_srgb(f32(i) / (CPU_ENCODE_STEPS - 1)) * 255 + 0.5, 0, 255))
		}
	})
	return &table
}
