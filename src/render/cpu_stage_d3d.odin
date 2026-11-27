#+build windows
package render

// The CPU stage on Direct3D 11 (cpu_stage.odin, src/md/infrastructure/cpu-first-frames.md). A host's window is
// translucent, made with WS_EX_NOREDIRECTIONBITMAP: it has no GDI surface, and only DirectComposition shows anything in
// it. So the CPU frames go to a composition swap chain of a WARP device (made in milliseconds: no driver to load) on the
// window's own visual. The renderer takes that visual over (init_composition) and shows its own chain there after the
// chain's first present, in one commit (composition_show): DirectComposition never shows the visual without content,
// and no frame is blank. A window without composition shows the CPU frames through GDI (platform.show_pixels), until
// its flip-model chain presents.

// (required: on the wgpu backend the procedures below are not built)
@(require) import "core:fmt"
@(require) import win "core:sys/windows"
@(require) import "vendor:directx/d3d11"
@(require) import "vendor:directx/dxgi"

when !USE_WGPU {

// The WARP device, its composition chain at `size`, and the window's DirectComposition target with a visual that shows
// the chain. False: none of it (the stage does not start; what was made is released by the caller).
@(private)
cpu_show_open :: proc(r: ^Renderer, size: [2]int) -> bool {
	s := &r.cpu.show
	holder: Renderer
	if !create_device(&holder, .WARP) { return false }
	s.device, s.ctx = holder.device, holder.ctx
	dxgi_device: ^dxgi.IDevice
	if hr_failed(s.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))) || dxgi_device == nil { return false }
	defer dxgi_device->Release()
	adapter: ^dxgi.IAdapter
	if hr_failed(dxgi_device->GetAdapter(&adapter)) || adapter == nil { return false }
	defer adapter->Release()
	factory: ^dxgi.IFactory2
	if hr_failed(adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory))) || factory == nil { return false }
	defer factory->Release()
	desc := dxgi.SWAP_CHAIN_DESC1{
		Width = u32(max(size.x, 1)), Height = u32(max(size.y, 1)), Format = .B8G8R8A8_UNORM, SampleDesc = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT}, BufferCount = 2, Scaling = .STRETCH, SwapEffect = .FLIP_SEQUENTIAL,
		// (the CPU frame is premultiplied, its sRGB-encoded bytes what an 8-bit chain holds: DWM reads them as sRGB)
		AlphaMode = .PREMULTIPLIED,
	}
	if hr_failed(factory->CreateSwapChainForComposition(s.device, &desc, nil, &s.swapchain)) || s.swapchain == nil { return false }
	s.size = size
	ok := win.SUCCEEDED(DCompositionCreateDevice((^win.IUnknown)(dxgi_device), IDCompositionDevice_UUID, (^rawptr)(&s.dcomp)))
	ok = ok && win.SUCCEEDED(s.dcomp->CreateTargetForHwnd(r.hwnd, !r.under_children, &s.target))
	ok = ok && win.SUCCEEDED(s.dcomp->CreateVisual(&s.visual))
	ok = ok && win.SUCCEEDED(s.visual->SetContent((^win.IUnknown)(s.swapchain)))
	ok = ok && win.SUCCEEDED(s.target->SetRoot(s.visual))
	return ok
}

// The CPU frame (r.cpu.bgra) into the chain's back buffer, presented; the first one commits the visual. False: not shown.
@(private)
cpu_show_present :: proc(r: ^Renderer) -> bool {
	s := &r.cpu.show
	if r.size.x <= 0 || r.size.y <= 0 { return false }
	if r.size != s.size {
		if hr_failed(s.swapchain->ResizeBuffers(0, u32(r.size.x), u32(r.size.y), .UNKNOWN, {})) { return false }
		s.size = r.size
	}
	buffer: ^d3d11.ITexture2D
	if hr_failed(s.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&buffer))) || buffer == nil { return false }
	s.ctx->UpdateSubresource(buffer, 0, nil, raw_data(r.cpu.bgra), u32(r.size.x * 4), 0)
	buffer->Release()
	if hr_failed(s.swapchain->Present(0, {})) { return false }
	if !s.committed { s.committed = win.SUCCEEDED(s.dcomp->Commit()) }
	return s.committed
}

// The end of the stage: the device (waited for), the window's chain (on the stage's visual, init_composition), the
// pipelines, then every texture and retained heap given its GPU object and its pixels. False: no device (init_failure
// says why), the frames stay on the CPU.
@(private)
cpu_stage_end_d3d :: proc(r: ^Renderer) -> bool {
	in_ := r.cpu.init
	if !d3d_init(r, in_.surface, r.size, in_.transparent, in_.space) {
		if r.failure.error == .None { r.failure.error = .Failed }
		r.cpu.failed = true
		fmt.eprintln("render: the graphics device did not come: the frames stay on the CPU")
		return false
	}
	for i in 1 ..< len(r.textures) {
		td := &r.textures[i]
		#partial switch td.kind {
		case .R8, .RGBA, .Slug_Curves, .Slug_Bands, .Data:
			if !texture_objects(r, td) { fmt.eprintln("render: texture", i, "could not be made"); td^ = {kind = .Failed}; continue }
			if i >= len(r.cpu.texels) || r.cpu.texels[i] == nil { continue }
			r.ctx->UpdateSubresource(td.tex, 0, nil, raw_data(r.cpu.texels[i]), u32(td.w * cpu_texel_bytes(td)), 0)
			if td.kind == .RGBA { td.unfilled = false }
			if td.mips { td.mips_dirty = true }
		}
	}
	for kind in Heap_Kind { cpu_heap_make_d3d(r, kind) }
	d3d_app_shaders_recreate(r)
	cpu_stage_ended(r)
	return true
}

// A retained heap of the stage made on the device, at its room, with its contents.
@(private = "file")
cpu_heap_make_d3d :: proc(r: ^Renderer, kind: Heap_Kind) {
	h := &r.heaps[kind]
	if h.cap == 0 { return }
	stride := HEAP_STRIDE[kind]
	desc := d3d11.BUFFER_DESC{ByteWidth = u32(h.cap * stride), Usage = .DEFAULT}
	if kind == .Insts {
		desc.BindFlags = {.VERTEX_BUFFER}
	} else {
		desc.BindFlags = {.SHADER_RESOURCE}
		desc.MiscFlags = {.BUFFER_ALLOW_RAW_VIEWS}
	}
	data := r.cpu.heaps[kind]
	init := d3d11.SUBRESOURCE_DATA{pSysMem = raw_data(data)}
	if hr_failed(r.device->CreateBuffer(&desc, len(data) >= h.cap * stride ? &init : nil, &h.buf)) || h.buf == nil {
		fmt.eprintln("render: the retained heap", kind, "could not be made")
		h.buf = nil
		return
	}
	if kind != .Insts { h.view = raw_buffer_view(r, h.buf, h.cap * stride) }
}

}   // when !USE_WGPU
