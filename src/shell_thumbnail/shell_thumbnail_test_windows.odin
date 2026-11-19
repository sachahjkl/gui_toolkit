package shell_thumbnail

// The whole COM path as the shell takes it, in this process: DllGetClassObject, the factory, the provider's two
// interfaces, a memory stream for the document, the bitmap. One test: `set` is the process's (the DLL's @(init)).

import "core:testing"
import win "core:sys/windows"

foreign import shlwapi_ "system:Shlwapi.lib"

@(default_calling_convention = "system", private = "file")
foreign shlwapi_ {
	SHCreateMemStream :: proc(init: [^]u8, size: u32) -> rawptr ---
}

@(private = "file") TEST_CLSID :: "{0b6a3f3e-2d1c-4b8e-9a7f-5c4d3e2f1a0b}"

// The layouts the shell sees (the package's own are file-private): an object is a pointer to its vtable.
@(private = "file")
Test_Unknown :: struct { vtbl: ^Test_Unknown_Vtbl }
@(private = "file")
Test_Unknown_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: rawptr) -> u32,
	Release:        proc "system" (this: rawptr) -> u32,
	method:         rawptr,   // CreateInstance, GetThumbnail, Initialize: cast to its own type
}

@(test)
the_shell_gets_an_opaque_top_down_bitmap :: proc(t: ^testing.T) {
	saved := provider_config
	defer provider_config = saved
	iid_factory := IID_IClassFactory
	iid_thumb := IID_IThumbnailProvider
	iid_init := IID_IInitializeWithStream

	// a malformed CLSID, then another program's: nothing is served
	set("not a clsid", proc(data: []u8, size: int) -> (rgba: []u8, width, height: int, ok: bool) { return })
	testing.expect(t, !provider_config.ready, "a malformed CLSID")
	set(TEST_CLSID, proc(data: []u8, size: int) -> (rgba: []u8, width, height: int, ok: bool) {
		// (two pixels: the document's first byte as red, then a transparent one)
		if len(data) == 0 || size < 2 { return }
		rgba = make([]u8, 8)
		rgba[0], rgba[3] = data[0], 255
		return rgba, 2, 1, true
	})
	clsid, _ := guid_parse(TEST_CLSID)
	other := GUID{1, 2, 3, {4, 5, 6, 7, 8, 9, 10, 11}}
	factory: rawptr
	testing.expect_value(t, dll_get_class_object(&other, &iid_factory, &factory), CLASS_E_CLASSNOTAVAILABLE)
	testing.expect(t, factory == nil, "no factory")

	testing.expect_value(t, dll_get_class_object(&clsid, &iid_factory, &factory), S_OK)
	if factory == nil { return }
	testing.expect_value(t, dll_can_unload_now(), S_FALSE)   // (a factory held)
	f := (^Test_Unknown)(factory)
	create := (proc "system" (this: rawptr, outer: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT)(f.vtbl.method)
	thumb: rawptr
	testing.expect_value(t, create(factory, nil, &iid_thumb, &thumb), S_OK)
	f.vtbl.Release(factory)
	if thumb == nil { return }
	th := (^Test_Unknown)(thumb)
	defer th.vtbl.Release(thumb)

	// before Initialize: refused
	get := (proc "system" (this: rawptr, cx: u32, bitmap: ^win.HBITMAP, alpha: ^u32) -> HRESULT)(th.vtbl.method)
	bitmap: win.HBITMAP
	alpha: u32
	testing.expect(t, get(thumb, 64, &bitmap, &alpha) < 0, "no document yet")

	init: rawptr
	testing.expect_value(t, th.vtbl.QueryInterface(thumb, &iid_init, &init), S_OK)
	if init == nil { return }
	in_ := (^Test_Unknown)(init)
	initialize := (proc "system" (this: rawptr, stream: rawptr, mode: u32) -> HRESULT)(in_.vtbl.method)
	document := []u8{200, 1, 2, 3}
	stream := SHCreateMemStream(raw_data(document), u32(len(document)))
	testing.expect(t, stream != nil, "a memory stream")
	if stream == nil { in_.vtbl.Release(init); return }
	testing.expect_value(t, initialize(init, stream, 0), S_OK)
	testing.expect_value(t, initialize(init, stream, 0), ALREADY_INITIALIZED)
	(^Test_Unknown)(stream).vtbl.Release(stream)
	in_.vtbl.Release(init)

	testing.expect_value(t, get(thumb, 64, &bitmap, &alpha), S_OK)
	testing.expect_value(t, alpha, u32(1))   // WTSAT_RGB
	testing.expect(t, bitmap != nil, "a bitmap")
	if bitmap == nil { return }
	defer win.DeleteObject(win.HGDIOBJ(bitmap))
	bm: win.BITMAP
	testing.expect(t, win.GetObjectW(win.HANDLE(bitmap), size_of(bm), &bm) > 0, "the bitmap reads")
	testing.expect_value(t, bm.bmWidth, 2)
	testing.expect_value(t, bm.bmBitsPixel, 32)
	if bm.bmBits != nil {
		px := (cast([^]u8)bm.bmBits)[:8]
		testing.expect_value(t, [8]u8{px[0], px[1], px[2], px[3], px[4], px[5], px[6], px[7]}, [8]u8{0, 0, 200, 255, 255, 255, 255, 255})
	}
}
