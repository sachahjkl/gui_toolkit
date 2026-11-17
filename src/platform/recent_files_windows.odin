#+build windows
package platform

// The recent documents of Windows (recent_files.odin has the API): the shell keeps them in the user's Recent folder and
// in the jump list of the program whose AppUserModelID the file's ProgID names (desktop's Documents part writes it).

import win "core:sys/windows"

foreign import shell32_recent "system:Shell32.lib"
@(default_calling_convention = "system", private = "file")
foreign shell32_recent {
	// (pv is a void pointer whose kind the flags say; this file passes only SHARD_PATHW, a path)
	SHAddToRecentDocs :: proc(flags: win.UINT, pv: win.LPCWSTR) ---
}

@(private = "file") SHARD_PATHW :: 0x00000003   // pv is a path in UTF-16

@(private)
add_recent_file_windows :: proc(path: string) {
	if path == "" { return }
	SHAddToRecentDocs(SHARD_PATHW, win.utf8_to_wstring(path, context.temp_allocator))
}
