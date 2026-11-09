package tk_desktop

// The system's icon of a file or a folder, as its file manager shows it: on Linux the icon theme of the person's desktop
// (the Icon Theme specification: the type of the file from shared-mime-info, the theme and the themes it inherits, the
// size nearest to the one asked; PNG files decoded, SVG files rendered by librsvg); on Windows the shell's icon of the
// path. See docs/desktop.md, "Icons".


// An icon: straight (not premultiplied) RGBA8, row by row from the top.
File_Icon :: struct {
	rgba: []u8,
	size: [2]int,
}

file_icon_destroy :: proc(icon: ^File_Icon, allocator := context.allocator) {
	delete(icon.rgba, allocator)
	icon^ = {}
}

// What decides the icon of `path`: two paths with the same key have the same icon (a program keeps one picture per key
// and size). `folder`: the path is a folder (the caller knows; no call to the system is made for it).
file_icon_key :: proc(path: string, folder: bool, allocator := context.allocator) -> string {
	return icon_key_native(path, folder, allocator)
}

// The icon of `path`, about `size` pixels square (the nearest the system has, or rendered at that size). ok is false
// when the system has none to give. It reads files: call it from a worker, not from the interface's thread.
file_icon :: proc(path: string, folder: bool, size: int, allocator := context.allocator) -> (icon: File_Icon, ok: bool) {
	return icon_of_path_native(path, folder, size, allocator)
}

