package tk_desktop

// "Open with" on Windows: the shell's handlers of the file's extension (SHAssocEnumHandlers, the recommended ones, as
// Explorer's "Open with" shows them), a handler's name its id; one opens the file through IAssocHandler.Invoke with
// the file's data object. The default is the handler whose program is the extension's (AssocQueryStringW).

import "base:runtime"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
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
	GetIconLocation: rawptr,
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
}

// Each handler of the extension of `path`, in the shell's order; `visit` returns false to stop (the handler is released
// after it). COM is entered for the call.
@(private = "file")
each_handler :: proc(path: string, visit: proc(h: ^IAssocHandler, name, ui_name: string, user: rawptr) -> bool, user: rawptr) {
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
		go_on := visit(h, n, u, user)
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
	each_handler(path, proc(h: ^IAssocHandler, name, ui_name: string, user: rawptr) -> bool {
		f := (^Found)(user)
		if name == "" || ui_name == "" { return true }
		for x in f.list { if ascii.equal_fold(x.id, name) { return true } }
		append(&f.list, handler_clone(name, ui_name, f.default != "" && ascii.equal_fold(name, f.default), f.allocator))
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
	each_handler(path, proc(h: ^IAssocHandler, name, ui_name: string, user: rawptr) -> bool {
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
