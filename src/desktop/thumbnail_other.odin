#+build !windows
#+build !linux
package tk_desktop

// Where the toolkit does not read the system's thumbnails: none (the program shows its own pictures or icons).

import "base:runtime"

@(private)
thumbnail_native :: proc(path: string, size: int, mode: Thumbnail_Mode, allocator: runtime.Allocator) -> (thumb: Thumbnail, ok: bool) { return }

@(private)
thumbnail_store_native :: proc(path: string, rgba: []u8, width, height: int) -> bool { return false }
