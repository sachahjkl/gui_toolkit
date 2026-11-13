#+build windows
package platform

// The file dialogs and shell actions of dialogs.odin on Windows: the Common Item Dialog (IFileOpenDialog,
// IFileSaveDialog, FOS_PICKFOLDERS for folders) and ShellExecuteExW.

import "core:hash"
import "core:strings"
import win "core:sys/windows"
import "../base"

open_file_dialog :: proc(d: File_Dialog, allocator := context.allocator, loc := #caller_location) -> Dialog_Result {
	base.blocking("platform.open_file_dialog", loc)
	if dialog_test_hook != nil { return dialog_test_hook(DIALOG_OPEN, d, allocator) }
	return file_dialog_show(DIALOG_OPEN, d, allocator)
}

save_file_dialog :: proc(d: File_Dialog, allocator := context.allocator, loc := #caller_location) -> Dialog_Result {
	base.blocking("platform.save_file_dialog", loc)
	if dialog_test_hook != nil { return dialog_test_hook(DIALOG_SAVE, d, allocator) }
	return file_dialog_show(DIALOG_SAVE, d, allocator)
}

pick_folder_dialog :: proc(d: File_Dialog, allocator := context.allocator, loc := #caller_location) -> Dialog_Result {
	base.blocking("platform.pick_folder_dialog", loc)
	if dialog_test_hook != nil { return dialog_test_hook(DIALOG_FOLDER, d, allocator) }
	return file_dialog_show(DIALOG_FOLDER, d, allocator)
}

@(private = "file")
known_folder_id :: proc(k: Known_Folder) -> ^win.GUID {
	@(static) ids := [Known_Folder]win.GUID{
		.None = {}, .Desktop = win.FOLDERID_Desktop, .Documents = win.FOLDERID_Documents, .Downloads = win.FOLDERID_Downloads,
		.Music = win.FOLDERID_Music, .Pictures = win.FOLDERID_Pictures, .Videos = win.FOLDERID_Videos, .Home = win.FOLDERID_Profile,
	}
	return &ids[k]
}

// The path of a folder the system names ("" when it has none).
known_folder_path :: proc(k: Known_Folder, allocator := context.allocator) -> string {
	if k == .None { return "" }
	p: win.LPWSTR
	if win.SHGetKnownFolderPath(known_folder_id(k), 0, nil, &p) < 0 || p == nil { return "" }
	defer win.CoTaskMemFree(p)
	return wide_to_utf8(p, allocator)
}

@(private = "file")
wide_to_utf8 :: proc(p: win.LPWSTR, allocator := context.allocator) -> string {
	n := 0
	for (cast([^]u16)p)[n] != 0 { n += 1 }
	s, err := win.utf16_to_utf8((cast([^]u16)p)[:n], allocator)
	return err == nil ? s : ""
}

@(private = "file")
item_path :: proc(item: ^win.IShellItem, allocator := context.allocator) -> string {
	wp: win.LPWSTR
	if item->GetDisplayName(.FILESYSPATH, &wp) < 0 || wp == nil { return "" }
	defer win.CoTaskMemFree(wp)
	return wide_to_utf8(wp, allocator)
}

// A stable GUID of an id (the system keeps the last folder per dialog GUID).
@(private = "file")
guid_of :: proc(id: string) -> win.GUID {
	a := hash.fnv64a(transmute([]byte)id)
	b := hash.fnv64a(transmute([]byte)strings.concatenate({"wren-dialog:", id}, context.temp_allocator))
	g := win.GUID{Data1 = u32(a), Data2 = u16(a >> 32), Data3 = u16(a >> 48)}
	for i in 0 ..< 8 { g.Data4[i] = win.BYTE(b >> (8 * uint(i))) }
	return g
}

// One line of the dialog's type list as the system takes it.
File_Dialog_Type :: struct { name, spec: string }

// What the Common Item Dialog is told for a File_Dialog of `kind` (DIALOG_OPEN, DIALOG_SAVE, DIALOG_FOLDER: the kinds
// of dialog_test_hook): file_dialog_show applies it. Pure but for a known folder's path: a test reads it without a dialog.
File_Dialog_Call :: struct {
	set_options:   win.FILEOPENDIALOGOPTIONS,   // added to the dialog's own options
	clear_options: win.FILEOPENDIALOGOPTIONS,   // taken from them
	title:         string,                      // "": not set
	types:         []File_Dialog_Type,          // SetFileTypes (none for a folder)
	type_index:    u32,                         // SetFileTypeIndex: 1-based
	file_name:     string,                      // save: SetFileName ("": not set)
	default_ext:   string,                      // save: SetDefaultExtension, without the dot ("": not set)
	client_guid:   win.GUID,                    // SetClientGuid when `remember`
	remember:      bool,
	folder:        string,                      // "": none
	folder_forced: bool,                        // SetFolder (an explicit folder); else SetDefaultFolder (a known folder)
}

ALL_FILES_NAME :: "All files (*.*)"
ALL_FILES_SPEC :: "*.*"

// The call for a dialog (its strings in `allocator`).
file_dialog_call :: proc(kind: int, d: File_Dialog, allocator := context.temp_allocator) -> File_Dialog_Call {
	c := File_Dialog_Call{set_options = win.FOS_FORCEFILESYSTEM | win.FOS_PATHMUSTEXIST, title = d.title}
	switch kind {
	case DIALOG_OPEN:
		c.set_options |= win.FOS_FILEMUSTEXIST
		if d.multiple { c.set_options |= win.FOS_ALLOWMULTISELECT }
	case DIALOG_SAVE:
		if d.overwrite_prompt { c.set_options |= win.FOS_OVERWRITEPROMPT } else { c.clear_options |= win.FOS_OVERWRITEPROMPT }
		c.file_name = d.suggested_name
		c.default_ext = strings.trim_prefix(d.default_ext, ".")
	case DIALOG_FOLDER:
		c.set_options |= win.FOS_PICKFOLDERS
	}
	if kind != DIALOG_FOLDER {
		types := make([dynamic]File_Dialog_Type, allocator)
		for f in d.filters {
			pats := filter_patterns(f, allocator)
			append(&types, File_Dialog_Type{f.name != "" ? f.name : pats, pats})
		}
		if d.all_files || len(types) == 0 { append(&types, File_Dialog_Type{ALL_FILES_NAME, ALL_FILES_SPEC}) }
		c.types = types[:]
		c.type_index = u32(clamp(d.filter_index, 0, len(types) - 1) + 1)
	}
	if d.remember_id != "" { c.client_guid, c.remember = guid_of(d.remember_id), true }
	c.folder, c.folder_forced = d.start_dir, d.start_dir != ""
	if c.folder == "" && d.start_known != .None { c.folder = known_folder_path(d.start_known, allocator) }
	return c
}

@(private = "file")
file_dialog_show :: proc(kind: int, d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	res := Dialog_Result{status = .Failed}
	hr := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	if hr >= 0 { defer win.CoUninitialize() }   // (another mode already on this thread: the dialog works in it too)
	call := file_dialog_call(kind, d)
	dlg: ^win.IFileDialog
	if kind == DIALOG_SAVE {
		sd: ^win.IFileSaveDialog
		if win.CoCreateInstance(win.CLSID_FileSaveDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileSaveDialog, cast(^rawptr)&sd) < 0 || sd == nil { return res }
		dlg = cast(^win.IFileDialog)sd
	} else {
		od: ^win.IFileOpenDialog
		if win.CoCreateInstance(win.CLSID_FileOpenDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileOpenDialog, cast(^rawptr)&od) < 0 || od == nil { return res }
		dlg = cast(^win.IFileDialog)od
	}
	defer dlg->Release()
	opts: win.FILEOPENDIALOGOPTIONS
	dlg->GetOptions(&opts)
	dlg->SetOptions((opts | call.set_options) &~ call.clear_options)
	W :: proc(s: string) -> win.LPCWSTR { return win.utf8_to_wstring(s, context.temp_allocator) }
	if call.title != "" { dlg->SetTitle(W(call.title)) }
	if len(call.types) > 0 {
		specs := make([]win.COMDLG_FILTERSPEC, len(call.types), context.temp_allocator)
		for ty, i in call.types { specs[i] = {W(ty.name), W(ty.spec)} }
		dlg->SetFileTypes(u32(len(specs)), &specs[0])
		dlg->SetFileTypeIndex(call.type_index)
	}
	if call.file_name != "" { dlg->SetFileName(W(call.file_name)) }
	if call.default_ext != "" { dlg->SetDefaultExtension(W(call.default_ext)) }
	if call.remember { dlg->SetClientGuid(call.client_guid) }
	if call.folder != "" {
		folder: ^win.IShellItem
		if win.SHCreateItemFromParsingName(W(call.folder), nil, win.IID_IShellItem, cast(^rawptr)&folder) >= 0 && folder != nil {
			// an explicit folder wins over the one remembered; a known folder is only the default
			if call.folder_forced { dlg->SetFolder(folder) } else { dlg->SetDefaultFolder(folder) }
			folder->Release()
		}
	}
	owner: win.HWND
	if d.owner != nil { owner = d.owner.hwnd }
	hr = dlg->Show(owner)
	ERROR_CANCELLED :: 1223
	if hr == win.HRESULT_FROM_WIN32(ERROR_CANCELLED) { res.status = .Cancelled; return res }
	if hr < 0 { return res }
	idx: u32
	if dlg->GetFileTypeIndex(&idx) >= 0 && idx > 0 { res.filter = int(idx) - 1 }
	paths := make([dynamic]string, allocator)
	if kind == DIALOG_OPEN && d.multiple {
		arr: ^win.IShellItemArray
		if (cast(^win.IFileOpenDialog)dlg)->GetResults(&arr) >= 0 && arr != nil {
			n: u32
			arr->GetCount(&n)
			for i in 0 ..< n {
				it: ^win.IShellItem
				if arr->GetItemAt(i, &it) < 0 || it == nil { continue }
				if p := item_path(it, allocator); p != "" { append(&paths, p) }
				it->Release()
			}
			arr->Release()
		}
	} else {
		it: ^win.IShellItem
		if dlg->GetResult(&it) >= 0 && it != nil {
			if p := item_path(it, allocator); p != "" { append(&paths, p) }
			it->Release()
		}
	}
	res.paths = paths[:]
	res.status = len(paths) > 0 ? .Chosen : .Failed
	return res
}

@(private = "file")
shell_execute :: proc(verb, file, params: string) -> bool {
	W :: proc(s: string) -> win.LPCWSTR { return s == "" ? nil : win.utf8_to_wstring(s, context.temp_allocator) }
	_ = win.CoInitializeEx(nil, .APARTMENTTHREADED | .DISABLE_OLE1DDE)
	info := win.SHELLEXECUTEINFOW{cbSize = size_of(win.SHELLEXECUTEINFOW), lpVerb = W(verb), lpFile = W(file), lpParameters = W(params), nShow = win.SW_SHOWNORMAL}
	return bool(win.ShellExecuteExW(&info))
}

// The system's handler of a URL (http(s), mailto...): the default browser, the mail client.
open_url :: proc(url: string, loc := #caller_location) -> bool {
	base.blocking("platform.open_url", loc)
	if url == "" { return false }
	return shell_execute("open", url, "")
}

// A file or folder opened by the application of its type (a folder: the file manager).
open_path :: proc(path: string, loc := #caller_location) -> bool {
	base.blocking("platform.open_path", loc)
	if path == "" { return false }
	return shell_execute("open", path, "")
}

// The file manager on the folder of `path`, with it selected.
reveal_in_folder :: proc(path: string, loc := #caller_location) -> bool {
	base.blocking("platform.reveal_in_folder", loc)
	if path == "" { return false }
	p, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	return shell_execute("open", "explorer.exe", strings.concatenate({"/select,\"", p, "\""}, context.temp_allocator))
}
