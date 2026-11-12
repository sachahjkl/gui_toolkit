package tk_desktop

// The shell's icon of a path, as Explorer shows it: a folder's own (the person's folders, a drive), a program's or a
// shortcut's own, else its type's. SHGetFileInfoW gives its index in the system's image list; the list of the size
// asked (16, 32, 48 or 256 pixels: SHGetImageList) gives the icon, its colour bitmap read as 32-bit BGRA (an old icon
// with no alpha takes it from its mask). COM is started once on each thread that asks (the shell needs it).

import "base:runtime"
import "core:strings"
import win "core:sys/windows"
import "../ascii"

foreign import shell32 "system:Shell32.lib"
foreign import user32 "system:User32.lib"

@(private = "file")
SHFILEINFOW :: struct {
	hIcon:         win.HICON,
	iIcon:         i32,
	dwAttributes:  win.DWORD,
	szDisplayName: [win.MAX_PATH]u16,
	szTypeName:    [80]u16,
}

@(private = "file") SHGFI_ICON              :: 0x100
@(private = "file") SHGFI_SMALLICON         :: 0x1
@(private = "file") SHGFI_LARGEICON         :: 0x0
@(private = "file") SHGFI_USEFILEATTRIBUTES :: 0x10
@(private = "file") FILE_ATTRIBUTE_NORMAL   :: 0x80
@(private = "file") FILE_ATTRIBUTE_DIRECTORY :: 0x10
@(private = "file") SHGFI_SYSICONINDEX      :: 0x4000
@(private = "file") SHIL_LARGE      :: 0   // 32
@(private = "file") SHIL_SMALL      :: 1   // 16
@(private = "file") SHIL_EXTRALARGE :: 2   // 48
@(private = "file") SHIL_JUMBO      :: 4   // 256
@(private = "file") ILD_TRANSPARENT :: 0x1

// IImageList's interface id: an IImageList is an HIMAGELIST (the shell's documentation says it may be cast).
@(private = "file", rodata)
IID_IImageList := win.GUID{0x46EB5926, 0x582E, 0x4017, {0x9F, 0xDF, 0xE8, 0x99, 0x8D, 0xAA, 0x09, 0x50}}

@(private = "file", thread_local) com_started: bool

// COM on this thread, started once and kept while the thread lives (the shell's icons and thumbnails need it).
@(private)
com_thread_start :: proc() {
	if com_started { return }
	win.CoInitializeEx(nil, .APARTMENTTHREADED)
	com_started = true
}

@(default_calling_convention = "system", private = "file")
foreign shell32 {
	SHGetFileInfoW :: proc(path: win.LPCWSTR, attributes: win.DWORD, info: ^SHFILEINFOW, size: win.UINT, flags: win.UINT) -> uintptr ---
	SHGetImageList :: proc(list: i32, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT ---
}

@(default_calling_convention = "system", private = "file")
foreign user32 {
	GetIconInfo :: proc(icon: win.HICON, info: ^win.ICONINFO) -> win.BOOL ---
}

// The extensions whose files have icons of their own (a program's, a shortcut's, an icon file's).
@(private = "file")
own_icon :: proc(ext: string) -> bool {
	switch ext {
	case ".exe", ".lnk", ".ico", ".url", ".scr", ".cpl", ".msc", ".appref-ms": return true
	}
	return false
}

@(private = "file")
extension_of :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '.')
	j := max(strings.last_index_byte(path, '\\'), strings.last_index_byte(path, '/'))
	if i <= j + 1 { return "" }
	return ascii.lower(path[i:])   // (an extension: ASCII)
}

@(private)
icon_key_native :: proc(path: string, folder: bool, allocator: runtime.Allocator) -> string {
	// (a folder may be a special one with an icon of its own: each folder its key)
	if folder { return strings.concatenate({"folder:", strings.to_lower(path, context.temp_allocator)}, allocator) }
	ext := extension_of(path)
	if own_icon(ext) { return strings.concatenate({"file:", strings.to_lower(path, context.temp_allocator)}, allocator) }
	return strings.concatenate({"type:", ext}, allocator)
}

// The list of the system's images nearest above `size`.
@(private = "file")
image_list_for :: proc(size: int) -> i32 {
	switch {
	case size <= 16: return SHIL_SMALL
	case size <= 32: return SHIL_LARGE
	case size <= 48: return SHIL_EXTRALARGE
	}
	return SHIL_JUMBO
}

@(private)
icon_of_path_native :: proc(path: string, folder: bool, size, choose: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) {
	com_thread_start()
	info: SHFILEINFOW
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	if SHGetFileInfoW(wpath, 0, &info, size_of(info), SHGFI_SYSICONINDEX) == 0 {
		// (a path that is gone: the icon of its kind)
		attrs: win.DWORD = folder ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL
		if SHGetFileInfoW(wpath, attrs, &info, size_of(info), SHGFI_SYSICONINDEX | SHGFI_USEFILEATTRIBUTES) == 0 { return }
	}
	list: rawptr
	if SHGetImageList(image_list_for(size), &IID_IImageList, &list) < 0 || list == nil { return }
	hicon := win.ImageList_GetIcon(win.HIMAGELIST(list), info.iIcon, ILD_TRANSPARENT)
	if hicon == nil { return }
	defer win.DestroyIcon(hicon)
	return icon_pixels(hicon, allocator)
}

// An icon's pixels: its colour bitmap as RGBA; with no alpha in it, the alpha from its mask (black there: shown).
@(private = "file")
icon_pixels :: proc(hicon: win.HICON, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) {
	ii: win.ICONINFO
	if !GetIconInfo(hicon, &ii) { return }
	defer if ii.hbmColor != nil { win.DeleteObject(win.HGDIOBJ(ii.hbmColor)) }
	defer if ii.hbmMask != nil { win.DeleteObject(win.HGDIOBJ(ii.hbmMask)) }
	if ii.hbmColor == nil { return }
	bm: win.BITMAP
	if win.GetObjectW(win.HANDLE(ii.hbmColor), size_of(bm), &bm) == 0 { return }
	w, h := int(bm.bmWidth), int(bm.bmHeight)
	bi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(w), biHeight = -i32(h), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	px := make([]u8, w * h * 4, allocator)
	dc := win.CreateCompatibleDC(nil)
	defer win.DeleteDC(dc)
	if win.GetDIBits(dc, ii.hbmColor, 0, u32(h), raw_data(px), &bi, win.DIB_RGB_COLORS) == 0 {
		delete(px, allocator)
		return
	}
	any_alpha := false
	for i := 3; i < len(px); i += 4 { if px[i] != 0 { any_alpha = true; break } }
	mask: []u8
	if !any_alpha && ii.hbmMask != nil {
		mask = make([]u8, w * h * 4, context.temp_allocator)
		mi := bi
		if win.GetDIBits(dc, ii.hbmMask, 0, u32(h), raw_data(mask), &mi, win.DIB_RGB_COLORS) == 0 { mask = nil }
	}
	for i := 0; i < len(px); i += 4 {
		px[i], px[i + 2] = px[i + 2], px[i]
		if !any_alpha { px[i + 3] = mask != nil && mask[i] != 0 ? 0 : 255 }
	}
	return File_Icon{px, {w, h}}, true
}

// (Windows has no icon themes: a program's icon comes from its executable, file_icon)
@(private)
theme_icon_native :: proc(name: string, size: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) { return }
