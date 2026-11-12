#+build windows
package capture

// The Windows backend: the outputs from EnumDisplayMonitors, their pictures from DXGI Desktop Duplication (GDI where
// duplication is unavailable), the windows from EnumWindows, a window's picture from Windows.Graphics.Capture
// (capture_wgc_windows.odin).
//
// A session belongs to the thread that opened it: open joins that thread to COM's multithreaded apartment and makes it
// per-monitor DPI aware (SetThreadDpiAwarenessContext, restored by close), and every later call must come from it.
//
// Coordinates: to a per-monitor aware thread the virtual desktop is in physical pixels (monitor rects, window rects,
// the screen DC). layout_logical (layout.odin) turns the monitors' physical rects into logical ones, the same way for
// every call of the session: one scale everywhere, the exact division; mixed scales, origins divided by the smallest
// scale and sizes by the output's own. A window's rect goes through the output that holds most of it
// (physical_to_logical); a frame of an output starts at that output's logical origin, at its scale.

import "base:runtime"
import "core:math"
import "core:strings"
import win "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

foreign import kernel32_capture "system:Kernel32.lib"
foreign import user32_capture "system:User32.lib"
foreign import gdi32_capture "system:Gdi32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_capture {
	QueryFullProcessImageNameW :: proc(process: win.HANDLE, flags: u32, name: [^]u16, size: ^u32) -> win.BOOL ---
}

@(default_calling_convention = "system", private = "file")
foreign user32_capture {
	// The title as the system keeps it, with no WM_GETTEXT: GetWindowTextW sends one to a window of this process, which
	// blocks while that window's thread is busy, or for ever when it waits for this worker.
	InternalGetWindowText :: proc(window: win.HWND, text: [^]u16, count: i32) -> i32 ---
}

@(default_calling_convention = "system", private = "file")
foreign gdi32_capture {
	GdiFlush :: proc() -> win.BOOL ---
}

@(private = "file") ACQUIRE_MS :: 100          // a new frame comes within a refresh or two; past this the screen did not change
@(private = "file") ACQUIRE_ATTEMPTS :: 3      // the first frame can be empty, and a lost duplication is made again once
@(private = "file") MONITORS_MAX :: 64
@(private = "file") TITLE_MAX :: 512           // UTF-16 units; a longer title is cut
@(private = "file") CLASS_MAX :: 256           // the longest window class name
@(private = "file") PATH_MAX :: 1024           // UTF-16 units of an executable's path

@(private)
Impl :: struct {
	com_joined:     bool,                        // CoInitializeEx succeeded: close leaves the apartment
	dpi_previous:   win.DPI_AWARENESS_CONTEXT,   // the thread's awareness before open
	factory:        ^dxgi.IFactory1,             // nil: no DXGI, GDI only
	monitors:       [dynamic]Monitor,            // as last read (monitors_read)
	window_capture: Window_Capture,
}

@(private = "file")
Monitor :: struct {
	handle:      win.HMONITOR,
	device_name: [32]u16,   // MONITORINFOEXW.szDevice: "\\.\DISPLAY1"
	physical:    Rect,
	logical:     Rect,
	scale:       f32,
	duplication: Duplication,
}

// One output's Desktop Duplication, kept from capture to capture: making it costs tens of milliseconds, and an
// unchanged screen gives no new frame, so the last one stays in `staging`.
@(private = "file")
Duplication :: struct {
	device:         ^d3d11.IDevice,          // on the adapter that drives the output: duplication works only there
	device_context: ^d3d11.IDeviceContext,
	duplication:    ^dxgi.IOutputDuplication,
	rotation:       Win32_Rotation,
	staging:        ^d3d11.ITexture2D,       // the last frame, readable by the CPU
	filled:         bool,                    // staging holds a frame
	presented:      bool,                    // a frame with a picture came (LastPresentTime != 0)
	unavailable:    bool,                    // duplication failed for this output: GDI until the output changes
}

@(private)
platform_open :: proc(s: ^Session) -> Error {
	impl := new(Impl, s.allocator)
	impl.monitors.allocator = s.allocator
	s.impl = impl
	s.backend = .Windows
	// Every rect here is physical only to a per-monitor aware thread: the capture sets it on its own thread rather than
	// depend on what the program chose for the process.
	impl.dpi_previous = win.SetThreadDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	// RPC_E_CHANGED_MODE (a single-threaded apartment already) is not joined, but DXGI and the free-threaded frame pool
	// work there too.
	impl.com_joined = win.CoInitializeEx(nil, .MULTITHREADED) >= 0
	factory: rawptr
	if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, &factory) >= 0 { impl.factory = (^dxgi.IFactory1)(factory) }
	monitors_read(impl)
	if len(impl.monitors) == 0 {
		platform_close(s)
		return .Unsupported
	}
	return .None
}

@(private)
platform_close :: proc(s: ^Session) {
	impl := (^Impl)(s.impl)
	if impl == nil { return }
	for &m in impl.monitors { duplication_close(&m.duplication) }
	delete(impl.monitors)
	window_capture_close(&impl.window_capture)
	if impl.factory != nil { impl.factory->Release() }
	if impl.com_joined { win.CoUninitialize() }
	if impl.dpi_previous != nil { win.SetThreadDpiAwarenessContext(impl.dpi_previous) }
	free(impl, s.allocator)
	s.impl = nil
}

@(private)
platform_outputs :: proc(s: ^Session) {
	impl := (^Impl)(s.impl)
	monitors_read(impl)
	for &m in impl.monitors {
		name, _ := win.utf16_to_utf8(until_nul(m.device_name[:]), s.allocator)
		append(&s.outputs, Output{id = monitor_id(m.handle), name = name, rect = m.logical, scale = m.scale})
	}
}

@(private)
platform_windows_have_rects :: proc(s: ^Session) -> bool { return true }

@(private)
platform_windows :: proc(s: ^Session) {
	impl := (^Impl)(s.impl)
	monitors_read(impl)
	physical := monitors_physical(impl)
	// EnumWindows goes through the top-level windows in z-order, the frontmost first: the order windows() promises.
	handles := make([dynamic]win.HWND, 0, 64, context.temp_allocator)
	win.EnumWindows(proc "system" (window: win.HWND, data: win.LPARAM) -> win.BOOL {
		context = runtime.default_context()
		append((^[dynamic]win.HWND)(uintptr(data)), window)   // (the array's own allocator)
		return true
	}, win.LPARAM(uintptr(&handles)))
	for handle in handles {
		facts := window_facts(handle)
		if !win32_window_listed(facts) { continue }
		w := Window{id = u64(uintptr(handle)), minimized = facts.minimized}
		// A minimized window's frame is parked off screen (-32000): no rect to frame it by.
		if !facts.minimized {
			if i := output_of(facts.frame, physical); i >= 0 {
				m := impl.monitors[i]
				w.rect = physical_to_logical(facts.frame, m.physical, m.logical, m.scale)
				w.has_rect = true
			}
		}
		w.title = strings.clone(facts.title, s.allocator)
		w.app_id = executable_name(handle, s.allocator)
		append(&s.windows, w)
	}
}

@(private)
platform_output :: proc(s: ^Session, id: u64, allocator: runtime.Allocator) -> (Frame, Error) {
	impl := (^Impl)(s.impl)
	m := monitor_find(impl, id)
	if m == nil {
		monitors_read(impl)
		m = monitor_find(impl, id)
	}
	if m == nil { return {}, .Gone }
	return output_frame(impl, m, allocator)
}

@(private)
platform_window :: proc(s: ^Session, id: u64, allocator: runtime.Allocator) -> (Frame, Error) {
	impl := (^Impl)(s.impl)
	handle := win.HWND(uintptr(id))
	if !win.IsWindow(handle) { return {}, .Gone }
	// A minimized window draws nothing: no capture of it has a picture.
	if win.IsIconic(handle) { return {}, .Failed }
	monitors_read(impl)
	frame := window_frame(handle)
	i := output_of(frame, monitors_physical(impl))
	if i < 0 { return {}, .Failed }
	m := impl.monitors[i]
	logical := physical_to_logical(frame, m.physical, m.logical, m.scale)

	f, err := window_capture_frame(&impl.window_capture, handle, allocator)
	if err == .None {
		f.scale = m.scale
		f.origin = {logical.x, logical.y}
		return f, .None
	}
	if err != .Unsupported { return {}, err }
	// No Windows.Graphics.Capture here (before Windows 10 1903, or a session that refuses it): the desktop cut to the
	// window's rect, where what is over the window shows.
	d, desktop_err := platform_desktop(s, allocator)
	if desktop_err != .None { return {}, desktop_err }
	defer frame_free(&d)
	out, ok := crop(d, logical, allocator)
	if !ok { return {}, .Failed }
	return out, .None
}

@(private)
platform_desktop :: proc(s: ^Session, allocator: runtime.Allocator) -> (Frame, Error) {
	impl := (^Impl)(s.impl)
	monitors_read(impl)
	if len(impl.monitors) == 0 { return {}, .Failed }
	logical := make([]Rect, len(impl.monitors), context.temp_allocator)
	scale := f32(0)
	for m, i in impl.monitors {
		logical[i] = m.logical
		scale = max(scale, m.scale)
	}
	bounds := bounding_rect(logical)
	f := Frame{
		width     = i32(math.ceil(f64(bounds.w) * f64(scale))),
		height    = i32(math.ceil(f64(bounds.h) * f64(scale))),
		scale     = scale,
		origin    = {bounds.x, bounds.y},
		allocator = allocator,
	}
	f.stride = f.width * 4
	f.pixels = make([]u8, int(f.stride * f.height), allocator)   // zero: transparent where no output is
	drawn := 0
	first_err := Error.None
	for &m in impl.monitors {
		part, err := output_frame(impl, &m, allocator)
		if err != .None {
			if first_err == .None { first_err = err }
			continue
		}
		at := Rect{
			x = i32(math.round(f64(m.logical.x - bounds.x) * f64(scale))),
			y = i32(math.round(f64(m.logical.y - bounds.y) * f64(scale))),
			w = part.width,
			h = part.height,
		}
		if m.scale != scale {
			at.w = i32(math.round(f64(m.logical.w) * f64(scale)))
			at.h = i32(math.round(f64(m.logical.h) * f64(scale)))
		}
		frame_draw(&f, part, at)
		frame_free(&part)
		drawn += 1
	}
	// One output that failed leaves its place transparent; none drawn is the error of the first.
	if drawn == 0 {
		frame_free(&f)
		return {}, first_err
	}
	return f, .None
}

////////////////////////////////
// Monitors

@(private = "file")
Monitor_Handles :: struct {
	handles: [MONITORS_MAX]win.HMONITOR,
	count:   int,
}

// Reads the monitors again. A monitor still there with the same rect keeps its duplication; the others' are released.
@(private = "file")
monitors_read :: proc(impl: ^Impl) {
	list: Monitor_Handles
	win.EnumDisplayMonitors(nil, nil, proc "system" (monitor: win.HMONITOR, _: win.HDC, _: win.LPRECT, data: win.LPARAM) -> win.BOOL {
		l := (^Monitor_Handles)(uintptr(data))
		if l.count < len(l.handles) {
			l.handles[l.count] = monitor
			l.count += 1
		}
		return true
	}, win.LPARAM(uintptr(&list)))

	previous := impl.monitors
	next := make([dynamic]Monitor, 0, list.count, previous.allocator)
	for handle in list.handles[:list.count] {
		info: win.MONITORINFOEXW
		info.cbSize = size_of(win.MONITORINFOEXW)
		if !win.GetMonitorInfoW(handle, (^win.MONITORINFO)(&info)) { continue }
		m := Monitor{handle = handle, device_name = info.szDevice, physical = rect_of(info.rcMonitor), scale = monitor_scale(handle)}
		for &p in previous {
			if p.handle == handle && p.physical == m.physical {
				m.duplication = p.duplication
				p.duplication = {}
			}
		}
		append(&next, m)
	}
	for &p in previous { duplication_close(&p.duplication) }
	delete(previous)
	impl.monitors = next

	physical := monitors_physical(impl)
	scales := make([]f32, len(next), context.temp_allocator)
	logical := make([]Rect, len(next), context.temp_allocator)
	for m, i in next { scales[i] = m.scale }
	layout_logical(physical, scales, logical)
	for &m, i in impl.monitors { m.logical = logical[i] }
}

// The effective DPI (what the user's scale setting gives) over 96; 1 when the system does not say.
@(private = "file")
monitor_scale :: proc(handle: win.HMONITOR) -> f32 {
	x, y: u32
	if win.GetDpiForMonitor(handle, .MDT_EFFECTIVE_DPI, &x, &y) < 0 || x == 0 { return 1 }
	return f32(x) / 96
}

@(private = "file")
monitors_physical :: proc(impl: ^Impl) -> []Rect {
	physical := make([]Rect, len(impl.monitors), context.temp_allocator)
	for m, i in impl.monitors { physical[i] = m.physical }
	return physical
}

// An output's id: its HMONITOR, which stays the same while the monitor is attached and the display layout does not change.
@(private = "file")
monitor_id :: proc(handle: win.HMONITOR) -> u64 { return u64(uintptr(handle)) }

@(private = "file")
monitor_find :: proc(impl: ^Impl, id: u64) -> ^Monitor {
	for &m in impl.monitors { if monitor_id(m.handle) == id { return &m } }
	return nil
}

////////////////////////////////
// An output's picture

// Desktop Duplication, else GDI.
@(private = "file")
output_frame :: proc(impl: ^Impl, m: ^Monitor, allocator: runtime.Allocator) -> (Frame, Error) {
	f, ok := duplication_frame(impl, m, allocator)
	if !ok { f, ok = gdi_frame(m.physical, allocator) }
	if !ok { return {}, .Failed }
	f.scale = m.scale
	f.origin = {m.logical.x, m.logical.y}
	return f, .None
}

// The output's picture through its duplication (made when there is none). false: use GDI.
@(private = "file")
duplication_frame :: proc(impl: ^Impl, m: ^Monitor, allocator: runtime.Allocator) -> (f: Frame, ok: bool) {
	d := &m.duplication
	if d.unavailable { return }
	acquire: for attempt in 0 ..< ACQUIRE_ATTEMPTS {
		if d.duplication == nil && !duplication_open(impl, m) {
			// Remote sessions, some drivers, the secure desktop: GDI still sees the screen.
			d.unavailable = true
			return
		}
		info: dxgi.OUTDUPL_FRAME_INFO
		resource: ^dxgi.IResource
		hr := d.duplication->AcquireNextFrame(ACQUIRE_MS, &info, &resource)
		if hr == dxgi.ERROR_ACCESS_LOST {
			// A mode change, the secure desktop, a full-screen exclusive program: this duplication is dead, a new one works.
			duplication_close(d)
			continue acquire
		}
		if hr == dxgi.ERROR_WAIT_TIMEOUT {
			// Nothing changed since the last frame: staging is the screen.
			if d.filled { break acquire }
			continue acquire
		}
		if hr < 0 || resource == nil {
			duplication_close(d)
			d.unavailable = true
			return
		}
		copied := duplication_copy(d, resource)
		resource->Release()
		d.duplication->ReleaseFrame()
		if !copied {
			duplication_close(d)
			d.unavailable = true
			return
		}
		if info.LastPresentTime != 0 { d.presented = true }
		// The first frame of a new duplication can carry only the pointer, over a surface not drawn yet: once more.
		if !d.presented && attempt == 0 { continue acquire }
		break acquire
	}
	if !d.filled { return }
	return staging_read(d.device_context, d.staging, d.rotation, allocator)
}

@(private = "file")
duplication_copy :: proc(d: ^Duplication, resource: ^dxgi.IResource) -> bool {
	texture: ^d3d11.ITexture2D
	if resource->QueryInterface(d3d11.ITexture2D_UUID, (^rawptr)(&texture)) < 0 || texture == nil { return false }
	defer texture->Release()
	if !staging_copy(d.device, d.device_context, &d.staging, texture) { return false }
	d.filled = true
	return true
}

// Finds the DXGI output of the monitor and duplicates it on a device of its adapter.
@(private = "file")
duplication_open :: proc(impl: ^Impl, m: ^Monitor) -> bool {
	if impl.factory == nil { return false }
	for a: u32 = 0; ; a += 1 {
		adapter: ^dxgi.IAdapter1
		if impl.factory->EnumAdapters1(a, &adapter) < 0 { return false }   // DXGI_ERROR_NOT_FOUND: no more adapters
		defer adapter->Release()
		for o: u32 = 0; ; o += 1 {
			output: ^dxgi.IOutput
			if adapter->EnumOutputs(o, &output) < 0 { break }
			defer output->Release()
			desc: dxgi.OUTPUT_DESC
			if output->GetDesc(&desc) < 0 || desc.Monitor != m.handle { continue }
			return duplication_make(&m.duplication, adapter, output)
		}
	}
}

@(private = "file")
duplication_make :: proc(d: ^Duplication, adapter: ^dxgi.IAdapter1, output: ^dxgi.IOutput) -> bool {
	device: ^d3d11.IDevice
	device_context: ^d3d11.IDeviceContext
	// A given adapter needs the UNKNOWN driver type (HARDWARE is for nil).
	if d3d11.CreateDevice((^dxgi.IAdapter)(adapter), .UNKNOWN, nil, {.BGRA_SUPPORT}, nil, 0, d3d11.SDK_VERSION, &device, nil, &device_context) < 0 || device == nil {
		return false
	}
	duplication: ^dxgi.IOutputDuplication
	// DuplicateOutput1 first: it is the one meant for per-monitor aware callers (Windows 10 1703 and later), and it says
	// which format to give, BGRA, which keeps an HDR output readable by the same copy.
	output5: ^dxgi.IOutput5
	if output->QueryInterface(dxgi.IOutput5_UUID, (^rawptr)(&output5)) >= 0 && output5 != nil {
		formats := [1]dxgi.FORMAT{.B8G8R8A8_UNORM}
		if output5->DuplicateOutput1((^dxgi.IUnknown)(device), {}, 1, raw_data(formats[:]), &duplication) < 0 { duplication = nil }
		output5->Release()
	}
	if duplication == nil {
		output1: ^dxgi.IOutput1
		if output->QueryInterface(dxgi.IOutput1_UUID, (^rawptr)(&output1)) >= 0 && output1 != nil {
			if output1->DuplicateOutput((^dxgi.IUnknown)(device), &duplication) < 0 { duplication = nil }
			output1->Release()
		}
	}
	if duplication == nil {
		device_context->Release()
		device->Release()
		return false
	}
	desc: dxgi.OUTDUPL_DESC
	duplication->GetDesc(&desc)
	unavailable := d.unavailable
	d^ = Duplication{
		device         = device,
		device_context = device_context,
		duplication    = duplication,
		rotation       = Win32_Rotation(i32(desc.Rotation)),
		unavailable    = unavailable,
	}
	return true
}

@(private = "file")
duplication_close :: proc(d: ^Duplication) {
	if d.staging != nil { d.staging->Release() }
	if d.duplication != nil { d.duplication->Release() }
	if d.device_context != nil { d.device_context->Release() }
	if d.device != nil { d.device->Release() }
	unavailable := d.unavailable
	d^ = Duplication{unavailable = unavailable}
}

////////////////////////////////
// Textures and surfaces, shared with capture_wgc_windows.odin

// Copies `texture` (BGRA) into `staging^`, made again when its size changed. false: another format, or no texture.
@(private)
staging_copy :: proc(device: ^d3d11.IDevice, device_context: ^d3d11.IDeviceContext, staging: ^^d3d11.ITexture2D, texture: ^d3d11.ITexture2D) -> bool {
	desc: d3d11.TEXTURE2D_DESC
	texture->GetDesc(&desc)
	if desc.Format != .B8G8R8A8_UNORM && desc.Format != .B8G8R8A8_UNORM_SRGB { return false }
	if staging^ != nil {
		have: d3d11.TEXTURE2D_DESC
		staging^->GetDesc(&have)
		if have.Width != desc.Width || have.Height != desc.Height || have.Format != desc.Format {
			staging^->Release()
			staging^ = nil
		}
	}
	if staging^ == nil {
		want := d3d11.TEXTURE2D_DESC{
			Width          = desc.Width,
			Height         = desc.Height,
			MipLevels      = 1,
			ArraySize      = 1,
			Format         = desc.Format,
			SampleDesc     = {Count = 1},
			Usage          = .STAGING,
			CPUAccessFlags = {.READ},
		}
		if device->CreateTexture2D(&want, nil, staging) < 0 || staging^ == nil { return false }
	}
	device_context->CopyResource(staging^, texture)
	return true
}

// The picture in `staging`, turned upright, its `size` first pixels (0: all of it).
@(private)
staging_read :: proc(device_context: ^d3d11.IDeviceContext, staging: ^d3d11.ITexture2D, rotation: Win32_Rotation, allocator: runtime.Allocator, size := [2]i32{}) -> (f: Frame, ok: bool) {
	desc: d3d11.TEXTURE2D_DESC
	staging->GetDesc(&desc)
	sw, sh := i32(desc.Width), i32(desc.Height)
	if size.x > 0 && size.y > 0 { sw, sh = min(sw, size.x), min(sh, size.y) }
	mapped: d3d11.MAPPED_SUBRESOURCE
	if device_context->Map(staging, 0, .READ, {}, &mapped) < 0 || mapped.pData == nil { return }
	defer device_context->Unmap(staging, 0)
	return surface_read(([^]u8)(mapped.pData), i32(mapped.RowPitch), sw, sh, rotation, allocator), true
}

// A frame of the surface `src` (`sw` x `sh` BGRA pixels, rows `pitch` bytes apart), upright, opaque.
@(private = "file")
surface_read :: proc(src: [^]u8, pitch, sw, sh: i32, rotation: Win32_Rotation, allocator: runtime.Allocator) -> Frame {
	w, h := sw, sh
	if rotation == .Rotate90 || rotation == .Rotate270 { w, h = sh, sw }
	f := Frame{width = w, height = h, stride = w * 4, allocator = allocator}
	f.pixels = make([]u8, int(w * h * 4), allocator)
	if rotation == .Identity || rotation == .Unspecified {
		for y in 0 ..< h { copy(f.pixels[int(y * w * 4):][:int(w * 4)], src[int(y * pitch):][:int(w * 4)]) }
	} else {
		for y in 0 ..< h {
			for x in 0 ..< w {
				sx, sy := win32_rotated_source(rotation, x, y, w, h)
				copy(f.pixels[int((y * w + x) * 4):][:4], src[int(sy * pitch + sx * 4):][:4])
			}
		}
	}
	opaque(f.pixels)
	return f
}

// A screen has no transparency: whatever the alpha byte holds (DWM leaves it undefined, GDI zero) becomes 255.
@(private = "file")
opaque :: proc(pixels: []u8) {
	for i := 3; i < len(pixels); i += 4 { pixels[i] = 255 }
}

////////////////////////////////
// GDI

// `r` (physical, on the virtual desktop) copied from the screen. What works where duplication does not.
@(private = "file")
gdi_frame :: proc(r: Rect, allocator: runtime.Allocator) -> (f: Frame, ok: bool) {
	if r.w <= 0 || r.h <= 0 { return }
	screen := win.GetDC(nil)
	if screen == nil { return }
	defer win.ReleaseDC(nil, screen)
	memory := win.CreateCompatibleDC(screen)
	if memory == nil { return }
	defer win.DeleteDC(memory)
	info := win.BITMAPINFO{bmiHeader = {
		biSize        = size_of(win.BITMAPINFOHEADER),
		biWidth       = r.w,
		biHeight      = -r.h,   // negative: rows top to bottom
		biPlanes      = 1,
		biBitCount    = 32,
		biCompression = win.BI_RGB,
	}}
	bits: rawptr
	bitmap := win.CreateDIBSection(screen, &info, win.DIB_RGB_COLORS, &bits, nil, 0)
	if bitmap == nil || bits == nil { return }
	defer win.DeleteObject(win.HGDIOBJ(bitmap))
	previous := win.SelectObject(memory, win.HGDIOBJ(bitmap))
	defer win.SelectObject(memory, previous)
	// CAPTUREBLT: layered windows (translucent ones, many menus and tooltips) are only in the copy with it.
	if !win.BitBlt(memory, 0, 0, r.w, r.h, screen, r.x, r.y, win.SRCCOPY | win.CAPTUREBLT) { return }
	// GDI batches its calls: the bits are there only once the batch ran.
	GdiFlush()
	f = Frame{width = r.w, height = r.h, stride = r.w * 4, allocator = allocator}
	f.pixels = make([]u8, int(r.w * r.h * 4), allocator)
	copy(f.pixels, ([^]u8)(bits)[:int(r.w * r.h * 4)])
	opaque(f.pixels)
	return f, true
}

////////////////////////////////
// Windows

@(private = "file")
window_facts :: proc(handle: win.HWND) -> (f: Win32_Window_Facts) {
	f.visible = bool(win.IsWindowVisible(handle))
	if !f.visible { return }
	cloaked: u32
	f.cloaked = win.DwmGetWindowAttribute(handle, u32(win.DWMWINDOWATTRIBUTE.DWMWA_CLOAKED), &cloaked, size_of(cloaked)) >= 0 && cloaked != 0
	f.minimized = bool(win.IsIconic(handle))
	f.has_owner = win.GetWindow(handle, win.GW_OWNER) != nil
	f.ex_style = u32(win.GetWindowLongW(handle, win.GWL_EXSTYLE))
	class: [CLASS_MAX]u16
	n := win.GetClassNameW(handle, &class[0], CLASS_MAX)
	f.class_name, _ = win.utf16_to_utf8(class[:max(n, 0)], context.temp_allocator)
	title: [TITLE_MAX]u16
	n = InternalGetWindowText(handle, raw_data(title[:]), TITLE_MAX)
	f.title, _ = win.utf16_to_utf8(title[:max(n, 0)], context.temp_allocator)
	f.frame = window_frame(handle)
	return
}

// The window's visible frame, physical: DWM's extended frame bounds leave out the invisible resize borders and the
// shadow that GetWindowRect includes.
@(private = "file")
window_frame :: proc(handle: win.HWND) -> Rect {
	r: win.RECT
	if win.DwmGetWindowAttribute(handle, u32(win.DWMWINDOWATTRIBUTE.DWMWA_EXTENDED_FRAME_BOUNDS), &r, size_of(r)) < 0 {
		win.GetWindowRect(handle, &r)
	}
	return rect_of(r)
}

// The file name of the window's executable; "" when the process cannot be opened (a protected process, another
// user's). A UWP app's windows are ApplicationFrameHost.exe's.
@(private = "file")
executable_name :: proc(handle: win.HWND, allocator: runtime.Allocator) -> string {
	pid: u32
	win.GetWindowThreadProcessId(handle, &pid)
	if pid == 0 { return "" }
	process := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if process == nil { return "" }
	defer win.CloseHandle(process)
	path: [PATH_MAX]u16
	size := u32(PATH_MAX)
	if !QueryFullProcessImageNameW(process, 0, raw_data(path[:]), &size) { return "" }
	text, _ := win.utf16_to_utf8(path[:size], context.temp_allocator)
	return strings.clone(win32_executable_name(text), allocator)
}

////////////////////////////////

@(private = "file")
rect_of :: proc(r: win.RECT) -> Rect { return Rect{r.left, r.top, r.right - r.left, r.bottom - r.top} }

@(private = "file")
until_nul :: proc(s: []u16) -> []u16 {
	for c, i in s { if c == 0 { return s[:i] } }
	return s
}
