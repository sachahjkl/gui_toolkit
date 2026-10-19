#+build windows
package font

// Direct2D bindings for color glyphs: a device context on a private D3D11 device draws a glyph run with every color
// representation DirectWrite knows (COLR v0 layers, COLR v1 paint trees, sbix / CBDT / PNG bitmaps, SVG) into a
// bitmap read back on the CPU. Only the methods the package calls are typed; vtable slot numbers follow d2d1.h,
// d2d1_1.h and d2d1_3.h of the Windows SDK (C++ declaration order, every STDMETHOD counted), unused ones are padding.

import "vendor:directx/d3d11"

foreign import d2d1_lib "system:d2d1.lib"

D2D1_COLOR_F :: struct { r, g, b, a: f32 }
D2D1_SIZE_U :: struct { width, height: u32 }
D2D1_POINT_2U :: struct { x, y: u32 }
D2D1_RECT_U :: struct { left, top, right, bottom: u32 }
D2D1_MATRIX_3X2_F :: [6]f32

D2D1_PIXEL_FORMAT :: struct {
	format:    u32,   // DXGI_FORMAT
	alphaMode: u32,
}

D2D1_BITMAP_PROPERTIES1 :: struct {
	pixelFormat:   D2D1_PIXEL_FORMAT,
	dpiX, dpiY:    f32,
	bitmapOptions: u32,
	colorContext:  rawptr,
}

D2D1_MAPPED_RECT :: struct {
	pitch: u32,
	bits:  [^]u8,
}

D2D1_CREATION_PROPERTIES :: struct {
	threadingMode: u32,   // 0 single-threaded, 1 multi-threaded
	debugLevel:    u32,
	options:       u32,
}

DXGI_FORMAT_B8G8R8A8_UNORM :: 87
D2D1_ALPHA_MODE_PREMULTIPLIED :: 1
D2D1_BITMAP_OPTIONS_TARGET :: 0x1
D2D1_BITMAP_OPTIONS_CANNOT_DRAW :: 0x2
D2D1_BITMAP_OPTIONS_CPU_READ :: 0x4
D2D1_MAP_OPTIONS_READ :: 1
D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE :: 2
D2D1_COLOR_BITMAP_GLYPH_SNAP_OPTION_DISABLE :: 1
DWRITE_PAINT_FEATURE_LEVEL_COLR_V1 :: 2
DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE :: DWRITE_GLYPH_IMAGE_FORMATS(0x100)

@(default_calling_convention = "system")
foreign d2d1_lib {
	D2D1CreateDevice :: proc(dxgi_device: rawptr, props: ^D2D1_CREATION_PROPERTIES, device: ^^ID2D1Device) -> HRESULT ---
}

IID_ID2D1DeviceContext4 := IID{0x8c427831, 0x3d90, 0x4476, {0xb6, 0x47, 0xc4, 0xfa, 0xe3, 0x49, 0xe4, 0xdb}}
IID_ID2D1DeviceContext7 := IID{0xec891cf7, 0x9b69, 0x4851, {0x9d, 0xef, 0x4e, 0x09, 0x15, 0x77, 0x1e, 0x62}}
IID_IDXGIDevice := IID{0x54ec77fa, 0x1377, 0x44e6, {0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c}}

ID2D1Device :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^ID2D1Device_VTable,
}
ID2D1Device_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFactory:          rawptr,
	CreateDeviceContext: proc "system" (this: ^ID2D1Device, options: u32, dc: ^^ID2D1DeviceContext) -> HRESULT,
}

ID2D1Brush :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^ID2D1SolidColorBrush_VTable,
}
ID2D1SolidColorBrush :: ID2D1Brush
ID2D1SolidColorBrush_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFactory:   rawptr,
	SetOpacity:   rawptr,
	SetTransform: rawptr,
	GetOpacity:   rawptr,
	GetTransform: rawptr,
	SetColor:     proc "system" (this: ^ID2D1SolidColorBrush, color: ^D2D1_COLOR_F),
}

ID2D1Bitmap1 :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^ID2D1Bitmap1_VTable,
}
ID2D1Bitmap1_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFactory:           rawptr,   // 3 (ID2D1Resource)
	GetSize:              rawptr,   // 4 (ID2D1Bitmap)
	GetPixelSize:         rawptr,
	GetPixelFormat:       rawptr,
	GetDpi:               rawptr,
	CopyFromBitmap:       proc "system" (this: ^ID2D1Bitmap1, dst: ^D2D1_POINT_2U, src: ^ID2D1Bitmap1, rect: ^D2D1_RECT_U) -> HRESULT,
	CopyFromRenderTarget: rawptr,
	CopyFromMemory:       rawptr,
	GetColorContext:      rawptr,   // 11 (ID2D1Bitmap1)
	GetOptions:           rawptr,
	GetSurface:           rawptr,
	Map:                  proc "system" (this: ^ID2D1Bitmap1, options: u32, mapped: ^D2D1_MAPPED_RECT) -> HRESULT,
	Unmap:                proc "system" (this: ^ID2D1Bitmap1) -> HRESULT,
}

// ID2D1DeviceContext7 (ID2D1RenderTarget 4..56, ID2D1DeviceContext 57..91, 1: 92..94, 2: 95..105, 3: 106..107,
// 4: 108..114, 5: 115..118, 6: 119, 7: 120..122). Methods past slot 91 may only be called on an object obtained by
// QueryInterface for the interface that declares them.
ID2D1DeviceContext :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^ID2D1DeviceContext_VTable,
}
ID2D1DeviceContext_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFactory:            rawptr,                                                    // 3
	_rt0:                  [4]rawptr,                                                 // 4..7
	CreateSolidColorBrush: proc "system" (this: ^ID2D1DeviceContext, color: ^D2D1_COLOR_F, props: rawptr, brush: ^^ID2D1SolidColorBrush) -> HRESULT,   // 8
	_rt1:                  [20]rawptr,                                                // 9..28
	DrawGlyphRun:          proc "system" (this: ^ID2D1DeviceContext, origin: D2D1_POINT_2F, run: ^DWRITE_GLYPH_RUN, brush: ^ID2D1Brush, mode: DWRITE_MEASURING_MODE),   // 29
	SetTransform:          proc "system" (this: ^ID2D1DeviceContext, m: ^D2D1_MATRIX_3X2_F),   // 30
	_rt2:                  [3]rawptr,                                                 // 31..33
	SetTextAntialiasMode:  proc "system" (this: ^ID2D1DeviceContext, mode: u32),      // 34
	_rt3:                  [12]rawptr,                                                // 35..46
	Clear:                 proc "system" (this: ^ID2D1DeviceContext, color: ^D2D1_COLOR_F),   // 47
	BeginDraw:             proc "system" (this: ^ID2D1DeviceContext),                 // 48
	EndDraw:               proc "system" (this: ^ID2D1DeviceContext, tag1, tag2: ^u64) -> HRESULT,   // 49
	_rt4:                  [7]rawptr,                                                 // 50..56
	CreateBitmap:          proc "system" (this: ^ID2D1DeviceContext, size: D2D1_SIZE_U, src: rawptr, pitch: u32, props: ^D2D1_BITMAP_PROPERTIES1, bitmap: ^^ID2D1Bitmap1) -> HRESULT,   // 57
	_dc0:                  [16]rawptr,                                                // 58..73
	SetTarget:             proc "system" (this: ^ID2D1DeviceContext, image: ^ID2D1Bitmap1),   // 74
	_dc1:                  [36]rawptr,                                                // 75..110
	DrawColorBitmapGlyphRun: proc "system" (this: ^ID2D1DeviceContext, format: DWRITE_GLYPH_IMAGE_FORMATS, origin: D2D1_POINT_2F, run: ^DWRITE_GLYPH_RUN, mode: DWRITE_MEASURING_MODE, snap: u32),   // 111
	DrawSvgGlyphRun:       proc "system" (this: ^ID2D1DeviceContext, origin: D2D1_POINT_2F, run: ^DWRITE_GLYPH_RUN, fill: ^ID2D1Brush, style: rawptr, palette: u32, mode: DWRITE_MEASURING_MODE),   // 112
	_dc4:                  [7]rawptr,                                                 // 113..119
	GetPaintFeatureLevel:  proc "system" (this: ^ID2D1DeviceContext) -> u32,          // 120
	DrawPaintGlyphRun:     proc "system" (this: ^ID2D1DeviceContext, origin: D2D1_POINT_2F, run: ^DWRITE_GLYPH_RUN, fill: ^ID2D1Brush, palette: u32, mode: DWRITE_MEASURING_MODE),   // 121
	DrawGlyphRunWithColorSupport: proc "system" (this: ^ID2D1DeviceContext, origin: D2D1_POINT_2F, run: ^DWRITE_GLYPH_RUN, desc: ^DWRITE_GLYPH_RUN_DESCRIPTION,
		fg: ^ID2D1Brush, style: rawptr, palette: u32, mode: DWRITE_MEASURING_MODE, snap: u32),   // 122
}

#assert(offset_of(ID2D1DeviceContext_VTable, CreateSolidColorBrush) == 8 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, DrawGlyphRun) == 29 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, Clear) == 47 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, EndDraw) == 49 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, CreateBitmap) == 57 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, SetTarget) == 74 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, DrawColorBitmapGlyphRun) == 111 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, GetPaintFeatureLevel) == 120 * size_of(rawptr))
#assert(offset_of(ID2D1DeviceContext_VTable, DrawGlyphRunWithColorSupport) == 122 * size_of(rawptr))
#assert(offset_of(ID2D1Bitmap1_VTable, CopyFromBitmap) == 8 * size_of(rawptr))
#assert(offset_of(ID2D1Bitmap1_VTable, Map) == 14 * size_of(rawptr))

// A D3D11 device of `driver` with BGRA support (what Direct2D needs), as a DXGI device for D2D1CreateDevice.
@(private)
d3d_device_for_d2d :: proc(driver: d3d11.DRIVER_TYPE) -> (dev: ^d3d11.IDevice, dxgi_dev: rawptr) {
	levels := [?]d3d11.FEATURE_LEVEL{._11_0, ._10_1, ._10_0, ._9_3}
	if d3d11.CreateDevice(nil, driver, nil, {.BGRA_SUPPORT}, &levels[0], len(levels), d3d11.SDK_VERSION, &dev, nil, nil) < 0 || dev == nil {
		return nil, nil
	}
	if dev->QueryInterface(&IID_IDXGIDevice, &dxgi_dev) < 0 || dxgi_dev == nil {
		dev->Release()
		return nil, nil
	}
	return
}
