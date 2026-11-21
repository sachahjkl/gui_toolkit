#+build windows
package tk_desktop

// System shell context menu on Windows (src/md/features/context-menu.md): runs on the dedicated COM STA worker thread
// owned by Context_Menu. Queries IShellFolder::GetUIObjectOf (for selected items) or CreateViewObject (for a folder
// background) to obtain IContextMenu, populates an HMENU (including dynamic submenus via IContextMenu2/3 HandleMenuMsg),
// extracts plain Context_Items, and invokes commands on the same STA thread via IContextMenu::InvokeCommand.

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import "../ascii"

@(private = "file") SHELL_CMD_FIRST      :: u32(1)
@(private = "file") SHELL_CMD_LAST       :: u32(0x7FFF)
@(private = "file") SHELL_MENU_TEXT_MAX  :: 256

@(private = "file") CMF_NORMAL           :: u32(0x00000000)
@(private = "file") CMF_EXPLORE          :: u32(0x00000004)
@(private = "file") GCS_VERBW            :: u32(0x00000004)
@(private = "file") CMIC_MASK_UNICODE    :: u32(0x00004000)

@(private = "file") MIIM_STATE           :: u32(0x00000001)
@(private = "file") MIIM_ID              :: u32(0x00000002)
@(private = "file") MIIM_SUBMENU         :: u32(0x00000004)
@(private = "file") MIIM_FTYPE           :: u32(0x00000100)
@(private = "file") MIIM_STRING          :: u32(0x00000040)
@(private = "file") MFT_SEPARATOR        :: u32(0x00000800)
@(private = "file") MFS_DISABLED         :: u32(0x00000003)

@(private = "file") IID_IShellFolder_Val  :: GUID{0x000214E6, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file") IID_IContextMenu_Val  :: GUID{0x000214E4, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file") IID_IContextMenu2_Val :: GUID{0x000214F4, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file") IID_IContextMenu3_Val :: GUID{0xBCFCE0A0, 0xEC17, 0x11D0, {0x8D, 0x10, 0x00, 0xA0, 0xC9, 0x0F, 0x27, 0x19}}

@(private = "file")
IShellFolder :: struct { using vtbl: ^IShellFolder_Vtbl }
@(private = "file")
IShellFolder_Vtbl :: struct {
	QueryInterface:   proc "system" (this: ^IShellFolder, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:           proc "system" (this: ^IShellFolder) -> u32,
	Release:          proc "system" (this: ^IShellFolder) -> u32,
	ParseDisplayName: rawptr,
	EnumObjects:      rawptr,
	BindToObject:     rawptr,
	BindToStorage:    rawptr,
	CompareIDs:       rawptr,
	CreateViewObject: proc "system" (this: ^IShellFolder, hwnd: win.HWND, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	GetAttributesOf:  rawptr,
	GetUIObjectOf:    proc "system" (this: ^IShellFolder, hwnd: win.HWND, cidl: u32, apidl: [^]rawptr, riid: ^GUID, reserved: ^u32, out: ^rawptr) -> win.HRESULT,
	GetDisplayNameOf: rawptr,
	SetNameOf:        rawptr,
}

@(private = "file")
IContextMenu :: struct { using vtbl: ^IContextMenu_Vtbl }
@(private = "file")
IContextMenu_Vtbl :: struct {
	QueryInterface:   proc "system" (this: ^IContextMenu, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:           proc "system" (this: ^IContextMenu) -> u32,
	Release:          proc "system" (this: ^IContextMenu) -> u32,
	QueryContextMenu: proc "system" (this: ^IContextMenu, hmenu: win.HMENU, index_menu, id_first, id_last, flags: u32) -> win.HRESULT,
	InvokeCommand:    proc "system" (this: ^IContextMenu, info: ^CMINVOKECOMMANDINFOEX) -> win.HRESULT,
	GetCommandString: proc "system" (this: ^IContextMenu, id_cmd: uintptr, flags: u32, reserved: ^u32, name: rawptr, cch_max: u32) -> win.HRESULT,
}

@(private = "file")
IContextMenu2 :: struct { using vtbl: ^IContextMenu2_Vtbl }
@(private = "file")
IContextMenu2_Vtbl :: struct {
	QueryInterface:   proc "system" (this: ^IContextMenu2, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:           proc "system" (this: ^IContextMenu2) -> u32,
	Release:          proc "system" (this: ^IContextMenu2) -> u32,
	QueryContextMenu: rawptr,
	InvokeCommand:    rawptr,
	GetCommandString: rawptr,
	HandleMenuMsg:    proc "system" (this: ^IContextMenu2, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) -> win.HRESULT,
}

@(private = "file")
IContextMenu3 :: struct { using vtbl: ^IContextMenu3_Vtbl }
@(private = "file")
IContextMenu3_Vtbl :: struct {
	QueryInterface:   proc "system" (this: ^IContextMenu3, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:           proc "system" (this: ^IContextMenu3) -> u32,
	Release:          proc "system" (this: ^IContextMenu3) -> u32,
	QueryContextMenu: rawptr,
	InvokeCommand:    rawptr,
	GetCommandString: rawptr,
	HandleMenuMsg:    proc "system" (this: ^IContextMenu3, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) -> win.HRESULT,
	HandleMenuMsg2:   proc "system" (this: ^IContextMenu3, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM, result: ^win.LRESULT) -> win.HRESULT,
}

@(private = "file")
CMINVOKECOMMANDINFOEX :: struct {
	cbSize:        u32,
	fMask:         u32,
	hwnd:          win.HWND,
	lpVerb:        cstring,
	lpParameters:  cstring,
	lpDirectory:   cstring,
	nShow:         i32,
	dwHotKey:      u32,
	hIcon:         win.HANDLE,
	lpTitle:       cstring,
	lpVerbW:       cstring16,
	lpParametersW: cstring16,
	lpDirectoryW:  cstring16,
	lpTitleW:      cstring16,
	ptInvoke:      win.POINT,
}
when size_of(rawptr) == 8 { #assert(size_of(CMINVOKECOMMANDINFOEX) == 104) }

@(private = "file")
MENUITEMINFOW :: struct {
	cbSize:        u32,
	fMask:         u32,
	fType:         u32,
	fState:        u32,
	wID:           u32,
	hSubMenu:      win.HMENU,
	hbmpChecked:   win.HBITMAP,
	hbmpUnchecked: win.HBITMAP,
	dwItemData:    uintptr,
	dwTypeData:    win.LPWSTR,
	cch:           u32,
	hbmpItem:      win.HBITMAP,
}
when size_of(rawptr) == 8 { #assert(size_of(MENUITEMINFOW) == 80) }

foreign import shell32_ctx "system:Shell32.lib"
foreign import user32_ctx  "system:User32.lib"

@(default_calling_convention = "system", private = "file")
foreign shell32_ctx {
	SHParseDisplayName :: proc(name: cstring16, pbc: rawptr, ppidl: ^rawptr, sfgao_in: u32, psfgao_out: ^u32) -> win.HRESULT ---
	SHBindToParent     :: proc(pidl: rawptr, riid: ^GUID, ppv: ^rawptr, ppidl_last: ^rawptr) -> win.HRESULT ---
	SHBindToObject     :: proc(psf: ^IShellFolder, pidl: rawptr, pbc: rawptr, riid: ^GUID, ppv: ^rawptr) -> win.HRESULT ---
	ILFree             :: proc(pidl: rawptr) ---
}

@(default_calling_convention = "system", private = "file")
foreign user32_ctx {
	CreatePopupMenu  :: proc() -> win.HMENU ---
	DestroyMenu      :: proc(hmenu: win.HMENU) -> win.BOOL ---
	GetMenuItemCount :: proc(hmenu: win.HMENU) -> i32 ---
	GetMenuItemInfoW :: proc(hmenu: win.HMENU, item: u32, by_pos: win.BOOL, lpmii: ^MENUITEMINFOW) -> win.BOOL ---
}

@(private)
Context_Menu_Native :: struct {
	com:   Com,
	cm:    ^IContextMenu,
	cm2:   ^IContextMenu2,
	cm3:   ^IContextMenu3,
	hmenu: win.HMENU,
	dir:   string,   // owned (heap): working directory passed to InvokeCommand
}

@(private)
context_menu_native_init :: proc(ns: ^Context_Menu_Native) {
	ns.com = com_enter()
}

@(private)
context_menu_native_end :: proc(ns: ^Context_Menu_Native) {
	context_menu_native_clear(ns)
	com_leave(ns.com)
	ns.com = {}
}

@(private)
context_menu_native_clear :: proc(ns: ^Context_Menu_Native) {
	if ns.cm3 != nil { ns.cm3->Release(); ns.cm3 = nil }
	if ns.cm2 != nil { ns.cm2->Release(); ns.cm2 = nil }
	if ns.cm != nil  { ns.cm->Release();  ns.cm = nil }
	if ns.hmenu != nil { DestroyMenu(ns.hmenu); ns.hmenu = nil }
	delete(ns.dir, runtime.heap_allocator())
	ns.dir = ""
}

@(private)
context_menu_native_query :: proc(ns: ^Context_Menu_Native, req: Context_Query_Req, allocator: runtime.Allocator) -> []Context_Item {
	if len(req.paths) == 0 { return nil }
	cm := req.background ? query_background_cm(req.paths[0]) : query_items_cm(req.paths)
	if cm == nil { return nil }
	hmenu := CreatePopupMenu()
	if hmenu == nil {
		cm->Release()
		return nil
	}
	if cm->QueryContextMenu(hmenu, 0, SHELL_CMD_FIRST, SHELL_CMD_LAST, CMF_NORMAL | CMF_EXPLORE) < 0 {
		DestroyMenu(hmenu)
		cm->Release()
		return nil
	}
	ns.cm = cm
	ns.hmenu = hmenu
	iid2 := IID_IContextMenu2_Val
	_ = cm->QueryInterface(&iid2, (^rawptr)(&ns.cm2))
	iid3 := IID_IContextMenu3_Val
	_ = cm->QueryInterface(&iid3, (^rawptr)(&ns.cm3))
	dir := req.background ? req.paths[0] : filepath.dir(req.paths[0])
	ns.dir = strings.clone(dir, runtime.heap_allocator())

	raw := walk_hmenu(ns, hmenu, 0, context.temp_allocator)
	return context_items_prune(raw, req.exclude_verbs, allocator)
}

@(private)
context_menu_native_invoke :: proc(ns: ^Context_Menu_Native, id: u32, hwnd: rawptr) -> bool {
	if ns.cm == nil || id < SHELL_CMD_FIRST || id > SHELL_CMD_LAST { return false }
	offset := uintptr(id - SHELL_CMD_FIRST)
	dir_w := ns.dir != "" ? wide(ns.dir) : nil
	info := CMINVOKECOMMANDINFOEX{
		cbSize       = size_of(CMINVOKECOMMANDINFOEX),
		fMask        = CMIC_MASK_UNICODE,
		hwnd         = win.HWND(hwnd),
		lpVerb       = cstring(rawptr(offset)),
		lpVerbW      = cstring16(rawptr(offset)),
		lpDirectoryW = dir_w,
		nShow        = win.SW_SHOWNORMAL,
	}
	return ns.cm->InvokeCommand(&info) >= 0
}

@(private = "file")
query_background_cm :: proc(folder_path: string) -> ^IContextMenu {
	pidl: rawptr
	if SHParseDisplayName(wide(folder_path), nil, &pidl, 0, nil) < 0 || pidl == nil { return nil }
	defer ILFree(pidl)
	sf: ^IShellFolder
	iid_sf := IID_IShellFolder_Val
	if SHBindToObject(nil, pidl, nil, &iid_sf, (^rawptr)(&sf)) < 0 || sf == nil { return nil }
	defer sf->Release()
	cm: ^IContextMenu
	iid_cm := IID_IContextMenu_Val
	if sf->CreateViewObject(nil, &iid_cm, (^rawptr)(&cm)) < 0 { return nil }
	return cm
}

// Binds the first path's parent IShellFolder and passes every selected path sharing that same parent folder.
@(private = "file")
query_items_cm :: proc(paths: []string) -> ^IContextMenu {
	first_dir := filepath.dir(paths[0])
	full_pidls := make([dynamic]rawptr, 0, len(paths), context.temp_allocator)
	child_pidls := make([dynamic]rawptr, 0, len(paths), context.temp_allocator)
	defer for p in full_pidls { ILFree(p) }

	parent: ^IShellFolder
	defer if parent != nil { parent->Release() }

	iid_sf := IID_IShellFolder_Val
	for p, i in paths {
		if i > 0 && !ascii.equal_fold(filepath.dir(p), first_dir) { continue }
		full: rawptr
		if SHParseDisplayName(wide(p), nil, &full, 0, nil) < 0 || full == nil { continue }
		append(&full_pidls, full)
		child: rawptr
		sf: ^IShellFolder
		if SHBindToParent(full, &iid_sf, (^rawptr)(&sf), &child) < 0 || sf == nil || child == nil { continue }
		if parent == nil {
			parent = sf
		} else {
			sf->Release()
		}
		append(&child_pidls, child)
	}
	if parent == nil || len(child_pidls) == 0 { return nil }
	cm: ^IContextMenu
	iid_cm := IID_IContextMenu_Val
	if parent->GetUIObjectOf(nil, u32(len(child_pidls)), raw_data(child_pidls), &iid_cm, nil, (^rawptr)(&cm)) < 0 { return nil }
	return cm
}

@(private = "file")
walk_hmenu :: proc(ns: ^Context_Menu_Native, hmenu: win.HMENU, depth: int, allocator: runtime.Allocator) -> []Context_Item {
	if hmenu == nil || depth >= CONTEXT_MENU_MAX_DEPTH { return nil }
	count := GetMenuItemCount(hmenu)
	if count <= 0 { return nil }
	out := make([dynamic]Context_Item, 0, int(count), allocator)
	text_buf: [SHELL_MENU_TEXT_MAX]u16
	for i := u32(0); i < u32(count); i += 1 {
		mii := MENUITEMINFOW{
			cbSize     = size_of(MENUITEMINFOW),
			fMask      = MIIM_FTYPE | MIIM_STATE | MIIM_ID | MIIM_SUBMENU | MIIM_STRING,
			dwTypeData = raw_data(text_buf[:]),
			cch        = u32(len(text_buf)),
		}
		if !GetMenuItemInfoW(hmenu, i, true, &mii) { continue }
		if (mii.fType & MFT_SEPARATOR) != 0 {
			append(&out, Context_Item{separator = true})
			continue
		}
		raw_label := narrow(text_buf[:min(int(mii.cch), len(text_buf))], context.temp_allocator)
		label := context_menu_strip_mnemonic(raw_label, allocator)
		disabled := (mii.fState & MFS_DISABLED) != 0

		if mii.hSubMenu != nil {
			// Ask IContextMenu2/3 to populate dynamic submenus (7-Zip, Send To, Git, etc.) before walking them.
			init_submenu(ns, mii.hSubMenu, i)
			kids := walk_hmenu(ns, mii.hSubMenu, depth + 1, allocator)
			if len(kids) > 0 && label != "" {
				append(&out, Context_Item{label = label, disabled = disabled, children = kids})
			}
			continue
		}
		if mii.wID < SHELL_CMD_FIRST || mii.wID > SHELL_CMD_LAST || label == "" { continue }
		verb := query_verb(ns.cm, mii.wID - SHELL_CMD_FIRST, allocator)
		append(&out, Context_Item{id = mii.wID, label = label, verb = verb, disabled = disabled})
	}
	return out[:]
}

@(private = "file")
init_submenu :: proc(ns: ^Context_Menu_Native, sub: win.HMENU, pos: u32) {
	if ns.cm3 != nil {
		res: win.LRESULT
		_ = ns.cm3->HandleMenuMsg2(win.WM_INITMENUPOPUP, win.WPARAM(uintptr(sub)), win.LPARAM(pos), &res)
	} else if ns.cm2 != nil {
		_ = ns.cm2->HandleMenuMsg(win.WM_INITMENUPOPUP, win.WPARAM(uintptr(sub)), win.LPARAM(pos))
	}
}

@(private = "file")
query_verb :: proc(cm: ^IContextMenu, offset: u32, allocator: runtime.Allocator) -> string {
	buf: [SHELL_MENU_TEXT_MAX]u16
	if cm->GetCommandString(uintptr(offset), GCS_VERBW, nil, raw_data(buf[:]), u32(len(buf))) < 0 { return "" }
	return narrow(buf[:], allocator)
}
