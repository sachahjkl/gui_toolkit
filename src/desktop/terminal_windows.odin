package tk_desktop

import "core:strings"
import win "core:sys/windows"

@(private)
open_terminal_native :: proc(dir: string) -> bool {
	// (a folder's trailing backslash would escape the closing quote: "C:\" is "C:\\" there)
	quoted := dir
	if len(quoted) > 0 && quoted[len(quoted) - 1] == '\\' { quoted = strings.concatenate({quoted, "\\"}, context.temp_allocator) }
	if start_quietly("wt.exe", strings.concatenate({"-d \"", quoted, "\""}, context.temp_allocator), dir) { return true }
	return start_quietly("cmd.exe", "", dir)
}

// Starts `program` in `dir`, with no dialog of the shell when it is not found.
@(private = "file")
start_quietly :: proc(program, params, dir: string) -> bool {
	info := win.SHELLEXECUTEINFOW{
		cbSize = size_of(win.SHELLEXECUTEINFOW),
		fMask = win.SEE_MASK_FLAG_NO_UI,
		lpVerb = win.utf8_to_wstring("open", context.temp_allocator),
		lpFile = win.utf8_to_wstring(program, context.temp_allocator),
		lpParameters = params != "" ? win.utf8_to_wstring(params, context.temp_allocator) : nil,
		lpDirectory = win.utf8_to_wstring(dir, context.temp_allocator),
		nShow = win.SW_SHOWNORMAL,
	}
	return bool(win.ShellExecuteExW(&info))
}
