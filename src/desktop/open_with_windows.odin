package tk_desktop

// "Open with" on Windows: the shell's handlers of the file's extension (SHAssocEnumHandlers, the recommended ones, as
// Explorer's "Open with" shows them), a handler's name its id; one opens the file through IAssocHandler.Invoke with
// the file's data object. The default is the handler whose program is the extension's (AssocQueryStringW).

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:slice"
import "core:strings"
import win "core:sys/windows"

foreign import shell32_types "system:Shell32.lib"
import "../ascii"

@(private) ASSOC_FILTER_RECOMMENDED :: 0x1
@(private) BHID_DataObject := GUID{0xB8C0BD9F, 0xED24, 0x455C, {0x83, 0xE6, 0xD5, 0x39, 0x0C, 0x4F, 0xE8, 0xC4}}
@(private) IID_IDataObject := GUID{0x0000010E, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

// shobjidl_core.h, in its order.
@(private)
IAssocHandler :: struct { using vtbl: ^IAssocHandler_Vtbl }
@(private)
IAssocHandler_Vtbl :: struct {
	QueryInterface:  proc "system" (this: ^IAssocHandler, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:          proc "system" (this: ^IAssocHandler) -> u32,
	Release:         proc "system" (this: ^IAssocHandler) -> u32,
	GetName:         proc "system" (this: ^IAssocHandler, name: ^win.LPWSTR) -> win.HRESULT,
	GetUIName:       proc "system" (this: ^IAssocHandler, name: ^win.LPWSTR) -> win.HRESULT,
	GetIconLocation: proc "system" (this: ^IAssocHandler, path: ^win.LPWSTR, index: ^i32) -> win.HRESULT,
	IsRecommended:   rawptr,
	MakeDefault:     rawptr,
	Invoke:          proc "system" (this: ^IAssocHandler, data: rawptr) -> win.HRESULT,
	CreateInvoker:   rawptr,
}

@(private)
IEnumAssocHandlers :: struct { using vtbl: ^IEnumAssocHandlers_Vtbl }
@(private)
IEnumAssocHandlers_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IEnumAssocHandlers, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IEnumAssocHandlers) -> u32,
	Release:        proc "system" (this: ^IEnumAssocHandlers) -> u32,
	Next:           proc "system" (this: ^IEnumAssocHandlers, count: u32, out: ^^IAssocHandler, fetched: ^u32) -> win.HRESULT,
}

foreign import shell32_assoc "system:Shell32.lib"
@(default_calling_convention = "system", private)
foreign shell32_assoc {
	SHAssocEnumHandlers :: proc(extension: cstring16, filter: i32, out: ^^IEnumAssocHandlers) -> win.HRESULT ---
	SHDefExtractIconW :: proc(file: cstring16, index: i32, flags: u32, large: ^win.HICON, small: ^win.HICON, sizes: u32) -> win.HRESULT ---
}

// The icon at the shell's location "file,index" (GetIconLocation's), drawn at `size`.
@(private)
handler_icon_native :: proc(icon: string, size: int, allocator: runtime.Allocator) -> (File_Icon, bool) {
	file, index := icon, i32(0)
	if comma := strings.last_index_byte(icon, ','); comma > 0 {
		if n, ok := strconv.parse_int(strings.trim_space(icon[comma + 1:])); ok { file, index = icon[:comma], i32(n) }
	}
	if file == "" { return {}, false }
	com_thread_start()
	large: win.HICON
	px := u32(clamp(size, 1, 256))
	if SHDefExtractIconW(wide(file), index, 0, &large, nil, px) < 0 || large == nil { return {}, false }
	defer win.DestroyIcon(large)
	return icon_pixels(large, allocator)
}

// Each handler of the extension of `path`, in the shell's order; `visit` returns false to stop (the handler is released
// after it). COM is entered for the call.
@(private = "file")
each_handler :: proc(path: string, visit: proc(h: ^IAssocHandler, name, ui_name, icon: string, user: rawptr) -> bool, user: rawptr) {
	ext := filepath.ext(path)
	if ext == "" { return }
	c := com_enter()
	defer com_leave(c)
	en: ^IEnumAssocHandlers
	if SHAssocEnumHandlers(wide(ext), ASSOC_FILTER_RECOMMENDED, &en) < 0 || en == nil { return }
	defer en->Release()
	for {
		h: ^IAssocHandler
		fetched: u32
		if en->Next(1, &h, &fetched) != 0 || fetched == 0 || h == nil { return }
		name, ui_name: win.LPWSTR
		_ = h->GetName(&name)
		_ = h->GetUIName(&ui_name)
		n := name != nil ? win.wstring_to_utf8(cstring16(name), -1, context.temp_allocator) or_else "" : ""
		u := ui_name != nil ? win.wstring_to_utf8(cstring16(ui_name), -1, context.temp_allocator) or_else "" : ""
		if name != nil { win.CoTaskMemFree(name) }
		if ui_name != nil { win.CoTaskMemFree(ui_name) }
		// (the shell's form of a location: "file,index", what handler_icon_native reads)
		icon := ""
		icon_path: win.LPWSTR
		icon_index: i32
		if h->GetIconLocation(&icon_path, &icon_index) >= 0 && icon_path != nil {
			file := win.wstring_to_utf8(cstring16(icon_path), -1, context.temp_allocator) or_else ""
			if file != "" { icon = strings.concatenate({file, ",", fmt.tprint(icon_index)}, context.temp_allocator) }
			win.CoTaskMemFree(icon_path)
		}
		go_on := visit(h, n, u, icon, user)
		h->Release()
		if !go_on { return }
	}
}

// The program the extension of `path` opens with ("" when none).
@(private = "file")
default_program :: proc(path: string) -> string {
	ext := filepath.ext(path)
	if ext == "" { return "" }
	buf: [win.MAX_PATH_WIDE]u16
	n := u32(len(buf))
	if win.AssocQueryStringW({}, .EXECUTABLE, wide(ext), wide("open"), raw_data(buf[:]), &n) != 0 { return "" }
	return narrow(buf[:])
}

@(private)
handlers_for_file_native :: proc(path: string, allocator: runtime.Allocator) -> []Handler {
	Found :: struct { list: [dynamic]Handler, default: string, allocator: runtime.Allocator }
	f := Found{list = make([dynamic]Handler, allocator), default = default_program(path), allocator = allocator}
	each_handler(path, proc(h: ^IAssocHandler, name, ui_name, icon: string, user: rawptr) -> bool {
		f := (^Found)(user)
		if name == "" || ui_name == "" { return true }
		for x in f.list { if ascii.equal_fold(x.id, name) { return true } }
		append(&f.list, handler_clone(name, ui_name, icon, f.default != "" && ascii.equal_fold(name, f.default), f.allocator))
		return true
	}, &f)
	// the default first, then by name
	slice.stable_sort_by(f.list[:], proc(a, b: Handler) -> bool {
		if a.default != b.default { return a.default }
		return strings.compare(ascii.lower(a.name), ascii.lower(b.name)) < 0
	})
	return f.list[:]
}

@(private)
open_with_native :: proc(path: string, id: string) -> bool {
	Run :: struct { path, id: string, done: bool }
	r := Run{path = path, id = id}
	each_handler(path, proc(h: ^IAssocHandler, name, ui_name, icon: string, user: rawptr) -> bool {
		r := (^Run)(user)
		if !ascii.equal_fold(name, r.id) { return true }
		item: ^win.IShellItem
		if win.SHCreateItemFromParsingName(wide(r.path), nil, win.IID_IShellItem, (^rawptr)(&item)) < 0 || item == nil { return false }
		defer item->Release()
		data: rawptr
		if item->BindToHandler(nil, BHID_DataObject, &IID_IDataObject, &data) < 0 || data == nil { return false }
		defer (^win.IUnknown)(data)->Release()
		r.done = h->Invoke(data) >= 0
		return false
	}, &r)
	return r.done
}

@(private = "file") SHGFI_TYPENAME_FLAG :: 0x400
@(private = "file") SHGFI_ATTRIBUTES_GIVEN :: 0x10   // SHGFI_USEFILEATTRIBUTES: the name alone, no file read
@(private = "file") FILE_NORMAL :: 0x80

@(private = "file")
Type_Info :: struct {
	hIcon:         win.HICON,
	iIcon:         i32,
	dwAttributes:  win.DWORD,
	szDisplayName: [win.MAX_PATH]u16,
	szTypeName:    [80]u16,
}

@(default_calling_convention = "system", private = "file")
foreign shell32_types {
	@(link_name = "SHGetFileInfoW")
	type_info_get :: proc(path: win.LPCWSTR, attributes: win.DWORD, info: ^Type_Info, size: win.UINT, flags: win.UINT) -> uintptr ---
}

@(private)
type_name_native :: proc(name: string, allocator: runtime.Allocator) -> string {
	ext := filepath.ext(name)
	if ext == "" { return "" }
	info: Type_Info
	if type_info_get(win.utf8_to_wstring(ext, context.temp_allocator), FILE_NORMAL, &info, size_of(Type_Info), SHGFI_TYPENAME_FLAG | SHGFI_ATTRIBUTES_GIVEN) == 0 { return "" }
	n := 0
	for n < len(info.szTypeName) && info.szTypeName[n] != 0 { n += 1 }
	if n == 0 { return "" }
	text, err := win.utf16_to_utf8(info.szTypeName[:n], allocator)
	return err == nil ? text : ""
}
