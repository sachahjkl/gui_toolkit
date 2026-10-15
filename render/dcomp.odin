package render

// Minimal DirectComposition bindings: just enough to show a swap chain with per-pixel alpha in a window (what a
// translucent window needs; an HWND swap chain is always opaque).

import win "core:sys/windows"

foreign import dcomp_lib "system:dcomp.lib"

@(default_calling_convention = "system")
foreign dcomp_lib {
	DCompositionCreateDevice :: proc(dxgiDevice: ^win.IUnknown, iid: ^win.GUID, dcompositionDevice: ^rawptr) -> win.HRESULT ---
}

IDCompositionDevice_UUID := &win.GUID{0xC37EA93A, 0xE7AA, 0x450D, {0xB1, 0x6F, 0x97, 0x46, 0xCB, 0x04, 0x07, 0xF3}}

IDCompositionDevice :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^IDCompositionDevice_VTable,
}
IDCompositionDevice_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	Commit:                  proc "system" (this: ^IDCompositionDevice) -> win.HRESULT,
	WaitForCommitCompletion: proc "system" (this: ^IDCompositionDevice) -> win.HRESULT,
	GetFrameStatistics:      rawptr,
	CreateTargetForHwnd:     proc "system" (this: ^IDCompositionDevice, hwnd: win.HWND, topmost: win.BOOL, target: ^^IDCompositionTarget) -> win.HRESULT,
	CreateVisual:            proc "system" (this: ^IDCompositionDevice, visual: ^^IDCompositionVisual) -> win.HRESULT,
}

IDCompositionTarget :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^IDCompositionTarget_VTable,
}
IDCompositionTarget_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	SetRoot: proc "system" (this: ^IDCompositionTarget, visual: ^IDCompositionVisual) -> win.HRESULT,
}

IDCompositionVisual :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^IDCompositionVisual_VTable,
}
IDCompositionVisual_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	_: [12]rawptr,   // SetOffsetX x2, SetOffsetY x2, SetTransform x2, SetTransformParent, SetEffect, SetBitmapInterpolationMode, SetBorderMode, SetClip x2
	SetContent: proc "system" (this: ^IDCompositionVisual, content: ^win.IUnknown) -> win.HRESULT,
}
