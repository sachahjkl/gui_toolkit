package shell_thumbnail

// The COM in-process server: a class factory (one static object) and the provider it makes, one per thumbnail asked.
// Every vtable lists its methods in the order of the SDK's headers (unknwn.h, propsys.h, thumbcache.h, objidl.h): the
// offsets are what matters. Every "system" entry makes its own Odin context: the caller is a thread of the shell's
// surrogate, which has none.

import "base:runtime"
import "core:sync"
import win "core:sys/windows"

IID_IUnknown              :: GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IClassFactory         :: GUID{0x00000001, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IInitializeWithStream :: GUID{0xb824b49d, 0x22ac, 0x4161, {0xac, 0x8a, 0x99, 0x16, 0xe8, 0xfa, 0x3f, 0x7f}}
IID_IThumbnailProvider    :: GUID{0xe357fccd, 0xa995, 0x4576, {0xb0, 0x1f, 0x23, 0x46, 0x30, 0x15, 0x4e, 0x96}}

// WTS_ALPHATYPE: the bitmap has no alpha to read (every pixel is opaque, bgra_on_white).
@(private = "file") WTSAT_RGB :: u32(1)
// STATFLAG_NONAME: Stat gives no name (nothing to free).
@(private = "file") STATFLAG_NONAME :: u32(1)
// What one Read asks: the stream may be a file on a network share.
@(private = "file") READ_CHUNK :: 1 << 20

// The objects alive and the locks held (LockServer, a factory held): DllCanUnloadNow says S_OK at 0.
@(private = "file")
module_count: i32

// dll_get_class_object: the class factory of the program's CLSID (set), for DllGetClassObject.
dll_get_class_object :: proc "system" (rclsid, riid: ^GUID, ppv: ^rawptr) -> HRESULT {
	if ppv == nil { return E_POINTER }
	ppv^ = nil
	if !provider_config.ready || rclsid == nil || rclsid^ != provider_config.clsid { return CLASS_E_CLASSNOTAVAILABLE }
	return FACTORY_VTBL.QueryInterface(&the_factory, riid, ppv)
}

// dll_can_unload_now: S_OK when no object and no lock is left, else S_FALSE, for DllCanUnloadNow.
dll_can_unload_now :: proc "system" () -> HRESULT {
	return sync.atomic_load(&module_count) == 0 ? S_OK : S_FALSE
}

////////////////////////////////
// The class factory

@(private = "file")
Factory :: struct { vtbl: ^Factory_Vtbl }

@(private = "file")
Factory_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^Factory, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: ^Factory) -> u32,
	Release:        proc "system" (this: ^Factory) -> u32,
	CreateInstance: proc "system" (this: ^Factory, outer: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT,
	LockServer:     proc "system" (this: ^Factory, lock: win.BOOL) -> HRESULT,
}

// (static: its references are locks of the module, so a held factory keeps the DLL loaded)
@(private = "file", rodata)
FACTORY_VTBL := Factory_Vtbl{
	QueryInterface = proc "system" (this: ^Factory, riid: ^GUID, out: ^rawptr) -> HRESULT {
		if out == nil { return E_POINTER }
		if riid != nil && (riid^ == IID_IUnknown || riid^ == IID_IClassFactory) {
			sync.atomic_add(&module_count, 1)
			out^ = this
			return S_OK
		}
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^Factory) -> u32 { return u32(sync.atomic_add(&module_count, 1) + 1) },
	Release = proc "system" (this: ^Factory) -> u32 { return u32(sync.atomic_sub(&module_count, 1) - 1) },
	CreateInstance = proc "system" (this: ^Factory, outer: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT {
		if out == nil { return E_POINTER }
		out^ = nil
		if outer != nil { return CLASS_E_NOAGGREGATION }
		context = runtime.default_context()
		p := new(Provider, runtime.heap_allocator())
		if p == nil { return E_OUTOFMEMORY }
		p^ = {thumb = &THUMBNAIL_VTBL, init = &INIT_VTBL, refs = 1}
		sync.atomic_add(&module_count, 1)
		hr := provider_query(p, riid, out)
		provider_release(p)   // (the caller's reference is the query's; none left on failure)
		return hr
	},
	LockServer = proc "system" (this: ^Factory, lock: win.BOOL) -> HRESULT {
		if lock { sync.atomic_add(&module_count, 1) } else { sync.atomic_sub(&module_count, 1) }
		return S_OK
	},
}

@(private = "file")
the_factory := Factory{vtbl = &FACTORY_VTBL}

////////////////////////////////
// The provider: IUnknown and IThumbnailProvider at its start, IInitializeWithStream after

@(private = "file")
Provider :: struct {
	thumb: ^Thumbnail_Vtbl,   // the object's pointer: IUnknown, IThumbnailProvider
	init:  ^Init_Vtbl,        // &init: IInitializeWithStream
	refs:  i32,
	data:  []u8,              // the document, read whole by Initialize (the heap's)
	ready: bool,              // Initialize succeeded
}

@(private = "file")
Thumbnail_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^Provider, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: ^Provider) -> u32,
	Release:        proc "system" (this: ^Provider) -> u32,
	GetThumbnail:   proc "system" (this: ^Provider, cx: u32, bitmap: ^win.HBITMAP, alpha: ^u32) -> HRESULT,
}

// (`this` is &Provider.init: init_owner finds the object)
@(private = "file")
Init_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: rawptr) -> u32,
	Release:        proc "system" (this: rawptr) -> u32,
	Initialize:     proc "system" (this: rawptr, stream: ^Stream, mode: u32) -> HRESULT,
}

// IStream: only Read and Stat are called.
@(private = "file")
Stream :: struct { vtbl: ^Stream_Vtbl }

@(private = "file")
Stream_Vtbl :: struct {
	QueryInterface: rawptr,
	AddRef:         rawptr,
	Release:        rawptr,
	Read:           proc "system" (this: ^Stream, pv: rawptr, cb: u32, read: ^u32) -> HRESULT,
	Write:          rawptr,
	Seek:           rawptr,
	SetSize:        rawptr,
	CopyTo:         rawptr,
	Commit:         rawptr,
	Revert:         rawptr,
	LockRegion:     rawptr,
	UnlockRegion:   rawptr,
	Stat:           proc "system" (this: ^Stream, stat: ^win.STATSTG, flag: u32) -> HRESULT,
	Clone:          rawptr,
}

@(private = "file")
init_owner :: proc "contextless" (this: rawptr) -> ^Provider {
	return (^Provider)(uintptr(this) - offset_of(Provider, init))
}

@(private = "file")
provider_query :: proc "contextless" (p: ^Provider, riid: ^GUID, out: ^rawptr) -> HRESULT {
	if out == nil { return E_POINTER }
	out^ = nil
	if riid == nil { return E_NOINTERFACE }
	if riid^ == IID_IUnknown || riid^ == IID_IThumbnailProvider {
		out^ = p
	} else if riid^ == IID_IInitializeWithStream {
		out^ = &p.init
	} else {
		return E_NOINTERFACE
	}
	sync.atomic_add(&p.refs, 1)
	return S_OK
}

@(private = "file")
provider_release :: proc "contextless" (p: ^Provider) -> u32 {
	left := sync.atomic_sub(&p.refs, 1) - 1
	if left == 0 {
		context = runtime.default_context()
		delete(p.data, runtime.heap_allocator())
		free(p, runtime.heap_allocator())
		sync.atomic_sub(&module_count, 1)
	}
	return u32(left)
}

@(private = "file", rodata)
THUMBNAIL_VTBL := Thumbnail_Vtbl{
	QueryInterface = proc "system" (this: ^Provider, riid: ^GUID, out: ^rawptr) -> HRESULT { return provider_query(this, riid, out) },
	AddRef = proc "system" (this: ^Provider) -> u32 { return u32(sync.atomic_add(&this.refs, 1) + 1) },
	Release = proc "system" (this: ^Provider) -> u32 { return provider_release(this) },
	GetThumbnail = proc "system" (this: ^Provider, cx: u32, bitmap: ^win.HBITMAP, alpha: ^u32) -> HRESULT {
		if bitmap == nil { return E_POINTER }
		bitmap^ = nil
		if !this.ready || !provider_config.ready { return E_UNEXPECTED }
		if cx == 0 { return E_FAIL }
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		rgba, w, h, ok := provider_config.render(this.data, int(cx))
		defer delete(rgba)
		if !ok || w <= 0 || h <= 0 || len(rgba) < w * h * 4 { return E_FAIL }
		// (a negative height: top-down rows, as the render gives them; 32 bits a pixel need no row padding)
		info := win.BITMAPINFO{bmiHeader = {
			biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(w), biHeight = -i32(h),
			biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB,
		}}
		bits: rawptr
		dib := win.CreateDIBSection(nil, &info, win.DIB_RGB_COLORS, &bits, nil, 0)
		if dib == nil || bits == nil {
			if dib != nil { win.DeleteObject(win.HGDIOBJ(dib)) }
			return E_OUTOFMEMORY
		}
		bgra_on_white(rgba[:w * h * 4], (cast([^]u8)bits)[:w * h * 4])
		bitmap^ = dib
		if alpha != nil { alpha^ = WTSAT_RGB }
		return S_OK
	},
}

@(private = "file", rodata)
INIT_VTBL := Init_Vtbl{
	QueryInterface = proc "system" (this: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT { return provider_query(init_owner(this), riid, out) },
	AddRef = proc "system" (this: rawptr) -> u32 { return u32(sync.atomic_add(&init_owner(this).refs, 1) + 1) },
	Release = proc "system" (this: rawptr) -> u32 { return provider_release(init_owner(this)) },
	// The document, read whole into memory: the stream is released by the shell after this call, and the render needs
	// the whole file. A stream larger than DOCUMENT_MAX is refused.
	Initialize = proc "system" (this: rawptr, stream: ^Stream, mode: u32) -> HRESULT {
		p := init_owner(this)
		if p.ready { return ALREADY_INITIALIZED }
		if stream == nil { return E_POINTER }
		context = runtime.default_context()
		heap := runtime.heap_allocator()
		expected := 0
		st: win.STATSTG
		if stream.vtbl.Stat(stream, &st, STATFLAG_NONAME) >= 0 {
			if u64(st.cbSize) > DOCUMENT_MAX { return E_FAIL }
			expected = int(st.cbSize)
		}
		data := make([dynamic]u8, 0, expected, heap)
		for {
			n := len(data)
			if n >= DOCUMENT_MAX + 1 { delete(data); return E_FAIL }
			want := min(READ_CHUNK, DOCUMENT_MAX + 1 - n)
			if resize(&data, n + want) != .None { delete(data); return E_OUTOFMEMORY }
			got: u32
			hr := stream.vtbl.Read(stream, &data[n], u32(want), &got)
			_ = resize(&data, n + int(min(got, u32(want))))   // (smaller: never fails)
			if hr < 0 { delete(data); return hr }
			if got == 0 { break }
		}
		if len(data) > DOCUMENT_MAX || len(data) == 0 { delete(data); return E_FAIL }
		_, _ = shrink(&data)
		p.data = data[:]
		p.ready = true
		return S_OK
	},
}
