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

// The machine the offscreen windows of the process share (a process has one screen, as a machine has its monitors). The windows
// of any thread read it: locked.
@(private = "file")
Virtual_Machine :: struct {
	mutex:             sync.Mutex,
	screen:            Virtual_Screen,
	serial:            u64,   // how often the screen changed: an offscreen window's Display_Info.serial follows it
	offscreen_windows: int,   // open: the calls that name no window (clipboard_formats) go to the process's store then (atomic)
}

@(private = "file") machine := Virtual_Machine{screen = VIRTUAL_SCREEN_DEFAULT, serial = 1}

// The screen of the offscreen windows. Each window's display_info tells the change by its serial, as for a monitor whose mode
// changed.
virtual_screen_set :: proc(s: Virtual_Screen) {
	sync.guard(&machine.mutex)
	machine.screen = s
	machine.serial += 1
}

virtual_screen :: proc() -> Virtual_Screen {
	sync.guard(&machine.mutex)
	return machine.screen
}

// The window becomes, or stops being, the one the user is in: `focused`, `active` and the Activate event, as a real window's
// activation gives them. The system does this for a real window: a no-op for one.
set_offscreen_active :: proc(w: ^Window, on: bool) {
	if !w.offscreen || w.active == on { return }
	w.focused, w.active = on, on
	inject_event(w, {kind = .Activate})
}

@(private)
offscreen_display :: proc(w: ^Window) -> Display_Info {
	sync.guard(&machine.mutex)
	if w.display.serial != machine.serial {
		w.display = {hz = machine.screen.hz, max_hz = machine.screen.hz, source = .Default, serial = machine.serial}
	}
	return w.display
}

@(private)
offscreen_opened :: proc() { sync.atomic_add(&machine.offscreen_windows, 1) }

@(private)
offscreen_closed :: proc() { sync.atomic_sub(&machine.offscreen_windows, 1) }

// Whether a clipboard call goes to the process's store: an offscreen window's; a call with no window when the process runs
// offscreen.
@(private)
clip_is_virtual :: proc(w: ^Window) -> bool { return w != nil ? w.offscreen : sync.atomic_load(&machine.offscreen_windows) > 0 }
