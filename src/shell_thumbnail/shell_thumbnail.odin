// Package shell_thumbnail (gt:shell_thumbnail): a program's thumbnail provider for Windows Explorer, the in-process COM
// server of its own small DLL (src/md/features/shell-thumbnails.md, docs/shell-thumbnail.md). The program gives a
// render procedure; the package does the COM plumbing: the class factory, IInitializeWithStream, IThumbnailProvider,
// the reference and lock counts.
//
// The program's DLL package holds only this:
//
//     @(init) thumbnailer_init :: proc "contextless" () { ... shell_thumbnail.set(CLSID, render) }
//     @(export, link_name = "DllGetClassObject")
//     DllGetClassObject :: proc "system" (rclsid, riid: ^shell_thumbnail.GUID, ppv: ^rawptr) -> shell_thumbnail.HRESULT {
//         return shell_thumbnail.dll_get_class_object(rclsid, riid, ppv)
//     }
//     @(export, link_name = "DllCanUnloadNow")
//     DllCanUnloadNow :: proc "system" () -> shell_thumbnail.HRESULT { return shell_thumbnail.dll_can_unload_now() }
//
// Odin's runtime gives the DLL its DllMain, which runs the @(init) procedures. Other systems: the package compiles,
// `set` keeps its values and the entries refuse (shell_thumbnail_other.odin).
package shell_thumbnail

// The largest document read: the provider holds the whole stream in memory (a PDF's index is at its end), and the
// surrogate's memory is the person's.
DOCUMENT_MAX :: 256 << 20

// A COM HRESULT (LONG): below 0 is a failure.
HRESULT :: i32

S_OK                      :: HRESULT(0)
S_FALSE                   :: HRESULT(1)
E_NOINTERFACE             :: HRESULT(-2147467262)   // 0x80004002
E_POINTER                 :: HRESULT(-2147467261)   // 0x80004003
E_FAIL                    :: HRESULT(-2147467259)   // 0x80004005
E_OUTOFMEMORY             :: HRESULT(-2147024882)   // 0x8007000E
E_UNEXPECTED              :: HRESULT(-2147418113)   // 0x8000FFFF
CLASS_E_NOAGGREGATION     :: HRESULT(-2147221232)   // 0x80040110
CLASS_E_CLASSNOTAVAILABLE :: HRESULT(-2147221231)   // 0x80040111
ALREADY_INITIALIZED       :: HRESULT(-2147023649)   // 0x800704DF: HRESULT_FROM_WIN32(ERROR_ALREADY_INITIALIZED)

// A COM GUID as Windows lays it out (the CLSID, an interface's IID).
GUID :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

// The document's first page fitted in `size` x `size` pixels, as straight RGBA8 (`width` * `height` * 4 bytes), in
// `context.allocator`: the package frees `rgba` with it, which is the default heap allocator of the COM call's context.
// `data` is the whole file, borrowed for the call. Called from the surrogate's threads, several at once: it must be
// thread-safe.
Render :: proc(data: []u8, size: int) -> (rgba: []u8, width, height: int, ok: bool)

// What `set` gave: the program's CLSID and its render. Written once, by the DLL's @(init), before any COM call reads it.
@(private)
Provider_Config :: struct {
	clsid:  GUID,
	render: Render,
	ready:  bool,
}

@(private)
provider_config: Provider_Config

// Makes the DLL serve `clsid` ("{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}", the one the program's install registers) with
// `render`. Call it from the DLL's @(init), or before any export is used. A malformed `clsid` leaves the DLL serving
// nothing: DllGetClassObject then says CLASS_E_CLASSNOTAVAILABLE.
set :: proc "contextless" (clsid: string, render: Render) {
	g, ok := guid_parse(clsid)
	provider_config = {clsid = g, render = render, ready = ok && render != nil}
}

// The GUID a registry string writes ("{8-4-4-4-12}" hex digits, either case); ok false for anything else.
guid_parse :: proc "contextless" (s: string) -> (g: GUID, ok: bool) {
	if len(s) != 38 || s[0] != '{' || s[37] != '}' { return }
	for i in ([]int{9, 14, 19, 24}) { if s[i] != '-' { return } }
	hex :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
		for c in transmute([]u8)s {
			d: u8
			switch c {
			case '0' ..= '9': d = c - '0'
			case 'a' ..= 'f': d = c - 'a' + 10
			case 'A' ..= 'F': d = c - 'A' + 10
			case:             return 0, false
			}
			v = v << 4 | u64(d)
		}
		return v, true
	}
	a, ok1 := hex(s[1:9])
	b, ok2 := hex(s[10:14])
	c, ok3 := hex(s[15:19])
	d, ok4 := hex(s[20:24])
	e, ok5 := hex(s[25:37])
	if !(ok1 && ok2 && ok3 && ok4 && ok5) { return }
	g.data1, g.data2, g.data3 = u32(a), u16(b), u16(c)
	g.data4[0], g.data4[1] = u8(d >> 8), u8(d)
	for i in 0 ..< 6 { g.data4[2 + i] = u8(e >> uint(8 * (5 - i))) }
	return g, true
}

// Straight RGBA8 `rgba` as the bitmap Explorer takes: BGRA, every pixel opaque, composited on white (a page is paper:
// a transparent pixel would show the view's background through it). `bgra` holds as many bytes as `rgba`.
bgra_on_white :: proc "contextless" (rgba, bgra: []u8) {
	over :: proc "contextless" (c, a: u32) -> u8 { return u8((c * a + 255 * (255 - a) + 127) / 255) }
	n := min(len(rgba), len(bgra)) / 4
	for i in 0 ..< n {
		p := rgba[i * 4:][:4]
		a := u32(p[3])
		bgra[i * 4 + 0] = over(u32(p[2]), a)
		bgra[i * 4 + 1] = over(u32(p[1]), a)
		bgra[i * 4 + 2] = over(u32(p[0]), a)
		bgra[i * 4 + 3] = 255
	}
}
