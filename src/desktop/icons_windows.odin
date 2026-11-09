package tk_desktop

// The shell's icon of a path (SHGetFileInfoW), as Explorer shows it: a folder's own (the person's folders, a drive),
// a program's or a shortcut's own, else its type's. Its colour bitmap read as 32-bit BGRA.

import "base:runtime"
import "core:strings"
import win "core:sys/windows"

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

@(default_calling_convention = "system", private = "file")
foreign shell32 {
	SHGetFileInfoW :: proc(path: win.LPCWSTR, attributes: win.DWORD, info: ^SHFILEINFOW, size: win.UINT, flags: win.UINT) -> uintptr ---
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
	return strings.to_lower(path[i:], context.temp_allocator)
}

@(private)
icon_key_native :: proc(path: string, folder: bool, allocator: runtime.Allocator) -> string {
	// (a folder may be a special one with an icon of its own: each folder its key)
	if folder { return strings.concatenate({"folder:", strings.to_lower(path, context.temp_allocator)}, allocator) }
	ext := extension_of(path)
	if own_icon(ext) { return strings.concatenate({"file:", strings.to_lower(path, context.temp_allocator)}, allocator) }
	return strings.concatenate({"type:", ext}, allocator)
}

@(private)
icon_of_path_native :: proc(path: string, folder: bool, size, choose: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) {
	info: SHFILEINFOW
	flags: win.UINT = SHGFI_ICON | (size <= 16 ? SHGFI_SMALLICON : SHGFI_LARGEICON)
	if SHGetFileInfoW(win.utf8_to_wstring(path, context.temp_allocator), 0, &info, size_of(info), flags) == 0 || info.hIcon == nil {
		// (a path that is gone: the icon of its kind)
		attrs: win.DWORD = folder ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL
		if SHGetFileInfoW(win.utf8_to_wstring(path, context.temp_allocator), attrs, &info, size_of(info), flags | SHGFI_USEFILEATTRIBUTES) == 0 || info.hIcon == nil { return }
	}
	defer win.DestroyIcon(info.hIcon)
	ii: win.ICONINFO
	if !GetIconInfo(info.hIcon, &ii) { return }
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
	// BGRA to RGBA; an icon of no alpha (an old one) is opaque
	any_alpha := false
	for i := 3; i < len(px); i += 4 { if px[i] != 0 { any_alpha = true; break } }
	for i := 0; i < len(px); i += 4 {
		px[i], px[i + 2] = px[i + 2], px[i]
		if !any_alpha { px[i + 3] = 255 }
	}
	return File_Icon{px, {w, h}}, true
}
