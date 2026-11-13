package ui

// How the interface answers the hand: delays, repeats, steps, the zoom's step. One struct the State holds, so a settings page
// can show each value and a program can change them all at once. The defaults are FEEL_DEFAULT.
//
//   f := ui.feel(&state)
//   f.tooltip_delay_ms = 800
//   ui.set_feel(&state, f)

import "../platform"

Feel :: struct {
	tooltip_delay_ms:    int,   // the pointer rests this long on a box before its tooltip shows (hovered_for). 500
	menu_hover_ms:       int,   // the pointer rests this long on a submenu's item before it opens, or another closes. 280
	menu_item_em:        f32,   // the height of a menu item, in em, times the density. 1.9
	palette_fade_ms:     int,   // a change of palette cross-fades every colour for this long. 160
	typeahead_ms:        int,   // keys typed in a list within this much of each other add up to one prefix. 900
	undo_steps:          int,   // the steps of edit history a line_edit and a text_edit keep. 200
	undo_merge_ms:       int,   // typing (or deleting) within this much of the previous edit is the same undo step. 1000
	repeat_delay_ms:     int,   // a held button (a number's − and +, a scroll bar's arrow) repeats after this long. 420
	repeat_interval_ms:  int,   // then once every this much. 55
	step_shift:          f64,   // Shift multiplies a step (a slider's key or notch, a number's button, key or notch). 10
	step_ctrl:           f64,   // Ctrl multiplies the step of a number in text (num_step_delta). 100
	step_alt:            f64,   // Alt multiplies the step of a number in text. 0.1
	step_page:           f64,   // Page Up / Page Down move this many steps (a slider, a number in text). 10
	zoom_step:           f32,   // the interface's zoom is multiplied or divided by it (Ctrl+wheel, Ctrl+= / Ctrl+-). 1.1
	wheel_lines:         f32,   // lines a notch of the wheel moves where the system does not say (platform.wheel_lines). 3
	key_repeat_delay_ms: int,   // a held key repeats after this long, where the system leaves it to the program and does not say (Wayland). 600
	key_repeat_rate:     int,   // then this many times a second, likewise. 25
	fling_stop_speed:    f32,   // a fling of the finger is over under this speed, pixels per second (platform.touch_fling). 20
}

FEEL_DEFAULT :: Feel{
	tooltip_delay_ms    = 500,
	menu_hover_ms       = 280,
	menu_item_em        = 1.9,
	palette_fade_ms     = 160,
	typeahead_ms        = 900,
	undo_steps          = 200,
	undo_merge_ms       = 1000,
	repeat_delay_ms     = 420,
	repeat_interval_ms  = 55,
	step_shift          = 10,
	step_ctrl           = 100,
	step_alt            = 0.1,
	step_page           = 10,
	zoom_step           = 1.1,
	wheel_lines         = 3,
	key_repeat_delay_ms = 600,
	key_repeat_rate     = 25,
	fling_stop_speed    = 20,
}

// Least values that keep each one working: an undo history of one step, a zoom that still grows, a repeat that is not every
// build, a menu row a line of text fits.
@(private = "file") FEEL_UNDO_STEPS_MIN :: 1
@(private = "file") FEEL_ZOOM_STEP_MIN :: 1.01
@(private = "file") FEEL_REPEAT_INTERVAL_MIN_MS :: 1
@(private = "file") FEEL_MENU_ITEM_EM_MIN :: 1.2

feel :: proc(s: ^State) -> Feel { return s.feel }

// Takes `f` for every build from now on (each value brought within what works), and gives the platform its part: the
// wheel's lines, a held key's repeat and a fling's end, for the thread that builds this state.
set_feel :: proc(s: ^State, f: Feel) {
	f := f
	f.undo_steps = max(f.undo_steps, FEEL_UNDO_STEPS_MIN)
	f.zoom_step = max(f.zoom_step, FEEL_ZOOM_STEP_MIN)
	f.repeat_interval_ms = max(f.repeat_interval_ms, FEEL_REPEAT_INTERVAL_MIN_MS)
	f.menu_item_em = max(f.menu_item_em, FEEL_MENU_ITEM_EM_MIN)
	for v in ([]^int{&f.tooltip_delay_ms, &f.menu_hover_ms, &f.palette_fade_ms, &f.typeahead_ms, &f.undo_merge_ms, &f.repeat_delay_ms, &f.key_repeat_delay_ms, &f.key_repeat_rate}) { v^ = max(v^, 0) }
	f.wheel_lines = max(f.wheel_lines, 0)
	f.fling_stop_speed = max(f.fling_stop_speed, 0)
	s.feel = f
	feel_apply_platform(f)
}

@(private)
feel_apply_platform :: proc(f: Feel) {
	platform.set_input_defaults({wheel_lines = f.wheel_lines, key_repeat_delay_ms = f.key_repeat_delay_ms, key_repeat_rate = f.key_repeat_rate, fling_stop_speed = f.fling_stop_speed})
}

// The current state's feel, or the defaults where no state is current: an edit of a field or a number's step made outside
// any build still follows it.
@(private)
feel_now :: proc() -> Feel { return current != nil ? current.feel : FEEL_DEFAULT }
