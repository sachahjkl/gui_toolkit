#+build !windows
#+build !linux
package platform

// Windows on the systems that have no backend yet (macOS: the port comes later). No window opens: open_window,
// open_overlay and open_window_offscreen return nil, so a program learns at once that it has none. Every other call
// accepts a window and does nothing, or answers "no" or "unknown". platform.odin has the API; Windows
// (platform_win32.odin) and Linux (platform_linux.odin) have their own.

// The fields that platform.odin, virtual.odin and the other shared files read. Nothing sets them: no window exists.
Native_Window :: struct {
	cursor:          Cursor,
	closed:          bool,
	in_poll:         bool,
	display:         Display_Info,
	injected:        [dynamic]Event,
	returned:        int,
	keep_events:     bool,
	paint_requested: bool,
	stats:           Pump_Stats,
	buttons_down:    Mouse_Buttons,
	offscreen:       bool,
	off_place:       [4]int,
}

// No window system here: nothing opens.
open_window :: proc(title: string, size: [2]int, user: rawptr = nil, on_frame: proc(user: rawptr) = nil, transparent := false, integrated_title := false) -> ^Window { return nil }
open_overlay :: proc(title: string, area: [4]int, keyboard := Overlay_Keyboard.On_Demand, user: rawptr = nil, on_frame: proc(user: rawptr) = nil) -> ^Window { return nil }
open_window_offscreen :: proc(title: string, size: [2]int, dpi_scale: f32 = 1, user: rawptr = nil, on_frame: proc(user: rawptr) = nil) -> ^Window { return nil }
destroy_window :: proc(w: ^Window) {}

// No window, so no events: nothing is read, nothing waits.
poll_events :: proc(w: ^Window, wait: bool, timeout_ms := 0) -> []Event { return nil }
wait_event :: proc(w: ^Window, timeout_ms := 0) {}
wait_handle :: proc(w: ^Window, handle: rawptr, timeout_ms := 0, until_press := false) -> bool { return false }
events_waiting :: proc(w: ^Window) -> bool { return false }
inject_event :: proc(w: ^Window, e: Event) {}
wake :: proc(w: ^Window) {}
wake_handle :: proc(w: ^Window) -> rawptr { return nil }
wake_signal :: proc(h: rawptr) {}
request_close :: proc(w: ^Window) {}

// No compositor tells when a picture is shown here: nothing is pending, nothing was waited for.
frame_shown_ask :: proc(w: ^Window) {}
frame_shown_forget :: proc(w: ^Window) {}
frame_shown_held :: proc(w: ^Window) {}
frame_shown_pending :: proc(w: ^Window) -> bool { return false }
frame_shown_waited_ms :: proc(w: ^Window) -> int { return -1 }

is_closed :: proc(w: ^Window) -> bool { return w.closed }
is_offscreen :: proc(w: ^Window) -> bool { return w.offscreen }
is_overlay :: proc(w: ^Window) -> bool { return false }
is_fullscreen :: proc(w: ^Window) -> bool { return false }
is_maximized :: proc(w: ^Window) -> bool { return false }
is_minimized :: proc(w: ^Window) -> bool { return false }
is_integrated_title :: proc(w: ^Window) -> bool { return false }
is_window_visible :: proc(w: ^Window) -> bool { return false }
can_hide_windows :: proc() -> bool { return false }
system_menu_available :: proc(w: ^Window) -> bool { return false }
system_title_available :: proc(w: ^Window) -> bool { return false }
needs_frame_outline :: proc(w: ^Window) -> bool { return false }
needs_top_border :: proc(w: ^Window) -> bool { return false }
resize_border :: proc(w: ^Window) -> int { return max(int(RESIZE_BAND_PX * w.dpi_scale), 1) }

// No window to change: each request is dropped.
show_window :: proc(w: ^Window) {}
hide_window :: proc(w: ^Window) {}
raise_window :: proc(w: ^Window) {}
raise_window_token :: proc(w: ^Window, token: string) {}
minimize :: proc(w: ^Window) {}
toggle_maximize :: proc(w: ^Window) {}
set_fullscreen :: proc(w: ^Window, on: bool) {}
set_title :: proc(w: ^Window, title: string) {}
set_size :: proc(w: ^Window, size: [2]int) {}
move_window :: proc(w: ^Window, x, y: int) {}
set_integrated_title :: proc(w: ^Window, on: bool) {}
set_dark_title :: proc(w: ^Window, dark: bool) {}
set_border_color :: proc(w: ^Window, rgb: Maybe(u32)) {}
set_square_corners :: proc(w: ^Window, square: bool) {}
set_backdrop :: proc(w: ^Window, on: bool) -> bool { return false }
set_input_region :: proc(w: ^Window, rects: [][4]int) {}
clear_input_region :: proc(w: ^Window) {}
show_system_menu :: proc(w: ^Window, pos: [2]f32) {}
set_app_id :: proc(id: string) {}

// No window, so no place: zero sizes and an empty placement.
get_placement :: proc(w: ^Window) -> Placement { return {} }
set_placement :: proc(w: ^Window, p: Placement) {}
client_origin :: proc(w: ^Window) -> [2]int { return {} }
outer_rect :: proc(w: ^Window) -> [4]int { return {} }
monitor_size :: proc(w: ^Window) -> [2]int { return {} }
window_output_name :: proc(w: ^Window) -> string { return "" }

// No surface: a renderer sees backend .None, as for an offscreen window.
native_surface_handles :: proc(w: ^Window) -> Surface_Handles { return {} }

// Nothing answers about the monitor: the fallback rate, marked .Default.
display_info :: proc(w: ^Window) -> Display_Info {
	return {hz = DISPLAY_FALLBACK_HZ, max_hz = DISPLAY_FALLBACK_HZ, numerator = DISPLAY_FALLBACK_HZ, denominator = 1, source = .Default}
}
display_invalidate :: proc(w: ^Window) {}
display_live_hz :: proc(w: ^Window) -> (hz: f64, ok: bool) { return 0, false }

// The plain-text clipboard: nothing is there, nothing is written (clipboard_stub.odin has the rich one).
get_clipboard :: proc(w: ^Window, allocator := context.allocator, loc := #caller_location) -> string { return "" }
set_clipboard :: proc(w: ^Window, text: string) {}

// The system's preferences are not read here: light, animations on (the defaults when a system says nothing), the
// toolkit's wheel step.
dark_mode_preferred :: proc(loc := #caller_location) -> bool { return false }
@(private) color_scheme_watch :: proc() {}
os_animations_enabled :: proc() -> bool { return true }
wheel_lines :: proc(across := false) -> f32 { return input_defaults().wheel_lines }

// No icon, no launcher token, no font folder is known here.
app_icon_rgba :: proc(size: int, allocator := context.allocator) -> (pixels: []u8, ok: bool) { return nil, false }
activation_token_from_env :: proc(allocator := context.allocator) -> string { return "" }
system_font_path :: proc(file: string, allocator := context.temp_allocator) -> string { return "" }

