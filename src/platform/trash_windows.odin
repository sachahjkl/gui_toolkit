#+build windows
package platform

// The Recycle Bin, through IFileOperation: its records ($I) are the shell's, so Explorer's Restore reads them, and the
// operation says the $R path it made, which put_back renames back. SHFileOperationW does not say where the item went:
// no undo with it.

import "core:strings"
import win "core:sys/windows"
import base "../base"

// Moves `path` to the system's trash. `in_trash`: where it is now (put_back's argument), in `allocator`; "" with ok
// when the drive has no Recycle Bin and the item was deleted for good. It asks the disk: call it from a task.
move_to_trash :: proc(path: string, allocator := context.allocator, loc := #caller_location) -> (in_trash: string, ok: bool) {
	base.blocking("platform.move_to_trash", loc)
	if path == "" { return }
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	if win.GetFileAttributesW(wpath) == win.INVALID_FILE_ATTRIBUTES { return }
	// (an apartment of this thread for the operation; one already there in another mode is fine)
	joined := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	defer if win.SUCCEEDED(joined) { win.CoUninitialize() }
	op: ^Trash_File_Operation
	if !win.SUCCEEDED(win.CoCreateInstance(TRASH_CLSID_FILE_OPERATION, nil, win.CLSCTX_ALL, TRASH_IID_FILE_OPERATION, (^rawptr)(&op))) { return }
	defer op->Release()
	item: ^win.IShellItem
	if !win.SUCCEEDED(win.SHCreateItemFromParsingName(wpath, nil, win.IID_IShellItem, (^rawptr)(&item))) { return }
	defer item->Release()
	sink := Trash_Sink{sink = {Vtbl = &trash_sink_vtbl}}
	defer if sink.created != nil { win.CoTaskMemFree(sink.created) }
	if !win.SUCCEEDED(op->SetOperationFlags(TRASH_FLAGS)) || !win.SUCCEEDED(op->DeleteItem(item, &sink)) { return }
	hr := op->PerformOperations()
	aborted: win.BOOL
	_ = op->GetAnyOperationsAborted(&aborted)
	if !win.SUCCEEDED(hr) || !win.SUCCEEDED(sink.result) || bool(aborted) { return }
	if sink.created == nil { return "", true }
	s, err := win.wstring_to_utf8(cstring16(sink.created), -1, allocator)
	return err == nil ? s : "", true
}

// Puts back what move_to_trash moved to `in_trash` (its $R file), at `to` (where it was), and removes its $I record.
// False when something is at `to` again: MoveFileExW without MOVEFILE_REPLACE_EXISTING never goes over it. It asks the
// disk: call it from a task.
put_back :: proc(in_trash, to: string, loc := #caller_location) -> bool {
	base.blocking("platform.put_back", loc)
	if in_trash == "" || to == "" { return false }
	if !win.MoveFileExW(win.utf8_to_wstring(in_trash, context.temp_allocator), win.utf8_to_wstring(to, context.temp_allocator), 0) { return false }
	// (the $I record beside the $R file: the same name after its two first letters)
	cut := strings.last_index_any(in_trash, "\\/")
	name := in_trash[cut + 1:]
	if strings.has_prefix(name, "$R") {
		record := strings.concatenate({in_trash[:cut + 1], "$I", name[2:]}, context.temp_allocator)
		_ = win.DeleteFileW(win.utf8_to_wstring(record, context.temp_allocator))
	}
	return true
}

// IFileOperation (shobjidl_core.h), which core:sys/windows does not declare: only the methods move_to_trash calls are
// typed, the others keep their places in the table.
@(private = "file")
Trash_File_Operation :: struct #raw_union {
	#subtype IUnknown: win.IUnknown,
	using Vtbl: ^Trash_File_Operation_Vtbl,
}

@(private = "file")
Trash_File_Operation_Vtbl :: struct {
	using IUnknownVtbl: win.IUnknownVtbl,
	Advise:                  rawptr,
	Unadvise:                rawptr,
	SetOperationFlags:       proc "system" (this: ^Trash_File_Operation, flags: win.DWORD) -> win.HRESULT,
	SetProgressMessage:      rawptr,
	SetProgressDialog:       rawptr,
	SetProperties:           rawptr,
	SetOwnerWindow:          rawptr,
	ApplyPropertiesToItem:   rawptr,
	ApplyPropertiesToItems:  rawptr,
	RenameItem:              rawptr,
	RenameItems:             rawptr,
	MoveItem:                rawptr,
	MoveItems:               rawptr,
	CopyItem:                rawptr,
	CopyItems:               rawptr,
	DeleteItem:              proc "system" (this: ^Trash_File_Operation, item: ^win.IShellItem, sink: ^win.IFileOperationProgressSink) -> win.HRESULT,
	DeleteItems:             rawptr,
	NewItem:                 rawptr,
	PerformOperations:       proc "system" (this: ^Trash_File_Operation) -> win.HRESULT,
	GetAnyOperationsAborted: proc "system" (this: ^Trash_File_Operation, aborted: ^win.BOOL) -> win.HRESULT,
}

@(private = "file")
TRASH_CLSID_FILE_OPERATION := &win.GUID{0x3ad05575, 0x8857, 0x4850, {0x92, 0x77, 0x11, 0xb8, 0x5b, 0xdb, 0x8e, 0x09}}
@(private = "file")
TRASH_IID_FILE_OPERATION := &win.GUID{0x947aab5f, 0x0a5c, 0x4c13, {0xb4, 0xd6, 0x4b, 0xf7, 0x83, 0x6f, 0xc9, 0xf8}}
@(private = "file")
TRASH_IID_PROGRESS_SINK := &win.GUID{0x04b0f1a7, 0x9490, 0x44bc, {0x96, 0xe1, 0x42, 0x96, 0xa3, 0x12, 0x52, 0xe2}}

// No interface at all, to the Recycle Bin (FOFX_RECYCLEONDELETE: FOF_ALLOWUNDO alone is not enough for IFileOperation).
@(private = "file")
TRASH_FLAGS :: win.FOF_NO_UI | win.FOF_ALLOWUNDO | 0x00080000

// The sink of one delete: it keeps the path of the item the Recycle Bin made (CoTaskMem, the caller frees it). It lives
// on the caller's stack for the length of PerformOperations, so it counts no references.
@(private = "file")
Trash_Sink :: struct {
	using sink: win.IFileOperationProgressSink,
	created:    win.LPWSTR,
	result:     win.HRESULT,
}

@(private = "file")
trash_sink_vtbl := win.IFileOperationProgressSinkVtbl{
	QueryInterface = proc "system" (this: ^win.IUnknown, riid: win.REFIID, out: ^rawptr) -> win.HRESULT {
		if riid^ == win.IUnknown_UUID^ || riid^ == TRASH_IID_PROGRESS_SINK^ { out^ = this; return win.S_OK }
		out^ = nil
		return transmute(win.HRESULT)u32(win.E_NOINTERFACE)
	},
	AddRef  = proc "system" (this: ^win.IUnknown) -> win.ULONG { return 1 },
	Release = proc "system" (this: ^win.IUnknown) -> win.ULONG { return 1 },
	StartOperations  = proc "system" (this: ^win.IFileOperationProgressSink) -> win.HRESULT { return win.S_OK },
	FinishOperations = proc "system" (this: ^win.IFileOperationProgressSink, hr: win.HRESULT) -> win.HRESULT { return win.S_OK },
	PreRenameItem    = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item: ^win.IShellItem, name: win.LPCWSTR) -> win.HRESULT { return win.S_OK },
	PostRenameItem   = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item: ^win.IShellItem, name: win.LPCWSTR, hr: win.HRESULT, created: ^win.IShellItem) -> win.HRESULT { return win.S_OK },
	PreMoveItem      = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item, to: ^win.IShellItem, name: win.LPCWSTR) -> win.HRESULT { return win.S_OK },
	PostMoveItem     = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item, to: ^win.IShellItem, name: win.LPCWSTR, hr: win.HRESULT, created: ^win.IShellItem) -> win.HRESULT { return win.S_OK },
	PreCopyItem      = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item, to: ^win.IShellItem, name: win.LPCWSTR) -> win.HRESULT { return win.S_OK },
	PostCopyItem     = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item, to: ^win.IShellItem, name: win.LPCWSTR, hr: win.HRESULT, created: ^win.IShellItem) -> win.HRESULT { return win.S_OK },
	PreDeleteItem    = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item: ^win.IShellItem) -> win.HRESULT { return win.S_OK },
	PostDeleteItem   = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, item: ^win.IShellItem, hr: win.HRESULT, created: ^win.IShellItem) -> win.HRESULT {
		s := (^Trash_Sink)(this)
		s.result = hr
		// (no new item: deleted for good, the drive has no Recycle Bin)
		if win.SUCCEEDED(hr) && created != nil && s.created == nil { _ = created->GetDisplayName(.FILESYSPATH, &s.created) }
		return win.S_OK
	},
	PreNewItem     = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, to: ^win.IShellItem, name: win.LPCWSTR) -> win.HRESULT { return win.S_OK },
	PostNewItem    = proc "system" (this: ^win.IFileOperationProgressSink, flags: win.DWORD, to: ^win.IShellItem, name, template: win.LPCWSTR, attributes: win.DWORD, hr: win.HRESULT, item: ^win.IShellItem) -> win.HRESULT { return win.S_OK },
	UpdateProgress = proc "system" (this: ^win.IFileOperationProgressSink, total, done: win.UINT) -> win.HRESULT { return win.S_OK },
	ResetTimer     = proc "system" (this: ^win.IFileOperationProgressSink) -> win.HRESULT { return win.S_OK },
	PauseTimer     = proc "system" (this: ^win.IFileOperationProgressSink) -> win.HRESULT { return win.S_OK },
	ResumeTimer    = proc "system" (this: ^win.IFileOperationProgressSink) -> win.HRESULT { return win.S_OK },
}
