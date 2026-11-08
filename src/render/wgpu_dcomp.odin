package render

import win "core:sys/windows"
import "vendor:directx/dxgi"
import "vendor:wgpu"

// WebGPU backend: a translucent window (premultiplied alpha, what DirectComposition shows) and the integrated title bar's
// transparent areas.
//
// wgpu-native 29 gives a surface made from an HWND an opaque swap chain only (its alpha modes: [Opaque]) and has no call to
// make a surface from a DirectComposition visual (wgpu's Rust API has one, the C API does not). What it does have is
// SurfaceSourceSwapChainPanel, meant for WinUI: the surface is made on a "swap chain panel", an object implementing
// ISwapChainPanelNative, and wgpu creates a composition swap chain (CreateSwapChainForComposition, alpha modes allowed) and
// hands it over with ISwapChainPanelNative::SetSwapChain. Anything can implement that interface: `Panel` below does, and its
// SetSwapChain puts the swap chain into the content of a DirectComposition visual of the window.

@(private)
Panel_VTable :: struct {
	QueryInterface: proc "system" (this: ^Panel, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^Panel) -> u32,
	Release:        proc "system" (this: ^Panel) -> u32,
	SetSwapChain:   proc "system" (this: ^Panel, swap_chain: ^win.IUnknown) -> win.HRESULT,
}

// An ISwapChainPanelNative (its pointer is what wgpu holds: the vtable comes first).
@(private)
Panel :: struct {
	vtable:  ^Panel_VTable,
	refs:    u32,
	hr:      win.HRESULT,           // result of the last SetSwapChain
	swap_chain: ^win.IUnknown,      // the one wgpu handed over (for the color space of a later format)
	color_space: dxgi.COLOR_SPACE_TYPE,
	dcomp:   ^IDCompositionDevice,
	target:  ^IDCompositionTarget,
	visual:  ^IDCompositionVisual,
}

@(private) panel_vtable := Panel_VTable{
	QueryInterface = panel_query_interface,
	AddRef = panel_add_ref,
	Release = panel_release,
	SetSwapChain = panel_set_swap_chain,
}

@(private) IID_ISwapChainPanelNative := win.GUID{0x63aad0b8, 0x7c24, 0x40ff, {0x85, 0xa8, 0x64, 0x0d, 0x94, 0x4c, 0xc3, 0x25}}

@(private) IID_IUnknown_ := win.GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46}}

@(private)
guid_equal :: proc "contextless" (a, b: ^win.GUID) -> bool { return a^ == b^ }

@(private)
panel_query_interface :: proc "system" (this: ^Panel, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT {
	if guid_equal(riid, &IID_IUnknown_) || guid_equal(riid, &IID_ISwapChainPanelNative) {
		out^ = this
		this.refs += 1
		return 0
	}
	out^ = nil
	return win.HRESULT(-2147467262)   // E_NOINTERFACE
}

@(private)
panel_add_ref :: proc "system" (this: ^Panel) -> u32 { this.refs += 1; return this.refs }

// The panel is owned by the renderer (freed in wgpu_dcomp_destroy); wgpu's references only count.
@(private)
panel_release :: proc "system" (this: ^Panel) -> u32 { if this.refs > 0 { this.refs -= 1 }; return this.refs }

@(private)
panel_set_swap_chain :: proc "system" (this: ^Panel, swap_chain: ^win.IUnknown) -> win.HRESULT {
	if swap_chain == nil { this.hr = this.visual->SetContent(nil); return this.hr }
	// an fp16 swap chain holds scRGB (linear light), an 8-bit one premultiplied sRGB values: tell the compositor which
	sc3: ^dxgi.ISwapChain3
	if hr_ok(swap_chain->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&sc3))) && sc3 != nil {
		sc3->SetColorSpace1(this.color_space)
		sc3->Release()
	}
	if this.swap_chain != nil { this.swap_chain->Release() }
	swap_chain->AddRef()
	this.swap_chain = swap_chain
	hr := this.visual->SetContent(swap_chain)
	if hr_ok(hr) { hr = this.dcomp->Commit() }
	this.hr = hr
	return hr
}

// A surface on a DirectComposition visual of `hwnd`. nil: not available (the caller falls back to an opaque HWND surface).
@(private)
wgpu_dcomp_surface :: proc(r: ^Renderer, hwnd: win.HWND) -> wgpu.Surface {
	g := &r.wg
	p := new(Panel)
	p.vtable = &panel_vtable
	p.refs = 1
	p.color_space = r.space == .Srgb ? .RGB_FULL_G22_NONE_P709 : .RGB_FULL_G10_NONE_P709
	ok := hr_ok(DCompositionCreateDevice(nil, IDCompositionDevice_UUID, (^rawptr)(&p.dcomp)))
	ok = ok && hr_ok(p.dcomp->CreateTargetForHwnd(hwnd, true, &p.target))
	ok = ok && hr_ok(p.dcomp->CreateVisual(&p.visual))
	ok = ok && hr_ok(p.target->SetRoot(p.visual))
	if !ok { panel_free(p); return nil }
	src := wgpu.SurfaceSourceSwapChainPanel{chain = {sType = .SurfaceSourceSwapChainPanel}, panelNative = p}
	surface := wgpu.InstanceCreateSurface(g.instance, &{nextInChain = &src.chain, label = "window (DirectComposition)"})
	if surface == nil { panel_free(p); return nil }
	g.panel = p
	return surface
}

@(private)
panel_free :: proc(p: ^Panel) {
	if p.swap_chain != nil { p.swap_chain->Release() }
	if p.visual != nil { p.visual->Release() }
	if p.target != nil { p.target->Release() }
	if p.dcomp != nil { p.dcomp->Release() }
	free(p)
}

@(private)
wgpu_dcomp_destroy :: proc(r: ^Renderer) {
	if r.wg.panel != nil { panel_free(r.wg.panel); r.wg.panel = nil }
}

// Tells the compositor the color space of the swap chain after the blend space changed (set_blend_space).
@(private)
wgpu_dcomp_color_space :: proc(r: ^Renderer) {
	p := r.wg.panel
	if p == nil { return }
	p.color_space = r.space == .Srgb ? .RGB_FULL_G22_NONE_P709 : .RGB_FULL_G10_NONE_P709
	sc3: ^dxgi.ISwapChain3
	if p.swap_chain != nil && hr_ok(p.swap_chain->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&sc3))) && sc3 != nil {
		sc3->SetColorSpace1(p.color_space)
		sc3->Release()
	}
}
