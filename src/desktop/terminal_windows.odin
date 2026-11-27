package tk_desktop

import "core:os"
import "core:strings"
import win "core:sys/windows"
import "../process"

@(private)
open_terminal_native :: proc(dir: string) -> bool {
	// (the folder is the started program's own folder, never a word of its command line: wt reads a ";" in any
	// argument as the start of another of its commands, so a folder named "x; new-tab calc" would start calc. Each
	// program by its whole path: a bare name is looked for in the folder it starts in first, and a wt.exe or a
	// cmd.exe planted in the folder opened would run)
	path_env, _ := os.lookup_env("PATH", context.temp_allocator)
	// (wt.exe is an app execution alias, a reparse point no stat follows: its attributes say it is there)
	exists :: proc(p: string, _: rawptr) -> bool {
		a := win.GetFileAttributesW(win.utf8_to_wstring(p, context.temp_allocator))
		return a != win.INVALID_FILE_ATTRIBUTES && a & win.FILE_ATTRIBUTE_DIRECTORY == 0
	}
	if wt, ok := process.resolve_command("wt.exe", path_env, "", true, exists, nil, context.temp_allocator); ok {
		if start_quietly(wt, "-d .", dir) { return true }
	}
	buf: [win.MAX_PATH]u16
	n := win.GetSystemDirectoryW(&buf[0], u32(len(buf)))
	if n == 0 || int(n) >= len(buf) { return false }
	system, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return false }
	return start_quietly(strings.concatenate({system, "\\cmd.exe"}, context.temp_allocator), "", dir)
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
