#+build !windows
#+build !linux
package platform

// The rich clipboard on the systems that have no implementation yet (clipboard.odin has the API and the conversions):
// nothing is there, nothing can be written. Linux has its own (clipboard_linux.odin).

clipboard_sequence :: proc() -> u32 { return 0 }
clipboard_formats :: proc() -> Clipboard_Formats { return {} }
clipboard_format_names :: proc(w: ^Window, allocator := context.allocator) -> []string { return nil }
clipboard_get_image :: proc(w: ^Window, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) { return }
clipboard_get_html :: proc(w: ^Window, allocator := context.allocator) -> (html, source_url: string, ok: bool) { return }
clipboard_get_files :: proc(w: ^Window, allocator := context.allocator) -> (paths: []string, ok: bool) { return }
clipboard_set :: proc(w: ^Window, c: Clipboard_Content) -> bool { return false }
clipboard_set_html :: proc(w: ^Window, html: string, text := "", source_url := "") -> bool { return false }
clipboard_set_image :: proc(w: ^Window, img: Clipboard_Image) -> bool { return false }
clipboard_set_files :: proc(w: ^Window, paths: []string) -> bool { return false }
clipboard_watch :: proc(w: ^Window, on: bool) -> bool { return !on }
clipboard_changed :: proc(w: ^Window) -> bool { return false }
png_encode :: proc(img: Clipboard_Image, allocator := context.allocator) -> []u8 { return nil }
png_decode :: proc(b: []u8, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) { return }
