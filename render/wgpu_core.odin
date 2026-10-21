package render

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:math/bits"
import "core:thread"
import "core:time"
import win "core:sys/windows"
import "vendor:directx/dxgi"
import "vendor:wgpu"

// WebGPU backend (TOOLKIT_RENDER=wgpu): wgpu-native over Direct3D 12 (or Vulkan). The same frame description as the
// Direct3D 11 backend (Frame_Data), the same shader logic ported to WGSL (rect.wgsl, filter.wgsl, mip.wgsl).
//
//   * Device, surface, formats, pipelines, textures, retained heaps, device loss: this file.
//   * frame_submit (passes, bind groups, filter passes), frame_begin / frame_end, presentation: wgpu_frame.odin.
//
// Differences from Direct3D 11 that shape the code:
//   * Nothing is immediate: constants live in a per-submit uniform arena (dynamic offsets) because every write is
//     applied before the submitted commands run.
//   * A frame is rendered through render passes: one per run of draw calls into the same target.
//   * No GenerateMips (mip.wgsl draws each level), no border sampler (done in the shaders), no frame statistics
//     (presentation estimates, see wgpu_present.odin).

WGPU_BACKEND :: #config(TOOLKIT_WGPU_BACKEND, "dx12")   // "dx12" | "vulkan"
WGPU_DX12_COMPILER :: #config(TOOLKIT_WGPU_DX12_COMPILER, "auto")   // "fxc" (d3dcompiler, always there) | "dxc" (dxcompiler.dll + dxil.dll next to the program) | "auto": dxc when the DLLs are there (tools/fetch_wgpu.ps1)

@(private) WGPU_RECT_SOURCE :: #load("rect.wgsl", string)
@(private) WGPU_FILTER_SOURCE :: #load("filter.wgsl", string)
@(private) WGPU_MIP_SOURCE :: #load("mip.wgsl", string)

@(private) ARENA_ALIGN :: 256           // minUniformBufferOffsetAlignment of every backend we use
@(private) PASS_CONSTANTS_SIZE :: 1280  // size_of(Pass_Constants), a multiple of ARENA_ALIGN

@(private)
Wgpu_Pipe :: struct {
	format:  wgpu.TextureFormat,
	replace: bool,
	pipe:    wgpu.RenderPipeline,
}

@(private)
Wgpu_Table :: struct {
	buf: wgpu.Buffer,
	cap: int,   // elements
}

// Shared with the callbacks wgpu-native calls (possibly from another thread): the renderer itself may move.
@(private)
Wgpu_Shared :: struct {
	lost:     bool,
	errors:   int,
	last_msg: [256]u8,
	last_len: int,
}

Wgpu_State :: struct {
	shared:        ^Wgpu_Shared,
	instance:      wgpu.Instance,
	adapter:       wgpu.Adapter,
	device:        wgpu.Device,
	queue:         wgpu.Queue,
	surface:       wgpu.Surface,
	backend_type:  wgpu.BackendType,
	adapter_name:  [128]u8,
	adapter_name_len: int,
	cpu_adapter:   bool,
	max_tex:       int,
	can_timestamp: bool,                 // TimestampQuery (+ inside encoders)
	surface_format: wgpu.TextureFormat,  // storage of the frame
	view_format:   wgpu.TextureFormat,   // how the frame is drawn into and read
	frame_tex:     wgpu.Texture,         // the surface texture of this frame, or the offscreen image
	frame_rtv:     wgpu.TextureView,
	frame_acquired: bool,
	configured:    bool,
	clear:         [4]f64,
	clear_pending: bool,                 // the frame target still has to be cleared (first pass of the frame)
	present_mode:  wgpu.PresentMode,
	// shaders, layouts, pipelines
	module_rect, module_fx, module_mip: wgpu.ShaderModule,
	bgl0, bgl1, bgl_fx, bgl_mip: wgpu.BindGroupLayout,
	pl_main, pl_fx, pl_mip: wgpu.PipelineLayout,
	pipes, fx_pipes, mip_pipes: [dynamic]Wgpu_Pipe,
	s_atlas, s_img, s_wrap, s_fx, s_mip: wgpu.Sampler,
	dummy_r8, dummy_rgba: wgpu.Texture,
	dummy_r8_view, dummy_rgba_view: wgpu.TextureView,
	// tables of the frame
	inst, xforms, clips, points, grads: Wgpu_Table,
	arena:         wgpu.Buffer,
	arena_cap:     int,
	arena_used:    int,
	// latency (wgpu_present.odin)
	latency:       Wgpu_Latency,
	// start-up costs, milliseconds (wgpu_costs)
	t_device, t_modules, t_pipelines: f64,
	n_pipelines: int,
}

@(private)
uncaptured_error :: proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: wgpu.StringView, u1, u2: rawptr) {
	context = runtime.default_context()
	sh := (^Wgpu_Shared)(u1)
	if sh != nil {
		sh.errors += 1
		sh.last_len = copy(sh.last_msg[:], message)
	}
	fmt.eprintln("render: wgpu error:", type, message)
}

@(private)
device_lost_cb :: proc "c" (device: ^wgpu.Device, reason: wgpu.DeviceLostReason, message: wgpu.StringView, u1, u2: rawptr) {
	context = runtime.default_context()
	if reason == .Destroyed || reason == .CallbackCancelled { return }
	fmt.eprintln("render: wgpu device lost:", reason, message)
	sh := (^Wgpu_Shared)(u1)
	if sh != nil { sh.lost = true }
}

@(private)
Request :: struct {
	adapter: wgpu.Adapter,
	device:  wgpu.Device,
	done:    bool,
	ok:      bool,
}

@(private)
wait_request :: proc(g: ^Wgpu_State, req: ^Request) -> bool {
	for tries := 0; !req.done && tries < 5000; tries += 1 {
		wgpu.InstanceProcessEvents(g.instance)
		if !req.done { win.Sleep(1) }
	}
	return req.done && req.ok
}

// The path of dxcompiler.dll when it and dxil.dll sit next to the program ("" otherwise: FXC compiles the shaders).
@(private)
find_dxc :: proc() -> string {
	buf: [win.MAX_PATH_WIDE]u16
	n := win.GetModuleFileNameW(nil, raw_data(buf[:]), len(buf))
	if n == 0 { return "" }
	dir, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "" }
	slash := strings.last_index_byte(dir, '\\')
	if slash < 0 { return "" }
	dll := fmt.tprintf("%s\\dxcompiler.dll", dir[:slash])
	il := fmt.tprintf("%s\\dxil.dll", dir[:slash])
	if !os.exists(dll) || !os.exists(il) { return "" }
	return dll
}

// Instance, (surface), adapter, device and queue. `hwnd` nil: no surface (offscreen). `fallback`: the software adapter.
//
// Run on a thread of its own: Direct3D 12 and DXGI raise and catch C++ exceptions (0xE06D7363) while they probe adapters,
// and a vectored exception handler that treats every exception as fatal (the one of Odin's test runner, debuggers' `break
// on first chance` options) would stop the process on them. Only the thread that makes the calls sees them.
@(private)
wgpu_create_device :: proc(r: ^Renderer, hwnd: win.HWND, fallback: bool) -> bool {
	Job :: struct { r: ^Renderer, hwnd: win.HWND, fallback, ok: bool }
	if r.wg.shared == nil { r.wg.shared = new(Wgpu_Shared) }   // with the caller's allocator (a thread's default one differs under a tracking allocator)
	job := Job{r, hwnd, fallback, false}
	t0 := time.tick_now()
	defer r.wg.t_device = time.duration_milliseconds(time.tick_since(t0))
	th := thread.create_and_start_with_data(&job, proc(data: rawptr) {
		j := (^Job)(data)
		j.ok = wgpu_create_device_here(j.r, j.hwnd, j.fallback)
	})
	thread.join(th)
	thread.destroy(th)
	return job.ok
}

@(private)
wgpu_create_device_here :: proc(r: ^Renderer, hwnd: win.HWND, fallback: bool) -> bool {
	g := &r.wg
	dxc_path := WGPU_DX12_COMPILER != "fxc" ? find_dxc() : ""
	extras := wgpu.InstanceExtras{
		chain = {sType = .InstanceExtras},
		backends = WGPU_BACKEND == "vulkan" ? wgpu.InstanceBackendFlags{.Vulkan} : wgpu.InstanceBackendFlags{.DX12},
		dx12ShaderCompiler = dxc_path != "" ? .Dxc : .Fxc,
		dxcPath = dxc_path,
		dcxMaxShaderModel = .V6_0,
	}
	g.instance = wgpu.CreateInstance(&{nextInChain = &extras.chain})
	if g.instance == nil { fmt.eprintln("render: wgpu: no instance"); return false }
	if hwnd != nil {
		src := wgpu.SurfaceSourceWindowsHWND{chain = {sType = .SurfaceSourceWindowsHWND}, hinstance = rawptr(win.GetModuleHandleW(nil)), hwnd = rawptr(hwnd)}
		g.surface = wgpu.InstanceCreateSurface(g.instance, &{nextInChain = &src.chain})
		if g.surface == nil { fmt.eprintln("render: wgpu: cannot create the surface"); return false }
	}
	req: Request
	adapter_cb :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: wgpu.StringView, u1, u2: rawptr) {
		req := (^Request)(u1)
		req.done, req.ok, req.adapter = true, status == .Success, adapter
		if status != .Success {
			context = runtime.default_context()
			fmt.eprintln("render: wgpu: no adapter:", status, message)
		}
	}
	opts := wgpu.RequestAdapterOptions{
		powerPreference = .HighPerformance, forceFallbackAdapter = b32(fallback), compatibleSurface = g.surface,
	}
	wgpu.InstanceRequestAdapter(g.instance, &opts, {mode = .AllowSpontaneos, callback = adapter_cb, userdata1 = &req})
	if !wait_request(g, &req) { return false }
	g.adapter = req.adapter

	info, _ := wgpu.AdapterGetInfo(g.adapter)
	g.backend_type = info.backendType
	g.cpu_adapter = info.adapterType == .CPU
	g.adapter_name_len = copy(g.adapter_name[:], info.description)
	wgpu.AdapterInfoFreeMembers(info)

	limits, _ := wgpu.AdapterGetLimits(g.adapter)
	g.max_tex = int(limits.maxTextureDimension2D)
	features: [dynamic]wgpu.FeatureName
	defer delete(features)
	if wgpu.AdapterHasFeature(g.adapter, .TimestampQuery) && wgpu.AdapterHasFeature(g.adapter, .TimestampQueryInsideEncoders) {
		append(&features, wgpu.FeatureName.TimestampQuery, wgpu.FeatureName.TimestampQueryInsideEncoders)
		g.can_timestamp = true
	} else { g.can_timestamp = false }
	dd := wgpu.DeviceDescriptor{
		label = "gui_toolkit",
		requiredFeatureCount = len(features), requiredFeatures = raw_data(features),
		requiredLimits = &limits,
		deviceLostCallbackInfo = {mode = .AllowSpontaneos, callback = device_lost_cb, userdata1 = g.shared},
		uncapturedErrorCallbackInfo = {callback = uncaptured_error, userdata1 = g.shared},
	}
	req = {}
	device_cb :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: wgpu.StringView, u1, u2: rawptr) {
		req := (^Request)(u1)
		req.done, req.ok, req.device = true, status == .Success, device
		if status != .Success {
			context = runtime.default_context()
			fmt.eprintln("render: wgpu: no device:", status, message)
		}
	}
	wgpu.AdapterRequestDevice(g.adapter, &dd, {mode = .AllowSpontaneos, callback = device_cb, userdata1 = &req})
	if !wait_request(g, &req) { return false }
	g.device = req.device
	g.queue = wgpu.DeviceGetQueue(g.device)
	return g.queue != nil
}

// The name of the adapter and the graphics API wgpu chose, for logs and reports ("NVIDIA GeForce RTX 4070 SUPER (D3D12)").
adapter_description :: proc(r: ^Renderer) -> string {
	when USE_WGPU {
		return fmt.tprintf("%s (%v)", string(r.wg.adapter_name[:r.wg.adapter_name_len]), r.wg.backend_type)
	} else {
		return "Direct3D 11"
	}
}

// Storage and view formats of the frame for the renderer's blend space (the Direct3D swap chain's choices).
@(private)
wgpu_frame_formats :: proc(r: ^Renderer) {
	g := &r.wg
	fp16 := r.transparent && r.space == .Linear
	g.surface_format = fp16 ? .RGBA16Float : .BGRA8Unorm
	g.view_format = fp16 ? .RGBA16Float : (r.space == .Srgb ? .BGRA8Unorm : .BGRA8UnormSrgb)
	r.frame_format = fp16 ? dxgi.FORMAT.R16G16B16A16_FLOAT : dxgi.FORMAT.B8G8R8A8_UNORM
}

@(private)
wgpu_init :: proc(r: ^Renderer, hwnd: win.HWND, size: [2]int, transparent := false, space := Blend_Space.Linear) -> bool {
	r.hwnd = hwnd
	r.size = size
	r.transparent = transparent
	r.space = space
	wgpu_create_device(r, hwnd, false) or_return
	wgpu_frame_formats(r)
	wgpu_configure_surface(r) or_return
	wgpu_init_pipeline(r) or_return
	return true
}

@(private)
wgpu_init_offscreen :: proc(r: ^Renderer, size: [2]int, warp := false, space := Blend_Space.Linear) -> bool {
	r.size = size
	r.space = space
	r.warp = warp
	if !wgpu_create_device(r, nil, warp) {
		wgpu_release_device(r)
		if warp || !wgpu_create_device(r, nil, true) { return false }
		r.warp = true
	}
	wgpu_frame_formats(r)
	wgpu_create_offscreen(r) or_return
	return wgpu_init_pipeline(r)
}

@(private)
wgpu_create_offscreen :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	vf := [1]wgpu.TextureFormat{g.view_format}
	g.frame_tex = wgpu.DeviceCreateTexture(g.device, &{
		label = "offscreen frame", usage = {.RenderAttachment, .CopySrc, .TextureBinding},
		dimension = ._2D, size = {u32(r.size.x), u32(r.size.y), 1}, format = g.surface_format,
		mipLevelCount = 1, sampleCount = 1,
		viewFormatCount = g.view_format != g.surface_format ? 1 : 0, viewFormats = raw_data(vf[:]),
	})
	if g.frame_tex == nil { return false }
	g.frame_rtv = wgpu.TextureCreateView(g.frame_tex, &{
		format = g.view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All,
	})
	g.frame_acquired = true
	r.buffer_size, r.source_size = r.size, r.size
	return g.frame_rtv != nil
}

@(private)
wgpu_surface_alpha :: proc(r: ^Renderer) -> wgpu.CompositeAlphaMode {
	return .Opaque
}

// (Re)configures the surface for the current size, format, present mode and latency.
@(private)
wgpu_configure_surface :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	if g.surface == nil { return true }
	t_start := time.tick_now()
	t_drain := time.tick_now()
	wgpu_drop_frame(r)
	wgpu_query_tearing(r)
	vf := [1]wgpu.TextureFormat{g.view_format}
	extras := wgpu.SurfaceConfigurationExtras{chain = {sType = .SurfaceConfigurationExtras}, desiredMaximumFrameLatency = wgpu_frame_latency(r)}
	cfg := wgpu.SurfaceConfiguration{
		nextInChain = &extras.chain,
		device = g.device, format = g.surface_format, usage = {.RenderAttachment, .CopySrc},
		width = u32(max(r.size.x, 1)), height = u32(max(r.size.y, 1)),
		viewFormatCount = g.view_format != g.surface_format ? 1 : 0, viewFormats = raw_data(vf[:]),
		alphaMode = wgpu_surface_alpha(r), presentMode = wgpu_pick_present_mode(r),
	}
	g.present_mode = cfg.presentMode
	t_conf := time.tick_now()
	wgpu.SurfaceConfigure(g.surface, &cfg)
	if wgpu_trace() { fmt.eprintfln("wgpu: configure %dx%d: drain %.2f ms, SurfaceConfigure %.2f ms", r.size.x, r.size.y, time.duration_milliseconds(time.tick_diff(t_start, t_drain)), time.duration_milliseconds(time.tick_since(t_conf))) }
	g.configured = true
	r.buffer_size, r.source_size = r.size, r.size
	wgpu_latency_start(r)
	return true
}

// Drops the texture of the frame in progress (before a reconfigure, a resize, a destroy).
@(private)
wgpu_drop_frame :: proc(r: ^Renderer) {
	g := &r.wg
	if g.frame_rtv != nil && g.surface != nil { wgpu.TextureViewRelease(g.frame_rtv); g.frame_rtv = nil }
	if g.frame_tex != nil && g.surface != nil { wgpu.TextureRelease(g.frame_tex); g.frame_tex = nil }
	if g.surface != nil { g.frame_acquired = false }
}

@(private)
wgpu_resize :: proc(r: ^Renderer, size: [2]int) {
	if size.x <= 0 || size.y <= 0 || size == r.size || r.wg.surface == nil { return }
	r.size = size
	wgpu_configure_surface(r)
}

@(private)
wgpu_set_blend_space :: proc(r: ^Renderer, space: Blend_Space) {
	if space == r.space { return }
	g := &r.wg
	r.space = space
	r.text = text_rendering_default(space)
	release_targets(r)
	wgpu_frame_formats(r)
	if g.surface != nil {
		wgpu_configure_surface(r)
	} else if g.frame_tex != nil {
		wgpu.TextureViewRelease(g.frame_rtv)
		wgpu.TextureRelease(g.frame_tex)
		g.frame_tex, g.frame_rtv = nil, nil
		wgpu_create_offscreen(r)
	}
}

////////////////////////////////
// Pipelines

@(private)
wgpu_module :: proc(g: ^Wgpu_State, label: string, code: string) -> wgpu.ShaderModule {
	src := wgpu.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = code}
	return wgpu.DeviceCreateShaderModule(g.device, &{nextInChain = &src.chain, label = label})
}

@(private)
bgl_buffer :: proc(binding: u32, vis: wgpu.ShaderStageFlags, type: wgpu.BufferBindingType, dyn: bool, min_size: u64) -> wgpu.BindGroupLayoutEntry {
	return {binding = binding, visibility = vis, buffer = {type = type, hasDynamicOffset = b32(dyn), minBindingSize = min_size}}
}

@(private)
bgl_texture :: proc(binding: u32, vis: wgpu.ShaderStageFlags) -> wgpu.BindGroupLayoutEntry {
	return {binding = binding, visibility = vis, texture = {sampleType = .Float, viewDimension = ._2D}}
}

@(private)
bgl_sampler :: proc(binding: u32, vis: wgpu.ShaderStageFlags) -> wgpu.BindGroupLayoutEntry {
	return {binding = binding, visibility = vis, sampler = {type = .Filtering}}
}

// Shaders, bind group layouts, samplers and the placeholders for unbound slots: everything after the device.
@(private)
wgpu_init_pipeline :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	t0 := time.tick_now()
	g.module_rect = wgpu_module(g, "rect.wgsl", WGPU_RECT_SOURCE)
	g.module_fx = wgpu_module(g, "filter.wgsl", WGPU_FILTER_SOURCE)
	g.module_mip = wgpu_module(g, "mip.wgsl", WGPU_MIP_SOURCE)
	g.t_modules = time.duration_milliseconds(time.tick_since(t0))
	VF :: wgpu.ShaderStageFlags{.Vertex, .Fragment}
	V :: wgpu.ShaderStageFlags{.Vertex}
	F :: wgpu.ShaderStageFlags{.Fragment}
	e0 := [?]wgpu.BindGroupLayoutEntry{
		bgl_buffer(0, VF, .Uniform, true, size_of(Globals)),
		bgl_buffer(1, VF, .Uniform, true, size_of(Replay_Constants)),
		bgl_buffer(2, V, .ReadOnlyStorage, false, 0),
		bgl_buffer(3, F, .ReadOnlyStorage, false, 0),
		bgl_buffer(4, F, .ReadOnlyStorage, false, 0),
		bgl_buffer(5, F, .ReadOnlyStorage, false, 0),
		bgl_buffer(6, VF, .ReadOnlyStorage, false, 0),
		bgl_buffer(7, F, .ReadOnlyStorage, false, 0),
		bgl_buffer(8, F, .ReadOnlyStorage, false, 0),
		bgl_buffer(9, F, .ReadOnlyStorage, false, 0),
		bgl_sampler(10, F), bgl_sampler(11, F), bgl_sampler(12, F),
	}
	g.bgl0 = wgpu.DeviceCreateBindGroupLayout(g.device, &{label = "tables", entryCount = len(e0), entries = raw_data(e0[:])})
	e1 := [?]wgpu.BindGroupLayoutEntry{bgl_texture(0, F), bgl_texture(1, F), bgl_texture(2, F)}
	g.bgl1 = wgpu.DeviceCreateBindGroupLayout(g.device, &{label = "textures", entryCount = len(e1), entries = raw_data(e1[:])})
	efx := [?]wgpu.BindGroupLayoutEntry{
		bgl_buffer(0, F, .Uniform, true, PASS_CONSTANTS_SIZE), bgl_texture(1, F), bgl_texture(2, F), bgl_sampler(3, F),
	}
	g.bgl_fx = wgpu.DeviceCreateBindGroupLayout(g.device, &{label = "filter", entryCount = len(efx), entries = raw_data(efx[:])})
	emip := [?]wgpu.BindGroupLayoutEntry{bgl_texture(0, F), bgl_sampler(1, F)}
	g.bgl_mip = wgpu.DeviceCreateBindGroupLayout(g.device, &{label = "mip", entryCount = len(emip), entries = raw_data(emip[:])})
	l_main := [2]wgpu.BindGroupLayout{g.bgl0, g.bgl1}
	g.pl_main = wgpu.DeviceCreatePipelineLayout(g.device, &{label = "main", bindGroupLayoutCount = 2, bindGroupLayouts = raw_data(l_main[:])})
	g.pl_fx = wgpu.DeviceCreatePipelineLayout(g.device, &{label = "filter", bindGroupLayoutCount = 1, bindGroupLayouts = &g.bgl_fx})
	g.pl_mip = wgpu.DeviceCreatePipelineLayout(g.device, &{label = "mip", bindGroupLayoutCount = 1, bindGroupLayouts = &g.bgl_mip})

	sampler :: proc(g: ^Wgpu_State, mode: wgpu.AddressMode) -> wgpu.Sampler {
		return wgpu.DeviceCreateSampler(g.device, &{
			addressModeU = mode, addressModeV = mode, addressModeW = .ClampToEdge,
			magFilter = .Linear, minFilter = .Linear, mipmapFilter = .Linear, lodMinClamp = 0, lodMaxClamp = 32, maxAnisotropy = 1,
		})
	}
	g.s_atlas = sampler(g, .ClampToEdge)
	g.s_img = sampler(g, .ClampToEdge)
	g.s_wrap = sampler(g, .Repeat)
	g.s_fx = g.s_img
	wgpu.SamplerAddRef(g.s_fx)
	g.s_mip = g.s_img
	wgpu.SamplerAddRef(g.s_mip)

	dummy :: proc(g: ^Wgpu_State, format: wgpu.TextureFormat) -> (wgpu.Texture, wgpu.TextureView) {
		t := wgpu.DeviceCreateTexture(g.device, &{
			label = "empty", usage = {.TextureBinding}, dimension = ._2D, size = {1, 1, 1}, format = format, mipLevelCount = 1, sampleCount = 1,
		})
		return t, wgpu.TextureCreateView(t, nil)
	}
	g.dummy_r8, g.dummy_r8_view = dummy(g, .R8Unorm)
	g.dummy_rgba, g.dummy_rgba_view = dummy(g, .RGBA8Unorm)

	if len(r.textures) > 0 { return g.module_rect != nil }   // recover: the settings stay
	append(&r.textures, Texture_Data{})   // dummy slot 0
	r.corner_smoothing = 1
	r.blur_sigma_limit = DEFAULT_BLUR_SIGMA_LIMIT
	r.text = text_rendering_default(r.space)
	return g.module_rect != nil && g.module_fx != nil && g.module_mip != nil
}

@(private)
wgpu_blend :: proc() -> wgpu.BlendState {
	return {
		color = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
		alpha = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
	}
}

// The instanced-quad pipeline for a target of `format`; `replace`: no blending (FLAG_BLEND composites write their result).
@(private)
wgpu_pipeline :: proc(r: ^Renderer, format: wgpu.TextureFormat, replace: bool) -> wgpu.RenderPipeline {
	g := &r.wg
	for p in g.pipes { if p.format == format && p.replace == replace { return p.pipe } }
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
	blend := wgpu_blend()
	target := wgpu.ColorTargetState{format = format, blend = replace ? nil : &blend, writeMask = wgpu.ColorWriteMaskFlags_All}
	fs := wgpu.FragmentState{module = g.module_rect, entryPoint = "ps_main", targetCount = 1, targets = &target}
	pipe := wgpu.DeviceCreateRenderPipeline(g.device, &{
		label = "rect", layout = g.pl_main,
		vertex = {module = g.module_rect, entryPoint = "vs_main", bufferCount = 1, buffers = &vb},
		primitive = {topology = .TriangleStrip, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = 0xFFFFFFFF},
		fragment = &fs,
	})
	g.t_pipelines += time.duration_milliseconds(time.tick_since(t0)); g.n_pipelines += 1
	append(&g.pipes, Wgpu_Pipe{format, replace, pipe})
	return pipe
}

@(private)
wgpu_fx_pipeline :: proc(r: ^Renderer, format: wgpu.TextureFormat) -> wgpu.RenderPipeline {
	g := &r.wg
	for p in g.fx_pipes { if p.format == format { return p.pipe } }
	t0 := time.tick_now()
	target := wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All}
	fs := wgpu.FragmentState{module = g.module_fx, entryPoint = "ps_fx", targetCount = 1, targets = &target}
	pipe := wgpu.DeviceCreateRenderPipeline(g.device, &{
		label = "filter", layout = g.pl_fx,
		vertex = {module = g.module_fx, entryPoint = "vs_fx"},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = 0xFFFFFFFF},
		fragment = &fs,
	})
	g.t_pipelines += time.duration_milliseconds(time.tick_since(t0)); g.n_pipelines += 1
	append(&g.fx_pipes, Wgpu_Pipe{format, false, pipe})
	return pipe
}

@(private)
wgpu_mip_pipeline :: proc(r: ^Renderer, format: wgpu.TextureFormat) -> wgpu.RenderPipeline {
	g := &r.wg
	for p in g.mip_pipes { if p.format == format { return p.pipe } }
	t0 := time.tick_now()
	target := wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All}
	fs := wgpu.FragmentState{module = g.module_mip, entryPoint = "ps_mip", targetCount = 1, targets = &target}
	pipe := wgpu.DeviceCreateRenderPipeline(g.device, &{
		label = "mip", layout = g.pl_mip,
		vertex = {module = g.module_mip, entryPoint = "vs_mip"},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = 0xFFFFFFFF},
		fragment = &fs,
	})
	g.t_pipelines += time.duration_milliseconds(time.tick_since(t0)); g.n_pipelines += 1
	append(&g.mip_pipes, Wgpu_Pipe{format, false, pipe})
	return pipe
}

////////////////////////////////
// Textures

@(private)
wgpu_create_texture_r8 :: proc(r: ^Renderer, size: int) -> Texture {
	td := Texture_Data{size = size, w = size, h = size, kind = .R8}
	if !wgpu_texture_objects(r, &td) { return 0 }
	return add_texture(r, td)
}

// The GPU texture and view of an R8 or RGBA texture described by `td` (kind, size, mips, space). Zeroed by wgpu.
@(private)
wgpu_texture_objects :: proc(r: ^Renderer, td: ^Texture_Data) -> bool {
	g := &r.wg
	format := wgpu.TextureFormat.R8Unorm
	usage := wgpu.TextureUsageFlags{.TextureBinding, .CopyDst}
	levels := 1
	if td.kind == .RGBA {
		format = td.space == .Srgb ? .RGBA8Unorm : .RGBA8UnormSrgb
		if td.mips {
			levels = int(bits.log2(u32(max(td.w, td.h)))) + 1
			usage += {.RenderAttachment}
		}
	}
	td.wformat = format
	td.mip_count = levels
	td.wtex = wgpu.DeviceCreateTexture(g.device, &{
		label = td.kind == .R8 ? "glyph atlas" : "image", usage = usage, dimension = ._2D,
		size = {u32(td.w), u32(td.h), 1}, format = format, mipLevelCount = u32(levels), sampleCount = 1,
	})
	if td.wtex == nil { return false }
	td.wview = wgpu.TextureCreateView(td.wtex, nil)
	td.mips_dirty = td.mips
	return td.wview != nil
}

@(private)
wgpu_update_texture_r8 :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, pitch: int) {
	if int(t) <= 0 || int(t) >= len(r.textures) || w <= 0 || h <= 0 { return }
	td := &r.textures[int(t)]
	if td.wtex == nil || len(pixels) < pitch * (h - 1) + w { return }
	wgpu.QueueWriteTexture(r.wg.queue,
		&{texture = td.wtex, mipLevel = 0, origin = {u32(x), u32(y), 0}, aspect = .All},
		raw_data(pixels), uint(pitch * (h - 1) + w),
		&{offset = 0, bytesPerRow = u32(pitch), rowsPerImage = u32(h)},
		&{u32(w), u32(h), 1})
}

@(private)
wgpu_max_texture_size :: proc(r: ^Renderer) -> int { return r.wg.max_tex > 0 ? r.wg.max_tex : 8192 }

@(private)
wgpu_create_texture_rgba :: proc(r: ^Renderer, w, h: int, mips := true) -> Texture {
	limit := wgpu_max_texture_size(r)
	if w <= 0 || h <= 0 || w > limit || h > limit { return 0 }
	td := Texture_Data{w = w, h = h, size = max(w, h), kind = .RGBA, space = r.space}
	td.mips = mips && (w > 1 || h > 1)
	if !wgpu_texture_objects(r, &td) { return 0 }
	return add_texture(r, td)
}

@(private)
wgpu_update_texture_rgba :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind != .RGBA || td.wtex == nil || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > td.w || y + h > td.h { return }
	pitch := stride > 0 ? stride : w * 4
	if len(pixels) < pitch * (h - 1) + w * 4 { return }
	premultiply_upload(r, td, w, h, pixels, pitch)
	wgpu.QueueWriteTexture(r.wg.queue,
		&{texture = td.wtex, mipLevel = 0, origin = {u32(x), u32(y), 0}, aspect = .All},
		raw_data(r.scratch), uint(w * h * 4),
		&{offset = 0, bytesPerRow = u32(w * 4), rowsPerImage = u32(h)},
		&{u32(w), u32(h), 1})
	if td.mips { td.mips_dirty = true }
}

@(private)
wgpu_release_texture :: proc(td: ^Texture_Data) {
	if td.wrtv != nil { wgpu.TextureViewRelease(td.wrtv) }
	if td.wview != nil { wgpu.TextureViewRelease(td.wview) }
	if td.wtex != nil { wgpu.TextureRelease(td.wtex) }
	td.wrtv, td.wview, td.wtex = nil, nil, nil
}

@(private)
wgpu_destroy_texture :: proc(r: ^Renderer, t: Texture) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind == .None { return }
	wgpu_release_texture(td)
	td^ = {}
	append(&r.free_textures, t)
}

// A pooled layer target (fp16 or 8-bit) or a snapshot of the frame (copy destination, read in the frame's blend space).
@(private)
wgpu_target_objects :: proc(r: ^Renderer, td: ^Texture_Data) -> bool {
	g := &r.wg
	vf := [1]wgpu.TextureFormat{g.view_format}
	if td.kind == .Snapshot {
		td.wformat = g.surface_format
		td.wtex = wgpu.DeviceCreateTexture(g.device, &{
			label = "snapshot", usage = {.TextureBinding, .CopyDst}, dimension = ._2D,
			size = {u32(td.w), u32(td.h), 1}, format = td.wformat, mipLevelCount = 1, sampleCount = 1,
			viewFormatCount = g.view_format != td.wformat ? 1 : 0, viewFormats = raw_data(vf[:]),
		})
		if td.wtex == nil { return false }
		td.wview = wgpu.TextureCreateView(td.wtex, &{
			format = g.view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All,
		})
		return td.wview != nil
	}
	td.wformat = td.unorm ? .RGBA8Unorm : .RGBA16Float
	td.wtex = wgpu.DeviceCreateTexture(g.device, &{
		label = "target", usage = {.TextureBinding, .RenderAttachment, .CopySrc, .CopyDst}, dimension = ._2D,
		size = {u32(td.w), u32(td.h), 1}, format = td.wformat, mipLevelCount = 1, sampleCount = 1,
	})
	if td.wtex == nil { return false }
	td.wview = wgpu.TextureCreateView(td.wtex, nil)
	td.wrtv = wgpu.TextureCreateView(td.wtex, nil)
	return td.wview != nil && td.wrtv != nil
}

////////////////////////////////
// Retained heaps

@(private)
wgpu_heap_usage :: proc(kind: Heap_Kind) -> wgpu.BufferUsageFlags {
	return kind == .Insts ? wgpu.BufferUsageFlags{.Vertex, .CopyDst, .CopySrc} : wgpu.BufferUsageFlags{.Storage, .CopyDst, .CopySrc}
}

@(private)
wgpu_heap_write :: proc(r: ^Renderer, kind: Heap_Kind, offset: int, data: rawptr, n: int) {
	h := &r.heaps[kind]
	if n <= 0 || h.wbuf == nil || offset < 0 || offset + n > h.cap { return }
	stride := HEAP_STRIDE[kind]
	wgpu.QueueWriteBuffer(r.wg.queue, h.wbuf, u64(offset * stride), data, uint(n * stride))
}

@(private)
wgpu_heap_grow :: proc(r: ^Renderer, kind: Heap_Kind, need: int) -> bool {
	g := &r.wg
	h := &r.heaps[kind]
	stride := HEAP_STRIDE[kind]
	ncap := max(h.cap * 2, h.cap + need, HEAP_MIN)
	buf := wgpu.DeviceCreateBuffer(g.device, &{label = "retained heap", usage = wgpu_heap_usage(kind), size = u64(ncap * stride)})
	if buf == nil {
		fmt.eprintln("render: cannot grow the retained heap", kind, "to", ncap * stride, "bytes")
		return false
	}
	if h.wbuf != nil {
		enc := wgpu.DeviceCreateCommandEncoder(g.device)
		wgpu.CommandEncoderCopyBufferToBuffer(enc, h.wbuf, 0, buf, 0, u64(h.cap * stride))
		cb := wgpu.CommandEncoderFinish(enc)
		wgpu.QueueSubmit(g.queue, {cb})
		wgpu.CommandBufferRelease(cb)
		wgpu.CommandEncoderRelease(enc)
		wgpu.BufferRelease(h.wbuf)
	}
	old := h.cap
	h.wbuf, h.cap = buf, ncap
	insert_free(h, old, ncap - old)
	return true
}

@(private)
wgpu_heaps_destroy :: proc(r: ^Renderer) {
	for &h in r.heaps {
		if h.wbuf != nil { wgpu.BufferRelease(h.wbuf) }
		delete(h.free)
		h = {}
	}
}

////////////////////////////////
// Teardown and device loss

@(private)
wgpu_release_pipelines :: proc(g: ^Wgpu_State) {
	for p in g.pipes { wgpu.RenderPipelineRelease(p.pipe) }
	for p in g.fx_pipes { wgpu.RenderPipelineRelease(p.pipe) }
	for p in g.mip_pipes { wgpu.RenderPipelineRelease(p.pipe) }
	clear(&g.pipes); clear(&g.fx_pipes); clear(&g.mip_pipes)
}

// Every object made on the device (not the device itself): what destroy releases, minus the CPU state.
@(private)
wgpu_release_objects :: proc(r: ^Renderer) {
	g := &r.wg
	for &td in r.textures { wgpu_release_texture(&td) }
	clear(&r.targets)
	r.targets_gen += 1
	wgpu_profile_release(r)
	wgpu_drop_frame(r)
	if g.surface == nil && g.frame_tex != nil {
		wgpu.TextureViewRelease(g.frame_rtv)
		wgpu.TextureRelease(g.frame_tex)
		g.frame_tex, g.frame_rtv = nil, nil
	}
	wgpu_release_pipelines(g)
	rel :: proc(p: ^$T, $f: proc "c" (T)) { if p^ != nil { f(p^); p^ = nil } }
	for t in ([?]^Wgpu_Table{&g.inst, &g.xforms, &g.clips, &g.points, &g.grads}) {
		if t.buf != nil { wgpu.BufferRelease(t.buf) }
		t^ = {}
	}
	if g.arena != nil { wgpu.BufferRelease(g.arena); g.arena = nil }
	g.arena_cap = 0
	rel(&g.dummy_r8_view, wgpu.TextureViewRelease); rel(&g.dummy_rgba_view, wgpu.TextureViewRelease)
	rel(&g.dummy_r8, wgpu.TextureRelease); rel(&g.dummy_rgba, wgpu.TextureRelease)
	rel(&g.s_atlas, wgpu.SamplerRelease); rel(&g.s_img, wgpu.SamplerRelease); rel(&g.s_wrap, wgpu.SamplerRelease)
	rel(&g.s_fx, wgpu.SamplerRelease); rel(&g.s_mip, wgpu.SamplerRelease)
	rel(&g.pl_main, wgpu.PipelineLayoutRelease); rel(&g.pl_fx, wgpu.PipelineLayoutRelease); rel(&g.pl_mip, wgpu.PipelineLayoutRelease)
	rel(&g.bgl0, wgpu.BindGroupLayoutRelease); rel(&g.bgl1, wgpu.BindGroupLayoutRelease)
	rel(&g.bgl_fx, wgpu.BindGroupLayoutRelease); rel(&g.bgl_mip, wgpu.BindGroupLayoutRelease)
	rel(&g.module_rect, wgpu.ShaderModuleRelease); rel(&g.module_fx, wgpu.ShaderModuleRelease); rel(&g.module_mip, wgpu.ShaderModuleRelease)
}

// Surface, device, adapter, instance.
@(private)
wgpu_release_device :: proc(r: ^Renderer) {
	g := &r.wg
	if g.surface != nil { wgpu.SurfaceUnconfigure(g.surface); wgpu.SurfaceRelease(g.surface); g.surface = nil }
	g.configured = false
	if g.queue != nil { wgpu.QueueRelease(g.queue); g.queue = nil }
	if g.device != nil { wgpu.DeviceDestroy(g.device); wgpu.DeviceRelease(g.device); g.device = nil }
	if g.adapter != nil { wgpu.AdapterRelease(g.adapter); g.adapter = nil }
	if g.instance != nil { wgpu.InstanceRelease(g.instance); g.instance = nil }
}

@(private)
wgpu_destroy :: proc(r: ^Renderer) {
	for i in 1 ..< len(r.textures) { wgpu_destroy_texture(r, Texture(i)) }
	delete(r.textures); delete(r.free_textures); delete(r.targets); delete(r.scratch)
	wgpu_latency_stop(r)
	wgpu_release_objects(r)
	wgpu_heaps_destroy(r)
	wgpu_release_device(r)
	present_destroy(r)
	delete(r.wg.pipes); delete(r.wg.fx_pipes); delete(r.wg.mip_pipes)
	if r.wg.shared != nil { free(r.wg.shared) }
	r^ = {}
}

@(private)
wgpu_recover :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	hwnd := r.hwnd
	was_offscreen := g.surface == nil
	wgpu_latency_stop(r)
	wgpu_release_objects(r)
	wgpu_release_device(r)
	g.shared.lost = false
	ok := wgpu_create_device(r, hwnd, r.warp)
	if ok { wgpu_frame_formats(r) }
	ok = ok && (was_offscreen ? wgpu_create_offscreen(r) : wgpu_configure_surface(r))
	ok = ok && wgpu_init_pipeline(r)
	for i in 1 ..< len(r.textures) {
		td := &r.textures[i]
		#partial switch td.kind {
		case .R8, .RGBA:
			if !wgpu_texture_objects(r, td) { fmt.eprintln("render: texture", i, "could not be recreated"); td.kind = .None }
		case:
			if td.kind != .None { td^ = {}; append(&r.free_textures, Texture(i)) }
		}
	}
	wgpu_heaps_destroy(r)
	r.heap_generation += 1
	r.device_generation += 1
	r.gpu_frame = 0
	r.lost = !ok
	return ok
}

// Start-up costs of the WebGPU backend, in milliseconds: device creation, shader modules, and the render pipelines made so far (count).
wgpu_costs :: proc(r: ^Renderer) -> (device, modules, pipelines: f64, count: int) {
	return r.wg.t_device, r.wg.t_modules, r.wg.t_pipelines, r.wg.n_pipelines
}

// TOOLKIT_WGPU_TRACE=1 in the environment: timings of the surface calls on stderr.
@(private)
wgpu_trace :: proc() -> bool {
	@(static) state: int   // 0: unknown, 1: off, 2: on
	if state == 0 { state = os.get_env("TOOLKIT_WGPU_TRACE", context.temp_allocator) != "" ? 2 : 1 }
	return state == 2
}
