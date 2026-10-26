#+build !windows
package platform

// The file dialogs and shell actions on the systems that have no implementation yet (dialogs.odin has the API): every
// call answers "not supported" (a dialog test hook still answers), so an app written for them builds and runs.

open_file_dialog :: proc(d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	if dialog_test_hook != nil { return dialog_test_hook(0, d, allocator) }
	return {status = .Unsupported}
}

save_file_dialog :: proc(d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	if dialog_test_hook != nil { return dialog_test_hook(1, d, allocator) }
	return {status = .Unsupported}
}

pick_folder_dialog :: proc(d: File_Dialog, allocator := context.allocator) -> Dialog_Result {
	if dialog_test_hook != nil { return dialog_test_hook(2, d, allocator) }
	return {status = .Unsupported}
}

known_folder_path :: proc(k: Known_Folder, allocator := context.allocator) -> string { return "" }
open_url :: proc(url: string) -> bool { return false }
open_path :: proc(path: string) -> bool { return false }
reveal_in_folder :: proc(path: string) -> bool { return false }
