package fsx

import win "core:sys/windows"

@(private = "file")
ERROR_LOCK_VIOLATION :: 33

@(private)
file_lock_try :: proc(path: string) -> (l: File_Lock, result: Lock_Result) {
	share := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE
	h := win.CreateFileW(win.utf8_to_wstring(path, context.temp_allocator), win.GENERIC_READ | win.GENERIC_WRITE, share, nil, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return {}, .Failed }
	ov: win.OVERLAPPED
	if !win.LockFileEx(h, win.LOCKFILE_EXCLUSIVE_LOCK | win.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov) {
		busy := win.GetLastError() == ERROR_LOCK_VIOLATION
		win.CloseHandle(h)
		return {}, busy ? .Busy : .Failed
	}
	return {handle = uintptr(h), held = true}, .Locked
}

// Lets the lock go (closing the handle does it); a lock not held: nothing.
file_unlock :: proc(l: ^File_Lock) {
	if l.held { win.CloseHandle(win.HANDLE(l.handle)) }
	l^ = {}
}
