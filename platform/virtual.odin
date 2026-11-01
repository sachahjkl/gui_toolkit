package platform

import "core:sync"

// What an offscreen window (open_window_offscreen) has in place of a machine. No monitor, no pointer, no keyboard and no
// clipboard of a person is read or written by it: its screen is this one, its input comes through inject_event, its
// cursor is what the app last set (`w.cursor`), its clipboard is the process's store (clipboard.odin). What runs offscreen
// (a service, a headless browser, tests) neither depends on the machine it runs on nor disturbs whoever sits at it.

// The screen an offscreen window is on: what monitor_size and display_info answer for it.
Virtual_Screen :: struct {
	size: [2]int,
	hz:   f64,
}

VIRTUAL_SCREEN_DEFAULT :: Virtual_Screen{size = {1920, 1080}, hz = DISPLAY_FALLBACK_HZ}

@(private = "file") screen := VIRTUAL_SCREEN_DEFAULT
// How often the screen changed: an offscreen window's Display_Info.serial follows it.
@(private = "file") screen_serial: u64 = 1
// How many offscreen windows are open: the calls that name no window (clipboard_formats) go to the process's store then.
@(private = "file") offscreen_windows: int

// The screen of the offscreen windows (a process has one, as a machine has its monitors). Each window's display_info tells
// the change by its serial, as for a monitor whose mode changed.
virtual_screen_set :: proc(s: Virtual_Screen) {
	screen = s
	screen_serial += 1
}

virtual_screen :: proc() -> Virtual_Screen { return screen }

// The window becomes, or stops being, the one the user is in: `focused`, `active` and the Activate event, as a real window's
// activation gives them. The system does this for a real window: a no-op for one.
set_offscreen_active :: proc(w: ^Window, on: bool) {
	if !w.offscreen || w.active == on { return }
	w.focused, w.active = on, on
	inject_event(w, {kind = .Activate})
}

@(private)
offscreen_display :: proc(w: ^Window) -> Display_Info {
	if w.display.serial != screen_serial {
		w.display = {hz = screen.hz, max_hz = screen.hz, source = .Default, serial = screen_serial}
	}
	return w.display
}

@(private)
offscreen_opened :: proc() { sync.atomic_add(&offscreen_windows, 1) }

@(private)
offscreen_closed :: proc() { sync.atomic_sub(&offscreen_windows, 1) }

// Whether a clipboard call goes to the process's store: an offscreen window's; a call with no window when the process runs
// offscreen.
@(private)
clip_is_virtual :: proc(w: ^Window) -> bool { return w != nil ? w.offscreen : sync.atomic_load(&offscreen_windows) > 0 }
