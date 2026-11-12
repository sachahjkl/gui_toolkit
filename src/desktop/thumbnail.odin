package tk_desktop

// The system's thumbnail of a file, as its file manager shows it: on Linux the freedesktop.org Thumbnail Managing
// Standard (the shared cache in ~/.cache/thumbnails, the thumbnailers the desktop installs); on Windows the shell's
// (its thumbnail cache and handlers). See docs/desktop.md, "Thumbnails".

// A thumbnail: straight (not premultiplied) RGBA8, row by row from the top.
Thumbnail :: struct {
	rgba: []u8,
	size: [2]int,
}

thumbnail_destroy :: proc(thumb: ^Thumbnail, allocator := context.allocator) {
	delete(thumb.rgba, allocator)
	thumb^ = {}
}

// What a call may do to give a thumbnail.
@(private)
Thumbnail_Mode :: enum u8 {
	Cached,   // read the system's cache only
	Make,     // and on a miss, have the system make one (run a thumbnailer)
}

// The system's thumbnail of the file at `path` (absolute), at most `size` pixels on its longer side (smaller when the
// system makes none that large). On a miss it has the system make one: on Linux that runs the file type's thumbnailer
// and waits for it (seconds for a long video). It blocks: call it from a worker, never from the interface's thread. ok
// is false when the system has none and cannot make one (no thumbnailer for the type, a file it failed on before).
thumbnail :: proc(path: string, size: int, allocator := context.allocator) -> (thumb: Thumbnail, ok: bool) {
	if size <= 0 { return }
	return thumbnail_native(path, size, .Make, allocator)
}

// The thumbnail the system already keeps for the file at `path`, as `thumbnail` gives it, but nothing is made: a miss is
// ok = false at once. It reads files: call it from a worker.
thumbnail_cached :: proc(path: string, size: int, allocator := context.allocator) -> (thumb: Thumbnail, ok: bool) {
	if size <= 0 { return }
	return thumbnail_native(path, size, .Cached, allocator)
}

// Keeps `rgba` (`width` x `height`, straight RGBA8: a picture the program made of the file at `path`, an absolute path)
// in the system's cache, where `thumbnail_cached` and the other programs find it. Linux only (Windows' shell fills its
// own cache): false elsewhere, and when the file or the cache cannot be read or written. It writes files: call it from
// a worker.
thumbnail_store :: proc(path: string, rgba: []u8, width, height: int) -> bool {
	if width <= 0 || height <= 0 || len(rgba) < width * height * 4 { return false }
	return thumbnail_store_native(path, rgba, width, height)
}
