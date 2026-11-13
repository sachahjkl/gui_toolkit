#+build !windows
#+build !linux
package platform

// Cursors on the systems that have no backend yet (macOS: the port comes later). No window opens there
// (window_other.odin), so no cursor is shown or made: every query answers "none" (Cursor_Info.ok false, a nil handle) and
// custom_cursor_create reports .System. Windows (cursors_win32.odin) and Linux (cursors_linux.odin) have their own.

Cursor_Source :: enum u8 { System, Drawn, Hidden }

Cursor_Info :: struct {
	handle: rawptr,
	size:   [2]int,
	hot:    [2]int,
	source: Cursor_Source,
	ok:     bool,
}

set_cursor :: proc(w: ^Window, c: Cursor) {}
set_cursor_custom :: proc(w: ^Window, cc: Custom_Cursor, fallback: Cursor, scale: f32 = 0) {}
shown_cursor :: proc(w: ^Window) -> rawptr { return nil }
cursor_handle_of :: proc(w: ^Window, c: Cursor) -> rawptr { return nil }
cursor_info :: proc(w: ^Window, c: Cursor) -> Cursor_Info { return {} }
cursor_source :: proc(c: Cursor) -> Cursor_Source { return c == .None ? .Hidden : .System }
cursor_scheme :: proc() -> Cursor_Scheme { return .Light }
cursor_settings_changed :: proc() {}
cursor_render :: proc(handle: rawptr, size: int, background: [3]u8, allocator := context.allocator) -> []u8 { return nil }

custom_cursor_create :: proc(w: ^Window, rgba: []u8, size: [2]int, hot: [2]f32, density: f32 = 1, key: u64 = 0, max_css := CUSTOM_CURSOR_MAX_CSS) -> (Custom_Cursor, Custom_Cursor_Error) { return 0, .System }
custom_cursor_release :: proc(w: ^Window, cc: Custom_Cursor) {}
custom_cursor_valid :: proc(w: ^Window, cc: Custom_Cursor) -> bool { return false }
custom_cursor_info :: proc(w: ^Window, cc: Custom_Cursor, scale: f32 = 0) -> Cursor_Info { return {} }
custom_cursor_stats :: proc(w: ^Window) -> (images, handles: int) { return 0, 0 }
