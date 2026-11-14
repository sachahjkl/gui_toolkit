#+build windows
package capture

// A window's picture through Windows.Graphics.Capture (Windows 10 1903 and later): the window's own content, whatever
// covers it. One frame from a free-threaded Direct3D11CaptureFramePool, then everything is closed: a window capture is
// rare enough (a click in a screenshot tool) that keeping a session open would only keep the capture border on screen.
// A stream (the end of this file) keeps its pool and its session open instead, of a window or of a monitor.
//
// The interfaces are declared here with no projection (docs/winrt.md): vtables in the order of the SDK's headers
// (windows.graphics.capture.h, windows.graphics.directx.direct3d11.interop.h).

import "base:runtime"
import "core:time"
import win "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import winrt "../winrt"

foreign import d3d11_capture "system:d3d11.lib"

@(default_calling_convention = "system", private = "file")
foreign d3d11_capture {
	// The D3D11 device as WinRT takes it (an IDirect3DDevice).
	CreateDirect3D11DeviceFromDXGIDevice :: proc(device: ^dxgi.IDevice, graphics_device: ^rawptr) -> win.HRESULT ---
}

@(private = "file") CLASS_ITEM :: "Windows.Graphics.Capture.GraphicsCaptureItem"
@(private = "file") CLASS_FRAME_POOL :: "Windows.Graphics.Capture.Direct3D11CaptureFramePool"
@(private = "file") PIXEL_FORMAT_B8G8R8A8 :: 87   // DirectXPixelFormat.B8G8R8A8UIntNormalized
@(private = "file") FRAME_MS :: 1000              // the first frame comes within a few refreshes; a window that never draws, none

@(private = "file") IID_IGraphicsCaptureItemInterop       :: winrt.GUID{0x3628e81b, 0x3cac, 0x4c60, {0xb7, 0xf4, 0x23, 0xce, 0x0e, 0x0c, 0x33, 0x56}}
@(private = "file") IID_IGraphicsCaptureItem              :: winrt.GUID{0x79c3f95b, 0x31f7, 0x4ec2, {0xa4, 0x64, 0x63, 0x2e, 0xf5, 0xd3, 0x07, 0x60}}
@(private = "file") IID_IDirect3D11CaptureFramePoolStatics2 :: winrt.GUID{0x589b103f, 0x6bbc, 0x5df5, {0xa9, 0x91, 0x02, 0xe2, 0x8b, 0x3b, 0x66, 0xd5}}
@(private = "file") IID_IDirect3D11CaptureFramePool       :: winrt.GUID{0x24eb6d22, 0x1975, 0x422e, {0x82, 0xe7, 0x78, 0x0d, 0xbd, 0x8d, 0xdf, 0x24}}
@(private = "file") IID_IGraphicsCaptureSession2          :: winrt.GUID{0x2c39ae40, 0x7d2e, 0x5044, {0x80, 0x4e, 0x8b, 0x67, 0x99, 0xd4, 0xcf, 0x9e}}
@(private = "file") IID_IDirect3DDxgiInterfaceAccess      :: winrt.GUID{0xa9b3d012, 0x3df2, 0x4ee3, {0xb8, 0xd1, 0x86, 0x95, 0xf4, 0x57, 0xd3, 0xc1}}
@(private = "file") IID_IClosable                         :: winrt.GUID{0x30d5a829, 0x7fa4, 0x4026, {0x83, 0xbb, 0xd7, 0x5b, 0xae, 0x4e, 0xa9, 0x9e}}
@(private = "file") IID_ID3D11Multithread                 :: winrt.GUID{0x9b7e4e00, 0x342c, 0x4106, {0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0}}

@(private = "file")
SizeInt32 :: struct { width, height: i32 }

// A classic COM interface (IUnknown, not IInspectable).
@(private = "file")
IGraphicsCaptureItemInterop_Vtbl :: struct {
	QueryInterface:   rawptr,
	AddRef:           rawptr,
	Release:          rawptr,
	CreateForWindow:  proc "system" (this: rawptr, window: win.HWND, riid: ^winrt.GUID, item: ^rawptr) -> win.HRESULT,
	CreateForMonitor: proc "system" (this: rawptr, monitor: win.HMONITOR, riid: ^winrt.GUID, item: ^rawptr) -> win.HRESULT,
}

@(private = "file")
IGraphicsCaptureItem_Vtbl :: struct {
	using base:      winrt.IInspectable_Vtbl,
	get_DisplayName: rawptr,
	get_Size:        proc "system" (this: rawptr, size: ^SizeInt32) -> win.HRESULT,
	add_Closed:      rawptr,
	remove_Closed:   rawptr,
}

@(private = "file")
IDirect3D11CaptureFramePoolStatics2_Vtbl :: struct {
	using base:         winrt.IInspectable_Vtbl,
	CreateFreeThreaded: proc "system" (this: rawptr, device: rawptr, pixel_format: i32, buffers: i32, size: SizeInt32, pool: ^rawptr) -> win.HRESULT,
}

@(private = "file")
IDirect3D11CaptureFramePool_Vtbl :: struct {
	using base:           winrt.IInspectable_Vtbl,
	Recreate:             rawptr,
	TryGetNextFrame:      proc "system" (this: rawptr, frame: ^rawptr) -> win.HRESULT,
	add_FrameArrived:     proc "system" (this: rawptr, handler: rawptr, token: ^i64) -> win.HRESULT,
	remove_FrameArrived:  proc "system" (this: rawptr, token: i64) -> win.HRESULT,
	CreateCaptureSession: proc "system" (this: rawptr, item: rawptr, session: ^rawptr) -> win.HRESULT,
	get_DispatcherQueue:  rawptr,
}

@(private = "file")
IGraphicsCaptureSession_Vtbl :: struct {
	using base:   winrt.IInspectable_Vtbl,
	StartCapture: proc "system" (this: rawptr) -> win.HRESULT,
}

@(private = "file")
IGraphicsCaptureSession2_Vtbl :: struct {
	using base:                 winrt.IInspectable_Vtbl,
	get_IsCursorCaptureEnabled: rawptr,
	put_IsCursorCaptureEnabled: proc "system" (this: rawptr, value: b8) -> win.HRESULT,
}

@(private = "file")
IDirect3D11CaptureFrame_Vtbl :: struct {
	using base:             winrt.IInspectable_Vtbl,
	get_Surface:            proc "system" (this: rawptr, surface: ^rawptr) -> win.HRESULT,
	get_SystemRelativeTime: proc "system" (this: rawptr, time: ^i64) -> win.HRESULT,   // a TimeSpan: 100 ns units, QueryPerformanceCounter's clock
	get_ContentSize:        proc "system" (this: rawptr, size: ^SizeInt32) -> win.HRESULT,
}

// A classic COM interface (IUnknown, not IInspectable).
@(private = "file")
IDirect3DDxgiInterfaceAccess_Vtbl :: struct {
	QueryInterface: rawptr,
	AddRef:         rawptr,
	Release:        rawptr,
	GetInterface:   proc "system" (this: rawptr, iid: ^winrt.GUID, object: ^rawptr) -> win.HRESULT,
}

// d3d11_4.h; not in vendor:directx/d3d11. A classic COM interface.
@(private = "file")
ID3D11Multithread_Vtbl :: struct {
	QueryInterface:          rawptr,
	AddRef:                  rawptr,
	Release:                 rawptr,
	Enter:                   rawptr,
	Leave:                   rawptr,
	SetMultithreadProtected: proc "system" (this: rawptr, protect: win.BOOL) -> win.BOOL,
	GetMultithreadProtected: rawptr,
}

@(private = "file")
IClosable_Vtbl :: struct {
	using base: winrt.IInspectable_Vtbl,
	Close:      proc "system" (this: rawptr) -> win.HRESULT,
}

// What a window capture keeps for the session: a D3D11 device on the default adapter (made at the first window
// capture), its WinRT face, the staging texture, the event the frame pool's handler sets.
@(private)
Window_Capture :: struct {
	device:          ^d3d11.IDevice,
	device_context:  ^d3d11.IDeviceContext,
	graphics_device: rawptr,               // IDirect3DDevice
	staging:         ^d3d11.ITexture2D,
	frame_event:     win.HANDLE,           // auto-reset; lives as long as the session, so a late FrameArrived sets a live handle
	unsupported:     bool,                 // no Windows.Graphics.Capture here: not asked again
}

@(private)
window_capture_close :: proc(c: ^Window_Capture) {
	if c.staging != nil { c.staging->Release() }
	winrt.release(c.graphics_device)
	if c.device_context != nil { c.device_context->Release() }
	if c.device != nil { c.device->Release() }
	if c.frame_event != nil { win.CloseHandle(c.frame_event) }
	c^ = {}
}

@(private = "file")
window_capture_open :: proc(c: ^Window_Capture) -> bool {
	if d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, nil, 0, d3d11.SDK_VERSION, &c.device, nil, &c.device_context) < 0 || c.device == nil {
		return false
	}
	// The free-threaded pool copies into its buffers on its own thread while this one copies out of them: the immediate
	// context is then shared, which D3D11 allows only once protected.
	if multithread := winrt.query(c.device, IID_ID3D11Multithread); multithread != nil {
		winrt.vtable(multithread, ID3D11Multithread_Vtbl).SetMultithreadProtected(multithread, true)
		winrt.release(multithread)
	}
	dxgi_device: ^dxgi.IDevice
	if c.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device)) < 0 || dxgi_device == nil { return false }
	defer dxgi_device->Release()
	if CreateDirect3D11DeviceFromDXGIDevice(dxgi_device, &c.graphics_device) < 0 || c.graphics_device == nil { return false }
	c.frame_event = win.CreateEventW(nil, false, false, nil)
	return c.frame_event != nil
}

// One frame of the window. .Unsupported: no Windows.Graphics.Capture on this system (the caller then crops the
// desktop). The frame's scale and origin are the caller's to set. `cursor`: the pointer in the picture (set_cursor).
@(private)
window_capture_frame :: proc(c: ^Window_Capture, window: win.HWND, allocator: runtime.Allocator, cursor: bool) -> (f: Frame, err: Error) {
	if c.unsupported { return {}, .Unsupported }
	if c.device == nil && !window_capture_open(c) {
		window_capture_close(c)
		c.unsupported = true
		return {}, .Unsupported
	}

	interop, hr := winrt.factory(CLASS_ITEM, IID_IGraphicsCaptureItemInterop)
	if !winrt.ok(hr) || interop == nil {
		c.unsupported = true
		return {}, .Unsupported
	}
	defer winrt.release(interop)
	item: rawptr
	item_iid := IID_IGraphicsCaptureItem
	if !winrt.ok(winrt.vtable(interop, IGraphicsCaptureItemInterop_Vtbl).CreateForWindow(interop, window, &item_iid, &item)) || item == nil {
		return {}, win.IsWindow(window) ? Error.Failed : Error.Gone
	}
	defer winrt.release(item)
	size: SizeInt32
	if !winrt.ok(winrt.vtable(item, IGraphicsCaptureItem_Vtbl).get_Size(item, &size)) || size.width <= 0 || size.height <= 0 {
		return {}, .Failed
	}

	statics: rawptr
	statics, hr = winrt.factory(CLASS_FRAME_POOL, IID_IDirect3D11CaptureFramePoolStatics2)
	if !winrt.ok(hr) || statics == nil {
		c.unsupported = true
		return {}, .Unsupported
	}
	defer winrt.release(statics)
	pool: rawptr
	if !winrt.ok(winrt.vtable(statics, IDirect3D11CaptureFramePoolStatics2_Vtbl).CreateFreeThreaded(statics, c.graphics_device, PIXEL_FORMAT_B8G8R8A8, 1, size, &pool)) || pool == nil {
		return {}, .Failed
	}
	defer {
		closable_close(pool)
		winrt.release(pool)
	}
	pool_vtbl := winrt.vtable(pool, IDirect3D11CaptureFramePool_Vtbl)

	// A free-threaded pool raises FrameArrived on a thread of its own: the handler only wakes this one.
	win.ResetEvent(c.frame_event)
	handler_iid := winrt.typed_event_handler_iid(winrt.sig_class(CLASS_FRAME_POOL, IID_IDirect3D11CaptureFramePool), winrt.SIG_INSPECTABLE)
	handler := winrt.event_handler_make(handler_iid, proc(user: rawptr, sender: rawptr, args: rawptr) {
		win.SetEvent(win.HANDLE(user))
	}, rawptr(c.frame_event))
	token: i64
	hr = pool_vtbl.add_FrameArrived(pool, handler, &token)
	winrt.release(handler)   // the pool holds its own reference until remove_FrameArrived
	if !winrt.ok(hr) { return {}, .Failed }
	defer pool_vtbl.remove_FrameArrived(pool, token)

	session: rawptr
	if !winrt.ok(pool_vtbl.CreateCaptureSession(pool, item, &session)) || session == nil { return {}, .Failed }
	defer {
		closable_close(session)
		winrt.release(session)
	}
	// The pointer is in a window's picture only when the session asked it (Windows 10 2004 and later; before, it is
	// always drawn in).
	if session2 := winrt.query(session, IID_IGraphicsCaptureSession2); session2 != nil {
		winrt.vtable(session2, IGraphicsCaptureSession2_Vtbl).put_IsCursorCaptureEnabled(session2, b8(cursor))
		winrt.release(session2)
	}
	if !winrt.ok(winrt.vtable(session, IGraphicsCaptureSession_Vtbl).StartCapture(session)) { return {}, .Failed }
	if win.WaitForSingleObject(c.frame_event, FRAME_MS) != win.WAIT_OBJECT_0 { return {}, .Failed }

	frame: rawptr
	if !winrt.ok(pool_vtbl.TryGetNextFrame(pool, &frame)) || frame == nil { return {}, .Failed }
	defer {
		closable_close(frame)
		winrt.release(frame)
	}
	frame_vtbl := winrt.vtable(frame, IDirect3D11CaptureFrame_Vtbl)
	// The pool's buffers have the size the window had when it was made; the content, the size it has now.
	content: SizeInt32
	if !winrt.ok(frame_vtbl.get_ContentSize(frame, &content)) { content = size }
	surface: rawptr
	if !winrt.ok(frame_vtbl.get_Surface(frame, &surface)) || surface == nil { return {}, .Failed }
	defer winrt.release(surface)
	access := winrt.query(surface, IID_IDirect3DDxgiInterfaceAccess)
	if access == nil { return {}, .Failed }
	defer winrt.release(access)
	texture_iid := transmute(winrt.GUID)d3d11.ITexture2D_UUID^
	texture: ^d3d11.ITexture2D
	if !winrt.ok(winrt.vtable(access, IDirect3DDxgiInterfaceAccess_Vtbl).GetInterface(access, &texture_iid, (^rawptr)(&texture))) || texture == nil {
		return {}, .Failed
	}
	defer texture->Release()

	if !staging_copy(c.device, c.device_context, &c.staging, texture) { return {}, .Failed }
	ok: bool
	f, ok = staging_read(c.device_context, c.staging, .Identity, allocator, {content.width, content.height})
	if !ok { return {}, .Failed }
	return f, .None
}

// IClosable.Close: a pool, a session or a frame lets its buffers go now rather than when its last reference does.
@(private = "file")
closable_close :: proc(object: rawptr) {
	if closable := winrt.query(object, IID_IClosable); closable != nil {
		winrt.vtable(closable, IClosable_Vtbl).Close(closable)
		winrt.release(closable)
	}
}

////////////////////////////////
// streams

// A stream through Windows.Graphics.Capture: the item (a window or a monitor), a free-threaded frame pool of two
// buffers and its session, kept open while the stream is. The pool gives a frame each time the content changed; each
// step takes the newest one and drops the older ones. Every frame has the size the item had at the start (a window
// that grows is cut, one that shrinks is padded with black): an encoder's frames all have one size.
@(private)
Wgc_Stream :: struct {
	item:       rawptr,             // GraphicsCaptureItem
	pool:       rawptr,             // Direct3D11CaptureFramePool
	session:    rawptr,             // GraphicsCaptureSession
	token:      i64,
	registered: bool,               // the FrameArrived handler is added (token is its)
	event:      win.HANDLE,         // auto-reset, set by the pool's thread at each frame
	window:     win.HWND,           // nil: a monitor
	size:       SizeInt32,          // the pool's, and every frame's
	staging:    ^d3d11.ITexture2D,
}

@(private = "file") STREAM_BUFFERS :: 2

// The stream opened on `window`, or else on `monitor`, with the device of the session's window captures.
// .Unsupported: no Windows.Graphics.Capture here (the caller takes Desktop Duplication for a monitor).
@(private)
wgc_stream_open :: proc(c: ^Window_Capture, ws: ^Wgc_Stream, window: win.HWND, monitor: win.HMONITOR, cursor: bool) -> (err: Error) {
	if c.unsupported { return .Unsupported }
	if c.device == nil && !window_capture_open(c) {
		window_capture_close(c)
		c.unsupported = true
		return .Unsupported
	}
	ws^ = {window = window}
	defer if err != .None { wgc_stream_close(ws) }

	interop, hr := winrt.factory(CLASS_ITEM, IID_IGraphicsCaptureItemInterop)
	if !winrt.ok(hr) || interop == nil { return .Unsupported }
	defer winrt.release(interop)
	item_iid := IID_IGraphicsCaptureItem
	interop_vtbl := winrt.vtable(interop, IGraphicsCaptureItemInterop_Vtbl)
	if window != nil {
		hr = interop_vtbl.CreateForWindow(interop, window, &item_iid, &ws.item)
	} else {
		hr = interop_vtbl.CreateForMonitor(interop, monitor, &item_iid, &ws.item)
	}
	if !winrt.ok(hr) || ws.item == nil {
		if window != nil && !win.IsWindow(window) { return .Gone }
		return .Failed
	}
	if !winrt.ok(winrt.vtable(ws.item, IGraphicsCaptureItem_Vtbl).get_Size(ws.item, &ws.size)) || ws.size.width <= 0 || ws.size.height <= 0 {
		return .Failed
	}

	statics: rawptr
	statics, hr = winrt.factory(CLASS_FRAME_POOL, IID_IDirect3D11CaptureFramePoolStatics2)
	if !winrt.ok(hr) || statics == nil { return .Unsupported }
	defer winrt.release(statics)
	if !winrt.ok(winrt.vtable(statics, IDirect3D11CaptureFramePoolStatics2_Vtbl).CreateFreeThreaded(statics, c.graphics_device, PIXEL_FORMAT_B8G8R8A8, STREAM_BUFFERS, ws.size, &ws.pool)) || ws.pool == nil {
		return .Failed
	}
	pool_vtbl := winrt.vtable(ws.pool, IDirect3D11CaptureFramePool_Vtbl)

	ws.event = win.CreateEventW(nil, false, false, nil)
	if ws.event == nil { return .Failed }
	handler_iid := winrt.typed_event_handler_iid(winrt.sig_class(CLASS_FRAME_POOL, IID_IDirect3D11CaptureFramePool), winrt.SIG_INSPECTABLE)
	handler := winrt.event_handler_make(handler_iid, proc(user: rawptr, sender: rawptr, args: rawptr) {
		win.SetEvent(win.HANDLE(user))
	}, rawptr(ws.event))
	hr = pool_vtbl.add_FrameArrived(ws.pool, handler, &ws.token)
	winrt.release(handler)   // the pool holds its own reference until remove_FrameArrived
	if !winrt.ok(hr) { return .Failed }
	ws.registered = true

	if !winrt.ok(pool_vtbl.CreateCaptureSession(ws.pool, ws.item, &ws.session)) || ws.session == nil { return .Failed }
	// (Windows 10 2004 and later; before, the pointer is always drawn in)
	if session2 := winrt.query(ws.session, IID_IGraphicsCaptureSession2); session2 != nil {
		winrt.vtable(session2, IGraphicsCaptureSession2_Vtbl).put_IsCursorCaptureEnabled(session2, b8(cursor))
		winrt.release(session2)
	}
	if !winrt.ok(winrt.vtable(ws.session, IGraphicsCaptureSession_Vtbl).StartCapture(ws.session)) { return .Failed }
	return .None
}

@(private)
wgc_stream_close :: proc(ws: ^Wgc_Stream) {
	if ws.registered { winrt.vtable(ws.pool, IDirect3D11CaptureFramePool_Vtbl).remove_FrameArrived(ws.pool, ws.token) }
	if ws.session != nil {
		closable_close(ws.session)
		winrt.release(ws.session)
	}
	if ws.pool != nil {
		closable_close(ws.pool)
		winrt.release(ws.pool)
	}
	winrt.release(ws.item)
	if ws.staging != nil { ws.staging->Release() }
	// (after the handler is removed: a late FrameArrived never sets a closed handle)
	if ws.event != nil { win.CloseHandle(ws.event) }
	ws^ = {}
}

// The newest frame of the pool once the pace allows, placed at `origin` and `scale`. ok false: none came within
// `timeout`.
@(private)
wgc_stream_next :: proc(c: ^Window_Capture, ws: ^Wgc_Stream, stream: ^Stream, origin: [2]i32, scale: f32, timeout: time.Duration) -> (f: Stream_Frame, ok: bool, err: Error) {
	deadline := monotonic_ns() + i64(timeout)
	pool_vtbl := winrt.vtable(ws.pool, IDirect3D11CaptureFramePool_Vtbl)
	for {
		now := monotonic_ns()
		due := stream_pacer_due(&stream.pacer)
		if now < due {
			if now >= deadline { return {}, false, .None }
			win.Sleep(u32(max((min(due, deadline) - now) / 1_000_000, 1)))
			continue
		}
		// the newest frame; the ones before it were already late
		frame: rawptr
		for {
			next: rawptr
			if !winrt.ok(pool_vtbl.TryGetNextFrame(ws.pool, &next)) || next == nil { break }
			if frame != nil {
				closable_close(frame)
				winrt.release(frame)
			}
			frame = next
		}
		if frame == nil {
			if ws.window != nil && !win.IsWindow(ws.window) { return {}, false, .Gone }
			if now >= deadline { return {}, false, .None }
			win.WaitForSingleObject(ws.event, u32(max((deadline - now) / 1_000_000, 1)))
			continue
		}
		f, ok = wgc_stream_read(c, ws, stream, frame, origin, scale)
		closable_close(frame)
		winrt.release(frame)
		if !ok { return {}, false, .Failed }
		return f, true, .None
	}
}

@(private = "file")
wgc_stream_read :: proc(c: ^Window_Capture, ws: ^Wgc_Stream, stream: ^Stream, frame: rawptr, origin: [2]i32, scale: f32) -> (f: Stream_Frame, ok: bool) {
	frame_vtbl := winrt.vtable(frame, IDirect3D11CaptureFrame_Vtbl)
	at := monotonic_ns()
	relative: i64
	if winrt.ok(frame_vtbl.get_SystemRelativeTime(frame, &relative)) && relative > 0 { at = relative * 100 }
	content := ws.size
	if !winrt.ok(frame_vtbl.get_ContentSize(frame, &content)) { content = ws.size }
	surface: rawptr
	if !winrt.ok(frame_vtbl.get_Surface(frame, &surface)) || surface == nil { return }
	defer winrt.release(surface)
	access := winrt.query(surface, IID_IDirect3DDxgiInterfaceAccess)
	if access == nil { return }
	defer winrt.release(access)
	texture_iid := transmute(winrt.GUID)d3d11.ITexture2D_UUID^
	texture: ^d3d11.ITexture2D
	if !winrt.ok(winrt.vtable(access, IDirect3DDxgiInterfaceAccess_Vtbl).GetInterface(access, &texture_iid, (^rawptr)(&texture))) || texture == nil {
		return
	}
	defer texture->Release()
	if !staging_copy(c.device, c.device_context, &ws.staging, texture) { return }
	size := [2]i32{ws.size.width, ws.size.height}
	dst := stream_frame_target(stream, size.x, size.y)
	frame_out := staging_read_into(c.device_context, ws.staging, .Identity, dst, size, {content.width, content.height}) or_return
	frame_out.origin = origin
	frame_out.scale = scale
	return stream_frame_finish(stream, frame_out, at)
}
